#!/usr/bin/env python3
"""authoring-stamp-gate.py — PreToolUse[declared comment/issue-posting tools]: refuse a body whose
AUTHORING stamp is hand-estimated instead of read from the clock.

  <hook JSON on stdin> | authoring-stamp-gate.py

WHY THIS EXISTS: a "written at" stamp on a durable record comes from the clock, never from memory of
the conversation. An agent that writes `~HH:MMZ` from recollection drifts 15-50 minutes over a long
session, and because a recency rule (latest-wins) compares event dates, a record stamped wrong silently
reorders history: a reader acts on the "newer" one, which is really the older one. Prose asking for
`date -u` has not held across repeated measurement.

SCOPE: only the AUTHORING stamp — a time in the OPENING LABEL POSITION of the body's first non-blank
line: right after the label's own trailing comma or open-paren, as in `<seat>, HH:MMZ:` or
`<seat> (HH:MMZ):`, or that same position labelled as now (`(now)`, `(at the time of writing)`)
instead of a numeric time. A time appearing anywhere ELSE — after the label's closing colon/paren, on
a later line, or on a first line that has no `<label>,`/`<label>(` opening at all (e.g. `coa verdict:
PASS ... (01:00-01:35Z)`, where the colon after "coa verdict" is not a stamp delimiter) — is a cited
event, never an authoring stamp, and is never examined: it stays allowed regardless of how it reads.

THREE OUTCOMES for whatever sits in that label position:
  - no label-plus-delimiter opening at all, or a label followed by something that is not a
    stamp-shaped token                                            -> allowed, nothing to check
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

# The opening label itself: a short "<seat>[ (host)]" run at the very start of the line, ending in
# the comma or open-paren that introduces the stamp — `<seat>, HH:MMZ:` or `<seat> (HH:MMZ):`. The
# middle group is deliberately narrow ([\w .-], i.e. no ":" or ";") and lazy, so a line whose label is
# instead followed by a colon ("coa verdict: PASS ... (01:00-01:35Z)") never reaches a later comma or
# paren at all: there is no label-delimiter opening on that line, so nothing is in stamp position.
LABEL_RX = re.compile(r"^\W*[\w .-]{1,40}?[,(]\s*")

# Checked against the text RIGHT AFTER the label delimiter (never searched for elsewhere on the line)
# so a stamp-shaped token must be the very next thing after "<label>," or "<label>(" to count at all.
APPROX_HEAD_RX = re.compile(
    r"^~\s*\d{1,2}:\d{2}\s*Z"           # ~HH:MMZ
    r"|^\d{1,2}:\d{2}\s*ish\b"          # HH:MMish
    r"|^\d{1,2}:\s*\d?[xX]\s*Z"         # HH:0xZ / HH:xZ
    r"|^now\s*[:)]"                     # now) / now:
    r"|^at the time of writing\s*\)",
    re.I,
)
# An exact HH:MMZ, also anchored to right after the label delimiter.
EXACT_HEAD_RX = re.compile(r"^(\d{1,2}):(\d{2})\s*Z\b")


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
        try:
            h, m = override.split(":")
            h, m = int(h), int(m)
            if 0 <= h <= 23 and 0 <= m <= 59:
                return f"{h:02d}:{m:02d}"
        except (ValueError, AttributeError):
            pass  # malformed override: fall through to the real clock
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
    """The first NON-BLANK line — a leading blank line is not a dodge around the check."""
    for line in text.splitlines():
        if line.strip():
            return line
    return ""


def stamp_violation(text):
    """None if the opening label's stamp position (if any) is fine; else a refusal reason. Only the
    text immediately after the label's own trailing comma/open-paren is ever examined — a time
    anywhere else on the line (or the line's absence of a label-delimiter opening at all) is out of
    scope and is never inspected, let alone refused."""
    line = first_line(text)
    m = LABEL_RX.match(line)
    if not m:
        return None  # no "<label>," / "<label>(" opening at all: nothing is in stamp position
    rest = line[m.end():]
    if APPROX_HEAD_RX.match(rest):
        return f"an approximate or unread first-line stamp — {REFUSAL_FIX}"
    m2 = EXACT_HEAD_RX.match(rest)
    if not m2:
        return None  # the label is followed by something else: not a stamp attempt
    stamp = f"{int(m2.group(1)):02d}:{m2.group(2)}"
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
    if not isinstance(hook_input, dict):
        print("authoring-stamp-gate: not checking — hook payload is not a JSON object", file=sys.stderr)
        return 0

    gated_path = os.environ.get(GATED_TOOLS_ENV) or DEFAULT_GATED_TOOLS
    gated, note = load_gated_tools(gated_path)
    if gated is None:
        print(f"authoring-stamp-gate: not checking — {note}", file=sys.stderr)
        return 0

    tool_name = hook_input.get("tool_name", "")
    if not isinstance(tool_name, str):
        return 0  # not a recognizable tool name: nothing declared could match it
    fields = gated_fields(tool_name, gated)
    if fields is None:
        return 0

    tool_input = hook_input.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0  # no body fields to read
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
