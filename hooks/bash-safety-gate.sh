#!/bin/bash
# Hook: PreToolUse[Bash] — Block dangerous shell commands
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
      v=$(printf '%s' "$json" | jq -r "$k // empty" 2>/dev/null)
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
cmd=$(tool_field "$input" .tool_input.command)
[[ -z "$cmd" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && cmd=$(tool_field "$CLAUDE_TOOL_INPUT" .command)

if [[ -z "$cmd" ]]; then
  exit 0
fi

# Block destructive filesystem operations
if echo "$cmd" | grep -qE '^\s*rm\s+-rf\s+(/|~|\$HOME|\.\.)'; then
  echo "BLOCKED: Destructive rm -rf targeting root, home, or parent directory. Requires manual execution." >&2
  exit 2
fi

# Block force pushes
if echo "$cmd" | grep -qE 'git\s+push\s+.*--force'; then
  echo "BLOCKED: Force push requires manual confirmation. Run this command yourself if intended." >&2
  exit 2
fi

# Block hard resets
if echo "$cmd" | grep -qE 'git\s+reset\s+--hard'; then
  echo "BLOCKED: Hard reset requires manual confirmation. Run this command yourself if intended." >&2
  exit 2
fi

# Block database destruction
if echo "$cmd" | grep -qiE '(DROP\s+(TABLE|DATABASE)|TRUNCATE\s+TABLE|DELETE\s+FROM\s+\w+\s*;?\s*$)'; then
  echo "BLOCKED: Destructive database operation. Requires manual confirmation." >&2
  exit 2
fi

# Block piping remote scripts to shell
if echo "$cmd" | grep -qE '(curl|wget)\s+.*\|\s*(bash|sh|zsh)'; then
  echo "BLOCKED: Piping remote content to shell is unsafe. Download and review first." >&2
  exit 2
fi

# Block eval of untrusted input
if echo "$cmd" | grep -qE '^\s*eval\s+'; then
  echo "BLOCKED: eval is dangerous. Use direct commands instead." >&2
  exit 2
fi

# Block fork bombs.
# Not redundant with a settings deny rule: a deny entry for the classic literal contains inner
# parentheses, and a rule parser that matches `Bash(` to the FIRST `)` reads it as malformed and
# drops it, silently, whenever the harness rewrites the settings file. This check survives that.
#
# Matched by SHAPE, not by literal, which the deny rule never managed: a function whose body pipes
# itself into the background. Renaming `:` to anything else defeats the literal but not this.
if echo "$cmd" | grep -qE '[a-zA-Z_:][a-zA-Z0-9_:]*\s*\(\s*\)\s*\{[^}]*\|[^}]*&[^}]*\}\s*;'; then
  echo "BLOCKED: fork-bomb shape (self-piping backgrounded function). Requires manual execution." >&2
  exit 2
fi

# Block secret extraction — secrets must never enter agent context.
# Catches: cat/grep/rg/head/tail on .env files, keychain access, docker env dumps.
if echo "$cmd" | grep -qE 'cat\s+.*\.env|grep\s+.*\.env|rg\s+.*\.env|head\s+.*\.env|tail\s+.*\.env|less\s+.*\.env|more\s+.*\.env'; then
  echo "BLOCKED: Reading .env files would expose secrets to the AI context. Use Secure Handoff: write a script with read -rs prompts for the user to run." >&2
  exit 2
fi

if echo "$cmd" | grep -qE 'security\s+find-generic-password|security\s+find-internet-password'; then
  echo "BLOCKED: Keychain access would expose secrets to the AI context. Keychain reads belong in runtime code only, not in development commands." >&2
  exit 2
fi

if echo "$cmd" | grep -qE 'docker\s+(exec|inspect).*env|docker\s+(exec|inspect).*\.env|docker\s+(exec|inspect).*secret|docker\s+(exec|inspect).*token|docker\s+(exec|inspect).*password'; then
  echo "BLOCKED: Extracting secrets from containers would expose them to the AI context. Use Secure Handoff instead." >&2
  exit 2
fi

if echo "$cmd" | grep -qE 'printenv|/proc/.*/environ'; then
  echo "BLOCKED: Reading process environment would expose secrets to the AI context." >&2
  exit 2
fi

exit 0
