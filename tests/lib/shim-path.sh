#!/usr/bin/env bash
# shim-path.sh — sourced by the suites that run a hook under a PATH missing one parser (jq, python3).
#
# shim_path <label> <excluded-tool>... prints a directory to use as the WHOLE PATH: one tiny exec
# wrapper per tool the hooks under test call, minus the excluded ones. The caller sets $TMP.
#
# ⚠️ WRAPPERS, NEVER LINKS, AND NEVER THE WHOLE PATH. The first version linked every entry of every
# PATH directory. Git for Windows without native symlinks makes `ln -s` COPY, so each run copied all of
# PATH (System32 included, ~450 MB) and filled the disk (governance#280). A wrapper is one line and the
# same on every OS; the tool list is closed, so a run writes a few dozen small files.
#
# A tool the hooks start to call must be added to SHIM_TOOLS, or the restricted legs run without it.
# A tool missing on this host is skipped, as it would be on the host's own PATH.
SHIM_TOOLS="bash sh env cat grep sed awk tr head tail cut sort uniq wc tee date mkdir rm mv cp chmod
  touch ls find xargs dirname basename readlink realpath mktemp uname shasum git jq python3 node npx ruby gofmt"

shim_path() {
  local dir="$TMP/path-$1"; shift
  mkdir -p "$dir"
  local t x skip target
  for t in $SHIM_TOOLS; do
    skip=0
    for x in "$@"; do [ "$t" = "$x" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    target="$(command -v "$t" 2>/dev/null)" || continue
    case "$target" in /*|[A-Za-z]:*) ;; *) continue ;; esac   # a builtin, alias or function: no file to wrap
    # A version-manager shim (pyenv, asdf) only works with its manager on PATH; wrap the real interpreter,
    # or the "no-jq" leg measures a broken python3, not a missing jq.
    if [ "$t" = python3 ]; then target="$(python3 -c 'import sys; print(sys.executable)')" || continue; fi
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$target" >"$dir/$t"
    chmod +x "$dir/$t"
  done
  printf '%s' "$dir"
}
