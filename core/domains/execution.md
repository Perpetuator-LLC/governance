---
type: governance
domain: operations
status: draft
---

# Execution stop gate

This operational check implements the shared seed's per-step gating rule at the
point where an implementation turn would otherwise end prematurely.

Before ending an authorized implementation turn:

1. Identify the next unfinished step and classify it as runnable, dependent on
   external progress, or blocked by a specific permission, input, or capability.
2. Execute runnable steps now. Approval of a previously presented choice removes
   that gate; acknowledge briefly while continuing, not in a final-only promise.
3. A later gated step does not block independent preparation, tests, review, or
   packaging. Finish those before handing over. Do not retry a denied action or
   bypass a safety gate to satisfy this rule.
4. For external progress, use the host's supported wait or monitoring mechanism
   when authorized. State what is actually running; never imply a future action
   is armed merely because it appears under a “next” heading.
5. End only with verified completion, an explicit pause/cancellation, or an
   evidenced blocker with the smallest actionable handoff. Distinguish local
   tests, remote CI, merge, deployment, and end-to-end validation.

When challenged about inactivity during an unfinished implementation request,
give a brief factual explanation and resume authorized work in the same turn.
An apology-only response does not discharge the original request. A genuinely
explanation-only request or explicit pause does not authorize additional writes.

Recovery checks: approving a deployment choice leads to preparation immediately;
a future secret-entry gate leaves independent tests runnable; failed CI leads to
diagnosis rather than a claim of completion; a denied deployment produces a
precise handoff without a bypass. None of these checks expands task authority.
