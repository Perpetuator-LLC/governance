#!/usr/bin/env bash
# unpushed-work.test.sh — work that exists only on this machine is reported, work the forge has is
# not, and nothing is changed. Fixture: a bare origin, two clones, worktrees; never a real repo.
#
# Hand-derived for the fixture: exit 1, and exactly these hits:
#   repo app:        branch local-only +1 (never pushed) · branch ahead +1 (pushed, then one more)
#                    · branch deleted-unmerged +1 (pushed, then deleted on the forge unmerged: only a
#                      fetch --prune shows it; a stale tracking ref would call it pushed) · stashes 1
#   worktree app:    modified 1 · untracked 1
#   worktree wt-det: detached HEAD +1
#   repo solo:       NO REMOTE, main +1
# Silent: branch pushed (on the forge), branch gone-merged (deleted on the forge after merging into
# main, so main contains it), worktree wt-clean.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UW="$ROOT/bin/unpushed-work"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
q() { "$@" >/dev/null 2>&1; }
P="$TMP/projects"; mkdir -p "$P/worktrees"; O="$TMP/origin.git"; A="$P/app"
q git init -q --bare -b main "$O"; q git clone -q "$O" "$A"
c() { echo "$2" > "$A/$1"; q git -C "$A" add "$1"; q git -C "$A" commit -qm "$3"; }
c f base base; q git -C "$A" push -q origin main
q git -C "$A" switch -qc pushed; c p p pushed; q git -C "$A" push -q origin pushed
q git -C "$A" switch -qc gone-merged main; c g g gone; q git -C "$A" push -q origin gone-merged
q git -C "$A" switch -q main; q git -C "$A" merge -q --no-ff gone-merged -m merge; q git -C "$A" push -q origin main
q git -C "$A" push -q origin --delete gone-merged
q git -C "$A" switch -qc ahead main; c a a a1; q git -C "$A" push -q origin ahead; c a a2 a2
q git -C "$A" switch -qc local-only main; c l l local
q git -C "$A" switch -qc deleted-unmerged main; c x x lost; q git -C "$A" push -q origin deleted-unmerged
q git -C "$O" branch -D deleted-unmerged   # the forge loses it; this clone's tracking ref is now stale
q git -C "$A" switch -q main
echo s >> "$A/f"; q git -C "$A" stash push -m s
echo dirty >> "$A/f"; echo u > "$A/untracked.txt"
q git -C "$A" worktree add -q "$P/worktrees/wt-clean" pushed
q git -C "$A" worktree add -q --detach "$P/worktrees/wt-det" main; echo d > "$P/worktrees/wt-det/d"
q git -C "$P/worktrees/wt-det" add d; q git -C "$P/worktrees/wt-det" commit -qm det
q git init -q -b main "$P/solo"; echo s > "$P/solo/s"; q git -C "$P/solo" add s; q git -C "$P/solo" commit -qm s
mkdir -p "$P/plain"; echo x > "$P/plain/x"
q git clone -q --bare "$O" "$P/aaa-bare.git"                   # bare: no stash, no worktree to read
q git -C "$P/aaa-bare.git" fetch -q "$A" local-only:refs/heads/bare-only   # a commit only this bare clone has
q git -C "$A" worktree add -q "$P/aa-early" pushed              # sorts before app: must not stand in for it

snap() { for r in "$A" "$P/solo"; do git -C "$r" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/stash; git -C "$r" status --porcelain; done; }
before="$(snap)"
# The mirror, proven: without a fetch the stale tracking ref hides deleted-unmerged.
"$UW" --root "$P" --no-fetch "$A" | grep -q "deleted-unmerged" && bad "no-fetch saw deleted-unmerged (control broken)" \
  || ok "control: --no-fetch, judged on the stale ref, misses deleted-unmerged"
before="$(snap)"
out="$("$UW" --root "$P")"; rc=$?
after="$(snap)"
echo "$out" | sed 's/^/    /'

[ "$rc" -eq 1 ] && ok "exit 1 when work is only here" || bad "exit $rc, want 1"
has() { printf '%s\n' "$out" | grep -qE "$1" && ok "$2" || bad "$2"; }
hasnt() { printf '%s\n' "$out" | grep -qE "$1" && bad "$2" || ok "$2"; }
has  "^REPO .*/app — unpushed: ahead\+1, deleted-unmerged\+1, local-only\+1 · stashes: 1" \
     "app: ahead+1, deleted-unmerged+1 (gone from the forge: the fetch prunes the stale ref), local-only+1, 1 stash"
has  "^WORKTREE .*/app — modified 1 · untracked 1" "app worktree: modified 1, untracked 1"
has  "^WORKTREE .*/wt-det — .*detached HEAD \+1" "a detached HEAD's own commit is reported"
has  "^REPO .*/solo \(NO REMOTE\) — unpushed: main\+1" "a repo with no remote: every branch is unpushed"
has  "^NOT-GIT .*/plain" "a plain dir is listed as not-git"
hasnt "pushed\+|gone-merged" "control: pushed and merged-then-deleted branches are silent"
hasnt "wt-clean" "control: a clean worktree on a pushed branch is silent"
hasnt "^ERROR" "a bare repository is read without error"
has  "^REPO .*/aaa-bare.git — unpushed: bare-only\+1 · " "a bare clone: only its own branch is unpushed (judged by ls-remote)"
has  "^REPO .*/projects/app — " "the repo row names the main checkout, not a worktree that sorts first"
hasnt "^(Please|fatal|error:)" "git's multi-line errors do not leak onto their own lines"
[ "$before" = "$after" ] && ok "read-only: refs, stash and status unchanged" || bad "work changed"

echo "fails closed:"
"$UW" --root "$P" --no-fetch "$P/plain" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "a not-git dir alone does not fail the gate (it is backed up as files)" || bad "plain-only exit $rc"
git -C "$A" remote set-url origin "$TMP/missing.git"
out="$("$UW" --root "$P" "$A" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q "^ERROR .*fetch failed" && ok "a failed fetch exits 2, never clean" || bad "fetch failure: rc=$rc"
out="$("$UW" --root "$P" --no-fetch "$A")"
printf '%s\n' "$out" | grep -q "NOT fetched" && ok "--no-fetch says its verdict is as of the last fetch" || bad "no NOT fetched note"
git -C "$A" remote set-url origin "$O"
mkdir -p "$P/broken/.git"
"$UW" --root "$P" --no-fetch >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an unreadable repository exits 2" || bad "broken repo exit $rc"

# A bare mirror cloned now and never touched again: the forge moves on, so this clone's own objects
# fall behind what a LIVE `ls-remote` reports (bare repos are judged against a fresh ls-remote, never
# fetched — see the comment on `against` in repo_report). Found by mutation (quality sweep,
# 2026-10-14): removing the resulting refusal passed every existing case here, because the only bare
# fixture in the main sweep (aaa-bare.git) is never allowed to fall behind by anything later in this
# file. Isolated in its own root: mixed into the main sweep it would flip that run's own exit code
# from 1 (work found) to 2 (error), breaking an assertion that has nothing to do with this case.
B="$TMP/bare-check"; mkdir -p "$B"
q git clone -q --bare "$O" "$B/mirror.git"
q git clone -q "$O" "$TMP/elsewhere" 2>/dev/null
q git -C "$TMP/elsewhere" switch -qc forge-moved-on main
echo moved > "$TMP/elsewhere/m"; q git -C "$TMP/elsewhere" add m; q git -C "$TMP/elsewhere" commit -qm moved
q git -C "$TMP/elsewhere" push -q origin forge-moved-on
out="$("$UW" --root "$B" --no-fetch 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q "bare clone is behind its remote (1 remote heads not local): fetch it to judge" \
  && ok "a bare mirror missing a commit the LIVE forge now reports: refused, not silently judged stale" \
  || bad "a stale bare mirror was not refused (rc=$rc): $out"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
