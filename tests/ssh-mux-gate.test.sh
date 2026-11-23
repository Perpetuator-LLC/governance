#!/usr/bin/env bash
# tests/ssh-mux-gate.test.sh — bash-safety-gate's SSH-multiplexing check (governance#433, cisa
# SEND-BACK on PR #438 c189241): refuse turning ON a connection master (-M, ControlMaster=yes/auto/
# ask/autoask/true — in any getopt-bundled or attached flag form), keeping one open (ControlPath other
# than none, ControlPersist other than no — INCLUDING when that comes from the user's OWN ssh config,
# not just a command-line flag), or reusing one (-S, unless paired with -O exit on that SAME ssh call).
# A plain ssh or git push over a config that is itself clean, and the explicit "off" spellings, stay
# allowed.
#
# No real network ssh runs here, ever: the gate's own subprocess call is `ssh -G ...`, which OpenSSH
# documents as print-the-effective-config-and-exit, no connection — but this sandbox has no ssh binary
# installed at all, so every test below runs under a FAKE `ssh` (this file's own, below) that answers
# `-G` the same way: reads any `-F`/`-o` the real call would have used, applies them over ssh's real
# defaults (controlmaster no, controlpath none, controlpersist no), prints the result, and refuses to
# do anything else. The hook code path under test — build the ssh -G argv, run it, parse its output —
# is the SAME code whether the real binary or this fixture answers it.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

. "$ROOT/tests/lib/shim-path.sh"

# A fake `ssh` that understands only `-G [-F file]... [-o k=v]... target`. File/`-o` overrides are
# applied in the SAME precedence real ssh uses (command-line wins), over ssh's own real defaults.
FAKESSH="$TMP/fakebin"; mkdir -p "$FAKESSH"
cat > "$FAKESSH/ssh" <<'FAKE'
#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if not args or args[0] != "-G":
    sys.exit(1)
args = args[1:]
cfg = {"controlmaster": "no", "controlpath": "none", "controlpersist": "no"}
i, fvals, ovals = 0, [], []
while i < len(args):
    if args[i] == "-F" and i + 1 < len(args):
        fvals.append(args[i + 1]); i += 2; continue
    if args[i] == "-o" and i + 1 < len(args):
        ovals.append(args[i + 1]); i += 2; continue
    i += 1
for fpath in fvals:
    try:
        with open(fpath) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2 and parts[0].lower() in cfg:
                    cfg[parts[0].lower()] = parts[1].strip().lower()
    except OSError:
        pass
for o in ovals:
    if "=" in o:
        k, v = o.split("=", 1)
    else:
        parts = o.split(None, 1)
        k, v = (parts[0], parts[1]) if len(parts) == 2 else (parts[0], "")
    if k.strip().lower() in cfg:
        cfg[k.strip().lower()] = v.strip().lower()
for k, v in cfg.items():
    print(f"{k} {v}")
sys.exit(0)
FAKE
chmod +x "$FAKESSH/ssh"
export PATH="$FAKESSH:$PATH"   # ahead of any real ssh, so the gate's own subprocess call hits this

payload() {  # payload <command> -> the hook's stdin JSON
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

run() {  # run <command> [<PATH>] -> exit code; stderr captured in $TMP/err
  local cmd="$1" path="${2:-$PATH}"
  printf '%s' "$(payload "$cmd")" | PATH="$path" bash "$GATE" >/dev/null 2>"$TMP/err"
}

check_blocked() {  # check_blocked <command> <label>
  run "$1"; local rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/err" \
    && pass "$2: blocked" || fail "$2: NOT blocked (rc=$rc) — $(cat "$TMP/err")"
}
check_allowed() {  # check_allowed <command> <label>
  run "$1"; local rc=$?
  [[ "$rc" == "0" ]] && pass "$2: allowed" || fail "$2: blocked (should be allowed) — $(cat "$TMP/err")"
}

echo "── ssh-mux-gate: refuse turning multiplexing ON (command-line forms)"

echo " · opening a master"
check_blocked 'ssh -M host' "ssh -M"
check_blocked 'ssh -o ControlMaster=yes host' "ControlMaster=yes"
check_blocked 'ssh -o ControlMaster=auto host' "ControlMaster=auto"
check_blocked 'ssh -o ControlMaster=ask host' "ControlMaster=ask"
check_blocked 'ssh -o ControlMaster=autoask host' "ControlMaster=autoask"
check_blocked 'ssh -o ControlMaster=true host' "ControlMaster=true (cisa c189241: ssh treats true as yes)"
check_blocked 'ssh -oControlMaster=auto host' "ControlMaster=auto, no space before -o's value"
check_blocked 'ssh -o "ControlMaster yes" host' "ControlMaster yes (space form, quoted)"

echo " · bundled and attached short flags (cisa c189241 item 2 — standalone-only was the bug)"
check_blocked 'ssh -fNM host' "-fNM bundled: -f -N -M"
check_blocked 'ssh -fNMS /tmp/sock host' "-fNMS <path>: -f -N -M -S=<path>"
check_blocked 'ssh -S/tmp/sock host' "-S<path> attached, no space"
check_blocked 'ssh -nS /tmp/sock host' "-nS <path> bundled: -n -S=<path>"
check_blocked 'ssh -MS /tmp/s host' "coa c189310's own exact form: -MS <path> bundled: -M -S=<path>"

echo " · the scope itself: -M/-S are an SSH OPTION, never a bare substring of the whole command line"
echo "   (coa SEND-BACK on PR #438, c189310 blocking 1 — each of these passes on main; re-probed here"
echo "   against this exact head first, and all six already passed before this round's own fix, since"
echo "   the getopt-aware parser this file's prior round added already scopes -M/-S to ssh's own argv)"
check_allowed 'git commit -S -m "signed"' "coa c189310: git commit -S (a signed commit, not ssh's -S)"
check_allowed 'git branch -M main' "coa c189310: git branch -M (force-rename, not ssh's -M)"
check_allowed 'git log -S needle' "coa c189310: git log -S (pickaxe search, not ssh's -S)"
check_allowed 'git diff -M HEAD~1' "coa c189310: git diff -M (rename detection, not ssh's -M)"
check_allowed 'ls -S /tmp' "coa c189310: ls -S (sort by size, not ssh's -S)"
check_allowed 'sort -S 50% f' "coa c189310: sort -S (buffer size, not ssh's -S)"

echo " · keeping one open"
check_blocked 'ssh -o ControlPath=/tmp/%r@%h:%p host' "ControlPath=<socket path>"
check_blocked 'ssh -o ControlPersist=600 host' "ControlPersist=600 (a kept-open duration)"
check_blocked 'ssh -o ControlPersist=yes host' "ControlPersist=yes"
check_allowed 'ssh -o ControlPersist=false host' "ControlPersist=false (cisa c189241: the false positive — false IS off)"

echo " · reusing an existing master, -O exit SCOPED to its own ssh call only"
check_blocked 'ssh -S /tmp/sock host' "ssh -S <path>, no -O exit"
check_blocked 'ssh -S /tmp/sock -O forward host' "ssh -S <path> -O forward (not the close-only exit)"
check_blocked 'ssh -O exit host1; ssh -S /tmp/sock host2' \
  "cisa c189241: -O exit on ONE ssh call must not exempt a DIFFERENT ssh call later in the command"
check_blocked "ssh -S /tmp/sock host 'echo -O exit'" \
  "cisa c189241: -O exit INSIDE the quoted remote command is not this ssh call's own flag"

echo " · through git's own SSH wrapper, including a bundled/quoted form"
check_blocked 'GIT_SSH_COMMAND="ssh -o ControlMaster=auto" git push' "GIT_SSH_COMMAND"
check_blocked "git -c core.sshCommand='ssh -o ControlMaster=auto' push" "git -c core.sshCommand="
check_blocked "GIT_SSH_COMMAND='ssh -M' git push" "cisa c189241: GIT_SSH_COMMAND='ssh -M' (-M after a quote)"
check_blocked "GIT_SSH_COMMAND='ssh -o ControlMaster=true' git push" \
  "ControlMaster=true via GIT_SSH_COMMAND (no target here at all — isolates the DIRECT -o check from ssh -G, which a target-bearing call would also reach)"
check_blocked "git -c core.sshCommand='ssh -MS/tmp/sock' push" "cisa c189241: core.sshCommand='ssh -MS/path' (bundled)"

echo "── ssh-mux-gate: an INHERITED config already multiplexing is refused even with NO flag on the"
echo "   command line at all (cisa c189241 item 1 — ssh -G evaluates command + file + global config)"
printf 'Host *\n  ControlMaster auto\n' > "$TMP/sshcfg-mux.conf"
check_blocked "ssh -F $TMP/sshcfg-mux.conf host" \
  "cisa's own done-when: a -F fixture, Host * + ControlMaster auto, no -M/-o on the command line at all"
printf 'Host *\n  ControlMaster no\n  ControlPath none\n  ControlPersist no\n' > "$TMP/sshcfg-clean.conf"
check_allowed "ssh -F $TMP/sshcfg-clean.conf host" "control: a -F file that is itself clean stays allowed"

echo "── ssh-mux-gate: the safe direction stays allowed"
check_allowed 'ssh host ls' "a plain ssh invocation, no flags at all, clean effective config"
check_allowed 'git push origin main' "a plain git push (no explicit ssh invocation to evaluate — see NOT CLOSED below)"
check_allowed 'ssh -o ControlMaster=no host' "ControlMaster=no"
check_allowed 'ssh -o ControlPath=none host' "ControlPath=none"
check_allowed 'ssh -o ControlPersist=no host' "ControlPersist=no"
check_allowed 'ssh -O exit -S /tmp/sock host' "ssh -O exit (closing a master, same call as the -S)"
check_allowed 'ssh -o StrictHostKeyChecking=no host' "an unrelated -o option is never mistaken for one of these"
check_allowed 'ssh -S none host' \
  "coa c189310 non-blocking: -S none explicitly turns reuse OFF, the command-line mirror of ControlPath=none"
check_allowed 'ssh -S NONE host' "control: -S none matched case-insensitively, the same as every -o value here"

echo "── control: without python3, EVERY ssh invocation this gate recognises fails CLOSED now — not"
echo "   only a mux-shaped one — because item 1 means even a PLAIN call needs ssh -G to verify, and"
echo "   that needs python3. (This still needs jq to parse the hook's OWN input once python3 is gone.)"
NOPY="$(shim_path nopy python3)"
if PATH="$FAKESSH:$NOPY" command -v jq >/dev/null 2>&1; then
  run 'ssh -M host' "$FAKESSH:$NOPY"; rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/err" && pass "no python3: a mux-shaped command fails closed" \
    || fail "no python3: a mux-shaped command was not blocked (rc=$rc) — $(cat "$TMP/err")"
  run 'ssh host ls' "$FAKESSH:$NOPY"; rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/err" \
    && pass "no python3: a PLAIN ssh invocation ALSO fails closed (cannot verify the effective config)" \
    || fail "no python3: a plain ssh invocation was not blocked (rc=$rc) — $(cat "$TMP/err")"
  run 'ls -la' "$FAKESSH:$NOPY"; rc=$?
  [[ "$rc" == "0" ]] && pass "no python3: a command that is not an ssh invocation at all is still allowed" \
    || fail "no python3: an unrelated command was wrongly blocked (rc=$rc) — $(cat "$TMP/err")"
else
  echo "  ⚠️  SKIPPED — this host has no jq, so removing python3 leaves the hook with no parser at all"
  echo "     (its own pre-existing no-parser gate fires first; this suite tests OUR check, not that one)"
fi

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1; fi
