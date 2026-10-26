#!/usr/bin/env bash
# credential-path-gates-agree.test.sh — the read gate (bash-safety-gate.sh) and the write gate
# (write-safety-gate.sh) refuse the SAME set of well-known credential paths (governance#335). Both
# source hooks/credential-paths.sh's CRED_PATH rather than keeping their own copy, so this is the KAT
# that keeps them from drifting apart: an edit to one gate's check that didn't touch the shared file,
# or a gate that stopped sourcing it, fails here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READ_GATE="$ROOT/hooks/bash-safety-gate.sh"
WRITE_GATE="$ROOT/hooks/write-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

for f in "$READ_GATE" "$WRITE_GATE"; do
  if grep -q 'credential-paths\.sh' "$f"; then
    ok "$(basename "$f") sources the shared hooks/credential-paths.sh"
  else
    bad "$(basename "$f") does not source hooks/credential-paths.sh — the two lists can drift apart"
  fi
done

PATHS=(
  "$HOME/.aws/credentials" "$HOME/.aws/config" "$HOME/.netrc"
  "$HOME/.ssh/id_rsa" "$HOME/.ssh/deploy_key"
  "$HOME/.docker/config.json" "$HOME/.kube/config"
  "$HOME/.config/gh/hosts.yml" "$HOME/.git-credentials" "$HOME/.pgpass"
)

read_rc() {  # read_rc <path> -> exit code of a `cat <path>` through the read gate
  python3 -c "import json,sys; print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':'cat '+sys.argv[1]}}))" "$1" \
    | bash "$READ_GATE" >/dev/null 2>&1
  echo $?
}
write_rc() {  # write_rc <path> -> exit code of a Write to <path> through the write gate
  python3 -c "import json,sys; print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':'x'}}))" "$1" \
    | bash "$WRITE_GATE" >/dev/null 2>&1
  echo $?
}

for p in "${PATHS[@]}"; do
  rrc=$(read_rc "$p"); wrc=$(write_rc "$p")
  if [ "$rrc" = 2 ] && [ "$wrc" = 2 ]; then
    ok "read and write both refuse $p"
  else
    bad "read=$rrc write=$wrc for $p (want both 2 — refused)"
  fi
done

rrc=$(read_rc "$HOME/notes.md"); wrc=$(write_rc "$HOME/notes.md")
if [ "$rrc" = 0 ] && [ "$wrc" = 0 ]; then
  ok "an ordinary path is refused by neither gate"
else
  bad "ordinary path: read=$rrc write=$wrc (want both 0 — allowed)"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
