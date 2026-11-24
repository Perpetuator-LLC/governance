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

# Block RIDING THE OPERATOR'S OWN CREDENTIAL HELPER: Apple's system gitconfig sets
# `credential.helper=osxkeychain` globally, so an agent's own `git ls-remote https://<forge>` makes
# macOS ask the OPERATOR to unlock their login keychain -- an unrelated prompt, on the operator's own
# screen, for a credential the agent's call never needed. settings/claude.json's own `env` block is
# the primary fix (every session starts with the helper reset to empty, GIT_CONFIG_COUNT/KEY/VALUE,
# and GIT_TERMINAL_PROMPT=0 so a prompt that still manages to fire never blocks on an answer); these
# three checks are the floor backstop for a session that mitigation never reached, or a command that
# tries to work around it directly.
#
# 1. RE-ENABLING a helper the env override reset to empty: `-c credential.helper=<value>` or
# `git config ... credential.helper <value>`, where <value> is non-empty -- an EMPTY value is the safe
# direction (it is exactly what the env override itself sets, and `--unset` removes the key outright),
# so neither is refused, the same "empty/no-op is off" shape as ControlPath=none and
# ControlPersist=false in the ssh-mux check above.
# Matched WITHOUT regard to case, and with an optional middle part: git config keys are
# case-insensitive (`credential.Helper`, `CREDENTIAL.HELPER`), and a helper can be scoped to one URL
# (`credential.<url>.helper`, `credential.<host>.helper`), which re-enables it for exactly the host
# the session override was protecting.
GIT_CRED_HELPER_SET='credential(\.[^=[:space:];&|]+)?\.helper(=|[[:space:]]+)[^[:space:];&|]*[A-Za-z0-9][^[:space:];&|]*'
# A shell removes quotes and backslashes before git ever reads a word, so `-c 'credential.helper'=x`,
# `-c "credential".helper=x` and `-c credential.help\er=x` all set the same key. Every check in this
# block reads a copy of the command with those three characters removed, without regard to case (a
# case-insensitive disk runs `Git-Credential-<Name>` too).
cmd_bare=$(printf '%s' "$cmd" | tr -d "\"'\\\\")
# 2. The credential subsystem invoked DIRECTLY: `git credential fill/approve/reject/-C`, or a helper
# binary called by its own name (`git-credential-osxkeychain`, `git credential-manager`) -- there is no
# legitimate agent use for any of these; a seat that needs a credential uses its own AppRole path, not
# git's.
GIT_CRED_SUBCOMMAND="${GIT_SEG}credential([[:space:]]+(fill|approve|reject|-C)\\b|-[a-z0-9_-]+)"
# The helper binary is refused at ANY path: by bare name, `./<name>`, a full path into git-core, or
# `"$(git --exec-path)/<name>"`. A real helper prints the saved login on stdout. The name ends at the
# first character a file name does not hold, whatever it is: a space, a redirect (`<req`), a brace
# list, a backtick, or a glob standing in for the rest of the name (`git-credential-*`, `...chai?`).
# A dot is not such an end, so a file that merely starts with the same letters and carries an
# extension (a test named git-credential-<x>.test.sh, a doc) is not a helper call.
# One extension is part of a helper's own name on one OS: `git-credential-manager.exe`, in any case.
GIT_CRED_HELPER_BINARY='(^|[^A-Za-z0-9_-])git-credential-[a-z0-9_-]*(\.exe)?([^A-Za-z0-9_.-]|$)'
# An alias reaches the same subsystem under another name: `-c alias.k=credential-<name>`, then `git k`.
# Any alias whose value holds the word is refused, set on the command line or written to a config file.
GIT_CRED_ALIAS='alias\.[^=[:space:]]+(=|[[:space:]]+)[^;&|]*credential'
if printf '%s' "$cmd_bare" | grep -qiE "$GIT_CRED_HELPER_SET" \
   || printf '%s' "$cmd_bare" | grep -qiE "$GIT_CRED_SUBCOMMAND" \
   || printf '%s' "$cmd_bare" | grep -qiE "$GIT_CRED_HELPER_BINARY" \
   || printf '%s' "$cmd_bare" | grep -qiE "$GIT_CRED_ALIAS"; then
  deny git-credential-helper-use "this sets, unsets-to-a-value, or directly invokes a git credential helper, which would read or re-enable the operator's own saved login -- never an agent's to reach. Run this yourself if a helper genuinely needs changing."
fi

# 2b. PULLING ANOTHER CONFIG FILE IN at command scope: `-c include.path=<file>`,
# `-c includeIf.<condition>.path=<file>` and the `--config-env=` form of either. Command-scope config
# is read AFTER the session's own reset, so a helper named in the included file is live again, and the
# file can be the system gitconfig itself (no file is written at all). A bare read
# (`git config --get include.path`) is not this.
GIT_INCLUDE_KEY='(^|[[:space:]])(-c[[:space:]]*|--config-env[=[:space:]]+)(include\.path|includeif\..*\.path)([=[:space:]]|$)'
if printf '%s' "$cmd_bare" | grep -qiE "$GIT_INCLUDE_KEY"; then
  deny git-config-include "this pulls another config file in at command scope (include.path / includeIf), which is read after the session's own credential-helper reset and can re-enable a helper. Pass the one setting you need as its own \`git -c <key>=<value>\`."
fi

# 3. CLEARING THE ENVIRONMENT the session's own override lives in. `env -i` strips every variable
# from the command it wraps, `env -u <name>` one of them, and `exec -c` replaces the shell with a
# command run in an empty environment. Each re-exposes exactly the prompt the override exists to
# prevent. Refused by SHAPE, whatever the wrapped command or the variable is, because the spellings
# cannot be told apart by name: `env -uNAME` glues the name to the flag, `env -` is `-i`, and a
# cluster such as `-vi` hides the letter:
#   env with a lone `-`, a short-option cluster holding `i` or `u`, `--ignore-environment` or `--unset`
#   exec with a short-option cluster holding `c`
# Only env's OWN options count: the ones before the wrapped command's first word, so the `-i` of
# `env LC_ALL=C grep -i ...` and the `-u` of `env LC_ALL=C sort -u` are not this.
# Cost, accepted: `env -u <an unrelated variable> <command>` and `env -i <command>` are refused too.
# Read on the quote-stripped copy, like the key checks above.
ENV_OWN_ARG='(-[CPS][[:space:]]+[^[:space:];&|]+|-[^[:space:];&|]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*)'
ENV_CLEARS="(^|[^A-Za-z0-9_./-])env([[:space:]]+${ENV_OWN_ARG})*[[:space:]]+(-|-[A-Za-z0-9]*[iu][^[:space:];&|]*|--ignore-environment|--unset(=[^[:space:];&|]*)?)([[:space:];&|]|\$)"
if printf '%s' "$cmd_bare" | grep -qE "$ENV_CLEARS"; then
  deny env-strips-credential-override "this clears or unsets environment variables around a command (env with -, -i, -u or their long forms), which lifts the session's own git credential-helper override and re-exposes the operator's saved login. Set the one variable you need as NAME=value in front of the command instead, or run this yourself."
fi
EXEC_CLEARS='(^|[^A-Za-z0-9_./-])exec([[:space:]]+(-a[[:space:]]+[^[:space:];&|]+|-[A-Za-z]*))*[[:space:]]+-[A-Za-z]*c[A-Za-z]*([[:space:];&|]|$)'
if printf '%s' "$cmd_bare" | grep -qE "$EXEC_CLEARS"; then
  deny exec-clears-environment "this replaces the shell with a command run in an empty environment (exec -c), which drops the session's own git credential-helper override. Run the command without exec -c, or run this yourself."
fi

# 3b. ANY USE OF A GUARDED NAME EXCEPT READING IT. The session's override is five variable names. A
# shell has many ways to change a variable, and a rule that lists them (an assignment, export, unset)
# is one builtin behind for ever:
#   GIT_CONFIG_COUNT=0 git ...            export GIT_CONFIG_COUNT=0        unset GIT_CONFIG_COUNT
#   GIT_CONFIG_VALUE_0+=<helper>          export -n GIT_CONFIG_COUNT       declare +x / typeset +x
#   printf -v GIT_CONFIG_VALUE_0 <h>      read GIT_CONFIG_VALUE_0 <<< <h>  for GIT_CONFIG_VALUE_0 in <h>
#   local GIT_CONFIG_COUNT (in a function)                                 env GIT_CONFIG_COUNT=0 git ...
# So the rule is structural: one of the names as a WHOLE WORD anywhere in the command is refused,
# unless it is only being read, as `$NAME` or `${NAME...}`. Numbered names count with any number: a
# raised count makes KEY_1 and VALUE_1 live. GIT_CONFIG_PARAMETERS is the fifth name: it is what
# `git -c` itself exports, so setting it injects any key with no `-c` on the line at all.
# Refused on the VALUE too, not only the override-removing one: a legitimate tool's own
# `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory ...` silently drops the reset the same way, and
# this gate cannot tell intent from shape. `git -c <key>=<value>` is the one-off form that does not
# touch the session-wide override at all.
# Cost, accepted: a SEARCH for one of the names (`rg GIT_CONFIG_COUNT hooks/`), or a message that
# quotes one, is refused too. Search for a shorter stem (`GIT_CONFIG_`), and pass a message by file.
GIT_ENV_OVERRIDE_NAMES='GIT_CONFIG_COUNT|GIT_CONFIG_KEY_[0-9]+|GIT_CONFIG_VALUE_[0-9]+|GIT_TERMINAL_PROMPT|GIT_CONFIG_PARAMETERS'
# Reads are taken out first, in pure bash (no helper program whose absence would change the verdict).
cmd_names=$cmd_bare
GIT_ENV_READ_RX="[\$][{]?(${GIT_ENV_OVERRIDE_NAMES})"
while [[ "$cmd_names" =~ $GIT_ENV_READ_RX ]]; do
  cmd_names=${cmd_names/"${BASH_REMATCH[0]}"/}
done
GIT_ENV_NAME_RX="(^|[^A-Za-z0-9_])(${GIT_ENV_OVERRIDE_NAMES})([^A-Za-z0-9_]|\$)"
if printf '%s' "$cmd_names" | grep -qE "$GIT_ENV_NAME_RX"; then
  deny git-env-override-reassigned "this names one of the session's own git credential-helper override variables (GIT_CONFIG_COUNT, GIT_CONFIG_KEY_<n>, GIT_CONFIG_VALUE_<n>, GIT_TERMINAL_PROMPT, GIT_CONFIG_PARAMETERS) other than to read it. Any assignment, export, unset, read, printf -v, declare or loop over one of them lifts or replaces the override for later commands. Use \`git -c <key>=<value>\` for a one-off setting instead."
fi

# 4. A RAW https:// URL to one of the installation's OWN forges, inside a git invocation: this is the
# measured incident's own shape (`git ls-remote https://<forge>`), typed with an explicit URL rather
# than through the repo's already-configured remote. The host list is a PARAMETER from the adapter --
# $GOVERNANCE_OWN_FORGES (comma- or newline-separated), or a file at $GOVERNANCE_OWN_FORGES_FILE
# (default ~/.governance/own-forges, one host per line, `#` comments allowed) when that is unset -- the
# same env-var-then-dotfile convention id-provenance-gate.py's gated-tool list and redaction-check's
# own private-pattern list already use, for the same reason: a literal host name in core is a rule for
# every fleet, so it can never be core's own.  NOT a bare `git push`/`fetch`/`pull`/`clone` with no URL
# argument at all: that uses the remote already configured for the repo, which this check does not
# read and is unaffected (the measured incident's own command named an explicit URL).
# Read and joined in PURE BASH. An external program here (tr, grep, sed, paste) that a restricted PATH
# lacks leaves the list or its pattern empty, and the check then switches itself off without a word.
# A list file that EXISTS but is not a readable regular file (no read permission, a directory at the
# path) is a list that did not load, not "no list": it takes the fail-closed branch below.
OWN_FORGES=""
OWN_FORGES_UNREADABLE=0
if [[ -n "${GOVERNANCE_OWN_FORGES:-}" ]]; then
  OWN_FORGES=$GOVERNANCE_OWN_FORGES
else
  own_forges_file="${GOVERNANCE_OWN_FORGES_FILE:-$HOME/.governance/own-forges}"
  if [[ -e "$own_forges_file" || -L "$own_forges_file" ]]; then
    if [[ -f "$own_forges_file" && -r "$own_forges_file" ]]; then
      while IFS= read -r own_line || [[ -n "$own_line" ]]; do
        [[ "$own_line" =~ ^[[:space:]]*# ]] && continue
        OWN_FORGES+="$own_line "
      done < "$own_forges_file"
    else
      OWN_FORGES_UNREADABLE=1
    fi
  fi
fi
OWN_FORGES=${OWN_FORGES//,/ }
OWN_FORGES=${OWN_FORGES//$'\n'/ }
OWN_FORGES=${OWN_FORGES//$'\r'/ }
if [[ -n "${OWN_FORGES//[[:space:]]/}" || "$OWN_FORGES_UNREADABLE" == 1 ]]; then
  OWN_FORGES_RX=""
  read -r -a own_hosts <<< "$OWN_FORGES"
  for own_host in "${own_hosts[@]}"; do
    # A host is letters, digits, dots, hyphens, underscores and a port colon. Anything else is not a
    # host name and is left out, never turned into a pattern.
    [[ "$own_host" =~ ^[A-Za-z0-9._:-]+$ ]] || continue
    OWN_FORGES_RX+="${OWN_FORGES_RX:+|}${own_host//./\\.}"
  done
  GIT_HTTP_URL="${GIT_SEG}([^;&|]*[[:space:]])?https?://"
  if [[ -z "$OWN_FORGES_RX" ]]; then
    # The list is SET but no host in it could be read. Fail CLOSED: an explicit URL in a git call
    # cannot be checked against a list that did not load, so it is refused rather than waved through.
    if printf '%s' "$cmd_bare" | grep -qiE "$GIT_HTTP_URL"; then
      deny git-own-forge-list-unreadable "the installation's own-forge list is set but could not be read, or holds no host name, so an explicit http(s):// URL in a git call cannot be checked and is refused. Fix the list (host names, comma- or newline-separated), or use the repo's already-configured remote."
    fi
  # Wide on two axes. `https?://` -- the credential helper resolves for a PLAIN http:// remote too, not
  # only https. And userinfo -- `https://user@<host>/...` or `https://user:pass@<host>/...` -- matched
  # generically (anything but a slash, `@`, or whitespace, then `@`): the userinfo is only skipped over.
  # Read on the quote-stripped copy, like every check in this block: git receives the URL after the
  # shell has removed its quotes and backslashes, so `'https://<host>/x'`, `h''ttps://<host>/x` and
  # `https://<ho\st>/x` all name the same forge.
  elif printf '%s' "$cmd_bare" | grep -qiE "${GIT_HTTP_URL}([^/@[:space:];&|]*@)?($OWN_FORGES_RX)([^[:space:];&|]*)?"; then
    deny git-https-own-forge "this names an explicit http(s):// URL to one of the installation's own forges, which rides the operator's own credential helper if the session's own override has not reached this host. Use the repo's already-configured remote (a bare git push/fetch/pull/clone), or the forge's own API/MCP tools."
  fi
fi

# Block database destruction
if echo "$cmd" | grep -qiE '(DROP\s+(TABLE|DATABASE)|TRUNCATE\s+TABLE|DELETE\s+FROM\s+\w+\s*;?\s*(["'"'"']|$))'; then
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

# Block READING THE OPERATOR'S LIVE SECRET SESSION from an agent process. A measured incident: a
# dry-run lister, run through an agent's own sandboxed Bash shell, read an admin secret this way -- no
# value entered a model's context, but the read itself rode a session the agent never authenticated.
# The token-helper mechanism hands the operator's already-authenticated token to EVERY process running as the same OS
# user, so once an operator is logged in (bao/vault login -- outside CRED_MINT's own Bash exemption
# above, which exists for LOGIN specifically, a "legitimate blind pipeline"), any later agent command
# that reads a secret or reveals the token rides that same live session with no new presence check at
# all. CRED_MINT refuses MINTING a token; this refuses READING one or what it unlocks, which has no
# comparable blind-pipeline exception -- so, unlike CRED_MINT, this is NOT scoped to tool != Bash.
#
# NO ALLOW RULE, on purpose. A draft of this check skipped both refusals whenever the command named a
# seat's own credential script. It was matched against the WHOLE command, so a mention anywhere (after
# a `;`, inside a comment) switched the refusals off for everything else on the line. A seat's own
# machine-identity path needs no exemption: it never runs these subcommands as text this gate reads.
# An installation whose own wrapper does spells its exemption in its adapter, for that one
# sub-command, never by a name that may sit anywhere in the command.
#
# Matched on the flattened, LOWER-CASED text: the default macOS disk is case-insensitive, so `BAO` runs
# `bao`. The words may be joined by what a list-form argv puts between them (quotes, commas,
# backslashes) as well as by spaces, so `["bao","kv","get",...]` inside an interpreter is the same
# read. Only the tool's own options may sit between the tool word and the subcommand:
# `vault policy read` is a policy definition, not a secret. Best effort, not a parser: a tool word or
# subcommand assembled at run time is not seen.
#   kv get/read and the legacy bare read (a secret's VALUE); unwrap (it reads a wrapped secret); the
#   two commands that reveal the RESOLVED token (print token, token lookup); and token create, which
#   prints a child of the operator's own token (CRED_MINT above exempts the Bash tool for a
#   stdin-fed LOGIN; there is no such case for minting from a session the agent never opened).
# NOT refused: a names-only listing (`kv list`, `list`, `kv metadata get|list`). It shows which paths
# exist, never a value, and an agent checks a path is present before asking for it to be seeded.
# NOT CLOSED: a `write <path>` that returns secret material (a transit decrypt, an AppRole secret-id,
# auth/token/create): a write is not a read by shape, and the paths are installation-specific.
osr_flat=$(printf '%s' "$scan" | tr '\n\r' '  ' | tr '[:upper:]' '[:lower:]')
# A second copy with quotes and backslashes removed: `b''ao` and `b\ao` run the same binary, and a
# list-form argv still reads `[bao,kv,get` there, so the comma keeps joining the words.
osr_bare=$(printf '%s' "$osr_flat" | tr -d "\"'\\\\")
OSR_SEP="[[:space:]\"',\\]"
OSR_WORD="[^[:space:]\"',\;&|]"
OPERATOR_SECRET_READ="(^|[^a-z0-9_-])(bao|vault)(${OSR_SEP}+-${OSR_WORD}+)*${OSR_SEP}+(kv${OSR_SEP}+(get|read)|read|unwrap|print${OSR_SEP}+token|token${OSR_SEP}+(lookup|create))([^a-z0-9_-]|\$)"
if printf '%s' "$osr_bare" | grep -qE "$OPERATOR_SECRET_READ"; then
  deny operator-secret-read "this reads a secret, or reveals or mints from the resolved token, through the bao/vault CLI, which would ride the operator's own live session if one is open -- every process running as this user shares it, with no new presence check. Use the seat's own machine-identity credential path, or ask the human to run this themselves."
fi

# The token-helper's own token file, read directly: the same shape as the secret-file rule above (a
# reader verb and the file name in ONE sub-command), with a wider verb list, because a token file is a
# single line that any filter prints whole (sed, awk, base64, xxd, od, strings, cut), a copy moves out
# of reach of this rule (cp, dd), and an input redirect hands it to any program at all. Lower-cased for
# the same reason as above. Best effort: a reader this list does not name is not seen. NOT CLOSED by
# this: executing the CONFIGURED token_helper script itself (its path is host-specific, so a public
# core cannot name it -- an organisation's own adapter should gate its own path, the same convention
# CRED_MINT's own comment states for a private login wrapper); and a VAULT_TOKEN/BAO_TOKEN env var the
# agent's process merely INHERITS from an already-authenticated parent shell, which never appears as
# text in the command this gate reads at all.
osr_lines=$(printf '%s' "$scan" | tr '[:upper:]' '[:lower:]')
VAULT_TOKEN_NAME='\.(vault|bao)-token\b'
VAULT_TOKEN_VERBS='cat|grep|rg|head|tail|less|more|sed|awk|base64|xxd|od|strings|cut|cp|dd'
VAULT_TOKEN_READ="(^|[^a-z0-9_-])(${VAULT_TOKEN_VERBS})\s+.*${VAULT_TOKEN_NAME}|<\s*[^ ;&|<>]*${VAULT_TOKEN_NAME}"
if printf '%s' "$osr_flat" | grep -qE "$VAULT_TOKEN_READ" && ! only_across_subcommands "$osr_lines" "$VAULT_TOKEN_READ"; then
  deny operator-token-file-read "this reads the token helper's own token file, which holds the operator's live session token if one is open -- every process running as this user shares it, with no new presence check. Use the seat's own machine-identity credential path, or ask the human to run this themselves."
fi

# Credential-store reads. Two failures this rule had, both measured against a reference case list: it
# needed the tool word DIRECTLY before the subcommand, case-sensitively, so a list-form argv inside an
# interpreter wrapper, padding between the two, or the tool spelled in capitals (the default macOS disk
# is case-insensitive) all passed; and it knew two subcommands, so a whole-keychain dump and a `keyring`
# library read passed with no tool word to find. So: the SUBCOMMAND WORD ALONE refuses, anywhere in the
# flattened, lower-cased text, with no tool word and no proximity required; and a keyring READ call
# refuses on its own. Best effort, not a parser: a subcommand assembled at run time is not seen.
# Cost, accepted: a command that only MENTIONS one of these words (a grep, a commit -m) is refused too;
# search by the rule id, and pass a message by file.
# `export` (it writes items, private keys included, to a file) is too common a word to refuse alone, so
# it refuses only after the store's tool word, within a short run (40 characters) holding no command
# separator: the tool's own global options (`-v`, `-q`, `-p x`), a list-form argv and a line
# continuation are caught; a shell `export` after `;`, `&&` or `|` is not.
kc=$(printf '%s' "$cmd" | tr '\n\r' '  ' | tr '[:upper:]' '[:lower:]')
if printf '%s' "$kc" | grep -qE '(^|[^a-z0-9_-])(find-generic-password|find-internet-password|dump-keychain)([^a-z0-9_-]|$)' \
   || printf '%s' "$kc" | grep -qE '(^|[^a-z0-9_-])security[^a-z0-9_;&|-]([^;&|]{0,40}[^a-z0-9_-])?export([^a-z0-9_-]|$)'; then
  deny keychain-read "Keychain access would expose secrets to the AI context. Keychain reads belong in runtime code only, not in development commands."
fi
if printf '%s' "$kc" | grep -qE '(^|[^a-z0-9_])keyring([^a-z0-9_]|$)' \
   && printf '%s' "$kc" | grep -qE 'get_password|get_credential|keyring[[:space:]]+get([^a-z0-9_]|$)'; then
  deny keyring-read "Keychain access through a keyring library would expose secrets to the AI context. Credential-store reads belong in runtime code only, not in development commands."
fi

if echo "$cmd" | grep -qE 'docker\s+(exec|inspect).*env|docker\s+(exec|inspect).*\.env|docker\s+(exec|inspect).*secret|docker\s+(exec|inspect).*token|docker\s+(exec|inspect).*password'; then
  deny container-secret-read "Extracting secrets from containers would expose them to the AI context. Use Secure Handoff instead."
fi

if echo "$cmd" | grep -qE 'printenv|/proc/.*/environ'; then
  deny process-env-read "Reading process environment would expose secrets to the AI context."
fi

# zsh expansion traps (#181). An inline command runs under the harness's shell, usually the user's login
# shell, and in zsh two ordinary bash idioms do something else. Both are already prose rules (technical.md,
# "the SHELL an agent's command runs in"), and both kept recurring, which is the case for a gate:
#   - `$name:<letter>` is a MODIFIER, even inside double quotes: `"$H:refs/heads/x"` loses its `:r`.
#   - an unquoted `$name` is NOT word-split, so a variable holding a space-separated list reaches the
#     command as ONE argument. A grep over two directories then exits 2 on a path that does not exist,
#     and with its stderr discarded that reads as a clean zero.
# Scoped to a zsh harness shell: `$SHELL`, or `GOVERNANCE_HARNESS_SHELL` where a harness runs another
# shell than the login one. Both fixes it asks for (brace the name; use an array, or quote) are correct
# in bash too, so a refusal on a mis-detected shell costs one edit, never a wrong command. A script run
# by path is unaffected: it runs under its shebang, and this gate never sees its contents. Fails OPEN
# without python3: this check catches mistakes; it is not a security control.
harness_shell="${GOVERNANCE_HARNESS_SHELL:-${SHELL:-}}"
if [[ "${harness_shell##*/}" == "zsh" ]] && command -v python3 >/dev/null 2>&1; then
  zsh_trap=$(python3 - "$cmd" <<'PY' 2>/dev/null
import re, sys
cmd = sys.argv[1]
MARK = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*(?:(\\)?([A-Za-z_]\w*)|'([A-Za-z_]\w*)'|\"([A-Za-z_]\w*)\")")

def blank_heredocs(text, quoted_only):
    """Heredoc bodies blanked. A QUOTED body is expanded by no shell. An unquoted body is expanded by
    THIS shell (zsh) while it is built, so it keeps its modifiers; no body is ever word-split."""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        out.append(lines[i])
        marks = list(MARK.finditer(lines[i]))
        if len(marks) != 1:
            i += 1
            continue
        m = marks[0]
        tag = m.group(3) or m.group(4) or m.group(5)
        quoted = bool(m.group(2) or m.group(4) or m.group(5))
        j = i + 1
        while j < len(lines) and (lines[j].lstrip("\t") if m.group(1) else lines[j]) != tag:
            j += 1
        if j == len(lines) or (quoted_only and not quoted):
            i += 1
            continue
        out += [""] * (j - i - 1) + [lines[j]]
        i = j + 1
    return "\n".join(out)

def states(text):
    """Per character: N unquoted, D inside double quotes, S never expanded (single-quoted, escaped, or
    a comment)."""
    st, q, i, word_start = [], None, 0, True
    while i < len(text):
        c = text[i]
        if q is None:
            if c == "\\":
                st += ["S", "S"]; i += 2; word_start = False; continue
            if c == "#" and word_start:
                while i < len(text) and text[i] != "\n":
                    st.append("S"); i += 1
                continue
            if c == "'" or (c == "$" and text[i + 1:i + 2] == "'"):
                n = 2 if c == "$" else 1
                j = text.find("'", i + n)
                j = len(text) - 1 if j < 0 else j
                st += ["S"] * (j - i + 1); i = j + 1; word_start = False; continue
            if c == '"':
                q = '"'; st.append("D"); i += 1; word_start = False; continue
            st.append("N"); word_start = c in " \t\n;&|()"; i += 1; continue
        if c == "\\" and text[i + 1:i + 2] in ('$', '"', "\\", "`"):
            st += ["S", "S"]; i += 2; continue
        if c == '"':
            q = None
        st.append("D"); i += 1
    return st[:len(text)]

# 1. `$name:<modifier>`, unbraced, wherever this shell expands it.
a = blank_heredocs(cmd, quoted_only=True)
sa = states(a)
for m in re.finditer(r"\$([A-Za-z_][A-Za-z0-9_]*|[0-9]):([aAcehlPqQrstux&])", a):
    if sa[m.start()] in "ND":
        print(f"modifier\t{m.group(1)}\t{m.group(2)}")
        sys.exit(0)

# 2. An unquoted expansion of a variable that this same command assigned a literal holding whitespace.
b = blank_heredocs(cmd, quoted_only=False)
sb = states(b)
ASSIGN = re.compile(r"(?:^|(?<=[\s;&|(]))(?:(?:export|local|typeset|declare|readonly)\s+)?"
                    r"([A-Za-z_]\w*)=(\"(?:[^\"\\]|\\.)*\"|'[^']*')")
spaced = {}
for m in ASSIGN.finditer(b):
    if sb[m.start(1)] == "N" and re.search(r"\s", m.group(2)[1:-1]):
        spaced.setdefault(m.group(1), m.end())
for name, after in spaced.items():
    for m in re.finditer(r"\$(?:%s(?![A-Za-z0-9_])|\{%s\})" % (name, name), b):
        if m.start() < after or sb[m.start()] != "N":
            continue
        seg = re.split(r"&&|\|\||[;|&\n(`]|\$\(", b[:m.start()])[-1]
        words = [w for w in seg.split() if not re.match(r"[A-Za-z_]\w*=", w)]
        if not words:
            continue            # the right-hand side of an assignment is never split, in either shell
        if words[0] in ("echo", "print", "printf"):
            continue            # output reads the same as one argument or as several
        print(f"split\t{name}")
        sys.exit(0)
PY
)
  case "$zsh_trap" in
    modifier*)
      IFS=$'\t' read -r _ zname zmod <<<"$zsh_trap"
      deny zsh-modifier "zsh reads \`\$${zname}:${zmod}\` as the \`:${zmod}\` modifier, even inside double quotes, and edits the value. Brace the name: \`\${${zname}}:…\`." ;;
    split*)
      IFS=$'\t' read -r _ zname <<<"$zsh_trap"
      deny zsh-no-word-split "zsh does not word-split an unquoted \`\$${zname}\`: it holds spaces, so it reaches the command as ONE argument. For several, use an array, ${zname}=(a b) and \"\${${zname}[@]}\"; for one, quote it, \"\$${zname}\"." ;;
  esac
fi

exit 0
