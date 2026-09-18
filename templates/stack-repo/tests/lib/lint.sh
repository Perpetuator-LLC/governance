# shellcheck shell=bash disable=SC2034  # its variables are read by the scripts that source it
# lint.sh — shared by the repository's lint tests: the path rules, a git-grep scanner, a fixture writer.
# Sourced, never run.

# A path into one user's home directory, under the Users or home root.
HOME_RX='(^|[^A-Za-z0-9_.~-])/(Users|home)/[A-Za-z0-9_.-]+/'
# A line carrying this marker, with its reason, is exempt from the path rules (a path inside a container).
ALLOW='checkout-path: allow'

# checkout_rx NAME — an absolute path through a directory called NAME, including one rooted at $HOME or ~
checkout_rx() {
  # shellcheck disable=SC2016  # $HOME is matched as TEXT here, not expanded
  printf '%s' '(^|[^A-Za-z0-9_.~:/$}-]|\$HOME|\$[{]HOME[}]|~)/([A-Za-z0-9_.-]+/)*'"${1//./\\.}"'([^A-Za-z0-9_.-]|$)'
}

# repo_name TOP — the name the checkout rule keys on: CHECKOUT_NAME, else the checkout directory's name
repo_name() {
  local name="${CHECKOUT_NAME:-$(basename "$1")}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "cannot build a pattern from the repository name: $name" >&2; return 2; }
  printf '%s' "$name"
}

# grep_findings TOP LABEL REGEX ALLOW PATHSPEC… — print one line per match in a tracked file, prefixed
# with LABEL; lines holding ALLOW (when non-empty) are dropped.
# 0 none · 1 found · 2 git grep failed — a bad pattern is never read as "no match"
grep_findings() {
  local top="$1" label="$2" rx="$3" allow="$4" out rc
  shift 4
  out="$(git -C "$top" grep -nIE -e "$rx" -- "$@")"; rc=$?
  [ "$rc" -le 1 ] || { echo "git grep failed (exit $rc) on the $label pattern" >&2; return 2; }
  [ -z "$allow" ] || out="$(printf '%s\n' "$out" | grep -vF -e "$allow")"
  out="$(printf '%s\n' "$out" | grep -v '^$')"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sed "s|^|$label  |"
  return 1
}

# put REPO PATH LINE… — write the LINEs to REPO/PATH and track the file (test fixtures)
put() {
  local repo="$1" rel="$2"
  shift 2
  mkdir -p "$(dirname "$repo/$rel")"
  printf '%s\n' "$@" > "$repo/$rel"
  git -C "$repo" add -- "$rel"
}
