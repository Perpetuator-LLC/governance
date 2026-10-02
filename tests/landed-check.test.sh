#!/usr/bin/env bash
# tests/landed-check.test.sh — bin/landed-check decides by CONTENT, in three outcomes, with both
# controls the archive rule requires: a squash-merged branch reads LANDED, one unlanded line reads
# MISSING. Every expected value below is derived by hand from the fixture, not read from the tool.
#
# Fixture (one bare origin, one clone; origin/main is the base):
#   base commit       app.py = def alpha(): / return 'alpha-value'
#   feat/squashed     + app.py: def beta(): / return 'beta-value' ; + util/helpers.py: def helper_one(): / return 'helper-one'
#   main              squash of feat/squashed (same content, different commit)        -> LANDED (control)
#   feat/one-missing  + app.py: the two beta lines + GAMMA_SETTING = 'gamma-unlanded'  -> MISSING, app.py 1/3
#   feat/ancestor     + notes.txt, fast-forwarded into main                            -> LANDED, ancestor
#   feat/newfile      + docs/never-landed.md (one line)                                -> MISSING, not by path or name
#   feat/moved        + lib/mover.py; main holds the same two lines at pkg/mover.py    -> LANDED (a move)
#   feat/moved-part   + lib/partial.py (2 lines); main's pkg/partial.py holds 1 of them -> CANNOT-TELL
#   feat/delete       - app.py's two alpha lines; main still has both                  -> MISSING, 2/2 still there
#   feat/empty        an empty commit                                                   -> LANDED, nothing to land
#   no/such           not a ref                                                         -> CANNOT-TELL
# Exit: all LANDED 0 · any MISSING 1 · CANNOT-TELL and no MISSING 2.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LC="$ROOT/bin/landed-check"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/landed-check.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

git init -q --bare "$TMP/origin.git"; git clone -q "$TMP/origin.git" "$TMP/w" 2>/dev/null; R="$TMP/w"
c() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; }
printf "def alpha():\n    return 'alpha-value'\n" > "$R/app.py"; c base
git -C "$R" branch -M main; git -C "$R" push -q origin main; git -C "$R" remote set-head origin main >/dev/null 2>&1
BASE=$(git -C "$R" rev-parse HEAD)

git -C "$R" checkout -q -b feat/squashed
printf "\ndef beta():\n    return 'beta-value'\n" >> "$R/app.py"
mkdir -p "$R/util"; printf "def helper_one():\n    return 'helper-one'\n" > "$R/util/helpers.py"; c "beta + helpers"
git -C "$R" checkout -q -b feat/one-missing "$BASE"
printf "\ndef beta():\n    return 'beta-value'\nGAMMA_SETTING = 'gamma-unlanded'\n" >> "$R/app.py"; c "beta + gamma"
git -C "$R" checkout -q -b feat/newfile "$BASE"
mkdir -p "$R/docs"; echo "This text never reached main." > "$R/docs/never-landed.md"; c newfile
git -C "$R" checkout -q -b feat/moved "$BASE"
mkdir -p "$R/lib"; printf "def moved_function():\n    return 'moved-content'\n" > "$R/lib/mover.py"; c moved
git -C "$R" checkout -q -b feat/moved-part "$BASE"
mkdir -p "$R/lib"; printf "def partial_one():\n    return 'partial-two'\n" > "$R/lib/partial.py"; c movedpart
git -C "$R" checkout -q -b feat/delete "$BASE"
printf "" > "$R/app.py"; c "drop alpha"
git -C "$R" checkout -q -b feat/empty "$BASE"; git -C "$R" commit -q --allow-empty -m empty

git -C "$R" checkout -q main
git -C "$R" merge -q --squash feat/squashed >/dev/null; git -C "$R" commit -qm "squash: beta + helpers"
git -C "$R" checkout -q -b feat/ancestor; echo n > "$R/notes.txt"; c notes
git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only feat/ancestor
mkdir -p "$R/pkg"; printf "def moved_function():\n    return 'moved-content'\n" > "$R/pkg/mover.py"
printf "def partial_one():\n    return 'something-else'\n" > "$R/pkg/partial.py"; c "pkg"
git -C "$R" push -q origin main; git -C "$R" fetch -q origin

verdict() { local o; o=$("$LC" --repo "$R" "$1"); awk -v b="$1" '$2==b{print $1}' <<<"$o"; }
# Output is captured before grep: under pipefail, `tool | grep -q` reports failure when grep exits
# early on its match and the tool takes SIGPIPE.
out() { "$LC" --repo "$R" "$@"; }
echo "── landed-check"
[ "$(verdict feat/squashed)" = LANDED ] && pass "control: a squash-merged branch reads LANDED" || fail "squash-merged branch: $(verdict feat/squashed)"
[ "$(verdict feat/one-missing)" = MISSING ] && pass "control: one unlanded line reads MISSING" || fail "one unlanded line: $(verdict feat/one-missing)"
grep -q 'app.py: 1/3 added line(s) not in the base' <<<"$(out feat/one-missing)" \
  && pass "and names the file and the count (1 of 3)" || fail "MISSING detail wrong: $("$LC" --repo "$R" feat/one-missing | tr '\n' '|')"
grep -q 'an ancestor of the base' <<<"$(out feat/ancestor)" && [ "$(verdict feat/ancestor)" = LANDED ] \
  && pass "an ancestor of the base reads LANDED" || fail "ancestor: $(verdict feat/ancestor)"
grep -q 'docs/never-landed.md: not in the base at this path or by this name' <<<"$(out feat/newfile)" \
  && [ "$(verdict feat/newfile)" = MISSING ] && pass "a file that never landed reads MISSING" || fail "new file: $(verdict feat/newfile)"
[ "$(verdict feat/moved)" = LANDED ] && pass "content moved to another path on main reads LANDED" || fail "moved: $(verdict feat/moved)"
[ "$(verdict feat/moved-part)" = CANNOT-TELL ] && pass "a moved file that only partly matches reads CANNOT-TELL, never LANDED" \
  || fail "partly-matching move: $(verdict feat/moved-part)"
grep -q '2/2 removed line(s) still there' <<<"$(out feat/delete)" && [ "$(verdict feat/delete)" = MISSING ] \
  && pass "a deletion the base never took reads MISSING" || fail "deletion: $(verdict feat/delete)"
grep -q 'nothing of substance to land' <<<"$(out feat/empty)" && [ "$(verdict feat/empty)" = LANDED ] \
  && pass "mirror: a branch with no unique work reads LANDED (needs no ticket)" || fail "empty: $(verdict feat/empty)"
[ "$(verdict no/such)" = CANNOT-TELL ] && pass "a bad ref reads CANNOT-TELL" || fail "bad ref: $(verdict no/such)"
head -1 <<<"$(out feat/squashed)" | grep -q "base origin/main @ $(git -C "$R" rev-parse --short=12 origin/main)" \
  && pass "prints the base and the SHA it compared against" || fail "base line missing or wrong"

"$LC" --repo "$R" feat/squashed feat/empty >/dev/null; [ $? -eq 0 ] && pass "all LANDED exits 0" || fail "all LANDED did not exit 0"
"$LC" --repo "$R" feat/squashed feat/one-missing feat/moved-part >/dev/null; [ $? -eq 1 ] && pass "any MISSING exits 1" || fail "MISSING did not exit 1"
"$LC" --repo "$R" feat/squashed feat/moved-part >/dev/null; [ $? -eq 2 ] && pass "CANNOT-TELL without MISSING exits 2" || fail "CANNOT-TELL did not exit 2"
"$LC" --repo "$R" >/dev/null 2>&1; [ $? -eq 2 ] && pass "no branch named exits 2" || fail "no-branch call did not exit 2"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; else echo "  ❌ $fails failed"; fi
exit $(( fails > 0 ))
