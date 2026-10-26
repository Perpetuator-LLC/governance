# hooks/credential-paths.sh — credential PATHS shared by the read (bash-safety-gate.sh) and write
# (write-safety-gate.sh) gates (governance#335). A name-based rule (.env*) catches a secret by its
# CONTENT category; this list catches well-known files whose location says "credential" even when
# the name alone does not (`credentials`, `config`, `hosts.yml`). Read and write refuse the same set,
# so it is named once here; tests/credential-path-gates-agree.test.sh is the KAT that keeps them in
# sync. Sourced, not executed — it only ever sets CRED_PATH.
#
# Each branch is anchored at a path separator or `~` on the left, and a non-path character or the end
# on the right, the same right-boundary technique SECRET_NAME in bash-safety-gate.sh uses: it still
# matches `~/.aws/credentials` and `/home/x/.aws/credentials`, and stops at a longer name that merely
# starts with one of these (`.aws/credentials.bak` is not `.aws/credentials`).
CRED_PATH='(^|[/~])\.aws/(credentials|config)([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.netrc([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.ssh/(id_[A-Za-z0-9_-]+|[A-Za-z0-9_-]+_key)([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.docker/config\.json([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.kube/config([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.config/gh/hosts\.yml([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.git-credentials([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.pgpass([^A-Za-z0-9._/-]|$)'
