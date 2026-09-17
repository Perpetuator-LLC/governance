#!/usr/bin/env bash
# render.test.sh — bin/governance render / check
#
# A rendered instruction file fails in exactly one way that matters: it goes stale without saying so.
# These tests prove `check` catches both shapes of staleness (a layer changed; the output was edited by
# hand), refuses to call a missing or foreign file "in sync", and that layer order is what precedence
# promises.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOV="$ROOT/bin/governance"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
gov()  { python3 "$GOV" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; echo $?; }

echo "governance render / check"
check "the script is executable" "[ -x '$GOV' ]"

mkdir -p "$TMP/core" "$TMP/adapter/sub"
echo "# core rules"        > "$TMP/core/AGENTS.md"
echo "# core extra"        > "$TMP/core/00-extra.md"
echo "# adapter rules"     > "$TMP/adapter/AGENTS.md"
echo "# adapter nested"    > "$TMP/adapter/sub/b.md"
echo "# local override"    > "$TMP/local.md"
OUT="$TMP/INSTRUCTIONS.md"
L=(--core "$TMP/core" --adapter "$TMP/adapter" --local "$TMP/local.md")

rc="$(gov render --out "$OUT" "${L[@]}")"
check "render succeeds" "[ '$rc' = '0' ] && [ -f '$OUT' ]"
rc="$(gov check --out "$OUT" "${L[@]}")"
check "a fresh render is in sync (exit 0)" "[ '$rc' = '0' ]"

order="$(grep -nE '^# ' "$OUT" | cut -d: -f2- | tr '\n' '|')"
check "order: core AGENTS.md → core extra → adapter AGENTS.md → adapter nested → local" \
  "[ '$order' = '# core rules|# core extra|# adapter rules|# adapter nested|# local override|' ]"

cp "$OUT" "$TMP/first"; gov render --out "$OUT" "${L[@]}" >/dev/null
check "rendering twice is byte-identical" "cmp -s '$OUT' '$TMP/first'"

echo "# adapter rules, amended" > "$TMP/adapter/AGENTS.md"
rc="$(gov check --out "$OUT" "${L[@]}")"
check "a changed layer ⇒ drift (exit 1)" "[ '$rc' = '1' ]"
check "…reported as LAYERS CHANGED" "grep -q 'LAYERS CHANGED' '$TMP/stdout'"

gov render --out "$OUT" "${L[@]}" >/dev/null
printf '\nan edit made directly in the rendered file\n' >> "$OUT"
rc="$(gov check --out "$OUT" "${L[@]}")"
check "a hand edit to the output ⇒ drift (exit 1)" "[ '$rc' = '1' ]"
check "…reported as EDITED BY HAND, not as stale layers" "grep -q 'EDITED BY HAND' '$TMP/stdout'"

rm -f "$OUT"
rc="$(gov check --out "$OUT" "${L[@]}")"
check "a missing output ⇒ exit 2, never in sync" "[ '$rc' = '2' ]"

echo "# someone else's instruction file" > "$OUT"
rc="$(gov check --out "$OUT" "${L[@]}")"
check "a file without the header ⇒ exit 2" "[ '$rc' = '2' ]"

rc="$(gov render --out "$OUT" --core "$TMP/core" --adapter "$TMP/no-such-adapter")"
check "a named layer that does not exist ⇒ exit 2" "[ '$rc' = '2' ]"

mkdir -p "$TMP/empty"
rc="$(gov render --out "$TMP/E.md" --core "$TMP/empty")"
check "layers with no Markdown ⇒ refuse to render an empty file (exit 2)" "[ '$rc' = '2' ] && [ ! -f '$TMP/E.md' ]"

mkdir -p "$TMP/adapter2"
echo "# second adapter"      > "$TMP/adapter2/AGENTS.md"
M=(--core "$TMP/core" --adapter "$TMP/adapter" --adapter "$TMP/adapter2" --local "$TMP/local.md")
rc="$(gov render --out "$TMP/MULTI.md" "${M[@]}")"
order="$(grep -E '^# ' "$TMP/MULTI.md" | tr '\n' '|')"
check "--adapter repeats: adapters render in the order given, between core and local" \
  "[ '$rc' = '0' ] && [ '$order' = '# core rules|# core extra|# adapter rules, amended|# adapter nested|# second adapter|# local override|' ]"
rc="$(gov check --out "$TMP/MULTI.md" "${M[@]}")"
check "…and check with the same adapters is in sync" "[ '$rc' = '0' ]"
rc="$(gov check --out "$TMP/MULTI.md" --core "$TMP/core" --adapter "$TMP/adapter2" --adapter "$TMP/adapter" --local "$TMP/local.md")"
check "…while the same adapters in another order are drift" "[ '$rc' = '1' ]"

# --- this repository's own core renders and checks ------------------------------------
rc="$(gov render --out "$TMP/SELF.md")"
check "THIS core renders" "[ '$rc' = '0' ]"
rc="$(gov check --out "$TMP/SELF.md")"
check "THIS core render is in sync" "[ '$rc' = '0' ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
