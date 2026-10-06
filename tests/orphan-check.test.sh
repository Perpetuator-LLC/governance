#!/usr/bin/env bash
# orphan-check.test.sh — commits stranded on a rolling branch must be caught
#
# The failure this catches is a commit that exists on a rolling branch and never
# reaches main, while everything looks green. So the test builds that exact
# state in real git repos — a clean one and a stranded one — and asserts the
# tool separates them and reports the stranded commit's ticket references.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/orphan-check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Throwaway fixtures must not inherit the developer's git config. An inherited commit.gpgsign over an
# agent that intermittently refuses makes `git commit` fail, the fixture has NO commits, and every
# assertion below fails for a reason none of them names. So the suite builds its own config.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false

pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "orphan-check"
check "the script is executable" "[ -x '$CHECK' ]"

# --- build a bare "origin" plus a working clone -----------------------------
make_repo() { # $1 name
  local name="$1"
  git init -q --bare "$TMP/$name.git"
  git clone -q "$TMP/$name.git" "$TMP/$name" 2>/dev/null
  echo "seed" > "$TMP/$name/f.txt"
  git -C "$TMP/$name" add f.txt
  git -C "$TMP/$name" commit -qm "seed"
  git -C "$TMP/$name" branch -M main
  git -C "$TMP/$name" push -q -u origin main
}

# CLEAN: a rolling branch identical to main — nothing stranded.
make_repo clean
git -C "$TMP/clean" checkout -qb merge/tester
git -C "$TMP/clean" push -q -u origin merge/tester

# STRANDED: a commit on the rolling branch that main never got.
make_repo stranded
git -C "$TMP/stranded" checkout -qb merge/tester
echo "work" >> "$TMP/stranded/f.txt"
git -C "$TMP/stranded" commit -qam "feat: work that never reached main (#123)"
git -C "$TMP/stranded" push -q -u origin merge/tester

# --- the clean repo must be silent and exit 0 -------------------------------
out_clean="$("$CHECK" --no-fetch "$TMP/clean" 2>&1)"; rc_clean=$?
check "a rolling branch level with main exits 0" "[ '$rc_clean' -eq 0 ]"
check "...and says nothing is stranded" "grep -q 'nothing stranded' <<< \"\$out_clean\""

# --- the stranded repo must be caught ---------------------------------------
out_bad="$("$CHECK" --no-fetch "$TMP/stranded" 2>&1)"; rc_bad=$?
check "a stranded commit exits 1" "[ '$rc_bad' -eq 1 ]"
check "...names the rolling branch" "grep -q 'merge/tester' <<< \"\$out_bad\""
check "...shows the stranded commit subject" \
  "grep -q 'never reached main' <<< \"\$out_bad\""
check "...extracts the referenced ticket (#123)" \
  "grep -q '#123' <<< \"\$out_bad\""
check "...tells the reader to check for an open PR" \
  "grep -qi 'OPEN PR' <<< \"\$out_bad\""

# --- both together: one bad repo must fail the whole run --------------------
out_both="$("$CHECK" --no-fetch "$TMP/clean" "$TMP/stranded" 2>&1)"; rc_both=$?
check "a clean repo does not mask a stranded one" "[ '$rc_both' -eq 1 ]"
check "both repos are counted as checked" "grep -q '2 repo(s) checked' <<< \"\$out_both\""

# --- a repo with no rolling branch at all is not a finding ------------------
make_repo norolling
out_nr="$("$CHECK" --no-fetch "$TMP/norolling" 2>&1)"; rc_nr=$?
check "a repo with no merge/* branch exits 0" "[ '$rc_nr' -eq 0 ]"

# --- a non-repo path must not be silently counted as clean ------------------
mkdir -p "$TMP/notarepo"
out_na="$("$CHECK" --no-fetch "$TMP/notarepo" 2>&1)"
check "a non-repo is not counted as a checked repo" \
  "grep -q '0 repo(s) checked' <<< \"\$out_na\""

# --- scope selection: a roster that resolves to nothing must refuse, not narrow ----
printf '%s\n' "$TMP/stranded" > "$TMP/roster"
out_r="$("$CHECK" --no-fetch --repos-from "$TMP/roster" 2>&1)"; rc_r=$?
check "--repos-from scans the listed repo" "[ '$rc_r' -eq 1 ] && grep -q '1 repo(s) checked' <<< \"\$out_r\""
printf '\n  \n' > "$TMP/empty-roster"
out_e="$(cd "$TMP/stranded" && "$CHECK" --no-fetch --repos-from "$TMP/empty-roster" 2>&1)"; rc_e=$?
check "an EMPTY roster exits 2 and scans nothing (no fallback to the current repo)" \
  "[ '$rc_e' -eq 2 ] && ! grep -q 'repo(s) checked' <<< \"\$out_e\""
"$CHECK" --no-fetch --repos-from "$TMP/no-such-roster" >/dev/null 2>&1; rc_m=$?
check "an unreadable roster exits 2" "[ '$rc_m' -eq 2 ]"

mkdir -p "$TMP/tree"
for r in clean stranded; do ln -s "$TMP/$r" "$TMP/tree/$r"; done
mkdir -p "$TMP/tree/plain-dir"
out_a="$("$CHECK" --no-fetch --all "$TMP/tree" 2>&1)"; rc_a=$?
check "--all DIR finds every repo directly under DIR, and skips non-repos" \
  "[ '$rc_a' -eq 1 ] && grep -q '2 repo(s) checked' <<< \"\$out_a\""
"$CHECK" --no-fetch --all "$TMP/tree/plain-dir" >/dev/null 2>&1; rc_ae=$?
check "--all over a directory with NO repos exits 2, not a clean result" "[ '$rc_ae' -eq 2 ]"
"$CHECK" --no-fetch --all >/dev/null 2>&1; rc_an=$?
check "--all without a directory is a usage error (exit 2, never the findings code)" "[ '$rc_an' -eq 2 ]"

out_p="$(cd "$TMP/stranded" && "$CHECK" --no-fetch 2>&1)"; rc_p=$?
check "no arguments checks the CURRENT repo" "[ '$rc_p' -eq 1 ] && grep -q '1 repo(s) checked' <<< \"\$out_p\""

# --- governance#59: adjudicate by CONTENT, dedupe origins, remember verdicts by TIP ---------------
# SQUASHED: the rolling branch's commit reached main as a different commit (a squash merge). Ancestry
# calls it stranded forever; its content is on main.
make_repo squashed
git -C "$TMP/squashed" checkout -qb merge/tester
echo "squashed work" >> "$TMP/squashed/f.txt"
git -C "$TMP/squashed" commit -qam "feat: work that landed as a squash (#7)"
git -C "$TMP/squashed" push -q -u origin merge/tester
git -C "$TMP/squashed" checkout -q main
echo "squashed work" >> "$TMP/squashed/f.txt"
git -C "$TMP/squashed" commit -qam "squash of #7"
git -C "$TMP/squashed" push -q origin main
out_s="$("$CHECK" --no-fetch "$TMP/squashed" 2>&1)"; rc_s=$?
check "a branch whose content landed as a squash is NOT a candidate (exit 0)" "[ '$rc_s' -eq 0 ]"
check "...and the report says its content is on main, counted apart" \
  "grep -q 'CONTENT is on main' <<< \"\$out_s\" && grep -q '1 landed by content' <<< \"\$out_s\""
check "the stranded branch states its content verdict" \
  "grep -q 'content: MISSING' <<< \"\$out_bad\""

# MERGED-MAIN: a rolling branch that pulled main in counts only its own commits.
make_repo pulled
git -C "$TMP/pulled" checkout -qb merge/tester
echo "own" > "$TMP/pulled/own.txt"; git -C "$TMP/pulled" add own.txt; git -C "$TMP/pulled" commit -qm "feat: own work"
git -C "$TMP/pulled" checkout -q main; echo "m" > "$TMP/pulled/m.txt"; git -C "$TMP/pulled" add m.txt
git -C "$TMP/pulled" commit -qm "main moved"; git -C "$TMP/pulled" push -q origin main
git -C "$TMP/pulled" checkout -q merge/tester; git -C "$TMP/pulled" merge -q --no-edit main
git -C "$TMP/pulled" push -q -u origin merge/tester
out_m="$("$CHECK" --no-fetch "$TMP/pulled" 2>&1)"
check "a branch that merged main counts its own commit only (merge commits are not work)" \
  "grep -q '1 commit(s) on merge/tester' <<< \"\$out_m\""

# DUPLICATE ORIGIN: two checkouts of one repository are one repository.
git clone -q "$TMP/stranded.git" "$TMP/stranded-twin" 2>/dev/null
out_d="$("$CHECK" --no-fetch "$TMP/stranded" "$TMP/stranded-twin" 2>&1)"; rc_d=$?
check "a second checkout of the same origin is skipped and named, not counted twice" \
  "[ '$rc_d' -eq 1 ] && grep -q '1 repo(s) checked' <<< \"\$out_d\" && grep -q 'same origin' <<< \"\$out_d\""

# KNOWN, keyed on the TIP: a verdict already given suppresses that tip, and only that tip.
tip="$(git -C "$TMP/stranded" rev-parse origin/merge/tester)"
printf '# verdicts\n%s abandoned, PR closed with a reason\n' "$tip" > "$TMP/known"
out_k="$("$CHECK" --no-fetch --known "$TMP/known" "$TMP/stranded" 2>&1)"; rc_k=$?
check "a branch whose TIP has a recorded verdict is not a candidate, and the verdict is shown" \
  "[ '$rc_k' -eq 0 ] && grep -q 'already adjudicated: abandoned, PR closed' <<< \"\$out_k\""
echo "more" >> "$TMP/stranded/f.txt"; git -C "$TMP/stranded" commit -qam "feat: new work after the verdict"
git -C "$TMP/stranded" push -q origin merge/tester
out_k2="$("$CHECK" --no-fetch --known "$TMP/known" "$TMP/stranded" 2>&1)"; rc_k2=$?
check "...a new push moves the tip, so the branch surfaces again" \
  "[ '$rc_k2' -eq 1 ] && grep -q 'new work after the verdict' <<< \"\$out_k2\""
"$CHECK" --no-fetch --known "$TMP/no-such-known" "$TMP/stranded" >/dev/null 2>&1; rc_kn=$?
check "an unreadable --known file is a usage error (exit 2)" "[ '$rc_kn' -eq 2 ]"

# AMBIGUOUS: the content check itself cannot tell (a file absent at its path; a same-named file on main
# holds only part of it). That stays a candidate.
make_repo partial
git -C "$TMP/partial" checkout -qb merge/tester
mkdir -p "$TMP/partial/lib"; printf "def partial_one():\n    return 'partial-two'\n" > "$TMP/partial/lib/partial.py"
git -C "$TMP/partial" add lib; git -C "$TMP/partial" commit -qm "feat: partial"; git -C "$TMP/partial" push -q -u origin merge/tester
git -C "$TMP/partial" checkout -q main; mkdir -p "$TMP/partial/pkg"
printf "def partial_one():\n    return 'something-else'\n" > "$TMP/partial/pkg/partial.py"
git -C "$TMP/partial" add pkg; git -C "$TMP/partial" commit -qm "pkg"; git -C "$TMP/partial" push -q origin main
out_c="$("$CHECK" --no-fetch "$TMP/partial" 2>&1)"; rc_c=$?
check "when the content check answers CANNOT-TELL, the branch stays a candidate" \
  "[ '$rc_c' -eq 1 ] && grep -q 'content: CANNOT-TELL' <<< \"\$out_c\""

# FAIL SAFE: with no content check available, a squashed branch stays a candidate, never clean.
mkdir -p "$TMP/bare-bin" && cp "$CHECK" "$TMP/bare-bin/orphan-check"
out_f="$("$TMP/bare-bin/orphan-check" --no-fetch "$TMP/squashed" 2>&1)"; rc_f=$?
check "without landed-check, a branch ahead is CANNOT-TELL and stays a candidate" \
  "[ '$rc_f' -eq 1 ] && grep -q 'content: CANNOT-TELL' <<< \"\$out_f\""

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
