# credential-paths.sh — sourced, not executed. The well-known credential-STORE path shapes refused by
# BOTH bash-safety-gate.sh (read) and write-safety-gate.sh (write), declared exactly once so the two
# can never drift (governance#335; the mirror, for PATHS, of the SECRET_NAME list #313 already shares
# between the gates for NAMES like .env).
#
# Each caller matches this, case-insensitively, against whatever text it already built: a full command
# for the read gate (a reader verb may sit anywhere before the path), a single resolved path for the
# write gate. `\b` word-bounds each fragment so ".ssh/id_ed25519" is caught without also catching an
# unrelated "id_ed25519_backup.tar" name that merely starts the same way at a word boundary elsewhere —
# a very small amount of over-matching here (a path merely containing one of these fragments, not
# exactly ending there) is the accepted direction for a credential-store path, the same way the read
# gate already accepts it for a keychain subcommand word.
#
# WRAPPED IN ONE GROUP (cisa SEND-BACK on PR #436, c189146 item 3): a bare, un-grouped `A|B|C` embedded
# inside a bigger pattern like `cat\s+.*A|B|C` binds the `cat\s+.*` prefix to A ONLY — | has the lowest
# precedence in a regex, so B and C silently become UNGATED top-level alternatives of the WHOLE
# expression, matched anywhere with no reader verb required at all. Measured: `ls ~/.aws/credentials`
# (the first alternative, the only one actually gated behind a verb) read the file clean, while
# `ssh -i ~/.ssh/id_ed25519 host` and `kubectl --kubeconfig ~/.kube/config get pods` — ordinary,
# non-reading uses that merely MENTION a later, un-grouped alternative — were refused. A plain `(...)`
# group is used, not `(?:...)`: POSIX ERE (what grep -E speaks) has no non-capturing-group syntax.
#
# `/+` not a bare `/` between segments (cisa c189146 item 4): a doubled separator (`~/.aws//credentials`)
# is the same file to the shell (it collapses repeated slashes) and must be the same match here. A `/./`
# segment, a glob (`?`, `*`), a brace expansion, or a path built via a variable (`F=<path>; cat $F`) are
# NOT closed by this pattern — those need the shell's own path and variable resolution to see through,
# which a regex over un-executed text cannot do; recorded here as an accepted limit of a best-effort
# gate, not a parser.
CREDENTIAL_PATH_RX='(\.aws/+credentials\b|\.aws/+config\b|\.netrc\b|\.ssh/+id_[a-z0-9_]*\b|\.ssh/+[a-z0-9_]*_key\b|\.docker/+config\.json\b|\.kube/+config\b|\.config/+gh/+hosts\.yml\b|\.git-credentials\b|\.pgpass\b)'
