#!/usr/bin/env bash
# signed-commits-check.test.sh — the CI gate that every commit in a pull request's range is signed.
#
# A fixture repository with two throwaway ed25519 keys: TRUSTED (listed in the fixture's allowed-signers
# file) and STRANGER (a valid key, not listed). Each expectation comes from how the range was BUILT,
# stated before the checker runs, never read back from its output:
#   two commits signed by TRUSTED                         → pass (exit 0)
#   an UNSIGNED commit before the range, signed range     → pass: older history is never checked
#   an unsigned commit inside the range                   → fail (exit 1), naming that commit
#   a commit signed by STRANGER                           → fail (exit 1): a good signature is not enough
#   an unsigned MERGE of two signed commits               → fail (exit 1): merges are commits too
#   an empty range                                        → pass (exit 0)
#   missing allowed-signers file / unresolvable ref       → cannot check (exit 2), never a pass
#
# Never touches the caller's keys, agent or git config: SSH_AUTH_SOCK is emptied and global/system git
# config are replaced with an empty file.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$ROOT/bin/signed-commits-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

command -v ssh-keygen >/dev/null || { echo "  ❌ ssh-keygen missing; cannot build signed fixtures"; exit 1; }

export SSH_AUTH_SOCK=""
: > "$TMP/empty.gitconfig"
export GIT_CONFIG_GLOBAL="$TMP/empty.gitconfig" GIT_CONFIG_NOSYSTEM=1

ssh-keygen -q -t ed25519 -N '' -C trusted  -f "$TMP/trusted"
ssh-keygen -q -t ed25519 -N '' -C stranger -f "$TMP/stranger"
chmod 600 "$TMP/trusted" "$TMP/stranger"
SIGNERS="$TMP/allowed_signers"
echo "trusted@example.com $(cut -d' ' -f1,2 "$TMP/trusted.pub")" > "$SIGNERS"

R="$TMP/repo"
git init -q -b main "$R"
g() { git -C "$R" -c user.email=t@example.com -c user.name=test -c gpg.format=ssh "$@"; }
n=0
unsigned() { n=$((n+1)); echo "$n" > "$R/f$n"; g add "f$n"; g -c commit.gpgsign=false commit -q -m "$1"; }
signed()   { n=$((n+1)); echo "$n" > "$R/f$n"; g add "f$n"; g -c user.signingkey="$TMP/$2" commit -q -S -m "$1"; }
run() { (cd "$R" && bash "$CHK" --allowed-signers "$SIGNERS" "$@"); }

unsigned "old history: unsigned, before the range"
BASE=$(g rev-parse HEAD)
signed "good one" trusted
signed "good two" trusted
GOOD=$(g rev-parse HEAD)

# Fixture sanity, by a different route than the checker: git's own verifier against the same file.
check "fixture: a TRUSTED commit verifies with git verify-commit" \
  "g -c gpg.ssh.allowedSignersFile='$SIGNERS' verify-commit '$GOOD' >/dev/null 2>&1"

out=$(run "$BASE..$GOOD"); rc=$?
check "signed range passes (exit 0)" "[ $rc -eq 0 ]"
check "both in-range commits listed ok" "[ \$(grep -c '^  ok   G ' <<< \"\$out\") -eq 2 ]"
check "the unsigned commit BEFORE the range is not mentioned" "! grep -q 'old history' <<< \"\$out\""

unsigned "sneaky: unsigned inside the range"
UNS=$(g rev-parse HEAD)
out=$(run "$BASE..$UNS"); rc=$?
check "unsigned commit in range fails (exit 1)" "[ $rc -eq 1 ]"
check "the failure names the unsigned commit with N" "grep -q '^  FAIL N .*sneaky' <<< \"\$out\""
check "the signed commits still read ok" "[ \$(grep -c '^  ok   G ' <<< \"\$out\") -eq 2 ]"

g checkout -q -b stranger "$GOOD"
signed "stranger: valid signature, key not allowed" stranger
STR=$(g rev-parse HEAD)
out=$(run "$GOOD..$STR"); rc=$?
check "commit signed by a key NOT in allowed signers fails (exit 1)" "[ $rc -eq 1 ]"
check "it is reported as a failure, not ok" "grep -q '^  FAIL .*stranger' <<< \"\$out\" && ! grep -q '^  ok ' <<< \"\$out\""

g checkout -q -b side "$GOOD"; signed "side work" trusted
g checkout -q -b topic "$GOOD"; signed "topic work" trusted
g -c commit.gpgsign=false merge -q --no-ff --no-edit side
MRG=$(g rev-parse HEAD)
out=$(run "$GOOD..$MRG"); rc=$?
check "unsigned merge of signed commits fails (exit 1)" "[ $rc -eq 1 ]"
check "exactly one failure: the merge" "[ \$(grep -c '^  FAIL ' <<< \"\$out\") -eq 1 ] && grep -q '^  FAIL N .*Merge' <<< \"\$out\""

out=$(run "$GOOD..$GOOD"); rc=$?
check "empty range passes (exit 0)" "[ $rc -eq 0 ] && grep -q 'empty' <<< \"\$out\""

out=$( (cd "$R" && bash "$CHK" --allowed-signers "$TMP/nope" "$BASE..$GOOD") 2>&1); rc=$?
check "missing allowed-signers file cannot check (exit 2)" "[ $rc -eq 2 ]"
echo "# comments only" > "$TMP/empty_signers"
out=$( (cd "$R" && bash "$CHK" --allowed-signers "$TMP/empty_signers" "$BASE..$GOOD") 2>&1); rc=$?
check "allowed-signers file with no keys cannot check (exit 2)" "[ $rc -eq 2 ]"
out=$(run "no-such-ref..$GOOD" 2>&1); rc=$?
check "unresolvable base cannot check (exit 2)" "[ $rc -eq 2 ]"
out=$(run "$GOOD" 2>&1); rc=$?
check "a bare ref (no range) is a usage error (exit 2)" "[ $rc -eq 2 ]"

echo "signed-commits-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
