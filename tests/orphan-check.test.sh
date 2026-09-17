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

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
