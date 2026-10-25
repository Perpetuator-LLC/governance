#!/usr/bin/env bash
# shim-path.test.sh — shim_path (tests/lib/shim-path.sh) writes a few exec wrappers, never a copy of PATH.
#
# The helper once linked every entry of every PATH directory. Where `ln -s` copies (Git for Windows
# without native symlinks) each run copied all of PATH, ~450 MB, and filled the disk (governance#280).
# Known answer: after `shim_path kat jq`, the directory holds exactly the SHIM_TOOLS found on this host
# minus jq, as regular files (no links), under 1 MB in total, and a wrapper runs its tool.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
. "$ROOT/tests/lib/shim-path.sh"

echo "shim_path (exec wrappers, closed tool list)"
D="$(shim_path kat jq)"

# Expected set, derived from the tool list and this host, not from the helper's output.
want=""; for t in $SHIM_TOOLS; do [ "$t" = jq ] && continue; command -v "$t" >/dev/null 2>&1 && want="$want $t"; done
want="$(printf '%s\n' $want | sort)"
got="$(ls -A "$D" | sort)"
check "the shim dir holds exactly the requested tools found on this host" "[ \"\$got\" = \"\$want\" ]"
check "the excluded tool is absent" "[ ! -e '$D/jq' ] && ! PATH='$D' command -v jq >/dev/null"
check "nothing in it is a symlink (a link is what copies on Windows)" "[ -z \"\$(find '$D' -type l)\" ]"
kb="$(du -sk "$D" | cut -f1)"
check "the shim dir is under 1 MB on disk (${kb} KB)" "[ '$kb' -lt 1024 ]"
check "a wrapper runs its tool with its arguments" "[ \"\$(PATH='$D' bash -c 'echo \"\$1\"' _ 'a b')\" = 'a b' ]"

echo; echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
