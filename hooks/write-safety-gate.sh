#!/bin/bash
# Hook: PreToolUse[Write] — Prevent writing to secrets and sensitive files
# Exit 2 = block the tool call with message shown to Claude
# Exit 0 = allow

# Claude Code delivers hook input as JSON on STDIN: {"tool_name": ..., "tool_input": {...}}. This hook
# originally read $CLAUDE_TOOL_INPUT, which the harness never sets, so every check below received an
# empty string and ALLOWED everything, silently, from the first commit. The env var is kept only as a
# fallback for a harness that still uses it.
input=""
[[ ! -t 0 ]] && input=$(cat)

# Every refusal goes through deny(): the one-line reason to the model, then ONE audit event from
# deny-event.py beside this script (OCSF api_activity, security_control). The event carries a hash of the
# refused text, never the text. The trail fails OPEN (no helper, no python3, an unwritable log) and never
# changes the verdict.
DENY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/deny-event.py"
deny() {  # deny <rule-id> <reason>: refuse, record, exit 2
  echo "BLOCKED: $2" >&2
  if [[ -f "$DENY_HELPER" ]] && python3 -c '' >/dev/null 2>&1; then
    printf '%s' "${path:-}" | python3 "$DENY_HELPER" --gate write-safety-gate --rule "$1" \
      --tool "${tool:-}" --reason "$2" >/dev/null 2>&1 || true
  fi
  exit 2
}
# Parse with jq when present, python3 otherwise: a CI runner or a fresh machine may lack jq, and a
# parser dependency that is silently absent is exactly how this hook read nothing for months.
tool_field() {  # tool_field <json> <.path> [<.path> ...]  -> first non-empty string
  local json="$1"; shift
  if command -v jq >/dev/null 2>&1; then
    local k v
    for k in "$@"; do
      # `strings`: a non-string value is unreadable, as in the python branch. Without it jq printed an
      # array as JSON text, so one payload got two verdicts depending on which parser the host had.
      v=$(printf '%s' "$json" | jq -r "($k | strings) // empty" 2>/dev/null)
      [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    done
  elif python3 -c '' >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1:]:
    v = d
    for p in k.strip(".").split("."):
        v = v.get(p) if isinstance(v, dict) else None
    if isinstance(v, str) and v:
        sys.stdout.write(v)
        break
' "$@"
  fi
}
is_json() {
  if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -e . >/dev/null 2>&1
  else printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; fi
}
if ! command -v jq >/dev/null 2>&1 && ! python3 -c '' >/dev/null 2>&1; then
  deny no-parser "this safety gate cannot evaluate the call (neither jq nor python3 is installed). Install one, or run the command yourself."
fi
if [[ -n "$input" ]] && ! is_json "$input"; then
  deny unparseable-input "this safety gate received tool input it cannot parse; refusing rather than allowing it unchecked."
fi
if [[ -z "$input" && -z "${CLAUDE_TOOL_INPUT:-}" ]]; then
  echo "safety gate: no tool input on stdin or in CLAUDE_TOOL_INPUT; nothing was checked" >&2
fi
path=$(tool_field "$input" .tool_input.file_path .tool_input.path .toolInput.file_path .toolInput.path)
[[ -z "$path" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && path=$(tool_field "$CLAUDE_TOOL_INPUT" .file_path .path)
tool=$(tool_field "$input" .tool_name .toolName)   # once, for deny()'s event

if [[ -z "$path" ]]; then
  # A write payload with no path this gate can read is a BLIND gate, not a pathless write: refuse.
  # `write` and `search_replace` are Grok's names for Write and Edit (captured 2026-09-25).
  if [[ -n "$input" ]]; then
    tool=$(tool_field "$input" .tool_name .toolName)
    case "$tool" in
      ""|Write|Edit|MultiEdit|write|search_replace)
        deny blind-payload "this safety gate cannot read the file path in this ${tool:-unnamed} tool payload; refusing rather than allowing it unchecked." ;;
    esac
  fi
  exit 0
fi

# A Windows path names the same file with `\` as with `/`, and every directory rule below is written
# with `/`: `C:\Users\me\.ssh\config` and `.kube\config` were writable while the slash forms were
# refused. Canonicalise once, before any match, and keep the path AS GIVEN too: on Linux and macOS a
# `\` is an ordinary name character, so `.env.example\.local` is one real non-template file there,
# while the `/` spelling reads it as a template directory. Every rule runs on both and refuses if either
# matches (the union only adds refusals). COST: a Windows path inside a template directory
# (`C:\proj\.env.example\notes.txt`) is refused; write it with `/`.
rawpath="$path"
path="${path//\\//}"

# Windows opens one file under many spellings, and every `$`-anchored or `dir/` rule below missed them
# (#300): a trailing dot or space on any component (`.env.`, `.kube.\config`), an NTFS stream suffix
# (`.env::$DATA`, `.npmrc:$DATA`, `.env:name`), a doubled separator (`.kube\/config`), and an 8.3 short
# name (`KUBE~1\config`). win_canon spells the path the way Windows resolves it, ONCE; every rule then
# runs on BOTH spellings and refuses if either matches. The original spelling stays a candidate because
# on Linux/macOS `notes:x.env` or `.env.` is a real, distinct name: the union only ever adds refusals.
# (`\\?\`, `\\.\`, UNC and `C:` drive-relative prefixes need no rewrite: no rule anchors the start.)
# Same function, line for line, as the #300 change, so the two cannot disagree.
win_canon() {  # win_canon <slash-separated path> -> the path Windows would open
  local p="$1" lead="" drive="" out="" c i n
  [[ "$p" == //* ]] && lead=/                    # keep a UNC / device prefix's double slash
  p="$lead$(printf '%s' "$p" | tr -s '/')"       # a separator run is one separator
  local IFS=/
  local -a parts
  read -r -a parts <<< "$p"
  n=${#parts[@]}
  for ((i = 0; i < n; i++)); do
    c=${parts[i]}
    drive=""
    if (( i == 0 )) && [[ "$c" == [A-Za-z]:* ]]; then drive=${c:0:2}; c=${c:2}; fi
    (( i == n - 1 )) && c=${c%%:*}               # the last component's stream suffix (`:x`, `::$DATA`)
    [[ "$c" == *[!.\ ]* ]] && c=${c%"${c##*[!.\ ]}"}   # trailing dots/spaces; `.` and `..` stay
    parts[i]="$drive$c"
  done
  out="${parts[*]}"
  # 8.3 short names (`PROGRA~1`) resolve only against the disk: expand the longest existing prefix.
  if [[ "$out" == *"~"* ]] && command -v cygpath >/dev/null 2>&1; then
    local head="$out" tail=""
    while [[ -n "$head" && "$head" == */* && ! -e "$head" ]]; do
      tail="/${head##*/}$tail"; head=${head%/*}
    done
    [[ -n "$head" && -e "$head" ]] && out="$(cygpath -l -m "$head" 2>/dev/null || printf '%s' "$head")$tail"
  fi
  printf '%s' "$out"
}
wpath=$(win_canon "$path")
# `hit()` checks the `/` spellings only. The path AS GIVEN was a third leg, and it could never decide:
# no rule below holds a literal `\`, so any match on the raw path is also a match on `$path`, which
# differs from it only by `\` -> `/`, and every rule character other than `\` matches the same way in
# both. The env rule below DOES keep the raw leg: there a `\` changes where a template name ends.
hit() { printf '%s\n%s\n' "$path" "$wpath" | grep -qiE "$1"; }   # a rule matches either spelling

# Every secret-path match below is CASE-INSENSITIVE (`grep -i`). Windows and default macOS (APFS)
# filesystems are case-insensitive, so `.ENV`, `.Env` or `ID_RSA` open the very same file as the
# lowercase name; a case-sensitive pattern let those spellings write it unrefused.

# Block writes to environment/secrets files, by the SAME name list the read gate uses
# (secret-names.sh, found as below): what bash-safety-gate.sh refuses to read, this refuses to
# write. A DENYLIST of suffixes (`.prod`, `.local`, …) is always one spelling behind: `.env.stage`,
# `.env.ci`, `.env.qa`, `.env.uat`, `.env.preview` and `.env.local.bak` were all measured writable
# (#301). So it is an ALLOWLIST: every `.env`, `.env.<anything>` or `.envrc<anything>` is blocked
# UNLESS it is a whole template name (`.env.example`, `.env.sample`, `.env.template`).
#
# WHERE the list is found: this script's REAL directory (symlinks followed), then beside the link, then
# the copy embedded below. The installer links hooks file by file, so looking only beside the link
# refused every write on a machine whose links predated secret-names.sh. Same loader as
# bash-safety-gate.sh; tests/secret-names-fallback.test.sh diffs this copy against the file.
# >>> embedded copy of secret-names.sh (code lines only; keep identical)
SECRET_NAME='\.[eE][nN][vV]([^A-Za-z]|[rR][cC]|$)'
SECRET_TEMPLATES='example|sample|template'
strip_secret_templates() {
  local s="$1" re="^(.*)\\.env\\.(${SECRET_TEMPLATES})(\$|[[:space:]\"'/;&|<>)].*)\$" nocase=0 mark=$'\001'
  shopt -q nocasematch && nocase=1
  shopt -s nocasematch
  while [[ "$s" =~ $re ]]; do s="${BASH_REMATCH[1]}${mark}${BASH_REMATCH[3]}"; done
  [ "$nocase" = 1 ] || shopt -u nocasematch
  printf '%s' "${s//$mark/}"
}
# <<< end of embedded copy
gate_real_dir() {  # the directory of this script's REAL file, symlinks followed (portable: no readlink -f)
  local src="${BASH_SOURCE[0]}" dir
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)" || return 0
    src="$(readlink "$src")" || return 0
    [[ "$src" == /* ]] || src="$dir/$src"
  done
  cd -P "$(dirname "$src")" 2>/dev/null && pwd
}
# A list file with no code in it (empty, whitespace or comments only: a truncated or blanked file)
# holds no list, so it counts as MISSING: the gate warns and keeps its built-in copy. Refusing on it
# locked every seat out of Bash and Write, the repair included.
SECRET_NAMES_FILE=""
for secret_names_candidate in "$(gate_real_dir)/secret-names.sh" "$(dirname "${BASH_SOURCE[0]}")/secret-names.sh"; do
  [[ -f "$secret_names_candidate" ]] || continue
  if ! grep -qvE '^[[:space:]]*(#|$)' "$secret_names_candidate" 2>/dev/null; then
    echo "safety gate: $secret_names_candidate is empty; ignored, using the built-in copy of the secret-name list in this gate. Restore it (git checkout -- hooks/secret-names.sh in the governance clone)." >&2
    continue
  fi
  SECRET_NAMES_FILE="$secret_names_candidate"
  # shellcheck source=secret-names.sh
  . "$secret_names_candidate" && break
done
# A file that DOES load but leaves a value empty would check against no list. Refuse, and say how out:
# every Bash and Write call is refused from here on, the agent's own repair included.
if [[ -z "${SECRET_NAME:-}" || -z "${SECRET_TEMPLATES:-}" ]]; then
  deny secret-names-missing "this safety gate's secret-name list is empty: ${SECRET_NAMES_FILE:-the copy built into this gate} leaves SECRET_NAME or SECRET_TEMPLATES unset, so every call is refused rather than checked against no list. Way out: a human, in a terminal (this agent's Bash and Write are refused), restores that file (git checkout -- hooks/secret-names.sh in the governance clone, then reconcile) or deletes it; the gate then uses its built-in copy."
fi
# A quote in a PATH is a name character, not a boundary, but the shared strip ends a template at one:
# `.env.example''.local` passed as a template plus `''.local`. The quote-removed spelling closes that,
# and gives the verdict the read gate gives `cat .env.example''.local` (bash reads `.env.example.local`).
unqpath="${rawpath//[\"\']/}"
if strip_secret_templates "$rawpath" | grep -qE "$SECRET_NAME" || strip_secret_templates "$path" | grep -qE "$SECRET_NAME" \
  || strip_secret_templates "$wpath" | grep -qE "$SECRET_NAME" || strip_secret_templates "$unqpath" | grep -qE "$SECRET_NAME"; then
  deny env-file-write "Cannot write to environment files. These may contain secrets. Edit manually."
fi

# Block writes to credential/key files. The second line is files whose ordinary use holds a login or
# token: `.netrc` (machine passwords), `.npmrc` (registry auth tokens), `.pgpass` (PostgreSQL
# passwords), the Docker and Kubernetes client configs (registry auths, cluster tokens), and the GnuPG
# home (private keys). `.git-credentials` is already caught by `credentials`.
if hit '(credentials|secrets|\.pem$|\.key$|\.p12$|\.pfx$|\.jks$|id_rsa|id_ed25519|\.ssh/|\.aws/|\.gcloud/)' \
  || hit '(\.netrc$|\.npmrc$|\.pgpass$|\.docker/config\.json$|\.kube/config$|\.gnupg/)'; then
  deny credential-file-write "Cannot write to credential or key files. Edit manually."
fi

# Block writes to CI/CD secrets
if hit '(\.github/.*secret|vault\.y[a]?ml|\.vault-pass)'; then
  deny ci-secret-write "Cannot write to CI/CD secrets files. Edit manually."
fi

exit 0
