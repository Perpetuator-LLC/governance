#!/usr/bin/env python3
"""Roll up token usage across every agent transcript — the instrument behind a token-efficiency KPI.

"Are we getting better at token usage over time?" needs a number anyone can re-derive on demand. A
baseline produced once by hand is an anecdote; this is the re-derivation.

⚠️ READS ONLY `message.usage.*` AND `timestamp`. It never reads, sums, or emits transcript CONTENT
— not prompts, not outputs, not tool arguments. That is deliberate and load-bearing: the corpus it
walks is every conversation on the machine, and an instrument that touched content would be a
disclosure channel pointed at the whole archive. Keep it that way.

Idempotent, read-only, and tolerant of partial lines: a transcript being APPENDED TO WHILE THIS
RUNS is the normal case, not the exception, so a half-written final line must never abort the run
or skew a total. Unparseable lines are counted and reported, never silently dropped — a parse-error
count that is quietly zero is absence reported as health.

A "seat" is a transcript directory. Claude Code names each one after the working directory with
every separator turned into '-'; the encoded home directory (and a following `projects-`) is
stripped so the seat reads as the project name.

Usage:  token-usage.py [--root DIR] [--days YYYY-MM-DD] [--since ISO-TIME] [--alarm-p50 N]
                       [--alarm-max N] [--target-p50 N] [--json]

The context CEILING is a property of one thread, so it is keyed on the TRANSCRIPT, not the directory:
a context clear starts a new transcript in the same directory, and grouping by directory blended the
pre-clear tail into the live thread (governance#32 — it raised ROTATE for five seats right after
they had rotated). Only each seat's LATEST transcript of the day can raise ROTATE; earlier ones are
listed as rotated. The billed series still sums every transcript: that one is a per-day total.
Exit:   0 no seat over the alarm · 1 at least one over · 2 cannot run
"""
import argparse, collections, glob, json, os, re, sys

USAGE_KEYS = ("input_tokens", "output_tokens",
              "cache_creation_input_tokens", "cache_read_input_tokens")


def seat_prefixes(home=None):
    """Directory-name prefixes to strip, longest first: `<encoded home>-projects-`, `<encoded home>-`."""
    enc = re.sub(r"[^A-Za-z0-9]", "-", home if home is not None else os.path.expanduser("~"))
    return (enc + "-projects-", enc + "-")


def seat_name(dirname, prefixes):
    for p in prefixes:
        if dirname.startswith(p) and len(dirname) > len(p):
            return dirname[len(p):]
    return dirname


def walk(root, days=None, since=None):
    """Per-day billed/cached totals and per-(day, seat) context samples.

    BILLED = input + output + cache_creation. Cache READ is excluded on purpose: it is the cheap
    leg, and folding it in makes a well-cached day look like a runaway. CONTEXT per turn is
    cache_read + cache_creation — what the model actually saw — which is the number the rotation
    ceiling is about and is NOT the same as the billed number. Conflating them is how "we are
    getting worse" and "we are caching well" become indistinguishable.
    """
    totals = collections.defaultdict(lambda: collections.defaultdict(int))
    ctx = collections.defaultdict(list)          # (day, seat, transcript) -> [context per turn]
    last = {}                                    # (day, seat, transcript) -> latest timestamp
    stats = {"files": 0, "turns": 0, "unparseable": 0, "no_usage": 0}
    prefixes = seat_prefixes()

    for path in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
        seat = seat_name(os.path.basename(os.path.dirname(path)), prefixes)
        tid = os.path.basename(path)[:-len(".jsonl")]
        stats["files"] += 1
        try:
            fh = open(path, encoding="utf-8", errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:                                   # noqa: BLE001
                    # A transcript is appended to while this runs; the last line is routinely
                    # half-written. Count it so the number is visible rather than assumed zero.
                    stats["unparseable"] += 1
                    continue
                msg = d.get("message")
                usage = msg.get("usage") if isinstance(msg, dict) else None
                if not isinstance(usage, dict):
                    stats["no_usage"] += 1
                    continue
                ts = d.get("timestamp") or ""
                day = ts[:10]
                if not day:
                    continue
                if days and day < days:
                    continue
                if since and ts.rstrip("Z") < since:
                    continue
                inp, out, cw, cr = (int(usage.get(k) or 0) for k in USAGE_KEYS)
                totals[day]["billed"] += inp + out + cw
                totals[day]["cache_read"] += cr
                totals[day]["output"] += out
                ctx[(day, seat, tid)].append(cr + cw)
                last[(day, seat, tid)] = max(last.get((day, seat, tid), ""), ts)
                stats["turns"] += 1
    return totals, (ctx, last), stats


def pct(values, p):
    """p-th percentile, nearest-rank. statistics.quantiles needs n>=2 and we often have n==1."""
    if not values:
        return 0
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * len(s) + 0.5)) - 1))
    return s[k]


def report(totals, ctx, stats, alarm_p50, alarm_max, target_p50, latest_only=True):
    days = sorted(totals)
    rows = []
    for day in days:
        t = totals[day]
        rows.append({"day": day, "billed": t["billed"], "cache_read": t["cache_read"],
                     "output": t["output"]})

    # Per-seat context for the most recent day only: the ceiling is a rotation trigger, and a seat
    # that ran hot last week has already rotated. Averaging it across the window would hide today.
    target = days[-1] if days else None
    ctx, last = ctx
    # The live thread of a seat is its transcript with the latest turn that day; any earlier one was
    # cleared or rotated away, so it can describe the day but can never be a rotation candidate.
    latest = {}
    for (day, seat, tid), ts in last.items():
        if (day, seat) not in latest or ts > last[(day, seat, latest[(day, seat)])]:
            latest[(day, seat)] = tid
    count = collections.Counter((day, seat) for (day, seat, _t) in ctx)
    seats = []
    for (day, seat, tid), vals in ctx.items():
        if latest_only and day != target:
            continue
        seats.append({"seat": seat, "transcript": tid, "day": day, "turns": len(vals),
                      "p50": pct(vals, 50), "p90": pct(vals, 90), "max": max(vals),
                      "transcripts_that_day": count[(day, seat)],
                      "rotated": latest[(day, seat)] != tid})
    seats.sort(key=lambda r: (r["rotated"], -r["p50"]))
    live = [s for s in seats if not s["rotated"]]
    # A seat trips on EITHER limit: a healthy median hides a turn that nearly filled the window,
    # and it is the max that actually degrades a run.
    over = [s for s in live if s["p50"] > alarm_p50 or s["max"] > alarm_max]
    above_target = [s for s in live if s["p50"] > target_p50]
    return rows, seats, over, above_target, target


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--days", default=None,
                    help="only count days >= this ISO date (lexical compare)")
    # TWO TIERS, and the distinction is the whole design. ALARM = act now. TARGET = are we improving.
    # Collapsing them into one ceiling flags nearly every seat, which describes the norm rather than
    # calling for action — and a nightly list nobody can act on is a report nobody reads.
    # The target cannot double as an alarm because BOOT ALONE consumes a large fraction of it: a seat
    # would trip close to arrival, before doing any work a rotation could shed.
    # "Boot" also needs a definition before it is a measurement: RESIDENT boot (the first
    # usage-bearing turn) and TO-FIRST-ACTION boot (resident plus whatever a seat loads before it can
    # act) are different numbers, and the gap between them is the boot-diet target.
    ap.add_argument("--since", default=None,
                    help="only count turns at or after this ISO time, e.g. 2026-09-25T15:00 (the clear)")
    ap.add_argument("--alarm-p50", type=int, default=400_000,
                    help="p50 context/turn above which a seat should ROTATE")
    ap.add_argument("--alarm-max", type=int, default=600_000,
                    help="any single turn above this also triggers ROTATE")
    ap.add_argument("--target-p50", type=int, default=250_000,
                    help="p50 target to drive down (reported, never a rotate row)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args()
    if a.help:
        print(__doc__)
        return 0
    if not os.path.isdir(a.root):
        print(f"error: no transcript root at {a.root}", file=sys.stderr)
        return 2

    since = a.since.rstrip("Z") if a.since else None
    if since and not re.match(r"^\d{4}-\d\d-\d\d(T\d\d(:\d\d(:\d\d(\.\d+)?)?)?)?$", since):
        print(f"error: --since must be an ISO date or time (YYYY-MM-DD[THH[:MM[:SS]]]), got {a.since!r}",
              file=sys.stderr)
        return 2
    totals, ctx, stats = walk(a.root, a.days, since)
    if not totals:
        # An empty result is not a clean bill of health: it means the walk found nothing, which is
        # far more likely to be a wrong --root than a machine that used no tokens.
        print(f"error: no usage records under {a.root} — wrong --root, or a changed transcript "
              f"schema. Refusing to report 0 as a result.", file=sys.stderr)
        return 2

    rows, seats, over, above_target, target = report(
        totals, ctx, stats, a.alarm_p50, a.alarm_max, a.target_p50)

    if a.json:
        print(json.dumps({"days": rows, "seats": seats, "rotate": over,
                          "above_target": [x["seat"] for x in above_target],
                          "thresholds": {"alarm_p50": a.alarm_p50, "alarm_max": a.alarm_max,
                                         "target_p50": a.target_p50},
                          "scan": stats}, indent=2))
    else:
        print(f"scanned {stats['files']} transcript(s), {stats['turns']} turn(s) with usage"
              f"  ·  unparseable lines: {stats['unparseable']}")
        print()
        print(f"{'day':12} {'billed':>14} {'cache-read':>14} {'output':>10}")
        for r in rows[-14:]:
            print(f"{r['day']:12} {r['billed']:>14,} {r['cache_read']:>14,} {r['output']:>10,}")
        print()
        print(f"context per turn (cache_read + cache_creation), {target or 'n/a'}")
        print(f"  ROTATE alarm: p50 > {a.alarm_p50:,} or any turn > {a.alarm_max:,}"
              f"   ·   target: p50 < {a.target_p50:,}")
        print(f"{'seat':24} {'thread':9} {'turns':>6} {'p50':>12} {'p90':>12} {'max':>12}")
        for s in seats[:15]:
            if s["rotated"]:
                flag = "  (rotated — earlier thread, not a candidate)"
            elif s["p50"] > a.alarm_p50 or s["max"] > a.alarm_max:
                flag = "  ⚠️ ROTATE"
            elif s["p50"] > a.target_p50:
                flag = "  · above target"          # progress, NOT an action row
            else:
                flag = ""
            if s["transcripts_that_day"] > 1 and not s["rotated"]:
                flag += f"  ↻ {s['transcripts_that_day']} threads today"
            print(f"{s['seat']:24} {s['transcript'][:8]:9} {s['turns']:>6} {s['p50']:>12,} "
                  f"{s['p90']:>12,} {s['max']:>12,}{flag}")
        print()
        # Progress against the target: ALWAYS printed, never an action row. Being above target is
        # a normal state while the boot footprint is large; reporting it as a rotation would ask
        # every seat to fix something no rotation can fix.
        n_live = sum(1 for s in seats if not s["rotated"])
        print(f"target: {n_live - len(above_target)}/{n_live} live threads at or under the "
              f"{a.target_p50:,} p50 target (a trend to drive down, NOT an alarm).")
        if over:
            print(f"⚠️  ROTATE: {len(over)} seat(s) over the alarm — "
                  f"{', '.join(x['seat'] for x in over)}. Rotation is cheap; "
                  f"context pressure alone is reason enough.")
        else:
            print("No seat over the ROTATE alarm.")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())
