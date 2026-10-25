#!/usr/bin/env bash
# credential-path-read-gate.test.sh — bash-safety-gate refuses a reader verb on a well-known
# credential PATH (governance#335): the name-based `.env*` rule only catches a secret by its content
# category, and `less ~/.aws/credentials` matched nothing there — its name says "credentials" and
# "config", never ".env". hooks/credential-paths.sh is the shared CRED_PATH list; this suite is its
# KAT on the read side, on the channel the harness actually uses (PreToolUse JSON on stdin).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

check() {  # check <label> <want: BLOCK|ALLOW> <command>
  local label="$1" want="$2" cmd="$3" payload rc got reason
  payload=$(python3 -c "import json,sys; print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':sys.argv[1]}}))" "$cmd")
  reason=$(printf '%s' "$payload" | bash "$GATE" 2>&1 >/dev/null); rc=$?
  got=$([ "$rc" = 2 ] && echo BLOCK || echo ALLOW)
  if [ "$got" != "$want" ]; then
    bad "$label (want $want, got $got): $cmd"
  elif [ "$got" = BLOCK ] && [[ "$reason" != *"credential-path-read"* ]] && [[ "$reason" != BLOCKED* ]]; then
    bad "$label: blocked without the reason reaching the model: $reason"
  else
    ok "$label"
  fi
}

check "AWS credentials file"        BLOCK "less ~/.aws/credentials"
check "AWS config file"             BLOCK "cat ~/.aws/config"
check "netrc"                       BLOCK "cat ~/.netrc"
check "SSH private key (id_*)"      BLOCK "cat ~/.ssh/id_rsa"
check "SSH private key (*_key)"     BLOCK "head ~/.ssh/deploy_key"
check "Docker config"               BLOCK "cat ~/.docker/config.json"
check "kube config"                 BLOCK "cat ~/.kube/config"
check "gh hosts.yml"                BLOCK "cat ~/.config/gh/hosts.yml"
check "git-credentials"             BLOCK "cat ~/.git-credentials"
check "pgpass"                      BLOCK "cat ~/.pgpass"
check "absolute path form"          BLOCK "grep -i key /home/user/.aws/credentials"
# RIGHT BOUNDARY: a longer name that merely starts with the shape is not the credential file.
check "a .aws/credentials.bak is not .aws/credentials" ALLOW "cat ~/.aws/credentials.bak"
check "an id_* README is not a private key"            ALLOW "cat ~/.ssh/id_rsa.md"
check "a kube-config.example is not the real one"      ALLOW "cat ~/.kube/config.example"
# controls
check "a benign SSH file (known_hosts) is not the list" ALLOW "cat ~/.ssh/known_hosts"
check "an ordinary read"                                ALLOW "cat README.md"
# cross-sub-command false positive: a reader verb in one command, a credential-shaped path in another
# that no reader verb touches. These match the whole-string pattern, so they need the per-sub-command
# check — the same shape secret-read-gate.test.sh proves for the name-based rule.
check "FP: reader and credential path in unrelated sub-commands" ALLOW "cat README.md && echo ~/.aws/credentials"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
