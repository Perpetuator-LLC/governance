#!/usr/bin/env python3
"""id-provenance-gate.py — PreToolUse[message/comment-posting tools]: refuse a body that cites an id
no earlier tool result or user message contains.

  <hook JSON on stdin> | id-provenance-gate.py

WHY THIS EXISTS (governance#203): a parallel tool batch cannot see its own sibling results. An agent
that posts a comment and, in the SAME batch, sends a message citing that comment's id is guessing the
id — it has not been returned yet. The guess is wrong (another comment's id, or nothing at all), and
prose rules asking agents to sequence these calls have not held across six measured repeats.

SHAPE: a floor gate, not advice — refuse first, explain on the channel the harness returns to the
model (stderr, exit 2), the same contract every hook in this directory uses. Exit 0 allows.

WHAT IT CHECKS: provenance, not correctness. An id copied from an earlier tool result that was itself
wrong still passes — this gate only proves the id was SEEN before, not that what it names is right.

READS: the hook's own JSON on stdin (`tool_name`, `tool_input`, `transcript_path`) — Claude Code's
PreToolUse hook contract. The transcript file, read fresh each call, holds exactly the turns and tool
results that happened BEFORE this pending call: a sibling call in the same parallel batch has not
written its result there yet, which is exactly the gap this gate exists to close.

FAILS OPEN on anything it cannot parse (no transcript path, unreadable file, malformed JSON): a
mis-wired gate should not block every message in the fleet. It fails open silently for the same
reason `bash-safety-gate.sh` keeps the python3 fallback optional — a missing dependency must not
become an outage of every tool this gate sits in front of. (Scope note, not a contradiction of that
file's own OPPOSITE choice there: that gate protects against a destructive command, where failing
closed is cheap; this one sits in front of ordinary comment/message tools used constantly, where
failing closed on a parse error would halt the fleet over this gate's own bug, not the thing it
checks for.)

ID SHAPES extracted from the OUTGOING body (never from the transcript — the transcript is only ever
searched, not parsed for ids):
  - a forge comment anchor:  #issuecomment-<digits>
  - a short comment form:    c<digits>        (the house convention: "c76292")
  - a state-card anchor:     #i=<token>       (a uuid, or a bare placeholder)
  - a commit sha:            a bare 7-40 hex-digit run, word-bounded

PLACEHOLDERS always refuse, independent of the transcript: `#i=PENDING` and any angle-bracket
stand-in (`<id>`, `<uuid>`, ...) are never a real id, so "it doesn't appear yet" is not the finding —
it should never have been typed as a citation at all.

FENCED CODE the body itself quotes (```...```) is stripped before extraction: a body illustrating or
quoting example text is not making a live citation, and flagging it would teach the rule's own
violators to stop reading the refusal.
"""
import json
import os
import re
import sys

# Tools this gate sits in front of. Named explicitly rather than "every tool": a gate that fires on
# every tool call is a gate nobody can argue with being wrong about scope, which is how it gets turned
# off for everything rather than fixed for its one false positive.
GATED_TOOLS = {
    "mcp__perpetuator__gitea_comment_on_issue",
    "mcp__perpetuator__gitea_review_pull_request",
    "mcp__perpetuator__gitea_edit_comment",
    "mcp__perpetuator__gitea_create_issue",
    "mcp__perpetuator__gitea_create_pull_request",
    "SendMessage",
    "mcp__perpetuator__state_item_upsert",
    "mcp__perpetuator__state_item_patch",
    "mcp__perpetuator__state_seat_patch",
}

# The text field each gated tool carries its outgoing body in. A tool not listed here is not gated —
# see GATED_TOOLS above for why that is deliberate, not an oversight.
BODY_FIELDS = {
    "mcp__perpetuator__gitea_comment_on_issue": ("comment",),
    "mcp__perpetuator__gitea_review_pull_request": ("body",),
    "mcp__perpetuator__gitea_edit_comment": ("body",),
    "mcp__perpetuator__gitea_create_issue": ("body",),
    "mcp__perpetuator__gitea_create_pull_request": ("body",),
    "SendMessage": ("message",),
    "mcp__perpetuator__state_item_upsert": ("notes", "current_step"),
    "mcp__perpetuator__state_item_patch": ("notes", "current_step"),
    "mcp__perpetuator__state_seat_patch": ("current_step",),
}

FENCE_RX = re.compile(r"```.*?```", re.DOTALL)

ID_PATTERNS = [
    ("issuecomment", re.compile(r"#issuecomment-(\d+)")),
    ("short-comment", re.compile(r"(?<![A-Za-z0-9_])c(\d{3,7})(?![A-Za-z0-9_])")),
    ("card-anchor", re.compile(r"#i=([0-9a-fA-F-]{8,36})")),
    ("commit-sha", re.compile(r"(?<![A-Za-z0-9_])([0-9a-f]{7,40})(?![A-Za-z0-9_])")),
]
PLACEHOLDER_PATTERNS = [
    re.compile(r"#i=PENDING\b"),
    re.compile(r"<[A-Za-z][A-Za-z0-9_-]*>"),
]


def strip_fences(text):
    return FENCE_RX.sub("", text)


def extract_ids(text):
    """Return [(kind, raw_match_string), ...] for every id-shaped reference in text."""
    found = []
    for kind, rx in ID_PATTERNS:
        for m in rx.finditer(text):
            found.append((kind, m.group(0)))
    return found


def extract_placeholders(text):
    return [m.group(0) for rx in PLACEHOLDER_PATTERNS for m in rx.finditer(text)]


def id_variants(kind, raw_id):
    """Other textual forms the SAME id is known to appear under in a transcript. The house
    short-comment convention (c76292) and the forge's own anchor (#issuecomment-76292) name the
    same comment; a literal string match on raw_id alone misses that every time one form was
    minted and the other is what got cited, which is the common case (a tool result returns the
    forge's full anchor, a human or an earlier turn writes the short form back)."""
    digits = re.search(r"\d+", raw_id)
    digits = digits.group(0) if digits else ""
    if kind == "short-comment":
        return {raw_id, f"issuecomment-{digits}", f"#issuecomment-{digits}"}
    if kind == "issuecomment":
        return {raw_id, f"c{digits}"}
    return {raw_id}


def body_text(tool_name, tool_input):
    fields = BODY_FIELDS.get(tool_name, ())
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

    tool_name = hook_input.get("tool_name", "")
    if tool_name not in GATED_TOOLS:
        return 0

    tool_input = hook_input.get("tool_input") or {}
    text = body_text(tool_name, tool_input)
    if not text:
        return 0

    placeholders = extract_placeholders(text)
    if placeholders:
        print(
            f"BLOCKED: cites a placeholder id ({placeholders[0]!r}) — "
            "resolve the real id after the call that mints it has answered, never a stand-in.",
            file=sys.stderr,
        )
        return 2

    scan_text = strip_fences(text)
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
