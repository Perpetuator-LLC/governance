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
# camelCase is Grok's own spelling. Captured 2026-09-25 it sends both, but its documentation shows only
# camelCase, and a harness that drops the alias would leave this gate reading nothing.
cmd=$(tool_field "$input" .tool_input.command .toolInput.command)
[[ -z "$cmd" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && cmd=$(tool_field "$CLAUDE_TOOL_INPUT" .command)

if [[ -z "$cmd" ]]; then
  # A payload arrived, it is (or may be) a shell call, and there is no command this gate can read: the
  # gate is BLIND, not the call empty. Allowing here is how a harness with a different schema gets a
  # floor that allows everything while looking installed. A payload naming some OTHER tool is not ours.
  if [[ -n "$input" ]]; then
    tool=$(tool_field "$input" .tool_name .toolName)
    case "$tool" in
      ""|Bash|run_terminal_command)
        echo "BLOCKED: this safety gate cannot read the command in this ${tool:-unnamed} tool payload; refusing rather than allowing it unchecked." >&2
        exit 2 ;;
    esac
  fi
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

# Block executing an ENCODED payload.
# A step handed to a human must be readable by the human who runs it. An encoded or compressed
# payload is not a command — it is an opaque binary that will execute with that human's credentials,
# and the blast radius is everything those credentials reach, not just their machine. Compression
# that defeats review is not incidental to the delivery mechanism; it IS the defect. Decoding alone
# is allowed (inspecting a payload is how you review it); decoding INTO an interpreter is not.
if echo "$cmd" | grep -qiE '(base64|xxd|uudecode|openssl\s+enc)[^|;]*(-d|--decode|-D)?[^|;]*\|\s*(bash|sh|zsh|python3?|node|perl|ruby)'; then
  echo "BLOCKED: decoding a payload straight into an interpreter. The human running this cannot read what it does, and it executes with their credentials. Commit the change and open a pull request instead." >&2
  exit 2
fi
# Decode-then-execute, split across && or ; — the same shape with a file in the middle.
if echo "$cmd" | grep -qiE '(base64|xxd|uudecode)[^&;]*(-d|--decode|-D)[^&;]*>[^&;]+[;&]+[^&;]*(bash|sh|zsh|python3?|node|perl|ruby)\s'; then
  echo "BLOCKED: decoding a payload to a file and then executing it. Writing it to disk first does not make it reviewable. Commit the change and open a pull request instead." >&2
  exit 2
fi
# Piping stdin straight into an interpreter.
if echo "$cmd" | grep -qE '\|\s*(python3?|node|perl|ruby|bash|sh|zsh)\s+-\s*$'; then
  echo "BLOCKED: piping stdin into an interpreter. Whatever produced that stream is unreviewable at the point it runs. Put the code in a file under version control." >&2
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
SECRET_READ='cat\s+.*\.env|grep\s+.*\.env|rg\s+.*\.env|head\s+.*\.env|tail\s+.*\.env|less\s+.*\.env|more\s+.*\.env'

# The pattern runs over the WHOLE string, so `.*` spans `&&`, `;` and `|`: a reader verb in one command
# and a name merely containing ".env" in another (`grep -q x a.json && cp sample.environment.ts b`) was
# blocked, several times a session in one lane. An over-broad floor gate is one the next person deletes.
#
# So a whole-string match is re-checked per SUB-COMMAND — and this can only ever turn a block into an
# allow, never the reverse: the pattern is unchanged and still runs first. Every doubt keeps the block:
#   - no python3 (a jq-only host), or a command that will not tokenise (unbalanced quote);
#   - anything that nests one command inside another, because a separator inside it belongs to the
#     inner command and the tokeniser cannot see that: `head $(echo x; echo .env)` reads .env, and a
#     naive split calls it two clean halves. Same for backticks, `(…)` subshells, `<(…)`, `{ …; }`
#     groups (a redirect after the group feeds every command in it), and an ESCAPED separator such as
#     `find … -exec head {} \;`, which the tokeniser returns as a bare `;`.
# Quote-aware: `grep "a && b" .env` is ONE sub-command. A naive split on `&&` would allow it.
only_across_subcommands() {  # <cmd> <regex> -> 0 iff it tokenises cleanly and NO sub-command matches
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import re, shlex, sys
cmd, pat = sys.argv[1], sys.argv[2]
if re.search(r"[`()]|\\[;&|\n]", cmd):   # nesting; an escaped separator; a backslash-continued line
    sys.exit(1)
try:
    # posix=False KEEPS the quotes on a token. In posix mode a quoted `";"` or a quoted newline comes
    # back as the bare `;` / newline — indistinguishable from a real separator — so `grep ";" .env`
    # split into two clean halves and was ALLOWED. Caught by the probe before it shipped.
    # An UNQUOTED newline ends a command, so it is a separator token; a QUOTED one stays inside its
    # word, so `grep "KEY<newline>" .env` remains one sub-command and still matches (DOTALL below).
    lex = shlex.shlex(cmd, posix=False, punctuation_chars="();<>|&\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    toks = list(lex)
except ValueError:
    sys.exit(1)
if any(t in ("{", "}") for t in toks):
    sys.exit(1)
SEP = {"&&", "||", ";", "|", "&", "|&", "\n"}
segs, cur = [], []
for t in toks:
    if t in SEP:
        segs.append(cur)
        cur = []
    else:
        cur.append(t)
segs.append(cur)
rx = re.compile(pat, re.DOTALL)
sys.exit(1 if any(rx.search(" ".join(s)) for s in segs) else 0)
PY
}

# FLATTEN before matching. `grep -E` matches line by line, so a newline between the reader and the file
# name — even one inside quotes, `cat "<newline>" .env`, which reads the file — hid the read from every
# line and the gate ALLOWED it. Joining the lines closes that; the per-sub-command check above then
# splits on UNQUOTED newlines, so an ordinary multi-line command keeps today's line-wise behaviour.
if printf '%s' "$cmd" | tr '\n\r' '  ' | grep -qE "$SECRET_READ" && ! only_across_subcommands "$cmd" "$SECRET_READ"; then
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
