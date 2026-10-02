---
type: capability
id: CAP-<STACK>-<n>
title: "<what a user or an agent can DO because this exists, as a verb phrase>"
stack: <this repository, or the module/services/<name> that runs alone>
status: draft                     # draft | published; published by a human
owner: <the lane or team that owns it>
created: YYYY-MM-DD
objective: "<the strategy objective this capability serves, as a link>"
requirement_packages: []          # the requirement-package epics that build it, fully qualified
data_owned: []                    # the object types this stack is the source of truth for
---
# Capability: <title>

<!-- Copy this file to docs/capabilities/<capability-slug>.md, one file per capability, and delete
     this comment. Keep the headings: tools read them by name. Names and parameters only in Contracts:
     never a value, never a secret (values live in overlay/). -->

## Why it exists

<One paragraph: the pain it removes, or what a person can now do alone. If you cannot name a user,
stop here.>

## What it does

<!-- Features a stranger could verify: observable behaviour, not implementation. -->
- <feature>

## What it does NOT do

<!-- The nearest thing people will assume it does, and it doesn't. -->
- <non-feature>

## Contracts

The replaceable boundary: the diff base for any engine swap. It agrees with the README's *Contracts*
section; a change to either changes both in the same commit.

### Exposes

| interface | protocol / port / path | consumers |
|---|---|---|

### Consumes (core services, by parameter, never a literal)

| core service | parameter | why |
|---|---|---|

### Data

| object | source of truth here? | schema location |
|---|---|---|

## Keep-it-running gate

Filled in before any engine is replaced:
- **rollback:** the tagged previous release and the one command that restores it;
- **headline flow walked on stage:** who · the exact artifact pair · steps · what was observed;
- **presence probe:** the check that proves the old engine is gone, not merely unused.

## Requirement packages → requirements → work items

<!-- Links only. Status is rendered from the tracker, never typed here: a typed status is stale the
     day after it is written. -->

## Decisions

<!-- Links to the decision records (docs/decisions/). A decision that names a cadence links the
     routine that runs it. -->
