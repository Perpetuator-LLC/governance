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

# Block TURNING ON SSH connection multiplexing (governance#433). While a connection master stays open,
# every process running as this user reaches the host over the already-authenticated connection, with
# no new presence check — one touch on a presence-gated key (a hardware or secure-enclave key) then
# authorizes every later command that rides the same master, including one from a different session on
# the same account. Checked wherever ssh is invoked, including through git's own wrapper
# (GIT_SSH_COMMAND, `-c core.sshCommand=`, a committed `core.sshCommand`).
#
# cisa SEND-BACK on PR #438 (c189241): a PLAIN ssh/git call is only safe if NOTHING already makes it
# multiplex — a user-level `Host *` block with `ControlMaster auto` turns every allowed plain call into
# one that opens or rides a master, with no flag on the command line at all. The command line alone can
# never answer this; only ssh's OWN config resolution can (`ssh -G`, print-only, no connection — this
# runs for every PLAIN call too, not only a suspicious-looking one). The command line IS still the only
# source for -M and -O, which are MODE switches, never configuration values `ssh -G` would report.
#
# Not closed by this (recorded, not fixed — a regex/subprocess gate is not a shell, and changing the
# user's own ssh config is a human decision, not this gate's to make):
#   - `ssh -F <file>` is read and passed to `ssh -G`; `GIT_SSH=<wrapper>` (an external, unreadable
#     script) and a Write/Edit to the user's own ssh config file are not.
#   - a bare `git push`/`pull`/`fetch`/`clone` with NO ssh override at all: resolving its real target
#     needs the repo's OWN remote configuration, which this gate does not read. Only an EXPLICIT ssh
#     invocation — bare `ssh`, or one embedded in GIT_SSH_COMMAND/core.sshCommand — is evaluated.
#
# Cheap gate first: a command naming none of these is not an ssh invocation in any form this check
# recognises, so an unrelated command never reaches the subprocess call below.
SSH_INVOKE_HINT='(^|[[:space:];&|])ssh([[:space:]]|$)|GIT_SSH_COMMAND=|core\.sshcommand'
if printf '%s' "$cmd" | tr '\n\r' '  ' | grep -qiE "$SSH_INVOKE_HINT"; then
  if command -v python3 >/dev/null 2>&1; then
    ssh_mux_reason=$(python3 - "$cmd" <<'PY'
import re, shlex, subprocess, sys

cmd = sys.argv[1]

# ssh's OWN getopt shape (ssh(1)): a boolean flag takes no argument and may be BUNDLED with others in
# one token (`-fNM` = -f -N -M); an argument-flag's value is either the REST of its own token
# (`-S/path`, attached) or, if nothing follows it in that token, the NEXT token (`-S /path`). Only ONE
# argument-flag may end a bundle, matching real getopt: `-fNMS/path` is -f -N -M -S=/path.
BOOL_FLAGS = set("46AaCfGgKkMNnqsTtVvXxYy")
ARG_FLAGS = set("BbcDEeFIiJLlmOopQRSWw")
SEP = {"&&", "||", ";", "|", "&", "|&", "\n"}


def tokenize(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars="();<>|&\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""  # a bare "#" is only a comment at the START of a word in a real shell
    return list(lex)


def segments(toks):
    segs, cur = [], []
    for t in toks:
        if t in SEP:
            segs.append(cur)
            cur = []
        else:
            cur.append(t)
    segs.append(cur)
    return segs


def parse_ssh_opts(argv):
    """argv: tokens AFTER the leading 'ssh'. -> (bool flags seen, {arg-flag: [values]}, target|None)."""
    bools, args, i, target = set(), {}, 0, None
    while i < len(argv):
        tok = argv[i]
        if tok == "--":
            i += 1
            break
        if len(tok) > 1 and tok[0] == "-":
            j = 1
            while j < len(tok):
                c = tok[j]
                if c in BOOL_FLAGS:
                    bools.add(c)
                    j += 1
                    continue
                if c in ARG_FLAGS:
                    rest = tok[j + 1:]
                    if rest:
                        args.setdefault(c, []).append(rest)
                    elif i + 1 < len(argv):
                        i += 1
                        args.setdefault(c, []).append(argv[i])
                    break
                break  # an unrecognised flag char: stop scanning this token, best effort
            i += 1
            continue
        target = tok
        i += 1
        break
    return bools, args, target


def opt_text_values(args, name):
    """Values set for `-o NAME=value` or `-o NAME value` among already-parsed -o entries, matched on
    the key case-insensitively. These are LITERAL text on this command line — checked even with no
    target at all, since an embedded GIT_SSH_COMMAND/core.sshCommand wrapper never carries one (git
    appends the destination itself at invocation time), so `ssh -G` has nothing to resolve against for
    that text alone, and the override would otherwise never be seen."""
    out = []
    for o in args.get("o", []):
        if "=" in o:
            k, v = o.split("=", 1)
        else:
            parts = o.split(None, 1)
            k, v = (parts[0], parts[1]) if len(parts) == 2 else (parts[0], "")
        if k.strip().lower() == name.lower():
            out.append(v.strip().lower())
    return out


def ssh_invocation_mux(argv, label):
    """argv includes the leading 'ssh'. -> a refusal reason, or None if safe."""
    bools, args, target = parse_ssh_opts(argv[1:])
    if "M" in bools:
        return f"{label}: -M opens a connection master"
    # -O is a control command, not configuration; "exit" (closing) exempts the -S check below for
    # THIS SAME ssh call only — a different ssh call elsewhere in the command line gets its own,
    # independent check, never exempted by an -O exit that belongs to a different invocation.
    has_o_exit = "exit" in [v.lower() for v in args.get("O", [])]
    # "-S none" explicitly turns reuse OFF (ssh(1)'s own documented escape hatch, the command-line
    # mirror of "ControlPath none" below) — coa SEND-BACK on PR #438, c189310 non-blocking note.
    s_values = [v.strip().lower() for v in args.get("S", [])]
    if s_values and not has_o_exit and any(v != "none" for v in s_values):
        return f"{label}: -S reuses or targets a connection master (no -O exit on this same call)"
    if any(v in ("yes", "auto", "ask", "autoask", "true") for v in opt_text_values(args, "ControlMaster")):
        return f"{label}: -o ControlMaster is set to open a master"
    if any(v != "none" for v in opt_text_values(args, "ControlPath")):
        return f"{label}: -o ControlPath is set to keep a master open"
    if any(v not in ("no", "false") for v in opt_text_values(args, "ControlPersist")):
        return f"{label}: -o ControlPersist is set to keep a master open"
    if not target:
        return None  # no destination at all: ssh itself refuses; nothing further here to evaluate
    # `ssh -G` prints the EFFECTIVE config (command-line overrides merged with every config file ssh
    # would read) and makes NO connection. Command-line -F/-o are passed through so the same overrides
    # this call would actually use are the ones evaluated — never a DIFFERENT, unrelated config. This
    # is what catches an INHERITED Host * block this command line never mentions at all (cisa SEND-BACK
    # on PR #438, c189241 item 1) — the direct -o checks above cover only what THIS line spells out.
    ssh_g = ["ssh", "-G"]
    for f in args.get("F", []):
        ssh_g += ["-F", f]
    for o in args.get("o", []):
        ssh_g += ["-o", o]
    ssh_g.append(target)
    try:
        out = subprocess.run(ssh_g, capture_output=True, text=True, timeout=5)
    except Exception as e:
        return f"{label}: could not evaluate the effective ssh config to verify it is safe ({e})"
    if out.returncode != 0:
        return f"{label}: `ssh -G` could not evaluate the effective config for this destination"
    cfg = {}
    for line in out.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            cfg.setdefault(parts[0].lower(), parts[1].strip().lower())
    if cfg.get("controlmaster", "no") not in ("no", "false"):
        return f"{label}: the effective ssh config's ControlMaster is {cfg.get('controlmaster')!r}, not off"
    if cfg.get("controlpath", "none") != "none":
        return f"{label}: the effective ssh config's ControlPath is {cfg.get('controlpath')!r}, not none"
    if cfg.get("controlpersist", "no") not in ("no", "false"):
        return f"{label}: the effective ssh config's ControlPersist is {cfg.get('controlpersist')!r}, not off"
    return None


def embedded_ssh_argv(value):
    """value: a shell command STRING (from GIT_SSH_COMMAND, or -c core.sshCommand=). -> argv or None."""
    try:
        toks = tokenize(value)
    except ValueError:
        return None
    return toks if toks and toks[0] == "ssh" else None


try:
    cmd_toks = tokenize(cmd)
except ValueError:
    print("the command could not be tokenised to verify it is safe")
    sys.exit(1)

reason = None
for seg in segments(cmd_toks):
    if not seg:
        continue
    if seg[0] == "ssh":
        reason = ssh_invocation_mux(seg, "ssh")
    else:
        for i, t in enumerate(seg):
            if t.startswith("GIT_SSH_COMMAND="):
                argv = embedded_ssh_argv(t[len("GIT_SSH_COMMAND="):])
                if argv:
                    reason = ssh_invocation_mux(argv, "GIT_SSH_COMMAND")
                break
            if t == "-c" and i + 1 < len(seg) and seg[i + 1].lower().startswith("core.sshcommand="):
                argv = embedded_ssh_argv(seg[i + 1].split("=", 1)[1])
                if argv:
                    reason = ssh_invocation_mux(argv, "core.sshCommand")
                break
    if reason:
        break

if reason:
    print(reason)
    sys.exit(1)
sys.exit(0)
PY
)
    if [[ $? -ne 0 ]]; then
      deny ssh-mux-on "Turning on SSH connection multiplexing, or an inherited ssh config that already does ($ssh_mux_reason), bypasses a presence-gated key's per-use touch for every later command that rides the same master. Use a plain ssh/git push under a config with ControlMaster=no / ControlPath=none / ControlPersist=no, or close a master with -O exit on that same call."
    fi
  else
    # Without python3 there is no way to parse ssh's own getopt-bundled flags, decode an embedded
    # GIT_SSH_COMMAND/core.sshCommand, or run `ssh -G` to see the EFFECTIVE config at all — and per
    # item 1 above, even a plain, flagless ssh/git call can already be multiplexing via inherited
    # config. Every ssh invocation this gate recognises is refused outright rather than allowed
    # unverified: the same "every doubt keeps the block" direction this file takes everywhere else.
    deny ssh-mux-unverifiable "this safety gate cannot verify an SSH invocation's effective multiplexing config is safe without python3; refusing rather than allowing it unchecked. Install python3, or run the command yourself."
  fi
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
