#!/usr/bin/env bash
# hygiene-check.test.sh — over budget is REFUSED, under budget is ALLOWED, and the pre-push hook that
# carries the gate is actually INSTALLED (by `governance scaffold` and by --install-hook) and actually
# refuses a real `git push`. Fixture: a bare origin plus a clone under mktemp, never a real repo.
#
# Pinned because each was a real failure elsewhere:
#   - a hook nobody installs is no gate: the install is asserted by where the file lands, and the gate by
#     a push that does not reach the remote;
#   - a cleanup push (deletes, refs/archive/*) must pass even while the repo is over budget, or the gate
#     blocks the sweep that would bring it back under;
#   - a branch whose tip is a PR head, and every protected rolling branch, is never called stale.
# MUTANTS at the end: each copies the checker, breaks one decision, and must turn a pinned case red.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HC="$ROOT/bin/hygiene-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HYGIENE_BRANCH_BUDGET HYGIENE_WORKTREE_BUDGET HYGIENE_STALE_BUDGET HYGIENE_STALE_DAYS HYGIENE_KEEP
O="$TMP/origin.git"; C="$TMP/clone"
git init -q --bare -b main "$O"
git clone -q "$O" "$C" 2>/dev/null
g() { git -C "$C" "$@"; }
commit() { printf '%s\n' "$2" > "$C/$1"; g add "$1"; g commit -qm "$3"; }
old="@$(( $(date +%s) - 30 * 86400 )) +0000"

commit base base "base"; g push -q origin main
g switch -qc merge/lane;  GIT_COMMITTER_DATE="$old" commit m m "rolling";  g push -q origin merge/lane
g switch -q main; g switch -qc landed; commit l l "landed work"; g switch -q main; g merge -q --ff-only landed
g push -q origin main landed
g switch -qc idle;  GIT_COMMITTER_DATE="$old" commit i i "idle work";  g push -q origin idle
g switch -q main; g switch -qc pr-held; GIT_COMMITTER_DATE="$old" commit p p "held by a PR"; g push -q origin pr-held
git -C "$O" update-ref refs/pull/7/head "$(g rev-parse pr-held)"
g switch -q main; g switch -qc fresh; commit f f "fresh work"; g push -q origin fresh
g switch -q main
# Remote heads: main merge/lane landed idle pr-held fresh = 6. Stale: landed (LANDED) + idle (IDLE) = 2.

run() { "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

echo "hygiene-check — under budget is allowed"
rc="$(run "$HC" --repo "$C")"
check "defaults ⇒ exit 0, counts printed" \
  "[ '$rc' = '0' ] && grep -q 'remote branches 6 (budget 100)' '$TMP/out' && grep -q 'worktrees 1 (budget 10)' '$TMP/out' && grep -q 'stale 2 ' '$TMP/out'"
rc="$(HYGIENE_BRANCH_BUDGET=6 HYGIENE_STALE_BUDGET=2 HYGIENE_WORKTREE_BUDGET=1 run "$HC" --repo "$C")"
check "exactly AT every budget ⇒ exit 0 (the budget is the most allowed, not one less)" "[ '$rc' = '0' ]"

echo "hygiene-check — over budget is refused"
rc="$(HYGIENE_BRANCH_BUDGET=5 run "$HC" --repo "$C")"
check "6 branches over a budget of 5 ⇒ exit 1, says so" "[ '$rc' = '1' ] && grep -q 'OVER BUDGET: 6 remote branches > 5' '$TMP/out' && grep -q REFUSED '$TMP/err'"
rc="$(HYGIENE_STALE_BUDGET=1 run "$HC" --repo "$C")"
check "2 stale over a budget of 1 ⇒ exit 1" "[ '$rc' = '1' ] && grep -q 'OVER BUDGET: 2 stale' '$TMP/out'"
check "the landed branch is LANDED, the idle one IDLE, each with its archive-then-delete pair" \
  "grep -q '^  LANDED  landed ' '$TMP/out' && grep -q '^  IDLE    idle ' '$TMP/out' && grep -q 'refs/archive/[0-9-]*/idle && git push origin --delete idle' '$TMP/out'"
check "never stale: the default branch, merge/* (old), a PR head (old), a fresh branch" \
  "! grep -Eq '^  (LANDED|IDLE) +(main|merge/lane|pr-held|fresh) ' '$TMP/out'"
rc="$(HYGIENE_STALE_BUDGET=1 HYGIENE_KEEP='id*' run "$HC" --repo "$C")"
check "HYGIENE_KEEP protects a glob ⇒ 1 stale, under budget 1, exit 0" "[ '$rc' = '0' ] && grep -q 'stale 1 ' '$TMP/out'"
rc="$(HYGIENE_STALE_DAYS=60 run "$HC" --repo "$C" --no-fetch)"
check "HYGIENE_STALE_DAYS=60 ⇒ the 30-day branch is not IDLE (landed still is)" \
  "[ '$rc' = '0' ] && ! grep -q 'IDLE    idle' '$TMP/out' && grep -q 'LANDED  landed' '$TMP/out'"

g worktree add -q "$TMP/wt-a" fresh 2>/dev/null; g worktree add -q --detach "$TMP/wt-b" main 2>/dev/null
echo dirt > "$TMP/wt-a/dirt"
rc="$(HYGIENE_WORKTREE_BUDGET=2 run "$HC" --repo "$C")"
check "3 worktrees over a budget of 2 ⇒ exit 1, each listed with its state and a non-forced remove" \
  "[ '$rc' = '1' ] && grep -q 'OVER BUDGET: 3 worktrees > 2' '$TMP/out' && grep -q 'wt-a  (DIRTY, not in main)' '$TMP/out' && grep -q 'wt-b  (clean, HEAD in main)' '$TMP/out' && ! grep -q -- '--force' <(grep 'git worktree remove' '$TMP/out')"
rc="$(HYGIENE_WORKTREE_BUDGET=3 run "$HC" --repo "$TMP/wt-b")"
check "run from a linked worktree: same repo name, same count, budget 3 ⇒ exit 0" \
  "[ '$rc' = '0' ] && grep -q '^clone: .*worktrees 3 (budget 3)' '$TMP/out'"

echo "hygiene-check — receipts and refusals to run"
R="$TMP/receipts.tsv"
run "$HC" --repo "$C" --receipt "$R" >/dev/null
HYGIENE_BRANCH_BUDGET=1 run "$HC" --repo "$C" --receipt "$R" >/dev/null
check "--receipt appends one row per run: time, repo, counts/budgets, verdict" \
  "[ \"\$(wc -l < '$R')\" -eq 2 ] && [ \"\$(sed -n 1p '$R' | cut -f2-)\" = \"\$(printf 'clone\tbranches 6/100\tworktrees 3/10\tstale 2/10\tPASS')\" ] && sed -n 1p '$R' | cut -f1 | grep -q 'Z\$' &&sed -n 2p '$R' | grep -q 'branches 6/1.*REFUSED'"
rc="$(HYGIENE_BRANCH_BUDGET=lots run "$HC" --repo "$C")"
check "a non-numeric budget ⇒ exit 2" "[ '$rc' = '2' ]"
mkdir -p "$TMP/plain"
rc="$(run "$HC" --repo "$TMP/plain")"
check "not a git repo ⇒ exit 2" "[ '$rc' = '2' ]"
rc="$(run "$HC" --repo "$C" --frobnicate)"
check "an unknown argument ⇒ exit 2" "[ '$rc' = '2' ]"

echo "--install-hook — the gate is installed, once, and never over someone else's hook"
HOOK="$(cd "$C" && cd "$(git rev-parse --git-common-dir)" && pwd)/hooks/pre-push"
rc="$(run "$HC" --repo "$TMP/wt-b" --install-hook)"
check "from a linked worktree it installs into the COMMON hooks dir (covers every worktree)" \
  "[ '$rc' = '0' ] && [ -x '$HOOK' ] && cmp -s '$HOOK' '$ROOT/lib/git-hooks/pre-push' && grep -q '^installed ' '$TMP/out'"
rc="$(run "$HC" --repo "$C" --install-hook)"
check "a second install ⇒ ok, unchanged" "[ '$rc' = '0' ] && grep -q '^ok ' '$TMP/out'"
mkdir -p "$TMP/foreign"; git init -q "$TMP/foreign"
printf '#!/bin/sh\necho mine\n' > "$TMP/foreign/.git/hooks/pre-push"
rc="$(run "$HC" --repo "$TMP/foreign" --install-hook)"
check "another pre-push hook already there ⇒ exit 1, left byte for byte" \
  "[ '$rc' = '1' ] && grep -q refused '$TMP/err' && grep -q 'echo mine' '$TMP/foreign/.git/hooks/pre-push'"

echo "pre-push hook — a real push is refused over budget and allowed under"
export HYGIENE_CHECK="$HC"
g switch -q -c newwork; commit n n "new work"
HYGIENE_BRANCH_BUDGET=3 g push -q origin newwork >"$TMP/out" 2>&1; rc=$?
check "over budget ⇒ the push fails and the branch never reaches the remote" \
  "[ '$rc' != '0' ] && ! git -C '$O' rev-parse --verify -q refs/heads/newwork >/dev/null && grep -q 'OVER BUDGET' '$TMP/out'"
HYGIENE_BRANCH_BUDGET=3 g push -q origin "$(g rev-parse idle):refs/archive/2026-01-01/idle" >"$TMP/out" 2>&1; rc=$?
check "over budget, an archive-ref push still passes (cleanup is never refused)" \
  "[ '$rc' = '0' ] && git -C '$O' rev-parse --verify -q refs/archive/2026-01-01/idle >/dev/null"
HYGIENE_BRANCH_BUDGET=3 g push -q origin --delete idle >"$TMP/out" 2>&1; rc=$?
check "over budget, a delete push still passes" "[ '$rc' = '0' ] && ! git -C '$O' rev-parse --verify -q refs/heads/idle >/dev/null"
g push -q origin newwork >"$TMP/out" 2>&1; rc=$?
check "under the default budgets ⇒ the push goes through" "[ '$rc' = '0' ] && git -C '$O' rev-parse --verify -q refs/heads/newwork >/dev/null"
g switch -q -c nochecker; commit q q "no checker"
HYGIENE_CHECK="$TMP/nope" PATH="$(dirname "$(command -v git)"):/usr/bin:/bin" HOME="$TMP/emptyhome" g push -q origin nochecker >"$TMP/out" 2>&1; rc=$?
check "no checker anywhere ⇒ refused by name, never a silent pass" \
  "[ '$rc' != '0' ] && grep -q 'hygiene-check not found' '$TMP/out'"
unset HYGIENE_CHECK; g switch -q main

echo "governance scaffold — installs the hook it ships"
S="$TMP/scaf"; mkdir -p "$S"; git init -q "$S"
rc="$(run python3 "$ROOT/bin/governance" scaffold --template code-repo --out "$S")"
check "into a fresh git repo ⇒ 'hook: installed', .git/hooks/pre-push is the gate" \
  "[ '$rc' = '0' ] && grep -q '^hook: installed' '$TMP/out' && cmp -s '$S/.git/hooks/pre-push' '$ROOT/lib/git-hooks/pre-push'"
rc="$(run python3 "$ROOT/bin/governance" scaffold --template code-repo --out "$S")"
check "scaffold again ⇒ 'hook: ok'" "[ '$rc' = '0' ] && grep -q '^hook: ok' '$TMP/out'"
rc="$(run python3 "$ROOT/bin/governance" scaffold --template code-repo --out "$TMP/nogit")"
check "not a git repo yet ⇒ 'hook: pending' with the way out, exit 0" \
  "[ '$rc' = '0' ] && grep -q '^hook: pending .*git init' '$TMP/out'"
rm -f "$S/.git/hooks/pre-push"
rc="$(run python3 "$ROOT/bin/governance" scaffold --template code-repo --out "$S/sub")"
check "a directory INSIDE a repo ⇒ pending; the parent repo gets no hook" \
  "[ '$rc' = '0' ] && grep -q '^hook: pending' '$TMP/out' && [ ! -e '$S/.git/hooks/pre-push' ]"
printf '#!/bin/sh\n' > "$S/.git/hooks/pre-push"
rc="$(run python3 "$ROOT/bin/governance" scaffold --template code-repo --out "$S")"
check "someone else's pre-push hook ⇒ 'hook: refused', exit 1" "[ '$rc' = '1' ] && grep -q '^hook: refused' '$TMP/out'"

echo "mutants — each must turn a pinned case red"
mutant() {  # mutant <label> <sed expression> <command that must FAIL against the mutant to count as killed>
  local M="$TMP/mut"; rm -rf "$M"; mkdir -p "$M/bin"; cp -r "$ROOT/lib" "$M/lib"
  sed "$2" "$HC" > "$M/bin/hygiene-check"; chmod +x "$M/bin/hygiene-check"
  if cmp -s "$HC" "$M/bin/hygiene-check"; then bad "mutant '$1' did not apply"; return; fi
  if (HCM="$M/bin/hygiene-check"; eval "$3") >/dev/null 2>&1; then bad "mutant '$1' SURVIVED"; else ok "mutant '$1' killed"; fi
}
mutant "branch budget never compared" 's/"\$branch_count" -gt "\$BRANCH_BUDGET"/0 -gt 1/' \
  '[ "$(HYGIENE_BRANCH_BUDGET=5 run "$HCM" --repo "$C" --no-fetch)" = 1 ]'
mutant "worktree overrun does not refuse" '/OVER BUDGET: \$worktree_count/,/status=1/{s/status=1/:/}' \
  '[ "$(HYGIENE_WORKTREE_BUDGET=2 run "$HCM" --repo "$C" --no-fetch)" = 1 ]'
mutant "landed check dropped" 's/if git -C "\$REPO" merge-base --is-ancestor "\$sha"/if false \&\& git -C "$REPO" merge-base --is-ancestor "$sha"/' \
  'run "$HCM" --repo "$C" --no-fetch >/dev/null; grep -q "LANDED  landed" "$TMP/out"'
mutant "off by one: at-budget refused" 's/"\$stale_count" -gt "\$STALE_BUDGET"/"$stale_count" -ge "$STALE_BUDGET"/' \
  '[ "$(HYGIENE_STALE_BUDGET=1 run "$HCM" --repo "$C" --no-fetch)" = 0 ]'

echo
echo "hygiene-check.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
