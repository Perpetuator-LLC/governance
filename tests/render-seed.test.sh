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

# A baseline private-patterns list at the DEFAULT path (governance#283 c106374): a public ADAPTER
# render now refuses outright when the instance-name leg was NOT CHECKED at all, so every ordinary
# render below needs a list to be CHECKED against — same as a real host or CI runner that has one
# configured, which is the condition every one of these tests except the "no list anywhere" KAT
# further down means to exercise. The pattern matches nothing in any fixture here; only that one KAT
# overrides HOME to a directory with no list, to prove the REFUSAL this file exists to pin.
export HOME="$TMP/home-default"
mkdir -p "$HOME/.governance"
cat > "$HOME/.governance/private-patterns" <<'DOC'
```redaction-instances
literal:Never Matches Any Fixture In This File
```
DOC

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

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --audience public)"
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

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement other --audience public)"
check "a DIFFERENT engagement set renders without error" "[ '$rc' = '0' ]"
H_OTHER="$(bundle_dirs "$SEED" | grep -v "^$H_ACME\$")"
check "KAT: a different engagement set hashes DIFFERENTLY (new directory, not reused)" \
  "[ -n \"\$H_OTHER\" ] && [ \"\$H_OTHER\" != \"\$H_ACME\" ]"
check "…and the other bundle carries ITS canary, not acme's" \
  "grep -q 'CANARY-OTHER' '$SEED/$H_OTHER/governance.md' && ! grep -q 'CANARY-ACME' '$SEED/$H_OTHER/governance.md'"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --audience public)"
N_DIRS_BEFORE=2
N_DIRS_AFTER="$(bundle_dirs "$SEED" | wc -l | tr -d ' ')"
check "KAT: re-rendering the SAME engagement set with unchanged layers reuses the same hash (no 3rd dir)" \
  "[ \"\$N_DIRS_AFTER\" = \"\$N_DIRS_BEFORE\" ]"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --audience public)"
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

rc="$(gov check --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --audience public)"
check "check --target seed: in sync right after render (exit 0)" "[ '$rc' = '0' ] && grep -q 'in sync' '$TMP/stdout'"

echo "extra line" >> "$ADAPTER/AGENTS.md"
rc="$(gov check --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --audience public)"
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
rc="$(gov check --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --audience public)"
check "…and reverting the source clears the staleness (exit 0 again, the control)" "[ '$rc' = '0' ]"

rc="$(gov render --target seed --out "$SEED" --core "$CORE" --adapter "$ADAPTER" --engagement acme --local "$TMP/core/AGENTS.md" --audience public)"
check "--local is refused for --target seed (LOCAL never leaves the machine), not silently dropped" "[ '$rc' = '2' ]"

rc="$(gov render --target seed --out "$SEED" --core "$TMP/no-such-core" --adapter "$ADAPTER" --engagement acme --audience public)"
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

rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience public)"
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
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience public)"
check "item 4 KAT: an over-budget instructions-core.md is REFUSED (exit 2), not truncated or shipped" \
  "[ '$rc' = '2' ] && grep -qi 'budget' '$TMP/stderr'"
python3 -c "open('$ADAPTER2/seed/instructions-core.md', 'w').write('INSTR-CORE-OK\n')"  # restore

# item 5 KAT: a shape finding in a RENDERED bundle file (not just a source) refuses the render. A
# ticket-reference shape (bin/redaction-check's own SHAPE_PATTERNS) is enough to trigger it and
# needs no real secret.
echo "see acme#42 for details" >> "$ADAPTER2/seed/map.md"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience public)"
check "item 5 KAT: a redaction finding in the rendered bundle REFUSES the render (exit 2)" \
  "[ '$rc' = '2' ] && grep -qi 'redaction-check found' '$TMP/stderr'"
check "…and no bundle directory is left behind for a refused render" \
  "[ \"\$(bundle_dirs '$SEED2' | wc -l | tr -d ' ')\" = '1' ]"
python3 -c "
lines = open('$ADAPTER2/seed/map.md').readlines()
open('$ADAPTER2/seed/map.md', 'w').writelines(lines[:-1])
"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience public)"
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
rc="$(gov render --target seed --out "$SEED3" --core "$CORE3" --adapter "$ADAPTER3" --engagement acme --audience public)"
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
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement 'proj#99' --audience public)"
check "r4 KAT: an engagement name shaped like a ticket-ref, with no matching directory, is still caught (exit 2)" \
  "[ '$rc' = '2' ] && grep -qi 'redaction-check found' '$TMP/stderr'"

# --- CTA ruling c104786, governance#283: AUDIENCE gates who a bundle is for. public keeps the
# unconditional gate; org:<id> allows instance names (the audience IS the organisation) but still
# refuses any SHAPE finding (a credential shape is a defect whatever the audience). Audience is part
# of the bundle hash. Reuses CORE2/ADAPTER2, restored to their clean post-item-5 state above.
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme)"
check "KAT: an adapter render with NO --audience is refused (exit 2), never defaults silently" \
  "[ '$rc' = '2' ] && grep -qi 'audience' '$TMP/stderr'"

rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience public)"
# H2 was itself rendered with --audience public (added to the earlier call by the same global
# transform that added --audience to every pre-existing call in this file) from content that has
# since been fully restored, so this re-render reuses H2's own hash exactly — it is NOT a new
# directory, which is correct and is the "same inputs -> same hash" property, not a bug to work
# around. H_ORG, by contrast, WILL be new: same layers, different audience.
H_PUB="$H2"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience 'org:acme-corp')"
H_ORG="$(bundle_dirs "$SEED2" | grep -v "^$H2\$")"
check "KAT: same inputs, different audience, renders both without error" "[ -n \"\$H_PUB\" ] && [ -n \"\$H_ORG\" ]"
check "KAT: …and lands at a DIFFERENT hash (audience is part of the hash input)" "[ \"\$H_PUB\" != \"\$H_ORG\" ]"
check "…and bundle.json records which audience each one is" \
  "python3 -c \"import json; assert json.load(open('$SEED2/\$H_PUB/bundle.json'))['audience'] == 'public'\" && \
   python3 -c \"import json; assert json.load(open('$SEED2/\$H_ORG/bundle.json'))['audience'] == 'org:acme-corp'\""

rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --audience 'not-a-real-audience')"
check "an invalid --audience value (not public or org:<id>) is refused (exit 2)" "[ '$rc' = '2' ]"

# CISA send-back, governance#283 c106374: a PUBLIC render of an ADAPTER accepted redaction-check
# exit 3 (the instance-name leg NOT CHECKED — no --private-patterns anywhere) as if it were clean,
# so an adapter's own client names could ship unchecked on any host or CI runner that simply never
# had the private list. HOME points at a fresh, empty directory so this does not depend on whether
# THIS host happens to have one at ~/.governance/private-patterns.
# A dedicated output directory — never $SEED2 — so these renders cannot add an extra bundle
# directory to the shared fixture the audience-hash comparisons just above rely on counting.
NOLIST_HOME="$TMP/home-no-list"; mkdir -p "$NOLIST_HOME"
SEED_NOLIST="$TMP/seed-nolist"
rc="$(HOME="$NOLIST_HOME" gov render --target seed --out "$SEED_NOLIST" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience public)"
check "KAT: an ADAPTER render under public with NO private list anywhere is REFUSED (exit 2), not shipped unchecked" \
  "[ '$rc' = '2' ] && grep -qi 'not checked' '$TMP/stderr'"
# Control: the SAME no-list host, CORE-ONLY — core is public by construction, so it still renders.
rc="$(HOME="$NOLIST_HOME" gov render --target seed --out "$SEED_NOLIST" --core "$CORE2" --engagement acme --audience public)"
check "control: a CORE-ONLY render with no private list anywhere still renders (exit 0)" "[ '$rc' = '0' ]"

# A private-patterns fixture: one literal instance name. Set via the env var redaction-check itself
# documents as its fallback (GOVERNANCE_PRIVATE_PATTERNS) — bin/governance's subprocess call passes
# no --private-patterns of its own, so this only reaches redaction-check if the environment actually
# propagates through the two-level call, which is exactly what a real server's environment would do.
PRIVATE="$TMP/private-patterns.md"
cat > "$PRIVATE" <<'DOC'
```redaction-instances
literal:Acme Corp
```
DOC
echo "Acme Corp is the contracting party." >> "$ADAPTER2/seed/map.md"
export GOVERNANCE_PRIVATE_PATTERNS="$PRIVATE"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience public)"
check "KAT: a PUBLIC bundle refuses on an instance-name match (exit 2) — the full gate, unchanged" \
  "[ '$rc' = '2' ]"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience 'org:acme-corp')"
check "KAT: an ORG bundle ALLOWS the same instance-name match (exit 0) — the audience is the organisation" \
  "[ '$rc' = '0' ]"

# …but a SHAPE finding still refuses an org bundle — instance names are allowed, shapes are not.
echo "see acme#42 for details" >> "$ADAPTER2/seed/map.md"
rc="$(gov render --target seed --out "$SEED2" --core "$CORE2" --adapter "$ADAPTER2" --engagement acme --audience 'org:acme-corp')"
check "KAT: an ORG bundle with a SHAPE finding is still refused (exit 2)" \
  "[ '$rc' = '2' ] && grep -qi 'shape finding' '$TMP/stderr'"
unset GOVERNANCE_PRIVATE_PATTERNS
# restore map.md to its pre-audience-block state (drop the two appended lines)
python3 -c "
lines = open('$ADAPTER2/seed/map.md').readlines()
open('$ADAPTER2/seed/map.md', 'w').writelines(lines[:-2])
"

# --- coa SEND-BACK on r6 (governance#283 c120537): core_tag, --engagement path traversal, the
# audience regex's trailing-newline and leading-dot holes ---

# item 1 (mutant M3 survived 50/50): core_tag comes from a REAL git checkout, never the scratch
# fixture above (which has no .git, so "unknown" is its CORRECT answer and proves nothing about the
# mutant). This repo's own core is a real checkout.
SEED_REAL="$TMP/seed-real"
rc="$(gov render --target seed --out "$SEED_REAL" --core "$ROOT/core" --audience public)"
check "a render of THIS repo's own core exits 0" "[ '$rc' = '0' ]"
H_REAL="$(bundle_dirs "$SEED_REAL")"
check "KAT: core_tag in a real git checkout is never \"unknown\" (kills: core_tag hardcoded to \"unknown\")" \
  "python3 -c \"import json; t=json.load(open('$SEED_REAL/$H_REAL/bundle.json'))['core_tag']; assert t and t != 'unknown', t\""

# item 2: --engagement joins a directory path with no charset check — `../../outside` escaped the
# adapter tree and a canary from outside it landed in governance.md.
OUTSIDE="$TMP/outside-canary.md"
echo "CANARY-OUTSIDE-f00d" > "$OUTSIDE"
rc="$(gov render --target seed --out "$TMP/seed-trav" --core "$CORE2" --adapter "$ADAPTER2" \
  --engagement '../../outside-canary' --audience 'org:acme-corp' )"
check "KAT: an --engagement name carrying a path separator or '..' is refused (exit 2), not joined into a path" \
  "[ '$rc' = '2' ] && grep -qi \"path separator\" '$TMP/stderr'"

# item 3: the audience regex's `$` allows a trailing newline, and `.` in an org id allowed `org:..`.
rc="$(gov render --target seed --out "$TMP/seed-aud1" --core "$CORE2" --adapter "$ADAPTER2" \
  --engagement acme --audience $'org:acme\n' )"
check "KAT: an audience with a trailing newline is refused, not accepted via \$'s newline exception" \
  "[ '$rc' = '2' ]"
rc="$(gov render --target seed --out "$TMP/seed-aud2" --core "$CORE2" --adapter "$ADAPTER2" \
  --engagement acme --audience 'org:..' )"
check "KAT: audience org:.. (a path-traversal shape) is refused" "[ '$rc' = '2' ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
