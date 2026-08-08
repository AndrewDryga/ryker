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

Seven pages. Each answers one question.

### 1. Overview — "what is happening right now?"

The landing page. Live state, not history.

- Health of each deployment: readyz, running binary sha, uptime, Coop supervision
- Work in flight, by phase (queued, working, verifying, waiting)
- Needs a decision: the same set the App Home leads with, linked into detail
- Failure rate and correction rate over the last 24h and 30d, as sparklines
- Provider state: which target is live, ladder position, last rotation, credential
  expiry

**Source:** `work_episodes`, `agent_runs`, `responder_state`, readyz probe,
`coop credentials`. Mostly present.

### 2. Episodes — "what did it do, and why?"

The heart of the dashboard and the reason to build it first. A list, filterable
by state, channel, repository, provider and outcome; each row opens a detail
page.

Episode detail:
- **Timeline** from `work_episode_events` — every phase change, evidence record,
  progress report, destination change, reopen, with actor and timestamp. 11,679
  of these exist today and none is visible anywhere.
- **Evidence ledger** from `evidence` and `claim_assessments` — each claim, what
  supported or contradicted it, source, freshness, confidence. This is what makes
  "why did it say that" answerable.
- **Coverage** from `coverage` — which layers were assessed, which were unknown.
- **Context manifest** from `context_manifests` and `context_manifest_refs` —
  provider, model, reasoning effort, prompt version, and what was omitted from
  the prompt and why. 2,825 refs exist and are invisible.
- **The turn itself** — prompt sent, response received, parse outcome.
- **Delivery** from `slack_deliveries` — what was posted, where, whether it landed.
- **Attempts** from `episode_attempts` — retries, and what changed between them.

Every debugging question in this repository's history is answered on this page.
Today they are answered by running sqlite against a production database.

### 3. Failures — "what is broken and can I retry it?"

`Failed work: 100` is a number the App Home cannot open.

- Grouped by cause, because a hundred failures are rarely a hundred problems
- Retryable vs terminal, attempts, last error
- Bulk retry within a group, with confirmation
- Link to the episode that failed

**Source:** `agent_runs`, `episode_attempts`, `coop_cleanup`.

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

### 5. Memory — "what does it believe, and where did that come from?"

- Operational memory entries with scope, expiry, source, and the episode that
  proposed them
- Conversation memory per channel: goal, situation, open loops, topology,
  knowledge items with status and confidence
- Channel situations, with the provenance link for each learned fact
- Forget, with confirmation

**Source:** `memory_entries`, `memory_rollups`, `conversation_memories`,
`channel_memories`.

### 6. Configuration — "how is it set up, and what is that costing me?"

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

### 7. Usage — "what is it spending?"

Tokens and time, broken down by:
- Provider and model
- Deployment, channel, repository
- Episode kind: watch, incident, engineering task, scheduled
- Prompt composition: how much of each turn was instructions, context, tool
  results, conversation
- Cache hit rate on cached input tokens
- Cost, once a price table is configured

**This is the one page that cannot be built from existing data.** See below.

## Data gaps

Everything above is present in the database today except three things.

### Token usage — needs plumbing, not research

Coop already parses `input_tokens`, `cached_input_tokens`, `output_tokens` and
`reasoning_output_tokens` from the provider stream
(`coop/internal/cli/streamjson_providers.go`). Responder never receives them and
nothing is persisted.

Required:
1. Coop reports usage on the turn result
2. Responder persists it per attempt, alongside the context manifest that already
   records provider, model and effort
3. Aggregation by the dimensions above

Until then the Usage page renders its full shape with an explicit "not yet
recorded" state per panel. It must not show an estimate dressed as a
measurement — a number derived from prompt bytes is a guess, and a guess in a
cost report is worse than a blank.

### Cost — needs a price table

Tokens are provider-native; cost needs a per-model price table in configuration.
Deliberately not hardcoded: prices change, and a stale hardcoded rate reports
confident wrong money.

### Wall-clock breakdown — partially derivable

Episode duration is derivable from timestamps. Time split between model
inference, tool calls and host processing is not recorded, and would need
timing on the turn result the same way usage does.

## What v1 wires

The instruction is that the whole shape is visible even where it is not yet
live, so the design can be judged as a whole.

| Page | v1 |
|---|---|
| Overview | Live |
| Episodes list and detail | Live — this is the reason to build it |
| Failures | Live, read-only; retry in v2 |
| Decisions | Live for history and correction rate; triage actions in v2 |
| Memory | Live, read-only; forget in v2 |
| Configuration | Live, read-only |
| Usage | Full layout, every panel marked "not recorded yet" |

An unwired panel says exactly why it is empty and what would make it work. A
panel that looks live and is not is worse than no panel, and this repository has
already been bitten by that twice today: a deploy that reported success while
old code ran, and a quality watcher that logged "no defects" for a day while
its assessor could not start.

## Technology

- **Go `html/template`**, server-rendered. No build step, no bundler, no
  node_modules. The service already serves HTTP from `internal/httpapi`.
- **htmx** for filtering, sorting and partial refresh, vendored as a single
  file. No SPA, no client-side router, no state duplication.
- **CSS in one hand-written stylesheet**, vendored. No framework.
- **No JavaScript beyond htmx.** Charts are inline SVG rendered server-side, so
  a sparkline is data rather than a runtime dependency.

The test is that the whole dashboard works offline, from one Go binary, with no
assets fetched at runtime.

## Non-goals

- Multi-user, accounts, roles
- Editing prompts or policies through the browser — those are code and config,
  reviewed in git
- Anything that mutates infrastructure; Emisar remains the only path for that
- Replacing the Slack App Home
- Public exposure
