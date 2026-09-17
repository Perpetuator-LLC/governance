#!/usr/bin/env python3
"""settings-write-audit — attribute writes to an agent settings file.

Permission rules (deny/allow/ask) can vanish from a settings file and come back with nothing red
anywhere. By the time anyone looks, the file is content-clean AND git-clean — the ONLY surviving
witness is the mtime, and an mtime does not name its author. This records write EVENTS as they
happen, with evidence attached, to an append-only JSONL log that outlives the session observing it.

Two surfaces, deliberately, because conflating them produces confident wrong conclusions. When the
live settings path is a SYMLINK into a version-controlled config repo, two independent things can
change:

  * the TARGET — a write through the symlink; this is the one that strips rules, and it lands in a
    git working tree.
  * the LINK itself (lstat mtime) — the symlink being RECREATED, which is what an installer's
    `ln -sf` does and which does not modify the target at all.

An installer run that recreates the link, read off the link's mtime, looks exactly like "settings
rewritten" — same clock, different file, wrong conclusion. So each event says which surface moved.

Attribution without root: there is generally no supported way to name the writer of a PAST write
(kernel tracing needs elevated privileges). What IS available is a snapshot taken at the moment the
change is observed: who holds the file open (lsof) and which plausible writers are running. That is
evidence, not proof — the field is named `candidates`, never `writer`, so a future reader is not
misled into treating a correlation as an identification.

The reference the live file is compared against is the target as committed at HEAD of the git repo
that contains it. A target outside any repo makes that comparison UNDETERMINED, never "clean".

Usage
    bin/settings-write-audit.py                 # watch until interrupted
    bin/settings-write-audit.py --oneshot       # record current state, exit
    bin/settings-write-audit.py --status        # summarise the log, exit

Environment (all optional):
    SETTINGS_AUDIT_LINK        live settings path       (default ~/.claude/settings.json)
    SETTINGS_AUDIT_TARGET      file actually written    (default: where LINK resolves)
    SETTINGS_AUDIT_LOG         append-only JSONL log    (default ~/.claude/audit/settings-writes.jsonl)
    SETTINGS_AUDIT_INTERVAL    poll seconds             (default 2)
    SETTINGS_AUDIT_CANDIDATES  comma-separated process-name fragments worth naming
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
LINK = os.environ.get("SETTINGS_AUDIT_LINK", os.path.join(HOME, ".claude/settings.json"))
TARGET = os.environ.get("SETTINGS_AUDIT_TARGET") or os.path.realpath(LINK)
LOG = os.environ.get("SETTINGS_AUDIT_LOG", os.path.join(HOME, ".claude/audit/settings-writes.jsonl"))
INTERVAL = float(os.environ.get("SETTINGS_AUDIT_INTERVAL", "2"))

# Processes worth naming if they are running when a write is observed. Not a
# suspect list — a shortlist of things that plausibly write agent config.
CANDIDATE_PATTERNS = tuple(
    p.strip().lower()
    for p in os.environ.get("SETTINGS_AUDIT_CANDIDATES", "claude,codex,grok,node,install").split(",")
    if p.strip()
)


def _utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _local():
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def rule_id(rule):
    """Stable, greppable identity for a permission rule.

    Deliberately NOT the raw rule text. The rules are committed config rather
    than secrets, but one of them is a literal fork bomb, and splattering that
    string across a log read by shells and agents is a foot-gun for no gain.
    A truncated head plus a digest is enough to say 'this exact rule vanished'.
    """
    head = rule[:40].replace("\n", " ")
    return f"{head}#{hashlib.sha256(rule.encode()).hexdigest()[:8]}"


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def head_permissions():
    """permissions{} as committed at HEAD — the reference the live file drifts from.

    Returns (perms, error) — NEVER a bare {}. An unreadable reference and a reference with no rules
    are different facts, and collapsing them is the dangerous direction for this instrument: with an
    empty reference, `missing_vs_head` finds nothing missing and the audit reports a CLEAN file it
    never actually checked. A slow `git show` under load that times out, swallowed into `{}`,
    produces both a false negative and a false all-clear at once — so the instrument must be able
    to say it could not determine the reference.
    """
    target = os.path.abspath(TARGET)
    try:
        top = subprocess.run(
            ["git", "-C", os.path.dirname(target), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=30,
        )
    except Exception as exc:
        return {}, f"{type(exc).__name__}: {exc}"
    if top.returncode != 0 or not top.stdout.strip():
        return {}, f"{os.path.dirname(target)} is not inside a git repository"
    repo = top.stdout.strip()
    rel = os.path.relpath(os.path.realpath(target), os.path.realpath(repo))
    try:
        out = subprocess.run(
            ["git", "-C", repo, "show", f"HEAD:{rel}"],
            capture_output=True, text=True, timeout=30,
        )
        if out.returncode != 0:
            return {}, f"git show HEAD:{rel} exited {out.returncode}"
        return (json.loads(out.stdout) or {}).get("permissions", {}) or {}, None
    except Exception as exc:
        return {}, f"{type(exc).__name__}: {exc}"


def snapshot(path):
    """(mtime, sha256, permissions-summary) for a file, tolerant of it being absent."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    with open(path, "rb") as fh:
        raw = fh.read()
    digest = hashlib.sha256(raw).hexdigest()[:16]
    perms = {}
    try:
        perms = (json.loads(raw.decode("utf-8")) or {}).get("permissions", {}) or {}
    except Exception:
        perms = {"__unparseable__": True}
    counts = {k: len(v) for k, v in perms.items() if isinstance(v, list)}
    return {"mtime": st.st_mtime, "size": st.st_size, "sha256_16": digest,
            "counts": counts, "_perms": perms}


def link_mtime(path):
    try:
        return os.lstat(path).st_mtime
    except OSError:
        return None


def lsof_holders(path):
    """Who has the file open right now. Empty is the common case — a writer that
    already closed is gone, which is exactly why this is evidence, not proof."""
    try:
        out = subprocess.run(["lsof", "--", path], capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    rows = []
    for line in out.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3:
            rows.append({"command": parts[0], "pid": parts[1], "user": parts[2]})
    return rows


def candidate_processes():
    try:
        out = subprocess.run(["ps", "-Ao", "pid,lstart,comm"], capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    rows = []
    for line in out.stdout.splitlines()[1:]:
        low = line.lower()
        if any(p in low for p in CANDIDATE_PATTERNS):
            parts = line.split(None, 1)
            if len(parts) == 2:
                rows.append({"pid": parts[0], "detail": parts[1].strip()[:160]})
    return rows[:25]


def missing_vs_head(perms, head):
    """Which committed rules are ABSENT from the live file, per section."""
    out = {}
    for section in ("deny", "allow", "ask"):
        h = set(head.get(section, []) or [])
        l = set(perms.get(section, []) or [])
        gone = sorted(h - l)
        if gone:
            out[section] = [rule_id(r) for r in gone]
    return out


def emit(event, **fields):
    rec = {"ts_utc": _utc(), "ts_local": _local(), "event": event}
    rec.update(fields)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    print(json.dumps(rec, sort_keys=True), flush=True)
    return rec


def describe(snap, head, head_error=None):
    if snap is None:
        return {"present": False}
    body = {"present": True, "mtime": snap["mtime"], "size": snap["size"],
            "sha256_16": snap["sha256_16"], "counts": snap["counts"]}
    # UNDETERMINED must be distinguishable from "nothing missing". Without this the
    # audit's most reassuring output is exactly what an unreadable reference produces.
    if head_error is not None:
        body["missing_vs_head"] = "UNDETERMINED"
        body["head_reference_error"] = head_error
        return body
    gone = missing_vs_head(snap["_perms"], head)
    if gone:
        body["missing_vs_head"] = gone
    return body


def cmd_status():
    if not os.path.exists(LOG):
        print(f"no audit log yet at {LOG}")
        return 0
    n = strips = 0
    with open(LOG, encoding="utf-8") as fh:
        for line in fh:
            n += 1
            try:
                if json.loads(line).get("after", {}).get("missing_vs_head"):
                    strips += 1
            except Exception:
                pass
    print(f"{LOG}\n  {n} events recorded, {strips} of them with rules MISSING vs HEAD")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Attribute writes to an agent settings file")
    ap.add_argument("--oneshot", action="store_true", help="record current state and exit")
    ap.add_argument("--status", action="store_true", help="summarise the log and exit")
    args = ap.parse_args()

    if args.status:
        return cmd_status()

    head, head_error = head_permissions()
    tgt = snapshot(TARGET)
    lnk = link_mtime(LINK)

    emit("baseline", surface="both", target=describe(tgt, head, head_error), link_mtime=lnk,
         watching={"target": TARGET, "link": LINK, "interval_s": INTERVAL})

    if args.oneshot:
        return 0

    while True:
        time.sleep(INTERVAL)
        new_tgt = snapshot(TARGET)
        new_lnk = link_mtime(LINK)

        # The symlink being recreated is its own event, and must never be
        # reported as a settings rewrite — an installer run logged as a
        # content strip is exactly the misreading this split prevents.
        if new_lnk != lnk:
            emit("symlink_recreated", surface="link", link_mtime_before=lnk,
                 link_mtime_after=new_lnk,
                 note="the LINK moved, not the file it points at; an installer's `ln -sf` does this",
                 candidates=candidate_processes())
            lnk = new_lnk

        if new_tgt != tgt:
            changed = (tgt or {}).get("sha256_16") != (new_tgt or {}).get("sha256_16")
            emit("target_write" if changed else "target_touched", surface="target",
                 before=describe(tgt, head, head_error), after=describe(new_tgt, head, head_error),
                 content_changed=changed,
                 holders=lsof_holders(TARGET), candidates=candidate_processes())
            tgt = new_tgt


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
