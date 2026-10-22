#!/usr/bin/env bash
# redirect-read-check.test.sh — a script never `cat`s the file a compound command redirects into
# (#276). Exhibit: a routine leg ran a loop `done > "$S/out.txt" 2>&1`, then `cat "$S/out.txt"`; with
# the redirect still in force the cat appended the file to itself, and every read of it hung. Every
# expected finding, with its line number, is derived from the fixtures below, not read back from the
# tool. Each known-good case is the same shape with one property inverted (core AGENTS.md: "the
# exhibit that taught you the rule is the thing hiding its mirror").

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RRC="$ROOT/bin/redirect-read-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
mkdir -p "$TMP/bad" "$TMP/good" "$TMP/empty"

# --- known-bad ------------------------------------------------------------------------------------
# 1 the exhibit: multi-line loop redirected, then cat of the same path (cat on line 5)
cat > "$TMP/bad/exhibit.sh" <<'EOF'
#!/usr/bin/env bash
for b in $branches; do
  probe "$b"
done > "$S/out.txt" 2>&1
echo done; cat "$S/out.txt"
EOF
# 2 backgrounded loop, then cat (cat on line 3)
cat > "$TMP/bad/background.sh" <<'EOF'
#!/usr/bin/env bash
while read -r b; do probe "$b"; done < list > "$OUT" 2>&1 &
cat "$OUT"
EOF
# 3 the literal self-feed: the cat INSIDE the redirected group (line 2)
cat > "$TMP/bad/inside.sh" <<'EOF'
#!/usr/bin/env bash
{ work; cat "$X"; } >> "$X"
EOF
# 4 spelt two ways: ${S} in the redirect, $S in the cat, unquoted (line 3); no .sh suffix, shebang only
cat > "$TMP/bad/spelling" <<'EOF'
#!/bin/sh
if true; then work; fi > "${S}/log"
cat $S/log
EOF
# 5 the same leg written into a routine's Markdown, in a fenced zsh block (cat on line 6)
cat > "$TMP/bad/routine.md" <<'EOF'
# Leg N2

```zsh
for b in $branches; do probe "$b"
done &> "$S/out.txt"
cat "$S/out.txt"
```
EOF

echo "redirect-read-check (#276)"
for f in exhibit.sh:5 background.sh:3 inside.sh:2 spelling:3 routine.md:6; do
  out=$(python3 "$RRC" "$TMP/bad/${f%%:*}" 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q "^REDIRECT_THEN_CAT  .*${f%%:*}:${f##*:}  cat" <<<"$out" \
    && ok "refused: ${f%%:*}, the cat at line ${f##*:}" || bad "${f%%:*} not refused at line ${f##*:}: rc=$rc $out"
done

# --- known-good (each the bad shape with one property inverted) -----------------------------------
# a MIRROR, order: the read happens BEFORE the compound opens — finished before the write began
cat > "$TMP/good/read-first.sh" <<'EOF'
#!/usr/bin/env bash
cat "$X"
for b in a b; do echo "$b"; done > "$X"
EOF
# b MIRROR, direction: an INPUT redirect, then cat — a read, not a write
cat > "$TMP/good/input.sh" <<'EOF'
#!/usr/bin/env bash
while read -r l; do echo "$l"; done < "$X"
cat "$X"
EOF
# c the rule's own remedy: work to one path, print a bounded summary from a DIFFERENT path
cat > "$TMP/good/other-path.sh" <<'EOF'
#!/usr/bin/env bash
for b in a b; do probe "$b"; done > "$OUT" 2>&1
grep -c CONFLICT "$OUT" > "$SUMMARY"
cat "$SUMMARY"
EOF
# d the NEIGHBOUR: a SIMPLE command's redirect ends with the command (the interactive shape)
cat > "$TMP/good/simple.sh" <<'EOF'
#!/usr/bin/env bash
probe all > "$X" 2>&1
cat "$X"
EOF
# e text that only LOOKS like the shape: quoted, commented, in a heredoc body, stderr-only redirect
cat > "$TMP/good/lookalike.sh" <<'EOF'
#!/usr/bin/env bash
echo "for b in a; do x; done > $X; cat $X"
# for b in a; do x; done > "$X"; cat "$X"
cat > "$T" <<'INNER'
for b in a; do x; done > "$X"
cat "$X"
INNER
for b in a; do x; done 2> "$E"
EOF
for f in read-first.sh input.sh other-path.sh simple.sh lookalike.sh; do
  out=$(python3 "$RRC" "$TMP/good/$f" 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q "1 script(s)/block(s), 0 finding" <<<"$out" \
    && ok "allowed: $f (and it WAS read)" || bad "$f refused or unread: rc=$rc $out"
done

python3 "$RRC" "$TMP/empty" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "nothing to scan exits 2, never a clean 0" || bad "empty dir: rc=$rc"

out=$(python3 "$RRC" "$ROOT/bin" "$ROOT/hooks" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "this repository's own bin/ and hooks/ are clean" || bad "own scripts: $out"

# --- mutants: each must flip a case above -----------------------------------------------------------
mutant() {  # $1 label, $2 sed expression, $3 fixture, $4 expected rc under the mutant
  local m="$TMP/rrc.mutant"
  sed "$2" "$RRC" > "$m"
  if cmp -s "$m" "$RRC"; then bad "mutant '$1' did not apply"; return; fi
  python3 "$m" "$3" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$4" ] && ok "mutant killed: $1" || bad "mutant survived: $1 (rc=$rc)"
}
mutant "no order check (a read before the write is refused)" \
  's/if coff > ostart and target in args:/if target in args:/' "$TMP/good/read-first.sh" 1
mutant "only reads after the closer count (the in-group self-feed passes)" \
  's/if coff > ostart and target in args:/if coff > cend and target in args:/' "$TMP/bad/inside.sh" 0
mutant "an input redirect counted as a write" \
  's/if op != "<" and fd in/if fd in/' "$TMP/good/input.sh" 1
mutant "heredoc bodies read as code" \
  's/pending.append(m.group(2))/pass/' "$TMP/good/lookalike.sh" 1
mutant "braces not normalised" \
  's/return re.sub(.*$/return w/' "$TMP/bad/spelling" 0

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
