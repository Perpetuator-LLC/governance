#!/usr/bin/env bash
# name-check.test.sh — the one naming rule, as data: each case states its expected verdict in words, and
# the expected value is derived from the spec by hand, never read back from the tool's output.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NC="$ROOT/bin/name-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

cat >"$TMP/spec.json" <<'JSON'
{"version": 1, "max_length": 30,
 "segments": {"lane": ["alpha", "beta-two"], "place": ["ctr", "m1"], "harness": ["claude", "codex"],
              "service": ["sched"], "probe": ["canary"]},
 "kinds": [{"kind": "agent", "shape": "{lane}-{place}-{harness}"},
           {"kind": "service", "shape": "svc-{service}-{place}"},
           {"kind": "probe", "shape": "probe-{probe}"}],
 "derived": {"secret-path": "secret/agents/{name}", "approle": "agent-{name}-key"},
 "retired": {"gamma": "alpha", "old": null}}
JSON

verdict() {  # verdict <form> <value> -> "ok <kind>" or "FAIL"
  printf '%s\t%s\n' "$1" "$2" | "$NC" --spec "$TMP/spec.json" --json >"$TMP/o" 2>"$TMP/e"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"][0]; print(("ok "+r["kind"]) if r["ok"] else "FAIL "+r["reason"])' "$TMP/o" 2>/dev/null || echo "ERR $(cat "$TMP/e")"
}
expect() {  # expect <form> <value> <want-prefix> <label>
  local got; got=$(verdict "$1" "$2")
  [[ "$got" == "$3"* ]] && ok "$4" || bad "$4 — want '$3…', got '$got'"
}

echo "── conforming names, one per kind (the shape, filled from the lists)"
expect name alpha-ctr-claude           "ok agent"   "agent: lane-place-harness"
expect name beta-two-m1-codex          "ok agent"   "agent: a hyphenated lane is one segment"
expect name svc-sched-m1               "ok service" "service: svc-service-place"
expect name probe-canary               "ok probe"   "probe: probe-name"

echo "── derived forms are the same name with the store's prefix and suffix"
expect secret-path secret/agents/alpha-ctr-claude "ok agent" "secret path of a conforming agent"
expect approle agent-alpha-m1-claude-key           "ok agent" "auth role of a conforming agent"
expect approle alpha-m1-claude                     "FAIL is not spelled as approle" "a bare name offered as an auth role"

echo "── every other name fails, each for its own reason"
expect name alpha-claude          "FAIL matches no shape"   "missing place segment"
expect name alpha-ctr-grok        "FAIL matches no shape"   "harness not on the list"
expect name delta-ctr-claude      "FAIL matches no shape"   "lane not on the list"
expect name gamma-ctr-claude      "FAIL uses the retired word 'gamma' (successor: alpha)" "retired lane names its successor"
expect name old                   "FAIL uses the retired word 'old' (successor: none)"    "retired with no successor"
expect name Alpha-ctr-claude      "FAIL must be lower-case" "capitals"
expect name alpha--ctr-claude     "FAIL must be lower-case" "double hyphen"
expect name beta-two-ctr-claude-x "FAIL matches no shape"   "trailing extra word"
expect name svc-sched-m1-xxxxxxxxxxxxxxxxxxxx "FAIL is 33 characters, over the limit of 30" "length limit"
expect secret-path secret/agents/gamma-m1-codex "FAIL uses the retired word" "a retired name inside a derived form"

echo "── ambiguity is a failure: two lanes that overlap make one name two identities"
python3 - "$TMP/spec.json" "$TMP/amb.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["segments"]["lane"] += ["alpha-ctr"]; s["segments"]["place"] += ["ctr-m1"]
json.dump(s, open(sys.argv[2], "w"))
PY
printf 'name\talpha-ctr-m1-claude\n' | "$NC" --spec "$TMP/amb.json" >"$TMP/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q "is ambiguous" "$TMP/o" && ok "a name with two parses is refused" || bad "ambiguity (rc=$rc): $(cat "$TMP/o")"

echo "── exit codes and never-clean-when-blind"
printf 'name\talpha-ctr-claude\nname\tsvc-sched-ctr\n' | "$NC" --spec "$TMP/spec.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "all conforming: exit 0" || bad "all conforming: exit $rc"
printf 'name\talpha-ctr-claude\nname\tgamma-ctr-claude\n' | "$NC" --spec "$TMP/spec.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "one failure: exit 1" || bad "one failure: exit $rc"
: | "$NC" --spec "$TMP/spec.json" >/dev/null 2>"$TMP/e"; rc=$?
[[ $rc -eq 2 ]] && grep -q "NOT CHECKED: no entries" "$TMP/e" && ok "empty input: exit 2, not clean" || bad "empty input: exit $rc"
printf 'name\talpha-ctr-claude\n' | "$NC" --spec "$TMP/missing.json" >/dev/null 2>"$TMP/e"; rc=$?
[[ $rc -eq 2 ]] && grep -q "NOT CHECKED: cannot read spec" "$TMP/e" && ok "missing spec: exit 2" || bad "missing spec: exit $rc"
printf 'keycloak\tagent-alpha-ctr-claude\n' | "$NC" --spec "$TMP/spec.json" >/dev/null 2>"$TMP/e"; rc=$?
[[ $rc -eq 2 ]] && grep -q "unknown form 'keycloak'" "$TMP/e" && ok "unknown form: exit 2, names the known ones" || bad "unknown form: exit $rc"
printf 'alpha-ctr-claude\n' | "$NC" --spec "$TMP/spec.json" >/dev/null 2>"$TMP/e"; rc=$?
[[ $rc -eq 2 ]] && ok "a line without a form: exit 2" || bad "line without form: exit $rc"

echo "── the spec is checked before any name is"
python3 - "$TMP/spec.json" "$TMP/bad1.json" "$TMP/bad2.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
a = json.loads(json.dumps(s)); a["retired"]["alpha"] = "beta-two"; json.dump(a, open(sys.argv[2], "w"))
b = json.loads(json.dumps(s)); b["segments"]["lane"].append("Bad_Name"); json.dump(b, open(sys.argv[3], "w"))
PY
printf 'name\tbeta-two-ctr-claude\n' | "$NC" --spec "$TMP/bad1.json" >/dev/null 2>"$TMP/e"; rc=$?
[[ $rc -eq 2 ]] && grep -q "both retired and a live lane" "$TMP/e" && ok "a word both retired and live: spec refused" || bad "retired+live: exit $rc"
printf 'name\tbeta-two-ctr-claude\n' | "$NC" --spec "$TMP/bad2.json" >/dev/null 2>"$TMP/e"; rc=$?
[[ $rc -eq 2 ]] && grep -q "Bad_Name" "$TMP/e" && ok "a segment value outside the charset: spec refused" || bad "bad charset in spec: exit $rc"

echo; echo "name-check: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
