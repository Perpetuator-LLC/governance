# Security

The non-negotiable security posture: secrets, credentials, access, and the controls that guard them.

Unlike most domains, **security holds its line even on client work** — a client's convenience
preference never overrides these (`core/AGENTS.md` → *Precedence of guidance*: your safety and
security always apply). Flag, don't bypass.

## Secrets in code (mandatory)

Never hardcode a credential in **any** repo file (incl. throwaway/test). Source from, in order:
1. **Process env** — bail with an error that says *where to fetch it* (the secret-store path).
2. **Secret store at runtime** — services fetch on startup; never persist to disk.
3. **Interactive prompt** — one-shot admin scripts use `read -rs`; **never** secrets on argv
   (`-e VAR=`, positional → leak to `ps`/history); pipe via stdin; `trap 'unset VAR' EXIT`.

**Standard secrets pattern (one bootstrap secret on disk):** the on-disk `.env` holds only the
bootstrap client secret for the identity provider; at every startup the service does
client-credentials → identity-provider token → secret-store login → fetch runtime secrets → export →
exec. No long-lived secrets on disk beyond one bootstrap secret; bouncing re-fetches fresh (rotation
without rebuild). Never commit `.env`; always `--exclude .env` in rsync.

**The remedy order is fixed, and it binds the blocks an agent AUTHORS for a human as hard as the
agent's own calls** (measured: a hand-off block said "paste the token" for a value already sitting in
the secret store — argv + shell history, when a one-line store-to-store substitution existed). Before
writing any block that carries a secret: (1) the value exists in a store the human can read →
**store-to-store** (`FIELD="$(store get …)"` command substitution — the history line carries no
value); (2) it exists nowhere → typed into a **silent prompt** (`read -rs`), exported, never argv;
(3) "paste it into the command" is never correct. Check the stores FIRST — asking a human to re-fetch
a value from a vendor portal that a store already holds is the same failure twice.

**Standard patterns** (never a secret on argv):
```bash
set -euo pipefail
: "${FOO_API_TOKEN:?Set FOO_API_TOKEN (fetch from <where>: <how>)}"
```
```bash
# one-shot admin: prompt (never argv); stream over ssh stdin → remote env → container via
# `-e NAME` (name only = env passthrough — the VALUE never lands on any argv / ps / audit line;
# `-e VAR="$T"` would put it back on the docker exec command line, so never do that)
read -rs "TOKEN?Paste TOKEN: " 2>/dev/null || read -rsp "Paste TOKEN: " TOKEN; echo
trap 'unset TOKEN 2>/dev/null || true' EXIT
printf '%s\n' "$TOKEN" | ssh "$HOST" 'read T; export T; docker exec -e T container cmd'
```
Multi-step credential ceremonies (generate-root, token mints) never have the human copy-paste an
intermediate: capture every nonce/OTP/encoded/decoded value into shell variables via command
substitution (`-format=json` + `jq -r`); the only typed secret is a hidden prompt.

## Ask-once provisioning

A provisioning/setup script that collects credentials interactively must be **re-runnable without
re-collecting them** — reruns are the NORM (scripts fail mid-flow, deploys iterate). Pattern:
**store-first, prompt-fallback, write-back** — (1) try the secret store first
(`secret/<engagement>/<purpose>`); (2) prompt ONLY for values the store doesn't have; (3) after the
script's own end-to-end verification passes, write collected values back so the next run is
zero-prompt. The store is the memory; the prompt is the one-time capture.

**This binds the AGENT, not just scripts: asking the human for an API token is the LAST resort, and
doing it twice for the same service is a violation.** Before any token prompt:
1. **Check the store** — the agent runs under the human's active login and consumes tokens IN-PROCESS
   via command substitution (`TOKEN="$(store get <path> <field>)" cmd`; value never printed, never in
   context, never on argv). A ban on secrets in agent context forbids the agent's *context* seeing
   values — it does **not** forbid command substitution in the human's shell or a script. Handing the
   human "fetch X from the store's UI and paste it" when a logged-in CLI can consume it in-process
   violates THIS rule (measured: a human was sent to a store's web UI for a token while the store's
   CLI could have returned it in-process).
   - **Store-agnostic:** "the store" is whichever secret manager the ENGAGEMENT uses — the pattern
     transfers. The in-process form is always `VAR="$(<store-cli> get KEY … --plain)" cmd` under the
     human's own store login session.
   - **Empty fields ≠ absent secret:** a blank latest version usually means a FAILED WRITE, not a
     missing credential — before prompting, list the subtree AND walk the version history for the
     newest non-empty version, and consume that in-process. Prefer the store's raw-path read forms:
     convenience wrappers can preflight paths a scoped token is denied.
2. **Verify scope** with a harmless read before using — a stored-but-stale token falls through to (3).
3. **ONE secure hand-off mint** that stores into the store in the same block (`read -s` → store
   write) and is then consumed from the store, so that service never prompts again. New tokens always
   land in the store at mint time — a token that only lives in a shell/history/CI var is a bug.

## A LOGIN QR IS A LIVE CREDENTIAL — a hand-over that renders one PUBLISHES it

**A device-linking QR is credential-equivalent, and unlike a password it is credential-equivalent to
whoever merely SEES it.** Measured on a chat bridge's device-link login: the login command does not
prompt — it immediately posts an image carrying a live device-linking token with a public key.
**Anyone who scans that image links a device to the account.** No secret is typed, so none of the
secret-handling reflexes fire, and the artifact looks like a picture rather than a key.

So the hazard is created by the INSTRUCTION, not by any value the agent handled: telling the human to
run a QR login **publishes a linking credential into a room**, and the agent's own blind-pipeline
discipline gives no protection because nothing ever entered agent context.

**Rules for any QR/device-link hand-over:**

1. **Name the room, and require it be one only the human is in.** A management room with any other
   member — including another agent's session — is a disclosure. Verify membership before sending the
   instruction, not after.
2. **An abandoned attempt is CANCELLED, never left to expire** (the bridge's cancel command). An
   unscanned code sitting in scrollback is a live credential with a timer nobody is watching.
3. **Never render one into a shared, bridged, or logged surface** — and remember a bridged room may
   have members the chat client's room list does not obviously show.
4. **A probe is not free.** An agent testing a login flow to learn its shape MINTS a real credential
   as a side effect. Probe in a room of your own, cancel immediately, and say that you did.

⚠️ **This does not generalise from the neighbouring flows, which is why it needs its own entry.** A
phone-number login prompts for a number and a code the human already possesses and creates no hazard;
a QR login mints a new linking capability on the spot. **Two flows that read identically in a
runbook — "log in to the bridge" — differ in whether following the instruction creates a credential.**
Check which kind you are handing over.

## MISPLACED is the finder's call; SENSITIVE is the owner's

⚠️ **A finder can establish that data is in the WRONG PLACE. Only the owner can establish that it
is SENSITIVE — and the two have very different remedies.** Misplaced data is MOVED: strip it at
HEAD, put it in its proper home, add a detector. Sensitive data exposed is an INCIDENT: history
rewrite, credential rotation, a re-clone of every checkout, a visibility change. The second is
irreversible, expensive, and lands on everyone.

**So ask the owner where it sits before designing the response.** The finding and the severity are
separate acts, and only the first is yours.

**Measured:** an agent found billing rates and a person's name in a public repo, correctly matched
them against a redaction standard's *"anything identifying a person"*, and escalated from *misplaced*
to *disclosure* on its own reading — producing a purge plan with a history rewrite, a force-push and a
quiesce→re-clone of every agent's checkout. The owner's actual position was that the figures were not
private, only in the wrong place. The HEAD strip was the whole fix. The rest was a large, irreversible
operation designed for a severity nobody had confirmed.

**The asymmetry is what makes this a rule rather than a judgement call:** under-reacting to a real
disclosure is recoverable by then reacting; over-reacting has already rewritten shared history by
the time anyone corrects you. **And the over-reaction is the one that feels responsible**, which is
why it needs a rule and not care. When the owner is reachable, one question costs a message; when
they are not, do the reversible half (strip, move, detect) and leave the irreversible half staged
and clearly labelled as awaiting a severity call.

**Rotate nothing until "is this a credential?" has an answer.** Rates, names, internal paths and
ticket numbers are placement problems. Keys, tokens and passwords are incidents. Treating the first
like the second buys nothing and spends trust.

## The BLIND PIPELINE — and it binds the hand-off blocks you author

⚠️ **The remedy for any secret is a BLIND PIPELINE: store-to-store, the value never in context.**
Anything that reaches an agent's context reaches the API and persists, so "handle it carefully" is
not a remedy — not passing through is.

⚠️ **This binds the COMMANDS YOU HAND A HUMAN, which is the half that gets missed.** If a value
exists in ANY store, the human's command reads it from that store (`"$(store get …)"`) — **never
"paste the value"**, which puts a secret in argv and in shell history, two places nobody scrubs.
Only a value that exists nowhere yet is typed, and then into a **silent prompt** (`read -rs`),
never argv. A ceremony that PRINTS a secret is worse than one that asks for it.

- **Probe credential files with `grep -c` / `grep -o`, never whole** — you need to know a key is
  present and well-shaped, not what it is.
- **Never grep FOR a secret — search by SHAPE.** A literal search puts the value in your own
  command line and your own history, which is the disclosure you were checking for.
- **Blind writes MERGE, never clobber.** A store write that replaces the document drops every key
  you could not read, and you cannot read any of them — so a clobber is undetectable by the writer.
- **Authenticated probes emit a status code and nothing else:** `-s -o /dev/null -w '%{http_code}'`.
  A response body is where the credential comes back.

## Found a hardcoded secret — rotation order matters

1. Verify it's **live** (dead = no rotation). 2. Find every runtime consumer. 3. **Mint the
replacement BEFORE revoking** (keeps a fallback). 4. Update consumers (push to store, bounce,
verify health). 5. **Verify end-to-end.** 6. **Then revoke** the old. 7. Scrub the repo to the
env-var pattern in one auditable commit. 8. Document where/when/new posture. Can't do 4–6 without an
admin token? **Stop and surface it** — never harvest an admin token from a remote `.env`.

## What NEVER leaves the machine

Encryption keys, keychain passwords, `.env` contents, secret-store tokens → **never** in tool output
to an LLM. Message/document *content* may by design; PII and secrets never.

## DNS conflicts: fix at the narrowest scope that works

When a shared DNS policy blocks something one machine legitimately needs, **do not widen
the shared policy** — override at the narrowest scope, in this order:

1. **Per-machine, per-domain resolver override.** macOS: `/etc/resolver/<domain>` containing
   `nameserver 1.1.1.1` routes only that domain's lookups off the shared resolver, only on
   that machine. Zero effect on everyone else, and the machine keeps filtering for
   everything else. *Gotcha that will fool you:* `dig`/`nslookup` query resolvers directly
   and IGNORE `/etc/resolver` — they still show the old answer. Verify with `curl` or a
   browser, which use the system resolver. (Linux equivalent: systemd-resolved per-link
   domain routing, or a dnsmasq `server=/domain/ip` line.)
2. **Per-client-group policy on the resolver** (a resolver's per-group blocking rules):
   infrastructure and work devices exempt, family devices keep the blocklist.
3. **Global allowlist entry — last resort**, and only with the cost stated out loud: it
   reduces filtering for *every* device on the network.

The reasoning generalizes past DNS: when a shared control blocks one legitimate use, the
fix is scoped exemption, never a blanket loosening — a global change to satisfy one machine
silently degrades the protection for everything else.

### Pick the rung from the CONSUMER, not from the domain

The ladder above is useless if you ask the wrong question. The instinct is to ask *"is this
domain legitimate?"* — which is almost always yes, and always argues for rung 3. The right
question is **"who actually needs this, and does everyone else need it too?"**

Worked example, and the mistake it caught: after a household ad-blocker was found blocking an
advertising platform's domains, the first draft was a **global** allowlist for its ad, analytics and
ads-API domains. The owner stopped it: the family network was supposed to keep ads blocked. Both
things were true at once: the domains are legitimate business infrastructure, **and** a global
exemption hands the family network that platform's ad tracking. The blocklist doing its job is not a
bug to be worked around.

**The same domain can sit on different rungs for different consumers.** Decompose by
consumer before choosing:

| Consumer | Actually needs | Rung |
|---|---|---|
| One human running ad campaigns in a web UI | `ads.example.com`, `analytics.example.com` | **1** — per-machine resolver override on that machine |
| Servers doing conversion sync via API | `ads-api.example.com` | **2** — group policy *if* those hosts even resolve through this resolver (often they don't; verify before exempting) |
| Family devices | nothing | **blocked, unchanged** |

So a single "unblock the ads platform" request splits into one machine-local override, one
verify-then-maybe group policy, and one deliberate no-change. **A global allowlist that
stays empty is the success condition, not an unfinished job** — record rejected candidates
and the reason in the file so the next person doesn't re-add them.

**Two separations, don't conflate them.** They answer different questions and split along
different lines:

| Separation | Question it answers | Splits by |
|---|---|---|
| **Policy scope** (this section) | who gets the exemption | *who consumes it* — machine / group / everyone |
| **Config location** (`technical.md` → *Public engine, private config*) | who may read the config | *what is publishable* — public repo / private overlay / secret store |

They cut across each other: a machine-scoped exemption may still be private config, and a
network-wide policy may be perfectly publishable. Deciding one does not decide the other.

## An access register that cannot answer "WHO IS THIS PERSON" cannot execute an offboarding

**Identity is a DIMENSION of access, not an attribute of a system.** A register that
maps *systems × people* — who has access to what — looks complete on every row and
still cannot be acted on, because revoking access requires knowing **which login**
that person holds **in that system**: the email, the username, the account id. Those
live nowhere in a systems×people matrix, so the omission is invisible: there is no
empty cell to notice.

**This fails silently and it fails at the worst moment.** Nobody consults an access
register on a calm afternoon; it is opened when someone leaves, under time pressure,
by whoever is available — and that is when it is discovered to be un-executable.

**Measured: three independent failures, one root.** A routine *"what is this person's
login email"* required a dig through chat archaeology; the same register shape had
previously let a mail account survive **a month past termination**; and a VPN
membership went unlisted across **four** departures. Three symptoms that were triaged
separately are one defect — the register recorded access without recording identity.

**The patch, and the mechanism is the second half:**

1. **Every access register carries a person → identity table** — one row per person
   per system, holding the actual login used there.
2. **`unknown` is written explicitly; the cell is NEVER left blank.** A blank reads as
   *"not applicable"* and disappears into the layout; `unknown` reads as *"we do not
   know"* and, crucially, is **countable** — you can ask how many identities are
   unknown and get a number. The gap becomes a metric instead of an absence.

That second rule is the whole difference between a register that degrades loudly and
one that degrades silently, and it is a recurring shape: *absence-as-health* (a missing
signal read as a healthy one) aimed at an access control. A missing row and a complete
row are indistinguishable until the moment you need to revoke something.

**Corollary for provisioning:** the identity is cheapest to capture at **grant** time,
when someone is actively logging the person in — not at revoke time, when they may be
unreachable and the account may already be the only record of its own existence.

## Security review: identify → ticket → hand off

**A security reviewer's deliverable is a triaged, verified finding that has REACHED THE WORK
QUEUE — not a patch.** Reviewers (scheduled audit agents, a review command, any audit pass) are not
responsible for remediating what they find. Their job ends at:

1. **Identify** — find it, and adversarially verify it firsthand (attacker-reachable input +
   unguarded sink, real file:line). Discard what you cannot confirm; a plausible-but-unverified
   finding costs more than it's worth.
2. **Triage** — separate real from noise, and rate by **actual exploitability, not theoretical
   severity**. A dev-only CVE that never enters the bundle is not a P1 because the scanner said
   "moderate".
3. **Ticket** — file it in the owning repo with a priority label, self-contained enough to act on
   without the audit session.
4. **Hand off** — tell the repo's worker thread the tickets exist and in what order.

**Fixing is optional and never the obligation.** A reviewer MAY land a small, surgical,
high-confidence fix — that's a bonus. It must never become the reason a finding goes unticketed,
and a fix that needs design work, touches a funnel under active churn, or can't be verified in
the reviewer's environment should be *ticketed instead*, with the exact patch recorded in the
ticket body.

**Why the separation.** Reviewer and worker are different jobs with different context, and
conflating them loses findings:
- A reviewer that only writes a dated markdown file on an unpushed audit branch has **no path
  into the work queue**. It reads as done; nothing is scheduled. *(Measured: a baseline audit's
  findings sat untouched for a month because thirteen audit runs had produced reports and zero
  tickets. The run that finally filed them surfaced seven real items that had been invisible backlog
  the whole time.)*
- Unattended reviewers can't run the full test suite, can't build, and can't judge product
  blast-radius. That's exactly the context a worker has and a reviewer doesn't.
- One agent doing both optimizes for what it can safely change, so the *hard* findings — the
  ones needing design or cross-repo coordination — are the ones that silently rot.

**Ticket contents** — self-contained, actionable without the audit thread: what's wrong, `file:line`,
why it matters *in this system* (who controls the input, what the attacker gets), the concrete fix
(name the existing helper/pattern to copy), the traps the worker will hit, and an explicit
**done-when**. Priority labels run `P0` critical → `P3` minimal; where the forge's create call takes
label IDs rather than names, create the issue first and set the labels by name afterwards.

**What must NOT go in a ticket.** Tickets are written as if public. A finding whose *description is
itself the disclosure* — a live unrotated credential, an unpatched exploitable path with a working
recipe — stays out of the tracker and goes to the human directly, with the detail left in an
access-controlled audit note. "File a ticket" never overrides that.

**The hand-off.** Delivering the list to the worker is part of the job, not an afterthought. Where
an unattended run cannot message other sessions, the hand-off is a paste-ready block in the run's
final summary, addressed to the repo's worker thread, ordered, with each ticket's one-line "why this
order".

## A ceiling is only as good as its WIDEST path — and the widest one carries METADATA

**When you bound what untrusted data can return, the paths that leak are the ones carrying *metadata
about* the data rather than the data itself** — traces, error strings, tool names, ids, counts,
labels. They are audited last precisely because they do not look like content, and **every other path
being capped is what makes the remaining one invisible.** This is the absence-as-health shape (a
missing signal read as a healthy one) aimed at a **bound** rather than a gate: the cap is real, the
tests pass, and the ceiling is not a ceiling.

**Measured on a tool that answers questions over private messages.** The answer is derived from
attacker-authorable content and was correctly capped: schema as a hint, code enforcement, cap held on
the failure path. A tool call's `name` is *model-controlled text*, and `trace` was rendered into
**both** return paths (the `[tools used: …]` suffix and the iteration-cap message), neither capped:

```
before:  return length 4066 chars   (MAX_ANSWER_CHARS = 600) — attacker text present: True
after:   'The demo is Thursday. [tools used: unknown, unknown, unknown]'
```

**4066 characters through a 600-character ceiling, verbatim.** The answer was bounded; the *report
about* the answer was not. The repro stubs the model, so it asks only what a compromised model can
push through a return value.

Three properties, all load-bearing:

- **Derive the allowlist FROM the thing it guards** — `frozenset(t["function"]["name"] for t in TOOLS)`.
  An allowlist maintained *in parallel* to its subject is a future divergence with a date on it.
- **Test the converse, or the fix is silently lossy.** A genuine tool name must still report
  unchanged; that is what makes it a ceiling rather than over-redaction.
- **Enumerate every path out, including the failure and cap-exceeded paths.** The question is not
  *"is the answer capped?"* but *"what can a malformed or creative return still push through?"*

⚠️ **Scope note, deliberately stated: one fixed instance does not make the sibling surfaces clean.**
In the same system, a sibling answer path over private message bodies had **no ceiling at all**, and a
listing returned conversation names under a fixed-width format that **pads rather than truncates** —
and a conversation's display name is set by whoever messages you, so it is attacker-authorable text
nobody classes as content *because it is a label*. Record the unfixed siblings beside the fix: an
entry implying the surface is bounded presents as complete while it is only scoped.

## Agent writes to a payment system are human-only — enforced by a deny rule, not a vendor prompt

**When an agent is connected to a tool server that can move money or change what customers are
charged — refunds, cancellations, voids, payment links, coupons, price or tax settings — every write
tool on it is DENIED to the agent in the harness settings.** Reads stay allowed: an agent may look up
a charge, a subscription or a balance; a human performs the change. A vendor-side confirmation step
that covers *some* writes is defence in depth, never the control: it covers what the vendor chose, and
the deny rule covers what you chose.

- **Deny by the exact tool name** the harness shows for that server, and verify it after connecting:
  a write attempt must be **refused by permissions**, not merely prompted.
- **Deny every surface the server arrives on.** The same tool server can reach a session under more
  than one name — added by hand under a chosen name, or attached as an account-level connector under
  a generated id — and a deny keyed to one name does not cover the other. List the names the harness
  actually shows, deny each, and **re-verify after any reconnect**: a re-added connector can get a new
  id, and the old deny then matches nothing, silently.
- **Do not assume the environment you connected is the only one it reaches.** An account-level
  connection may expose live as well as test data; check what it reports before relying on "sandbox".
- **An outbound channel on the same server** (feedback, support messages) is denied too unless there
  is a reason to allow it: it cannot move money, but it can send your data somewhere you did not choose.
- **Connect sandbox first**, and treat the live-mode connection as a separate grant with its own
  review; revoking one environment's session leaves the other untouched.
- Record the connection in the resource registry with **how to revoke it**, before connecting.

## A control is not designed until you have asked what its DEPLOYMENT exposes

A security control has two designs, and the second one is the one that gets skipped: what the
control **checks**, and where it **runs**. Nearly all the thought goes into the first. Nearly all
the exposure is in the second.

**The shape to recognise: the control gets built correctly, then wired in the one way that inverts
it.** Take a checker whose entire purpose is to keep a private list of internal names out of a
public repo — and wire it so the public repo's CI can read that list, by secret or by checkout. CI
that fires on pull requests runs code the pull request's author controls, so every PR becomes a read
primitive against the private inventory, and once the repo is public that includes strangers' PRs.
The control now discloses strictly more than the defect it prevents, and it does so wearing the name
of a security measure, which is exactly what stops anyone looking twice.

**The test, before wiring any control:** *who can cause this to run, and what does it get to read
when they do?* Not "is the secret scoped correctly" — **who holds the trigger.** A privilege granted
to a job is granted to everyone who can start that job.

**The fix is almost never "secure the wiring". It is to run the control where the data already is.**
Split it by input: the leg needing only public inputs runs in public CI; the leg needing private
inputs runs where those inputs already live — a maintainer's machine, or a job inside the private
repo itself. No new access is created anywhere, and nothing has to be kept safe that was not already.

⚠️ **The public leg must then report the private leg as NOT CHECKED, never as clean.** A split
control that reports "no findings" for a leg it never ran has traded a disclosure for an
absence-as-health defect — the other way to make a control worse than nothing. Three states, always:
**passed · failed · not checked**, with an exit code that distinguishes the third.

**This generalises well past checkers.** Any control needing privileged input to do its job — a
scanner with production credentials, a linter reading an internal allowlist, a test needing real
customer records — raises the same question and takes the same answer: **move the control to the
data, never the data to the control.**

⚠️ **THE LAUNCHING ENVIRONMENT IS PART OF THE DEPLOYMENT — a privacy or egress control must
OVERWRITE inherited values, never DEFAULT them.** `${VAR:-safe}` means *use the caller's value if
there is one*: right for a convenience setting, inverted for a control whose whole job is to
guarantee where traffic goes. Measured: a wrapper meant to pin a model client to a local endpoint
wrote that endpoint as a default; the desktop app it ran under already exported the vendor's
endpoint into every child shell, so the wrapper inherited it, a prompt left the machine, and the only
signal was an authentication failure from the vendor it was built never to reach. **It tested green
in every clean shell — which is every test shell — and failed open in the one environment that
mattered.** Rules:
- **Assign unconditionally** (`VAR=value`, or start clean with `env -u VAR` / `env -i`) for every
  variable that decides a destination, a credential, or a privacy boundary. A default is a request
  for the caller's value.
- **Test the control with the hostile value already exported**, never only with it unset.
- Where the value can arrive from several layers (shell profile, launcher, service unit, `.env`),
  **assert the effective value before the first request and refuse on mismatch** — fail closed, and
  say which layer supplied it.
