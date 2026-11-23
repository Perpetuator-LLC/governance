#!/usr/bin/env bash
# tests/operator-token-reuse.test.sh — bash-safety-gate refuses an agent session reading a secret or
# the resolved token through the bao/vault CLI, or reading the token-helper's own token file directly.
# A measured incident: a dry-run lister, run through an agent's own sandboxed Bash shell, read an
# admin secret this way while the operator's bao/vault login session was still live — no value
# entered a model's context, but the read itself rode a session the agent never authenticated.
#
# Unlike CRED_MINT (refuses MINTING a credential, scoped to tool != Bash because a stdin-fed login is
# a legitimate blind pipeline there), this rule applies to EVERY tool including Bash: there is no
# comparable blind-pipeline case for READING a secret or the token itself — see
# tests/terminal-floor.test.sh for the one existing case this moves from ALLOW to BLOCK.
#
# A seat's own credential withdrawal (state-withdraw.py --seat, seat-boot.sh) must keep working: this
# suite proves both script names pass through untouched, even when a bao/vault-shaped string sits
# elsewhere on the same command line.

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

payload() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")"; }

run() {  # run <command> -> exit code; stderr captured in $TMP/err
  payload "$1" | bash "$GATE" >/dev/null 2>"$TMP/err"
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

echo "── operator-token-reuse: refuse reading a secret or the resolved token via the bao/vault CLI"

check_blocked 'bao kv get secret/foo' "bao kv get"
check_blocked 'vault kv get secret/foo' "vault kv get"
check_blocked 'bao kv read secret/foo' "bao kv read"
check_blocked 'vault kv list secret/' "vault kv list"
check_blocked 'bao read secret/foo' "bao read (legacy form)"
check_blocked 'vault read secret/foo' "vault read (legacy form)"
check_blocked 'vault list secret/' "vault list (legacy form)"
check_blocked 'bao print token' "bao print token (reveals the resolved token)"
check_blocked 'vault token lookup' "vault token lookup (reveals token metadata)"
check_blocked 'bao -address=https://v.example kv get secret/foo' "a global flag between the binary and kv get"
check_blocked 'sudo bao kv get secret/foo' "sudo bao kv get"
check_blocked 'bao kv get -field=t secret/x | docker login --password-stdin r.example' \
  "a blind pipe into another login's stdin still rides the live session"

echo "── operator-token-reuse: refuse reading the token-helper's own token file"

check_blocked 'cat ~/.vault-token' "cat ~/.vault-token"
check_blocked 'cat ~/.bao-token' "cat ~/.bao-token"
check_blocked 'grep TOKEN ~/.vault-token' "grep on ~/.vault-token"
check_blocked 'head -c 40 ~/.vault-token' "head on ~/.vault-token"

echo "── operator-token-reuse: the seat's own AppRole path (named allow rule) stays allowed"

check_allowed 'python3 state-withdraw.py --seat kms-desk' "state-withdraw.py --seat"
check_allowed './state-withdraw.py --seat=kms-desk' "state-withdraw.py --seat=<name> (= form)"
check_allowed 'seat-boot.sh' "seat-boot.sh"
check_allowed '/usr/local/bin/seat-boot.sh --verbose' "seat-boot.sh by full path, with an argument"
check_allowed 'vault write auth/approle/login role_id=@role_id secret_id=@secret_id' \
  "the AppRole login itself (write, not get/read/list)"
check_allowed 'python3 state-withdraw.py --seat foo --note "see bao kv get for details"' \
  "the allow rule is load-bearing: a seat script's OWN argument happens to echo a refused phrase"

echo "── operator-token-reuse: known-goods and look-alikes stay allowed"

check_allowed 'bao status' "bao status"
check_allowed 'vault status' "vault status"
check_allowed 'bao kv put secret/foo bar=baz' "bao kv put (a write, not a read)"
check_allowed 'vault policy read my-policy' "vault policy read (a policy definition, not kv get/read/list)"
check_allowed 'cat environment.rc' "a file that merely shares letters with 'bao'/'vault' is unaffected"
check_allowed 'cat ~/.vault-tokens-backup.txt' "a longer name sharing the vault-token prefix is not the helper's own file"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1; fi
