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

# --- layers (governance#122): an adapter doc points into the RENDERED doc, core + adapter ---------------
mkdir -p "$TMP/r/core/domains" "$TMP/adp/domains" "$TMP/adp/skills/worker" "$TMP/adp/skills/orchestrator" "$TMP/loose"
printf '## Core rule\nbody\n' > "$TMP/r/core/domains/ops2.md"
printf '# core\n## Precedence\n' > "$TMP/r/core/AGENTS.md"
printf '# adapter\n## Workflow\n' > "$TMP/adp/AGENTS.md"
printf '## Adapter rule\nbody\n' > "$TMP/adp/domains/ops2.md"
cat > "$TMP/adp/domains/tech.md" <<'DOC'
See `governance/ops2.md` → *Core rule* · *Adapter rule*, and `global/CLAUDE.md` → *Workflow* · *Precedence*.
DOC
rc="$(run --root "$TMP/r" "$TMP/adp/domains/tech.md")"
check "an adapter doc's pointers resolve against core + its OWN layer, as rendered (exit 0)" \
  "[ '$rc' = '0' ] && grep -q '4 pointer(s), 0 dangling' '$TMP/out'"
echo 'See `governance/ops2.md` → *A rule no layer has*.' > "$TMP/adp/domains/planted.md"
rc="$(run --root "$TMP/r" "$TMP/adp/domains/planted.md")"
check "POSITIVE CONTROL: a planted dangling pointer in an adapter doc is still caught as DANGLING" \
  "[ '$rc' = '1' ] && grep -q 'DANGLING .*A rule no layer has' '$TMP/out'"
echo 'See `governance/nosuch.md` → *Anything*.' > "$TMP/adp/domains/nodoc.md"
rc="$(run --root "$TMP/r" "$TMP/adp/domains/nodoc.md")"
check "a doc in NO layer is NO-SUCH-DOC" "[ '$rc' = '1' ] && grep -q 'NO-SUCH-DOC' '$TMP/out'"

echo 'See `ops2.md` → *Adapter rule*.' > "$TMP/loose/x.md"
rc="$(run --root "$TMP/r" "$TMP/loose/x.md")"
check "a file in no known layer: a miss is NOT-IN-THIS-LAYER (a scope limit), never NO-SUCH-DOC" \
  "[ '$rc' = '1' ] && grep -q 'NOT-IN-THIS-LAYER' '$TMP/out' && ! grep -q 'NO-SUCH-DOC' '$TMP/out'"
rc="$(run --root "$TMP/r" --layer "$TMP/adp" "$TMP/loose/x.md")"
check "…and --layer names the layer that renders it (exit 0)" "[ '$rc' = '0' ]"

mkdir -p "$TMP/home/.claude/governance"
printf '<!-- rendered by governance — DO NOT EDIT: change a layer, then re-render. sha256=%064d -->\n## Core rule\n## Adapter rule\n' 0 > "$TMP/home/.claude/governance/ops2.md"
printf '<!-- rendered by governance — DO NOT EDIT: change a layer, then re-render. sha256=%064d -->\nSee `governance/ops2.md` → *Adapter rule*. And `governance/ops2.md` → *Gone rule*.\n' 0 > "$TMP/home/.claude/governance/tech.md"
rc="$(run --root "$TMP/r" "$TMP/home/.claude/governance/tech.md")"
check "a RENDERED doc resolves against its rendered home, and a real miss there is still DANGLING" \
  "[ '$rc' = '1' ] && grep -q '2 pointer(s), 1 dangling' '$TMP/out' && grep -q 'DANGLING .*Gone rule' '$TMP/out'"

printf '## Attribution\n' > "$TMP/adp/skills/orchestrator/G.md"
echo 'Follow `orchestrator/G.md` → *Attribution*.' > "$TMP/adp/skills/worker/SKILL.md"
rc="$(run --root "$TMP/r" "$TMP/adp/skills/worker/SKILL.md")"
check "a relative prefix resolves against an ANCESTOR (skills/worker → skills/orchestrator)" "[ '$rc' = '0' ]"

# --- the gate: this tree -------------------------------------------------------------
rc="$(run --root "$ROOT")"
check "THIS TREE has no dangling pointer" "[ '$rc' = '0' ]"
[ "$rc" = '0' ] || sed 's/^/      /' "$TMP/out"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
