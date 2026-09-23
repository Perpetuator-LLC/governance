# {{name}}

<!-- One paragraph: what this produces, who consumes it, what breaks without it. -->

## Feature index

Each row links to the file that explains that one thing. This index is the map; the linked file is
the manual — so a reader finds the manual without reading the map twice.

| Feature | Manual |
|---|---|
| Agent conventions | [`AGENTS.md`](AGENTS.md) |
| Decisions | [`docs/decisions/`](docs/decisions/) |

## Setup

```bash
pre-commit install    # secret scanning + hygiene, before anything reaches git history
```

## How to deploy

<!-- Or: "this repository publishes artifacts; deployment lives in <repo>". Say which, explicitly —
     a reader who cannot tell will guess, and half of them will guess wrong. -->
