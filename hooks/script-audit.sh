#!/bin/bash
# Hook: PreToolUse[Bash] — Audit agent-run SCRIPTS by capturing their content before execution.
#
# Why: shell history records `bash foo.sh` / `python3 deploy.py` / `node run.js` but NOT what the
# file contained. When an agent writes-then-runs a script (the sanctioned pattern for complex flows —
# `set -e` lives in a file, not a pasted block), the file may be transient and the actual steps
# become invisible. This recorder closes that blind spot: it appends each executed script's content
# to a local audit log the moment before it runs.
#
# Covers shell (bash/sh/zsh/dash + source/.), python (python/python2/python3), and node, plus direct
# execution in COMMAND position (argv[0] of a simple command: `./x`, `../x`, or a recognizable file
# *.sh *.py *.js *.mjs *.cjs *.ts). An argument such as `wc -l ./creds.ini` or `cp ./x.sh /y` is not
# executed, so it is never a candidate (governance#274: that heuristic copied credential files).
#
# Contract:
#   - Exit 0 ALWAYS. This is an audit recorder, never a gate — it must never block a tool call
#     and never fail the command (the safety gate is bash-safety-gate.sh's job).
#   - Emits NOTHING to stdout. Script content must not enter the agent context (secret-ban spirit);
#     it goes only to the on-disk log.
#   - Best-effort: file-based scripts only. Inline heredocs (`bash <<EOF … EOF`) are already fully
#     present in the command string, so they need no capture here.
#
# Secrets (governance#274): the content of a `source`/`.` target (dotenv files are sourced, not run)
# and of any file whose name is on the credential list (.env*, .envrc, *.pem, *.key, id_*, *secret*,
# *token*, credentials*, .netrc, ~/.ssh/, ~/.aws/ ...) is NEVER copied. Its record holds only
# path + sha256 + size.
#
# Log: ~/.claude/audit/scripts.log  (local-only, never transmitted). Dir 700, log and .1 are 600
# (umask 077; a chmod on every run fixes older 644 files). Retention, per the governance#274 rulings:
#   - rotate to .1 when the log is over 5MB, OR its FIRST entry's timestamp is over 30 days old
#     (not mtime: every append refreshes it). A log with content whose first timestamp is missing or
#     unparseable rotates (fail closed). An empty or whitespace-only log never rotates.
#   - one generation: rotation replaces .1 outright, no .2.
#   - .1 is deleted once its mtime is over 30 days old (it is never written after rotation), checked
#     on EVERY invocation, including one that logs nothing.

umask 077   # every file this hook creates is 0600 and every dir 0700, before the first write
set -f      # the command text is split unquoted below; never let a glob in it expand to cwd files

AUDIT_DIR="$HOME/.claude/audit"
LOG="$AUDIT_DIR/scripts.log"
MAX_AGE_S=2592000   # 30 days

# .1 age cap: runs on every invocation, before any early exit (governance#274 c100156). One stat.
if [[ -f "$LOG.1" ]] && [[ -n "$(find "$LOG.1" -maxdepth 0 -mmin +$((MAX_AGE_S / 60)) 2>/dev/null)" ]]; then
  rm -f "$LOG.1" 2>/dev/null
fi
for f in "$LOG" "$LOG.1"; do [[ -f "$f" ]] && chmod 600 "$f" 2>/dev/null; done

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
cmd=$(tool_field "$input" .tool_input.command .toolInput.command)
[[ -z "$cmd" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && cmd=$(tool_field "$CLAUDE_TOOL_INPUT" .command)
[[ -z "$cmd" ]] && exit 0

# --- Extract candidate script paths ------------------------------------------------------------
# Cases: interpreter invocation (`bash|sh|zsh|dash|python|python3|node` + optional flags + file),
# sourcing (`source file` / `. file`, recorded hash-only), and direct execution of the command word
# (`./x`, `../x`, any recognizable script file). Command separators (; | & ( ) newline) reset the
# command position; redirections (< >) are flattened to spaces.
declare -a candidates=()
declare -A sourced=()
armed=0; armed_src=0; cmdpos=1
for tok in $(printf '%s\n' "$cmd" | tr ';|&()\n<>' ';;;;;;  ' | sed 's/;/ ; /g'); do
  if [[ "$tok" == ";" ]]; then cmdpos=1; armed=0; continue; fi
  if [[ "$tok" =~ ^(bash|sh|zsh|dash|source|\.|python|python2|python3|node)$ ]]; then
    armed=1; cmdpos=0
    if [[ "$tok" == source || "$tok" == . ]]; then armed_src=1; else armed_src=0; fi
    continue
  fi
  if [[ $armed -eq 1 ]]; then
    [[ "$tok" == -* ]] && continue      # skip interpreter flags (bash -x foo.sh, python3 -u x.py), stay armed
    candidates+=("$tok")
    [[ $armed_src -eq 1 ]] && sourced[$tok]=1
    armed=0
    continue
  fi
  if [[ $cmdpos -eq 1 ]]; then
    [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue   # a leading VAR=val keeps command position
    cmdpos=0
    # direct execution of the command word: a relative path, or a recognizable script file
    if [[ "$tok" == ./* || "$tok" == ../* \
          || "$tok" == *.sh || "$tok" == *.py \
          || "$tok" == *.js || "$tok" == *.mjs || "$tok" == *.cjs || "$tok" == *.ts ]]; then
      candidates+=("$tok")
    fi
  fi
done

[[ ${#candidates[@]} -eq 0 ]] && exit 0

# A credential-looking name is hash-only even as an interpreter target (`bash ./id_rsa`): the list
# write-safety-gate.sh guards, plus the dotfiles that hold tokens.
is_secret_path() {
  local p="${1,,}" b="${1##*/}"; b="${b,,}"
  [[ "$p" =~ (^|/)\.(ssh|aws|gcloud|gnupg|docker|kube)/ ]] && return 0
  [[ "$b" =~ ^(\.env(\..*)?|\.envrc|\.netrc|\.npmrc|\.pypirc|\.pgpass|\.vault-pass|id_.*|credentials.*|.*creds.*|.*secret.*|.*token.*|.*\.(pem|key|p12|pfx|jks))$ ]]
}
sha256_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | awk '{print $1; exit}'; }
to_epoch() {  # ISO-8601 UTC -> epoch seconds (GNU or BSD date); empty when unparseable
  local e
  e=$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null)
  [[ "$e" =~ ^[0-9]+$ ]] && printf '%s' "$e"
}

# --- Record -----------------------------------------------------------------------------------
mkdir -p "$AUDIT_DIR" 2>/dev/null
chmod 700 "$AUDIT_DIR" 2>/dev/null

# Rotate, keeping one generation (mv -f replaces the old .1 outright, so there is never a .2).
# Triggers: over ~5MB; the first entry is over 30 days old; or a log with content has no parseable
# first timestamp (fail closed). An empty or whitespace-only log has nothing to age out: no rotation.
if [[ -f "$LOG" ]]; then
  rotate=0
  if [[ "$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')" -gt 5242880 ]]; then
    rotate=1
  elif grep -q '[^[:space:]]' "$LOG" 2>/dev/null; then
    first=$(head -n 1 "$LOG" 2>/dev/null)
    e0=""
    [[ "$first" =~ ^=====\ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\ \| ]] \
      && e0=$(to_epoch "${BASH_REMATCH[1]}")
    if [[ -z "$e0" ]] || (( $(date -u +%s) - e0 > MAX_AGE_S )); then rotate=1; fi
  fi
  if [[ $rotate -eq 1 ]]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null
    chmod 600 "$LOG.1" 2>/dev/null
  fi
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
declare -A seen=()
for f in "${candidates[@]}"; do
  [[ -n "${seen[$f]}" ]] && continue    # dedup within a single command
  seen[$f]=1
  [[ -f "$f" && -r "$f" ]] || continue   # unresolved ($VAR, missing, cd'd-away) → skip silently
  [[ -f "$LOG" ]] || { : > "$LOG"; chmod 600 "$LOG"; } 2>/dev/null
  sha=$(sha256_of "$f")
  if [[ -n "${sourced[$f]}" ]] || is_secret_path "$f"; then
    why=credential-name; [[ -n "${sourced[$f]}" ]] && why=sourced
    size=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
    {
      echo "===== ${ts} | cwd=${PWD} | script=${f} | sha256=${sha} | size=${size} | content withheld (${why}) ====="
      echo
    } >> "$LOG" 2>/dev/null
    continue
  fi
  {
    echo "===== ${ts} | cwd=${PWD} | script=${f} | sha256=${sha} ====="
    cat "$f"
    echo "===== end ${f} ====="
    echo
  } >> "$LOG" 2>/dev/null
done

exit 0
