#!/bin/bash
# Hook: PreToolUse[Write] — Prevent writing to secrets and sensitive files
# Exit 2 = block the tool call with message shown to Claude
# Exit 0 = allow

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
if ! command -v jq >/dev/null 2>&1 && ! python3 -c '' >/dev/null 2>&1; then
  echo "BLOCKED: this safety gate cannot evaluate the call (neither jq nor python3 is installed). Install one, or run the command yourself." >&2
  exit 2
fi
if [[ -n "$input" ]] && ! is_json "$input"; then
  echo "BLOCKED: this safety gate received tool input it cannot parse; refusing rather than allowing it unchecked." >&2
  exit 2
fi
if [[ -z "$input" && -z "${CLAUDE_TOOL_INPUT:-}" ]]; then
  echo "safety gate: no tool input on stdin or in CLAUDE_TOOL_INPUT; nothing was checked" >&2
fi
path=$(tool_field "$input" .tool_input.file_path .tool_input.path .toolInput.file_path .toolInput.path)
[[ -z "$path" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && path=$(tool_field "$CLAUDE_TOOL_INPUT" .file_path .path)

if [[ -z "$path" ]]; then
  # A write payload with no path this gate can read is a BLIND gate, not a pathless write: refuse.
  # `write` and `search_replace` are Grok's names for Write and Edit (captured 2026-09-25).
  if [[ -n "$input" ]]; then
    tool=$(tool_field "$input" .tool_name .toolName)
    case "$tool" in
      ""|Write|Edit|MultiEdit|write|search_replace)
        echo "BLOCKED: this safety gate cannot read the file path in this ${tool:-unnamed} tool payload; refusing rather than allowing it unchecked." >&2
        exit 2 ;;
    esac
  fi
  exit 0
fi

# Block writes to environment/secrets files
if echo "$path" | grep -qE '(\.env$|\.env\.(prod|production|staging|live)|\.env\.local$)'; then
  echo "BLOCKED: Cannot write to environment files. These may contain secrets. Edit manually." >&2
  exit 2
fi

# Block writes to credential/key files
if echo "$path" | grep -qiE '(credentials|secrets|\.pem$|\.key$|\.p12$|\.pfx$|\.jks$|id_rsa|id_ed25519|\.ssh/|\.aws/|\.gcloud/)'; then
  echo "BLOCKED: Cannot write to credential or key files. Edit manually." >&2
  exit 2
fi

# Block writes to CI/CD secrets
if echo "$path" | grep -qE '(\.github/.*secret|vault\.y[a]?ml|\.vault-pass)'; then
  echo "BLOCKED: Cannot write to CI/CD secrets files. Edit manually." >&2
  exit 2
fi

exit 0
