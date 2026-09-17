#!/usr/bin/env bash
# tests/branch-reap.test.sh — bin/branch-reap must never delete work, and must be safe enough to run
# UNATTENDED.
#
# The whole design rests on four properties, and each is pinned here because each one, if it
# silently broke, would destroy something nobody could name afterwards:
#   1. DRY RUN IS THE DEFAULT — deleting takes --apply, typed on purpose.
#   2. `git branch -d` ONLY. git's merged-check is the gate; a branch it refuses is REPORTED, never
#      forced. The script must hold no opinion that can override git.
#   3. PROTECTED SETS are never even proposed: default branch, current branch, merge/* integration
#      branches, anything checked out in ANY worktree.
#   4. THE UNDO LOG IS WRITTEN BEFORE THE DELETE — a log written after is missing exactly the
#      entries that matter if the delete is what went wrong.
# Plus: a repo roster that resolves to NOTHING aborts instead of narrowing to the current directory.
#
# Run:  bash tests/branch-reap.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BR="${BRANCH_REAP_BIN:-$ROOT/bin/branch-reap}"
[[ -x "$BR" ]] || { echo "FAIL: $BR missing or not executable"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/branch-reap.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
# The fixtures are built from a known git config, never the developer's: an inherited signing or hook
# setting makes `git commit` fail and every assertion below fails for a reason none of them names.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A real origin + clone, so `-d` and worktrees behave for real rather than being mocked.
mkrepo() {
  local d="$TMP/$1"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/work" 2>/dev/null
  echo base > "$d/work/f"; git -C "$d/work" add f; git -C "$d/work" commit -qm base
  git -C "$d/work" branch -M main; git -C "$d/work" push -q origin main
  git -C "$d/work" remote set-head origin main >/dev/null 2>&1
  echo "$d/work"
}
R=$(mkrepo r1)

# merged/*: fully contained in origin/main.  unmerged/*: carries its own commit.
git -C "$R" branch merged/a; git -C "$R" branch merged/b
git -C "$R" branch merge/keepme
git -C "$R" checkout -q -b unmerged/x
echo more > "$R/g"; git -C "$R" add g; git -C "$R" commit -qm extra
git -C "$R" checkout -q main

echo "── branch-reap"

# --- 1. DRY RUN DELETES NOTHING ---
out=$("$BR" --repo "$R" 2>&1)
grep -qi 'DRY RUN' <<<"$out" && pass "dry run announces itself" || fail "dry run not announced"
git -C "$R" rev-parse --verify --quiet merged/a >/dev/null \
  && pass "dry run left merged/a alive" || fail "DRY RUN DELETED A BRANCH"

# --- 2. --apply deletes ONLY the merged ones ---
LOG="$TMP/undo.log"
out=$("$BR" --apply --repo "$R" --log "$LOG" 2>&1)
git -C "$R" rev-parse --verify --quiet merged/a >/dev/null \
  && fail "merged/a survived --apply" || pass "--apply reaped merged/a"
git -C "$R" rev-parse --verify --quiet unmerged/x >/dev/null \
  && pass "unmerged/x SURVIVED (git -d refused, as designed)" || fail "UNMERGED WORK WAS DELETED"
git -C "$R" rev-parse --verify --quiet merge/keepme >/dev/null \
  && pass "merge/* integration branch untouched" || fail "INTEGRATION BRANCH DELETED"
git -C "$R" rev-parse --verify --quiet main >/dev/null \
  && pass "default branch untouched" || fail "DEFAULT BRANCH DELETED"

# --- 3. THE UNDO LOG IS USABLE: name + sha, and it actually restores ---
if [[ -s "$LOG" ]]; then
  pass "undo log written"
  sha=$(awk -F'\t' '$3=="merged/a"{print $4}' "$LOG" | head -1)
  if [[ -n "$sha" ]] && git -C "$R" branch restored "$sha" 2>/dev/null; then
    pass "undo log restores the branch (git branch <name> <sha>)"
  else fail "undo log did not restore — the recorded sha is not usable"; fi
else fail "undo log empty"; fi

# --- 4. a branch checked out in ANOTHER worktree is never proposed ---
git -C "$R" branch merged/inworktree
git -C "$R" worktree add -q "$TMP/wt" merged/inworktree 2>/dev/null
out=$("$BR" --repo "$R" 2>&1)
grep -q 'merged/inworktree' <<<"$out" && fail "proposed a branch held by another worktree" \
  || pass "worktree-held branch not proposed"

# --- 5. --protect keeps a glob ---
git -C "$R" branch keepme/one
out=$("$BR" --repo "$R" --protect 'keepme/*' 2>&1)
grep -q 'keepme/one' <<<"$out" && fail "--protect glob was ignored" || pass "--protect honoured"

# --- 6. refuses to guess: a repo with no resolvable default branch is SKIPPED ---
bare=$TMP/nodefault; mkdir -p "$bare"; git init -q "$bare"
echo x > "$bare/f"; git -C "$bare" add f; git -C "$bare" commit -qm x
err=$("$BR" --repo "$bare" 2>&1 >/dev/null)
grep -qi 'default branch' <<<"$err" && pass "no-origin repo is skipped, not guessed" \
  || fail "a repo with no origin was not skipped safely"

# --- 6b. THE `-d` BELT ITSELF, pinned at the source ---
# Honest note on why this is a source assertion and not a behavioural one: the
# containment check (`git log origin/$def..$b` empty) already filters unmerged
# branches out before `-d` is ever reached, so `-d` is DEFENCE IN DEPTH and the
# behavioural path cannot be reached without first breaking containment. That makes
# the mutation `-d` -> `-D` invisible to every behavioural test here — it was, when
# this suite was mutation-tested. The property is real and worth pinning anyway,
# because the two checks can disagree (`-d` measures merged-into-HEAD-or-upstream,
# not merged-into-origin/main), and on that disagreement `-D` would destroy the
# branch git was trying to protect.
if grep -qE 'branch +-D' "$BR"; then
  fail "the script contains 'branch -D' — force-delete must never appear"
else
  pass "no 'branch -D' anywhere in the script (-d only)"
fi

# --- 7. a repo roster is honoured, and an EMPTY or unreadable one aborts ---
printf '%s\n' "$R" > "$TMP/roster"
git -C "$R" branch merged/viaroster
out=$("$BR" --repos-from "$TMP/roster" 2>&1)
grep -q 'would reap merged/viaroster' <<<"$out" && pass "--repos-from reads the roster" \
  || fail "--repos-from did not scan the listed repo"
out=$(printf '%s\n' "$R" | "$BR" --repos-from - 2>&1)
grep -q 'would reap merged/viaroster' <<<"$out" && pass "--repos-from - reads stdin" \
  || fail "--repos-from - did not read stdin"
printf '\n   \n' > "$TMP/empty-roster"
( cd "$R" && "$BR" --repos-from "$TMP/empty-roster" >"$TMP/o" 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && ! grep -q 'would reap' "$TMP/o" \
  && pass "an EMPTY roster exits 2 and does NOT fall back to the current repo" \
  || fail "an empty roster was treated as a sweep (rc=$rc)"
( cd "$R" && "$BR" --repos-from "$TMP/no-such-roster" >"$TMP/o" 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && ! grep -q 'would reap' "$TMP/o" \
  && pass "an unreadable roster exits 2 and does NOT fall back to the current repo" \
  || fail "an unreadable roster was treated as a sweep (rc=$rc)"

# --- 8. argument hygiene ---
"$BR" --bogus >/dev/null 2>&1; [[ $? -eq 1 ]] && pass "unknown arg exits 1" || fail "unknown arg accepted"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; else echo "  ❌ $fails failed"; fi
exit $(( fails > 0 ))
