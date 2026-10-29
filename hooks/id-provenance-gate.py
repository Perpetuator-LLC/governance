#!/usr/bin/env python3
"""id-provenance-gate.py — PreToolUse[declared message/comment-posting tools]: refuse a body that
cites an id no earlier tool result or user message contains.

  <hook JSON on stdin> | id-provenance-gate.py

WHY THIS EXISTS: a parallel tool batch cannot see its own sibling results. An agent that posts a
comment and, in the SAME batch, sends a message citing that comment's id is guessing the id — it has
not been returned yet. The guess is wrong (another comment's id, or nothing at all), and prose rules
asking agents to sequence these calls have not held across repeated measurement.

SHAPE: a floor gate, not advice — refuse first, explain on the channel the harness returns to the
model (stderr, exit 2), the same contract every hook in this directory uses. Exit 0 allows.

WHAT IT CHECKS: provenance, not correctness. An id copied from an earlier tool result that was itself
wrong still passes — this gate only proves the id was SEEN before, not that what it names is right.

WHICH TOOLS ARE GATED, AND NOT HERE: this file names no vendor tool and no installation's
fully-qualified tool path — those are the installation's own labels, not a rule this repo can state
once for every fleet (the server half of an MCP tool's name is whatever that installation calls it,
and a literal name baked into core is also exactly the kind of disclosure a shared repo must not
carry). The gated set and which field each one carries its outgoing body in are declared externally —
see LOADING THE GATED-TOOL LIST below — and a tool is gated either by an EXACT name match (a
harness-native tool, declared once and spelled the same everywhere a harness runs) or by its name
ENDING in "__" + a declared suffix (an MCP tool: the fully-qualified name carries one more "__"
segment naming the server instance, which this gate must not depend on, or it silently stops gating
the moment that instance is renamed, reinstalled, or run as a different one).

LOADING THE GATED-TOOL LIST: a JSON object, suffix/name → list of body field names, at
$GOVERNANCE_GATED_TOOLS, or ~/.governance/gated-tools.json when that is unset — the same
env-var-then-dotfile convention bin/redaction-check uses for its own private pattern list, and for
the same reason: a value this repo ships is a rule for every fleet, so the list of WHICH tools and
fields actually apply here can never be one of this repo's own files.

A MISSING OR UNREADABLE LIST MEANS "NOT CHECKING", NEVER A SILENT ALLOW: every call still exits 0 (a
mis-wired gate must not block every message in the fleet), but it says so on stderr first, the same
way redaction-check's own private-name leg reports NOT CHECKED rather than reporting clean.

READS: the hook's own JSON on stdin (`tool_name`, `tool_input`, `transcript_path`) — Claude Code's
PreToolUse hook contract. The transcript file, read fresh each call, holds exactly the turns and tool
results that happened BEFORE this pending call: a sibling call in the same parallel batch has not
written its result there yet, which is exactly the gap this gate exists to close.

FAILS OPEN on anything it cannot parse (no transcript path, unreadable file, malformed JSON, no
gated-tool list): a mis-wired gate should not block every message in the fleet. It fails open silently
for the same reason `bash-safety-gate.sh` keeps the python3 fallback optional — a missing dependency
must not become an outage of every tool this gate sits in front of. (Scope note, not a contradiction of
that file's own OPPOSITE choice there: that gate protects against a destructive command, where failing
closed is cheap; this one sits in front of ordinary comment/message tools used constantly, where
failing closed on a parse error would halt the fleet over this gate's own bug, not the thing it checks
for.)

ID SHAPES extracted from the OUTGOING body (never from the transcript — the transcript is only ever
searched, not parsed for ids):
  - a forge comment anchor:  #issuecomment-<digits>
  - a short comment form:    c<digits>        (a house convention: "c76292")
  - a state-card anchor:     #i=<token>       (a uuid, or a bare placeholder)
  - a commit sha:            a bare 7-40 hex-digit run, word-bounded

PLACEHOLDERS always refuse, independent of the transcript: `#i=PENDING` and an angle-bracket stand-in
whose name IS an id word (`<id>`, `<uuid>`, `<sha>`, `<comment-id>`, ...) are never a real id, so "it
doesn't appear yet" is not the finding — it should never have been typed as a citation at all. An
angle-bracket tag that is not an id word (`<sub>`, `<details>`, `<summary>`, ...) is ordinary Markdown
HTML, such as an attribution footer, and is never a placeholder.

FENCED CODE the body itself quotes (```...```) is stripped before extraction: a body illustrating or
quoting example text is not making a live citation, and flagging it would teach the rule's own
violators to stop reading the refusal.
"""
import json
import os
import re
import sys

GATED_TOOLS_ENV = "GOVERNANCE_GATED_TOOLS"
DEFAULT_GATED_TOOLS = os.path.join(os.path.expanduser("~"), ".governance", "gated-tools.json")

FENCE_RX = re.compile(r"```.*?```", re.DOTALL)

ID_PATTERNS = [
    ("issuecomment", re.compile(r"#issuecomment-(\d+)")),
    ("short-comment", re.compile(r"(?<![A-Za-z0-9_])c(\d{3,7})(?![A-Za-z0-9_])")),
    ("card-anchor", re.compile(r"#i=([0-9a-fA-F-]{8,36})")),
    ("commit-sha", re.compile(r"(?<![A-Za-z0-9_])([0-9a-f]{7,40})(?![A-Za-z0-9_])")),
]
PLACEHOLDER_LITERAL_RX = re.compile(r"#i=PENDING\b")
PLACEHOLDER_TAG_RX = re.compile(r"<([A-Za-z][A-Za-z0-9_-]*)>")
# A bare word that NAMES an id, not an HTML/Markdown tag (<sub>, <details>, <summary>, ... are real
# markup the fleet ships routinely, e.g. an attribution footer, and are never a citation stand-in).
PLACEHOLDER_WORDS = {"id", "uuid", "sha", "hash", "token", "n", "num", "number", "pending"}


def _is_placeholder_word(name):
    key = name.lower().replace("-", "").replace("_", "")
    return key in PLACEHOLDER_WORDS or key.endswith(("id", "sha", "uuid"))


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


def strip_fences(text):
    return FENCE_RX.sub("", text)


def extract_ids(text):
    """Return [(kind, raw_match_string), ...] for every id-shaped reference in text.

    A span already claimed by an EARLIER pattern in ID_PATTERNS is never claimed again by a later
    one: "c120571" is both a short-comment (c + 6 digits) and a 7-char run of hex digits (c is a
    valid hex letter), and the two kinds check different things in the transcript — the short form's
    own id vs. a literal sha string that was never minted. Without this, a real, present short-comment
    citation is refused as an absent commit-sha. Patterns are listed most-specific first for exactly
    this reason."""
    claimed = []  # [(start, end), ...], in match order
    found = []
    for kind, rx in ID_PATTERNS:
        for m in rx.finditer(text):
            start, end = m.span()
            if any(start < c_end and end > c_start for c_start, c_end in claimed):
                continue
            raw = m.group(0)
            if kind == "commit-sha" and not re.search(r"[a-f]", raw):
                continue  # an all-digit run (a date, a count) is not a sha: a sha has a hex LETTER
            found.append((kind, raw))
            claimed.append((start, end))
    return found


def extract_placeholders(text):
    found = [m.group(0) for m in PLACEHOLDER_LITERAL_RX.finditer(text)]
    found += [m.group(0) for m in PLACEHOLDER_TAG_RX.finditer(text) if _is_placeholder_word(m.group(1))]
    return found


def id_variants(kind, raw_id):
    """Other textual forms the SAME id is known to appear under in a transcript. A house short-comment
    convention (c76292) and a forge's own anchor (#issuecomment-76292) can name the same comment; a
    literal string match on raw_id alone misses that every time one form was minted and the other is
    what got cited, which is the common case (a tool result returns the forge's full anchor, a human
    or an earlier turn writes the short form back)."""
    digits = re.search(r"\d+", raw_id)
    digits = digits.group(0) if digits else ""
    if kind == "short-comment":
        return {raw_id, f"issuecomment-{digits}", f"#issuecomment-{digits}"}
    if kind == "issuecomment":
        return {raw_id, f"c{digits}"}
    return {raw_id}


def body_text(fields, tool_input):
    parts = []
    for f in fields:
        v = tool_input.get(f)
        if isinstance(v, str) and v:
            parts.append(v)
    return "\n".join(parts)


def read_transcript(path):
    """Concatenate every string value from every JSON line in the transcript. Best-effort: a line
    that doesn't parse is skipped, never fatal — the transcript is a log, not a contract."""
    chunks = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                chunks.append(json.dumps(obj))  # keep it simple: search the raw re-serialized line
    except OSError:
        return None
    return "\n".join(chunks)


def main():
    raw = sys.stdin.read()
    try:
        hook_input = json.loads(raw) if raw.strip() else {}
    except ValueError:
        return 0  # fails open: an unparseable hook payload is this gate's bug, not a refusal

    gated_path = os.environ.get(GATED_TOOLS_ENV) or DEFAULT_GATED_TOOLS
    gated, note = load_gated_tools(gated_path)
    if gated is None:
        print(f"id-provenance-gate: not checking — {note}", file=sys.stderr)
        return 0

    tool_name = hook_input.get("tool_name", "")
    fields = gated_fields(tool_name, gated)
    if fields is None:
        return 0

    tool_input = hook_input.get("tool_input") or {}
    text = body_text(fields, tool_input)
    if not text:
        return 0

    scan_text = strip_fences(text)

    placeholders = extract_placeholders(scan_text)
    if placeholders:
        print(
            f"BLOCKED: cites a placeholder id ({placeholders[0]!r}) — "
            "resolve the real id after the call that mints it has answered, never a stand-in.",
            file=sys.stderr,
        )
        return 2

    ids = extract_ids(scan_text)
    if not ids:
        return 0

    transcript_path = hook_input.get("transcript_path", "")
    transcript = read_transcript(transcript_path) if transcript_path else None
    if transcript is None:
        return 0  # fails open: no transcript to check against is this gate's limitation, not a finding

    user_prompt = hook_input.get("prompt", "")  # the current turn's own user message, if the harness provides it

    for kind, raw_id in ids:
        variants = id_variants(kind, raw_id)
        if any(v in transcript for v in variants) or (user_prompt and any(v in user_prompt for v in variants)):
            continue
        print(
            f"BLOCKED: cites {raw_id!r} ({kind}), which no earlier tool result or user message in "
            "this transcript contains — cite it after the call that mints it has answered.",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
