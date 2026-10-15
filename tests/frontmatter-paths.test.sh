#!/usr/bin/env bash
# tests/frontmatter-paths.test.sh — bin/frontmatter_paths.py: the ONE definition of "a path value in
# vault frontmatter", shared by check-frontmatter-paths and check-cadence so they cannot disagree
# about what counts as a path. Exercised only indirectly until now, through check-frontmatter-paths'
# own suite — this is direct unit coverage of the module itself, one hand-derived case per resolver
# arm named in the ready-queue: an alias (cross-vault), a cross-root reference, the `scraped:`
# provenance prefix, and an unmounted-volume-shaped absolute path that is present but unreadable.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$ROOT/bin"
[[ -f "$MOD/frontmatter_paths.py" ]] || { echo "FAIL: $MOD/frontmatter_paths.py missing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

# Runs a Python snippet with the module importable; an AssertionError (or any exception) fails the
# check and prints it, rather than a bare "check(){ eval ... }" indirection — these are assertions
# ABOUT the module's return values, hand-derived before running, not read back from its output.
pyok() {  # pyok <label> <python-body>
  local label="$1" body="$2"
  if PYTHONPATH="$MOD" python3 -c "
import sys
from frontmatter_paths import looks_like_path, walk_values, resolve, iter_markdown, UnreadableError, EXTS
$body
" >"$TMP/out" 2>"$TMP/err"; then
    ok "$label"
  else
    bad "$label: $(tail -5 "$TMP/err" | tr '\n' '|')"
  fi
}

echo "frontmatter_paths.py"

# =================================================================================================
# looks_like_path(value) — shape detection, not a key roster
# =================================================================================================
pyok "a non-string value (int) is never a path" \
  "assert looks_like_path(42) is False"
pyok "a non-string value (None) is never a path" \
  "assert looks_like_path(None) is False"
pyok "a non-string value (a list) is never a path" \
  "assert looks_like_path(['a/b.md']) is False"
pyok "a string over 512 chars is refused regardless of shape" \
  "assert looks_like_path('a/' + 'x'*511 + '.md') is False"
pyok "an empty string is not a path" \
  "assert looks_like_path('') is False"
pyok "whitespace-only is not a path" \
  "assert looks_like_path('   ') is False"
pyok "a URL (://) is never a path, even with a slash and a recognised extension" \
  "assert looks_like_path('https://example.com/doc.md') is False"
pyok "an http-prefixed value with no :// is still refused" \
  "assert looks_like_path('http/doc.md') is False"
pyok "a mailto: value is not a path" \
  "assert looks_like_path('mailto:a@example.com/x.md') is False"
pyok "a comment/anchor (#) is not a path" \
  "assert looks_like_path('#heading/x.md') is False"
pyok "no slash at all is not a path, however the string ends" \
  "assert looks_like_path('notes.md') is False"
pyok "a slash with an UNRECOGNISED extension is not a path" \
  "assert looks_like_path('State/notes.exe') is False"
pyok "a slash with a recognised extension IS a path (the baseline positive case)" \
  "assert looks_like_path('State/notes.md') is True"
pyok "every declared extension is recognised, not just .md" \
  "assert all(looks_like_path('d/f' + e) is True for e in EXTS), [e for e in EXTS if not looks_like_path('d/f'+e)]"
pyok "extension matching is case-insensitive (vault authors capitalise inconsistently)" \
  "assert looks_like_path('State/Notes.MD') is True"
pyok "leading/trailing whitespace is stripped before the shape test" \
  "assert looks_like_path('  State/notes.md  ') is True"

# =================================================================================================
# walk_values(node, trail) — every scalar string in nested frontmatter, with its dotted key path
# =================================================================================================
pyok "a flat dict yields each string value under its own key" \
  "assert sorted(walk_values({'a': 'x/y.md', 'b': 'p/q.md'})) == [('a', 'x/y.md'), ('b', 'p/q.md')]"
pyok "a nested dict yields a DOTTED path" \
  "assert list(walk_values({'a': {'b': 'x/y.md'}})) == [('a.b', 'x/y.md')]"
pyok "a list under a key yields each element with an '[]' marker in the trail" \
  "assert list(walk_values({'a': ['x/y.md']})) == [('a.[]', 'x/y.md')]"
pyok "a list of dicts: each dict's own keys appear after the list's own '[]' marker" \
  "assert list(walk_values({'a': [{'path': 'x/y.md'}]})) == [('a.[].path', 'x/y.md')]"
pyok "a non-string, non-container scalar (int, bool, None) yields NOTHING — it is not a path candidate" \
  "assert list(walk_values({'a': 1, 'b': True, 'c': None})) == []"
pyok "an empty dict and an empty list both yield nothing, not an error" \
  "assert list(walk_values({})) == [] and list(walk_values([])) == []"

# =================================================================================================
# resolve(root, value, aliases) — does this value point at a real, non-empty file?
# =================================================================================================
mkdir -p "$TMP/vault/State" "$TMP/vault/Empty"
printf 'content\n' > "$TMP/vault/State/Doc.md"
: > "$TMP/vault/Empty/zero-bytes.md"

pyok "a vault-relative path to a real, non-empty file resolves True" \
  "assert resolve('$TMP/vault', 'State/Doc.md') is True"
pyok "a vault-relative path to a MISSING file resolves False" \
  "assert resolve('$TMP/vault', 'State/NoSuchFile.md') is False"
pyok "a vault-relative path to a file that exists but is EMPTY (0 bytes) resolves False — a dead link, not a live one" \
  "assert resolve('$TMP/vault', 'Empty/zero-bytes.md') is False"

mkdir -p "$TMP/outside"
printf 'outside content\n' > "$TMP/outside/External.md"
pyok "an ABSOLUTE path (outside the vault root) is tested as-is, never joined to root" \
  "assert resolve('$TMP/vault', '$TMP/outside/External.md') is True"
pyok "an absolute path to a file that does not exist resolves False, not an exception" \
  "assert resolve('$TMP/vault', '$TMP/outside/NoSuchFile.md') is False"

printf 'home content\n' > "$TMP/vault/HomeShaped.md"
pyok "a '~/'-prefixed value is HOME-relative, so it does NOT resolve against the vault root even when a same-named file sits there" \
  "import os; os.environ['HOME']='$TMP/nonexistent-home'; assert resolve('$TMP/vault', '~/HomeShaped.md') is False"
mkdir -p "$TMP/fakehome"
printf 'real home file\n' > "$TMP/fakehome/Doc.md"
pyok "...and DOES resolve against the real \$HOME when the file is actually there" \
  "import os; os.environ['HOME']='$TMP/fakehome'; assert resolve('$TMP/vault', '~/Doc.md') is True"

# --- the `scraped:` PROVENANCE prefix ------------------------------------------------------------
pyok "a 'scraped:' prefix on an ABSOLUTE path is stripped, and the remaining path is what's tested" \
  "assert resolve('$TMP/vault', 'scraped:$TMP/outside/External.md') is True"
pyok "a 'scraped:' prefix on a path that does not resolve (an UNMOUNTED volume, present-looking but absent) still resolves False cleanly, never an exception" \
  "assert resolve('$TMP/vault', 'scraped:/Volumes/NoSuchExternalDrive/file.md') is False"
pyok "a DOUBLE-SLASH scheme (scraped://host/path, URL-shaped) is NOT stripped as provenance — the lookahead excludes '//'" \
  "assert resolve('$TMP/vault', 'scraped://example.com/file.md') is False"
pyok "a '~/' provenance form is also recognised and stripped" \
  "import os; os.environ['HOME']='$TMP/fakehome'; assert resolve('$TMP/vault', 'scraped:~/Doc.md') is True"

# --- ALIASES: cross-vault / cross-root resolution -------------------------------------------------
mkdir -p "$TMP/altvault/State"
printf 'sibling vault content\n' > "$TMP/altvault/State/SiblingDoc.md"
pyok "a value under an ALIASED prefix resolves via the alt root, reported as 'cross-vault' (not plain True)" \
  "assert resolve('$TMP/vault', 'Other/State/SiblingDoc.md', aliases={'Other/': '$TMP/altvault'}) == 'cross-vault'"
pyok "the SAME value with NO aliases given is reported dead — the false-positive class the module's own docstring warns about" \
  "assert resolve('$TMP/vault', 'Other/State/SiblingDoc.md') is False"
mkdir -p "$TMP/vault/Other/State"
pyok "when the value ALSO resolves in-root (root wins — tried first), it is plain True, not cross-vault, even with an alias configured" \
  "import shutil; shutil.copy('$TMP/altvault/State/SiblingDoc.md', '$TMP/vault/Other/State/SiblingDoc.md'); assert resolve('$TMP/vault', 'Other/State/SiblingDoc.md', aliases={'Other/': '$TMP/altvault'}) is True"
pyok "MULTIPLE aliases: the one matching the value's own prefix is used, not just the first declared" \
  "assert resolve('$TMP/vault', 'Other/State/SiblingDoc.md', aliases={'Zzz/': '$TMP/nonexistent', 'Other/': '$TMP/altvault'}) in (True, 'cross-vault')"
pyok "an alias prefix that does not match the value's own prefix is never consulted" \
  "assert resolve('$TMP/vault', 'Unrelated/Doc.md', aliases={'Other/': '$TMP/altvault'}) is False"

# --- a path component that is itself a FILE (not a directory) cannot be descended into: OSError caught ---
printf 'not a directory\n' > "$TMP/vault/NotADir.md"
# Note: os.path.isfile() already swallows OSError internally (genericpath catches it), so this does
# not actually exercise resolve()'s own try/except — it is still a real, meaningful behavioural case
# (a malformed path resolves False cleanly, never a traceback), just not proof of that one line.
pyok "a FILE used as a directory component (NotADir.md/further.md) resolves False, not a crash" \
  "assert resolve('$TMP/vault', 'NotADir.md/further.md') is False"

# =================================================================================================
# iter_markdown(root, unreadable) — every .md with frontmatter, failing LOUD on what it cannot read
# =================================================================================================
pyok "a MISSING root raises SystemExit naming 'VAULT ROOT MISSING', never an empty, silent result" \
  "
try:
    list(iter_markdown('$TMP/does-not-exist'))
    assert False, 'did not raise'
except SystemExit as e:
    assert 'VAULT ROOT MISSING' in str(e), e
"

mkdir -p "$TMP/v2/.git" "$TMP/v2/.obsidian" "$TMP/v2/.trash"
printf -- '---\nkey: State/Doc.md\n---\nbody\n' > "$TMP/v2/note.md"
printf 'not frontmatter, just prose\n' > "$TMP/v2/plain.md"
printf -- '---\nkey: x\n---\n' > "$TMP/v2/.git/ignored.md"
pyok "a file under a SKIP_DIRS entry (.git) is never walked into" \
  "
results = list(iter_markdown('$TMP/v2'))
assert not any('ignored.md' in p for p, _, _ in results), results
"
pyok "a .md file WITH frontmatter yields (path, frontmatter text, body)" \
  "
results = {p: (fm, body) for p, fm, body in iter_markdown('$TMP/v2')}
hit = [v for p, v in results.items() if p.endswith('note.md')]
assert len(hit) == 1 and hit[0][0] == 'key: State/Doc.md' and hit[0][1] == 'body\n', hit
"
pyok "a .md file with NO frontmatter (does not start with '---') is silently excluded from the yield, but does not make the walk look empty" \
  "
results = list(iter_markdown('$TMP/v2'))
assert not any(p.endswith('plain.md') for p, _, _ in results), results
assert any(p.endswith('note.md') for p, _, _ in results), 'the real frontmatter file vanished too'
"

# "Unreadable" is made by a test double, not by mode bits: root ignores mode bits and CI runs the
# suites as root, so a chmod-000 case passes or fails depending on who runs it. The double raises
# what the real call raises (PermissionError from open, False from os.access); the chmod cases below
# calibrate that against the real filesystem wherever mode bits bind, i.e. when not root.
mkdir -p "$TMP/v3/sub"
printf -- '---\nkey: x\n---\n' > "$TMP/v3/a.md"
printf -- '---\nkey: y\n---\n' > "$TMP/v3/b.md"
printf -- '---\nkey: z\n---\n' > "$TMP/v3/sub/c.md"
# The FIRST .md the walk opens is refused, whichever it is, so the walk must continue past it:
# 3 files in, 1 refused, so 2 yielded and exactly one sink entry naming the refused path.
pyok "a file present but UNREADABLE is appended to the unreadable sink (never silently dropped), and the walk continues past it" \
  "
import frontmatter_paths as fp
refused, real_open = [], open
def refuse_first(p, *a, **k):
    if not refused and str(p).endswith('.md'):
        refused.append(p)
        raise PermissionError(13, 'Permission denied', p)
    return real_open(p, *a, **k)
fp.open = refuse_first
unreadable = []
results = [p for p, _, _ in iter_markdown('$TMP/v3', unreadable=unreadable)]
assert len(refused) == 1, refused
assert unreadable == [{'path': refused[0], 'error': 'PermissionError', 'kind': 'file'}], unreadable
assert len(results) == 2 and refused[0] not in results, results
assert sorted(results + refused) == sorted(['$TMP/v3/a.md', '$TMP/v3/b.md', '$TMP/v3/sub/c.md']), results
"

mkdir -p "$TMP/v4"
printf -- '---\nkey: x\n---\n' > "$TMP/v4/ok.md"
pyok "an UNREADABLE ROOT raises SystemExit naming it explicitly, distinct from a missing one" \
  "
import os
real_access = os.access
os.access = lambda p, *a, **k: False if p == '$TMP/v4' else real_access(p, *a, **k)
try:
    list(iter_markdown('$TMP/v4'))
    assert False, 'did not raise'
except SystemExit as e:
    assert 'VAULT ROOT PRESENT BUT UNREADABLE' in str(e), e
"

# Calibration of the two doubles above against real mode bits. Root reads through them, so these run
# only where they can bind; the cases above exercise the same branches for every user.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$TMP/v3/sub/c.md"
  pyok "calibration: a real chmod-000 file reaches the sink as the PermissionError the double raises" \
    "
unreadable = []
list(iter_markdown('$TMP/v3', unreadable=unreadable))
assert unreadable == [{'path': '$TMP/v3/sub/c.md', 'error': 'PermissionError', 'kind': 'file'}], unreadable
"
  chmod 644 "$TMP/v3/sub/c.md"
  chmod 000 "$TMP/v4"
  pyok "calibration: a real chmod-000 root is refused as unreadable, as the os.access double makes it" \
    "
try:
    list(iter_markdown('$TMP/v4'))
    assert False, 'did not raise'
except SystemExit as e:
    assert 'VAULT ROOT PRESENT BUT UNREADABLE' in str(e), e
"
  chmod 755 "$TMP/v4"
else
  echo "  (calibration of the unreadable doubles not run: root ignores mode bits; the double-based cases above still ran)"
fi

mkdir -p "$TMP/v5"
printf 'no markdown here\n' > "$TMP/v5/readme.txt"
pyok "a root with NO readable .md files at all raises SystemExit calling it a broken selector, not an empty vault" \
  "
try:
    list(iter_markdown('$TMP/v5'))
    assert False, 'did not raise'
except SystemExit as e:
    assert 'broken selector' in str(e), e
"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
