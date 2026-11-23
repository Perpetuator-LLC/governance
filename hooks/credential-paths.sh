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
CREDENTIAL_PATH_RX='\.aws/credentials\b|\.aws/config\b|\.netrc\b|\.ssh/id_[a-z0-9_]*\b|\.ssh/[a-z0-9_]*_key\b|\.docker/config\.json\b|\.kube/config\b|\.config/gh/hosts\.yml\b|\.git-credentials\b|\.pgpass\b'
