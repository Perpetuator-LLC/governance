#!/usr/bin/env bash
# heading-pointer-check.test.sh
#
# Proves the checker tells a live pointer from a dead one (known-good AND known-bad in the same pass),
# refuses to call an empty scan clean, tolerates the markup and line wraps that make hand-written
# survivor greps return false zeroes — then asserts THIS tree has no dangling pointer.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/heading-pointer-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run()  { python3 "$CHECK" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

echo "heading-pointer-check"
check "the script is executable" "[ -x '$CHECK' ]"

mkdir -p "$TMP/r/core" "$TMP/r/docs"
cat > "$TMP/r/core/ops.md" <<'DOC'
## Act → verify, every action
Body text with a **bold sub-rule that is
wrapped across a line** and the `git status` FIRST rule inside.
DOC
cat > "$TMP/r/docs/good.md" <<'DOC'
See `ops.md` → *Act → verify* · *bold sub-rule that is wrapped across a line* · *the git status FIRST rule*.
Also `core/ops.md → Act → verify`.
DOC
echo 'See `ops.md` → *A section that was renamed away*.' > "$TMP/r/docs/dead.md"
echo 'See `nosuch.md` → *Anything*.' > "$TMP/r/docs/nodoc.md"
echo 'No pointers in this file at all.' > "$TMP/r/docs/none.md"

rc="$(run --root "$TMP/r" "$TMP/r/docs/good.md")"
check "known-GOOD: heading, wrapped text, markup inside the phrase, code-span form (exit 0)" "[ '$rc' = '0' ]"
check "known-GOOD: all four pointers found" "grep -q '4 pointer(s), 0 dangling' '$TMP/out'"

rc="$(run --root "$TMP/r" "$TMP/r/docs/dead.md")"
check "known-BAD: a renamed target fails (exit 1)" "[ '$rc' = '1' ]"
check "known-BAD: names file, line and target" "grep -q 'dead.md:1' '$TMP/out' && grep -q 'renamed away' '$TMP/out'"

rc="$(run --root "$TMP/r" "$TMP/r/docs/nodoc.md")"
check "a pointer to a doc that does not exist fails" "[ '$rc' = '1' ] && grep -q 'NO-SUCH-DOC' '$TMP/out'"

rc="$(run --root "$TMP/r" "$TMP/r/docs/none.md")"
check "an EMPTY scan refuses (exit 2), never reads as clean" "[ '$rc' = '2' ]"

rc="$(run --root "$TMP/r" "$TMP/r/docs/missing.md")"
check "a nonexistent path refuses (exit 2)" "[ '$rc' = '2' ]"

# --- the gate: this tree -------------------------------------------------------------
rc="$(run --root "$ROOT")"
check "THIS TREE has no dangling pointer" "[ '$rc' = '0' ]"
[ "$rc" = '0' ] || sed 's/^/      /' "$TMP/out"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
