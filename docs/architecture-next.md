# Responder Target Architecture and Verification Plan

Status: proposed target architecture  
Last updated: 2026-08-03  
Audience: Responder maintainers, operators, and contributors  

This document defines the architecture Responder should evolve toward. It is intentionally more
prescriptive than [Architecture](architecture.md), which describes the currently deployed system,
and more implementation-oriented than [How Responder Works](how-responder-works.md), which explains
current product behavior.

The purpose of this document is to preserve the product and engineering decisions required for the
next implementation phase. A migration is complete only when the corresponding behavior is proven
by the tests and evaluation gates defined here. Existing behavior must not be removed merely because
the replacement type or package exists.

## 1. Product objective

Responder should behave like a persistent operational teammate:

> It notices important things, decides when it can help, works until it has a decision-ready result,
> communicates naturally while working, remembers commitments and organizational context, and never
> confuses initiative with authority.

The product is not primarily a chatbot, incident-room generator, or thin wrapper around an agent.
It is a durable operational work system with Slack as its main human interface, Coop as its model
execution boundary, Emisar and other tools as governed evidence and action boundaries, and
repositories as authoritative implementation context.

Success means that Responder can:

- understand a conversation without assuming every nearby message addresses it;
- decide whether to remain silent, react, answer, investigate, prepare work, or ask for approval;
- investigate broadly enough for the requested decision instead of stopping after the first check;
- handle compound instructions without silently dropping requested outcomes;
- make meaningful progress visible without posting repetitive status noise;
- continue work after restarts, approvals, schedules, PR transitions, deployments, and tool outages;
- operate across related repositories while keeping changes, review, and publication unambiguous;
- remember durable organizational facts and preferences without treating stale prose as evidence;
- use Coop presets, consults, and provider subscriptions without creating another model runtime;
- explain which context and evidence informed a conclusion;
- remain useful when an external system is slow or temporarily unavailable;
- sound like a thoughtful human teammate, including restrained humor when appropriate;
- preserve deterministic permission, approval, publication, and mutation boundaries.

## 2. Architectural stance

### 2.1 Modular monolith first

The target is a modular monolith, not a distributed system. One Go binary and one transactional
database remain the pragmatic deployment unit until measured scale requires separation.

Internal modules must have explicit boundaries, narrow ports, and independent tests. Network service
boundaries should be introduced only when deployment isolation, independent scaling, or ownership
requires them. Splitting code into packages is not sufficient if the packages still share mutable
state or call each other through broad interfaces.

### 2.2 Events are authoritative

Accepted work is represented by append-only domain events. Current state, Slack surfaces,
commitments, controls, scheduled work, and follow-up state are projections of those events.

The event stream is not a generic copy of every database mutation. It records product facts that
must survive restarts and support replay, such as:

- a Slack input was admitted;
- an episode was accepted;
- a goal was planned or completed;
- an execution attempt started or failed;
- evidence was recorded;
- an approval was requested or resolved;
- a publication was created or merged;
- a deployment was observed;
- verification passed or found a regression;
- an operator changed, cancelled, or superseded the goal;
- a user-facing progress or final message was durably delivered.

### 2.3 Models propose; the host decides effects

Every action with product consequences is typed and host-validated. The model can propose
investigative routes, evidence, progress, a question, a task, a schedule, a consult, an approval
request, or completion. The host validates authority, state, freshness, coverage, sizes, source
identity, and idempotency before accepting the operation.

The model never directly:

- writes durable memory;
- changes permissions or authority;
- approves an Emisar action;
- creates an incident, engineering task, schedule, standing assignment, branch, or PR;
- chooses arbitrary provider credentials;
- changes the Slack reply location after host routing is resolved;
- publishes unvalidated raw tool output;
- declares success when the claim and evidence ledger do not support it.

### 2.4 Reliability before cleverness

The architecture must prefer resumable work over short turn budgets, exact blockers over vague
failure prose, and idempotent effects over optimistic retries. No fixed turn count should be the
normal completion boundary for deep work. Resource governance is expressed through workspace
budgets, concurrency, deadlines, quiet intervals, and operator-visible pause states.

### 2.5 Privacy is structural

Workspace, channel, conversation, repository, and operator visibility are carried on every piece of
retrievable context. Retrieval intersects visibility rather than relying on prompt instructions not
to disclose private context. Cross-workspace reads are impossible by construction.

## 3. Four independent product policies

The following policies must remain separate because combining them causes unsafe or unnatural
behavior.

| Policy | Question | Owner |
| --- | --- | --- |
| Engagement | Should Responder speak, react, or start work? | Host policy plus bounded model classification |
| Effort | How much investigation is required? | Typed effort contract and goal coverage |
| Authority | What may be read, changed, published, or executed? | Deterministic host, Coop, and Emisar policy |
| Communication | Where, when, and how should the result be expressed? | Host routing plus communication policy |

Humor cannot affect authority. Proactivity cannot imply permission. Urgency cannot relax evidence
requirements. A channel preference can change reply location or investigation depth but cannot
authorize a mutation.

## 4. Complete system map

```text
Slack   Webhooks   GitHub   Terraform   Emisar   Schedules
  \         |         |         |          |         /
                 ingress adapters
                        |
                transactional inbox
                        |
                canonical event log
                        |
             workspace and service graph
                        |
                 engagement policy
                        |
                 episode reducer
                  /            \
             goal DAG      context assembler
                |                 |
         execution router    context manifest
                |
          Coop execution profile
       lead / consult / delegate
                |
          typed result operations
                |
       claim and evidence ledger
                |
             effect planner
                |
            transactional outbox
          /        |        |       \
       Slack     Emisar   GitHub   Terraform
```

The inbox, event append, state reduction, and outbox enqueue happen transactionally. External
network calls happen outside the transaction. A successful external effect is recorded as another
event and may advance the episode.

## 5. Package and dependency boundaries

The eventual package shape should make invalid dependencies difficult:

```text
internal/domain/
  workspace/       tenants, operators, visibility, authority
  graph/           services, dependencies, provenance
  conversation/    platform-neutral conversations and actors
  episode/         lifecycle state and event reducer
  goals/           goal DAG and completion criteria
  evidence/        claims, observations, contradictions, assessments
  memory/          durable knowledge and continuity summaries
  behavior/        preferences and standing assignments

internal/application/
  ingest/          normalize and admit external events
  engagement/      decide ignore, react, reply, or work
  orchestration/   advance episodes and goal DAGs
  context/         construct and persist bounded context manifests
  execution/       select and invoke Coop execution profiles
  subscriptions/   resume work from external lifecycle events
  communication/   produce semantic communication intents
  effects/         validate and enqueue side effects

internal/ports/
  conversation.go
  executor.go
  operations.go
  publication.go
  repositories.go
  scheduler.go
  storage.go

internal/adapters/
  slack/
  webhook/
  coop/
  emisar/
  github/
  terraform/
  repositories/
  sqlite/

internal/quality/
  corpus/
  replay/
  invariants/
  behavioral/
  canary/
  releasegate/
```

The domain and application packages must not import Slack Block Kit, `slack-go`, HTTP request
types, Coop transport structs, Emisar response structs, GitHub clients, SQL, or filesystem-specific
repository implementations.

This layout is a target, not a requirement to move every file at once. Boundaries should be
introduced around behavior and then existing code moved behind them in tested increments.

## 6. Canonical platform-neutral events and effects

Inbound adapters translate external payloads into canonical events:

```go
type ConversationRef struct {
    Platform  string
    Workspace string
    Channel   string
    Thread    string
}

type InteractionEvent struct {
    ID           string
    Revision     string
    Conversation ConversationRef
    Actor        Actor
    Kind         InteractionKind
    Content      Content
    OccurredAt   time.Time
    ReceivedAt   time.Time
    Visibility   Visibility
    Source       SourceRef
}
```

Application code emits semantic effects rather than provider calls:

```go
type MessageIntent struct {
    EpisodeID    string
    Conversation ConversationRef
    Visibility   Visibility
    Purpose      MessagePurpose
    Content      StructuredMessage
    Controls     []Control
    Generation   int64
}

type StatusIntent struct {
    EpisodeID    string
    Conversation ConversationRef
    Phase        string
    Detail       string
    Generation   int64
}
```

Provider adapters decide how these intents map to Slack threads, channel posts, native agent
status, Block Kit, reactions, file uploads, or future platforms. The domain never stores provider
rendering as its source of truth.

### 6.1 Engagement pipeline

Engagement is a staged decision rather than one model classification:

1. the inbound adapter identifies transport facts such as actor, app subtype, mention, thread,
   reaction, edit, file, and source event ID;
2. deterministic admission rejects duplicates, unauthorized actors, unsupported events, bot loops,
   and channels outside configured visibility;
3. configured behavior resolves mentions-only, proactive, shadow, standing-assignment, and explicit
   summon policy;
4. bounded model judgment decides whether an eligible ambient message deserves silence, a reaction,
   a concise answer, or an investigation;
5. the host validates the decision against conversation location, source identity, authority, and
   current episode state;
6. accepted work becomes an episode or goal event before any user-visible effect.

Static rules determine eligibility and safety. Model judgment handles semantic questions such as
whether a human conversation is already resolving the issue, whether an alert is credible, and
whether intervention would be useful. App identity alone does not prove an incident, while an
ordinary human message does not automatically require a response.

The autonomy ladder is explicit: notice, investigate, recommend, prepare, publish within an
authorized boundary, and escalate for approval. A standing assignment may grant initiative within
its configured scope but never general authority.

## 7. WorkEpisode state machine

### 7.1 Statechart

The state machine governs lifecycle and effects, not the model's private investigative reasoning.

```text
received -> classified
  -> ignored
  -> reacted
  -> accepted -> planning -> working
                           -> waiting_external
                           -> waiting_for_input
                           -> waiting_approval
                           -> verifying

verifying -> working          material evidence gap
verifying -> completed        completion contract satisfied

any active -> blocked
any active -> failed
any active -> cancelled
any active -> superseded
```

`waiting_external` has a typed reason such as `tool_retry`, `provider_capacity`, `scheduled_time`,
`pr_checks`, `merge`, `deployment`, `terraform_run`, or `rate_limit`. A generic "waiting" state is
not sufficient for resumption or useful UI.

Effort, authority, approval, publication, Slack delivery, and repository state are orthogonal
properties. Encoding every combination as a top-level state would create an unmaintainable state
explosion.

### 7.2 Transition invariants

Every transition must:

- be caused by an immutable event;
- be accepted by one pure reducer;
- carry the expected episode revision;
- reject events from stale workers or controls;
- be idempotent by source event or operation key;
- emit effects only after the new state is durably committed;
- preserve enough metadata to reproduce the decision in replay;
- produce an operator-visible exact blocker when forward progress is impossible.

The reducer has no network calls, clock reads, random values, or database queries. Time and
identifiers arrive in events.

### 7.3 Agent runs are attempts

An `AgentRun` is one execution attempt. It owns Coop submission, polling, transcript bounds,
artifacts, and transport failure. It does not own the product lifecycle. A failed or truncated run
can be replaced by another run while the episode remains active.

### 7.4 Conversation ordering

Inputs are serialized by conversation key. Multiple conversations and episodes may progress in
parallel, but only one reducer transaction can advance one episode revision at a time. Writable
repository goals also acquire a repository-scoped lease so two episodes cannot publish conflicting
changes from the same managed branch namespace.

## 8. Goal DAG and compound work

A message may contain multiple goals. Responder must preserve each explicit outcome and model their
dependencies instead of forcing the entire request into one final response.

```text
Investigate production error
  -> identify affected service
  -> verify customer impact
  -> prepare application patch
  -> prepare infrastructure patch
  -> open dependent draft PRs
  -> wait for checks and merges
  -> observe deployment
  -> verify recovery
  -> report resolution
```

Each goal node records:

- title and normalized desired outcome;
- parent and prerequisite goal IDs;
- service and repository scope;
- effort contract;
- authority boundary;
- execution profile;
- completion claims and verification requirements;
- current state and exact blocker;
- retry, deadline, spend, and concurrency policy;
- resulting evidence, artifacts, publications, and follow-ups.

Independent read-only nodes may execute concurrently. Dependent nodes become ready only after their
prerequisites complete. A failure blocks only affected descendants unless the parent objective
cannot remain useful without them.

The model may propose a DAG, but the host validates that every user instruction is represented,
that cycles do not exist, and that no node has broader authority than the parent request.

## 9. Planned executions, schedules, and follow-ups

Planned work is part of the goal system, not a separate agent pipeline.

Supported trigger classes include:

- a specific time;
- a recurring calendar or interval schedule;
- an operator reply;
- an Emisar approval or terminal run;
- a PR check, review, close, or merge transition;
- a deployment or Terraform lifecycle transition;
- a repository revision becoming available;
- a condition derived from authoritative evidence.

```go
type PlannedExecution struct {
    GoalID           string
    Trigger          Trigger
    ExecutionProfile string
    Authority        AuthorityBoundary
    Preconditions    []Condition
    Destination      ConversationRef
    Deadline         *time.Time
    RetryPolicy      RetryPolicy
    IdempotencyKey   string
}
```

When the trigger fires, Responder rehydrates the episode, refreshes relevant graph and repository
state, rechecks authority and tool availability, freezes a new context manifest, and invokes the
normal execution path. A schedule never carries permanent authorization.

Each recurring occurrence gets a child episode linked to its parent schedule. This prevents one
infinite event stream while retaining missed-run detection, trend summaries, and the next due time.

## 10. Service graph

The service graph is a derived operational index, not a second manually maintained infrastructure
catalog.

```text
service -> repository
service -> runtime or workload
service -> owner or on-call group
service -> Slack channel
service -> dependency
service -> runbook
service -> dashboard
service -> deployment pipeline
service -> SLO or operational indicator
```

Sources can include repositories, Terraform, Nomad or Kubernetes, GitHub, Emisar, monitoring tools,
and operator-confirmed mappings. Every node and edge records:

- workspace and visibility;
- source kind and stable source reference;
- source revision or observation time;
- first and last observed times;
- confidence and authority rank;
- expiry or refresh policy;
- active, stale, contradicted, or superseded state.

Conflicting assertions remain visible. A repository declaration and a live runtime observation may
both be correct at different layers. Resolution policy chooses the active view for a specific claim
without deleting history.

The graph helps select repositories, tools, runbooks, owners, incident audiences, related
conversations, required investigation claims, and lifecycle subscriptions. It cannot grant
authority or prove current health without fresh evidence.

## 11. Multiple repositories

Read-only investigations may use a repository set containing a primary repository and exact-revision
read-only companion snapshots. The context manifest records every repository and revision actually
used.

One writable engineering goal has one writable primary repository. Companion repositories remain
read-only. A genuine cross-repository change becomes a parent episode with one child engineering
goal and isolated Coop fork per writable repository.

```text
Parent objective
  -> API repository patch and PR
  -> infrastructure repository patch and PR
  -> client repository patch and PR
  -> coordinated compatibility validation
  -> ordered rollout and verification
```

This preserves clean diffs, review ownership, branch publication, rollback, and cleanup. A dummy
parent Git repository containing multiple independently writable nested repositories is not a
replacement for explicit repository identity.

Cross-repository completion requires explicit compatibility evidence and publication ordering. A
parent episode cannot report success merely because one child PR was merged.

## 12. Coop execution profiles, consults, and presets

Responder continues to use Coop for every model-backed decision. It must not introduce a direct
provider runtime for fast chat.

Responder selects a typed execution profile. The profile resolves to a Coop preset and records the
exact provider, model, effort, account, role, tool policy, peer set, and budget in the episode
runtime version.

Recommended profiles include:

| Profile | Intended use |
| --- | --- |
| `chat-fast` | Ordinary conversation and narrow contextual questions |
| `ops-focused` | One or two explicit operational checks |
| `ops-deep` | Broad production assessments and persistent investigations |
| `incident` | Incident investigation, progress, approval, and verification |
| `change-review` | Plans, diffs, and high-risk change analysis with critics |
| `engineering` | Isolated writable work, review, validation, and publication preparation |
| `postmortem` | Timeline analysis, evidence synthesis, and follow-up extraction |

The lead may request a read-only consult with an SRE, security, database, infrastructure, or code
review peer. The host validates the requested role, reason, spend, timeout, data visibility, and
profile allowlist. Consult advice is evidence or critique, never authority. The lead remains
responsible for the final result.

Consults should be used for contradictions, high-risk plans, specialist domains, major changes, or
an explicit operator request. They should not add cost and latency to every message.

## 13. Claim and evidence ledger

Every decision-material conclusion is represented as claims supported or contradicted by atomic
evidence.

```text
Claim: cms-web memory is healthy after rollout
  supporting evidence:
    - current allocation uses 24 percent of limit
    - no restarts since deployment
    - backend is ready
  limiting evidence:
    - observation window is only three hours
```

Evidence records source, target, dimensions, observation time, validity interval, freshness,
confidence, content digest, and whether it supports or contradicts a claim. The host computes claim
assessment from the ledger and the compiled investigation contract.

The model may not finish an operational assessment while a required material claim is absent,
unsupported, contradicted without resolution, or stale beyond the contract. It may finish as
blocked only when it names an exact external blocker, attempted routes, and a real unblocking action.

Health verdicts apply only to health questions. Engineering, configuration, runbook, scheduling,
and publication tasks use task-specific completion language instead of being labeled healthy or
degraded.

## 14. Memory architecture

Responder has one memory architecture but not one undifferentiated memory store. Facts, continuity,
evidence, behavior, commitments, and provider state have different trust and retention rules.

### 14.1 Memory taxonomy

| Subsystem | Incorporated current data | Role |
| --- | --- | --- |
| Working context | Recent Slack messages, attachments, reactions | Bounded input for one execution |
| Context manifests | Frozen agent-run context | Exact record of what informed a turn |
| Episodic memory | Conversation summaries, episode events, timelines | What happened in conversations and work |
| Semantic memory | Confirmed memory entries and service graph | Durable organizational knowledge |
| Evidence ledger | Evidence, coverage, claim assessments | Source-attributed support for conclusions |
| Behavioral policy | Preferences and standing rules | Deterministic configured behavior |
| Execution state | Goals, commitments, schedules, subscriptions | Work owed by Responder, not reusable facts |
| Runtime checkpoints | Coop session IDs and generations | Provider continuity only |

### 14.2 Knowledge entries

Confirmed semantic memory evolves into versioned assertions with:

- workspace, scope, and visibility;
- subject, predicate, and typed value;
- source reference and source revision;
- actor and confirmation record;
- confidence and authority rank;
- valid-from, observed-at, expiry, and review times;
- active, stale, contradicted, or superseded state;
- recall counters and downstream references.

Multiple contradictory assertions may coexist. Higher-authority or fresher sources affect retrieval,
but history is retained so an old episode can reconstruct what was known at that time.

### 14.3 Conversation continuity

Conversation summaries remain derived projections. They retain goal, situation, decisions, open
loops, unresolved questions, referenced evidence, and participants. Related summaries are selected
by service graph, repository, channel, visibility, and recency rather than copied into another
store.

Coop session checkpoints are separated from conversation memory. Rotating or discarding a provider
session cannot delete organizational continuity.

### 14.4 Memory precedence

Context assembly uses this precedence:

1. fresh authoritative live evidence;
2. current repository and service graph state;
3. current Responder configuration and authority;
4. target conversation and active episode;
5. operator-confirmed knowledge;
6. related summaries and rollups;
7. older evidence, explicitly marked stale.

Memory never proves current health, contains credentials, grants approval, or authorizes a change.

### 14.5 Compaction and review

Compaction is a deterministic projection pipeline:

```text
messages -> conversation summary
conversation summaries -> weekly continuity rollup
episode events -> outcome summary
repeated graph assertions -> refreshed graph edge
```

Rollups retain source references. Compaction does not rewrite confirmed operator memory, promote
model prose into facts, or silently change behavior. Stale and duplicate knowledge produces review
items for operators. Forgetting removes the active value but retains non-sensitive hashes required
for audit and idempotency.

## 15. Context manifests

Every model execution and published conclusion has an immutable context manifest containing:

- target Slack root, nearby messages, edits, reactions, and files;
- relevant conversation and episode summaries;
- knowledge and preferences recalled;
- service graph nodes and provenance;
- repositories, paths, and exact revisions;
- investigation contract and required claims;
- available tool schemas and immutable pack references;
- recorded evidence and freshness;
- prompt, result schema, execution profile, model, provider, and reasoning configuration;
- inputs omitted because of privacy, expiry, retrieval score, or size limits.

Large content is content-addressed and referenced rather than copied repeatedly. The manifest itself
is bounded and safe to inspect. It enables exact replay and an operator-facing "why this answer"
diagnostic without exposing hidden reasoning or raw credentials.

## 16. Slack adapter architecture

Slack is an adapter around the channel-neutral application kernel. It should be separated into:

- `slack/inbound`: Socket Mode messages, commands, buttons, reactions, edits, joins, files, and app
  lifecycle events into canonical events;
- `slack/outbound`: semantic message, status, file, reaction, and control intents into Block Kit and
  Slack API requests;
- `slack/gateway`: Web API calls, scopes, pagination, timeouts, rate limits, upload and download;
- `slack/delivery`: outbox consumption, idempotency, reconciliation, revision protection, and retry;
- `slack/context`: bounded target-centered history, thread reconstruction, reactions, edits, and
  attachments;
- `slack/admin`: channels, members, invitations, App Home, and configuration surfaces.

Do not replace the current broad Slack API with another broad `ChatPlatform` abstraction. Define
narrow ports around stable capabilities such as `ConversationReader`, `MessagePublisher`,
`StatusPublisher`, `AttachmentStore`, `MemberDirectory`, and `ChannelAdministrator`.

Slack-specific features remain explicit optional capabilities. A future platform can implement the
canonical event and effect contracts without forcing Slack behavior into the domain.

## 17. Progress and communication

Progress is a typed episode event, not arbitrary narration. Useful progress triggers include:

- the evidence plan is established;
- a goal begins or completes;
- a material hypothesis changes;
- an important finding is verified;
- a dependency or tool becomes unavailable;
- approval or operator input is required;
- a long-running investigation exceeds its quiet interval;
- verification begins or finds a regression.

Two Slack surfaces are used together:

- native status for frequent lightweight phase updates;
- durable thread messages for meaningful findings, changed decisions, blockers, and approvals.

The communication policy throttles and deduplicates updates. It must not publish raw tool output,
hidden reasoning, repetitive safety disclaimers, or routine "still working" messages.

The episode first produces a semantic communication intent such as finding, progress, blocker,
question, decision, or completion. A communication policy then selects location, detail, formatting,
reaction, tone, and humor level. Personality affects phrasing only.

Serious mode is mandatory for active incidents, security, destructive operations, approvals,
customer impact, failed actions, and material uncertainty. Relaxed conversations may use one
meaningful emoji or understated humor when it does not distract from the answer.

## 18. Durable subscriptions

The subscription manager turns external lifecycle events into episode events:

```text
PR opened -> checks -> review -> merge
deployment started -> rollout -> verification
Terraform planned -> approved -> applied
Emisar approval -> execution -> verification
scheduled check -> result -> next occurrence
```

Subscriptions record an exact binding such as PR number, head SHA, branch, Terraform run ID,
Emisar run ID, deployment revision, or immutable source event. The model may suggest correlation,
but the host accepts it only when exact identifiers match recorded state.

Subscriptions survive restarts. They are deduplicated, expire when their episode is terminal and no
follow-up remains, and do not require a Coop process to wait continuously.

## 19. Backpressure and failure recovery

Database-backed work lanes provide fair scheduling and prevent one long investigation from
blocking Slack controls or unrelated work.

Required properties include:

- per-conversation and per-episode serialization;
- workspace, profile, and external-provider concurrency limits;
- lease tokens and fencing revisions;
- deterministic idempotency keys;
- exponential retry with jitter for transient failures;
- circuit breakers for failing external systems;
- operator-visible pause or blocker only when action is required;
- automatic resumption after provider recovery;
- one failure message at most for a logical failure generation;
- dead-letter inspection without silently abandoning accepted commitments;
- no arbitrary agent-turn ceiling for decision-ready work.

Resource exhaustion pauses lower-priority goals rather than failing them. Interactive controls,
approvals, and cancellation remain responsive. Retry state is visible in diagnostics but does not
spam the public conversation.

### 19.1 Ownership-based cleanup

Garbage collection is derived from durable ownership and terminal lifecycle state. Responder may
clean only sessions, forks, artifacts, temporary files, deliveries, subscriptions, and projections
whose exact owner episode or execution attempt is recorded.

Cleanup rules include:

- never discard dirty or unpublished repository work;
- never identify owned Coop sessions or forks by name prefix alone;
- retain artifacts referenced by an active episode, publication, approval, replay fixture, or audit;
- close idle provider sessions while preserving conversation summaries and episode state;
- remove expired attachment bytes after their manifest and digest are durable;
- expire subscriptions only after their goals are terminal and no verification remains;
- compact events only through a versioned snapshot that can be verified against replay;
- delete channel-scoped knowledge and summaries when Slack confirms channel deletion;
- keep cleanup retryable and idempotent after restart;
- expose retained work and the reason it cannot yet be collected.

## 20. Authority and safety boundaries

Authority is checked at goal creation, execution, and effect time.

| Operation | Required boundary |
| --- | --- |
| Read Slack or repository context | Configured visibility and read-only policy |
| Query live infrastructure | Coop policy plus governed tool policy |
| Prepare repository changes | Confirmed writable engineering goal and isolated fork |
| Publish a draft PR | Exact reviewed tree plus publication policy |
| Execute an operational action | Explicit operator request plus Emisar policy |
| Approve an action | Emisar only; never Slack or Responder |
| Merge or deploy | External workflow unless explicitly introduced later |

A service graph edge, memory entry, standing assignment, schedule, consult, or previous approval
cannot widen these boundaries.

## 21. Storage model

The target database contains typed source tables plus the event and effect backbone:

- `inbox_events` for admitted external events and deduplication;
- `episodes` for current reduced state and revision;
- `episode_events` for append-only product history;
- `goals` and `goal_dependencies` for the DAG;
- `execution_attempts` for Coop and deterministic worker attempts;
- `claims`, `evidence`, and `claim_assessments`;
- `context_manifests` and content-addressed manifest objects;
- `knowledge_entries`, supersessions, recalls, and reviews;
- `conversation_summaries` and continuity rollups;
- `graph_nodes`, `graph_edges`, and graph source observations;
- `preferences` and `standing_assignments`;
- `planned_executions`, `subscriptions`, and occurrence records;
- `outbox_effects` and delivery reconciliation;
- `runtime_checkpoints` for Coop sessions and provider cursors;
- `runtime_versions` for prompt, contract, schema, preset, model, and tool versions.

Existing specialized tables may remain during migration. New generic tables must not become JSON
dumping grounds: stable domain fields remain queryable and constrained, while versioned payloads
hold bounded extension data.

## 22. Observability and operator diagnostics

Each episode exposes an inspectable trace:

- current state, revision, and active goals;
- accepted user instructions and normalized outcomes;
- active authority and execution profile;
- context manifest ID;
- evidence coverage and unresolved contradictions;
- execution attempts, retries, and exact blockers;
- outstanding subscriptions and next planned executions;
- delivered messages and effect idempotency keys;
- runtime versions used for each model execution.

Metrics should cover queue latency, time to acknowledgement, time to first useful finding, time to
decision-ready completion, retry rate, provider failures, duplicate prevention, intervention
precision and recall, abandoned commitments, evidence coverage, correction rate, progress utility,
and verified resolution.

Logs must contain stable workspace, episode, goal, attempt, source event, and effect IDs without
including secrets, raw private Slack content, signed URLs, or unbounded model output.

## 23. Versioning and exact replay

Every execution records a `RuntimeVersion`:

```text
Responder build
prompt template and digest
investigation contract version
result operation schema version
context manifest schema version
Coop API and preset digest
provider, model, effort, and account alias
tool schemas and immutable pack references
Slack renderer revision
communication policy revision
```

Schema migrations preserve readers for retained historical events. A replay either uses the exact
historical version or explicitly records that it is a counterfactual run using a newer version.

## 24. Existing capability preservation requirements

The migration must preserve the current product surface. A new architecture component is not a
replacement until the corresponding end-to-end behavior below passes through it.

| Existing capability | Required preserved behavior |
| --- | --- |
| Signed webhook admission | Authenticate, deduplicate, correlate firing and recovery, and retain source links safely |
| Slack Socket Mode | Persist before acknowledgement and recover after reconnect or restart |
| Mentions and direct requests | Respond in the correct conversation without forcing an incident |
| Proactive and shadow participation | Use context-aware engagement, avoid human conversations, and suppress shadow effects |
| App-alert triage | Investigate credible alerts deeply enough for a useful decision rather than restating payloads |
| Reactions | Observe and emit meaningful reactions without treating them as arbitrary authority |
| Thread and channel movement | Follow explicit conversation-location requests and keep subsequent work coherent |
| Old-thread context | Reconstruct root, relevant replies, files, edits, reactions, and compact continuity |
| Files and screenshots | Authenticate, bound, type-check, deliver to Coop, and retain only as policy permits |
| Generated charts and images | Validate artifacts, upload once to the same conversation, and reconcile uncertain sends |
| Native progress status | Start promptly, update semantically, survive restart, and clear only after durable outcome |
| Multipart replies | Preserve ordered outcomes in one destination and attach controls only where relevant |
| Channel setup | Support buttons and conversation, follow the operator between thread and channel, and confirm before saving |
| Slash commands and App Home | Keep deterministic status, configuration, memory, schedule, incident, and failure controls |
| Incidents | Correlate signals, optionally create dedicated rooms, invite validated audiences, and maintain timelines |
| In-thread engineering tasks | Confirm writable transition, isolate work, show diff, review, publish draft PR, and follow lifecycle |
| Repository sets | Use one writable primary and pinned read-only companions with explicit identity |
| Draft PR publication | Publish the exact reviewed tree with lease protection and never merge or deploy |
| Emisar operations | Discover current actions, preserve immutable request identity, link approvals, and verify terminal outcome |
| Evidence and coverage | Preserve source, target, time, freshness, contradictions, and completion validation |
| Conversation continuity | Carry target and related summaries without leaking private-channel context |
| Confirmed memory | Require operator confirmation, scope and expire entries, and preserve review and forgetting controls |
| Preferences | Resolve typed behavior by configured precedence without granting authority |
| Standing rules | Match typed triggers deterministically, execute idempotently, and remain read-only unless separately authorized |
| Schedules | Confirm typed schedules, preserve timezone semantics, avoid overlap, resume after restart, and support run-now/edit/pause/delete |
| Commitments | Show accepted work, progress, blocker, and completion without treating execution state as factual memory |
| External follow-ups | Correlate PR, deployment, Terraform, approval, and verification events back to the original episode |
| Coop supervision | Preserve authenticated provider accounts, private configuration, prewarming where policy permits, and process cleanup |
| Managed cleanup | Collect only exact owned state, preserve unpublished work, and bound retained storage |
| Multiple workspaces | Keep credentials, state, Coop policy, database, memory, and visibility isolated per deployment |

Behavioral copy may improve, and obsolete implementation details may disappear, but the user outcome
and authority boundary must remain. A migration PR identifies the rows it changes and links their
new automated proof.

## 25. Test and evaluation strategy

No single test layer proves the product. The release gate combines deterministic component tests,
state-machine invariants, recorded historical episodes, real-model evaluation, failure injection,
performance tests, and a small live canary.

### 25.1 Component unit tests

Pure domain tests cover:

- every valid state transition;
- rejection of stale, duplicate, impossible, or authority-widening events;
- goal DAG cycle detection and readiness;
- completion assessment from claims and evidence;
- visibility and retrieval precedence;
- knowledge contradiction and supersession;
- communication throttling and serious-mode selection;
- schedule and subscription trigger evaluation;
- effect idempotency derivation.

Use table-driven and property-based tests. Reducer tests should generate event sequences and assert
that replaying the same sequence always produces the same state.

### 25.2 Adapter conformance tests

Slack adapter tests cover:

- raw Socket Mode fixtures to exact canonical events;
- threads, channel posts, edits, deletions, reactions, joins, buttons, commands, and app messages;
- target-centered history and old-thread reconstruction;
- attachment authorization, type validation, size limits, download, and cleanup;
- canonical message intents to bounded valid Block Kit;
- status start, update, clear, restart recovery, and stale-generation rejection;
- rate limits, pagination, missing scopes, timeouts, disconnects, and partial history;
- duplicate input, duplicate delivery, uncertain send, and update-after-retry reconciliation;
- explicit movement between thread and channel.

Equivalent contract suites cover Coop, Emisar, GitHub, Terraform, repository workspaces, and
storage. Network adapters use recorded protocol fixtures and controllable fake servers.

### 25.3 Application contract tests

Application tests use fake ports and a real database transaction boundary to prove:

- inbox admission and acknowledgement ordering;
- event append, reduction, and outbox enqueue atomicity;
- conversation serialization and independent-channel concurrency;
- resumable agent attempts;
- compound goal preservation;
- progress and final message routing;
- approval, publication, subscription, and schedule continuation;
- backpressure without public failure spam;
- workspace and private-channel isolation;
- cleanup that never discards unpublished work.

### 25.4 Historical Slack corpus

Responder should import historical Slack behavior into a private encrypted corpus. Import is
restricted to explicitly allowed workspaces, channels, and time ranges.

The importer captures:

- channel and thread message order;
- edits, deletions, reactions, and app subtypes;
- files and authorized file bytes when permitted;
- timestamps and actor classes;
- Responder inputs, deliveries, episode events, evidence, and execution attempts;
- Coop turn and context manifest identifiers;
- operator corrections, repeated questions, negative reactions, and abandoned threads;
- original outcome and later lifecycle events.

Sensitive fields are redacted or replaced with stable pseudonyms. Tokens, signed URLs, credentials,
and unrelated private content are never written to checked-in fixtures. Raw captures are encrypted,
access-controlled, retention-bounded, and excluded from the public repository.

Two corpus layers are maintained:

1. a private immutable capture for forensic and counterfactual replay;
2. a minimized sanitized regression case checked into `testdata/eval` for each distinct product bug.

### 25.5 Episode fixture format

A fixture contains:

```yaml
id: stable-case-id
source:
  workspace: pseudonym
  conversation: pseudonym
  captured_at: 2026-08-03T00:00:00Z
runtime:
  responder: version
  prompt: digest
  contract: version
events: []
attachments: []
repository_snapshots: []
recorded_tool_results: []
expected:
  hard_invariants: []
  required_outcomes: []
  forbidden_outcomes: []
  behavioral_rubric: {}
```

Events and tool results are ordered, content-addressed, bounded, and sanitized. Tool recordings
include observation time and target identity. A fixture without historical tool results cannot make
assertions about the factual correctness of a historical production conclusion.

### 25.6 Replay modes

#### Deterministic host replay

No model and no live tools. Replays canonical events through reducers, policies, routing, effects,
renderers, and fake adapters. It proves ordering, state, authority, idempotency, attachments, controls,
and recovery.

#### Frozen-world real-model replay

Uses the configured real model through Coop with recorded sanitized tool results and a frozen clock.
It tests judgment and communication against a reproducible world. Live tool calls are forbidden.

#### Counterfactual historical replay

Runs a newer Responder version against an old captured episode and compares actions, claims,
messages, and completion with the original. It reports improvements and regressions without posting
to Slack.

#### Shadow production replay

Processes newly arriving production events through the candidate version without effects. Proposed
engagement, goals, evidence routes, and messages are stored for comparison with the active version.

#### Live canary

Uses the real Slack workspace, Coop, model, and read-only tools. It may post only in the explicitly
configured `#emisar-test` channel. Destructive actions, approval grants, production mutations, and
arbitrary channel posting are excluded.

### 25.7 Historical label mining

The corpus builder should identify likely regressions from operator behavior:

- "why did you" or "you should have" corrections;
- requests to move to a thread or channel;
- repeated questions after no useful response;
- reattached screenshots or pasted IDs after context loss;
- stale or ineffective button reports;
- negative reactions or reaction removal;
- long unexplained delays;
- Responder failures followed by manual operator investigation;
- claims later contradicted by authoritative evidence;
- accepted work with no completion or follow-up.

A model may propose a label and minimized scenario, but a human confirms the expected behavior before
it becomes a release-gating golden case.

### 25.8 Hard invariants

Hard invariants pass on every run:

- no cross-workspace or unauthorized private-channel context;
- no wrong-thread or wrong-channel reply;
- no lost eligible attachment;
- no duplicate public response, task, schedule, action, or publication;
- no stale button effect;
- no unauthorized mutation or authority widening;
- no unsupported success, health, root-cause, or approval claim;
- no final answer before required completion coverage or exact blocker;
- no accepted commitment silently abandoned;
- no public retry spam;
- no effect after cancellation or supersession;
- exact event ordering and deterministic state replay;
- every published conclusion has a context manifest and evidence references.

### 25.9 Behavioral evaluation

Real-model judges score observable behavior rather than hidden reasoning:

- correct engagement and addressee inference;
- investigation completeness;
- decision usefulness;
- directness and concision;
- natural human tone and conversation fit;
- meaningful progress and absence of repetitive progress;
- response-location correctness;
- appropriate use of reactions, formatting, and humor;
- precise blockers and useful next actions;
- productive completion of multi-step work;
- evidence discipline and uncertainty calibration.

Use multiple samples for nondeterministic model behavior. Hard invariants require 100 percent. Soft
scores require a per-case pass threshold, aggregate threshold, and bounded regression from the
previous release baseline.

Judge calibration includes human-labeled good and bad examples. A judge version cannot gate a
release until it separates concise useful answers from bureaucratic, repetitive, unsupported,
misrouted, or internally focused responses.

### 25.10 Failure injection

Tests must inject failures at every external boundary:

- Slack accepts a message but times out before returning;
- Slack rate limits, disconnects, or returns incomplete history;
- Coop returns a transient error, closes a child, exceeds one transcript, or restarts;
- a model result operation is malformed halfway through a program;
- Emisar requires approval, expires approval, or reports an uncertain operation;
- GitHub checks regress, a PR closes, or a branch lease conflicts;
- Terraform emits stale, duplicated, or out-of-order lifecycle messages;
- repository companions are missing or revisions move;
- SQLite restarts after event append but before effect delivery;
- the process stops during every lifecycle phase.

The required outcome is resume, exact blocker, or one bounded failure notice. Losing accepted work or
posting repeated public errors is always a failure.

### 25.11 Performance, load, and fairness

Load tests cover:

- many simultaneous channels and workspaces;
- bursts of app alerts and Slack replies;
- long deep investigations beside interactive controls;
- large but bounded threads and attachments;
- subscription storms after a deployment;
- scheduled tasks firing at the same minute;
- provider degradation and recovery;
- memory and graph retrieval under retention pressure.

Measure acknowledgement latency, queue wait, time to first useful progress, effect delivery,
database contention, retry amplification, and fairness between workspaces. Deep work has no forced
short completion target, but interactive acknowledgement and cancellation have strict latency
budgets.

### 25.12 Security and privacy testing

Tests verify:

- tenant and private-channel isolation at query level;
- prompt injection in Slack app payloads, files, repositories, and tool output;
- secret and signed-URL redaction;
- file authorization and deletion;
- authority checks at planning, execution, and effect time;
- stale memory and graph facts cannot override current evidence;
- consults receive no context outside their profile visibility;
- exports and replay fixtures contain no raw secrets or disallowed content.

### 25.13 Release gate

A production release or model, prompt, contract, tool, preset, or communication-policy change must
pass:

1. formatting, static analysis, race tests, vulnerability checks, and production build;
2. component and adapter conformance suites;
3. state-machine and property tests;
4. application contract and failure-injection tests;
5. sanitized historical deterministic replay;
6. frozen-world real-model replay with variance thresholds;
7. proactive engagement precision and recall gate;
8. evidence verification and productivity evaluation;
9. judge calibration and human-quality threshold;
10. performance regression bounds;
11. private counterfactual Slack corpus comparison;
12. a small live canary restricted to `#emisar-test`.

The release report records corpus digest, runtime versions, case pass distribution, hard invariant
failures, behavioral regressions, and accepted waivers. A changed corpus invalidates the previous
statistical baseline.

## 26. Migration plan

Migration is incremental. Each phase keeps the current product usable and has an explicit rollback
path.

### Phase 0: Freeze current behavior and collect evidence

Deliverables:

- inventory all current user-visible workflows and memory layers;
- assign stable IDs to existing regression cases;
- add sanitized cases for every known Slack failure reported during dogfooding;
- capture current quality, latency, proactivity, and reliability baselines;
- implement the private Slack corpus importer in read-only mode;
- document current database ownership and duplicate state transitions.

Exit criteria:

- all current critical paths have at least one deterministic journey;
- historical cases reproduce known failures against the appropriate old version or fixture;
- the corpus contains no secrets or disallowed private data;
- no architecture migration has changed production behavior.

### Phase 1: Canonical events and Slack adapter boundaries

Deliverables:

- introduce canonical conversation, actor, content, event, and intent types;
- move Socket Mode normalization behind inbound ports;
- move rendering and controls behind outbound ports;
- split the Slack gateway and delivery reconciliation;
- replace broad Slack API usage with narrow capability ports;
- add adapter conformance and import-boundary tests.

Exit criteria:

- the domain and new application packages import no Slack types;
- recorded Slack fixtures produce byte-for-byte equivalent canonical events;
- rendered surfaces pass size, action, URL, accessibility, and fallback checks;
- current customer journeys and live canary remain green.

Rollback:

- retain the existing service orchestration while new adapters can translate back to current input
  and message types.

### Phase 2: Authoritative episode event stream

Deliverables:

- define the complete episode event catalog and versioning rules;
- make the pure reducer the only writer of episode state;
- project commitments, native status, controls, and next action from events;
- add transactional inbox, event append, and outbox enqueue;
- migrate stale-button and delivery generation checks to episode revision.

Exit criteria:

- rebuilding projections from events matches stored current state;
- crash tests at every transition produce one eventual effect;
- commitments cannot diverge from episode state;
- duplicate and stale events are harmless.

Rollback:

- compare event-derived projections with existing tables in shadow mode before switching reads.

### Phase 3: Goal DAG and planned executions

Deliverables:

- normalize compound instructions into typed outcomes;
- persist goals and dependencies;
- attach schedules, approvals, external waits, and verification to goal nodes;
- generate child episodes for recurring occurrences;
- project progress from goal and episode events.

Exit criteria:

- compound-message evals account for every explicit instruction;
- independent goals can progress without reordering the conversation;
- scheduled and approval-gated work resumes through the same execution pipeline;
- no schedule or follow-up displays unrelated engineering controls.

### Phase 4: Context manifests and memory consolidation

Deliverables:

- persist immutable manifests for every execution and conclusion;
- split conversation summaries from runtime checkpoints;
- introduce versioned knowledge assertions and visibility-safe retrieval;
- migrate rollups, recalls, reviews, preferences, and rules;
- evolve standing rules into standing assignments backed by goal templates;
- add contradiction and supersession handling.

Exit criteria:

- every model execution can be replayed from its manifest and recorded tools;
- current and new retrieval results agree in shadow comparison or differences are reviewed;
- private context never crosses visibility boundaries;
- memory compaction preserves source references;
- operator-confirmed memory is never silently rewritten.

Rollback:

- retain old tables read-only and dual-read in diagnostics until retention and replay prove parity.

### Phase 5: Service graph and repository orchestration

Deliverables:

- ingest graph assertions from configured authoritative sources;
- expose provenance, freshness, contradiction, and visibility;
- use graph retrieval for tool, repository, owner, and context selection;
- formalize repository sets and companion snapshots;
- implement parent and child episodes for cross-repository writable work.

Exit criteria:

- graph selection is explainable from source assertions;
- stale graph data cannot override repository or live evidence;
- cross-repository changes produce separate reviewed diffs and coordinated completion;
- repository cleanup cannot discard another episode's work.

### Phase 6: Execution profiles and Coop consults

Deliverables:

- define workspace-allowlisted execution profiles;
- pass resolved Coop preset and profile metadata through the API;
- allow typed consult requests with budget and visibility checks;
- record lead, peer, model, account alias, effort, and preset digest;
- add profile selection and consult evaluation cases.

Exit criteria:

- ordinary conversation, deep operations, and engineering work resolve to intended profiles;
- consults cannot widen authority or visibility;
- profile changes are exactly replayable;
- latency and cost remain inside workspace budgets.

### Phase 7: Durable lifecycle subscriptions

Deliverables:

- unify GitHub, Terraform, deployment, Emisar, and scheduled follow-ups;
- attach exact external identifiers to subscriptions;
- resume the owning goal from lifecycle events;
- expose active subscriptions, missed events, and next verification;
- expire terminal subscriptions safely.

Exit criteria:

- PR merge, deployment, and post-deployment verification update the original thread once;
- stale or unrelated external messages cannot attach to an episode;
- restart and redelivery do not lose or duplicate lifecycle updates.

### Phase 8: Backpressure, diagnostics, and release enforcement

Deliverables:

- implement workspace fairness, circuit breakers, and resumable pause states;
- expose episode diagnostics and context-manifest inspection;
- complete private historical counterfactual replay;
- enforce the full model and product release gate;
- remove superseded service paths and tables after retention.

Exit criteria:

- provider outages create no public message storms;
- accepted commitments survive long outages and resume;
- operators can explain every active episode and effect;
- the full historical corpus and canary pass before deployment;
- `internal/service` no longer owns provider-specific orchestration across unrelated workflows.

## 27. Migration rules

The following rules apply to every phase:

- add tests before moving behavior;
- preserve unrelated work and existing database data;
- do not claim parity from unit tests alone;
- shadow-read or shadow-project before switching authority;
- keep one source of truth for each product fact;
- never dual-write indefinitely;
- record runtime and schema versions on new events;
- include forward and rollback migrations;
- update this document when a design decision changes;
- add every production correction as a minimized regression case.

## 28. Quality targets

Long-term product targets are:

- zero authority-boundary violations;
- zero unsupported success claims;
- zero abandoned accepted commitments;
- zero duplicate externally visible effects for one idempotency key;
- under 1 percent premature final answers in the gated corpus;
- under 2 percent regretted proactive interventions;
- over 95 percent recall where a strong teammate should intervene;
- over 90 percent of durable progress messages rated useful;
- bounded acknowledgement latency even while deep work is running;
- exact replay coverage for every high-severity production regression;
- every production conclusion traceable to a context manifest and evidence ledger.

Targets are gates only after the corpus is sufficiently representative and judge calibration is
stable. Until then, report both absolute results and confidence intervals rather than optimizing to
a misleading single score.

## 29. Deliberate non-goals

This architecture does not introduce:

- a second model runtime outside Coop;
- autonomous merge or deployment authority;
- Slack-based approval of Emisar operations;
- unrestricted prose-to-automation conversion;
- one global writable checkout containing unrelated repositories;
- an unscoped organizational memory visible across private channels or workspaces;
- raw hidden reasoning or tool transcripts in Slack;
- microservices solely for package-level separation;
- a health verdict requirement for non-health work;
- a fixed turn limit as the normal deep-work completion rule.

## 30. Open design decisions and recommended defaults

| Decision | Recommended default |
| --- | --- |
| Database during migration | SQLite with transactional inbox and outbox |
| Event payload format | Versioned typed columns plus bounded JSON extension |
| Artifact storage | Content-addressed local private store with retention; object storage later |
| Historical corpus | Encrypted private raw capture plus minimized checked-in fixtures |
| Graph refresh | Event-driven where possible, bounded periodic reconciliation otherwise |
| Consult selection | Host allowlist; model request with explicit reason |
| Cross-repository writes | Parent episode plus one isolated child fork per repository |
| Progress cadence | Event-driven, with configurable quiet-interval fallback |
| Live tests | Only an explicitly configured test channel such as `#emisar-test` |
| Humor | Restrained and contextual; disabled for serious-mode situations |
| Old table removal | After shadow parity, replay parity, and retention window |

## 31. First implementation slice

The first code change after this document should be deliberately narrow:

1. define `ConversationRef`, `InteractionEvent`, and semantic outbound intents;
2. add Slack inbound fixture tests using captured sanitized payloads;
3. add Slack outbound renderer conformance tests;
4. adapt one ordinary mentioned-message path through the new ports;
5. run the same path in shadow comparison with the existing implementation;
6. add one historical bug fixture involving thread context and an attachment;
7. prove identical routing, context, delivery, and retry behavior;
8. expand one workflow at a time only after the comparison is green.

This slice creates a tested boundary without prematurely rewriting the episode, memory, scheduling,
or publication systems. Subsequent work can then move behind that boundary with reliable regression
evidence.

## 32. Definition of architectural completion

The architecture migration is complete when:

- external providers are reachable only through tested adapters;
- domain and application behavior is platform-neutral;
- every accepted work item is an event-sourced episode with a goal DAG;
- progress, controls, commitments, schedules, approvals, and subscriptions are projections of the
  same lifecycle;
- every execution and conclusion has a context manifest and runtime version;
- memory, evidence, behavior, execution state, and provider checkpoints have distinct ownership;
- service and repository relationships are provenance-backed graph assertions;
- cross-repository work has explicit child goals and independent review boundaries;
- Coop presets and consults are selected through typed execution profiles;
- historical Slack cases are reproducible through deterministic and real-model replay;
- release gating includes component, invariant, historical, behavioral, performance, security, and
  live-canary proof;
- no superseded parallel orchestration path remains in `internal/service`.

At that point Responder will not be bug-free, but failures will be bounded, replayable, attributable,
and much less likely to recur after a fix. That is the practical standard required for a dependable
operational teammate.
