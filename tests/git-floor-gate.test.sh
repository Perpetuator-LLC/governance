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

# CISA c106327 on PR #285: five shapes reached main past the first version, which tokenised with shlex
# and so did not see what bash makes of quotes, `$'...'` and expansions. Each row below exited 0 at
# a5228c2. The rest of each list is the neighbourhood of the same causes: an unquoted brace, a backslash,
# a case-folded name, a partial ref, an expansion in a remote or an option, an alias or push refspec from
# `--config-env`, the environment or `git config`.
push_shapes=(
  'BR=$(git branch --show-current); git push origin HEAD:$BR'
  'git push origin "HEAD:ma""in"'
  "git push origin HEAD:\$'main'"
  'git push origin HEAD:heads/main'
  'git push origin HEAD:$BR'
  'git push origin "HEAD:$BR"'
  'git push origin HEAD:{main,x}'
  'git push origin HEAD:refs/heads/Main'
  'git push $R feeder/x'
  'git push "$R" feeder/x'
  'git push -o $X origin feeder/x'
  'GIT push origin main'
)
alias_shapes=(
  'git -c alias.p=push p origin main'
  'git -c Alias.P=push P origin main'
  'git --config-env=alias.p=X p origin main'
  'git -c remote.origin.push=HEAD:main push'
  'git -c push.default=matching push'
  'GIT_CONFIG_PARAMETERS="'"'alias.p=push'"'" git p origin main'
  'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=push git p origin main'
  'git config alias.p push'
  'git config --global remote.origin.push HEAD:main'
)
# An expansion where the command, an option or the subcommand goes. The tokeniser names the doubt; the
# pattern layer refuses it as a push or a hook bypass, so only the exit code is shared.
unreadable_shapes=(
  'G=git; $G push origin main'
  'git $SUB origin main'
  'git -C $D push origin feeder/x'
  'git -c "$K"=push p origin main'
  'F=--no-verify; git commit $F -m x'
  'git commit "$F" -m x'
  'git commit -m $MSG'
  'git commit -m x -"$F"'
)

for layer in tokeniser patterns; do
  pre=""; [[ "$layer" == patterns ]] && pre="$NEST"
  echo "── push to the default branch (#269), $layer layer"
  for c in "${push_blocked[@]}"; do blocked_as "$pre$c" "$PUSH"; done
  echo "── skipping the git hooks (#270), $layer layer"
  for c in "${hook_blocked[@]}"; do blocked_as "$pre$c" "$HOOK"; done
  echo "── what bash makes of the words (CISA c106327), $layer layer"
  for c in "${push_shapes[@]}"; do blocked_as "$pre$c" "$PUSH"; done
  echo "── an alias or push refspec defined in the command, $layer layer"
  for c in "${alias_shapes[@]}"; do blocked_as "$pre$c" "Changing what git runs"; done
  echo "── an expansion where git's command, options or subcommand go, $layer layer"
  for c in "${unreadable_shapes[@]}"; do
    if [[ "$layer" == tokeniser && "$c" != *commit* ]]; then blocked_as "$c" "cannot tell"
    elif [[ "$layer" == tokeniser ]]; then blocked_as "$c" "$HOOK"
    else rc=$(run "$pre$c"); [[ "$rc" == 2 ]] && pass "blocked: $pre$c" || fail "exit $rc, not 2 — $pre$c"; fi
  done
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
allowed 'git -C "$D" push origin feeder/x'
allowed 'git push -o "$X" origin feeder/x'
allowed 'git commit -m "$MSG"'
allowed 'git commit -m "$MSG" -- "$f"'
allowed 'git -c user.name=x commit -m y'
allowed 'git config --get alias.p'
allowed 'git log stash@{0}'
allowed 'git push origin feeder/heads-main'
allowed 'git push origin "$H:refs/heads/feeder-x"'   # git splits at the LAST colon: a literal destination
blocked_as 'git push origin "$H:main"' "$PUSH"
allowed "git commit -m \"\$(cat <<'MSG'
subject with \"quotes\"
MSG
)\""

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
