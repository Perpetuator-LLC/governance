#!/usr/bin/env bash
# attribution-check.test.sh — the CI gate for agent attribution trailers.
#
# One fixture commit per class. Each expectation comes from what that commit CARRIES, stated before
# the checker runs, never read back from its output:
#   full block + AI co-author          → attributed
#   forge-footer line (` · ` separated) → attributed
#   AI co-author only                   → INCOMPLETE (the shape that kept shipping)
#   two of three trailers               → INCOMPLETE, naming the one it lacks
#   nothing                             → unattributed (a human's commit), never a failure
#   a HUMAN co-author only              → unattributed: a co-author is an agent signal only if it names a model
#   a merge commit with nothing         → not checked at all
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$ROOT/bin/attribution-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

R="$TMP/repo"
git init -q "$R"
g() { git -C "$R" -c user.email=t@example.com -c user.name=test -c commit.gpgsign=false "$@"; }
n=0
commit() { n=$((n+1)); echo "$n" > "$R/f$n"; g add "f$n"; g commit -q -F -; }

g commit -q --allow-empty -m seed
BASE=$(g rev-parse HEAD)
commit <<'EOF'
full: block before the co-author

Harness: claude
Model: claude-opus-5-5
Initiated-By: nik

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
commit <<'EOF'
footer: one line

Harness: claude · Model: claude-opus-5-5 · Seat: x · Initiated-By: nik
EOF
GOOD=$(g rev-parse HEAD)
commit <<'EOF'
coauthor-only: the shape that kept shipping

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
commit <<'EOF'
two-of-three

Harness: codex
Model: gpt-6
EOF
commit <<'EOF'
human: no trailers at all
EOF
commit <<'EOF'
human-coauthor: pair-programmed with a person

Co-Authored-By: Jane Doe
EOF
g checkout -q -b side
commit <<'EOF'
side: attributed

Harness: claude
Model: claude-opus-5-5
Initiated-By: nik
EOF
g checkout -q -
g merge -q --no-ff side -m "merge side, no trailers"
HEAD_=$(g rev-parse HEAD)

# --- mutation sweep: every AI_COAUTHOR keyword individually, not just 'claude' ---------------------
# The earlier coauthor-only fixture only exercises the "claude" branch of the keyword alternation.
# Mutating out any OTHER keyword (anthropic, codex, openai, gpt, grok, xai) survived every check above
# — a co-author line naming Codex or Grok, with no other trailer, would be silently read as a human's
# commit (UNATTRIBUTED) instead of INCOMPLETE. One fixture per remaining keyword, same shape as
# coauthor-only, kills each.
commit <<'EOF'
coauthor-anthropic: names the org, not a product
Co-Authored-By: An Anthropic Agent <noreply@anthropic.com>
EOF
KW_ANTHROPIC=$(g rev-parse HEAD)
commit <<'EOF'
coauthor-codex: a different harness entirely
Co-Authored-By: Codex <noreply@example.com>
EOF
KW_CODEX=$(g rev-parse HEAD)
commit <<'EOF'
coauthor-openai: the vendor name, not the product
Co-Authored-By: OpenAI Assistant <noreply@openai.com>
EOF
KW_OPENAI=$(g rev-parse HEAD)
commit <<'EOF'
coauthor-gpt: bare model family name
Co-Authored-By: GPT-5 <noreply@example.com>
EOF
KW_GPT=$(g rev-parse HEAD)
commit <<'EOF'
coauthor-grok: xAI's model
Co-Authored-By: Grok <noreply@x.ai>
EOF
KW_GROK=$(g rev-parse HEAD)
commit <<'EOF'
coauthor-xai: the vendor name, not the product
Co-Authored-By: An xAI Agent <noreply@x.ai>
EOF
KW_XAI=$(g rev-parse HEAD)

# --- mutation sweep: a trailer KEY with no value must not count as present -------------------------
# has()'s \S requirement after the colon is what makes this fail correctly; removing it (a key present,
# value empty or whitespace-only) survived every check above.
commit <<'EOF'
empty-value: Harness is declared but given no value

Harness:
Model: claude-opus-5-5
Initiated-By: nik
EOF
EMPTY_VALUE=$(g rev-parse HEAD)

# --- mutation sweep: a trailer-shaped phrase embedded in PROSE must not count as a trailer -----------
# has()'s requirement that a match sit at line-start or directly after a '· ' separator is what keeps
# a conversational mention from being read as a real trailer. Relaxing that requirement to "anywhere in
# the text" survived every check above — all three keys below appear only mid-sentence, never at a
# line's own start.
commit <<'EOF'
prose-mention: a conversational reference to the trailer names, never actually set as trailers

This explains why Harness: claude and Model: claude-opus-5-5 and Initiated-By: nik are the three
fields the gate requires, without actually declaring any of them on this commit.
EOF
PROSE_MENTION=$(g rev-parse HEAD)

echo "attribution-check"
out="$(cd "$R" && "$CHK" "$BASE..$HEAD_")"; rc=$?
check "a range holding incomplete commits exits 1"          "[ $rc -eq 1 ]"
check "co-author-only is INCOMPLETE"                        "grep -q 'INCOMPLETE .*coauthor-only' <<<\"\$out\""
check "two-of-three is INCOMPLETE and names Initiated-By"   "grep -A1 'INCOMPLETE .*two-of-three' <<<\"\$out\" | grep -q 'lacks Initiated-By:\$'"
check "exactly 2 incomplete"                                "[ \$(grep -c '^INCOMPLETE' <<<\"\$out\") -eq 2 ]"
check "a commit with no trailers is UNATTRIBUTED, not failed" "grep -q 'UNATTRIBUTED .*human: no trailers' <<<\"\$out\""
check "a HUMAN co-author is not an agent signal"            "grep -q 'UNATTRIBUTED .*human-coauthor' <<<\"\$out\""
check "the full block and the footer line both pass"        "! grep -qE '(full|footer):' <<<\"\$out\""
check "the merge commit is not checked (7 non-merge commits)" "grep -q '7 commit(s), 2 incomplete' <<<\"\$out\""

out="$(cd "$R" && "$CHK" "$BASE..$GOOD")"; rc=$?
check "a range of attributed commits exits 0"               "[ $rc -eq 0 ]"

out="$(cd "$R" && "$CHK" "$HEAD_..$HEAD_" 2>&1)"; rc=$?
check "an EMPTY range exits 2, never clean"                 "[ $rc -eq 2 ] && grep -q 'not a pass' <<<\"\$out\""
out="$(cd "$R" && "$CHK" "nosuch..$HEAD_" 2>&1)"; rc=$?
check "an unreadable range exits 2"                         "[ $rc -eq 2 ]"
out="$(cd "$R" && "$CHK" 2>&1)"; rc=$?
check "no range is a usage error (2)"                       "[ $rc -eq 2 ]"

echo "attribution-check — mutation sweep additions"
for pair in "KW_ANTHROPIC:anthropic" "KW_CODEX:codex" "KW_OPENAI:openai" "KW_GPT:gpt" "KW_GROK:grok" "KW_XAI:xai"; do
  var="${pair%%:*}"; kw="${pair##*:}"
  sha="${!var}"
  out="$(cd "$R" && "$CHK" "$sha^..$sha")"; rc=$?
  check "a Co-Authored-By naming '$kw' with no other trailer is INCOMPLETE, not UNATTRIBUTED" \
    "[ $rc -eq 1 ] && grep -q '^INCOMPLETE' <<<\"\$out\" && ! grep -q '^UNATTRIBUTED' <<<\"\$out\""
done

out="$(cd "$R" && "$CHK" "$EMPTY_VALUE^..$EMPTY_VALUE")"; rc=$?
check "a trailer KEY present with an EMPTY value does not count — INCOMPLETE, names Harness:" \
  "[ $rc -eq 1 ] && grep -A1 '^INCOMPLETE' <<<\"\$out\" | grep -q 'lacks Harness:\$'"

out="$(cd "$R" && "$CHK" "$PROSE_MENTION^..$PROSE_MENTION")"; rc=$?
check "the three trailer names mentioned mid-PROSE (never at line-start, never after '· ') are not trailers — UNATTRIBUTED" \
  "[ $rc -eq 0 ] && grep -q '^UNATTRIBUTED' <<<\"\$out\""

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
