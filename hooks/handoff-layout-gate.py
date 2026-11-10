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
  R5  every shell block opens with a BANNER line and closes with an END line (the human, 2026-11-06: they run blocks
      from many agents and need to see, in the shell itself, which request and which step they are on):
          echo '▶ <agent> · <card> · <step>/<total> · <MM-DD HH:MM>'      (first line: who asked, for what, when)
          echo "■ <agent> · <card> · <step>/<total> · done rc=$?"          (last line: it finished, and how)
      <card> is the ticket or block the request belongs to (e.g. `#12 B`); <step>/<total> counts the blocks of
      one request; the time is when the agent asked, read from the clock. The END label repeats the BANNER's.
      TIMED form (the human, 2026-11-09): the shell also records when the block actually ran,
      how long it took, and the agent's estimate, so a slow or hung step shows up next to its guess:
          T0=$(date +%s); echo "▶ <label> · asked <MM-DD HH:MM> · est ~<N><s|m|h> · start $(date '+%H:%M:%S')"
          rc=$?; echo "■ <label> · done rc=$rc · end $(date '+%H:%M:%S') · took $(( $(date +%s) - T0 ))s"
      `rc=$?` comes FIRST on the end line: any command substitution before it (a `date`) would overwrite `$?`.
      The only expansions accepted are those literal ones; the label stays expansion-free. A timed banner needs
      a timed end (it sets T0) and an untimed banner an untimed end. Both pairs are accepted while hand-off
      examples move to the timed form.

The header table is two markdown rows directly above the fence, in either of two forms:
    | 🖥️ <host> | 👤 <user> | 📝 <logged, or "no"> |          | 👤 <user>@<machine> | 📝 <logged, or "no"> |
    | --- | --- | --- |                              or       | --- | --- |
    | 🔑 <prompts, or "none"> | | |                           | 🔑 <prompts, or "none"> | |
3-cell form: host and user are separate cells. 2-cell form: one cell merges them as `user@machine`,
parsed the same way as the `►` line's own `<user>@<host>`. All three forms are accepted; the human asked for
the 3-cell table on 2026-10-25 and the 2-cell table the same day, each replacing the one before it in
their own use, but none is retired here — the gate checks whichever one precedes a given block.

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
# The label is printed by `echo` in the human's own shell, and the END line must be double-quoted for `$?`,
# so a label is restricted to characters no shell expands or ends a string on: no `$`, backtick, quote, `;`,
# `\`, `(`, `)` -- a ticket title pasted as the card can never run as a command (cisa SEND-BACK, #395).
LABEL = r"[A-Za-z0-9 #._:/+\-]+"
BANNER = re.compile(r"""^echo\s+(['"])▶\s+(""" + LABEL + r"""\s·\s""" + LABEL + r"""\s·\s(\d+)/(\d+))\s·\s\d\d-\d\d\s\d\d:\d\d\1\s*$""")
END_LINE = re.compile(r"""^echo\s+"■\s+(""" + LABEL + r"""\s·\s""" + LABEL + r"""\s·\s\d+/\d+)\s·\sdone\s+rc=\$\?"\s*$""")
# The timed pair. Every expansion in it is spelled out literally here, so the gate still admits
# no expansion the agent chose: only T0, the clock, and the captured rc.
_LBL = r"(" + LABEL + r"""\s·\s""" + LABEL + r"""\s·\s(\d+)/(\d+))"""
TIMED_BANNER = re.compile(r"""^T0=\$\(date \+%s\);\s*echo\s+"▶\s+""" + _LBL
                          + r"""\s·\sasked\s\d\d-\d\d\s\d\d:\d\d\s·\sest\s~\d+[smh]"""
                          + r"""\s·\sstart\s\$\(date '\+%H:%M:%S'\)"\s*$""")
TIMED_END = re.compile(r"""^rc=\$\?;\s*echo\s+"■\s+(""" + LABEL + r"""\s·\s""" + LABEL + r"""\s·\s\d+/\d+)"""
                       + r"""\s·\sdone\s+rc=\$rc\s·\send\s\$\(date '\+%H:%M:%S'\)"""
                       + r"""\s·\stook\s\$\(\( \$\(date \+%s\) - T0 \)\)s"\s*$""")


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


def banner_violations(n, body):
    """R5: the block's first line names who asked, for which card, which step of how many, and when; its last
    line says it finished, with the same label and the exit status. The timed pair also records start, end,
    duration and the agent's estimate."""
    code = [l.strip() for l in body.splitlines() if l.strip()]
    timed = TIMED_BANNER.match(code[0]) if code else None
    first = timed or (BANNER.match(code[0]) if code else None)
    if not first:
        return [f"R5 line {n}: shell block must open with "
                "`T0=$(date +%s); echo \"▶ <agent> · <card> · <step>/<total> · asked <MM-DD HH:MM> · est ~<N>m · start $(date '+%H:%M:%S')\"`"
                " (label characters: letters, digits, space and # . _ : / + -)"]
    label = first.group(1) if timed else first.group(2)
    step, total = (int(first.group(2)), int(first.group(3))) if timed else (int(first.group(3)), int(first.group(4)))
    if not 1 <= step <= total:
        return [f"R5 line {n}: banner step {step}/{total} is out of range"]
    end_re, end_shape = (TIMED_END, "`rc=$?; echo \"■ <agent> · <card> · <step>/<total> · done rc=$rc · end $(date '+%H:%M:%S') · took $(( $(date +%s) - T0 ))s\"`"
                         " (rc=$? FIRST, before any date)") if timed else (END_LINE, "`echo \"■ <agent> · <card> · <step>/<total> · done rc=$?\"`")
    last = end_re.match(code[-1]) if len(code) > 1 else None
    if not last:
        return [f"R5 line {n}: shell block must close with {end_shape}"]
    if last.group(1) != label:
        return [f"R5 line {n}: end label `{last.group(1)}` does not repeat the banner's `{label}`"]
    return []


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
        out.extend(banner_violations(n, body))
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
