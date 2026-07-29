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
                declared policy -> fork -> short-lived agent box
                                   |
                                   +-> Emisar MCP
```

The layers have distinct authority:

| Concern | Owner |
| --- | --- |
| Webhook auth, incident correlation, Slack identity, inbox/outbox | Responder |
| Repository allowlist, agent target, budgets, fork, box, review | Coop |
| Infrastructure identity, observe/mutate policy, approval, audit | Emisar |
| Exact reviewed-tree branch publication and draft PR creation | Responder publisher |
| Merge, signing, deployment | External human-controlled workflow |

The Slack and Emisar tokens are never submitted through the Coop session API. `bootstrap-coop`
writes the Emisar key to Coop's dedicated owner-private `env` file, while `mcp.json` references it
by environment-variable name. Coop projects those files into a turn only while its short-lived box
runs. The same private environment sets `EMISAR_CLIENT=responder` for Emisar audit attribution.
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
- outgoing Slack messages with caller-owned IDs;
- Coop turn submissions with stable idempotency keys and frozen revisions;
- Slack channel, root timestamp, Coop session, and event cursor mappings;
- source-attributed evidence and health-layer coverage independent of answer prose;
- compact per-channel memory and bounded watch-session generations;
- incident timeline events and operator decisions;
- live and shadow evaluation decisions for replay analysis;
- bounded audit facts for denied and privileged actions.

One serialized reconciliation loop leases a small amount of each work type. HTTP and Socket Mode
handlers only validate and persist input. This keeps acknowledgements short and avoids concurrent
incident workers fighting over SQLite or Slack rate limits.

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

New messages use a durable outbox ID in Slack message metadata. If a request times out after Slack
may have accepted it, Responder does not post again immediately. It searches recent channel history
for that metadata, confirms the original message, or retries only after confirming absence.

The root-card send and root timestamp binding commit in one SQLite transaction. Channel creation
has no client idempotency key, so a timeout is recovered by deterministic channel name. Responder
adopts a same-name channel only when it was created by this bot near the incident creation time.

Thread posts and dirty root-card updates alternate through a conservative Slack write slot. A
failed card update keeps its durable dirty version and receives in-memory exponential backoff;
another incident card or queued thread reply can proceed instead of being starved. Responder posts
completed paragraphs or turns, never token-streaming tool output or routine raw webhook refreshes.
Alert source links expose their destination hostname and omit query strings and fragments before
leaving the service.

The App Home is generated from durable incident and failure metrics using Home-supported Block Kit
sections and fields. Opening the Agent Messages tab installs host-owned suggested prompts.
Accepted long-running work uses Slack's native agent status with semantic loading milestones; the
status remains until a reply, explicit silence decision, handoff, or user-facing failure is durably
handled.

## Coop delivery

Every mutation has a stable idempotency key:

```text
responder:session:<incident_id>
responder:turn:<turn_submission_id>
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

Coop events are consumed by durable sequence cursor. Terminal turns are fetched from Coop and only
their bounded assistant message or terminal error is rendered into Slack.

Every completed agent turn is asked for a strict JSON envelope containing Markdown prose, evidence,
coverage, compact session memory, and an optional inert operational-memory offer. The host
sanitizes and bounds every field,
persists evidence separately, strips credentials and query strings from evidence URLs, and renders
only host-owned interactive controls. Legacy prose remains readable during upgrades but is audited
as unstructured.

Shared operational channels use one ordered watch session at a time. After a configurable turn or
age limit, Responder closes an idle generation and creates the next one while carrying only compact
durable memory. The latest 10 to 50 Slack inputs remain frozen event context for each decision; they
are not compressed into hidden model history.

Durable cross-session memory uses one `memory_entries` table rather than a second infrastructure
catalog or entity graph. Each logical `(scope, subject, predicate)` has one active value with a
source reference, actor, visibility, expiry, and value hash. Only an explicit operator confirmation
can upsert it. The model cannot write memory directly. Exact channel, repository, workspace, and
operator visibility filters prevent cross-channel leakage. The prompt labels recalled entries as
untrusted hints and gives fresh live evidence, current repository content, and Responder
configuration higher precedence. Recent evidence is referenced from the existing ledger rather
than copied. Expiry, caps, channel deletion, and the normal maintenance prune bound storage.

Durable behavior uses two additional typed tables rather than turning memory prose into a hidden
prompt. `responder_preferences` stores one value per logical `(scope_kind, scope_key, name)` and
resolves operator, channel, repository, then workspace precedence. `standing_rules` stores one
allowlisted trigger/action/source tuple per channel and repository.
`standing_rule_runs(rule_id, source_input)` is the idempotency boundary for Slack redelivery and
worker retry.

The model can only propose an inert typed offer. Host validation owns the catalog, expiry,
authorization, capacity, replacement key, Slack confirmation, and audit receipt. Rule matching is
also host-owned and deterministic; the model receives only already-matched rules and must return a
read-only threaded reply. This keeps arbitrary user prose out of executable instructions and
allows one subscribed message class to operate while general proactivity is disabled. Expiry,
channel deletion, repository reconciliation, and maintenance prune remove behavior state and
dependent run records.

## Operational actions

Model-proposed and autonomous operational mutation remains disabled. Shared-channel work is
read-only. A configured operator may directly request one exact action in an existing incident
conversation; the agent must discover and submit it through Emisar's governed action contract
without widening its target or arguments.

When Emisar returns `pending_approval`, the structured agent result copies the exact run,
operation, immutable pack and runner references, approval request, URL, and expiry. Responder accepts
that envelope only for an allowlisted operator turn, validates that the HTTPS URL belongs to the
configured Emisar origin and ends in the returned request ID, and stores the hold with the incident.
Slack renders a **Review approval in Emisar** link. The link does not approve or execute anything,
and Responder never renders a Slack approve button for this state. Emisar owns the exact request,
policy revision, approvers, execution, and audit. A later operator turn follows the same
`wait_for_run` continuation and treats approval as authorization to dispatch, not proof of success.

## Evaluation

Shadow mode uses the same ordered read-only triage and persistence path but suppresses replies,
incident offers, and incident creation. Each decision records mode, action, reason, and evidence and
coverage counts. `responder eval` replays redacted JSONL outputs through the strict parsers so
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
