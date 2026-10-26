# secret-names.sh — the ONE definition of a secret-bearing env-file NAME. Sourced, never run, by both
# bash-safety-gate.sh (reading) and write-safety-gate.sh (writing), so the two cannot disagree.
#
# Two lists drifted both ways: `.envrc.local` was refused to read but allowed to write, a secret file
# left writable, while `.env.example.local` was allowed to read but refused to write.
# tests/secret-gates-agree.test.sh runs one table of names through both gates.
#
# Each gate also EMBEDS a copy of the code lines below, used when this file cannot be found (the
# installer links hooks one file at a time, so an older link set lacks it). Change both copies with
# this file; tests/secret-names-fallback.test.sh fails when they differ.
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
#
# LEFT boundary (governance#349): `.env` must start a path component — preceded by the start of the
# text or a non-word character (`/`, `~`, a quote, whitespace, `$`, another `.`, …) — never a letter,
# digit or underscore immediately before the dot. Without it `process.env` (an ordinary JS/Node
# property access, not a file) matched: `rg process.env src/` was refused in any JS/TS repo once #301
# dropped the reader-verb gate. No lookbehind (grep -E and python's re both compile this, and POSIX
# ERE has none): the boundary character is consumed by the alternation instead, which is harmless for
# a boolean `-q`/`re.search` match.
SECRET_NAME='(^|[^A-Za-z0-9_])\.[eE][nN][vV]([^A-Za-z]|[rR][cC]|$)'

# The only `.env.<suffix>` names that hold no secret. A template counts only as a WHOLE name: it ends
# the string or is followed by a path or shell separator, so `.env.example.local` and `.env.sample2`
# are real names. Matched case-insensitively.
SECRET_TEMPLATES='example|sample|template'

# strip_secret_templates <text> -> <text> with every whole template name removed, in ONE pass over the
# text as given. Each removed name first becomes a mark that is not a separator, so removing one name
# cannot make the text before it a whole name: `.env.sample.env.example` is a real file, not two
# templates (a repeat-until-none strip allowed it on both gates). The read gate does the same in
# python: one `re.sub` over the original text.
strip_secret_templates() {
  local s="$1" re="^(.*)\\.env\\.(${SECRET_TEMPLATES})(\$|[[:space:]\"'/;&|<>)].*)\$" nocase=0 mark=$'\001'
  shopt -q nocasematch && nocase=1
  shopt -s nocasematch
  while [[ "$s" =~ $re ]]; do s="${BASH_REMATCH[1]}${mark}${BASH_REMATCH[3]}"; done
  [ "$nocase" = 1 ] || shopt -u nocasematch
  printf '%s' "${s//$mark/}"
}
