# overlay — this organisation's layer (PRIVATE)

Everything specific to the organisation running the module lives here, and nowhere else: hosts and
inventory, deploy parameters, secret-store paths, and its own dashboards, probes and alerts. `module/`
is the CORE, this directory is its ADAPTER — the same shape as a governance render. The module
declares inputs; the overlay binds them to this organisation's values. The dependency points one way:
nothing under `module/` may name this directory, and the module lint fails the build if it does.

| path | what |
|---|---|
| `deploy/` | the deploy parameters as data (start from the example; replace every CHANGE-ME) and the inventory |
| `lint-denylist.txt` | this organisation's terms the module lint must never find under `module/` — its domains, private network names, secret-path prefixes. One extended regex per line; `#` starts a comment. Start from the example beside it. **Without it the module lint reports NOT CHECKED, never clean.** |
| `dashboards/` `probes/` `alerts/` | add as needed; each binds to the module's parameters, never the reverse |

**Publishing the module later** = publish `module/` (with the repository's README, tests and CI
gate, none of which names the organisation), and move this directory to a private repository.
