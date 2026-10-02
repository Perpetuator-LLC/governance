#!/usr/bin/env bash
# tests/bare-refs.test.sh — bin/bare-refs finds the bare `#N` the forge autolinks, including after a
# slash, nothing the forge leaves alone, and labels the two text-only mistake shapes (#159).
# Expected refs and kinds are listed by hand from the fixture:
#
#   1  see #12 and owner/repo#45                      -> #12 bare (owner/repo#45 is qualified)
#   2  ADR-002/#16 is decided                          -> #16 bare (after a slash: the old spec skipped it)
#   3  #229/#239/#262 landed                           -> #229 #239 #262 bare
#   4  ABC#41 and -#42 and X-#43                       -> none (word char / hyphen before)
#   5  `#5` in code, https://x.example/#6              -> none (inline code; a URL)
#   6-8 a fenced block holding #7                      -> none
#   9  power loss #3                                   -> #3 bare (an ordinal; rewording is the reader's call)
#   10 [#458](https://git.example/acme/billing/issues/458) is the pool -> #458 link-text, acme/billing#458
#   11 Billing#56 is written, then #56 again           -> #56 back-ref, Billing#56
#   12 [#9](https://git.example/acme/Host/issues/9) same repo         -> #9 link-text, acme/Host#9
#   13 Host#77 here, #77 there                         -> #77 back-ref, Host#77
# No --repo: 10 refs. --repo acme/Host: #9 is dropped (a link to the host itself) and #77 becomes plain
# bare (a back-reference to the host's own number) -> 9 refs. Empty text -> 0, exit 0.
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
ABC#41 and -#42 and X-#43
`#5` in code, https://x.example/#6
```
a fenced block holding #7
```
power loss #3
[#458](https://git.example/acme/billing/issues/458) is the pool
Billing#56 is written, then #56 again
[#9](https://git.example/acme/Host/issues/9) same repo
Host#77 here, #77 there
EOF

kinds() { awk -F'\t' '{printf "%s:%s ", $1, $3}' <<<"$1"; }
echo "── bare-refs"
out=$("$BR" "$TMP/t.md"); rc=$?
got=$(kinds "$out")
want="#12:bare #16:bare #229:bare #239:bare #262:bare #3:bare #458:link-text #56:back-ref #9:link-text #77:back-ref "
[ "$got" = "$want" ] && pass "the ten refs, in order, each with its kind" || fail "got [$got]"
[ $rc -eq 1 ] && pass "findings exit 1" || fail "exit $rc"
awk -F'\t' '$1=="#16" && $2==2{f=1} END{exit !f}' <<<"$out" \
  && pass "#16 after a slash is found, on line 2 (the case the old spec skipped)" || fail "slash case missing"
awk -F'\t' '$1=="#458" && $4=="acme/billing#458"{f=1} END{exit !f}' <<<"$out" \
  && pass "link-text suggests the href's repository" || fail "link-text suggestion wrong"
awk -F'\t' '$1=="#56" && $4=="Billing#56"{f=1} END{exit !f}' <<<"$out" \
  && pass "back-ref suggests the qualified form already in the text" || fail "back-ref suggestion wrong"
! awk -F'\t' '$1 ~ /^#(45|41|42|43|5|6|7)$/{f=1} END{exit !f}' <<<"$out" \
  && pass "qualified, word/hyphen-prefixed, code, URL and fenced refs are skipped" \
  || fail "a non-bare ref was reported: $(cut -f1 <<<"$out" | tr '\n' ' ')"

out=$("$BR" --repo acme/Host "$TMP/t.md")
got=$(kinds "$out")
want="#12:bare #16:bare #229:bare #239:bare #262:bare #3:bare #458:link-text #56:back-ref #77:bare "
[ "$got" = "$want" ] && pass "--repo: a link to the host is dropped, a back-ref to the host is plain bare" || fail "with --repo: [$got]"

n=$("$BR" --json "$TMP/t.md" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$n" = 10 ] && pass "--json carries the same 10" || fail "--json count $n"
: > "$TMP/empty.md"; "$BR" "$TMP/empty.md" >/dev/null; [ $? -eq 0 ] && pass "no refs exits 0" || fail "empty text did not exit 0"
o=$(printf 'x #9\n' | "$BR"); grep -q '^#9' <<<"$o" && pass "reads standard input" || fail "stdin not read"
"$BR" "$TMP/no-such.md" >/dev/null 2>&1; [ $? -eq 2 ] && pass "an unreadable file exits 2" || fail "missing file did not exit 2"
"$BR" --repo nohost "$TMP/t.md" >/dev/null 2>&1; [ $? -eq 2 ] && pass "a malformed --repo exits 2" || fail "bad --repo accepted"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; else echo "  ❌ $fails failed"; fi
exit $(( fails > 0 ))
