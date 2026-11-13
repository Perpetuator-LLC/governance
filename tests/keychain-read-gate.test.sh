#!/usr/bin/env bash
# keychain-read-gate.test.sh — bash-safety-gate's credential-store read rule, on the channel the harness
# uses (PreToolUse JSON on stdin; refused = exit 2 with a BLOCKED line on stderr, the line the model sees).
#
# The rule once needed the tool word directly before one of two subcommands, case-sensitively. A
# reference case list run against the INSTALLED hook showed five read forms passing: a whole-keychain
# dump, a list-form argv inside an interpreter wrapper, padding between tool and subcommand, a `keyring`
# library read, and the tool spelled in capitals. A separate reference implementation refused all five;
# its green test said nothing about the hook a session actually runs. So this suite is the ONE case
# list, and it is run through the hook itself.
#
# Every item name here is made up. Nothing is executed: the gate only inspects text.
#
# GAP rows name read forms the rule is known NOT to see. They assert today's "allowed" on purpose: a
# gap is a measured fact, and a later change to it, either way, should be visible in this suite.
#
# One rule, not two files: an organisation that keeps its own exhibit of this rule points
# GOVERNANCE_KEYCHAIN_EXHIBIT at a Python file defining BAD_CASES ({label: command}); every one of them
# must be refused by THIS hook, so the exhibit and the hook cannot drift apart unseen.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${GATE:-$ROOT/hooks/bash-safety-gate.sh}"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # never the real deny trail

python3 - "$TMP/cases.jsonl" "${GOVERNANCE_KEYCHAIN_EXHIBIT:-}" <<'PY'
import importlib.util, json, sys
TOOL, FIND, FINDI, DUMP = "security", "find-generic-password", "find-internet-password", "dump-keychain"
ITEM = "example-seat-item-"          # a made-up item-name prefix
REFUSE, ALLOW, CLOSED, GAP = "REFUSE", "ALLOW", "CLOSED", "GAP"
bash = lambda c: {"tool_name": "Bash", "tool_input": {"command": c}}
cases = [
    # ── must refuse: every read form
    (REFUSE, "direct lookup, item named", bash(f"{TOOL} {FIND} -s {ITEM}alpha-key -w")),
    (REFUSE, "internet-password lookup", bash(f"{TOOL} {FINDI} -s example.com -w")),
    (REFUSE, "whole-keychain dump, no item name", bash(f"{TOOL} {DUMP}")),
    (REFUSE, "python -c subprocess wrapper, list-form argv", bash(
        f"python3 -c \"import subprocess; subprocess.run(['{TOOL}','{FIND}','-s','{ITEM}beta-key','-w'])\"")),
    (REFUSE, "sh -c wrapper", bash(f'sh -c "{TOOL} {FIND} -s {ITEM}gamma-key -w"')),
    (REFUSE, "item suffix from a shell variable", bash(f'SEAT=alpha; {TOOL} {FIND} -s "{ITEM}$SEAT-key" -w')),
    (REFUSE, "item suffix from a loop", bash(
        f'for s in alpha beta; do {TOOL} {FIND} -s "{ITEM}$s-key" -w; done')),
    (REFUSE, "220 characters between tool word and subcommand", bash(
        f"{TOOL} " + "x" * 220 + f" {FIND} -s {ITEM}gamma-key -w")),
    (REFUSE, "keyring library read, no tool word at all", bash(
        f"python3 -c \"import keyring; print(keyring.get_password('seat','{ITEM}alpha-key'))\"")),
    (REFUSE, "keyring get_credential", bash(
        "python3 -c \"import keyring; print(keyring.get_credential('svc', None).password)\"")),
    (REFUSE, "keyring command-line read", bash(f"python3 -m keyring get svc {ITEM}alpha-key")),
    (REFUSE, "tool word in capitals, full path", bash(f"/usr/bin/{TOOL.upper()} {FIND} -s {ITEM}gamma-key -w")),
    (REFUSE, "subcommand in capitals", bash(f"{TOOL} {FIND.upper()} -s {ITEM}gamma-key")),
    (REFUSE, "metadata-only lookup (no value flag)", bash(f"{TOOL} {FIND} -s {ITEM}alpha-key")),
    (REFUSE, "account-only lookup, no item name", bash(f"{TOOL} {FIND} -a some-account -w")),
    (REFUSE, "item name split across two quoted fragments", bash(
        f'{TOOL} {FIND} -s "example-seat-""item-alpha-key" -w')),
    (REFUSE, "item name from a command substitution", bash(f'{TOOL} {FIND} -s "$(cat /tmp/made-up.txt)" -w')),
    (REFUSE, "tool word from a variable", bash(f'"$BINARY" {FIND} -s {ITEM}alpha-key -w')),
    (REFUSE, "a newline between tool word and subcommand", bash(f"{TOOL} \\\n  {FIND} -s {ITEM}alpha-key -w")),
    (REFUSE, "export subcommand (whole identity export)", bash(
        f"{TOOL} export -k login.keychain -t identities -f pkcs12 -o /tmp/made-up.p12")),
    (REFUSE, "export subcommand, tool in capitals, full path", bash(f"/usr/bin/{TOOL.upper()} EXPORT -k login.keychain")),
    (REFUSE, "export subcommand, list-form argv in a wrapper", bash(
        f"python3 -c \"import subprocess; subprocess.run(['{TOOL}','export','-k','login.keychain'])\"")),
    (REFUSE, "export subcommand after a line continuation", bash(f"{TOOL} \\\n  export -k login.keychain")),
    # ── must allow: nothing here reads a credential store
    (ALLOW, "a shell export", bash("export FOO=1")),
    (ALLOW, "a shell export after the tool word and a command separator", bash(f"which {TOOL} && export FOO=1")),
    (ALLOW, "a committed consumer that reads the item inside its own process", bash(
        "python3 scripts/consumer.py --seat alpha --dry-run 00000000-0000-0000")),
    (ALLOW, "an unrelated subcommand of the same tool", bash(f"{TOOL} list-keychains")),
    (ALLOW, "installing the keyring library", bash("pip install keyring")),
    (ALLOW, "a keyring WRITE names no read call", bash("python3 -m keyring set svc user")),
    (ALLOW, "a name that only contains a subcommand word", bash(f"ls my-{FIND}-notes")),
    (ALLOW, "an ordinary command", bash("ls -la")),
    (ALLOW, "a non-Bash tool is not this rule's", {"tool_name": "Read", "tool_input": {"file_path": "x"}}),
    # ── must fail closed: a payload the gate cannot read is refused, never allowed unchecked
    (CLOSED, "hook input is a JSON list", [1, 2, 3]),
    (CLOSED, "hook input is a bare JSON string", "just a string"),
    (CLOSED, "command is a list", {"tool_name": "Bash", "tool_input": {"command": [TOOL, DUMP]}}),
    (CLOSED, "command is missing", {"tool_name": "Bash", "tool_input": {}}),
    (CLOSED, "command is a number", {"tool_name": "Bash", "tool_input": {"command": 12345}}),
    # ── known gaps, informational: read forms the rule does NOT see today (it is best effort). Each row
    #    asserts today's "allowed", so a change that starts refusing one fails here and the row moves up.
    (GAP, "subcommand split by quotes", bash(f'{TOOL} find-"generic-password" -s {ITEM}alpha-key -w')),
    (GAP, "subcommand assembled from a variable", bash(f'S=find-generic; {TOOL} "$S-password" -s {ITEM}alpha-key -w')),
    (GAP, "export subcommand assembled from a variable", bash(f'X=export; {TOOL} "$X" -k login.keychain')),
    (GAP, "keyring read reached through getattr", bash(
        "python3 -c \"import keyring; print(getattr(keyring, 'get_' + 'password')('svc', 'user'))\"")),
    (GAP, "Linux secret-tool lookup", bash("secret-tool lookup service svc user alpha")),
]
if sys.argv[2]:
    spec = importlib.util.spec_from_file_location("exhibit", sys.argv[2])
    ex = importlib.util.module_from_spec(spec); spec.loader.exec_module(ex)
    for label, command in ex.BAD_CASES.items():
        cases.append((REFUSE, f"exhibit: {label}", bash(command)))
with open(sys.argv[1], "w") as f:
    for want, label, payload in cases:
        f.write(json.dumps({"want": want, "label": label, "payload": json.dumps(payload)}) + "\n")
PY
[[ -s "$TMP/cases.jsonl" ]] || { echo "FAIL: no cases built"; exit 1; }

pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }

echo "── bash-safety-gate: credential-store reads, through the hook's own input channel"
n=0
while IFS= read -r row; do
  n=$((n+1))
  want=$(field "$row" want); label=$(field "$row" label)
  field "$row" payload | bash "$GATE" >"$TMP/out" 2>"$TMP/err"; rc=$?
  case "$want" in
    REFUSE)
      if [[ $rc -eq 2 ]] && grep -q '^BLOCKED: Keychain access' "$TMP/err"; then ok "refused: $label"
      else bad "NOT refused as a credential-store read (rc=$rc, $(head -c 120 "$TMP/err")): $label"; fi ;;
    CLOSED)
      if [[ $rc -eq 2 ]] && grep -q '^BLOCKED: .*cannot read the command' "$TMP/err"; then ok "fails closed: $label"
      else bad "did not fail closed (rc=$rc, $(head -c 120 "$TMP/err")): $label"; fi ;;
    ALLOW)
      if [[ $rc -eq 0 ]] && [[ ! -s "$TMP/err" ]]; then ok "allowed: $label"
      else bad "refused, should be allowed (rc=$rc, $(head -c 120 "$TMP/err")): $label"; fi ;;
    GAP)
      if [[ $rc -eq 0 ]] && [[ ! -s "$TMP/err" ]]; then ok "known gap, still allowed: $label"
      else bad "known gap is now refused (rc=$rc): move this row to REFUSE: $label"; fi ;;
  esac
done < "$TMP/cases.jsonl"

# The deny trail records the rule id and never the refused text.
if [[ -s "$GOVERNANCE_DENY_LOG" ]]; then
  grep -q 'keychain-read' "$GOVERNANCE_DENY_LOG" && grep -q 'keyring-read' "$GOVERNANCE_DENY_LOG" && ok "deny trail names both rules" || bad "deny trail lacks the rule id"
  grep -q 'example-seat-item' "$GOVERNANCE_DENY_LOG" && bad "deny trail carries the refused text" || ok "deny trail carries no refused text"
fi

echo; echo "keychain-read-gate: $pass passed, $fail failed ($n cases)"
[[ $fail -eq 0 ]]
