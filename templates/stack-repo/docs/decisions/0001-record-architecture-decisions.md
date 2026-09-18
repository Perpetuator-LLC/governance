---
type: decision
id: ADR-0001
status: accepted
---
# 1. Record architecture decisions

## Context

Decisions outlive the change that made them. Without a record, the reason behind a choice is lost the
first time someone asks for it, and the choice is re-litigated or silently reversed.

## Decision

- Decisions this repository owns are recorded here, in `docs/decisions/`, one numbered file each.
- A record is never rewritten. A later decision **supersedes** it, and both say so.
- **One log per repository.** A decision that spans repositories stays in the log of whoever owns it
  (the platform, or the repository this one was extracted from) and is LINKED from here, never copied:
  two copies drift, and each then reads as the authoritative one.

## Consequences

Anyone can find why this repository is the way it is without asking its authors. A decision that
belongs to someone else is visible as a link, which is also the signal that changing it is not this
repository's call.
