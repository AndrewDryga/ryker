# Architecture

For end-to-end message, memory, incident, approval, and cleanup diagrams, see
[How Responder works](how-responder-works.md).

## Boundaries

Responder is the incident and conversation layer above Coop:

```text
Grafana or generic webhook
          |
          v
Responder HTTP admission -> SQLite inbox and incident correlation
          |
          +-> Slack Socket Mode and Web API
          |     channel + pinned thread + operator conversation
          |
          +-> Coop Unix socket
                declared policy -> fork -> boxed ACP agent
                                   |
                                   +-> Emisar MCP
```

The layers have distinct authority:

| Concern | Owner |
| --- | --- |
| Webhook auth, incident correlation, Slack identity, input/delivery ledgers | Responder |
| Repository allowlist, agent target, budgets, fork, box, review | Coop |
| Infrastructure identity, observe/mutate policy, approval, audit | Emisar |
| Exact reviewed-tree branch publication and draft PR creation | Responder publisher |
| Merge, signing, deployment | External human-controlled workflow |

Responder executes commands, routing, buttons, permissions, and typed configuration without a
model. Every path that needs model judgment, including ordinary conversation, goes through Coop and
an operator-selected authenticated provider account. Read-only conversation and investigation use
their declared Coop policies and available repository/MCP tools. Confirmed engineering work uses a
separate isolated writable policy; Responder has no second model runtime or direct provider client.

The Slack and Emisar tokens are never submitted through the Coop session API. `bootstrap-coop`
writes the Emisar key to Coop's dedicated owner-private `env` file, while `mcp.json` references it
by environment-variable name. Coop projects those files only while the boxed ACP execution exists;
that may be one cold turn or a bounded policy-opted warm lease. The same private environment sets
`EMISAR_CLIENT=responder` for Emisar audit attribution.
Responder verifies MCP authentication and the required tool catalog at startup, then instructs
every agent to choose evidence sources by claim: repository state for declared topology and
implementation, Emisar as the preferred live infrastructure source, and any other available MCP
server or tool when it owns relevant evidence. Cross-layer answers must reconcile those sources
instead of treating runner inventory as host, VM, workload, or service inventory.
When optional foreground supervision is enabled, Responder launches and monitors the Coop process
but still communicates only through the same Unix API. Configured Slack, webhook, and Emisar secret
variables are removed from the child environment.

## Durable model

SQLite runs in WAL mode with full synchronous writes and one connection. It stores:

- normalized signals and incident occurrences;
- webhook delivery state and body digests;
- Slack inputs admitted before Socket Mode acknowledgement;
- Slack posts, updates, and native statuses in one delivery ledger;
- a small durable scheduling index with lane, subject, conversation, due time, lease token, and retry state;
- agent runs with stable idempotency keys, frozen revisions, and persisted context snapshots;
- durable work episodes with independent effort and authority contracts, required evidence
  coverage, completion criteria, current phase, and an ordered progress ledger;
- operator-confirmed scheduled tasks plus an immutable occurrence ledger keyed by task and due time;
- Slack channel, root timestamp, Coop session, and event cursor mappings;
- source-attributed evidence and health-layer coverage independent of answer prose;
- compact per-channel memory and bounded watch-session generations;
- incident timeline events and operator decisions;
- live and shadow evaluation decisions for replay analysis;
- bounded audit facts for denied and privileged actions.

HTTP and Socket Mode handlers only validate and persist input. One durable scheduler leases a small
index of typed work: a control lane handles Slack inputs, buttons, slash commands, uncertain-send
reconciliation, and Slack delivery; a background lane handles webhooks, per-incident provisioning,
agent runs, scheduled occurrences, and results; a maintenance lane handles Coop polling and bounded cleanup. Payload and
domain state remain in their typed tables rather than being copied into a generic queue. Lease
tokens reject stale workers after expiry, expired leases are reclaimed without restart, and a
conversation key prevents concurrent work in the same Slack conversation. Per-incident
provisioning retries cannot head-of-line block unrelated incidents. SQLite still has one writer
connection, and network calls happen outside transactions. Long-running Coop work therefore cannot
block operator controls or consume the source Slack input's retry budget.

The work episode is the lifecycle authority for accepted model-backed work. Agent-run transport
states describe queueing, Coop submission, and finalization; episode states describe the product
promise: acknowledged, planning, working, blocked, waiting for approval, verifying, or terminal.
Active commitments are projected from non-terminal episode states. Emisar approval resolves the
original waiting episode and queues a separate verification episode, so approval is never treated
as proof that the requested live effect succeeded.

A scheduled occurrence is not a separate execution engine. The scheduler atomically records and
advances it, creates an idempotent synthetic Slack input, and queues the ordinary triage agent run.
That preserves the same conversation serialization, Coop policy, memory assembly, tool projection,
Slack status, evidence contract, and Emisar approval continuation used by an operator message.

## Incident identity and correlation

Webhook delivery, signal, incident occurrence, Slack thread, Coop session, and Coop turn are
different identities.

For Grafana:

1. `fingerprint` identifies a signal.
2. `groupKey` identifies the preferred incident group.
3. If `groupKey` is absent, configured labels form the group.
4. If none of those labels exists, the signal identity is the group.

For generic input, `mapping.incident_id` is preferred. Configured labels are the fallback.

An existing non-closed occurrence with the same correlation key is reused inside
`correlation_window`. Duplicate webhook delivery never repeats work. A manually closed or old
resolved occurrence is immutable; a later firing creates a new occurrence.

## Slack delivery

New posts use a durable delivery ID in Slack message metadata. If a request times out after Slack
may have accepted it, Responder does not post again immediately. It searches recent channel history
for that metadata, confirms the original message, or retries only after confirming absence.

The root-card send and root timestamp binding commit in one SQLite transaction. Channel creation
has no client idempotency key, so a timeout is recovered by deterministic channel name. Responder
adopts a same-name channel only when it was created by this bot near the incident creation time.

Posts, root-card updates, and native agent statuses share one durable delivery ledger and a
conservative Slack write slot. Updates and statuses are idempotent. Card revisions are monotonic,
and every thread status update or clear receives a persistent per-thread generation, so a late
stale progress write cannot replace a newer clear, including after restart. A failed write receives
durable exponential backoff, so another queued control or reply can proceed instead of being
starved. Responder posts completed paragraphs or runs, never token-streaming tool output or routine
raw webhook refreshes. Alert source links expose their destination hostname and omit query strings
and fragments before leaving the service.

The App Home is generated from durable incident and failure metrics using Home-supported Block Kit
sections and fields. Opening the Agent Messages tab installs host-owned suggested prompts.
Accepted long-running work uses Slack's native agent status with semantic loading milestones; the
status remains until a reply, explicit silence decision, handoff, or user-facing failure is durably
handled.

## Coop delivery

Every mutation has a stable idempotency key:

```text
responder:session:<incident_id>
responder:conversation-prepare:<channel_id>:<revision>
responder:run:<agent_run_id>
responder:review:<slack_input_id>
responder:publish-review:<slack_input_id>
responder:stop:<slack_input_id>
responder:extend:<slack_input_id>
responder:close:<slack_input_id>
responder:gc-plan:<session_id>:<revision>
responder:gc-discard:<session_id>:<plan_operation_id>
```

Revision-bearing actions freeze the observed session and revision before the call. A lost response
replays the exact request. A revision conflict is surfaced instead of silently guessing a new
action.

Draft PR publication is a separate authority boundary. Coop returns a complete reviewed patch,
exact parent commit, and candidate tree. Responder applies that patch to the exact parent in an
isolated checkout and refuses publication unless `git write-tree` equals Coop's candidate tree. It
then pushes a deterministic Responder-owned branch with `--force-with-lease` and creates or updates
a draft PR. GitHub credentials are held only by Responder and are not projected into the agent box.
Responder has no merge, signing, deployment, or arbitrary branch-push operation.

Closed-session cleanup is ownership-based rather than name-based. Responder records the exact Coop
session ID before requesting a discard plan. The plan pins revision, workspace identity, branch,
head, status digest, dirty state, and unmerged state. Automatic cleanup never accepts dirty work and
accepts unmerged work only after the reviewed tree has been published durably. Unrelated Coop forks
are outside Responder's cleanup set.

Coop events are consumed by durable sequence cursor. Terminal runs are fetched from Coop and only
their bounded assistant message or terminal error is rendered into Slack.

Every completed agent turn is asked for a strict JSON envelope containing Markdown prose, evidence,
coverage, compact session memory, and an optional inert operational-memory offer. The host
sanitizes and bounds every field,
persists evidence separately, strips credentials and query strings from evidence URLs, and renders
only host-owned interactive controls. Legacy prose remains readable during upgrades but is audited
as unstructured.

Compound requests use the same envelope and authority boundary. The model must account for every
explicit instruction, order dependent work, and complete independent read-only work in the same
turn. It may return one primary `message` plus at most five ordered `followup_messages` when distinct
outcomes are easier to scan separately. Responder validates both per-part and aggregate size,
persists one evidence and memory result, and durably posts every part to the same Slack destination.
Evidence summaries, generated files, approvals, durable offers, and other host-owned controls appear
only on the final part. Repository and operational changes keep their existing confirmation and
Emisar policy boundaries; a reply sequence does not create additional authority.

Shared operational channels use one ordered watch session generation at a time. A Slack input
classifies and queues an agent run, then finishes; the independent run record owns preparation,
submission, polling, finalization, and its own retry budget. Immediately before submission, the
context assembler freezes the latest 10 to 50 Slack messages, resolved repository, preferences,
confirmed memory, and recent evidence into `agent_runs.context_json`. That exact snapshot survives
restart. After a configurable run or age limit, Responder closes an idle generation and creates the
next one while carrying only compact durable memory.

Durable cross-session memory uses one `memory_entries` table rather than a second infrastructure
catalog or entity graph. Each logical `(scope, subject, predicate)` has one active value with a
source reference, actor, visibility, expiry, and value hash. Predicates cover bounded operational
mappings plus open-ended `guidance`. Only an explicit operator confirmation can upsert an entry;
the model cannot write memory directly. Exact channel, repository, workspace, and operator
visibility filters prevent leakage. Personal workspace guidance is visible only to its operator and
therefore follows that person across channels. The prompt marks operational mappings as untrusted
hints and guidance as advice rather than evidence or authority. Current user intent, host policy,
fresh live evidence, repository content, and Responder configuration take precedence. Guidance
cannot trigger work or authorize incidents, changes, approvals, or mutations. Recent evidence is
referenced from the existing ledger rather than copied. Expiry, caps, channel deletion, and the
normal maintenance prune bound storage.

Durable behavior uses two additional typed tables rather than turning memory prose into a hidden
prompt. `responder_preferences` stores one value per logical `(scope_kind, scope_key, name)` and
resolves operator, channel, repository, then workspace precedence. `standing_rules` stores one
allowlisted trigger/action/source tuple per channel and repository.
`standing_rule_runs(rule_id, source_input)` is the idempotency boundary for Slack redelivery and
worker retry.

The model can only propose an inert typed offer. Host validation owns the catalog, expiry,
authorization, capacity, replacement key, Slack confirmation, and audit receipt. Rule matching is
also host-owned and deterministic; the model receives only already-matched rules and must return a
read-only threaded reply. This keeps arbitrary user prose out of executable triggers and authority
while allowing confirmed guidance to steer model collaboration. It also allows one subscribed
message class to operate while general proactivity is disabled. Expiry,
channel deletion, repository reconciliation, and maintenance prune remove behavior state and
dependent run records.

## Operational actions

Model-proposed, inferred, and autonomous operational mutation remains disabled. A configured
operator may directly request one exact action in any Slack conversation; the agent must discover
and submit it through Emisar's governed action contract without widening its target or arguments.
An incident room is optional coordination context, not an authorization boundary.

When Emisar returns `pending_approval`, the structured agent result copies the exact run,
operation, immutable pack and runner references, approval request, URL, and expiry. Responder accepts
that envelope only for an allowlisted operator turn, validates that the HTTPS URL belongs to the
configured Emisar origin and ends in the returned request ID, and stores the hold with its Slack
conversation and, when present, its incident.
Slack renders a **Review approval in Emisar** link. The link does not approve or execute anything,
and Responder never renders a Slack approve button for this state. Emisar owns the exact request,
policy revision, approvers, execution, and audit. A later operator turn follows the same
`wait_for_run` continuation and treats approval as authorization to dispatch, not proof of success.

## Evaluation

Shadow mode uses the same ordered read-only triage and persistence path but suppresses replies,
incident offers, and incident creation. Each decision records mode, action, reason, and evidence and
coverage counts. `responder eval --replay` replays redacted JSONL outputs through the strict parsers so
prompt, model, and schema changes fail CI when they break accepted decision contracts.

Explicit repository-change requests use a separate engineering-task handoff. The shared-channel
session remains read-only and can only return an inert task title. An authorized Slack confirmation
binds that exact source thread to a task-identified durable work record and isolated Coop fork. The
task card, progress, agent replies, controls, and later operator messages all remain in that thread;
conversation lookup requires both channel and thread so unrelated messages cannot enter the writable
session. Incident workflows still create dedicated rooms. Task identity is carried through cards,
prompts, directory entries, and close behavior so repository work is not presented as an alert
incident.

## Deliberate limits

This v1 is a single-host, single-workspace service. SQLite and a local owner-only Coop socket are
the simplest reliable fit. Production operators must deploy one isolated Responder process,
`state_dir`, Coop state directory, Slack credential pair, GitHub credential, and Emisar identity per
Slack workspace; sharing any of those across customer workspaces is unsupported. A later
multi-tenant Emisar control plane should use an outbound worker, tenant-scoped identity, and a
server database. It should not expose Coop's local socket over TCP.
