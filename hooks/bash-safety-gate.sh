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

# Every refusal goes through deny(): the one-line reason to the model, then ONE audit event from
# deny-event.py beside this script (OCSF api_activity, security_control). The event carries a hash of the
# refused text, never the text. The trail fails OPEN (no helper, no python3, an unwritable log) and never
# changes the verdict.
DENY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/deny-event.py"
deny() {  # deny <rule-id> <reason>: refuse, record, exit 2
  echo "BLOCKED: $2" >&2
  if [[ -f "$DENY_HELPER" ]] && python3 -c '' >/dev/null 2>&1; then
    printf '%s' "${cmd:-}" | python3 "$DENY_HELPER" --gate bash-safety-gate --rule "$1" \
      --tool "${tool:-}" --reason "$2" >/dev/null 2>&1 || true
  fi
  exit 2
}
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
  deny no-parser "this safety gate cannot evaluate the call (neither jq nor python3 is installed). Install one, or run the command yourself."
fi
if [[ -n "$input" ]] && ! is_json "$input"; then
  deny unparseable-input "this safety gate received tool input it cannot parse; refusing rather than allowing it unchecked."
fi
if [[ -z "$input" && -z "${CLAUDE_TOOL_INPUT:-}" ]]; then
  echo "safety gate: no tool input on stdin or in CLAUDE_TOOL_INPUT; nothing was checked" >&2
fi
# camelCase is Grok's own spelling. Captured 2026-09-25 it sends both, but its documentation shows only
# camelCase, and a harness that drops the alias would leave this gate reading nothing.
cmd=$(tool_field "$input" .tool_input.command .toolInput.command)
[[ -z "$cmd" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && cmd=$(tool_field "$CLAUDE_TOOL_INPUT" .command)
tool=$(tool_field "$input" .tool_name .toolName)   # once, for the checks below and for deny()'s event

if [[ -z "$cmd" ]]; then
  # A payload arrived, it is (or may be) a shell call, and there is no command this gate can read: the
  # gate is BLIND, not the call empty. Allowing here is how a harness with a different schema gets a
  # floor that allows everything while looking installed. A payload naming some OTHER tool is not ours.
  if [[ -n "$input" ]]; then
    tool=$(tool_field "$input" .tool_name .toolName)
    case "$tool" in
      ""|Bash|run_terminal_command)
        deny blind-payload "this safety gate cannot read the command in this ${tool:-unnamed} tool payload; refusing rather than allowing it unchecked." ;;
    esac
  fi
  exit 0
fi

# Block MINTING A CREDENTIAL anywhere but the agent's own sandboxed shell.
# A terminal-panel tool types into the HUMAN'S interactive shell: it has a TTY and no agent ancestor, so
# a login script's own "refuse an agent" guard cannot see it, the credential lands in a session the human
# never chose to authenticate, and whatever the command prints can be read back by the agent. A layer
# that routes such a tool to this gate gets this check without the core naming the tool: it applies to
# every tool routed here EXCEPT `Bash`.
#   - Not `Bash`: no TTY, so an interactive login prompts nobody, and a login fed from a store on stdin
#     (`--password-stdin`) is a legitimate blind pipeline.
#   - Grok's `run_terminal_command` gets it: Grok has no separate terminal-panel tool, and a TUI session
#     runs its shell where the human sits. That also refuses a stdin-fed login typed directly on Grok;
#     put it in a committed script, whose contents this gate does not see.
# The class is "mint or print a credential"; the list is its public members, and a new CLI is added by
# name. An organisation's own login wrappers belong in its adapter, as its own gate on the same tools,
# because a wrapper's name is private and it hides the CLI it calls. Over-match is deliberate: `echo "bao login"` is refused too, which costs the human one keystroke,
# where a miss costs a credential.
CRED_MINT='(^|[^A-Za-z0-9_-])((bao|vault)([[:space:]]+-[^[:space:]]+)*[[:space:]]+(login|token[[:space:]]+(create|lookup)|print[[:space:]]+token)|gh[[:space:]]+auth[[:space:]]+(login|refresh|token)|(docker|podman)[[:space:]]+login|aws[[:space:]]+(sso[[:space:]]+login|sts[[:space:]]+(get-session-token|assume-role))|gcloud[[:space:]]+auth[[:space:]]+(login|print-access-token|application-default[[:space:]]+(login|print-access-token))|az[[:space:]]+login|op[[:space:]]+signin|npm[[:space:]]+(login|adduser)|kubectl[[:space:]]+create[[:space:]]+token)([^A-Za-z0-9_-]|$)'
if [[ "$tool" != "Bash" ]] \
   && printf '%s' "$cmd" | tr '\n\r' '  ' | grep -qE "$CRED_MINT"; then
  deny credential-mint "this runs a credential login or token command outside your own sandboxed shell, where it would create or print a credential in a session the human did not choose to open. Ask the human to run it themselves."
fi

# Block destructive filesystem operations
if echo "$cmd" | grep -qE '^\s*rm\s+-rf\s+(/|~|\$HOME|\.\.)'; then
  deny rm-rf-root "Destructive rm -rf targeting root, home, or parent directory. Requires manual execution."
fi

# git subcommands are matched within ONE command segment (no ; & |), and git's GLOBAL options may sit
# between `git` and the subcommand: `git -C <dir> push` and `git -c k=v push` are the ordinary agent
# forms, and both ran unchecked while the patterns required `git push` adjacent. A force is `--force`,
# `--force-with-lease`, `--force-if-includes`, `-f`, or a `+`-prefixed refspec (`push origin +main`).
GIT_SEG='(^|[^[:alnum:]_-])git([[:space:]]+[^;&|]*)?[[:space:]]'

# Block force pushes
if echo "$cmd" | grep -qE "${GIT_SEG}push([[:space:]][^;&|]*)?[[:space:]]((--force[a-z-]*|-f)([[:space:]=]|\$)|\+[^[:space:];&|])"; then
  deny force-push "Force push requires manual confirmation. Run this command yourself if intended."
fi

# Block hard resets
if echo "$cmd" | grep -qE "${GIT_SEG}reset([[:space:]][^;&|]*)?[[:space:]]--hard([[:space:]]|\$)"; then
  deny hard-reset "Hard reset requires manual confirmation. Run this command yourself if intended."
fi

# Block database destruction
if echo "$cmd" | grep -qiE '(DROP\s+(TABLE|DATABASE)|TRUNCATE\s+TABLE|DELETE\s+FROM\s+\w+\s*;?\s*$)'; then
  deny database-destroy "Destructive database operation. Requires manual confirmation."
fi

# Block piping remote scripts to shell. The shell name needs a RIGHT boundary (#148): without one,
# `| sha256` or `| shellcheck` read as `| sh`, and the review this rule prescribes was refused. And
# the shell may sit behind `sudo [flags]` or a full path (`| /bin/bash`), which passed unchecked.
if echo "$cmd" | grep -qE '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?([^[:space:]|;&]*/)?(bash|sh|zsh)([[:space:];&|)]|$)'; then
  deny remote-pipe-shell "Piping remote content to shell is unsafe. Download and review first."
fi

# Block executing an ENCODED payload.
# A step handed to a human must be readable by the human who runs it. An encoded or compressed
# payload is not a command — it is an opaque binary that will execute with that human's credentials,
# and the blast radius is everything those credentials reach, not just their machine. Compression
# that defeats review is not incidental to the delivery mechanism; it IS the defect. Decoding alone
# is allowed (inspecting a payload is how you review it); decoding INTO an interpreter is not.
if echo "$cmd" | grep -qiE '(base64|xxd|uudecode|openssl\s+enc)[^|;]*(-d|--decode|-D)?[^|;]*\|\s*(bash|sh|zsh|python3?|node|perl|ruby)'; then
  deny decode-to-interpreter "decoding a payload straight into an interpreter. The human running this cannot read what it does, and it executes with their credentials. Commit the change and open a pull request instead."
fi
# Decode-then-execute, split across && or ; — the same shape with a file in the middle.
if echo "$cmd" | grep -qiE '(base64|xxd|uudecode)[^&;]*(-d|--decode|-D)[^&;]*>[^&;]+[;&]+[^&;]*(bash|sh|zsh|python3?|node|perl|ruby)\s'; then
  deny decode-then-execute "decoding a payload to a file and then executing it. Writing it to disk first does not make it reviewable. Commit the change and open a pull request instead."
fi
# Piping stdin straight into an interpreter.
if echo "$cmd" | grep -qE '\|\s*(python3?|node|perl|ruby|bash|sh|zsh)\s+-\s*$'; then
  deny stdin-to-interpreter "piping stdin into an interpreter. Whatever produced that stream is unreviewable at the point it runs. Put the code in a file under version control."
fi

# Block eval of untrusted input
if echo "$cmd" | grep -qE '^\s*eval\s+'; then
  deny eval "eval is dangerous. Use direct commands instead."
fi

# Block fork bombs.
# Not redundant with a settings deny rule: a deny entry for the classic literal contains inner
# parentheses, and a rule parser that matches `Bash(` to the FIRST `)` reads it as malformed and
# drops it, silently, whenever the harness rewrites the settings file. This check survives that.
#
# Matched by SHAPE, not by literal, which the deny rule never managed: a function whose body pipes
# itself into the background. Renaming `:` to anything else defeats the literal but not this.
if echo "$cmd" | grep -qE '[a-zA-Z_:][a-zA-Z0-9_:]*\s*\(\s*\)\s*\{[^}]*\|[^}]*&[^}]*\}\s*;'; then
  deny fork-bomb "fork-bomb shape (self-piping backgrounded function). Requires manual execution."
fi

# Block secret extraction — secrets must never enter agent context.
# Catches: cat/grep/rg/head/tail on .env files, keychain access, docker env dumps.
# The name has a RIGHT BOUNDARY: `.env` followed by a non-letter, `rc`, or the end. That still matches
# `.env`, `.env.local`, `.env_x`, `"$D/.env"` and `.envrc` (direnv files hold secrets too), and stops
# matching a longer word that merely starts with the letters: `properties.environment`,
# `sample.environment.ts`, `.envoy.yaml`. Without it, any reader verb near such a word was refused.
SECRET_NAME='\.env([^A-Za-z]|rc|$)'
SECRET_READ="cat\s+.*$SECRET_NAME|grep\s+.*$SECRET_NAME|rg\s+.*$SECRET_NAME|head\s+.*$SECRET_NAME|tail\s+.*$SECRET_NAME|less\s+.*$SECRET_NAME|more\s+.*$SECRET_NAME"

# A heredoc BODY given to `cat` or `tee` is DATA: those two only copy their stdin, so prose in the body
# that names the file reads nothing. Refusing it blocked a seat's hand-off append (`cat >> <file> <<EOF`
# whose note said the file was absent), and the successor booted from a stale note. Such a body is
# removed before matching, and ONLY such a body. Every doubt keeps it, so this can only turn a block
# into an allow, never the reverse:
#   - any other owner keeps its body: `bash <<'EOF'` / `python3 - <<'EOF'` EXECUTE it;
#   - an UNQUOTED delimiter keeps a body holding `$(` or a backtick: those run while the body is built;
#   - no terminator, several heredocs on one line, an unusual delimiter, or no python3: nothing removed.
# The command line itself is never removed, so `cat .env - > out <<'EOF'` still reads, and is refused.
strip_data_heredocs() {  # <cmd> -> <cmd> with data-only heredoc bodies removed; unchanged on any doubt
  if ! command -v python3 >/dev/null 2>&1; then printf '%s' "$1"; return 0; fi
  python3 - "$1" <<'PY' 2>/dev/null || printf '%s' "$1"
import re, sys
cmd = sys.argv[1]
MARK = re.compile(r"<<(-?)[ \t]*(?:'([A-Za-z_]\w*)'|\"([A-Za-z_]\w*)\"|([A-Za-z_]\w*)(?![\w'\"-]))")
def strip(cmd):
    lines, out, i = cmd.split("\n"), [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        marks = [m for m in MARK.finditer(line)
                 if not (m.start() > 0 and line[m.start() - 1] == "<") and not line.startswith("<", m.start() + 2)]
        if len(marks) != 1:
            i += 1
            continue
        m = marks[0]
        dash, sq, dq, bare = m.groups()
        tag, quoted = sq or dq or bare, bool(sq or dq)
        words = re.split(r"&&|\|\||[;|&]", line[:m.start()])[-1].split()
        owner = words[0] if words else ""
        j = i + 1
        while j < len(lines) and (lines[j].lstrip("\t") if dash else lines[j]) != tag:
            j += 1
        if j == len(lines):                                  # unterminated: keep everything
            i += 1
            continue
        body = "\n".join(lines[i + 1:j])
        if owner in ("cat", "tee") and (quoted or ("$(" not in body and "`" not in body)):
            out.append(lines[j])                             # keep the terminator, drop the body
            i = j + 1
        else:
            i += 1
    return "\n".join(out)
try:
    sys.stdout.write(strip(cmd))
except Exception:
    sys.stdout.write(cmd)
PY
}

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
scan=$(strip_data_heredocs "$cmd")
if printf '%s' "$scan" | tr '\n\r' '  ' | grep -qE "$SECRET_READ" && ! only_across_subcommands "$scan" "$SECRET_READ"; then
  deny secret-file-read "Reading .env files would expose secrets to the AI context. Use Secure Handoff: write a script with read -rs prompts for the user to run."
fi

if echo "$cmd" | grep -qE 'security\s+find-generic-password|security\s+find-internet-password'; then
  deny keychain-read "Keychain access would expose secrets to the AI context. Keychain reads belong in runtime code only, not in development commands."
fi

if echo "$cmd" | grep -qE 'docker\s+(exec|inspect).*env|docker\s+(exec|inspect).*\.env|docker\s+(exec|inspect).*secret|docker\s+(exec|inspect).*token|docker\s+(exec|inspect).*password'; then
  deny container-secret-read "Extracting secrets from containers would expose them to the AI context. Use Secure Handoff instead."
fi

if echo "$cmd" | grep -qE 'printenv|/proc/.*/environ'; then
  deny process-env-read "Reading process environment would expose secrets to the AI context."
fi

exit 0
