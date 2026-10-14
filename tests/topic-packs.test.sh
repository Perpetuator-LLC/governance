#!/usr/bin/env bash
# topic-packs.test.sh — packs are built from core/ only, stay inside their caps, mark every cut, fail
# loudly on a bad manifest, and the committed packs/ match what the manifest builds (drift).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TP="$ROOT/bin/topic-packs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

echo "this repo:"
python3 "$TP" --root "$ROOT" --check >/dev/null 2>&1 && ok "committed packs/ match packs/topics.json (no drift)" \
  || bad "packs/ drifted from the manifest: run bin/topic-packs"
over=$(find "$ROOT/packs" -name '*.md' -path '*/rules/*' -size +8192c | wc -l | tr -d ' ')
[ "$over" -eq 0 ] && ok "every rule file is <= 8192 B" || bad "$over rule file(s) over 8192 B"
over=$(find "$ROOT/packs" -maxdepth 1 -name '*.md' -size +4096c | wc -l | tr -d ' ')
[ "$over" -eq 0 ] && ok "every pack is <= 4096 B" || bad "$over pack(s) over 4096 B"

echo "fixture:"
F="$TMP/f"; mkdir -p "$F/core/domains" "$F/packs" "$F/adapter"
long_lead="$(python3 -c 'print(" ".join(["**This sentence is a rule.**"] + ["Another sentence here."]*60))')"
long_body="$(python3 -c 'print("\n\n".join(["Paragraph %d. "%i + "word "*60 for i in range(60)]))')"
cat > "$F/core/domains/x.md" <<EOF
# X

## Short rule

**Do the thing.** Then stop.

Second paragraph is not in the pack.

## Long lead

$long_lead

## Long section

**Lead.**

$long_body
EOF
echo "## Private rule" > "$F/adapter/p.md"
write_manifest() { python3 -c 'import json,sys; print(json.dumps({"version":1,"topics":[{"name":"t","title":"T","when":"W.","rules":[r for r in sys.argv[1].split("|") if r]}]}))' "$1" > "$F/packs/topics.json"; }
write_manifest 'core/domains/x.md § Short rule|core/domains/x.md § Long lead|core/domains/x.md § Long section'
python3 "$TP" --root "$F" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "a valid manifest builds" || bad "build exit $rc"
grep -q "Do the thing" "$F/packs/t.md" && ! grep -q "Second paragraph" "$F/packs/t.md" \
  && ok "a pack carries the lead paragraph only" || bad "lead extraction"
grep -q "rule: short-rule" "$F/packs/t.md" && [ -f "$F/packs/rules/short-rule.md" ] \
  && ok "each rule has a slug and its own file" || bad "slug/rule file"
grep -q "This sentence is a rule\..*\[…\]" "$F/packs/t.md" && ok "a lead over 700 B is cut at a sentence and marked […]" || bad "long lead not cut/marked"
s=$(wc -c < "$F/packs/rules/long-section.md" | tr -d ' ')
[ "$s" -le 8192 ] && grep -q "^\[truncated" "$F/packs/rules/long-section.md" \
  && ok "a section over 8192 B is cut at a paragraph and marked ($s B)" || bad "long section: $s B, marker?"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["topics"][0]["topic"]=="t"' "$F/packs/index.json" \
  && ok "index.json lists the topic" || bad "index"
python3 "$TP" --root "$F" --check >/dev/null 2>&1 && ok "--check passes right after a build" || bad "check after build"
echo tampered >> "$F/packs/t.md"
python3 "$TP" --root "$F" --check >/dev/null 2>&1; [ $? -eq 1 ] && ok "a hand-edited pack is DRIFT (exit 1)" || bad "drift not caught"

echo "fails loudly:"
expect_fail() { # label, manifest rules, expected message fragment
  write_manifest "$2"; out="$(python3 "$TP" --root "$F" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$3" && ok "$1" || bad "$1 (rc=$rc: $out)"
}
expect_fail "a source outside core/ is refused" 'adapter/p.md § Private rule' "outside core/"
# Found by mutation (quality sweep, 2026-10-14): the boundary check is `path.startswith(corer +
# os.sep)`, not a bare `startswith(corer)` — dropping the separator passed every existing case here,
# because "adapter/..." shares no string prefix with ".../core" at all. The separator is what actually
# matters: without it, a SIBLING directory merely named with "core" as a prefix (core-private,
# core2, …) would pass the check, since its realpath also starts with the string "core".
mkdir -p "$F/core-private"; echo "## Sneaky rule" > "$F/core-private/p.md"
expect_fail "a sibling directory merely PREFIXED with 'core' (core-private/) is still refused, not treated as core/" \
  'core-private/p.md § Sneaky rule' "outside core/"
expect_fail "a renamed heading is refused" 'core/domains/x.md § No such rule' "no '## No such rule'"
expect_fail "a ref without ' § ' is refused" 'core/domains/x.md Short rule' "is not '<file> § <heading>'"
many=""; for i in $(seq 1 12); do many="$many|core/domains/x.md § Long lead"; done
expect_fail "a pack over 4096 B fails the build, never truncates" "$many" "over 4096"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
