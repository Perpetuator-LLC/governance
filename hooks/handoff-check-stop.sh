#!/bin/bash
# Hook: Stop — refuse to let the agent stop while its last message hands off an unlabelled prompt.
#
# The rule "every hand-off prompt is named by owner + host" can sit in an agent's resident
# instructions and still not be applied at hand-off time (governance#243): a committed script
# stopped on a bare `sudo` Password: prompt naming no account and no host, and more or fresher
# prose would not have changed that — prose is read once, at session start, and acted on from
# memory after that. This hook reads the actual text of the agent's last message, every turn, and
# runs it through bin/handoff-check: a gate that runs is a gate that fires, where a rule that only
# sat in context is not.
#
# Exit 2 = block the Stop (the reason goes to the model on stderr, which must fix the labelling
# and try again). Exit 0 = allow. ANY internal failure here — no transcript, no python3, nothing
# parseable, no assistant turn found — fails OPEN: this is a lint on a message's own wording, not
# a security control, and blocking every stop on a hiccup would cost more than missing one
# unlabelled prompt.

input=""
[[ ! -t 0 ]] && input=$(cat)
[[ -z "$input" ]] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

tool_field() {  # tool_field <json> <.path> [<.path> ...]  -> first non-empty string
  local json="$1"; shift
  if command -v jq >/dev/null 2>&1; then
    local k v
    for k in "$@"; do
      v=$(printf '%s' "$json" | jq -r "($k | strings) // empty" 2>/dev/null)
      [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    done
  else
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1:]:
    v = d
    for p in k.strip(".").split("."):
        v = v.get(p) if isinstance(v, dict) else None
    if isinstance(v, str) and v:
        sys.stdout.write(v)
        break
' "$@"
  fi
}

transcript=$(tool_field "$input" .transcript_path .transcriptPath)
[[ -z "$transcript" || ! -f "$transcript" ]] && exit 0
cwd=$(tool_field "$input" .cwd)
[[ -z "$cwd" || ! -d "$cwd" ]] && cwd="$(pwd)"

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/bin"
[[ -f "$BIN_DIR/handoff-check" ]] || exit 0

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MSG="$WORK/handoff.md"

# The last assistant turn's TEXT content, concatenated in order. Tool-use blocks and earlier turns
# are not what is about to be handed to the human; only this turn's own words are.
python3 - "$transcript" >"$MSG" 2>/dev/null <<'PY'
import json, sys

path = sys.argv[1]
last = None
with open(path, "r", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        msg = rec.get("message") if isinstance(rec, dict) else None
        if isinstance(msg, dict) and msg.get("role") == "assistant":
            last = msg

if not last:
    sys.exit(0)
content = last.get("content")
if isinstance(content, str):
    sys.stdout.write(content)
elif isinstance(content, list):
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            sys.stdout.write(block.get("text", ""))
            sys.stdout.write("\n")
PY

[[ -s "$MSG" ]] || exit 0

out=$(python3 "$BIN_DIR/handoff-check" --base-dir "$cwd" "$MSG" 2>&1)
rc=$?
if [[ $rc -eq 1 ]]; then
  echo "BLOCKED: this message hands off at least one unlabelled prompt (no owner + host named). Label it (e.g. sudo -p 'owner@host: ') and try again:" >&2
  echo "$out" >&2
  exit 2
fi
exit 0
