#!/usr/bin/env bash
# zsh-trap-gate.test.sh — the floor gate refuses the two zsh expansion traps, and only under zsh (#181).
#
# Both traps were prose rules that kept recurring: a `git push origin "$H:refs/heads/x"` whose `:r` zsh
# consumed, and a grep over `$R="dir1 dir2"` that zsh passed as ONE missing path, nine clean zeros in a
# row. Each case below is fed the way the harness feeds the gate (JSON on stdin), and every refusal has
# its allowed neighbour, because a gate proven only on the refusing side may simply refuse everything.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # never the real deny trail
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

payload() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
# gate <shell> <command> -> exit code; stderr in $TMP/err
gate() { payload "$2" | env -u GOVERNANCE_HARNESS_SHELL -u CLAUDE_TOOL_INPUT SHELL="$1" bash "$GATE" >/dev/null 2>"$TMP/err"; echo $?; }
refuses() {  # refuses <shell> <rule-text> <command>
  local rc; rc=$(gate "$1" "$3")
  if [ "$rc" = 2 ] && grep -q "BLOCKED: $2" "$TMP/err"; then ok "refused under ${1##*/}: $3"
  else bad "NOT refused under ${1##*/} (rc=$rc): $3 — $(head -1 "$TMP/err")"; fi
}
allows() {   # allows <shell> <command>
  local rc; rc=$(gate "$1" "$2")
  if [ "$rc" = 0 ]; then ok "allowed under ${1##*/}: $2"
  else bad "refused under ${1##*/} (rc=$rc): $2 — $(head -1 "$TMP/err")"; fi
}
Z=/bin/zsh; B=/bin/bash
NL=$'\n'

echo "zsh trap gate (#181)"
echo " ── 1. \$name:<letter> is a modifier in zsh"
refuses $Z 'zsh reads `\$H:r`' 'git push origin "$H:refs/heads/x"'
refuses $Z 'zsh reads `\$B:s`' 'git show $B:services/app.py'
refuses $Z 'zsh reads `\$F:t`' 'cp $F:t /tmp/'
refuses $Z 'zsh reads `\$USER:s`' 'chown $USER:staff f'
refuses $Z 'zsh reads `\$1:h`' 'ls $1:h'
# An UNQUOTED heredoc body is expanded by zsh while it is built, so its modifiers apply.
refuses $Z 'zsh reads `\$H:r`' "cat <<EOF > /tmp/x${NL}\$H:refs/heads/x${NL}EOF"
# The reason names the fix.
gate $Z 'git push origin "$H:refs/heads/x"' >/dev/null
grep -q 'Brace the name: `${H}:…`' "$TMP/err" && ok "the refusal names the braced form" || bad "the refusal does not name the braced form"
allows $Z 'git push origin "${H}:refs/heads/x"'
allows $Z 'echo "$a:$b"'
allows $Z 'ls $a:/x'
allows $Z 'echo $a:0'
allows $Z "echo '\$H:refs'"
allows $Z 'echo \$H:refs'
allows $Z 'echo "\$H:refs"'
allows $Z 'echo hi # $H:refs'
allows $Z 'git push origin main:feature/x'
# A QUOTED heredoc body is expanded by no shell: it is data, or code for another interpreter.
allows $Z "python3 - <<'PY'${NL}print(\"\$H:refs\")${NL}PY"
allows $Z "git commit -F - <<\"EOF\"${NL}note: \$sha:refs is mangled in zsh${NL}EOF"

echo " ── 2. zsh does not word-split an unquoted \$name"
refuses $Z 'zsh does not word-split an unquoted `\$R`' 'R=".governance Engagements/Internal/Strategy"; grep -ril KPI-014 $R'
refuses $Z 'zsh does not word-split an unquoted `\$R`' "R='a b'; for f in \$R; do ls \"\$f\"; done"
refuses $Z 'zsh does not word-split an unquoted `\$P`' 'export P="x y" && ls ${P}'
gate $Z 'R="a b"; ls $R' >/dev/null
grep -q 'use an array, R=(a b) and "${R\[@\]}"; for one, quote it, "$R"' "$TMP/err" \
  && ok "the refusal names both fixes" || bad "the refusal does not name both fixes: $(head -1 "$TMP/err")"
allows $Z 'A=(.governance Engagements/Internal/Strategy); grep -ril KPI-014 "${A[@]}"'
allows $Z 'D="Engagements/Internal/Strategy"; grep -ril KPI-014 $D'
allows $Z 'R="a b"; ls "$R"'
allows $Z 'M="hello world"; echo $M'
allows $Z 'R="a b"; ls ${=R}'
allows $Z 'R="a b"; S=$R; ls "$S"'
allows $Z 'R="a b"; ls $RX'
# A body fed to bash runs under bash, where the unquoted form is the correct idiom.
allows $Z "bash <<'SH'${NL}R=\"a b\"; ls \$R${NL}SH"

echo " ── 3. scope: only a zsh harness shell"
allows $B 'git push origin "$H:refs/heads/x"'
allows $B 'R=".governance Engagements/Internal/Strategy"; grep -ril KPI-014 $R'
rc=$(payload 'git push origin "$H:refs/heads/x"' | env -u CLAUDE_TOOL_INPUT SHELL=$B GOVERNANCE_HARNESS_SHELL=zsh bash "$GATE" >/dev/null 2>"$TMP/err"; echo $?)
[ "$rc" = 2 ] && ok "GOVERNANCE_HARNESS_SHELL=zsh turns the check on over a bash login shell" \
  || bad "the override did not turn the check on (rc=$rc)"
rc=$(payload 'git push origin "$H:refs/heads/x"' | env -u CLAUDE_TOOL_INPUT SHELL=$Z GOVERNANCE_HARNESS_SHELL=/bin/bash bash "$GATE" >/dev/null 2>"$TMP/err"; echo $?)
[ "$rc" = 0 ] && ok "GOVERNANCE_HARNESS_SHELL=/bin/bash turns it off over a zsh login shell" \
  || bad "the override did not turn the check off (rc=$rc)"
# The other checks are untouched by the scope: a force push is refused under either shell.
refuses $B 'Force push' 'git push origin main --force'
refuses $Z 'Force push' 'git push origin main --force'

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
