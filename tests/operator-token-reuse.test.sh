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
# A seat's own machine-identity credential path must keep working, and it needs NO allow rule: it never
# runs these subcommands as text the gate reads. An allow matched against the whole command switched
# both refusals off for everything else on the line, so this suite pins that no script name anywhere
# in a command does that. The script names below are examples; core carries no installation's names.
#
# Each class a reviewer sent back has a MUTANT: the gate with that fix undone, under which the rows
# of the class must stop being refused.

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


mutant() {  # mutant <label> <old> <new> <command>...
  # With <old> replaced by <new> in a copy of the gate, every <command> (each one refused by the real
  # gate in a row above) must be ALLOWED. That proves those rows are what catches the loss. A mutation
  # whose <old> text is gone fails loudly: the gate changed, so re-aim the mutant, never drop it.
  local label="$1" old="$2" new="$3" real="$GATE" c bad=0; shift 3
  if ! python3 - "$GATE" "$TMP/mutant-gate.sh" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new))
PY
  then fail "mutant not built: $label (the gate text it edits is gone; re-aim it)"; return; fi
  GATE="$TMP/mutant-gate.sh"
  for c in "$@"; do
    run "$c"; [[ $? == 0 ]] || { bad=$((bad + 1)); printf '        still refused under the mutant: %s\n' "$c"; }
  done
  GATE="$real"
  [[ $bad == 0 ]] && pass "mutant killed: $label ($# rows go red)" || fail "mutant survived: $label ($bad of $# rows)"
}

echo "── operator-token-reuse: refuse reading a secret or the resolved token via the bao/vault CLI"

check_blocked 'bao kv get secret/foo' "bao kv get"
check_blocked 'vault kv get secret/foo' "vault kv get"
check_blocked 'bao kv read secret/foo' "bao kv read"
check_blocked 'bao read secret/foo' "bao read (legacy form)"
check_blocked 'vault read secret/foo' "vault read (legacy form)"
check_blocked 'bao print token' "bao print token (reveals the resolved token)"
check_blocked 'vault token lookup' "vault token lookup (reveals token metadata)"
check_blocked 'bao -address=https://v.example kv get secret/foo' "a global flag between the binary and kv get"
check_blocked 'sudo bao kv get secret/foo' "sudo bao kv get"
check_blocked 'bao kv get -field=t secret/x | docker login --password-stdin r.example' \
  "a blind pipe into another login's stdin still rides the live session"

echo "── operator-token-reuse: unwrap, and minting a child of the operator's own token"

W_UNWRAP='bao unwrap s.wrappingtoken'
W_VAULT='vault unwrap'
W_LIST="python3 -c \"import subprocess; subprocess.run(['bao', 'unwrap', 'x'])\""
K_CREATE='bao token create -policy=x'
K_VAULT='vault token create -ttl=1h'
check_blocked "$W_UNWRAP" "bao unwrap (reads a wrapped secret)"
check_blocked "$W_VAULT" "vault unwrap"
check_blocked "$W_LIST" "unwrap as a list-form argv"
check_blocked "$K_CREATE" "bao token create from the Bash tool (a child of the operator's token)"
check_blocked "$K_VAULT" "vault token create"
mutant "unwrap is not in the refused subcommands" \
  '|read|unwrap|print${OSR_SEP}+token' '|read|print${OSR_SEP}+token' \
  "$W_UNWRAP" "$W_VAULT" "$W_LIST"
mutant "token create is not in the refused subcommands" \
  'token${OSR_SEP}+(lookup|create)' 'token${OSR_SEP}+(lookup)' \
  "$K_CREATE" "$K_VAULT"

echo "── operator-token-reuse: a names-only listing shows no value and stays allowed"

check_allowed 'vault kv list secret/' "vault kv list (path names only)"
check_allowed 'vault list secret/' "vault list (legacy form, names only)"
check_allowed 'bao kv metadata get secret/foo' "bao kv metadata get (presence and versions, no value)"
check_blocked 'bao kv list secret/ && bao kv get secret/foo' "a listing, then a value read"

echo "── operator-token-reuse: refuse reading the token-helper's own token file"

check_blocked 'cat ~/.vault-token' "cat ~/.vault-token"
check_blocked 'cat ~/.bao-token' "cat ~/.bao-token"
check_blocked 'grep TOKEN ~/.vault-token' "grep on ~/.vault-token"
check_blocked 'head -c 40 ~/.vault-token' "head on ~/.vault-token"

echo "── operator-token-reuse: the wider reader list for the token file"

T_SED='sed -n p ~/.vault-token'
T_AWK='awk 1 ~/.bao-token'
T_XXD='xxd ~/.vault-token'
T_CP='cp ~/.vault-token /tmp/t'
T_DD='dd if=~/.vault-token of=/tmp/t'
T_REDIR='python3 -c "print(input())" < ~/.vault-token'
T_CAPS='cat ~/.VAULT-TOKEN'
check_blocked "$T_SED" "sed prints the token file"
check_blocked "$T_AWK" "awk prints the token file"
check_blocked "$T_XXD" "xxd dumps the token file"
check_blocked "$T_CP" "cp moves the token out of reach of this rule"
check_blocked "$T_DD" "dd copies the token file"
check_blocked "$T_REDIR" "an input redirect hands the token to any program"
check_blocked 'base64 < ~/.vault-token' "base64 with an input redirect"
check_blocked "$T_CAPS" "the file name in capitals (a case-insensitive disk)"
check_allowed 'ls -la ~/.vault-token' "a listing is not a read"
check_allowed 'rm -f ~/.vault-token' "removing it (a logout) is not a read"
check_allowed 'test -f ~/.vault-token && echo present' "a presence check is not a read"
check_allowed 'cat notes.txt; ls -la ~/.vault-token' "a reader in one sub-command, the name in another"
mutant "the reader list cut back to the secret-file verbs" \
  "VAULT_TOKEN_VERBS='cat|grep|rg|head|tail|less|more|sed|awk|base64|xxd|od|strings|cut|cp|dd'" \
  "VAULT_TOKEN_VERBS='cat|grep|rg|head|tail|less|more'" \
  "$T_SED" "$T_AWK" "$T_XXD" "$T_CP" "$T_DD"
mutant "the input-redirect form removed" \
  '|<\s*[^ ;&|<>]*${VAULT_TOKEN_NAME}"' '"' \
  "$T_REDIR"

echo "── operator-token-reuse: a seat's own machine-identity path needs no allow rule and stays allowed"

check_allowed 'python3 seat-credential.py --seat build-desk' "a seat's own credential script (an example name)"
check_allowed '/usr/local/bin/seat-login.sh --verbose' "a seat's own login wrapper by full path (an example name)"
check_allowed 'vault write auth/approle/login role_id=@role_id secret_id=@secret_id' \
  "the AppRole login itself (write, not get/read/list)"

echo "── operator-token-reuse: no script name anywhere in the command switches the refusal off"

A_SEMI='echo seat-credential.py --seat x; bao kv get secret/x'
A_COMMENT='bao kv get secret/x # seat-login.sh'
A_AND='seat-login.sh && vault kv get secret/x'
check_blocked "$A_SEMI" "a script name in an earlier sub-command"
check_blocked "$A_COMMENT" "a script name in a trailing comment"
check_blocked "$A_AND" "the script run first, then the read"
mutant "a whole-command allow for a script name is back" \
  'if printf '"'"'%s'"'"' "$osr_bare" | grep -qE "$OPERATOR_SECRET_READ"; then' \
  'if ! printf '"'"'%s'"'"' "$cmd" | grep -qE "seat-login\.sh|seat-credential\.py" && printf '"'"'%s'"'"' "$osr_bare" | grep -qE "$OPERATOR_SECRET_READ"; then' \
  "$A_SEMI" "$A_COMMENT" "$A_AND"

echo "── operator-token-reuse: the tool word in capitals"

C_UP='BAO kv get secret/x'
C_MIX='Vault KV Get secret/x'
check_blocked "$C_UP" "BAO in capitals (a case-insensitive disk runs bao)"
check_blocked "$C_MIX" "mixed case"
check_blocked 'VAULT_ADDR=x bao kv get secret/x' "an env assignment in front"
mutant "the text is no longer lower-cased before matching" \
  'osr_flat=$(printf '"'"'%s'"'"' "$scan" | tr '"'"'\n\r'"'"' '"'"'  '"'"' | tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"')' \
  'osr_flat=$(printf '"'"'%s'"'"' "$scan" | tr '"'"'\n\r'"'"' '"'"'  '"'"')' \
  "$C_UP" "$C_MIX" "$T_CAPS"

echo "── operator-token-reuse: the tool word split by quotes or a backslash"

Z_QQ="b''ao kv get secret/x"
Z_BS='b\ao kv get secret/x'
Z_DQ='va""ult kv get secret/x'
check_blocked "$Z_QQ" "b''ao (an empty quote pair inside the word)"
check_blocked "$Z_BS" 'b\ao (a backslash inside the word)'
check_blocked "$Z_DQ" 'va""ult (an empty double-quote pair)'
mutant "the tool word is matched with quotes and backslashes left in" \
  'osr_bare=$(printf '"'"'%s'"'"' "$osr_flat" | tr -d "\"'"'"'\\\\")' 'osr_bare=$osr_flat' \
  "$Z_QQ" "$Z_BS" "$Z_DQ"

echo "── operator-token-reuse: a list-form argv inside an interpreter"

L_DQ='python3 -c "import subprocess;subprocess.run([\"bao\",\"kv\",\"get\",\"secret/x\"])"'
L_SQ="python3 -c \"import subprocess; subprocess.run(['vault', 'kv', 'get', 'secret/x'])\""
L_OPT="python3 -c \"import subprocess; subprocess.run(['bao', '-format=json', 'kv', 'get', 'secret/x'])\""
L_TOK="python3 -c \"import subprocess; subprocess.run(['vault','token','lookup'])\""
check_blocked "$L_DQ" "list form, escaped double quotes"
check_blocked "$L_SQ" "list form, single quotes and spaces"
check_blocked "$L_OPT" "list form with an option before the subcommand"
check_blocked "$L_TOK" "list form, token lookup"
check_blocked "python3 -c \"import os; os.system('bao print token')\"" "a command string handed to os.system"
mutant "only spaces may join the tool word and the subcommand" \
  'OSR_SEP="[[:space:]\"'"'"',\\]"' 'OSR_SEP="[[:space:]]"' \
  "$L_DQ" "$L_SQ" "$L_OPT" "$L_TOK"

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
