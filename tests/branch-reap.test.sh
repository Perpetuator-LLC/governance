#!/usr/bin/env bash
# tests/branch-reap.test.sh — bin/branch-reap must never delete work, and must be safe enough to run
# UNATTENDED.
#
# The whole design rests on four properties, and each is pinned here because each one, if it
# silently broke, would destroy something nobody could name afterwards:
#   1. DRY RUN IS THE DEFAULT — deleting takes --apply, typed on purpose.
#   2. NEVER A FORCE DELETE. A branch is deleted only when the FORGE's default branch contains it (read
#      with ls-remote, deleted by a sha-guarded update-ref), else only by git's own `-d`; whatever `-d`
#      refuses is REPORTED and kept (#158).
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
# branches out before `-d` is ever reached, so `-d` is DEFENCE IN DEPTH, and its
# refusal is reachable only where the two checks disagree (6c). That makes
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

# --- 6c. THE REFUSAL PATH, reached behaviourally (#31) ---
# 6b says -d cannot be reached without breaking containment. It can: a branch whose commits are all in
# origin/main but NOT in its own upstream. -d compares against the upstream and refuses. That is the
# production refusal, every night: git printed three lines and the report showed only the last hint.
R2=$(mkrepo r2)
git -C "$R2" checkout -q -b feat/up
echo a > "$R2/a"; git -C "$R2" add a; git -C "$R2" commit -qm a
git -C "$R2" push -q -u origin feat/up 2>/dev/null                  # upstream = origin/feat/up at A
echo b > "$R2/b"; git -C "$R2" add b; git -C "$R2" commit -qm b     # local feat/up at B, upstream still A
git -C "$R2" checkout -q main; git -C "$R2" merge -q --ff-only feat/up; git -C "$R2" push -q origin main
out=$("$BR" --repo "$R2" 2>&1)
grep -q "would reap feat/up .*on the forge's main" <<<"$out" \
  && pass "dry run: a branch on the forge's main is promised, and the forge is named as the reason" \
  || fail "dry run did not promise the forge-contained branch: $(grep 'feat/up' <<<"$out")"
# With the forge reachable that branch is now reaped (6d). Point origin at nothing, so the only delete
# path left is git's own -d, and the refusal path is still reached for real.
git -C "$R2" remote set-url origin "$TMP/no-such-forge.git"
out=$("$BR" --apply --repo "$R2" --log "$TMP/r2.log" 2>&1)
if grep -q 'REFUSED feat/up' <<<"$out"; then
  pass "the upstream-disagreement case reaches git's refusal (a real refusal, not a mock)"
  grep -q 'REFUSED feat/up — git says: .*not fully merged' <<<"$out" \
    && pass "the reason printed is git's error: line" || fail "reason is not git's error: line: $(grep 'REFUSED feat/up' <<<"$out")"
  grep -q 'REFUSED feat/up — git says: .*[Dd]isable this message' <<<"$out" \
    && fail "the reason printed is still git's advice hint" || pass "no advice hint printed as the reason"
  grep -q 'every commit is in the cached origin/main, but the forge could not be asked; git compared against origin/feat/up' <<<"$out" \
    && pass "says what the cache holds, that the forge was not asked, and what -d compared against" || fail "no containment line naming the cache, the forge and the upstream"
  git -C "$R2" rev-parse --verify --quiet feat/up >/dev/null && pass "the refused branch still exists" || fail "REFUSED BRANCH WAS DELETED"
else
  fail "fixture did not reach a refusal: $(printf '%s' "$out" | tr '\n' '|')"
fi

# --- 6d. A STALE CHECKOUT reaps what the FORGE's default branch contains (#158) ---
# Lanes work on merge/* and nobody checks out the default branch, so the local default runs far behind
# the forge's. `git branch -d` gates on HEAD (or the upstream), so a branch that is already on the
# forge's default was refused there every night, and reported as if it might be unmerged work.
# Hand-derived: forge main = base + L; local main (HEAD) = base; feat/landed = base + L, no upstream;
# work/open = base + its own commit. Expected under --apply: feat/landed deleted and logged,
# work/open kept.
R3=$(mkrepo r3)
git -C "$R3" checkout -q -b feat/landed
echo l > "$R3/l"; git -C "$R3" add l; git -C "$R3" commit -qm landed
git -C "$R3" push -q origin feat/landed:main 2>/dev/null                 # the forge's main now holds L
git -C "$R3" checkout -q main                                            # local main stays at base
git -C "$R3" fetch -q origin
git -C "$R3" checkout -q -b work/open
echo o > "$R3/o"; git -C "$R3" add o; git -C "$R3" commit -qm open
git -C "$R3" checkout -q main
out=$("$BR" --apply --repo "$R3" --log "$TMP/r3.log" 2>&1)
git -C "$R3" rev-parse --verify --quiet feat/landed >/dev/null \
  && fail "stale checkout: a branch already on the forge's main was not reaped: $(grep 'feat/landed' <<<"$out" | tr '\n' '|')" \
  || pass "stale checkout: a branch already on the forge's main is reaped"
# The log is written BEFORE every delete attempt, so a logged line alone proves nothing: require the
# reap line too, or a refusal would pass this.
grep -q 'reaped feat/landed' <<<"$out" && awk -F'\t' '$3=="feat/landed"' "$TMP/r3.log" | grep -q . \
  && pass "and its delete is reported and in the undo log" || fail "the stale-checkout delete was not reported and logged"
git -C "$R3" rev-parse --verify --quiet work/open >/dev/null && pass "work/open (its own commit) is kept" \
  || fail "UNMERGED WORK WAS DELETED in the stale checkout"

# --- 6e. THE MIRROR: a cached origin/<default> that is AHEAD of the forge (the forge was rewound) ---
# The cache claims the branch is contained; the forge no longer holds it. Containment must be read from
# the forge, so this branch is kept. Hand-derived: cached origin/main = base + R; the forge's main
# reset to base by another clone; local main = base; feat/rewound = base + R. Expected: kept.
R4=$(mkrepo r4)
git -C "$R4" checkout -q -b feat/rewound
echo r > "$R4/r"; git -C "$R4" add r; git -C "$R4" commit -qm rewound
git -C "$R4" push -q origin feat/rewound:main 2>/dev/null
git -C "$R4" checkout -q main; git -C "$R4" fetch -q origin              # cache: origin/main = base + R
other="$TMP/r4-other"; git clone -q "$TMP/r4/origin.git" "$other" 2>/dev/null
git -C "$other" reset -q --hard HEAD~1; git -C "$other" push -q --force origin HEAD:main 2>/dev/null
out=$("$BR" --apply --repo "$R4" --log "$TMP/r4.log" 2>&1)
git -C "$R4" rev-parse --verify --quiet feat/rewound >/dev/null && pass "a branch the forge no longer holds is kept, whatever the cache says" \
  || fail "DELETED a branch on the strength of a stale cache: the forge does not hold it"

# --- 6f. A forge that cannot be asked is never read as an answer ---
# Unreachable origin: no forge verdict, so the only delete path left is git's own `-d`, which refuses
# here (HEAD lacks the commit). Hand-derived: same shape as 6d, origin URL then pointed at nothing.
R5=$(mkrepo r5)
git -C "$R5" checkout -q -b feat/noforge
echo n > "$R5/n"; git -C "$R5" add n; git -C "$R5" commit -qm noforge
git -C "$R5" push -q origin feat/noforge:main 2>/dev/null
git -C "$R5" checkout -q main; git -C "$R5" fetch -q origin
git -C "$R5" remote set-url origin "$TMP/no-such-forge.git"
out=$("$BR" --apply --repo "$R5" --log "$TMP/r5.log" 2>&1)
git -C "$R5" rev-parse --verify --quiet feat/noforge >/dev/null && pass "unreachable forge: nothing deleted on a cache alone" \
  || fail "DELETED with no forge answer"
grep -q 'the forge could not be asked' <<<"$out" && pass "and the report says the forge could not be asked" \
  || fail "the report does not say the forge could not be asked: $(printf '%s' "$out" | tr '\n' '|')"

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
