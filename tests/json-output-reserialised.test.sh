#!/usr/bin/env bash
# A JSON output is rewritten by the application that reads it: toggling a setting re-serialises the
# file and the bytes move with no human involved. Byte comparison then reports EDITED BY HAND for an
# edit that never happened. These cases pin BOTH directions — re-serialisation is in sync, and a real
# content change is still caught.
# Resolve the repo from THIS FILE, never $PWD: a test that only passes from the repo root is
# green in CI (which cds there) and red for every agent running it from another directory,
# and the failure arrives as a FileNotFoundError that says nothing about the rule under test.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
bad(){ echo "  ❌ $1"; fail=$((fail+1)); }
T=$(mktemp -d)
probe() { # probe <live-json> <recorded-json> -> "True"/"False" from matches()
  printf '%s' "$1" > "$T/settings.json"
  GOV_BIN="$ROOT/bin/governance" python3 - "$T" "$2" <<'PY'
import sys, os, importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("gov", os.environ["GOV_BIN"])
spec = importlib.util.spec_from_loader("gov", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
home, recorded = sys.argv[1], sys.argv[2]
want = {"type": "file", "sha256": "deadbeef", "text": recorded}
cur = mod.inspect(home, "settings.json")
print(mod.matches(home, "settings.json", want, cur))
PY
  local rc=$?
  # A probe that cannot tell its own crash from a verdict certifies nothing. probe() runs inside
  # $( ), so it cannot abort the script and must not print the diagnostic on stdout either — that
  # would be captured as the verdict. Detail to stderr; return a sentinel no assertion accepts.
  if [ $rc -ne 0 ]; then
    echo "PROBE CRASHED (exit $rc): $GOV_BIN did not load — assertions below prove nothing" >&2
    echo "CRASHED"; return 0
  fi
}
r=$(probe '{"a":1,"b":2}' '{"b": 2, "a": 1}')
[ "$r" = "True" ] && ok "re-serialised JSON (key order + spacing) reads as in sync" \
                  || bad "re-serialised JSON reported as edited (got $r)"
r=$(probe '{"a":1,"b":3}' '{"a":1,"b":2}')
[ "$r" = "False" ] && ok "a real content change is still caught" \
                   || bad "content change NOT caught (got $r)"
r=$(probe 'not json at all' '{"a":1}')
[ "$r" = "False" ] && ok "unparseable live file is a finding, never a pass" \
                   || bad "unparseable file passed (got $r)"
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
