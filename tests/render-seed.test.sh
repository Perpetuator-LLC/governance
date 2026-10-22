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
bundle_dirs() {  # top-level directory names under $1, one per line, sorted — no GNU-only find flag
  for d in "$1"/*/; do [ -d "$d" ] && basename "$d"; done | sort
}

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
# BSD wc -l right-pads its count ("       1"), so a bare `wc -l` compared with `=` to '1' is false on
# macOS even when the count is right — pipe through `wc -l | tr -d ' '`, same as every other count
# check in this file, never a bare `wc -l` against a string literal.
check "exactly one bundle directory exists" "[ \"\$(bundle_dirs "$SEED" | wc -l | tr -d ' ')\" = '1' ]"

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
# control: reverting the mutation clears the staleness, proving the check is live and not a fixed
# string. Portable last-line removal (governance#283 CTA send-back c104640 item 1): `sed -i '$ d'` is
# GNU-only and errors on BSD/macOS sed ("invalid command code"), which every agent host runs.
python3 -c "
p = '$ADAPTER/AGENTS.md'
with open(p) as fh:
    lines = fh.readlines()
with open(p, 'w') as fh:
    fh.writelines(lines[:-1])
"
rc="$(gov check --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme)"
check "…and reverting the source clears the staleness (exit 0 again, the control)" "[ '$rc' = '0' ]"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --local "$TMP/core/AGENTS.md")"
check "--local is refused for --target seed (LOCAL never leaves the machine), not silently dropped" "[ '$rc' = '2' ]"

rc="$(gov render --target seed --out "$SEED" --core "$TMP/no-such-core" --adapter "$ADAPTER" --engagement acme)"
check "a missing core/adapter path refuses (exit 2), same as an ordinary render" "[ '$rc' = '2' ]"

# --- CTA send-back c104640, items 2-5: map.md is an authored map, not provenance; canary coverage
# extends to map rows, README and prompts; instructions-core.md exists and is budget-enforced;
# the RENDERED bundle itself is redaction-checked, not only its sources. Fresh fixtures: reusing the
# first block's would mix this block's new seed/ files into earlier hash/hit counts.
SEED2="$TMP/seed2"
CORE2="$TMP/core2"; ADAPTER2="$TMP/adapter2"
mkdir -p "$CORE2/seed" "$ADAPTER2/seed" "$ADAPTER2/engagements/acme/seed" "$ADAPTER2/engagements/other/seed" \
  "$ADAPTER2/engagements/acme/prompts"
cat > "$CORE2/AGENTS.md" <<'DOC'
# core
Core rule.
DOC
cat > "$ADAPTER2/AGENTS.md" <<'DOC'
# adapter
Org-wide rule.
DOC
cat > "$ADAPTER2/seed/map.md" <<'DOC'
MAP-ORGWIDE-ROW
DOC
cat > "$ADAPTER2/seed/instructions-core.md" <<'DOC'
INSTR-CORE-OK
DOC
cat > "$ADAPTER2/engagements/acme/seed/map.md" <<'DOC'
MAP-ACME-ROW
DOC
cat > "$ADAPTER2/engagements/other/seed/map.md" <<'DOC'
MAP-OTHER-ROW
DOC
cat > "$ADAPTER2/engagements/acme/README.md" <<'DOC'
README-ACME-CANARY
DOC
cat > "$ADAPTER2/engagements/acme/prompts/boot.md" <<'DOC'
PROMPT-ACME-CANARY
DOC

rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme)"
check "item 2/5: render with seed/ sources and no secret shapes exits 0 (redaction-clean)" "[ '$rc' = '0' ]"
H2="$(bundle_dirs "$SEED2")"

check "item 2: map.md is the AUTHORED map (org-wide row present)" "grep -q 'MAP-ORGWIDE-ROW' '$SEED2/$H2/map.md'"
check "item 2+3: map.md carries the IN-SET engagement's row" "grep -q 'MAP-ACME-ROW' '$SEED2/$H2/map.md'"
check "item 2+3 KAT: map.md does NOT carry the OUT-OF-SET engagement's row" "! grep -q 'MAP-OTHER-ROW' '$SEED2/$H2/map.md'"
check "item 3 KAT: the in-set engagement's own README canary made it into the bundle" \
  "grep -rq 'README-ACME-CANARY' '$SEED2/$H2'"
check "item 3 KAT: the in-set engagement's own prompt canary made it into the bundle" \
  "grep -rq 'PROMPT-ACME-CANARY' '$SEED2/$H2'"

check "item 4: instructions-core.md exists and carries the org-wide source" \
  "[ -f '$SEED2/$H2/instructions-core.md' ] && grep -q 'INSTR-CORE-OK' '$SEED2/$H2/instructions-core.md'"
check "item 4: instructions-core.md is well under its 1 KB budget" \
  "[ \"\$(wc -c <'$SEED2/$H2/instructions-core.md')\" -le 1024 ]"

# item 4 KAT: an over-budget instructions-core.md REFUSES the render rather than shipping it anyway.
python3 -c "open('$ADAPTER2/seed/instructions-core.md', 'w').write('x' * 2000)"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme)"
check "item 4 KAT: an over-budget instructions-core.md is REFUSED (exit 2), not truncated or shipped" \
  "[ '$rc' = '2' ] && grep -qi 'budget' '$TMP/stderr'"
python3 -c "open('$ADAPTER2/seed/instructions-core.md', 'w').write('INSTR-CORE-OK\n')"  # restore

# item 5 KAT: a shape finding in a RENDERED bundle file (not just a source) refuses the render. A
# ticket-reference shape (bin/redaction-check's own SHAPE_PATTERNS) is enough to trigger it and
# needs no real secret.
echo "see acme#42 for details" >> "$ADAPTER2/seed/map.md"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme)"
check "item 5 KAT: a redaction finding in the rendered bundle REFUSES the render (exit 2)" \
  "[ '$rc' = '2' ] && grep -qi 'redaction-check found' '$TMP/stderr'"
check "…and no bundle directory is left behind for a refused render" \
  "[ \"\$(bundle_dirs '$SEED2' | wc -l | tr -d ' ')\" = '1' ]"
python3 -c "
lines = open('$ADAPTER2/seed/map.md').readlines()
open('$ADAPTER2/seed/map.md', 'w').writelines(lines[:-1])
"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme)"
check "…and reverting the finding lets the render succeed again (the control)" "[ '$rc' = '0' ]"

# --- cos findings on r3 (real render on the render host), item 1: bundle.json's `sources` must be
# host-independent (label · relpath, never the render host's absolute filesystem path, which would
# bake a home directory — and on macOS, the account name inside it — into a file that ships to
# clients), and item "cover bundle.json too": the redaction scan must actually read bundle.json, not
# silently skip it as a non-Markdown file inside a directory argument.
BJ2="$SEED2/$H2/bundle.json"
check "r4 item 1: bundle.json's sources are label-keyed, never the render host's absolute path" \
  "! grep -q \"$TMP\" '$BJ2' && ! grep -qE '\"/[A-Za-z]' '$BJ2'"

SEED3="$TMP/seed3-elsewhere"; CORE3="$TMP/elsewhere/core3"; ADAPTER3="$TMP/elsewhere/adapter3"
mkdir -p "$(dirname "$CORE3")"
cp -r "$CORE2" "$CORE3"
cp -r "$ADAPTER2" "$ADAPTER3"
# instructions-core.md was restored to its original content above; this copy carries that, not the
# over-budget or redaction-tainted intermediate states.
rc="$(gov render --target seed --out "$SEED3" --core "$CORE3" --adapter "$ADAPTER3" --engagement acme)"
check "r4 KAT: rendering the SAME content from a DIFFERENT directory location exits 0" "[ '$rc' = '0' ]"
H3="$(bundle_dirs "$SEED3")"
check "r4 KAT: …and lands at the SAME content-addressed hash as the original location" "[ \"\$H3\" = \"\$H2\" ]"
check "r4 KAT: …and bundle.json is IDENTICAL across the two locations (sources/files/hash/engagements — rendered_at excepted, which always varies by invocation time on any single host too)" \
  "python3 -c \"
import json
a = json.load(open('$BJ2'))
b = json.load(open('$SEED3/\$H3/bundle.json'))
for k in ('bundle_hash', 'engagements', 'files', 'sources'):
    assert a[k] == b[k], (k, a[k], b[k])
\""

# r4 KAT: bundle.json is now actually scanned, proven by a shape that reaches it through a path NO
# OTHER bundle file carries: an --engagement name with no matching engagements/<name>/ directory in
# the adapter at all (confirmed below). seed_layers() and seed_source_layers() both guard every
# inclusion on the directory/file actually existing (already proven by the earlier "does NOT carry
# the OUT-OF-SET engagement's row" checks), so governance.md and map.md cannot contain this name —
# only bundle.json's own `"engagements": [...]` list does, generated regardless of whether anything
# on disk matches it. A refusal here is therefore bundle.json being read, not any other file.
check "r4 setup: no engagements/proj#99 directory exists in the fixture" "[ ! -d '$ADAPTER2/engagements/proj#99' ]"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement 'proj#99')"
check "r4 KAT: an engagement name shaped like a ticket-ref, with no matching directory, is still caught (exit 2)" \
  "[ '$rc' = '2' ] && grep -qi 'redaction-check found' '$TMP/stderr'"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
