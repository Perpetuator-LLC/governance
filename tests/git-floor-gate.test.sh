#!/usr/bin/env bash
# tests/git-floor-gate.test.sh — bash-safety-gate.sh refuses a push to the default branch (#269) and a
# commit or push that skips the git hooks (#270).
#
# Before the rule (main @194c9a3) every BLOCKED case below exited 0. Each block is run twice: as typed,
# where the python3 tokeniser decides, and behind a nested command (`true $(true) && ...`), where the
# tokeniser doubts and the plain patterns decide. Both layers must refuse; the ALLOWED controls hold on
# the tokeniser layer, which is the one that reads quotes and option values exactly.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # keep the audit trail out of the real state directory
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
  "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; }

run() {  # run <command-text> -> exit code; BLOCKED line (if any) in $TMP/err
  printf '%s' "$(bash_json "$1")" | bash "$GATE" >"$TMP/out" 2>"$TMP/err"
  echo $?
}

blocked_as() {  # blocked_as <command> <expected-substring-of-the-BLOCKED-reason>
  local rc; rc=$(run "$1")
  [[ "$rc" == "2" ]] || { fail "exit $rc, not 2 — $1"; return; }
  grep -qi "$2" "$TMP/err" || { fail "BLOCKED but not for '$2' ($(cat "$TMP/err")) — $1"; return; }
  pass "blocked ($2): $1"
}

allowed() {
  local rc; rc=$(run "$1")
  [[ "$rc" == "0" ]] && pass "allowed: $1" || fail "blocked (should be allowed, rc=$rc: $(cat "$TMP/err")) — $1"
}

PUSH="default branch"
HOOK="Skipping the git hooks"
NEST='true $(true) && '

push_blocked=(
  'git push origin main'
  'git push origin HEAD:main'
  'git push origin HEAD:refs/heads/main'
  'git -C ../repo push origin main'
  'cd repo && git push -u origin main'
  'git push origin "main"'
  'git push --all origin'
  'git push --mirror origin'
  'git push origin feeder/x:refs/heads/main'
)
hook_blocked=(
  'git commit --no-verify -m x'
  'git commit -n -m x'
  'git commit -anm x'
  'git commit -m x "--no-verify"'
  'git push --no-verify origin feeder/x'
  'git -c core.hooksPath=/dev/null commit -m x'
  'git -c core.hookspath= commit -m x'
  'git config core.hooksPath /dev/null'
  'GIT_CONFIG_PARAMETERS="'"'core.hooksPath=/dev/null'"'" git commit -m x'
  'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'
)

for layer in tokeniser patterns; do
  pre=""; [[ "$layer" == patterns ]] && pre="$NEST"
  echo "── push to the default branch (#269), $layer layer"
  for c in "${push_blocked[@]}"; do blocked_as "$pre$c" "$PUSH"; done
  echo "── skipping the git hooks (#270), $layer layer"
  for c in "${hook_blocked[@]}"; do blocked_as "$pre$c" "$HOOK"; done
done

echo "── GOVERNANCE_PROTECTED_BRANCHES replaces the default list"
GOVERNANCE_PROTECTED_BRANCHES="trunk" blocked_as 'git push origin trunk' "$PUSH"
rc=$(GOVERNANCE_PROTECTED_BRANCHES="trunk" run 'git push origin main')
[[ "$rc" == "0" ]] && pass "allowed: main is not protected when the list is 'trunk'" || fail "main refused under list 'trunk' (rc=$rc)"

echo "── controls: the ordinary feeder workflow stays allowed"
allowed 'git push origin feeder/269-x'
allowed 'git push -u origin feeder/269-x'
allowed 'git push origin some-main-feature'
allowed 'git push origin main-fix'
allowed 'git push -n origin feeder/x'
allowed 'git commit -m "mentions --no-verify and main"'
allowed 'git commit -m "no -n here"'
allowed 'git commit --amend --no-edit'
allowed 'git config --get core.hooksPath'
allowed 'git log -n 3 main'
allowed 'git fetch origin main'
allowed 'git pull origin main'
allowed "${NEST}git push origin feeder/x"
allowed "${NEST}git commit -m x"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
