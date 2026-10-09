#!/usr/bin/env bash
# tests/commit-push.test.sh — bin/commit-push must never push a commit that did not land.
#
# The failure it guards: `git commit …; git push` in one command, a pre-commit hook refuses the
# commit, and the push publishes the branch at its BASE (or an old tip). Each case below states what
# must and must not happen, on a real bare origin, and the last one proves the test can see the
# failure: a copy of commit-push with the HEAD-moved check removed must be caught by case 2.
#
# Run:  bash tests/commit-push.test.sh

# shellcheck disable=SC2034  # the results are read inside the eval strings given to check()
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP="${COMMIT_PUSH_BIN:-$ROOT/bin/commit-push}"
[[ -x "$CP" ]] || { echo "FAIL: $CP missing or not executable"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/commit-push.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A bare origin and a clone on a NEW branch `feature` that origin does not have yet.
mkrepo() {
  local d="$TMP/$1"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/work" 2>/dev/null
  printf 'base\n' > "$d/work/a"; printf 'base\n' > "$d/work/b"
  git -C "$d/work" add a b; git -C "$d/work" commit -qm base; git -C "$d/work" push -q origin main 2>/dev/null
  git -C "$d/work" checkout -q -b feature
  printf 'subject\n\nbody\n' > "$d/msg"
  echo "$d"
}
remote_tip() { git -C "$1/work" ls-remote origin "refs/heads/$2" | cut -f1; }
hook() { mkdir -p "$1/work/.git/hooks"; printf '%s\n' '#!/bin/sh' "$2" > "$1/work/.git/hooks/pre-commit"; chmod +x "$1/work/.git/hooks/pre-commit"; }

echo "commit-push"
# 1. Control: the commit lands, the branch is pushed, the remote reads back the new HEAD.
d=$(mkrepo ok); base=$(git -C "$d/work" rev-parse HEAD); echo change >> "$d/work/a"
out=$(cd "$d/work" && "$CP" -F "$d/msg" -- a 2>&1); rc=$?
head=$(git -C "$d/work" rev-parse HEAD)
check "control: exit 0, HEAD is a new child of the base, origin/feature = HEAD" \
  '[ $rc = 0 ] && [ "$head" != "$base" ] && [ "$(git -C "$d/work" rev-parse HEAD^)" = "$base" ] && [ "$(remote_tip "$d" feature)" = "$head" ]'

# 2. THE CASE: a hook refuses the commit. Nothing is pushed: origin still has no `feature`.
d=$(mkrepo refused); base=$(git -C "$d/work" rev-parse HEAD); echo change >> "$d/work/a"; hook "$d" 'exit 1'
out=$(cd "$d/work" && "$CP" -F "$d/msg" -- a 2>&1); rc=$?
check "a refused commit: exit 1, HEAD unmoved, origin has NO feature branch, and it says nothing was pushed" \
  '[ $rc = 1 ] && [ "$(git -C "$d/work" rev-parse HEAD)" = "$base" ] && [ -z "$(remote_tip "$d" feature)" ] && grep -q "Nothing was pushed" <<<"$out"'

# 3. A formatter-like hook rewrites the file and refuses: refused, and the left-behind file is named.
d=$(mkrepo rewritten); echo change >> "$d/work/a"; hook "$d" 'echo reformatted >> a; exit 1'
out=$(cd "$d/work" && "$CP" -F "$d/msg" -- a 2>&1); rc=$?
check "a rewriting hook: exit 1, nothing pushed, the rewritten file named as left behind" \
  '[ $rc = 1 ] && [ -z "$(remote_tip "$d" feature)" ] && grep -q "Left behind" <<<"$out" && grep -q " a$" <<<"$out"'

# 4. Only the named paths are committed; another modified file stays out of the commit.
d=$(mkrepo pathspec); echo change >> "$d/work/a"; echo other >> "$d/work/b"
(cd "$d/work" && "$CP" -F "$d/msg" -- a >/dev/null 2>&1)
check "only the named path is in the commit; b stays modified and unstaged" \
  '[ "$(git -C "$d/work" show --name-only --format= HEAD)" = a ] && [ "$(git -C "$d/work" status --porcelain b)" = " M b" ]'

# 5. Usage refusals commit nothing: no paths, a missing message file, a detached HEAD.
d=$(mkrepo usage); base=$(git -C "$d/work" rev-parse HEAD); echo change >> "$d/work/a"
(cd "$d/work" && "$CP" -F "$d/msg" -- >/dev/null 2>&1); r1=$?
(cd "$d/work" && "$CP" -F "$d/nope" -- a >/dev/null 2>&1); r2=$?
git -C "$d/work" checkout -q --detach
(cd "$d/work" && "$CP" -F "$d/msg" -- a >/dev/null 2>&1); r3=$?
check "no paths, no message file, detached HEAD: each exit 2, HEAD unmoved" \
  '[ $r1 = 2 ] && [ $r2 = 2 ] && [ $r3 = 2 ] && [ "$(git -C "$d/work" rev-parse HEAD)" = "$base" ]'

# 6. --no-push commits and verifies, and leaves origin alone.
d=$(mkrepo nopush); echo change >> "$d/work/a"
(cd "$d/work" && "$CP" -F "$d/msg" --no-push -- a >/dev/null 2>&1); rc=$?
check "--no-push: exit 0, committed, origin has no feature branch" '[ $rc = 0 ] && [ -z "$(remote_tip "$d" feature)" ] && [ "$(git -C "$d/work" rev-list --count HEAD)" = 2 ]'

# 7. A push the remote rejects (it moved on meanwhile): exit 1, and it says the commit is local only.
d=$(mkrepo rejected); echo change >> "$d/work/a"
git clone -q "$d/origin.git" "$d/other" 2>/dev/null
(cd "$d/other" && git checkout -q -b feature && echo theirs > c && git add c && git commit -qm theirs && git push -q origin feature 2>/dev/null)
out=$(cd "$d/work" && "$CP" -F "$d/msg" -- a 2>&1); rc=$?
check "a rejected push: exit 1, 'committed locally only', origin keeps the other tip" \
  '[ $rc = 1 ] && grep -q "committed locally only" <<<"$out" && [ "$(remote_tip "$d" feature)" = "$(git -C "$d/other" rev-parse HEAD)" ]'

# 8. The test can see the failure: commit-push WITHOUT the HEAD-moved check publishes the base in case 2.
M="$TMP/commit-push.mutant"; sed 's/if \[ "\$rc" -ne 0 \] || \[ "\$after" = "\$before" \] || .*; then/if false; then/' "$CP" > "$M"; chmod +x "$M"
d=$(mkrepo mutant); echo change >> "$d/work/a"; hook "$d" 'exit 1'
(cd "$d/work" && "$M" -F "$d/msg" -- a >/dev/null 2>&1)
check "control on the test: the mutant applied, and it DID publish feature at the base (case 2 would catch it)" \
  '! cmp -s "$CP" "$M" && [ -n "$(remote_tip "$d" feature)" ]'

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
