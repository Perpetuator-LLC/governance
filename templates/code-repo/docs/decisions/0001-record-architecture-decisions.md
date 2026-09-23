---
status: Accepted
date: <YYYY-MM-DD>
deciders: <who>
---

# ADR-0001 — Record architecture decisions

## Status

Accepted.

## Context

A decision that lives only in a chat log, a pull-request thread or somebody's memory gets
relitigated — usually by an agent, usually at the moment it is most expensive. The cost is not the
rediscussion; it is that the second answer can differ from the first and nothing flags the
contradiction.

## Decision

Record every architecture decision here as a numbered ADR: status, date, deciders, context,
decision, consequences, and the alternatives rejected **with the reason**. An alternative recorded
without its reason gets proposed again.

ADRs are append-only. A decision that is superseded gets a new ADR that names the one it supersedes;
the original text stays intact, because the record of what was believed at the time is the thing
that makes the reversal legible.

## Consequences

- `AGENTS.md` carries a *"Do not reopen"* list that points here, so a fresh agent meets the closed
  decisions before it spends tokens reopening one.
- A pull request that contradicts an ADR is either wrong or is itself a new ADR. Both are fine; a
  silent third option is not.
