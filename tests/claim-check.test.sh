#!/usr/bin/env bash
# claim-check.test.sh — a change that touches a declared surface is FLAGGED with the claim, an
# unrelated change is CLEAN, and anything the check could not look at is NOT EVALUATED, never clean.
#
# Fixture (main): web/index.html (5 lines), app/models.py (2 lines), app/config.py (2 lines),
# README.md, and a declaration with five surfaces. Expected results, derived by hand:
#   pixel      inserts `<script async src="https://tracker.example/p.js">` after line 2 of
#              web/index.html                       -> flagged: tracking-pixel web/index.html:3 (+)
#   readme     edits README.md only                  -> clean, empty comment file
#   cdn        inserts a script from the allowed CDN  -> clean (the surface's ignore pattern)
#   field      appends `    phone = Field()` as line 3 of app/models.py -> flagged: data-collection :3
#   retention  RETENTION_DAYS 30 -> 365 on line 1    -> flagged twice: retention :1 (-) and :1 (+)
#   sdk        adds requirements.txt                 -> flagged: processor-sdk, no line (any change)
#   binary     adds web/img/logo.png (binary)        -> not evaluated, 2 notes (tracking-pixel, assets)
#   no declaration / bad regex / bad base ref        -> not evaluated, with the reason
#   "block": true -> pixel exits 1, a bad ref exits 2, readme exits 0; flag-only always exits 0
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$ROOT/bin/claim-check"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/claimcheck.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
R="$TMP/repo"; mkdir -p "$R/web" "$R/app" "$R/.claims"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
g init -q; g checkout -q -b main
printf '<html>\n<head>\n<title>t</title>\n</head>\n</html>\n' > "$R/web/index.html"
printf 'class User:\n    email = Field()\n' > "$R/app/models.py"
printf 'RETENTION_DAYS = 30\nLOG_LEVEL = "info"\n' > "$R/app/config.py"
printf 'readme\n' > "$R/README.md"
cat > "$R/.claims/surfaces.json" <<'EOF'
{"version": 1, "footer": "A flag, not a block.",
 "surfaces": [
  {"id": "tracking-pixel", "claim": "We do not embed third-party trackers.", "register": "https://forge.example/r#tracking",
   "paths": ["web/**"], "added": ["<script[^>]+src=\"https?://", "fbq\\("], "ignore": ["https?://cdn\\.ourapp\\.example/"]},
  {"id": "data-collection", "claim": "We collect only email.", "register": "https://forge.example/r#collect",
   "paths": ["app/**/models.py", "app/models.py", "app/**/*.py"], "exclude": ["app/tests/**"], "added": ["=\\s*Field\\("]},
  {"id": "retention", "claim": "We keep data for 30 days.", "register": "https://forge.example/r#retention",
   "paths": ["app/config.py"], "added": ["RETENTION_DAYS"], "removed": ["RETENTION_DAYS"]},
  {"id": "processor-sdk", "claim": "Our processors are listed in the policy.", "register": "https://forge.example/r#processors",
   "paths": ["requirements.txt"]},
  {"id": "assets", "claim": "Images carry no tracking.", "register": "https://forge.example/r#assets",
   "paths": ["web/img/**"], "added": ["x"]}]}
EOF
g add -A; g commit -q -m base
br() { g checkout -q -b "$1" main; }
br pixel;  sed -i.bak '2a\
<script async src="https://tracker.example/p.js"></script>' "$R/web/index.html"; rm "$R/web/index.html.bak"; g commit -qam pixel
br readme; printf 'readme, edited\n' > "$R/README.md"; g commit -qam readme
br cdn;    sed -i.bak '2a\
<script src="https://cdn.ourapp.example/app.js"></script>' "$R/web/index.html"; rm "$R/web/index.html.bak"; g commit -qam cdn
br field;  printf '    phone = Field()\n' >> "$R/app/models.py"; g commit -qam field
br retention; sed -i.bak 's/RETENTION_DAYS = 30/RETENTION_DAYS = 365/' "$R/app/config.py"; rm "$R/app/config.py.bak"; g commit -qam retention
br testonly; mkdir -p "$R/app/tests"; printf 'fake = Field()\n' > "$R/app/tests/test_models.py"; g add app/tests; g commit -qm testonly
br sdk;    printf 'tracker-sdk==1.0\n' > "$R/requirements.txt"; g add requirements.txt; g commit -qm sdk
br binary; mkdir -p "$R/web/img"; printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > "$R/web/img/logo.png"; g add web/img/logo.png; g commit -qm binary
g checkout -q main

run() { (cd "$R" && "$CC" "$@" >"$TMP/out" 2>"$TMP/err"); echo $?; }
st()  { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$TMP/out"; }
q()   { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print($1)" "$TMP/out"; }

echo "claim-check"
rc=$(run --base main --head pixel --json --comment-out "$TMP/c.md")
[ "$rc" = 0 ] && [ "$(st)" = flagged ] && [ "$(q '[(f["surface"],f["file"],f["line"],f["side"]) for f in d["findings"]]')" = "[('tracking-pixel', 'web/index.html', 3, '+')]" ] \
  && ok "a PR that adds a tracking pixel is flagged at web/index.html:3, exit 0 (flag only)" || bad "pixel: rc $rc $(cat "$TMP/out")"
grep -q 'legal review: these claims may need updating' "$TMP/c.md" && grep -q 'We do not embed third-party trackers.' "$TMP/c.md" \
  && grep -q '(https://forge.example/r#tracking)' "$TMP/c.md" && grep -q 'web/index.html:3' "$TMP/c.md" \
  && ok "the comment names the claim, links its register row and the line" || bad "pixel comment: $(cat "$TMP/c.md")"
rc=$(run --base main --head readme --json --comment-out "$TMP/c.md")
[ "$rc" = 0 ] && [ "$(st)" = clean ] && [ ! -s "$TMP/c.md" ] && ok "a README-only PR is clean and leaves no comment" || bad "readme: rc $rc $(st)"
rc=$(run --base main --head cdn --json)
[ "$(st)" = clean ] && ok "a script from the allowed CDN is ignored, so clean" || bad "cdn: $(st)"
rc=$(run --base main --head field --json)
[ "$(q '[(f["surface"],f["line"]) for f in d["findings"]]')" = "[('data-collection', 3)]" ] \
  && ok "a new data field is flagged at app/models.py:3" || bad "field: $(cat "$TMP/out")"
rc=$(run --base main --head testonly --json)
[ "$(st)" = clean ] && ok "a matching line in an excluded path (app/tests/) is not flagged" || bad "exclude: $(cat "$TMP/out")"
rc=$(run --base main --head retention --json)
[ "$(q 'sorted((f["surface"],f["line"],f["side"]) for f in d["findings"])')" = "[('retention', 1, '+'), ('retention', 1, '-')]" ] \
  && ok "a retention change is flagged on both the removed and the added line 1" || bad "retention: $(cat "$TMP/out")"
rc=$(run --base main --head sdk --json)
[ "$(q '[(f["surface"],f["file"],f["line"]) for f in d["findings"]]')" = "[('processor-sdk', 'requirements.txt', None)]" ] \
  && ok "a surface with no line patterns flags any change to its paths" || bad "sdk: $(cat "$TMP/out")"
rc=$(run --base main --head binary --json --comment-out "$TMP/c.md")
[ "$rc" = 0 ] && [ "$(st)" = not-evaluated ] && [ "$(q 'len(d["not_evaluated"])')" = 2 ] && grep -q 'Not evaluated' "$TMP/c.md" \
  && ok "a binary file in a line-checked path is NOT EVALUATED (2 notes), never clean, and the comment says so" || bad "binary: rc $rc $(cat "$TMP/out")"
rc=$(run --base main --head pixel --declaration nope.json --json --comment-out "$TMP/c.md")
[ "$rc" = 0 ] && [ "$(st)" = not-evaluated ] && grep -q 'no declaration at nope.json' "$TMP/c.md" \
  && ok "no declaration: not evaluated, and the comment says why" || bad "no declaration: $(cat "$TMP/out")"
python3 - "$R/.claims/surfaces.json" "$TMP/badre.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); d["surfaces"][0]["added"]=["(unclosed"]; json.dump(d,open(sys.argv[2],"w"))
PY
rc=$(run --base main --head readme --declaration "$TMP/badre.json" --json)
[ "$(st)" = not-evaluated ] && grep -q 'invalid pattern' "$TMP/out" && ok "an invalid regex in the declaration: not evaluated" || bad "bad regex: $(cat "$TMP/out")"
rc=$(run --base no-such-ref --head pixel --json)
[ "$rc" = 0 ] && [ "$(st)" = not-evaluated ] && grep -q 'failed' "$TMP/out" && ok "a base ref git refuses: not evaluated, exit 0 when not blocking" || bad "bad ref: rc $rc $(cat "$TMP/out")"
python3 - "$R/.claims/surfaces.json" "$TMP/block.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); d["block"]=True; json.dump(d,open(sys.argv[2],"w"))
PY
[ "$(run --base main --head pixel --declaration "$TMP/block.json")" = 1 ] && [ "$(run --base no-such-ref --head pixel --declaration "$TMP/block.json")" = 2 ] \
  && [ "$(run --base main --head readme --declaration "$TMP/block.json")" = 0 ] \
  && ok "\"block\": true: flagged exits 1, not evaluated exits 2, clean exits 0" || bad "block mode"
[ "$(run)" = 64 ] && ok "no --base: exit 64" || bad "missing --base"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
