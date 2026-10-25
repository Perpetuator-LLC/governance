# secret-names.sh — the ONE definition of a secret-bearing env-file NAME. Sourced, never run, by both
# bash-safety-gate.sh (reading) and write-safety-gate.sh (writing), so the two cannot disagree.
#
# Two lists drifted both ways: `.envrc.local` was refused to read but allowed to write, a secret file
# left writable, while `.env.example.local` was allowed to read but refused to write.
# tests/secret-gates-agree.test.sh runs one table of names through both gates.
#
# SCOPE: this matches a NAME as written in the text of the tool call. It cannot see a file reached
# through an indirection: a variable (`f=.e; cat ${f}nv`), a glob (`cat .e*`, `cat .en[v]`), split
# quoting (`cat ./.e''nv`), or a symlink with another name. It is a floor for the common case, not a
# boundary against a determined reader. The COST runs the other way: any command that merely NAMES
# the file is refused too, including ones that read nothing (`echo .env >> .gitignore`,
# `git rm --cached .env`, `test -f .env`).

# `.env` followed by a non-letter, `rc`, or the end: matches `.env`, `.env.local`, `.env_x`,
# `.envrc`, `.envrc.local`; not `.environment`, `.envoy.yaml`. Bracket classes, not a case flag,
# because the read gate also runs this pattern in python's `re`. Windows and default macOS (APFS)
# filesystems are case-insensitive, so `.ENV` opens the same file as `.env`.
SECRET_NAME='\.[eE][nN][vV]([^A-Za-z]|[rR][cC]|$)'

# The only `.env.<suffix>` names that hold no secret. A template counts only as a WHOLE name: it ends
# the string or is followed by a path or shell separator, so `.env.example.local` and `.env.sample2`
# are real names. Matched case-insensitively.
SECRET_TEMPLATES='example|sample|template'

# strip_secret_templates <text> -> <text> with every whole template name removed, repeated until none
# is left. The read gate does the same in python, with the same pattern and the same repetition.
strip_secret_templates() {
  local s="$1" re="^(.*)\\.env\\.(${SECRET_TEMPLATES})(\$|[[:space:]\"'/;&|<>)].*)\$" nocase=0
  shopt -q nocasematch && nocase=1
  shopt -s nocasematch
  while [[ "$s" =~ $re ]]; do s="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"; done
  [ "$nocase" = 1 ] || shopt -u nocasematch
  printf '%s' "$s"
}
