#!/usr/bin/env bash
# held-branches.test.sh — a pushed hold that never reached main or a rolling branch is REPORTED;
# anything that did reach one is not. Fixture: a bare origin plus a clone, never a real repo.
#
# The two cases that decide the design are pinned here:
#   - FOLDED BY MERGE: the commit is an ANCESTOR of the rolling branch. `git cherry` prints nothing at
#     all for it, so a check built only on cherry's `-` misses it. The first draft of this check did.
#   - DROPPED WITH A COLLIDING SUBJECT: a never-folded "fix tests" while main has an unrelated
#     "fix tests". Matching SUBJECTS calls it landed; this must report it.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HB="$ROOT/bin/held-branches"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
O="$TMP/origin.git"; C="$TMP/clone"
git init -q --bare -b main "$O"
git clone -q "$O" "$C" 2>/dev/null
g() { git -C "$C" "$@"; }
commit() { printf '%s\n' "$2" > "$C/$1"; g add "$1"; g commit -qm "$3"; }

commit base base "base"; g push -q origin main
g switch -qc merge/lane; g push -q origin merge/lane; g switch -q main

# landed by merge into main — not --no-merged at all
g switch -qc landed; commit l l "landed work"; g switch -q main; g merge -q --no-ff landed -m "merge landed"
# landed on main under a NEW hash (cherry-pick) — cherry says '-'
g switch -qc landed-newhash; commit n n "landed under a new hash"; g switch -q main; g cherry-pick -q landed-newhash >/dev/null 2>&1 || g cherry-pick landed-newhash >/dev/null
# unrelated main commit whose subject collides with a dropped hold below
commit t t "fix tests"
g push -q origin main

# folded by MERGE into the rolling branch (ancestor) — pending, not dropped
g switch -qc folded-merge main~2 2>/dev/null || g switch -qc folded-merge main; commit f f "folded by merge"
g switch -q merge/lane; g merge -q --no-ff folded-merge -m "fold"
# folded onto the rolling branch under a NEW hash — pending, not dropped
g switch -qc folded-newhash main; commit h h "folded under a new hash"
g switch -q merge/lane; g cherry-pick folded-newhash >/dev/null
g push -q origin merge/lane

# dropped: never folded, subject collides with main's "fix tests"
g switch -qc dropped-collide main; commit d d "fix tests"
# dropped: plain — authored by someone else, so the report must say WHOSE it is
g switch -qc dropped-plain main
printf 'p\n' > "$C/p"; g add p; GIT_AUTHOR_NAME="Other Person" g commit -qm "a decision nobody folded"
# partly folded: one commit folded, one dropped — must still be a finding
g switch -qc partial main; commit q1 q1 "partial one"; commit q2 q2 "partial two"
g switch -q merge/lane; g cherry-pick "partial~1" >/dev/null; g push -q origin merge/lane

for b in landed landed-newhash folded-merge folded-newhash dropped-collide dropped-plain partial; do g push -q origin "$b"; done
g switch -q main

echo "held-branches"
rc=0; "$HB" "$C" >"$TMP/out" 2>"$TMP/err" || rc=$?
check "exit 1 when anything is unfolded" "[ '$rc' = '1' ]"
check "a dropped hold is reported" "grep -q 'origin/dropped-plain ' '$TMP/out'"
check "…with the tip's AUTHOR, the first adjudication question (whose work is this?)" \
  "grep 'origin/dropped-plain ' '$TMP/out' | grep -q 'by Other Person'"
check "a dropped hold whose SUBJECT collides with main is still reported (subject-matching would call it landed)" \
  "grep -q 'origin/dropped-collide ' '$TMP/out'"
check "a partly folded branch is reported, with its split" "grep -q 'origin/partial  1 not upstream · 1 folded' '$TMP/out'"
check "a branch MERGED into the rolling branch is folded, not dropped (cherry prints nothing for an ancestor)" \
  "! grep -q 'origin/folded-merge ' '$TMP/out'"
check "a branch folded under a NEW hash is folded, not dropped" "! grep -q 'origin/folded-newhash ' '$TMP/out'"
check "…and the folded branches are counted, not silently dropped from view" "grep -q '2 branch(es) fully folded' '$TMP/out'"
check "work merged into main is not reported" "! grep -q 'origin/landed ' '$TMP/out'"
check "work that reached main under a new hash is not reported" "! grep -q 'origin/landed-newhash ' '$TMP/out'"
check "the rolling branch itself is never listed (orphan-check's job)" "! grep -q 'origin/merge/' '$TMP/out'"
check "exactly three findings" "[ \"\$(grep -c 'not upstream' '$TMP/out')\" = 3 ]"
check "the finding says to adjudicate by content, on stderr" "grep -q 'Adjudicate by CONTENT' '$TMP/err'"

# a clean repo: exit 0
for b in dropped-collide dropped-plain partial; do g push -q origin --delete "$b"; g branch -qD "$b"; done
rc=0; "$HB" "$C" >"$TMP/out" 2>"$TMP/err" || rc=$?
check "nothing unfolded ⇒ exit 0" "[ '$rc' = '0' ]"

# setup errors are exit 2, never a clean report
rc=0; "$HB" "$TMP/not-a-repo" >/dev/null 2>&1 || rc=$?
check "not a repo ⇒ exit 2" "[ '$rc' = '2' ]"
rc=0; "$HB" --bogus >/dev/null 2>&1 || rc=$?
check "unknown flag ⇒ exit 2" "[ '$rc' = '2' ]"
mkdir -p "$TMP/noremote"; git -C "$TMP/noremote" init -q
rc=0; "$HB" "$TMP/noremote" >/dev/null 2>&1 || rc=$?
check "fetch failure ⇒ exit 2, never a report on stale refs" "[ '$rc' = '2' ]"

# --- --local: commits that exist ONLY on this machine ---------------------------------------------
# Measured: two finished fixes sat unpushed on local branches for three weeks across rotations. The
# remote scan cannot see a branch that was never pushed; this is the case the flag exists for.
O2="$TMP/origin2.git"; C2="$TMP/clone2"
git init -q --bare -b main "$O2"; git clone -q "$O2" "$C2" 2>/dev/null
h() { git -C "$C2" "$@"; }
c2() { printf '%s\n' "$2" > "$C2/$1"; h add "$1"; h commit -qm "$3"; }
c2 base base "base"; h push -q origin main
h switch -qc merge/lane; h push -q origin merge/lane; h switch -q main
h switch -qc fix/never-pushed; c2 np np "finished fix, never pushed"
h switch -qc feat/pushed main; c2 pu pu "pushed, not folded"; h push -q origin feat/pushed
h switch -qc fix/landed-newhash main; c2 lh lh "landed under a new hash"
h switch -q main; h cherry-pick fix/landed-newhash >/dev/null; h push -q origin main
h switch -qc fix/folded-newhash main; c2 fh fh "folded under a new hash"
h switch -q merge/lane; h cherry-pick fix/folded-newhash >/dev/null; h push -q origin merge/lane
h switch -q main; c2 um um "unpushed commit on main"
# a local branch whose ONLY local-only commit is a merge: no work of its own is at risk
h switch -qc merge-only origin/feat/pushed 2>/dev/null; h merge -q --no-ff origin/merge/lane -m "Merge branch 'merge/lane' into merge-only"; h switch -q main

rc=0; "$HB" --no-fetch "$C2" >"$TMP/out" 2>"$TMP/err" || rc=$?
check "WITHOUT --local, a never-pushed fix is invisible (the gap the flag closes)" \
  "! grep -q 'fix/never-pushed' '$TMP/out'"
rc=0; "$HB" --no-fetch --local "$C2" >"$TMP/out" 2>"$TMP/err" || rc=$?
check "--local: exit 1 when this machine holds the only copy of anything" "[ '$rc' = '1' ]"
check "--local: a never-pushed fix is reported as the ONLY copy" \
  "grep -q 'fix/never-pushed (local)  1 commit(s) ONLY ON THIS MACHINE' '$TMP/out'"
check "--local: an unpushed commit on the default branch is reported too" "grep -q ' main (local)  1 commit' '$TMP/out'"
check "--local: a PUSHED branch gets no (local) row — the remote row covers it, never listed twice" \
  "! grep -q 'feat/pushed (local)' '$TMP/out' && grep -q 'origin/feat/pushed ' '$TMP/out'"
check "--local: a local commit that landed on main under a new hash is not reported" "! grep -q 'fix/landed-newhash' '$TMP/out'"
check "--local: a local commit folded onto a pushed rolling branch under a new hash is not reported" \
  "! grep -q 'fix/folded-newhash (local)' '$TMP/out'"
check "--local: stderr says a (local) row is the only copy" "grep -q 'ONLY copy' '$TMP/err'"
check "--local: a branch whose only local-only commit is a MERGE gets no row (first live run's noise)" \
  "! grep -q 'merge-only (local)' '$TMP/out'"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
