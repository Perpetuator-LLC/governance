#!/usr/bin/env python3
"""handoff-layout-gate.py — Stop hook: refuse a final message that hands the human a shell block without the layout.

The hand-off layout is canon (domains/operations.md -> Command hand-off format). It kept not being applied, so it is
enforced here as floor, not text. The rules, each checked only when the final message contains a
fenced SHELL block (```bash / sh / zsh / shell / console):

  R1  every shell block is preceded (within the 4 non-blank lines above it) by a `► <user>@<host>` line,
      OR a header table (3-cell or 2-cell form, below) whose user/host identity is present;
  R2  a block containing `read -s`, `sudo`, `login`, `ssh ` or `--ask-` needs a `🔑 PROMPTS` line in the message,
      OR the header table's 🔑 cell is non-empty and not the literal "none";
  R3  the message has a `## 👤 You` header and it is the LAST `## ` header;
  R4  every shell block has `📝 LOGGED` or `🚫 NOT LOGGED` within the 4 non-blank lines above it,
      OR the header table's 📝 cell is non-empty (its text may be "no": the cell only has to say whether
      it was logged, not that it was).

The header table is two markdown rows directly above the fence, in either of two forms:
    | 🖥️ <host> | 👤 <user> | 📝 <logged, or "no"> |          | 👤 <user>@<machine> | 📝 <logged, or "no"> |
    | --- | --- | --- |                              or       | --- | --- |
    | 🔑 <prompts, or "none"> | | |                           | 🔑 <prompts, or "none"> | |
3-cell form: host and user are separate cells. 2-cell form: one cell merges them as `user@machine`,
parsed the same way as the `►` line's own `<user>@<host>`. All three forms are accepted; Nik asked for
the 3-cell table on 2026-10-25 and the 2-cell table the same day, each replacing the one before it in
his own use, but none is retired here — the gate checks whichever one precedes a given block.

Scope: the final message to the human (the last assistant text in the transcript). Peer DMs and forge comments are
tool calls, never final text, so they are exempt by construction. A block relayed for the human is final text: checked.

Protocol (Claude Code Stop hook): stdin JSON with `transcript_path` and `stop_hook_active`. To refuse, print
{"decision": "block", "reason": ...} and exit 0; the model sees the reason and rewrites. When the stop is already a
retry (`stop_hook_active` true) the hook allows it, so a model that cannot comply never loops forever; the refusal is
still recorded through deny-event.py.

`--check FILE` checks a plain message file instead (tests, and other harnesses' final-message hooks): prints the
violations, exit 1 when any.
"""
import json
import os
import re
import subprocess
import sys

SHELL_FENCE = re.compile(r"^```(bash|sh|zsh|shell|console)\s*$", re.I)
FENCE_END = re.compile(r"^```\s*$")
HOST_LINE = re.compile(r"►\s*\S+@\S+")
PROMPT_WORDS = re.compile(r"read\s+-s|\bsudo\b|\blogin\b|\bssh\s|--ask-")
TABLE_ROW1 = re.compile(r"^\|\s*🖥️\s*([^|]*?)\s*\|\s*👤\s*([^|]*?)\s*\|\s*📝\s*([^|]*?)\s*\|\s*$")
TABLE_SEP = re.compile(r"^\|\s*:?-+:?\s*\|\s*:?-+:?\s*\|\s*:?-+:?\s*\|\s*$")
TABLE_ROW2 = re.compile(r"^\|\s*🔑\s*([^|]*?)\s*\|\s*\|\s*\|\s*$")
TABLE2_ROW1 = re.compile(r"^\|\s*👤\s*([^|]*?)\s*\|\s*📝\s*([^|]*?)\s*\|\s*$")
TABLE2_SEP = re.compile(r"^\|\s*:?-+:?\s*\|\s*:?-+:?\s*\|\s*$")
TABLE2_ROW2 = re.compile(r"^\|\s*🔑\s*([^|]*?)\s*\|\s*\|\s*$")
USER_HOST = re.compile(r"(\S+)@(\S+)")


def table_header(above):
    """Find the two-row header table in the lines just above a fence, 3-cell or 2-cell form. Returns a
    dict with host/user/logged (required) and prompts (None when its row is absent), or None when no
    table is there."""
    for idx in range(len(above) - 1):
        line0, line1 = above[idx].strip(), above[idx + 1].strip()
        m1 = TABLE_ROW1.match(line0)
        if m1 and TABLE_SEP.match(line1):
            host, user, logged = (g.strip() for g in m1.groups())
            row2 = TABLE_ROW2
        else:
            m1 = TABLE2_ROW1.match(line0)
            if not (m1 and TABLE2_SEP.match(line1)):
                continue
            merged, logged = (g.strip() for g in m1.groups())
            uh = USER_HOST.search(merged)
            user, host = (uh.group(1), uh.group(2)) if uh else ("", "")
            row2 = TABLE2_ROW2
        prompts = None
        if idx + 2 < len(above):
            m2 = row2.match(above[idx + 2].strip())
            if m2:
                prompts = m2.group(1).strip()
        return {"host": host, "user": user, "logged": logged, "prompts": prompts}
    return None


def violations(text):
    lines = text.splitlines()
    blocks, i = [], 0
    while i < len(lines):
        if SHELL_FENCE.match(lines[i].strip()):
            j = i + 1
            while j < len(lines) and not FENCE_END.match(lines[j].strip()):
                j += 1
            above = [l for l in lines[max(0, i - 12):i] if l.strip()][-4:]
            blocks.append((i + 1, "\n".join(lines[i + 1:j]), above))
            i = j + 1
        else:
            i += 1
    if not blocks:
        return []
    out = []
    for n, body, above in blocks:
        tbl = table_header(above)
        if not any(HOST_LINE.search(l) for l in above) and not (tbl and tbl["host"] and tbl["user"]):
            out.append(f"R1 line {n}: shell block has no `► <user>@<host>` line, and no header table, just above it")
        if not any(("📝 LOGGED" in l) or ("🚫 NOT LOGGED" in l) for l in above) and not (tbl and tbl["logged"]):
            out.append(f"R4 line {n}: shell block has no `📝 LOGGED →` / `🚫 NOT LOGGED` marker, and no header table 📝 cell, just above it")
        table_prompts = tbl and tbl["prompts"] and tbl["prompts"].lower() != "none"
        if PROMPT_WORDS.search(body) and "🔑 PROMPTS" not in text and not table_prompts:
            out.append(f"R2 line {n}: block prompts (read -s / sudo / login / ssh / --ask-) but the message has no `🔑 PROMPTS` line or header-table 🔑 cell")
    heads = [l.strip() for l in lines if l.startswith("## ")]
    if not any(h.startswith("## 👤 You") for h in heads):
        out.append("R3: a message with a shell block for the human needs a `## 👤 You` section")
    elif not heads[-1].startswith("## 👤 You"):
        out.append("R3: `## 👤 You` must be the LAST `## ` section")
    return out


def last_assistant_text(path):
    text = ""
    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") != "assistant":
                continue
            parts = [c.get("text", "") for c in d.get("message", {}).get("content", [])
                     if isinstance(c, dict) and c.get("type") == "text"]
            if any(p.strip() for p in parts):
                text = "\n".join(parts)
    return text


def record(reasons):
    gate = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deny-event.py")
    if os.path.exists(gate):
        subprocess.run([sys.executable, gate, "--gate", "handoff-layout-gate", "--rule", "handoff-layout",
                        "--tool", "Stop", "--reason", "; ".join(r.split(":")[0] for r in reasons)],
                       input="\n".join(reasons), text=True, capture_output=True)


def main(argv):
    if argv[:1] == ["--check"]:
        v = violations(open(argv[1], errors="replace").read())
        print("\n".join(v) if v else "ok")
        return 1 if v else 0
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0  # never block on a malformed event; the floor fails open only on its own input errors
    path = data.get("transcript_path") or ""
    if not path or not os.path.exists(path):
        return 0
    v = violations(last_assistant_text(path))
    if not v:
        return 0
    record(v)
    if data.get("stop_hook_active"):
        return 0  # already a retry: allow, recorded, never loop
    reason = ("Hand-off layout (operations.md -> Command hand-off format) is missing:\n- "
              + "\n- ".join(v) + "\nRewrite the final message with the layout, or move the command out of the message.")
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
