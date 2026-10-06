#!/usr/bin/env bash
# prose-command-check.test.sh — a flag named in an instruction file must exist in the tool it calls
# (#48). Exhibit: a tool dropped `--fleet`, its own tests were updated, and two routines still
# called `--fleet` in their instruction text. The fixture builds that state; every expected finding,
# with its line number, is derived from the fixture below, not read back from the tool.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PCC="$ROOT/bin/prose-command-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

mkdir -p "$TMP/bin" "$TMP/docs" "$TMP/clean" "$TMP/empty"
cat > "$TMP/bin/mytool" <<'EOF'
#!/usr/bin/env python3
import argparse
ap = argparse.ArgumentParser()
ap.add_argument("--repos-from")
ap.add_argument("--json", action="store_true")
EOF
cat > "$TMP/bin/shtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in --fleet) echo fleet ;; esac
EOF
# docs/routine.md, line by line (the numbers the assertions use):
#  1 # Routine          5 bin/mytool --fleet            <- STALE (fenced, line 5)
#  2 (blank)            6 /bin/bash -c "echo hi"        <- system path, skipped
#  3 ```bash            7 bin/othertool --anything      <- not in --bin: unresolved, not a finding
#  4 ~/x/bin/mytool --repos-from - --json   (ok)        8 bin/shtool --fleet --help  (ok: in source; --help always)
#  9 ```               10 (blank)                      11 Run `bin/mytool --gone` nightly.  <- STALE (inline, line 11)
# 12 ```python  13 # then bin/mytool --nope  14 ```  <- a line that WOULD match, in a block that is not shell
# 15 #!/usr/bin/env bash  (prose; a shebang is never a tool)
cat > "$TMP/docs/routine.md" <<'EOF'
# Routine

```bash
~/x/bin/mytool --repos-from - --json
bin/mytool --fleet
/bin/bash -c "echo hi"
bin/othertool --anything
bin/shtool --fleet --help
```

Run `bin/mytool --gone` nightly.
```python
# then bin/mytool --nope
```
`#!/usr/bin/env bash`
EOF
printf '# Clean\n\n```sh\nbin/mytool --json\n```\n' > "$TMP/clean/ok.md"

echo "prose-command-check (#48)"
out=$(python3 "$PCC" --bin "$TMP/bin" "$TMP/docs" 2>&1); rc=$?
stale=$(grep -c '^STALE_FLAG' <<<"$out")
[ "$rc" = 1 ] && [ "$stale" = 2 ] && ok "exit 1 with exactly the two stale flags" || bad "rc=$rc, $stale stale: $out"
grep -q "routine.md:5  bin/mytool --fleet" <<<"$out" && ok "the fenced --fleet, at line 5" || bad "fenced stale flag not at line 5: $out"
grep -q "routine.md:11  bin/mytool --gone" <<<"$out" && ok "the inline-code --gone, at line 11" || bad "inline stale flag not at line 11: $out"
! grep -q -- "--nope" <<<"$out" && ok "a python block is not read as shell" || bad "a python block was scanned"
grep -q "1 tool(s) not in --bin: othertool" <<<"$out" && ok "a tool from elsewhere is counted unresolved, not a finding (bash, env skipped)" \
  || bad "unresolved count wrong: $(tail -1 <<<"$out")"
out=$(python3 "$PCC" --bin "$TMP/bin" "$TMP/clean" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "1 call(s) of a bin/ tool, 0 stale" <<<"$out" \
  && ok "a clean file exits 0, and its summary shows the call WAS read (the control)" || bad "clean: rc=$rc $out"
python3 "$PCC" --bin "$TMP/bin" "$TMP/empty" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no Markdown under the paths exits 2, never a clean 0" || bad "empty dir: rc=$rc"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
