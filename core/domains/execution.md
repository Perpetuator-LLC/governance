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
   **When the progress is another agent's or person's work, watch their next
   artifact, not the end state.** Name the owner, the artifact you expect next
   (a branch, a commit, a run, a reply) and a deadline. Poll for a *new* artifact
   (a changed tip or id, never mere presence), and escalate in the same turn when
   the deadline passes. A watch on the end state reads the same for "slow" and
   "nobody is working", and a delivered message is not a picked-up task.
   *Scope:* waits on an actor who must act. A run already started by a system
   with its own completion signal is itself the artifact: wait on that run.
   *Mirror:* an owner that shows idle may be waiting on its own background job,
   so the artifact's timestamp decides whether the work has stalled, not the
   owner's status.
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
