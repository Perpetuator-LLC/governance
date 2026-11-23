#!/usr/bin/env bash
# tests/ssh-mux-gate.test.sh — bash-safety-gate's SSH-multiplexing check (governance#433): refuse
# turning ON a connection master (-M, ControlMaster=yes/auto/ask/autoask), keeping one open
# (ControlPath other than none, ControlPersist other than no), or reusing one (-S, unless paired with
# the close-only -O exit) — on a bare ssh invocation or through git's own SSH wrapper. A plain ssh or
# git push, and the explicit "off" spellings, stay allowed.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

. "$ROOT/tests/lib/shim-path.sh"

payload() {  # payload <command> -> the hook's stdin JSON
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

run() {  # run <command> [<PATH>] -> exit code; stderr captured in $TMP/err
  local cmd="$1" path="${2:-$PATH}"
  printf '%s' "$(payload "$cmd")" | PATH="$path" bash "$GATE" >/dev/null 2>"$TMP/err"
}

check_blocked() {  # check_blocked <command> <label>
  run "$1"; local rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/err" \
    && pass "$2: blocked" || fail "$2: NOT blocked (rc=$rc) — $(cat "$TMP/err")"
}
check_allowed() {  # check_allowed <command> <label>
  run "$1"; local rc=$?
  [[ "$rc" == "0" ]] && pass "$2: allowed" || fail "$2: blocked (should be allowed) — $(cat "$TMP/err")"
}

echo "── ssh-mux-gate: refuse turning multiplexing ON"

echo " · opening a master"
check_blocked 'ssh -M host' "ssh -M"
check_blocked 'ssh -o ControlMaster=yes host' "ControlMaster=yes"
check_blocked 'ssh -o ControlMaster=auto host' "ControlMaster=auto"
check_blocked 'ssh -o ControlMaster=ask host' "ControlMaster=ask"
check_blocked 'ssh -o ControlMaster=autoask host' "ControlMaster=autoask"
check_blocked 'ssh -oControlMaster=auto host' "ControlMaster=auto, no space before -o's value"
check_blocked 'ssh -o "ControlMaster yes" host' "ControlMaster yes (space form, quoted)"

echo " · keeping one open"
check_blocked 'ssh -o ControlPath=/tmp/%r@%h:%p host' "ControlPath=<socket path>"
check_blocked 'ssh -o ControlPersist=600 host' "ControlPersist=600 (a kept-open duration)"
check_blocked 'ssh -o ControlPersist=yes host' "ControlPersist=yes"

echo " · reusing an existing master"
check_blocked 'ssh -S /tmp/sock host' "ssh -S <path>, no -O exit"
check_blocked 'ssh -S /tmp/sock -O forward host' "ssh -S <path> -O forward (not the close-only exit)"

echo " · through git's own SSH wrapper"
check_blocked 'GIT_SSH_COMMAND="ssh -o ControlMaster=auto" git push' "GIT_SSH_COMMAND"
check_blocked "git -c core.sshCommand='ssh -o ControlMaster=auto' push" "git -c core.sshCommand="

echo "── ssh-mux-gate: the safe direction stays allowed"
check_allowed 'ssh host ls' "a plain ssh invocation, no flags at all"
check_allowed 'git push origin main' "a plain git push"
check_allowed 'ssh -o ControlMaster=no host' "ControlMaster=no"
check_allowed 'ssh -o ControlPath=none host' "ControlPath=none"
check_allowed 'ssh -o ControlPersist=no host' "ControlPersist=no"
check_allowed 'ssh -O exit -S /tmp/sock host' "ssh -O exit (closing a master)"
check_allowed 'ssh -o StrictHostKeyChecking=no host' "an unrelated -o option is never mistaken for one of these"

echo "── control: the gate without python3 fails CLOSED on a command that mentions a mux keyword,"
echo "   but this needs jq to parse the hook's OWN input once python3 is gone"
NOPY="$(shim_path nopy python3)"
if PATH="$NOPY" command -v jq >/dev/null 2>&1; then
  run 'ssh -M host' "$NOPY"; rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/err" && pass "no python3: a mux-shaped command fails closed" \
    || fail "no python3: a mux-shaped command was not blocked (rc=$rc) — $(cat "$TMP/err")"
  run 'ssh host ls' "$NOPY"; rc=$?
  [[ "$rc" == "0" ]] && pass "no python3: a plain ssh invocation (no mux keyword) is still allowed" \
    || fail "no python3: a plain ssh invocation was wrongly blocked (rc=$rc) — $(cat "$TMP/err")"
else
  echo "  ⚠️  SKIPPED — this host has no jq, so removing python3 leaves the hook with no parser at all"
  echo "     (its own pre-existing no-parser gate fires first; this suite tests OUR check, not that one)"
fi

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1; fi
