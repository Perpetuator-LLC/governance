#!/usr/bin/env bash
# credential-path-read-gate.test.sh — bash-safety-gate refuses a command that NAMES a well-known
# credential PATH (governance#335): the name-based `.env*` rule only catches a secret by its content
# category, and `less ~/.aws/credentials` matched nothing there — its name says "credentials" and
# "config", never ".env". hooks/credential-paths.sh is the shared CRED_PATH list; this suite is its
# KAT on the read side, on the channel the harness actually uses (PreToolUse JSON on stdin).
#
# ⚠️ r2 (CISA review, governance#335): the first version gated this behind a reader-verb list
# (cat/grep/rg/head/tail/less/more), so `base64 ~/.aws/credentials`, `cp` to a readable spot, `xxd`,
# `awk`, `sed -n p` and `python3 -c "open(...)"` all exposed the file unrefused — a verb list only
# ever enumerates the readers someone thought of. The path is matched by NAME ALONE now, wherever in
# the (normalised) command it sits, with no per-sub-command carve-out: unlike `.env`, a name specific
# enough to be `~/.aws/credentials` has no benign reason to appear in a command at all.
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

# One probe per the seven reader verbs the OLD rule was gated behind — none of these were special;
# the point is that NONE of them matter any more.
check "verb: cat"   BLOCK "cat ~/.aws/credentials"
check "verb: grep"  BLOCK "grep -i key ~/.aws/credentials"
check "verb: rg"    BLOCK "rg key ~/.aws/credentials"
check "verb: head"  BLOCK "head ~/.aws/credentials"
check "verb: tail"  BLOCK "tail ~/.aws/credentials"
check "verb: less"  BLOCK "less ~/.aws/credentials"
check "verb: more"  BLOCK "more ~/.aws/credentials"
# ... and the ones the verb list MISSED, each of which can expose the file just as well.
check "non-verb: base64"       BLOCK "base64 ~/.aws/credentials"
check "non-verb: cp"           BLOCK "cp ~/.aws/credentials /tmp/x"
check "non-verb: xxd"          BLOCK "xxd ~/.aws/credentials"
check "non-verb: awk"          BLOCK "awk '{print}' ~/.aws/credentials"
check "non-verb: sed"          BLOCK "sed -n p ~/.aws/credentials"
check "non-verb: python open"  BLOCK 'python3 -c "open(\"/home/x/.aws/credentials\").read()"'

# RIGHT BOUNDARY: a longer name that merely starts with the shape is not the credential file.
check "a .aws/credentials.bak is not .aws/credentials" ALLOW "cat ~/.aws/credentials.bak"
check "an id_* README is not a private key"            ALLOW "cat ~/.ssh/id_rsa.md"
check "a kube-config.example is not the real one"      ALLOW "cat ~/.kube/config.example"
# controls
check "a benign SSH file (known_hosts) is not the list" ALLOW "cat ~/.ssh/known_hosts"
check "an ordinary read"                                ALLOW "cat README.md"
# A path this specific gets no cross-sub-command carve-out: naming it anywhere in the line is refused,
# even via a verb that isn't a reader at all (`echo`) and even in a sub-command no reader touches.
check "no FP carve-out: the path merely named in an unrelated sub-command is still refused" \
  BLOCK "cat README.md && echo ~/.aws/credentials"

# governance#335 r2: the keychain rule matched $cmd directly and skipped normalize_escapes, so a
# backslash-escaped call slipped through the same way the bare .env cases did.
check "keychain read, backslash-escaped past the literal match" BLOCK 'sec\urity find-generic-password -w'
check "keychain read, plain"                                    BLOCK "security find-generic-password -w"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
