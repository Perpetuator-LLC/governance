#!/bin/bash
# Hook: PostToolUse[Write|Edit] — Auto syntax-check after file edits
# Runs a quick syntax check based on file extension
# Exit 0 always — this is advisory, not blocking

# Claude Code delivers hook input as JSON on STDIN: {"tool_name": ..., "tool_input": {...}}. This hook
# originally read $CLAUDE_TOOL_INPUT, which the harness never sets, so every check below received an
# empty string and ALLOWED everything, silently, from the first commit. The env var is kept only as a
# fallback for a harness that still uses it.
input=""
[[ ! -t 0 ]] && input=$(cat)
# Parse with jq when present, python3 otherwise: a CI runner or a fresh machine may lack jq, and a
# parser dependency that is silently absent is exactly how this hook read nothing for months.
tool_field() {  # tool_field <json> <.path> [<.path> ...]  -> first non-empty string
  local json="$1"; shift
  if command -v jq >/dev/null 2>&1; then
    local k v
    for k in "$@"; do
      # `strings`: a non-string value is unreadable, as in the python branch. Without it jq printed an
      # array as JSON text, so one payload got two verdicts depending on which parser the host had.
      v=$(printf '%s' "$json" | jq -r "($k | strings) // empty" 2>/dev/null)
      [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    done
  elif python3 -c '' >/dev/null 2>&1; then
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
is_json() {
  if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -e . >/dev/null 2>&1
  else printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; fi
}
path=$(tool_field "$input" .tool_input.file_path .tool_input.path)
[[ -z "$path" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && path=$(tool_field "$CLAUDE_TOOL_INPUT" .file_path .path)

if [[ -z "$path" || ! -f "$path" ]]; then
  exit 0
fi

ext="${path##*.}"

case "$ext" in
  py)
    python3 -m py_compile "$path" 2>&1 | head -10
    ;;
  ts|tsx)
    if command -v npx &>/dev/null && [[ -f "$(dirname "$path")/tsconfig.json" || -f "./tsconfig.json" ]]; then
      npx tsc --noEmit --pretty false 2>&1 | grep -A2 "$(basename "$path")" | head -15
    fi
    ;;
  js|jsx|mjs)
    if command -v node &>/dev/null; then
      node --check "$path" 2>&1 | head -10
    fi
    ;;
  rb)
    if command -v ruby &>/dev/null; then
      ruby -c "$path" 2>&1 | head -10
    fi
    ;;
  go)
    if command -v gofmt &>/dev/null; then
      gofmt -e "$path" >/dev/null 2>&1 | head -10
    fi
    ;;
  rs)
    # Rust — just check syntax of the single file isn't practical,
    # so skip unless cargo check is fast
    ;;
  json)
    if command -v jq &>/dev/null; then
      jq empty "$path" 2>&1 | head -5
    elif command -v python3 &>/dev/null; then
      python3 -m json.tool "$path" >/dev/null 2>&1 | head -5
    fi
    ;;
  yaml|yml)
    if command -v python3 &>/dev/null; then
      python3 -c "import yaml; yaml.safe_load(open('$path'))" 2>&1 | head -5
    fi
    ;;
  sh|bash|zsh)
    if command -v bash &>/dev/null; then
      bash -n "$path" 2>&1 | head -5
    fi
    ;;
esac

exit 0
