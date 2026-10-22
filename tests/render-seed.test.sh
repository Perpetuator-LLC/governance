#!/usr/bin/env bash
# render-seed.test.sh — bin/governance render/check --target seed (governance#283)
#
# A seed bundle is handed to a fresh MCP connection with no local files of its own, so it carries
# two promises neither of which can fail quietly: (1) a bundle's content depends ONLY on the
# engagement set it was built for — another engagement's rules must never be reachable (G8); (2) the
# bundle is content-addressed, so identical layers and engagement set always hash identically, and a
# layer changing after the fact is a provable staleness, not a silent drift.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOV="$ROOT/bin/governance"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
gov()  { python3 "$GOV" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; echo $?; }
bundle_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }

echo "governance render/check --target seed"
check "the script is executable" "[ -x '$GOV' ]"

mkdir -p "$TMP/core" "$TMP/adapter/engagements/acme" "$TMP/adapter/engagements/other" "$TMP/adapter/prompts"
cat > "$TMP/core/AGENTS.md" <<'DOC'
# core
Core rule.
DOC
cat > "$TMP/adapter/AGENTS.md" <<'DOC'
# adapter
Org-wide rule.
DOC
cat > "$TMP/adapter/README.md" <<'DOC'
Adapter README.
DOC
cat > "$TMP/adapter/prompts/greeting.md" <<'DOC'
Hello prompt.
DOC
cat > "$TMP/adapter/engagements/acme/rules.md" <<'DOC'
CANARY-ACME-7f3a
DOC
cat > "$TMP/adapter/engagements/other/rules.md" <<'DOC'
CANARY-OTHER-9b1c
DOC

SEED="$TMP/seed"
CORE="$TMP/core"; ADAPTER="$TMP/adapter"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme)"
check "render exits 0" "[ '$rc' = '0' ]"
H_ACME="$(bundle_dirs "$SEED")"
check "exactly one bundle directory exists" "[ \"\$(wc -l <<<\"\$H_ACME\")\" = '1' ]"

GMD="$SEED/$H_ACME/governance.md"
check "KAT: the in-set canary (acme) is present in governance.md" "grep -q 'CANARY-ACME' '$GMD'"
check "KAT: the out-of-set canary (other) is ABSENT from governance.md" "! grep -q 'CANARY-OTHER' '$GMD'"
check "map.md, README and prompts are present as their own bundle files" \
  "[ -f '$SEED/$H_ACME/map.md' ] && [ -f '$SEED/$H_ACME/README-adapter.md' ] && [ -f '$SEED/$H_ACME/prompts/adapter/greeting.md' ]"
check "bundle.json names the engagement set, sorted, and nothing else" \
  "python3 -c \"import json; d=json.load(open('$SEED/$H_ACME/bundle.json')); assert d['engagements']==['acme'], d['engagements']\""

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement other)"
check "a DIFFERENT engagement set renders without error" "[ '$rc' = '0' ]"
H_OTHER="$(bundle_dirs "$SEED" | grep -v "^$H_ACME\$")"
check "KAT: a different engagement set hashes DIFFERENTLY (new directory, not reused)" \
  "[ -n \"\$H_OTHER\" ] && [ \"\$H_OTHER\" != \"\$H_ACME\" ]"
check "…and the other bundle carries ITS canary, not acme's" \
  "grep -q 'CANARY-OTHER' '$SEED/$H_OTHER/governance.md' && ! grep -q 'CANARY-ACME' '$SEED/$H_OTHER/governance.md'"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme)"
N_DIRS_BEFORE=2
N_DIRS_AFTER="$(bundle_dirs "$SEED" | wc -l | tr -d ' ')"
check "KAT: re-rendering the SAME engagement set with unchanged layers reuses the same hash (no 3rd dir)" \
  "[ \"\$N_DIRS_AFTER\" = \"\$N_DIRS_BEFORE\" ]"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER")"
H_EMPTY="$(bundle_dirs "$SEED" | grep -v -e "^$H_ACME\$" -e "^$H_OTHER\$")"
check "an EMPTY engagement set renders org-wide content only" "[ -n \"\$H_EMPTY\" ]"
check "…with NEITHER engagement's canary present" \
  "! grep -q 'CANARY-ACME' '$SEED/$H_EMPTY/governance.md' && ! grep -q 'CANARY-OTHER' '$SEED/$H_EMPTY/governance.md'"
check "…and org-wide content (the adapter's own AGENTS.md rule) is still there" \
  "grep -q 'Org-wide rule' '$SEED/$H_EMPTY/governance.md'"

rc="$(gov render --out "$TMP/plain.md" --core "$CORE" --adapter "$ADAPTER")"
check "an ORDINARY (non-seed) render of the same adapter still exits 0" "[ '$rc' = '0' ]"
check "…and NEVER leaks engagements/ content into a plain render (the reserved-name guard)" \
  "! grep -q 'CANARY-ACME' '$TMP/plain.md' && ! grep -q 'CANARY-OTHER' '$TMP/plain.md'"
check "…while still carrying the adapter's org-wide rule" "grep -q 'Org-wide rule' '$TMP/plain.md'"

rc="$(gov check --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme)"
check "check --target seed: in sync right after render (exit 0)" "[ '$rc' = '0' ] && grep -q 'in sync' '$TMP/stdout'"

echo "extra line" >> "$ADAPTER/AGENTS.md"
rc="$(gov check --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme)"
check "KAT: check --target seed flags a STALE bundle after a source changes (exit 1, LAYERS CHANGED)" \
  "[ '$rc' = '1' ] && grep -q 'LAYERS CHANGED' '$TMP/stdout'"
# control: reverting the mutation clears the staleness, proving the check is live and not a fixed string
sed -i '$ d' "$ADAPTER/AGENTS.md"
rc="$(gov check --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme)"
check "…and reverting the source clears the staleness (exit 0 again, the control)" "[ '$rc' = '0' ]"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --local "$TMP/core/AGENTS.md")"
check "--local is refused for --target seed (LOCAL never leaves the machine), not silently dropped" "[ '$rc' = '2' ]"

rc="$(gov render --target seed --out "$SEED" --core "$TMP/no-such-core" --adapter "$ADAPTER" --engagement acme)"
check "a missing core/adapter path refuses (exit 2), same as an ordinary render" "[ '$rc' = '2' ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
