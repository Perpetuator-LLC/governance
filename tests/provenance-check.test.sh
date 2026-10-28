#!/usr/bin/env bash
# provenance-check.test.sh — the commit-provenance and content-trap gate.
#
# Every row has a POSITIVE CONTROL that must be refused and a CLEAN neighbour that must pass, each
# built in a throwaway repository at test time; nothing malicious-looking is committed here. The
# payload fixtures rebuild the SHAPE of a known attack (an unsigned commit wearing a teammate's name,
# email and date; an editor task that runs on folder open with its output hidden; a setting that
# lets tasks run unasked; a one-line obfuscated script named like a font), never a live sample: the
# "script" is inert, and the trigger strings are assembled at run time so this file does not itself
# carry the shapes the gate hunts. Then a scripted MUTANT disables each row in turn, and the row's
# positive control must notice. Every key below is generated here and deleted on exit.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$ROOT/bin/provenance-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Isolate git from the machine: a global signing default or hooks path would change every answer.
mkdir -p "$TMP/home"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"; : > "$GIT_CONFIG_GLOBAL"
unset SSH_AUTH_SOCK GIT_DIR GIT_WORK_TREE

echo "provenance-check"
check "the script is executable" "[ -x '$CHK' ]"
command -v ssh-keygen >/dev/null || { echo "  ❌ ssh-keygen missing; cannot build signed fixtures"; exit 1; }

K="$TMP/keys"; mkdir -p "$K"
for who in alice bob mallory forge agent; do ssh-keygen -q -t ed25519 -N '' -C "fixture-$who" -f "$K/$who"; done
pub() { cut -d' ' -f1,2 "$K/$1.pub"; }
# alice and bob are humans; the forge's web-merge key signs for every human on the domain; the
# agent's delegated key signs for alice, the human it acts as. mallory's key is on no list.
{
  echo "# fixture allow-list"
  echo "alice@example.com $(pub alice)"
  echo "bob@example.com namespaces=\"git\" $(pub bob)"
  echo "*@example.com $(pub forge)"
  echo "alice@example.com $(pub agent)"
} > "$TMP/allowed"
CANARY="CANARY-CONTENT-do-not-print"

# repo NAME → a fresh repository with one alice-signed seed commit; BASE_<NAME> is that commit.
newrepo() {
  local r="$TMP/r/$1"; mkdir -p "$r"; git -C "$r" init -q -b main 2>/dev/null || git -C "$r" init -q
  git -C "$r" symbolic-ref HEAD refs/heads/main
  echo seed > "$r/README"; git -C "$r" add README
  cm "$1" alice alice@example.com "seed"
  eval "BASE_$1=\$(git -C '$r' rev-parse HEAD)"
}
# cm NAME KEY|none EMAIL MESSAGE [DATE] — commit what is staged (empty allowed).
cm() {
  local r="$TMP/r/$1" key="$2" email="$3" msg="$4" date="${5:-}"
  local sign="-c commit.gpgsign=false"; local s=""
  [ "$key" = none ] || { sign="-c gpg.format=ssh -c user.signingkey=$K/$key"; s="-S"; }
  if [ -n "$date" ]; then
    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" git -C "$r" -c user.name=x -c user.email="$email" $sign commit -q --allow-empty $s -m "$msg"
  else
    git -C "$r" -c user.name=x -c user.email="$email" $sign commit -q --allow-empty $s -m "$msg"
  fi
}
put() { mkdir -p "$(dirname "$TMP/r/$1/$2")"; printf '%s' "$3" > "$TMP/r/$1/$2"; git -C "$TMP/r/$1" add -- "$2"; }
# run NAME [args] — check BASE_<NAME>..HEAD with the fixture allow-list; sets RC, output in $TMP/out.
CHECKER="$CHK"
run() {
  local n="$1"; shift; local base; eval "base=\$BASE_$n"
  ( cd "$TMP/r/$n" && python3 "$CHECKER" --allowed-signers "$TMP/allowed" "$@" "$base..HEAD" ) >"$TMP/out" 2>"$TMP/err"
  RC=$?; cat "$TMP/out" "$TMP/err" >> "$TMP/all-output"
}
has()   { grep -q "^$1 *$2 " "$TMP/out"; }
none()  { ! grep -qE '^(REFUSE|WARN) ' "$TMP/out"; }

# Trigger strings, assembled so this file never carries them whole.
FO="folder""Open"; AAT="task.allow""AutomaticTasks"; PCC="post""CreateCommand"; PSC="post""StartCommand"
HP="core.hooks""Path"; X="_""0x"; Q="'"
rotation_js() {  # the commodity string-array-rotation shape; every string is inert
  local arr="" i=0
  while [ $i -lt 24 ]; do arr="$arr${arr:+,}${Q}s$i${Q}"; i=$((i+1)); done
  printf "var ${X}1a2b=[%s];(function(${X}3c4d,${X}5e6f){var ${X}7a8b=function(${X}9c0d){while(--${X}9c0d){${X}3c4d[${Q}pu""sh${Q}](${X}3c4d[${Q}sh""ift${Q}]());}};${X}7a8b(++${X}5e6f);}(${X}1a2b,0x1f4));var ${X}e1f2=function(${X}a1,${X}b2){return ${X}1a2b[${X}a1-0x0];};" "$arr"
}
pad_line() { local s="" i=0; while [ $i -lt 1400 ]; do s="${s}var a=$i;"; i=$((i+1)); done; printf '%s' "$s"; }

# ── row 1: signature ─────────────────────────────────────────────────────────────────────────
echo "  row 1 · signature"
newrepo sig_bad; put sig_bad a.txt "$CANARY"; cm sig_bad none carol@other.example "unsigned work"
run sig_bad
check "an unsigned commit is refused (exit 1, row signature)" "[ $RC = 1 ] && has REFUSE signature && grep -q unsigned '$TMP/out'"
newrepo sig_unlisted; put sig_unlisted a.txt x; cm sig_unlisted mallory carol@other.example "signed, unlisted key"
run sig_unlisted
check "a commit signed by a key on no list is refused" "[ $RC = 1 ] && has REFUSE signature && grep -q 'not on the allow-list' '$TMP/out'"
newrepo sig_ok; put sig_ok a.txt x; cm sig_ok alice alice@example.com "signed work"
run sig_ok
check "CLEAN: a commit signed by its author's listed key passes (exit 0, nothing reported)" "[ $RC = 0 ] && none"
newrepo forge; git -C "$TMP/r/forge" checkout -q -b topic; put forge t.txt x; cm forge alice alice@example.com "topic work"
git -C "$TMP/r/forge" checkout -q main
git -C "$TMP/r/forge" -c user.name=x -c user.email=bob@example.com -c gpg.format=ssh -c user.signingkey="$K/forge" merge -q --no-ff -S -m "Merge topic" topic
run forge
check "CLEAN: a web merge signed by the forge key (listed for *@example.com) passes" "[ $RC = 0 ] && none"
newrepo agent; put agent a.txt x; cm agent agent alice@example.com "agent work for alice"
run agent
check "CLEAN: an agent commit signed by the key delegated for its author passes" "[ $RC = 0 ] && none"

# ── row 2: author ≠ signer ───────────────────────────────────────────────────────────────────
echo "  row 2 · author-signer"
newrepo as_bad; put as_bad a.txt x; cm as_bad bob alice@example.com "bob's key, alice's name"
run as_bad
check "a listed key signing for another listed human is refused (row author-signer only)" \
  "[ $RC = 1 ] && has REFUSE author-signer && ! has REFUSE signature"
check "…and it names both the author and the key's principals" "grep -q 'author alice@example.com' '$TMP/out' && grep -q 'bob@example.com' '$TMP/out'"
newrepo as_agent_wrong; put as_agent_wrong a.txt x; cm as_agent_wrong agent bob@example.com "agent key, bob's name"
run as_agent_wrong
check "an agent key used for a human it was NOT delegated for is refused" "[ $RC = 1 ] && has REFUSE author-signer"
newrepo as_none; put as_none a.txt x; cm as_none none alice@example.com "alice's name, no signature"
run as_none
check "a listed human's identity on an unsigned commit is refused as author-signer too" "[ $RC = 1 ] && has REFUSE author-signer && has REFUSE signature"
newrepo as_ok; put as_ok a.txt x; cm as_ok bob bob@example.com "bob signs as bob"
run as_ok
check "CLEAN: a human signing as themselves passes" "[ $RC = 0 ] && none"

# ── row 3: copied identity (warning) ─────────────────────────────────────────────────────────
echo "  row 3 · copied-identity"
D="1767225600 +0000"
newrepo copy; git -C "$TMP/r/copy" checkout -q -b landed; put copy l.txt "one"; cm copy alice alice@example.com "refactor the parser" "$D"
git -C "$TMP/r/copy" checkout -q main; put copy evil.txt "two"; cm copy alice alice@example.com "refactor the parser" "$D"
run copy
check "same author date + message, different change: WARN copied-identity, exit stays 0" "[ $RC = 0 ] && has WARN copied-identity"
newrepo pick; git -C "$TMP/r/pick" checkout -q -b landed; put pick p.txt "same"; cm pick alice alice@example.com "fix the parser" "$D"
L=$(git -C "$TMP/r/pick" rev-parse HEAD); git -C "$TMP/r/pick" checkout -q main
git -C "$TMP/r/pick" -c user.name=x -c user.email=alice@example.com -c gpg.format=ssh -c user.signingkey="$K/alice" cherry-pick -S "$L" >/dev/null
run pick
check "CLEAN: a cherry-pick (same date, message AND patch) is not reported" "[ $RC = 0 ] && none"

# ── row 4: auto-run on open ──────────────────────────────────────────────────────────────────
echo "  row 4 · autorun-on-open"
newrepo task; put task .vscode/tasks.json "{\"version\":\"2.0.0\",\"tasks\":[{\"label\":\"$CANARY\",\"type\":\"shell\",\"command\":\"true\",\"presentation\":{\"reveal\":\"never\",\"echo\":false},\"runOptions\":{\"runOn\":\"$FO\"}}]}"
cm task alice alice@example.com "editor task"
run task
check "a task that runs on folder open, output hidden, is refused" "[ $RC = 1 ] && has REFUSE autorun-on-open && grep -q '.vscode/tasks.json' '$TMP/out'"
newrepo setting; put setting .vscode/settings.json "{\"$AAT\": \"on\"}"; cm setting alice alice@example.com "settings"
run setting
check "turning automatic tasks on in settings.json is refused" "[ $RC = 1 ] && has REFUSE autorun-on-open"
newrepo dc; put dc .devcontainer/devcontainer.json "{\"image\":\"x\",\"$PCC\":\"true\",\"$PSC\":\"true\"}"; cm dc alice alice@example.com "container"
run dc
check "a dev container post-create/post-start command is refused" "[ $RC = 1 ] && has REFUSE autorun-on-open && grep -q '$PCC/$PSC' '$TMP/out'"
newrepo hook; put hook .githooks/pre-commit "true"; cm hook alice alice@example.com "hook"
run hook
check "a committed .githooks/ file is refused" "[ $RC = 1 ] && has REFUSE autorun-on-open && grep -q '.githooks/pre-commit' '$TMP/out'"
newrepo hp; put hp setup.sh "#!/bin/sh
git config $HP .githooks
"; cm hp alice alice@example.com "setup"
run hp
check "an added line that sets the hooks path is refused, naming the file" "[ $RC = 1 ] && has REFUSE autorun-on-open && grep -q 'setup.sh' '$TMP/out'"
newrepo task_ok; put task_ok .vscode/tasks.json '{"tasks":[{"label":"build","command":"make"}]}'
put task_ok .vscode/settings.json "{\"$AAT\": \"off\", \"editor.tabSize\": 2}"
put task_ok .devcontainer/devcontainer.json '{"image":"x"}'; put task_ok docs.md "the hooks path setting is documented here"
put task_ok test.mjs "git(clone, 'config', '$HP', '/dev/null');"
cm task_ok alice alice@example.com "ordinary editor config"
run task_ok
check "CLEAN: a manual task, automatic tasks OFF, a plain container, prose about hooks, hooks pointed at /dev/null: all pass" "[ $RC = 0 ] && none"
newrepo evilmerge; git -C "$TMP/r/evilmerge" checkout -q -b topic; put evilmerge t.txt x; cm evilmerge alice alice@example.com "topic"
git -C "$TMP/r/evilmerge" checkout -q main
git -C "$TMP/r/evilmerge" -c user.name=x -c user.email=alice@example.com -c commit.gpgsign=false merge -q --no-ff --no-commit topic
put evilmerge .vscode/tasks.json "{\"tasks\":[{\"runOptions\":{\"runOn\":\"$FO\"}}]}"; cm evilmerge alice alice@example.com "Merge topic"
run evilmerge
check "a task the MERGE commit itself introduces is refused, attributed to the merge" \
  "[ $RC = 1 ] && has REFUSE autorun-on-open && grep -q \"\$(git -C '$TMP/r/evilmerge' rev-parse --short=12 HEAD)\" '$TMP/out'"
printf '.vscode/tasks.json  the team task, reviewed: it only prints a banner\n' > "$TMP/allow-paths"
run task --allow-paths "$TMP/allow-paths"
check "CLEAN: the same folder-open task passes when its path is allow-listed with a reason" "[ $RC = 0 ] && none"
printf '.vscode/tasks.json\n' > "$TMP/allow-noreason"
run task --allow-paths "$TMP/allow-noreason"
check "an allow-list line with no reason cannot run (exit 2), never a silent exemption" "[ $RC = 2 ]"

# ── row 5: type mismatch ─────────────────────────────────────────────────────────────────────
echo "  row 5 · type-mismatch"
newrepo font; put font public/fonts/fa-brand-400.woff "$CANARY $(rotation_js)"; cm font alice alice@example.com "font"
run font
check "script text behind a .woff name is refused as text or script" "[ $RC = 1 ] && has REFUSE type-mismatch && grep -q 'text or script' '$TMP/out'"
newrepo font_ok; printf 'wOFF\000\001\000\000\000\000\000\000' > "$TMP/r/font_ok/real.woff"
printf '\211PNG\r\n\032\n\000\000\000\rIHDR' > "$TMP/r/font_ok/real.png"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 12345\n' 0 > "$TMP/r/font_ok/lfs.png"
git -C "$TMP/r/font_ok" add real.woff real.png lfs.png; cm font_ok alice alice@example.com "assets"
run font_ok
check "CLEAN: real WOFF and PNG magic, and a Git LFS pointer, all pass" "[ $RC = 0 ] && none"

# ── row 6: obfuscation shape ─────────────────────────────────────────────────────────────────
echo "  row 6 · obfuscation"
newrepo oneline; put oneline dist/app.js "$(pad_line)"; cm oneline alice alice@example.com "bundle"
run oneline
check "a new single-line .js over 10 KB is refused" "[ $RC = 1 ] && has REFUSE obfuscation && grep -q 'single line' '$TMP/out'"
newrepo rot; put rot src/util.js "$(rotation_js)
export const ok = 1;
"; cm rot alice alice@example.com "util"
run rot
check "the string-array-rotation shape is refused in a multi-line file" "[ $RC = 1 ] && has REFUSE obfuscation && grep -q 'rotation' '$TMP/out'"
newrepo js_ok; put js_ok src/queue.js 'export function next(q) {
  q.push(q.shift());
  return q[0];
}
'; put js_ok src/small.js "var a = 1;"; cm js_ok alice alice@example.com "queue"
run js_ok
check "CLEAN: ordinary JS, including a round-robin push(shift()), passes" "[ $RC = 0 ] && none"

# ── the reconstructed payload: every row at once ─────────────────────────────────────────────
echo "  payload shape"
newrepo payload; put payload real.txt "a"; cm payload bob bob@example.com "Update docs" "1767312000 +0000"
git -C "$TMP/r/payload" branch landed; BASE_payload=$(git -C "$TMP/r/payload" rev-parse HEAD)
put payload .vscode/tasks.json "{\"tasks\":[{\"command\":\"true\",\"presentation\":{\"reveal\":\"never\"},\"runOptions\":{\"runOn\":\"$FO\"}}]}"
put payload .vscode/settings.json "{\"$AAT\": \"on\"}"
put payload public/fonts/fa-brand-400.woff "$(rotation_js)$(pad_line)"
cm payload none bob@example.com "Update docs" "1767312000 +0000"
run payload
for r in signature author-signer autorun-on-open type-mismatch obfuscation; do
  check "payload: REFUSE $r" "has REFUSE $r"
done
check "payload: WARN copied-identity (teammate's date + message reused)" "has WARN copied-identity"

# ── output, ranges, exit codes ───────────────────────────────────────────────────────────────
echo "  output and exit codes"
newrepo esc; f="$(printf 'x\n::error::forged.woff')"; printf 'text' > "$TMP/r/esc/$f"; git -C "$TMP/r/esc" add -- "$f"; cm esc alice alice@example.com "odd name"
run esc
check "an attacker-chosen path with a newline is escaped: no output line starts with ::" "[ $RC = 1 ] && ! grep -q '^::' '$TMP/out' && grep -q 'x\\\\x0a::error::forged.woff' '$TMP/out'"
( cd "$TMP/r/sig_ok" && python3 "$CHK" "$BASE_sig_ok..HEAD" ) >"$TMP/out" 2>&1; RC=$?
check "no --allowed-signers: exit 3 and says rows 1-2 were NOT CHECKED" "[ $RC = 3 ] && grep -q 'NOT CHECKED' '$TMP/out'"
( cd "$TMP/r/sig_bad" && python3 "$CHK" "$BASE_sig_bad..HEAD" ) >"$TMP/out" 2>&1; RC=$?
check "no --allowed-signers, nothing else wrong: still not 0" "[ $RC = 3 ]"
( cd "$TMP/r/sig_ok" && python3 "$CHK" --allowed-signers "$TMP/allowed" HEAD..HEAD ) >"$TMP/out" 2>&1; RC=$?
check "an empty range cannot run (exit 2), never a pass" "[ $RC = 2 ]"
( cd "$TMP/r/sig_ok" && python3 "$CHK" --allowed-signers "$TMP/allowed" no-such-ref..HEAD ) >"$TMP/out" 2>&1; RC=$?
check "a bad range cannot run (exit 2)" "[ $RC = 2 ]"
( cd "$TMP/r/sig_ok" && python3 "$CHK" --allowed-signers "$TMP/missing" "$BASE_sig_ok..HEAD" ) >"$TMP/out" 2>&1; RC=$?
check "a missing allow-list cannot run (exit 2)" "[ $RC = 2 ]"
( cd "$TMP/r/sig_ok" && git checkout -q -b probe && python3 "$CHK" --allowed-signers "$TMP/allowed" ) >"$TMP/out" 2>&1; RC=$?
check "the default range is origin/main..HEAD (no origin here ⇒ exit 2, named in the error)" "[ $RC = 2 ] && grep -q 'origin/main..HEAD\|origin/main' '$TMP/out'"
check "across every run above, no file content was ever printed" "! grep -q '$CANARY' '$TMP/all-output'"

# ── mutants: disable one row at a time; its positive control must notice ─────────────────────
echo "  mutants"
positive() { case "$1" in
  signature) echo sig_bad;; author_signer) echo as_bad;; copied_identity) echo copy;;
  autorun) echo task;; type_mismatch) echo font;; obfuscation) echo rot;; esac; }
label() { case "$1" in
  signature) echo signature;; author_signer) echo author-signer;; copied_identity) echo copied-identity;;
  autorun) echo autorun-on-open;; type_mismatch) echo type-mismatch;; obfuscation) echo obfuscation;; esac; }
mkdir -p "$TMP/mut"
for row in signature author_signer copied_identity autorun type_mismatch obfuscation; do
  M="$TMP/mut/$row"
  python3 - "$CHK" "$M" "$row" <<'PY'
import sys
src, dst, row = sys.argv[1:]
text = open(src).read()
anchor = "def row_%s(ctx):\n" % row
assert text.count(anchor) == 1, "anchor not found once: " + anchor
open(dst, "w").write(text.replace(anchor, anchor + "    return []  # MUTANT\n"))
PY
  applied=$(grep -c '# MUTANT' "$M" 2>/dev/null || true)
  check "mutant $row applied (exactly one disabled row)" "[ '$applied' = 1 ]"
  CHECKER="$M"; run "$(positive "$row")"; CHECKER="$CHK"
  check "mutant $row is caught: its positive control no longer reports $(label "$row")" \
    "! grep -qE '^(REFUSE|WARN) +$(label "$row") ' '$TMP/out'"
  run "$(positive "$row")"
  check "…and the unmutated script still reports it on the same fixture" "grep -qE '^(REFUSE|WARN) +$(label "$row") ' '$TMP/out'"
done

echo
echo "provenance-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
