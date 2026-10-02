#!/usr/bin/env bash
# tests/bare-refs.test.sh — bin/bare-refs finds the bare `#N` the forge autolinks, including after a
# slash, and nothing the forge leaves alone (#159). Expected refs are listed by hand from the fixture.
#
#   line 1  see #12 and owner/repo#45           -> #12 (owner/repo#45 is qualified)
#   line 2  ADR-002/#16 is decided              -> #16 (after a slash: the case the old spec skipped)
#   line 3  #229/#239/#262 landed               -> #229 #239 #262
#   line 4  ABC#12 and -#13 and X-#14            -> none (word char / hyphen before)
#   line 5  `#5` in code, https://x.example/#6  -> none (inline code; a URL, whose `/#6` would otherwise be bare)
#   line 6-8 a fenced block holding #7           -> none
#   line 9  power loss #3 (an ordinal)          -> #3 (found; rewording is the reader's call)
# => 6 refs (#12 #16 #229 #239 #262 #3), exit 1. Empty text => 0 refs, exit 0.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BR="$ROOT/bin/bare-refs"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bare-refs.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

cat > "$TMP/t.md" <<'EOF'
see #12 and owner/repo#45
ADR-002/#16 is decided
#229/#239/#262 landed
ABC#12 and -#13 and X-#14
`#5` in code, https://x.example/#6
```
a fenced block holding #7
```
power loss #3
EOF

echo "── bare-refs"
out=$("$BR" "$TMP/t.md"); rc=$?
refs=$(cut -f1 <<<"$out" | tr '\n' ' ')
[ "$refs" = "#12 #16 #229 #239 #262 #3 " ] && pass "exactly the six bare refs, in order" || fail "refs: [$refs]"
[ $rc -eq 1 ] && pass "findings exit 1" || fail "exit $rc"
awk -F'\t' '$1=="#16" && $2==2{f=1} END{exit !f}' <<<"$out" \
  && pass "#16 after a slash is found, on line 2 (the case the old spec skipped)" || fail "slash case missing"
! grep -qE '^#(45|13|14|5|6|7)\b' <<<"$out" && pass "qualified, word/hyphen-prefixed, code, URL and fenced refs are skipped" \
  || fail "a non-bare ref was reported: $(grep -E '^#(45|13|14|5|6|7)' <<<"$out")"
n=$("$BR" --json "$TMP/t.md" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$n" = 6 ] && pass "--json carries the same 6" || fail "--json count $n"
: > "$TMP/empty.md"; "$BR" "$TMP/empty.md" >/dev/null; [ $? -eq 0 ] && pass "no refs exits 0" || fail "empty text did not exit 0"
o=$(printf 'x #9\n' | "$BR"); grep -q '^#9' <<<"$o" && pass "reads standard input" || fail "stdin not read"
"$BR" "$TMP/no-such.md" >/dev/null 2>&1; [ $? -eq 2 ] && pass "an unreadable file exits 2" || fail "missing file did not exit 2"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; else echo "  ❌ $fails failed"; fi
exit $(( fails > 0 ))
