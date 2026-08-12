# Responder control plane

A local web dashboard for the operator who runs Responder, and for whoever has
to work out why it did something.

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

One person, running one or two Responder deployments, on their own machine.
Not multi-tenant, not a product surface, not for the wider team. That decision
sets everything else: no accounts, no roles, no invitations.

## Reach and trust

**Bound to `127.0.0.1` only**, on the port Responder already serves
(`listen:` in `responder.yaml`). Reached in a browser on the same machine, or
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
- Retry per run, with a confirm step: the run goes back to pending with a
  fresh Coop idempotency key and its episode reopens through the kernel's
  latest-attempt rule. Only the episode's latest attempt qualifies; a
  superseded run says which attempt replaced it instead of offering a button
  the store would refuse
- Link to the episode that failed

**Source:** `agent_runs`, `episode_attempts`, `work_episodes`.

### 3a. Workspaces — "what is still held, and why?"

Every Coop fork still on disk, with the janitor's refusal verbatim. The
blocked rows are the operator's queue: automatic cleanup has already declined
each one for a stated reason — a dirty tree, unpublished commits, a Coop
conflict — and will never look again without a person acting.

- Split into "waiting on you" (blocked) and "queued for automatic cleanup"
  (the janitor's own schedule), with reclaimed workspaces counted but not shown
- Publish and discard run the identical service handlers the Slack buttons
  call — the Coop review, the verified discard plan, the audit record, the
  Slack outcome notice — and mirror the Slack admission gate, so closed work
  refuses publish here too
- Rerun sends a blocked row back through the janitor's checks, and is offered
  only where a second pass could end differently; a dirty tree re-blocks
  deterministically and gets an explanation instead of a dead button
- A session with no work record says plainly that no safe discard path exists
  for it yet, rather than inventing one

**Source:** `coop_cleanup`, joined to `incidents`, `channel_memories` and
`conversation_sessions` for what each session belonged to.

### 4. Decisions — "what did it choose, and was it right?"

Responder's judgement, made inspectable.

- Every watch decision: action taken, attention scores, the reason it recorded
- Distribution of ignore/react/reply/incident over time
- Correction rate by class (unreadable, incomplete, rejected), which is currently
  only visible by running a CLI
- Judged eval results per corpus, with pass rate trend
- **Corrections triage**: keep or discard a fixture candidate *with the episode
  that produced it on the same page*. Today that decision is made against a
  one-line string with no context, which is why fifteen of them have sat
  unreviewed.

**Source:** `evaluation_decisions`, `fixture_candidates`, `agent_runs`,
correction-rate projection.

### 4a. Findings — "what is wrong with Responder itself?"

Decisions is about whether Responder judged a situation correctly. This is about
whether Responder is broken, which is a different question with a different
source: `scripts/quality-watch.sh` reads every terminal work episode out of
process, asks an assessor whether it reveals a concrete product defect, and then
asks a second reviewer to disprove it.

- One row per proposed defect, newest first, paged
- Both verdicts, because a rejection is the adversarial reviewer visibly working
  — it overturned 23 of the first 83 proposals — and a page that shows only
  survivors cannot tell you whether the skeptic exists
- What was wrong, what should have happened, the file-and-symbol evidence, the
  regression test the assessor would write, and the episodes it came from, each
  linking to its own page
- The path to the full prompts and transcripts, which expire on the same horizon
  the row does, so the pointer never outlives what it points at

The watcher used to keep none of this. A confirmed defect's only durable trace
was a quarantined Git worktree nobody opens and a line in a rotating log, and
its attempt to fix the defect itself landed nothing in 59 tries: 48 patches
failed the full gate against 81 distinct broken tests, 10 of the 11 that
survived were rejected by the final reviewer, and the one that passed everything
failed to install. So the fix attempt became opt-in
(`RESPONDER_QUALITY_FIX=on`), the finding became the product, and this is where
it lands. When an operator does turn the fixer on, what became of the attempt is
written back onto the row rather than left in a directory.

Findings and the transcripts behind them expire together after
`RESPONDER_QUALITY_RETENTION_DAYS` (default 30), and the sweep names every
artifact it drops.

**Source:** `quality_findings`, written by the watcher over sqlite3 rather than
through the service, because it runs out of process and only ever reports.

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

### 7. Configuration — "how is it set up, and what is that costing me?"

- Effective configuration per deployment, and which file each value came from
- Channels: participation mode, proactive, shadow, repository binding, alert
  policy — currently only reachable through a slash command per channel
- Preferences and standing rules with scope and expiry
- Schedules, with next occurrence and catch-up policy
- Session policies and the target ladder, per repository
- Prompt budget: static instruction size against the Coop turn cap, per prompt
  variant, with the history of that number

**Source:** `config`, `channel_configurations`, `responder_preferences`,
`standing_rules`, `scheduled_tasks`, session policy YAML.

### 8. Usage — "what is it spending?"

Tokens, over a selectable window (24h, 7d, 30d, everything), broken down by:
- Provider and model, as frozen on the attempt's manifest — so a turn that
  rotated to a fallback after a rate limit counts against what actually answered
- Channel, repository and episode kind
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

**Source:** `context_manifests`, joined to `agent_runs` on `attempt_id`. Not on
`episode_id`: an episode holds several runs, so that join fans out — 351
manifests became 953 rows on a production database — and every count would be
added once per run that shared the episode.

Two figures are counted separately everywhere: how many attempts are in a group,
and how many of them a provider actually measured. Zero tokens and "nobody
measured this" are different facts and are drawn differently, down to the trend,
where a day that ran unmeasured attempts gets its own mark rather than an absent
bar.

## Data gaps

Usage is only as complete as the active adapter. Token counters and
provider-reported USD cost are durable per turn when Coop receives them. An
adapter may report tokens without money, or neither; those gaps remain explicit
instead of being rendered as zero spend.

### The compiled prompt — kept as a digest, not as text

The context manifest records a sha256 of the compiled prompt, and only the
engineering-task path keeps the text itself. Twelve of 647 turns on a production
database can be read back; the rest can only be compared between attempts. The
digest is shown where the text is not, so the page says which of the two it has.

### Prompt composition — needs a size per reference

The manifest names every reference that went into a prompt and the digest of
each, and records the size of none of them, so "how much of this turn was
instructions" cannot be recovered from what is stored. It needs a byte count per
reference at freeze time.

### Cost — reported first, estimated only as a fallback

Coop normalizes ACP's cumulative USD counter into a durable per-turn delta, and
Responder totals those reported amounts without re-pricing them. This is the
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
- **Host** — Responder not yet having noticed the turn finished. It polls, so
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

## What v1 wires

The instruction is that the whole shape is visible even where it is not yet
live, so the design can be judged as a whole.

| Page | Wired |
|---|---|
| Overview | Live |
| Episodes list and detail | Live, with free-text search, a state filter, pagination, and resolve-as-overtaken on blocked and waiting work |
| Failures | Live, with retry per run; superseded runs say why they are history |
| Workspaces | Live, with publish, discard and rerun through the Slack buttons' own service paths; rows with no safe path say why |
| Decisions | Live, with corrections triage and feedback dismiss/convert |
| Findings | Live, read-only, with both verdicts and pagination |
| Audit | Live, with a drill-down per kind, an actor filter, a since window and pagination |
| Memory | Live, with forget and the stale/duplicate review queue's keep and dismiss |
| Configuration | Live, read-only |
| Usage | Live for tokens, cache rate, the daily trend, cost and the wall-clock split — each empty state names what was not measured or configured; prompt composition stays marked unwired |

Every action is a POST behind a native two-step confirm — the CSP forbids
script, so `confirm()` was never an option that actually ran — and writes its
store transition and its audit row in the same act, attributed to
`control-plane@localhost`.

An unwired panel says exactly why it is empty and what would make it work, and
says it about the right thing: once a gap is filled, a panel still tagged "not
recorded yet" reports a fixed problem as an open one and sends someone to plumb
what is already plumbed. An attempt frozen before a change says so about itself
rather than about the product. A panel that looks live and is not is worse than
no panel, and this repository has
already been bitten by that twice today: a deploy that reported success while
old code ran, and a quality watcher that logged "no defects" for a day while
its assessor could not start.

## Technology

- **Go `html/template`**, server-rendered. No build step, no bundler, no
  node_modules. The service already serves HTTP from `internal/httpapi`.
- **Filters and time windows are links**, not controls. A filtered list is a
  URL, which makes it bookmarkable and pasteable into an incident thread, and
  costs no client-side state to keep in step with the server's.
- **CSS in one hand-written stylesheet**, vendored. No framework.
- **No JavaScript at all.** Nothing on this dashboard needs it, and the moment
  something does it becomes the first thing on the page that cannot render with
  the network off. Charts are inline SVG with the geometry computed server-side,
  so a trend is data rather than a runtime dependency.

The test is that the whole dashboard works offline, from one Go binary, with no
assets fetched at runtime.

## Non-goals

- Multi-user, accounts, roles
- Editing prompts or policies through the browser — those are code and config,
  reviewed in git
- Anything that mutates infrastructure; Emisar remains the only path for that
- Replacing the Slack App Home
- Public exposure
