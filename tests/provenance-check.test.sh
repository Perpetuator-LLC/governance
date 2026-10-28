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
# agent's delegated key signs for alice, the human it acts as. mallory's key is on no list. eve is
# carved out of the forge key's pattern with a negation, so the forge key may never sign as eve.
{
  echo "# fixture allow-list"
  echo "alice@example.com $(pub alice)"
  echo "bob@example.com namespaces=\"git\" $(pub bob)"
  echo "*@example.com,!eve@example.com $(pub forge)"
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

# ── r2: every probe the review found accepted (rc=0) is now a fixture that must be refused ────
# Each probe is a function, so the same check runs against the script and, below, against a mutant
# that reverts just that fix: the mutant must accept the probe again.
echo "  r2 probes"
FPR="0123456789ABCDEF0123456789ABCDEF01234567"
GPG_ID="${FPR%????????????????????????}"  # a 16-hex-digit key id for the stand-in to sign with
# A stand-in for gpg, written to git's documented gpg interface (status lines on --status-fd): gpg
# is not on every runner. It reports a GOOD signature with FULL trust, i.e. a key the runner's own
# keyring trusts and the allow-list does not name.
GPG="$TMP/fake-gpg"
cat > "$GPG" <<EOF
#!/bin/sh
cat >/dev/null
case " \$* " in
*" --verify "*)
  printf '[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG 0123456789ABCDEF carol@other.example\n'
  printf '[GNUPG:] VALIDSIG $FPR 2026-01-01 1767225600 0 4 0 22 8 00 $FPR\n[GNUPG:] TRUST_FULLY 0 pgp\n'
  exit 0;;
*)
  printf '\n[GNUPG:] SIG_CREATED D 22 8 00 1767225600 $FPR\n' >&2
  printf -- '-----BEGIN PGP SIGNATURE-----\n\nZml4dHVyZQ==\n-----END PGP SIGNATURE-----\n'
  exit 0;;
esac
EOF
chmod +x "$GPG"
newrepo gpg_trusted; git -C "$TMP/r/gpg_trusted" config gpg.program "$GPG"; put gpg_trusted a.txt x
git -C "$TMP/r/gpg_trusted" -c user.name=x -c user.email=carol@other.example -c user.signingkey="$GPG_ID" commit -q -S -m "gpg-signed work"
check "control: git reports the stand-in GPG signature as GOOD (G) with its fingerprint" \
  "[ \"\$(git -C '$TMP/r/gpg_trusted' log -1 --format='%G? %GF')\" = 'G $FPR' ]"
probe_1() { run gpg_trusted; [ "$RC" = 1 ] && has REFUSE signature && grep -q 'fingerprint is not on the allow-list' "$TMP/out"; }
check "item 1: a GOOD signature by a trusted but UNLISTED GPG key is refused (row signature)" probe_1

newrepo attrs; put attrs .gitattributes "* -diff
"; put attrs setup.sh "#!/bin/sh
git config $HP .githooks
"; cm attrs alice alice@example.com "setup"
check "control: the committed .gitattributes hides setup.sh from a plain git show" \
  "git -C '$TMP/r/attrs' show --format= HEAD | grep -q '^Binary files'"
probe_2() { run attrs; [ "$RC" = 1 ] && has REFUSE autorun-on-open && grep -q 'setup.sh' "$TMP/out"; }
check "item 2: a hooks-path line behind a PR-committed '* -diff' is still refused" probe_2

newrepo casefold; put casefold .VSCode/Tasks.json "{\"tasks\":[{\"command\":\"true\",\"runOptions\":{\"runOn\":\"$FO\"}}]}"
cm casefold alice alice@example.com "editor task"
probe_3() { run casefold; [ "$RC" = 1 ] && has REFUSE autorun-on-open && grep -q '.VSCode/Tasks.json' "$TMP/out"; }
check "item 3: .VSCode/Tasks.json (any case) with a folder-open task is refused" probe_3

newrepo jsonesc
put jsonesc .vscode/tasks.json '{"tasks":[{"command":"true","runOptions":{"runOn":"folder\u004fpen"}}]}'
put jsonesc .vscode/settings.json '{"task.allow\u0041utomaticTasks": "\u006fn"}'
put jsonesc .devcontainer/devcontainer.json '{"image":"x","post\u0043reateCommand":"true"}'
cm jsonesc alice alice@example.com "escaped editor config"
probe_4() { run jsonesc; [ "$RC" = 1 ] && [ "$(grep -c '^REFUSE *autorun-on-open ' "$TMP/out")" = 3 ]; }
check "item 4: escaped folder-open, automatic-tasks and post-create keys: all 3 refused" probe_4

newrepo nuljs; mkdir -p "$TMP/r/nuljs/src"
{ printf '\000'; rotation_js; printf '\nexport const ok = 1;\n'; } > "$TMP/r/nuljs/src/app.js"
git -C "$TMP/r/nuljs" add src/app.js; cm nuljs alice alice@example.com "app"
probe_5() { run nuljs; [ "$RC" = 1 ] && has REFUSE obfuscation && grep -q 'src/app.js' "$TMP/out"; }
check "item 5: a NUL byte at the start of a .js file no longer skips row 6" probe_5
newrepo nulbin; { printf '\000'; rotation_js; printf '\n'; } > "$TMP/r/nulbin/blob.dat"; git -C "$TMP/r/nulbin" add blob.dat
cm nulbin alice alice@example.com "data"
run nulbin
check "CLEAN: a NUL still marks a non-script file as binary (row 6 skips it)" "[ $RC = 0 ] && none"

newrepo hooksoff; put hooksoff setup.sh "#!/bin/sh
git -c $HP=/dev/null fetch && git config $HP .githooks
"; cm hooksoff alice alice@example.com "setup"
probe_6() { run hooksoff; [ "$RC" = 1 ] && has REFUSE autorun-on-open && grep -q 'setup.sh' "$TMP/out"; }
check "item 6: a /dev/null setting on the same line no longer excuses a real hooks-path setting" probe_6

newrepo oddbytes; put oddbytes a.txt x; cm oddbytes alice alice@example.com "$(printf 'odd \036 record \037 unit bytes')"
probe_7() { run oddbytes; [ "$RC" = 0 ] && none; }
check "item 7: a message holding the old record/unit separators parses (clean: exit 0, no crash)" probe_7

newrepo header; put header setup.sh "#!/bin/sh
++ b/docs/ok.md
git config $HP .githooks
"; cm header alice alice@example.com "setup"
printf 'docs/ok.md  reviewed prose\n' > "$TMP/allow-docs"
probe_8() { run header --allow-paths "$TMP/allow-docs"; [ "$RC" = 1 ] && has REFUSE autorun-on-open && grep -q 'setup.sh' "$TMP/out" && ! grep -q 'docs/ok.md' "$TMP/out"; }
check "item 8: an added line that reads like a '+++ b/' header cannot move the next line to an exempt path" probe_8

newrepo neg; put neg a.txt x; cm neg forge eve@example.com "forge key, eve's name"
probe_9() { run neg; [ "$RC" = 1 ] && has REFUSE author-signer; }
check "item 9: a key listed for *@example.com,!eve@example.com may not sign as eve (negation)" probe_9
newrepo neg_ok; put neg_ok a.txt x; cm neg_ok forge dave@example.com "forge key, dave's name"
run neg_ok
check "CLEAN: ...and that key still signs for anyone else on the domain" "[ $RC = 0 ] && none"

# ── the lists come from the BASE, never from the change under review ────────────────────────
echo "  lists from the base ref"
newrepo lists; cp "$TMP/allowed" "$TMP/r/lists/allowed_signers"; printf '# no exemptions\n' > "$TMP/r/lists/allow-paths"
git -C "$TMP/r/lists" add allowed_signers allow-paths; cm lists alice alice@example.com "lists"
BASE_lists=$(git -C "$TMP/r/lists" rev-parse HEAD)
echo "carol@other.example $(pub mallory)" >> "$TMP/r/lists/allowed_signers"
printf '.vscode/tasks.json  trust me\n' >> "$TMP/r/lists/allow-paths"
put lists .vscode/tasks.json "{\"tasks\":[{\"runOptions\":{\"runOn\":\"$FO\"}}]}"
git -C "$TMP/r/lists" add allowed_signers allow-paths; cm lists mallory carol@other.example "add myself"
probe_lists() { run lists --allowed-signers allowed_signers --allow-paths allow-paths
  [ "$RC" = 1 ] && has REFUSE signature && has REFUSE autorun-on-open && grep -q 'read from' "$TMP/out"; }
check "a change that lists its own key and its own exemption is still refused (lists read from the base)" probe_lists
newrepo lists_ok; cp "$TMP/allowed" "$TMP/r/lists_ok/allowed_signers"; git -C "$TMP/r/lists_ok" add allowed_signers
cm lists_ok alice alice@example.com "lists"; BASE_lists_ok=$(git -C "$TMP/r/lists_ok" rev-parse HEAD)
put lists_ok a.txt x; cm lists_ok bob bob@example.com "work"
run lists_ok --allowed-signers allowed_signers
check "CLEAN: an in-repo list on the base, a change signed by a listed key: passes" "[ $RC = 0 ] && none"
newrepo lists_new; cp "$TMP/allowed" "$TMP/r/lists_new/allowed_signers"; git -C "$TMP/r/lists_new" add allowed_signers
cm lists_new alice alice@example.com "the change adds the list"
run lists_new --allowed-signers allowed_signers
check "an in-repo list missing on the base cannot run (exit 2)" "[ $RC = 2 ] && grep -q 'not on the base' '$TMP/err'"
( cd "$TMP/r/lists_ok" && python3 "$CHK" --allowed-signers allowed_signers HEAD ) >"$TMP/out" 2>"$TMP/err"; RC=$?
check "an in-repo list with no base (no A..B range, no --base) cannot run (exit 2)" "[ $RC = 2 ] && grep -q -- '--base' '$TMP/err'"

# ── row 3 in a shallow clone says it was skipped ─────────────────────────────────────────────
echo "  shallow clone"
git clone -q --depth 2 "file://$TMP/r/copy" "$TMP/r/shallow" 2>/dev/null
BASE_shallow=$(git -C "$TMP/r/shallow" rev-parse HEAD~1)
check "control: the clone is shallow" "[ \"\$(git -C '$TMP/r/shallow' rev-parse --is-shallow-repository)\" = true ]"
probe_shallow() { run shallow; [ "$RC" = 0 ] && grep -q '^SKIP *copied-identity .*shallow' "$TMP/out" && ! has WARN copied-identity; }
check "row 3 prints SKIP (shallow) instead of reporting nothing; the exit code is unchanged" probe_shallow
run copy
check "...while the full clone of the same history still WARNs" "has WARN copied-identity && ! grep -q '^SKIP' '$TMP/out'"

# ── r3: the second review's probes (JSONC comments, a symlinked folder, the env form, M3) ─────
echo "  r3 probes"
newrepo jsonc; put jsonc .devcontainer/devcontainer.json "{\"image\":\"x\",\"$PCC\" /* c */ : \"true\"}"
put jsonc .vscode/settings.json "{\"$AAT\" /**/ : \"on\"}"
cm jsonc alice alice@example.com "commented editor config"
probe_r3_1() { run jsonc; [ "$RC" = 1 ] && grep -q "devcontainer.json: a dev container runs $PCC" "$TMP/out" \
  && grep -q 'settings.json: task.allowAutomaticTasks is turned on' "$TMP/out"; }
check "r3 item 1: a comment between key and colon no longer hides postCreateCommand or allowAutomaticTasks" probe_r3_1
newrepo jsonc_dup; put jsonc_dup .vscode/tasks.json "{\"tasks\":[{\"runOptions\":{\"runOn\":\"$FO\", // first copy
  \"runOn\":\"default\",}},],}"
cm jsonc_dup alice alice@example.com "tasks"
probe_r3_dup() { run jsonc_dup; [ "$RC" = 1 ] && grep -q 'tasks.json: a task runs when the folder is opened' "$TMP/out"; }
check "r3 item 1: a repeated key, a line comment and trailing commas: the folder-open copy is still seen" probe_r3_dup
newrepo jsonc_bad; put jsonc_bad .vscode/tasks.json '{"tasks": [ {"label": "x"'; cm jsonc_bad alice alice@example.com "tasks"
probe_r3_bad() { run jsonc_bad; [ "$RC" = 1 ] && grep -q 'tasks.json: the file does not parse' "$TMP/out"; }
check "r3 item 1: a watched file that does not parse is refused, never skipped" probe_r3_bad
newrepo jsonc_ok; put jsonc_ok .vscode/settings.json "// team settings
{
  /* tasks stay manual */ \"$AAT\": \"off\",
  \"http.proxy\": \"http://proxy/*not-a-comment*/\", // trailing comma next
}"
put jsonc_ok .vscode/tasks.json '{"tasks":[{"label":"build","command":"make //not a comment"}],}'
cm jsonc_ok alice alice@example.com "settings"
run jsonc_ok
check "CLEAN: comments, trailing commas and comment-like text inside strings, automatic tasks off: passes" "[ $RC = 0 ] && none"

newrepo link; mkdir -p "$TMP/r/link/cfg"; printf '%s' "{\"tasks\":[{\"runOptions\":{\"runOn\":\"$FO\"}}]}" > "$TMP/r/link/cfg/tasks.json"
( cd "$TMP/r/link" && ln -s cfg .vscode ) && git -C "$TMP/r/link" add cfg/tasks.json .vscode
cm link alice alice@example.com "editor folder"
check "control: .vscode is committed as a symlink (mode 120000)" "git -C '$TMP/r/link' ls-files -s .vscode | grep -q '^120000 '"
probe_r3_2() { run link; [ "$RC" = 1 ] && grep -q '  .vscode: a symlink at an editor' "$TMP/out"; }
check "r3 item 2: a .vscode symlink to a folder holding a folder-open task is refused" probe_r3_2
newrepo linkfile; mkdir -p "$TMP/r/linkfile/cfg" "$TMP/r/linkfile/.vscode"; printf '{}' > "$TMP/r/linkfile/cfg/t.json"
( cd "$TMP/r/linkfile/.vscode" && ln -s ../cfg/t.json tasks.json ) && git -C "$TMP/r/linkfile" add cfg/t.json .vscode/tasks.json
cm linkfile alice alice@example.com "linked task file"
probe_r3_2b() { run linkfile; [ "$RC" = 1 ] && grep -q '.vscode/tasks.json: a symlink at an editor' "$TMP/out"; }
check "r3 item 2: a symlink at a watched file name (.vscode/tasks.json) is refused" probe_r3_2b
newrepo link_ok; ( cd "$TMP/r/link_ok" && ln -s README docs-link ) && git -C "$TMP/r/link_ok" add docs-link
cm link_ok alice alice@example.com "a plain link"
run link_ok
check "CLEAN: a symlink at an ordinary path passes" "[ $RC = 0 ] && none"

newrepo envform; put envform ci.sh "#!/bin/sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=$HP GIT_CONFIG_VALUE_0=.evil git status
"; cm envform alice alice@example.com "ci"
probe_r3_3() { run envform; [ "$RC" = 1 ] && has REFUSE autorun-on-open && grep -q 'ci.sh' "$TMP/out"; }
check "r3 item 3: GIT_CONFIG_KEY_0=core.hooksPath (the environment form) is refused" probe_r3_3

newrepo nullx; put nullx setup.sh "#!/bin/sh
git config $HP /dev/nullx
"; cm nullx alice alice@example.com "setup"
probe_r3_4() { run nullx; [ "$RC" = 1 ] && has REFUSE autorun-on-open && grep -q 'setup.sh' "$TMP/out"; }
check "r3 item 4: a hooks path that only STARTS with /dev/null (/dev/nullx) is refused" probe_r3_4

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

# ── mutants: revert one r2 fix at a time; its probe must be accepted again ───────────────────
echo "  r2 mutants"
# Item 4 (\u escapes) has no mutant since r3: the JSON parser decodes them, and probe_4 still runs.
for fix in 1 2 3 5 6 9 lists shallow r3_1 r3_dup r3_tc r3_bad r3_2 r3_2b r3_3 r3_4; do
  M="$TMP/mut/fix_$fix"
  python3 - "$CHK" "$M" "$fix" <<'MUT'
import sys
src, dst, fix = sys.argv[1:]
text = open(src).read()
REVERT = {  # each entry restores the pre-fix code, anchored on the fix's own text
    "1": [('    return c["sig"] == "G" and c["fp"] in keys\n', '    return c["sig"] == "G"\n'),
          ('            patterns = keys[c["fp"]]\n',
           '            patterns = keys.get(c["fp"]) or ([c["principal"]] if c["principal"] else [])\n')],
    "2": [('git("show", "--text", "--format=", "-U0"', 'git("show", "--format=", "-U0"')],
    "3": [("    return path.lower()\n", "    return path\n")],
    "5": [('if b"\\0" in data[:8192] and not path.lower().endswith(JS_EXT):', 'if b"\\0" in data[:8192]:')],
    "6": [('            rest = HOOKS_OFF.sub("", line)\n            if any(p.search(rest) for p in HOOKS_PATH):',
           '            if any(p.search(line) for p in HOOKS_PATH) and not HOOKS_OFF.search(line):')],
    "9": [("            if neg:\n                return False\n", "            if neg:\n                continue\n")],
    "lists": [('    top = git("rev-parse", "--show-toplevel", check=False).strip()\n',
               '    return path  # MUTANT\n')],
    "r3_1": [('    return "".join(out)\n', '    return text\n')],
    "r3_dup": [("object_pairs_hook=Members", "object_pairs_hook=None")],
    "r3_tc": [('                out[comma] = " "  # a trailing comma\n', '                pass\n')],
    "r3_bad": [('            return ["the file does not parse', '            return [] and ["the file does not parse')],
    "r3_2": [('            if mode == "120000" and (watched or base in WATCHED_DIRS):', '            if False:')],
    "r3_2b": [('            if mode == "120000" and (watched or base in WATCHED_DIRS):', '            if False:')],
    "r3_3": [('    re.compile(r"(?i)\\bgit_config_key_\\d+\\W{1,6}core\\.hookspath\\b"),', '')],
    "r3_4": [("""/dev/null(?=['"]?(?:\\s|$|[;,)&|]))\"\"\")""", """/dev/null\"\"\")""")],
    "shallow": [('    if name == "copied-identity" and ctx["shallow"]:\n', '    if False:  # MUTANT\n')],
}
for old, new in REVERT[fix]:
    assert text.count(old) == 1, "anchor not found once for fix %s: %r" % (fix, old)
    text = text.replace(old, new)
open(dst, "w").write(text)
MUT
  if [ ! -f "$M" ] || cmp -s "$CHK" "$M"; then bad "mutant fix $fix did not apply"; continue; fi
  ok "mutant fix $fix applied (the file differs from the script)"
  CHECKER="$M"
  probe="probe_$fix"; [ "$fix" = r3_tc ] && probe=probe_r3_dup
  if "$probe"; then bad "mutant fix $fix SURVIVES: its probe still passes"; else ok "mutant fix $fix is caught: its probe fails again"; fi
  CHECKER="$CHK"
done

echo
echo "provenance-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
