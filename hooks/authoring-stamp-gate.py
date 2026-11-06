#!/usr/bin/env python3
"""authoring-stamp-gate.py — PreToolUse[declared comment/issue-posting tools]: refuse a body whose
AUTHORING stamp is hand-estimated instead of read from the clock.

  <hook JSON on stdin> | authoring-stamp-gate.py

WHY THIS EXISTS: a "written at" stamp on a durable record comes from the clock, never from memory of
the conversation. An agent that writes `~HH:MMZ` from recollection drifts 15-50 minutes over a long
session, and because a recency rule (latest-wins) compares event dates, a record stamped wrong silently
reorders history: a reader acts on the "newer" one, which is really the older one. Prose asking for
`date -u` has not held across repeated measurement.

SCOPE: only the AUTHORING stamp — a time on the body's FIRST LINE (a header such as `<seat>, HH:MMZ:`
or `(HH:MMZ)`), or that line labelled as now (`(now)`, `(at the time of writing)`) instead of a numeric
time. NOT a past event's time cited anywhere in the body ("the run failed ~15:38Z") — that is
legitimate history, often approximate by nature, and stays allowed regardless of where it sits.

THREE OUTCOMES for whatever the first line holds:
  - no recognizable stamp at all                                  -> allowed, nothing to check
  - an APPROXIMATE or unread form (`~HH:MMZ`, `HH:0xZ`, `HH:MMish`, `(now)`, `(at the time of
    writing)`) -> refused outright, regardless of how close it actually is: none of these were read
    off a clock, which is the one thing this gate exists to require
  - an EXACT `HH:MMZ` stamp -> compared to the hook's own UTC clock; allowed within +/-3 minutes,
    refused outside it

WHICH TOOLS ARE GATED, AND NOT HERE: same convention as hooks/id-provenance-gate.py, which hooks the
same tools — this file names no vendor tool and no installation's fully-qualified tool path, because
the server half of an MCP tool's name is whatever that installation calls it. The gated set and which
field each one carries its outgoing body in are declared externally (the same $GOVERNANCE_GATED_TOOLS
/ ~/.governance/gated-tools.json lookup, the same exact-name-or-"__"+suffix match).

A MISSING OR UNREADABLE LIST MEANS "NOT CHECKING", NEVER A SILENT ALLOW: every call still exits 0, but
it says so on stderr first, exactly as id-provenance-gate.py reports it.

THE CLOCK: real UTC time, HH:MM granularity — this gate only ever compares time-of-day, never a date;
a stamp exactly 24 hours off reads as 0 minutes away, which is outside this gate's stated scope
(same-session authoring, not cross-day). Overridable via GOVERNANCE_STAMP_NOW ("HH:MM") for
deterministic tests; never set in a real install.

FAILS OPEN on anything it cannot parse (malformed JSON, no gated-tool list), loudly, the same way
id-provenance-gate.py does: a mis-wired gate must not block every comment/issue write in the fleet,
but it says "not checking" rather than looking like a clean pass.

REFUSES on stderr, exit 2 — the same channel and contract every hook in this directory uses. Exit 0
allows.
"""
import json
import os
import re
import sys
from datetime import datetime, timezone

GATED_TOOLS_ENV = "GOVERNANCE_GATED_TOOLS"
DEFAULT_GATED_TOOLS = os.path.join(os.path.expanduser("~"), ".governance", "gated-tools.json")
STAMP_NOW_ENV = "GOVERNANCE_STAMP_NOW"  # "HH:MM", test-injectable clock override

TOLERANCE_MINUTES = 3
REFUSAL_FIX = "stamp from `date -u +%H:%MZ` in the same step"

# An approximate or unread form on the first line — never a clock reading, refused regardless of how
# close the guess actually lands. "now"/"at the time of writing" only count in STAMP POSITION
# (parenthesized, or after a comma before a colon, mirroring where a real time would sit) so that
# ordinary prose containing the word "now" is never caught by accident.
APPROX_RX = re.compile(
    r"~\s*\d{1,2}:\d{2}\s*Z"            # ~HH:MMZ
    r"|\d{1,2}:\d{2}\s*ish\b"           # HH:MMish
    r"|\d{1,2}:\s*\d?[xX]\s*Z"          # HH:0xZ / HH:xZ
    r"|[,(]\s*now\s*[:)]"               # (now) / , now:
    r"|\(\s*at the time of writing\s*\)",
    re.I,
)
# An exact HH:MMZ, not already claimed by the approximate forms above (checked first in stamp_violation,
# so this never needs to exclude them itself).
EXACT_RX = re.compile(r"\b(\d{1,2}):(\d{2})\s*Z\b")


def load_gated_tools(path):
    """→ (dict name/suffix → (field, ...), note). The dict is None — never {} — when the list could
    not be used: None means 'not checking', {} would mean 'checked, nothing is gated'."""
    if not path or not os.path.isfile(path):
        return None, f"no gated-tool list at {path or '(unset)'}"
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as e:
        return None, f"gated-tool list at {path} is unreadable: {e}"
    if not isinstance(raw, dict):
        return None, f"gated-tool list at {path} is not a JSON object"
    out = {}
    for name, fields in raw.items():
        if isinstance(name, str) and isinstance(fields, list) and fields and all(isinstance(f, str) for f in fields):
            out[name] = tuple(fields)
    return out, f"{len(out)} tool(s) declared"


def gated_fields(tool_name, gated):
    """The body-field names for tool_name, or None when it is not gated. An EXACT key match covers a
    harness-native tool name (spelled the same everywhere); a tool_name ENDING in "__" + a declared
    key covers an MCP tool whose fully-qualified name carries one more leading segment — the
    installation's own label for the server — that this gate must never depend on."""
    if tool_name in gated:
        return gated[tool_name]
    for name, fields in gated.items():
        if tool_name.endswith("__" + name):
            return fields
    return None


def body_text(fields, tool_input):
    parts = []
    for f in fields:
        v = tool_input.get(f)
        if isinstance(v, str) and v:
            parts.append(v)
    return "\n".join(parts)


def current_hhmm():
    override = os.environ.get(STAMP_NOW_ENV)
    if override:
        return override
    return datetime.now(timezone.utc).strftime("%H:%M")


def _minutes(hhmm):
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def _circular_diff(a, b):
    """Minutes between two HH:MM wall-clock times, taking the SHORTER way around a 24h clock, so
    23:59 and 00:01 are 2 minutes apart, not 1438."""
    d = abs(_minutes(a) - _minutes(b)) % 1440
    return min(d, 1440 - d)


def first_line(text):
    return text.splitlines()[0] if text else ""


def stamp_violation(text):
    """None if the first line's stamp (if any) is fine; else a refusal reason."""
    line = first_line(text)
    if APPROX_RX.search(line):
        return f"an approximate or unread first-line stamp — {REFUSAL_FIX}"
    m = EXACT_RX.search(line)
    if not m:
        return None  # no stamp at all: nothing to check
    stamp = f"{int(m.group(1)):02d}:{m.group(2)}"
    now = current_hhmm()
    diff = _circular_diff(stamp, now)
    if diff > TOLERANCE_MINUTES:
        return f"a first-line stamp ({stamp}Z) {diff} min from the clock ({now}Z) — {REFUSAL_FIX}"
    return None


def main():
    raw = sys.stdin.read()
    try:
        hook_input = json.loads(raw) if raw.strip() else {}
    except ValueError:
        print("authoring-stamp-gate: not checking — unparseable hook payload", file=sys.stderr)
        return 0

    gated_path = os.environ.get(GATED_TOOLS_ENV) or DEFAULT_GATED_TOOLS
    gated, note = load_gated_tools(gated_path)
    if gated is None:
        print(f"authoring-stamp-gate: not checking — {note}", file=sys.stderr)
        return 0

    tool_name = hook_input.get("tool_name", "")
    fields = gated_fields(tool_name, gated)
    if fields is None:
        return 0

    tool_input = hook_input.get("tool_input") or {}
    text = body_text(fields, tool_input)
    if not text:
        return 0

    reason = stamp_violation(text)
    if reason is None:
        return 0
    print(f"BLOCKED: first line has {reason}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
