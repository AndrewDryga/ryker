# Ryker control plane

A local web dashboard for the operator who runs Ryker, and for whoever has
to work out why it did something.

The current implementation plan is [Control-plane redesign](control-plane-redesign.md).
It specifies Phoenix LiveView throughout, fast reliable admission, readable model
request inspection, complete cost accounting, the reviewed learning flywheel,
and simpler configuration. Its target technology and information architecture
supersede the older proposals below; they are not yet deployed. This document
remains the capability inventory and historical design rationale.

This document preserves the intended complete control-plane design. The current
Elixir replacement exposes only projections backed by durable Elixir state.
Usage is now one of those projections: admission, Work and learning executions
each retain the effective Coop target, provider usage when present, and remote
timing boundaries in one execution ledger. Missing provider telemetry stays
explicitly unmeasured rather than appearing as zero.

## Route map

Execution reading uses three named surfaces, and their routes match those names.
There are no compatibility aliases for earlier paths.

| Surface | Route | What it holds |
| --- | --- | --- |
| **Activity** | `/` and `/activity` | The global list of inputs, running work and delivered answers, with its filters in the query string. `/` is the application root and renders the same list. |
| **Timeline** | `/timeline/:ref` | One request's chronological case file, titled by its subject. `:ref` is a durable episode key or `ingress-input:<id>` for an input with no episode yet. |
| **Model calls** | `/timeline/:ref/model-calls` | The technical inspection of the retained model requests behind that Timeline, with `kind`, `attempt` and `generation` selecting the exact retained artifact. |

Live invalidation domains follow the first path segment, so `activity` and
`timeline` are also the PubSub domain names in `ControlPlane.Updates`.

### Timeline evidence: what is recorded and what is not

The Timeline groups evidence by the durable owner each step was recorded
against (the input row, the Work turn, or the remote turn id on an activity
event), never by the nearest message in time. Which inputs a turn was built
from is recorded beside its frozen submission (`episode_work_turns.selected_input_refs`);
turns frozen before that column say "Selected inputs not recorded" and are
never reconstructed from today's episode state.

Getting ready runs, per input, **Participation settings**, then **Standing
rules**, then the **Engagement** decision. The first and last read
`ingress_inbox_entries.engagement_receipt`, written by the adapter that admitted
the input: the entry path, the effective proactive/shadow values with the
source each one won from, and the outcome of every predicate the gate actually
reached. The Slack gate short-circuits, and the receipt records that honestly;
a predicate it never ran renders "Not checked", never "No". Explicit Lab and
shortcut submissions record that they bypassed channel settings instead of
inventing Slack checks. Inputs without a receipt render "not recorded"; nothing
is recomputed from today's settings.

Getting ready always carries a **Standing rules** card for each input. It reads
`standing_rule_inventories`, written once per accepted input after custody
commits and outside that transaction: every standing rule in the workspace at
that moment with the verdict it got (matched, not matched, other channel,
paused, expired, or not considered when it sat outside the runtime's 100-rule
candidate window). The recorder is observation only; it does not change which
rules schedule work, and a failure to write it never fails the input. A
recorded empty inventory renders "No standing rules existed"; an absent row
renders "Standing-rule evaluation was not recorded", and the two are never
conflated with "0 matched". The inventory expires with episode history.

Getting ready ends with an **Input queue** card per input: saved or not,
waiting for what, and whether routing picked it up. It reads only the durable
custody row (`ingress_inbox_entries` status, claim count, retry time, latest
error) and the earliest admission attempt, whose insertion is the routing claim.
A decided input is "Handed to routing" with its recorded claim time and queue
wait; an input with no surviving attempt row says "Not recorded" for both,
never a zero-second wait. Pending inputs read the live queue and label that
state current: a held lease is "Handed to routing", a future retry time is
"Waiting to retry" with the eligible-after time (eligible, not promised), and
an earlier pending input in the same transport, conversation and execution
mode is named and linked as the blocker. Blocked inputs say automatic retries
stopped and link the existing recovery page; superseded inputs keep their save
facts and say a newer revision won. No source acknowledgement log exists, so
that row is always "Not recorded". The standalone input view at
`/timeline/ingress-input:<id>` carries the same four Getting ready cards.

Each briefing card's counted rows say what they counted over. Included comes
from the frozen context, which is the exact set that reached the model, so a
stale or wrong ledger can never inflate it. Eligible and the two kinds of
omission come from `episode_work_turns.selection_ledger`, written beside the
frozen submission while the selection was being made: how many inputs were
eligible, how many fell outside the bounded history window, and how many were
cut to fit. A turn frozen before that column renders "selection not recorded"
rather than a zero, and a same-session update counts earlier messages as "not
resent", never as omitted. Routing rows read the frozen admission snapshot:
"N checked · M offered" from its conversation episode count and candidate list,
with recorded knowledge omissions; without a retained snapshot the row says the
search scope was not recorded. Offered is not chosen — the model's choice is a
later fact on its own card.

The work phase opens with a **Work setup** card per Work turn (and one on the
pinned session while no turn has claimed it), before the Work briefing. It
distinguishes the pinned setup from the session, worker and workspace the turn
actually ran on: Session New / Reused from previous work round / Replaced (the
rotation reason is not retained, so it says "Reason not recorded"), Worker
(the fleet placement's worker, or "Local Coop" for a bound local session),
Profile, and Workspace as "Prepared · N repositories" from the frozen
submission's workspace snapshot. Ready needs evidence that preparation
completed, which is a bound remote turn; a live Work lease without a bound
session is "Preparing" at the one step the rows record; a turn blocked before
it started says what its recorded error code means; and a session row alone is
"Setup selected". Individual preparation checks were never recorded and are
labelled that way. Setup details keep repository access, the bound Ryker
tools, the bound task and technical identifiers; the repo@sha chips and the
tool catalog stay on the briefing.

Recognized notification formats get a provider card in place of the generic
byline: HCP Terraform run notifications (recognized from the retained Slack
attachments, harvested in `testdata/slack/hcp-terraform-planning.json`) and
native Grafana webhook alerts. The card promotes a few labelled facts, a textual
state and https-only source links placed after Input details; recognition is a
presentation projection over retained content that proves a format, never a
sender, and it changes nothing about engagement, routing or prompts. Unknown
formats keep the generic card and an expired input loses the recognized card
rather than borrowing a later revision.

Each received input's **Input details** open on extracted metadata (source,
event, identifiers, revision, the source event time with its provenance and
the time Ryker recorded it), followed by three independently collapsed
bodies in this order: Raw input, Normalized input, Original message. Raw input
is the adapter's own event payload, stored beside the normalized content in
`ingress_inbox_entries.source_envelope` minus transport credentials, bounded
at 64 KiB and pruned with the other input bodies. The Slack gateway supplies
it; inputs from adapters that do not, and every input that predates the
column, render "Not recorded", and an oversized payload renders as an explicit
omission with its size. The normalized document is never shown as raw.

Full prompt bodies on the Timeline load when their disclosure is opened and
stay loaded across refreshes; a confirmed expiry, redaction or authorization
loss closes the disclosure and removes the body regardless of reading state.
Retained tool result bodies (`output`, `error`, `content`, `locations`) and
model plans follow the same contract, keyed by `activity-<event id>-<field>`;
so do the retained payloads on the Model calls page, keyed by `tool-<event
id>`. Tool **arguments** stay prepared, because the compact row a reader scans
— the command it ran, the file it read, the observation it recorded — is
derived from them.

Every card carries a link to itself built from its own durable evidence key
(`event-activity-<id>`, `event-queue-<input id>`, `story-message-<id>`), never
from its position in the page, so a link keeps resolving as history grows.

Retained history is bounded and says so: the Timeline names how much of each
retained total it is showing and offers "Show earlier activity", which loads
one more bounded page of older activity events (`?events=N`, up to ten pages of
1,000). Older events are added before the ones already read; nothing is dropped
or duplicated, and when no further page exists the affordance is absent.

Two background sections follow the answer in reading order while keeping their
own recorded times, because learning routinely overlaps the work and reading it
later must not make it look like it happened later. **Learning** appears only
when one of this request's own inputs is a recorded member of a learning batch
(`conversation_learning_inputs`); sharing a channel is not membership. A batch
that also read other requests says "1 of 3 from this request" rather than
claiming the rest, an all-defer judgment says nothing was saved instead of
reporting a failure, and a rejected or stale result says nothing was saved and
why. **Maintenance** reads the session's own cleanup fields: closing a session
is not removing its workspace, a workspace kept for uncommitted or unpublished
work is not a failure, a session that never bound a remote one had no remote
workspace to delete, and blocked cleanup states that the delivered answer is
unaffected.

The **Incident rooms** page at `/incident-rooms` tracks Slack incident rooms from
setup through closure, with channel status and linked investigation work. Each
room opens at `/incident-rooms/:ref`. The list includes requested and blocked
rooms before a Slack channel exists; it is not a directory of local Lab incidents.
Room status and search filters remain in the URL, and committed lifecycle changes
refresh the list and detail views.

The **Waits** page at `/subscriptions` shows each wait's saved target,
matching condition and source request. Relative times refresh with the page;
exact UTC times and internal references remain available in Technical details.
A next check is a polling fallback, not an estimated event arrival. Event-only
waits have no scheduled check or deadline; elapsed times do not mark work complete.
The list shows up to 100 waits in the selected status, active first and newest
updates first within each status. Search filters their readable labels;
exact subscription references search all history within that status. Opening,
filtering and refreshing this page never changes a wait.

## Global and channel instructions

`/instructions` has one installation-wide Global instructions field. Each available
Slack channel has its own Channel instructions editor directly on
`/channels/:workspace/:channel`, with a read-only preview of the inherited global
text. The channel list shows “Global only” or “Global + channel” without excerpts.

Save changes explicitly; Cancel discards the draft. Each field accepts 2,000 Unicode
characters and 8 KiB of UTF-8, preserving line breaks and Markdown. Clear and save
to remove that scope's instructions. A stale edit shows the current saved version
without overwriting it; review the conflict before saving again. Unsaved drafts
survive refresh and are kept per scope in browser tab storage for return navigation
when storage is available. Recovery retains the draft's original revision.

Every new Admission, Work and Learning/relearning request includes a frozen global
and applicable channel snapshot. Channel instructions override only conflicting
global defaults. An authorized task-specific request can override standing style
defaults; current settings take precedence over older recalled Guidance. Instructions
are always supplied, while Guidance is selected when relevant. Neither grants
permissions nor changes participation, source attribution, retention or response
contracts. The model cannot edit these operator settings.

Changes apply to the next newly prepared model turn, including continuing sessions.
Already submitted work and exact transport retries retain their saved instructions.
Clears are explicit empty revisions, not missing history. Request and learning
inspection show the text, scope and revisions actually submitted, through existing
redaction and retention; today's settings never reconstruct an expired request.

## Why this exists

The Slack App Home is the wrong surface for most of this and cannot be fixed by
writing it better. Block Kit allows ten fields in a section, rejects a view when
two buttons share an action id, and has no table, no sort, no filter and no
pagination. The content is lists of twenty-one blocked items, thirty retained
workspaces and a hundred failures. Slack renders an alert well; it cannot render
a workbench.

So the two surfaces split by job:

| Surface | Job | Good at |
|---|---|---|
| Slack App Home | "Does anything need me right now?" | Three items, tap to jump, already where the operator is |
| Control plane | "What happened, why, and what do I do about it?" | Lists, history, detail, triage, configuration |

The App Home stays as it is. Nothing here replaces it.

## Audience

One person, running one or two Ryker deployments, on their own machine.
Not multi-tenant, not a product surface, not for the wider team. That decision
sets everything else: no accounts, no roles, no invitations.

## Reach and trust

**Bound to `127.0.0.1` only**, on the port Ryker already serves
(`RYKER_CONTROL_IP` and `RYKER_CONTROL_PORT`). Reached in a browser on the same machine, or
through an SSH tunnel. No authentication, because the loopback interface is the
authentication.

This is a deliberate limit rather than a first step. The tailnet was the
alternative and was rejected for v1: it carries tagged service devices, so
binding to it without an identity check would put production episode content,
evidence and prompts in reach of any node on the tailnet. If the dashboard ever
needs to be reachable from a phone, that is a separate decision requiring
Tailscale identity headers and an allowlist, not a bind-address change.

Consequences to respect:
- **Read-only by default.** Write paths (retry, discard, publish, keep) are
  individually opted in, each with a confirmation, because there is no second
  factor behind them.
- **Secrets never render.** The same redaction the Slack path uses applies
  before anything reaches a template.
- **No external assets.** No CDN fonts, no analytics, no telemetry. The page
  must render with the network off, and nothing about production work should
  leave the machine.

## Information architecture

Nine pages. Each answers one question.

### 1. Overview — "what is happening right now?"

The landing page. Live state, not history.

- Health of each deployment: readyz, running binary sha, uptime, Coop supervision
- Work in flight, by phase (queued, working, verifying, waiting)
- Needs a decision: the same set the App Home leads with, linked into detail
- Failure rate and correction rate over the last 24h and 30d, as sparklines
- Provider state: which target is live, ladder position, last rotation, credential
  expiry
- Queues: pending, running and failed pollers per lane. Readyz reports that the
  process is up; a lane whose pollers are all failed is a process that is up and
  doing nothing

**Source:** `work_episodes`, `agent_runs`, `responder_state`, readyz probe,
`coop credentials`. Mostly present.

### 2. Episodes — "what did it do, and why?"

The heart of the dashboard and the reason to build it first. A list, filterable
by state, channel, repository, provider and outcome; each row opens a detail
page.

Incident rooms lead the page. A room is a whole conversation of work and an
episode is one turn of it, so the room is where the ask that opened it, the
narrative the channel saw, and the pull request that came out of it belong:
`incidents`, `signals`, `timeline_events`, `publications` with their followups
and lifecycle events. Three merged pull requests were visible only in GitHub.

Episode detail:
- **Timeline** from `work_episode_events` — every phase change, evidence record,
  progress report, destination change, reopen, with actor and timestamp. 11,679
  of these exist today and none is visible anywhere.
- **Evidence ledger** from `evidence` and `claim_assessments` — each claim, its
  verdict, what supported or contradicted it, source, freshness, confidence.
  This is what makes "why did it say that" answerable. Neither table carries an
  `episode_id`: both are filed under `source_input`, which is the Slack input id
  for a watch and the agent run id otherwise.
- **Coverage** from `coverage` — which layers were assessed, which were unknown.
  `unknown` is the load-bearing value: it separates "checked and healthy" from
  "nobody looked".
- **Context manifest** from `context_manifests` and `context_manifest_refs` —
  prompt, contract and tool-schema versions, execution policy, and the reference
  list itself: the Slack message that started the work, the compiled prompt and
  assembled context by digest, the repository at a revision, and any artifact.
- **The turn itself** — prompt sent, response received, parse outcome. The
  response is read with `decision.ParseWatchDecision`, the host's own parser,
  rather than a display decoder that would be a second implementation of the
  contract.
- **Answers the host refused** from `audit_events` — the corrections handed back
  when a result could not be read. The difference between "it said nothing" and
  "it said something the contract rejected".
- **Delivery** from `slack_deliveries` — what was posted, where, whether it landed.
- **Attempts** from `episode_attempts` — retries, and what changed between them.
- **What it spent** from the usage columns on `context_manifests` — tokens per
  manifest and totalled for the episode, with unmeasured attempts named as
  unmeasured rather than summed as free. One row per manifest, because an
  attempt whose context was extended froze a second one and the tokens are split
  across both.
- **What was left out** from `omissions_json` and the reference rows carrying an
  `omitted_reason` — the context layers the budget dropped, and any elision the
  transport had to make. The reference list says what the model read; this says
  what it did not, which is usually the answer to "why did it say that".

The list is filterable by channel, repository, episode kind, provider and model
through the query string, which is what makes each Usage breakdown openable.

Every debugging question in this repository's history is answered on this page.
Today they are answered by running sqlite against a production database.

### 3. Failures — "what is broken and can I retry it?"

`Failed work: 100` is a number the App Home cannot open.

- Grouped by cause, because a hundred failures are rarely a hundred problems
- Retryable vs superseded, attempts, last error
- Confirmed recovery for each typed custody owner: blocked admission reconciles
  its frozen context and operation identities; blocked Work retains its stopped
  turn and transfers to a fresh logical turn; delivery retries its exact accepted
  intent; Slack repaint and incident-room provisioning reuse their durable
  targets; Emisar resumes read-only monitoring of the same governed request
- Semantic publication review is not listed as an infrastructure failure and
  cannot be bypassed with a generic retry button
- Link to the episode that failed

**Source:** ingress, episode Work, delivery, Slack interaction/incident, Emisar,
and retention custody tables.

### 3a. Workspaces — "what is still held, and why?"

Every Coop fork still on disk, with the janitor's refusal verbatim. The
blocked rows are the operator's queue: automatic cleanup has already declined
each one for a stated reason — a dirty tree, unpublished commits, a Coop
conflict — and will never look again without a person acting.

- Split into "waiting on you" (blocked) and "queued for automatic cleanup"
  (the janitor's own schedule), with reclaimed workspaces counted but not shown
- Rearm restores only the exact cleanup phase captured when automation
  blocked. It keeps the frozen Coop session identity, clears the bounded retry
  state, and records the operator action atomically
- Explicit discard is offered only for a clean workspace retained because it
  has unpublished, unmerged commits. It requests a fresh exact Coop plan with
  unmerged acceptance; dirty work remains retained and has no discard button
- Publication remains a task/publication workflow, not a workspace-cleanup
  shortcut. The Workspaces page never invents a publish or generic rerun action
- A row with no provably safe transition says why and has no dead control

**Source:** `coop_cleanup`, joined to `incidents`, `channel_memories` and
`conversation_sessions` for what each session belonged to.

### 4. Routing and response checks

An episode's Routing section shows the saved briefing, activity, decision and
reason for each incoming message. Response checks appear as individual events
in the same timeline. The request inspector provides the full retained artifacts
for a selected model execution; it is not another execution or a second timeline.

Usage compares work classes and models using the execution ledger: runs, failures,
elapsed model time, and retained response corrections. Provider retries are not
counted as response corrections. Credentialed evaluation results remain in their
recorded reports and are not presented as live-traffic quality scores.

There are no standalone Decisions or Calibration pages. The current Elixir
control plane does not provide fixture-candidate keep/discard controls.

### 5. Audit — "who did what, and what came of it?"

The only place an approval, a saved channel configuration, a remembered
preference and a refused model answer sit in one sequence.

- Grouped by kind, because 976 events are not 976 different things
- Each kind opens to its own events, with actor, outcome and detail
- Rows link into the episode or the incident room they belong to, and episode
  and room detail link back
- Identical consecutive actions fold to one row with a count, the same way the
  episode timeline does

There is no directory that turns a Slack id into a name, so the actor column
says what kind of thing acted — person, app, the host, this dashboard — beside
the id. Inventing a name would be worse than the id.

**Source:** `audit_events`, joined to `agent_runs` to resolve an object to its
episode.

### 6. Memory — "what does it believe, and where did that come from?"

- Operational memory entries with scope, expiry, source, and the episode that
  proposed them
- Conversation memory per channel: goal, situation, open loops, topology,
  knowledge items with status and confidence
- Channel situations, with the provenance link for each learned fact
- Forget, with confirmation

**Source:** `memory_entries`, `memory_rollups`, `conversation_memories`,
`channel_memories`.

### 7. Settings — "how is it set up, and what is that costing me?"

- Editors for the product decisions: Slack, GitHub and Emisar connections,
  repositories, repository contexts, GitHub repository bindings, execution
  policies, work placement, publication identity, the weekly report, learning,
  retention horizons and optional token rates. Each section saves explicitly at
  the revision it was read at, keeps its draft when a save is refused, and shows
  what is saved now when another writer got there first
- Execution policies are chosen by name from what enrolled, unrevoked workers
  advertise; the digest and authority digest are copied from that advertisement,
  never typed, and a binding the fleet no longer advertises is shown as
  unavailable with its pin intact rather than repointed
- Saved revision and running revision as two separate facts, with the reason a
  saved revision could not be applied
- Which deployment credentials are configured, missing or unusable — presence
  only, never values
- Effective assembled configuration, read-only, below the editors
- Channels: participation mode, proactive, shadow, repository binding, alert
  policy — proactive and shadow are the only two a slash command still sets, and
  the rest are set by the channel setup conversation in that channel
- Preferences and standing rules with scope and expiry
- Schedules, with next occurrence and catch-up policy
- Prompt budget: static instruction size against the Coop turn cap, per prompt
  variant, with the history of that number

**Source:** `installation_settings` and the typed settings tables beside it,
`channel_configurations`, `responder_preferences`, `standing_rules`,
`scheduled_tasks`. There is no application configuration file.

### 8. Usage — "what is it spending?"

Tokens, over a selectable window (24h, 7d, 30d, everything), broken down by:
- Provider and model, as frozen on the attempt's manifest — so a turn that
  rotated to a fallback after a rate limit counts against what actually answered
- Channel, repository and episode kind
- Work type, named for what the execution bought rather than for the router's
  internal taxonomy: Routing (the admission decision), Conversation,
  Investigation and Deep investigation (the three compute tiers admission
  chooses between), and Learning (the background memory learner). Follow-on
  Work turns carry no admission decision, so they are typed by their turn
  family instead: continuation, resumed work, task, event wait, scheduled run,
  publication follow-up and approval. Every Coop turn Ryker submits is one
  ledger row whose counters are Coop's cumulative figures for that turn,
  including schema and semantic repairs.
- Cache hit rate: cached input over all input read
- A daily trend, inline SVG rendered server-side

Every row links into an episode list filtered to it. A breakdown that cannot be
opened says which model costs the most and gives no route to a single turn of
it.

Cost prefers what the provider reported through Coop. A configured
`config.Pricing.Cost` table supplies a separately labelled estimate only for
model rows that reported tokens but no money; reported and estimated amounts
are never added together. Wall clock reads the migration-49 columns and
averages only over timed turns; a window with none says "nothing timed" rather
than inventing an instant.

**Source:** `episode_work_turns`, joined once to its exact immutable
`episode_work_session` and owning episode. Usage is attached to an accepted
logical turn, so no episode-level fan-out is required.

Two figures are counted separately everywhere: how many attempts are in a group,
and how many of them a provider actually measured. Zero tokens and "nobody
measured this" are different facts and are drawn differently, down to the trend,
where a day that ran unmeasured attempts gets its own mark rather than an absent
bar.

## Data gaps

Usage is only as complete as the active adapter. Token counters and
provider-reported USD cost are durable per turn when Coop receives them. An
adapter may report tokens without money, or neither; those gaps remain explicit
instead of being rendered as zero spend. Coop keeps no counters for a turn that
fails or is cancelled before it stages a candidate, so such executions appear
with no token report rather than with the tokens the provider actually
consumed.

### The compiled prompt — kept as text, on the episode's clock

Two copies, deliberately, because they answer different questions and expire on
different clocks.

`context_manifests.submitted_prompt` is the exact submitted bytes, and the
`compiled_prompt` reference records a sha256 over them. It is transport state:
Prune empties it on the operational horizon, twenty-four hours, alongside the
agent run context it rides with.

`context_manifest_texts.prompt` is the same prompt after the production
sanitizer, cascading from the manifest and so from the episode — the
episode-history horizon, thirty days by default, and longer while anything pins
the episode. It is what record-episode, promote-fixtures and any later export
read.

Before the second copy existed there was only the first, and the survivorship
said what that cost: 428 of 1221 manifests on the blitz database still held a
prompt, and every one of them was from the previous two days. The harvest was
never limited to a code path, it was limited to yesterday.

The trace page prefers the submitted bytes while they exist, because the digest
beside them was taken over those. When only the archive copy is left it renders
that instead and labels it "Redacted archive", saying in as many words that the
text will not hash to the fingerprint below it. Neither copy is silently
substituted for the other.

What it costs, measured on both deployments before it shipped: blitz freezes
~142 manifests a day at ~132 KB of prompt each — ~19 MB a day, ~131 MB a week,
~560 MB once the thirty-day horizon fills. emisar, ~26 a day, is ~2 MB a day and
~60 MB filled. Prompts are bounded by `coop.MaxPromptBytes` at 256 KiB, not by
the 60 KiB `agentprompt` applies to its own; the measured p50 is 139 KB and the
p90 175 KB.

### Prompt composition — needs a size per reference

The manifest names every reference that went into a prompt and the digest of
each, and records the size of none of them, so "how much of this turn was
instructions" cannot be recovered from what is stored. It needs a byte count per
reference at freeze time.

### Cost — reported first, estimated only as a fallback

Coop normalizes ACP's cumulative USD counter into a durable per-turn delta, and
Ryker totals those reported amounts without re-pricing them. This is the
authoritative money figure when the adapter supplies one.

For adapters that report tokens but not money, `pricing` in the configuration
file can provide a clearly labelled estimate. `config.Pricing.Cost(provider,
model, usage)` returns an amount and whether it is knowable. An unpriced model
reports **no estimate, not a zero**. Keys are `provider:model`, falling back to
bare `provider`; rates are per million tokens.

The default table is empty and valid: provider-reported money still appears,
while turns whose adapters report no money stay unpriced.

### Wall-clock — recorded per attempt, except the split inside the provider

`context_manifests` carries `usage_timed_turns`, `usage_queued_ms`,
`usage_provider_ms` and `usage_host_ms` (migration 49), totalled over the same
turns as the token columns and written in the same idempotent statement.

Three spans, because there are three places a turn waits and they fail
independently and are fixed differently:

- **Queued** — Coop holding the turn before a provider picked it up: a busy
  session, or an exhausted ladder.
- **Provider** — the provider working.
- **Host** — Ryker not yet having noticed the turn finished. It polls, so
  that gap is real, is nobody else's, and is the one span this repository can fix
  on its own.

`usage_timed_turns` is both the divisor for a per-turn figure and the recorded
flag, because zero milliseconds is ambiguous between "instant" and "unmeasured".
A turn that failed while still queued carries no `started_at`, contributes no
span, and is kept out of the divisor rather than dragging every average toward a
duration no turn actually took.

**Provider time is not split into inference and tool calls, and cannot be from
here.** Coop's turn record carries `queued_at`, `started_at` and `finished_at`
and nothing between them, and its activity states (`starting`, `running`,
`parked`, `cancelling`) are session lifecycle rather than what the model is
doing. Splitting that span would mean inventing the boundary, and an invented
split in a latency report is a guess wearing a measurement's clothes. Closing it
needs per-tool-call timing on Coop's turn record — a change in that repository,
the same as the token counts.

### What was left out of a prompt — now recorded

`context_manifests.omissions_json` and `context_manifest_refs.omitted_reason`
were empty on every row of both deployed databases — 351 manifests and 2,825
references saying nothing had ever been dropped from any prompt, which is not
what happened. It is what nobody wrote down.

The watch assembler trims context to fit the turn, and now returns what it
trimmed instead of only telling the model. Each dropped layer is written twice:
as a reference row with `visibility = 'omitted'` and a reason, so it sits beside
the references it displaced, and as a line in the manifest's `omissions_json`
summary. A prompt the transport had to elide is recorded too, with the byte
count it lost, against the attempt that suffered it rather than in the
process-local counter that only ever knew how many prompts had been cut and
never which episode's.

A layer is reported the first time anything is taken from it, not when it
happens to reach exactly empty. That distinction is the whole value: budgeting
stops the moment the prompt fits, so a turn that dropped 389 of 400 channel
messages and then fitted at 11 left the layer non-empty — and under the old
rule said nothing at all, staying silent for precisely the prompts that lost the
most.

Omissions do not travel forward when a later attempt extends the manifest. They
are facts about the attempt that made them, and carried over, a layer trimmed
once would read as trimmed forever, including on the attempts that carried it in
full.

## What the Elixir replacement currently wires

Only backed projections appear in navigation. This table describes the current
replacement, not the older dashboard or the intended final design above.

| Page | Wired |
|---|---|
| Overview | Live for active, waiting, blocked, delivery-pending, admission queued/deciding/retrying counts, oldest active-admission time, durable Slack-status backlog age, and bounded attention records |
| Conversations | Live, with durable messages/files, generated-image delivery, the exact Slack chat tool schemas through a local-only adapter, reactions, confirmed extra posts, native cards/actions, episode custody, and same-session continuation |
| Episodes list and detail | Live, with bounded search, state filtering, pagination, lifecycle metadata, and typed state-record summaries |
| Incident rooms list and detail | Live, with bounded search, Slack-room lifecycle, linked source and investigation episodes, typed evidence records, and sanitized publication state |
| Schedules list and detail | Live, with bounded search, confirmed run-now, direct-conversation replacement, recurrence and authority, destination, trigger kind, child execution state and timing, attempts, sanitized failures, and dispatched or missed occurrence history |
| Waits | Live, with active-first bounded search, readable target/condition/request, relative timing and exact UTC timestamps, accurate event/timer resolution, and collapsed technical details without raw source payloads |
| Channels list and detail | Live, with bounded search across durable Slack configuration, membership, incident ownership, conversation summaries, schedules, overrides, and recent episodes |
| Repositories and topology | Live, with configured policy names, durable channel, schedule, session, and publication counts, serving Coop worker revisions, and the latest frozen freshness receipt |
| Failures | Live, with typed confirmed recovery for admission, Work, delivery, Slack repaint/incident, Emisar monitoring, and retention custody |
| Workspaces | Live, with audited cleanup rearm and explicit safe discard |
| Usage | Filtered execution ledger, cost and timing, plus work-class/model comparisons and retained response corrections |
| Findings | Live, read-only |
| Standing rules | Live, with active/paused/expired counts, searchable scope/status filters, paginated confirmed instructions, original conversation, expiry, recent matches, and confirmed pause/resume/delete |
| Preferences and Guidance | Separate live libraries with visible scope, effective expiry, full guidance, provenance, history filters, and confirmed lifecycle controls |
| Memory | Operational mappings and stale/duplicate reviews, with confirmed keep/merge/edit/forget; rules, guidance, preferences, and schedules have their own pages |
| Settings | Live editors for every product decision, each with explicit Save/Cancel, preserved drafts, revision conflicts, and saved-versus-running state; below them an allowlist of effective runtime values, MCP/host/tool grant names, and repository-topology linkage. Secrets, endpoints, callbacks, and raw policy documents are omitted, and credentials appear only as configured, missing or unusable |

Every administrative action is a POST behind a native two-step confirm and
writes its store transition and audit row in the same act, attributed to
`control-plane@localhost`. A direct-conversation message is intentionally a
single CSRF-protected POST: it is an ordinary user input, not an administrative
state mutation or a shortcut to the model.

New instructions go through the existing conversation and confirmed-offer
workflow. No legacy rules are implicitly imported or activated.

Episode model inputs summarize standing rules, preferences, guidance, and
memory from the complete sanitized **retained request**, not today's library.
Missing or partial archives do not acquire reconstructed rule matches. The
original source-aware context remains available inline for inspection.

An unwired panel says exactly why it is empty and what would make it work, and
says it about the right thing: once a gap is filled, a panel still tagged "not
recorded yet" reports a fixed problem as an open one and sends someone to plumb
what is already plumbed. An attempt frozen before a change says so about itself
rather than about the product. A panel that looks live and is not is worse than
no panel, and this repository has
already been bitten by that twice today: a deploy that reported success while
old code ran, and a quality watcher that logged "no defects" for a day while
its assessor could not start.

## Conversations

`http://127.0.0.1:4321/conversations` holds direct conversations with the agent,
without Slack. It is an ordinary way to use the same agent: enter here, receive
replies here, inspect the exact execution from each message. The page is a
directory of retained conversations (grouped by recency, times in UTC) beside
the conversation. The index is an empty draft: its composer is bound to a fresh
identity and nothing is written until the first message, after which the browser
opens that conversation; `New` in the directory header returns to the index. Each
message carries a `View request` link to its own retained execution: an input's
own admission request (or its pre-episode request inspector, or its recorded
decision when it was ignored) and a reply's producing work turn. While a message
is waiting on admission its progress shows beneath it. There is no runtime rail,
welcome page or `/conversations/new` route. Editing an operator message happens
in place: Edit swaps the rendered body for an editor at the same width, Enter
adds a line, Cmd/Ctrl+Enter saves one new revision through the message's own
edit route, Escape cancels without a request, a rejected save keeps the text with
an error beside it, and an open editor survives live patches and reconnects.
Reactions on a reply are compact pills showing each recorded emoji with the
count of its current reactors and a pressed state for the operator's own;
clicking a pill posts the real add or remove for that exact reply, and an
"Add reaction" control opens an anchored picker with the five quick choices and
a labelled custom-name field whose validation stays beside it. A
submitted message is
normalized as a `control_plane` source input and then crosses the ordinary
Inbox, Admission, Episode, Work, state-tool, and Delivery boundaries. The
browser never calls Coop or a model provider directly. Accepted replies and
status are projected from the same PostgreSQL rows that own runtime custody;
there is no second chat transcript or browser-owned recovery state.

A conversation uses the exact `control_plane.work_profile` from trusted host
configuration. That profile pins its Coop policy, digest, and optional
repository just like a Slack, GitHub, or webhook adapter does. Browser content
cannot select a policy, mount another repository, or widen authority.

One stable UUID identifies the local conversation and its exact destination
thread. Follow-ups can therefore continue the same episode and Coop session,
while a restart simply lets PostgreSQL leases be reclaimed. The page shows only
local operator text and validated attachments, bounded integration-event markers, accepted visible replies and generated images, deliberate
reactions, native host-issued state/task/publication cards and controls, task diff/timeline/evidence/handoff
views over the exact confirmed child episode, bounded record or artifact
references, and episode lifecycle metadata. Every control re-reads the exact delivered record and
destination before it mutates state. Integration markers show only the trusted adapter, route, event
type, revision, and custody status; arbitrary payload bodies remain model input and never render.
Prompts, unaccepted candidates, credentials, and state-tool bearer
tokens never render.

This is product-semantic parity, not borrowed platform authority. A direct conversation can exercise the same model,
episode, task, memory, schedule, wait, publication, Emisar, artifact, reaction, source-read, explicit
additional-post, incident, and recovery behavior as a Slack conversation. It publishes the exact five Slack chat
tool names and schemas through a virtual workspace containing only the current conversation. Local
model-requested reactions and host-confirmed extra posts traverse the same durable action outbox and
render in the conversation. Operator feedback reactions are ordered episode events: add/remove updates
the current count without waking work, and a later message carries both current state and bounded event
history into its frozen model context. Message edits and deletes retain one stable source identity with
monotonic revisions. Search and source reads span the exact conversation across completed episode boundaries, and
uploaded conversation files appear as bounded virtual file resources with the same `files` search and `document`
read contract. An incident offer opens a linked policy-pinned local incident episode in the same timeline,
so the investigation, tools, waits, progress, and controls are real while Slack channel creation is not.
Confirmed tasks automatically start the same trusted readiness checks as Slack when their completed
result contains prepared changes; no second readiness action is needed. Cards retain draft-publication, delivery-check, diff, stop,
close, timeline, evidence, and handoff actions. Local incidents add the same evidence-backed postmortem
view without pretending that a Slack room was provisioned.
The local adapter also keeps an executable allowlist of those five implementations. If the shared Slack
catalog gains or loses a tool without the matching local behavior, the catalog fails closed instead of
advertising a tool the conversation cannot execute.
The adapter reports that it is emulated and has no external effects. Real Slack audience filtering,
workspace content, channel provisioning, membership, topic, pin, and archive effects remain on the
disposable Slack qualification journey because a direct conversation never receives Slack credentials.

The manual qualification journeys that used to live on a Test journeys page
are in [`docs/testing.md`](testing.md#manual-qualification). A journey is
complete only when both the visible platform effect and its durable
Episode/Work/Delivery record agree.

## Technology

The following describes the current implementation. The target is Phoenix
LiveView with committed-state updates and reconnect recovery, as specified in
the [redesign plan](control-plane-redesign.md#1-liveview-throughout-the-control-plane).

- **Elixir Plug/Bandit**, server-rendered. No frontend build step, bundler, or
  node_modules. Read models are bounded Ecto projections over the same durable
  stores that own runtime custody.
- **Filters and time windows are links**, not controls. A filtered list is a
  URL, which makes it bookmarkable and pasteable into an incident thread, and
  costs no client-side state to keep in step with the server's.
- **CSS in one hand-written stylesheet**, vendored. No framework.
- **One tiny same-origin script for live conversation refresh.** Every page renders and
  every mutation works without JavaScript. While a local conversation owns live
  custody, `/static/lab.js` replaces only the server-rendered transcript/status
  fragment; it neither stores messages nor calls an external origin. Charts
  remain inline SVG with geometry computed server-side.

The test is that the whole dashboard works offline, from the Ryker runtime,
with no assets fetched at runtime.

## Non-goals

- Multi-user, accounts, roles
- Editing prompts or policies through the browser — those are code and config,
  reviewed in git
- Anything that mutates infrastructure; Emisar remains the only path for that
- Replacing the Slack App Home
- Public exposure
