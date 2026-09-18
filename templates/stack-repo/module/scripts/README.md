# scripts

Operator scripts: what a person runs by hand, on a named host. Every one starts with the same header,
so a reader knows before running it where it runs, what it will ask for, and where its evidence goes:

    #!/usr/bin/env bash
    # <name>.sh — <one line: what it does>
    #
    # host:    <the host role it runs on, or "any"> — it refuses to run anywhere else
    # prompts: <every value it asks for, or "none"> — a secret is read with a silent prompt, never argv
    # logged:  <the file it writes its evidence to> — the operator never pastes scrollback
    set -euo pipefail
    MODULE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # module/, from its own location

Every script is also:

- **idempotent** — a re-run from any partial state converges, and never mints a second key, password
  or token;
- **location-independent** — it derives its root from its own path, never from a hard-coded
  checkout path (the repository's `tests/no-checkout-paths.test.sh` fails the build on one);
- **generic** — anything that names the organisation comes in as a parameter bound by the overlay
  (the repository's `tests/module-lint.test.sh` fails the build on a literal);
- **committed before anyone runs it** — what ran is exactly what is in git.
