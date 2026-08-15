# Responder Target Architecture and Verification Plan

Status: episode-kernel implementation landed; compatibility retirement remains,
       and is now waiting on evidence rather than on work (the unused effect
       ledger was retired in schema 40; attempts, goals, manifests, and wakeups
       remain in use beside the legacy agent-run path)
Last updated: 2026-08-06
Audience: Responder maintainers, operators, and contributors

This document defines the architecture Responder should evolve toward. It is more prescriptive
than [Architecture](architecture.md), which describes the deployed system, and more
implementation-oriented than [How Responder Works](how-responder-works.md), which explains current
product behavior.

The goal is not to preserve the current implementation shape. The goal is to preserve every useful
product capability while replacing competing lifecycles with one reliable ownership model. A
migration phase is complete only after the historical regressions and release gates in this
document prove its behavior.

### Current implementation boundary

Schema version 41 carries the episode-first kernel described here. (40 removed
the effect ledger; 41 moved product feedback out of its own database and into
this one, where it is covered by the schema baseline, the verified
pre-migration backup, and ordinary cross-table transactions.) The parts
that are live today are attempts, goals, context manifests, and wakeups; the
effect ledger was removed in schema 40 because no caller ever planned, leased,
or completed an effect, and the `work_items` scheduler already owns delivery
with the same fencing and retry guarantees.

The kernel still runs beside the legacy `agent_runs` path rather than replacing
it: `internal/service/result_operations.go` folds typed operations back into
the older free-text fields so both shapes stay readable. That fold is the
remaining compatibility seam and the next thing to retire.

**The fold is retired.** The evidence came from replaying history rather than
waiting for it: `responder audit-result-protocol` re-reads stored model results
through the parser each run's mode actually used. Across 259 real production
turns the result was 187 typed, 72 plain prose, and zero fallbacks — with the
non-zero prose count as the check that the measurement worked at all. An invalid
operation stream is now a correction the model is told about rather than a
silent second reading of whatever prose sat beside it.

That unblocked the rest. `internal/decision` now owns the result shapes, their
parsers, validators and correction rules; `internal/investigation` owns the
completion rules beside the contract they check; and `internal/service` has
dropped from 27,180 to 23,743 code lines with publication, schedule, memory and
channel setup extracted behind their own boundaries.

Two things that do not need the window have landed in the meantime.
`internal/episode_replay_coverage_test.go` parses the capability matrix in
section 24 out of this document and fails the build if a capability has neither
a replay fixture nor an explicitly acknowledged gap — so the rule in section 24,
that no migration may remove a capability whose replacement is unproven, is now
enforced rather than stated. It currently measures **2 of 24 capabilities
proven**. And `responder record-episode` turns a completed episode into a
sanitized fixture, so that number can move without waiting on a history export.

The kernel establishes:

- episodes own lifecycle state, modes, destinations, revisions, goals, attempts, context-manifest
  lineage, effects, and wakeups;
- replacement attempts resume the same episode after timers, approvals, and external waits;
- required goals prevent premature completion;
- context manifests freeze prompt, contract, tool-schema, repository revisions, policies,
  artifacts, and source context for exact replay;
- model results support independently validated goal, evidence, progress, wait, approval, artifact,
  memory, configuration, and completion operations;
- Slack text and file deliveries are pinned to an episode destination revision, and a committed
  destination change supersedes output aimed at the old location;
- scheduled occurrences and standing assignments create episode-owned work;
- wakeup leases use fencing tokens, semantic idempotency, and retry state.

The existing `agent_runs`, incident records, Slack delivery rows, commitment rows, and final result
envelopes remain compatibility projections while their callers migrate. They no longer define the
new lifecycle, but they cannot be removed until the historical corpus, adapter conformance suites,
and live canaries prove every current capability. This is an intentional deployable cutover rather
than an indefinite second architecture.

## 1. Product objective

Responder should behave like a persistent operational teammate:

> It notices important things, decides when it can help, works until it has a decision-ready result,
> communicates naturally while working, remembers commitments and organizational context, and never
> confuses initiative with authority.

The product is not primarily a chatbot, incident-room generator, workflow engine, or thin wrapper
around a model. It is a durable operational work system with:

- Slack as its main human interface;
- Coop as its model execution and isolated engineering-work boundary;
- Emisar and other tools as governed evidence and operational-action boundaries;
- repositories and infrastructure definitions as authoritative implementation context;
- a transactional local database as the durable episode, inbox, outbox, and continuity store.

Success means Responder can:

- understand a conversation without assuming every nearby message addresses it;
- decide whether to remain silent, react, answer, investigate, prepare work, or request approval;
- acknowledge quickly and continue until the requested decision is actually supported;
- handle several instructions in one message without silently dropping one;
- expose meaningful progress without repetitive status noise or hidden-reasoning dumps;
- survive restarts, provider failures, approvals, schedules, PR transitions, and deployments;
- coordinate related repositories without making review or ownership ambiguous;
- recall organizational context across public channels without leaking private conversations;
- use committed Markdown knowledge without duplicating it into another source of truth;
- explain which messages, files, memories, repositories, and evidence informed a result;
- converse like a thoughtful human teammate, including restrained humor when appropriate;
- preserve deterministic permission, approval, publication, and mutation boundaries.

## 2. Final architectural decisions

### 2.1 One durable work aggregate

An `Episode` is the authoritative owner of accepted work. It owns the goals, execution attempts,
bound destination, context manifests, evidence, effects, waits, and outcome.

An episode may represent a conversational answer, proactive investigation, incident, engineering
task, operational action, scheduled check, or follow-up. Those are modes and capabilities of an
episode, not separate root lifecycles.

### 2.2 Event-source the lifecycle, not the whole database

Episode facts are append-only events. A materialized episode snapshot makes ordinary reads cheap.
The event log records product transitions that must survive restarts and support replay; it is not a
generic copy of every SQL mutation.

### 2.3 Models propose; the host decides

The model may propose typed operations. Responder validates state, authority, visibility, evidence,
freshness, destination, size, and idempotency before accepting them. External side effects are
performed only from the transactional outbox.

The model never directly:

- writes durable memory or behavior configuration;
- changes visibility, authority, or approval policy;
- approves an Emisar request;
- creates a schedule, incident room, branch, PR, or deployment;
- selects arbitrary provider credentials;
- changes the Slack destination without a validated reroute operation;
- publishes raw tool output or claims an artifact exists before delivery succeeds;
- declares a conclusion that the claim and evidence ledger does not support.

### 2.4 A modular monolith is the deployment unit

One Go binary and one transactional database remain the default. Modules have narrow ports and
independent tests, but network boundaries are introduced only when measured scale, isolation, or
ownership requires them.

### 2.5 Privacy is structural

Workspace, conversation, repository, actor, and visibility scope travel with every retrievable
object. Retrieval intersects the caller's visibility. Prompt instructions are not a privacy
boundary.

## 3. Architectural center

```text
Slack / Webhooks / GitHub / Terraform / Emisar / Schedules
                         |
                  ingress adapters
                         |
                transactional inbox
                         |
             normalize InteractionEvent
                         |
                 admission policy
                         |
                 Episode aggregate
       goals / attempts / context / evidence / waits
                         |
                 effect planning
                         |
                transactional outbox
             /       |       |       \
          Slack    Emisar   GitHub   Coop
                         |
              result events resume episode
```

Inbound admission, episode-event append, snapshot reduction, and effect enqueue are transactional.
Network calls happen outside that transaction. Effect outcomes return as new normalized events.

## 4. Authoritative kernel

### 4.1 Durable objects

| Object | Ownership and purpose |
| --- | --- |
| `Episode` | Root aggregate for one accepted unit of work |
| `Goal` | One requested outcome, optionally dependent on other goals |
| `Attempt` | One Coop/model execution; always a child of an episode |
| `ContextManifest` | Immutable record of the eligible context used by an attempt |
| `Evidence` | Immutable source-attributed observation supporting a typed claim |
| `Effect` | Idempotent outbox operation with an expected episode revision |
| `Wakeup` | Episode resumption condition: timer, retry, approval, event, or operator input |
| `Schedule` | Recurring template that creates a new child episode for each occurrence |
| `StandingAssignment` | Confirmed event-driven template that creates episodes within a bounded scope |

`ConversationRef` is a value object rather than a lifecycle. It contains platform, workspace,
channel, thread, anchor message, and visibility scope.

Stable operator knowledge and behavior are slower-moving stores, not episode state:

- `Preference` stores typed presentation or investigation preferences;
- `ConfirmedHint` stores bounded operator-confirmed mappings or factual context;
- `GuidanceNote` stores confirmed freeform steering with provenance, visibility, scope, and expiry;
- committed `.agent/kb/`, `.agent/rules/`, runbooks, and repository documentation remain in Git.

### 4.2 Episode identity and revision

Every episode has:

```text
id
workspace_id
conversation_ref
bound_destination
destination_revision
mode
state
revision
authority_snapshot_ref
effort_contract
parent_episode_id
created_at / updated_at / terminal_at
```

The revision increments for every accepted episode event. Effects and interactive controls carry the
revision they were created from. The host refuses effects based on stale state.

### 4.3 Event envelope

```text
EpisodeEvent {
  id
  episode_id
  workspace_id
  revision
  type
  actor
  occurred_at
  causation_id
  correlation_id
  schema_version
  payload
}
```

The initial event catalog should remain small:

- `episode_accepted`
- `destination_bound`
- `destination_changed`
- `goal_planned`
- `goal_started`
- `goal_completed`
- `goal_blocked`
- `attempt_started`
- `attempt_failed`
- `context_extended`
- `evidence_recorded`
- `progress_recorded`
- `operator_input_requested`
- `approval_requested`
- `external_wait_started`
- `wakeup_resolved`
- `effect_planned`
- `effect_succeeded`
- `effect_failed`
- `verification_started`
- `episode_completed`
- `episode_blocked`
- `episode_cancelled`
- `episode_refused`

Add events only when a durable transition cannot be represented by this catalog. Do not create one
event type per SQL table or Slack block.

### 4.4 Transactional storage constraints

The first storage implementation remains SQLite and uses explicit tables for inbox entries, episode
events, episode snapshots, goals, context manifests and references, evidence, effects, delivery
receipts, wakeups, schedules, standing assignments, leases, preferences, hints, and guidance notes.

Required constraints include:

- unique source identity on every inbox event;
- unique `(episode_id, revision)` on episode events;
- atomic append, snapshot update, and effect enqueue;
- unique semantic idempotency key on effects;
- fencing token on every execution lease;
- immutable context-manifest and evidence rows;
- versioned event and operation payloads;
- indexed workspace, visibility, destination, due-time, and ownership columns.

JSON payloads may carry versioned event-specific data, but lifecycle state, authority, identity,
visibility, due time, and idempotency must remain queryable columns. Process-local maps and caches are
never authoritative.

### 4.5 Projections, not competing records

The following are derived from episode events and current effect state:

- current lifecycle state;
- commitments and next actions;
- native Slack status;
- progress and final communication intents;
- interactive controls and their enabled state;
- incident-room and engineering-task cards;
- evidence coverage and claim assessments;
- publication, checks, merge, deployment, and verification state;
- scheduled-run history;
- operator-facing timelines and postmortem drafts.

An incident is an optional escalation label and room artifact attached to an episode. An engineering
task is an episode with a writable repository capability. Neither owns attempts, deliveries, or
follow-ups. An incident timeline and postmortem are evidence-backed projections of episode events,
external lifecycle observations, operator annotations, and verified effects; they are not another
mutable incident record.

## 5. Episode state machine

```text
accepted
   |
   v
planning
   |
   v
working <-------------------------+
   |                               |
   +--> waiting_operator ----------+
   +--> waiting_external ----------+
   +--> retrying ------------------+
   |
   v
verifying
   |
   +--> working       more work required
   +--> completed     decision supported
   +--> blocked       exact unresolved blocker
   +--> refused       policy denies requested work
   +--> cancelled     operator cancels
```

### 5.1 State invariants

- Only episode events change state.
- An `Attempt` failure does not make the episode terminal.
- `waiting_operator`, `waiting_external`, and approval states hold no execution lease.
- `completed` requires every required goal to be completed or explicitly excluded by policy.
- `blocked` names the exact missing input, unavailable capability, or exhausted configured budget.
- `refused` names the deterministic policy boundary and does not imply technical failure.
- Terminal episodes reject new effects; a follow-up creates a child episode or an explicit reopen
  event under operator control.

### 5.2 Attempts and continuation

An episode owns zero or more attempts. A transcript limit, provider crash, rate limit, child exit,
tool outage, or process restart records `attempt_failed`, classifies the blocker, and schedules a new
attempt or wakeup.

There is no normal fixed turn count. Governance uses workspace concurrency, spend, quiet intervals,
deadlines, and operator-visible pause states. A configured deadline pauses or blocks the episode
cleanly; it does not turn normal deep work into an opaque public error.

### 5.3 Admission and execution concurrency

Inputs are serialized only while they are deduplicated, attached to an episode, reduced, and
enqueued. That lock should last milliseconds.

Execution uses a per-episode lease with fencing tokens. A long investigation does not block a short
question in the same channel. Workspace and provider pools enforce fair bounded concurrency across
episodes.

## 6. End-to-end processing loop

1. Persist and deduplicate the inbound platform event before acknowledgement.
2. Normalize it to an `InteractionEvent` with actor, workspace, conversation, attachments,
   reactions, edits, blocks, and source IDs.
3. Resolve visibility, membership, authority, repository scope, and engagement policy.
4. Create a new episode or attach the input to an explicitly matched active episode.
5. Bind the destination and enqueue an acknowledgement or native-status effect.
6. Plan one or more typed goals and select an effort contract.
7. Compile an immutable context manifest for the next attempt.
8. Start Coop with the selected execution profile.
9. Accept validated typed result operations incrementally.
10. Append episode events and enqueue effects transactionally.
11. Deliver effects through adapters and record their outcomes.
12. Resume on new input, timer, approval, webhook, poll result, or retry.
13. Verify the requested outcome and publish one decision-ready final synthesis.

Follow-ups such as `try again`, `^`, `do that`, and `check it tomorrow` resolve through explicit
message and episode references before a model is asked to interpret them.

## 7. Independent product policies

| Policy | Question | Owner |
| --- | --- | --- |
| Engagement | Should Responder speak, react, or start work? | Host policy plus bounded classification |
| Effort | What coverage is required before finishing? | Typed effort contract and goals |
| Authority | What may be read, changed, published, or executed? | Responder, Coop, and Emisar policy |
| Communication | Where, when, and how should the result appear? | Bound destination and communication policy |

Humor cannot affect authority. Proactivity cannot imply permission. Urgency cannot relax evidence
requirements. Preferences may change presentation or investigation depth but never authorize an
external effect.

### 7.1 Effort contracts

Use a small contract vocabulary:

- `conversation`: answer from established context or perform a tiny focused lookup;
- `focused_check`: verify one or two named claims;
- `operational_assessment`: cover every material system layer for a decision;
- `investigation`: continue until a root boundary, remediation, or exact blocker is established;
- `engineering`: inspect, modify, validate, publish when authorized, and follow through;
- `scheduled_verification`: gather fresh evidence for a previously defined check.

Contract names describe work, not verdicts. `degraded` is a health verdict and is valid only when the
question asks about system health and supporting evidence establishes degradation.

## 8. Goals and compound requests

Every episode has at least one goal. A compound message creates several goal nodes rather than
forcing one model answer to encode all work.

```text
Goal {
  id
  episode_id
  parent_goal_id
  prerequisite_goal_ids
  kind
  requested_outcome
  completion_contract
  repository_scope
  authority_requirement
  state
}
```

The first implementation needs an ordered dependency list with bounded execution of independent
goals, not a general workflow scheduler. The schema permits a DAG later without requiring a DAG
engine now.

An `ExecutionPlan` is a projection of the current goals, prerequisites, selected profiles,
repository scopes, expected waits, and operator decision points. Deep or compound work can render a
concise plan and update it as evidence changes. The plan is explanatory and schedulable state; it
does not grant authority or become a second owner of execution.

Rules:

- planning must account for every material instruction in the input;
- the host validates that no requested goal disappeared during normalization;
- independent goals may run concurrently under workspace limits;
- dependent goals wait for their prerequisites;
- partial completion is explicit and lists remaining or blocked goals;
- one failed child blocks only its dependents;
- published work is never automatically reverted as compensation; remediation is a new explicit
  goal and communication.

## 9. Destination, context, attachments, and artifacts

### 9.1 Bound destination

The episode binds one delivery destination at acceptance. Every acknowledgement, status, progress
message, card, approval, file, and final response uses that destination.

A validated `destination_changed` event may move subsequent effects when:

- the operator explicitly requests a thread or channel move;
- policy escalates work to a dedicated incident room;
- Slack removes or archives the destination;
- the platform requires a replacement conversation.

The event records the typed cause. It does not move unrelated episodes in the same channel.

### 9.2 Context manifests are an input contract

Every attempt receives an immutable `ContextManifest` containing references to:

- the target message and its full thread lineage;
- bounded nearby channel messages centered on the target, not merely the newest messages;
- edits, reactions, blocks, link previews, and attachment metadata;
- eligible downloaded files and generated artifacts;
- relevant episode and conversation summaries;
- recalled preferences, confirmed hints, and committed knowledge cards;
- repository paths and exact revisions;
- tool schemas, execution profile, provider, model, and reasoning configuration;
- investigation contract, required claims, and existing evidence;
- omitted context with a typed reason: privacy, deletion, expiry, unsupported type, or size.

Attempt N+1 includes every still-eligible immutable referent from attempt N plus new relevant
context. Deletion, revoked visibility, or retention expiry may remove a referent and must be recorded.

Large content is content-addressed. The manifest stores digests and source references instead of
copying payloads repeatedly.

### 9.3 Artifact delivery honesty

Generated files and images are typed artifacts. A communication effect may reference an artifact
only after its upload effect succeeds. If upload fails, the episode keeps the artifact, reports the
specific delivery problem once, and can retry without regenerating it.

## 10. Claims, evidence, and completion

The model chooses investigative routes. The host determines whether the conclusion is supported.

```text
ClaimRequirement {
  claim_id
  question_class
  target_identity
  required_dimensions
  freshness
  acceptable_sources
  materiality
}

Evidence {
  id
  episode_id
  goal_id
  claim_id
  target_identity
  observation
  source_type
  source_ref
  source_revision
  observed_at
  valid_until
  confidence
  visibility
}
```

The ledger derives satisfied, contradicted, unsupported, stale, and blocked claims. Evidence for a
runner cannot satisfy a claim about an application. Evidence for one Terraform run cannot satisfy a
claim about another run. Successful scheduling does not prove successful application behavior.

An episode may finish only when:

1. required claims for every required goal are supported;
2. remaining gaps cannot materially change the requested decision; or
3. an exact blocker identifies what is missing and how an operator can unblock it.

Reports should be concise because the evidence is structured, not because investigation stopped
early.

## 11. Typed model operations

Coop returns an ordered bounded list of independently typed operations. The current transport
submits the list in one response envelope; each item is validated and recorded independently so a
later transport can stream the same protocol without changing episode semantics:

- `record_evidence`
- `record_coverage`
- `report_progress`
- `plan_goal`
- `update_goal`
- `request_operator_input`
- `wait_external`
- `request_approval`
- `offer_task`
- `attach_visual`
- `update_memory`
- `offer_memory`
- `offer_preference`
- `offer_rule`
- `offer_schedule`
- `record_alert_assessment`
- `complete_episode`

Responder validates each operation immediately. Invalid operations receive a structured correction
within the same attempt. Accepted operations become events; they do not fold back into a parallel
legacy result object.

Free-text model fields never become executable prompts, schedules, action arguments, or repository
changes. Typed operands are converted into host-owned work specifications.

## 12. Effects, delivery, and interactive controls

```text
Effect {
  id
  workspace_id
  episode_id
  expected_episode_revision
  kind
  destination_ref
  payload_ref
  idempotency_key
  state
  attempt_count
  next_attempt_at
  last_error_class
}
```

The transactional outbox owns Slack posts, reactions, statuses, file uploads, Emisar requests,
GitHub publication, provider starts, and other network actions.

Idempotency keys cover the full semantic payload, target, and episode revision. Delivery receipts
outlive optional presentation artifacts so deleting a channel or incident record cannot make a
duplicate effect appear new.

Interactive controls contain:

```text
episode_id
issued_revision
capability
subject_id
expires_at
```

On click, the host checks current episode state and authority. A stale control performs no stale
effect and renders the current controls instead of exposing an internal error.

## 13. Wakeups, schedules, and lifecycle subscriptions

### 13.1 Episode wakeups

A `Wakeup` resumes an existing episode:

```text
Wakeup {
  id
  episode_id
  kind
  event_matcher
  due_at
  poll_after
  deadline
  state
  last_observation
}
```

Kinds include retry, timer, approval, operator input, PR check, merge, deployment, Terraform run,
alert resolution, and post-change verification.

Every external-event wakeup has a polling fallback and a hard deadline. Webhooks provide low
latency; polling prevents lost webhooks from abandoning accepted commitments.

### 13.2 Recurring schedules

A schedule contains a typed goal template, resolved destination, timezone, recurrence, authority
snapshot policy, repository scope, and concurrency policy. Each occurrence creates a new child
episode. Schedule execution never reuses stale controls or an old writable fork.

Scheduled top-level work first creates a durable Slack anchor when native status requires a message
timestamp. A scheduled episode that reaches a terminal state with no communication intent is a
delivery failure, not a silent success.

### 13.3 Standing assignments

A standing assignment turns an operator-confirmed event pattern into future episodes. It is the
primitive for requests such as:

- review every Terraform plan posted in this channel;
- own first response for checkout alerts;
- investigate recurring CI failures and prepare a patch;
- follow every draft PR through checks, merge, deployment, and post-change verification.

```text
StandingAssignment {
  id
  workspace_id
  trigger_matcher
  goal_template
  service_and_repository_scope
  destination_policy
  allowed_outputs
  authority_ceiling
  effort_and_spend_budget
  concurrency_policy
  expires_at
  enabled
}
```

Every matched event creates a new episode or attaches to an explicitly correlated active episode.
Trigger deduplication and correlation are deterministic. The assignment grants initiative within
its scope, never permission beyond the current Responder, Coop, and Emisar policies.

Conversational setup proposes the typed assignment and renders a confirmation card showing trigger,
scope, output, expiry, budget, and authority boundary. Slash commands and App Home provide a reliable
management surface for review, pause, edit, history, and deletion rather than a second configuration
model.

### 13.4 Approval behavior

Responder may request a governed Emisar action in the current thread. If Emisar returns
`pending_approval`, Responder records a wakeup, renders a concise approval card with the authoritative
Emisar URL, releases all execution leases, and continues processing unrelated work. Approval or
denial resumes the same episode for verification.

Slack never approves the infrastructure action. A dedicated incident room is optional and governed
by channel policy or operator choice.

## 14. Slack adapter architecture

Slack is an adapter around a platform-neutral application kernel.

```text
adapters/slack/
  inbound       Socket Mode events, commands, buttons, reactions, edits, joins
  context       target-centered history, threads, files, blocks, reactions
  outbound      semantic communication intents to Block Kit and Web API calls
  delivery      outbox consumption, retry, receipts, revision reconciliation
  status        native status capabilities and fallback anchors
  admin         channels, members, invitations, App Home, configuration
```

Do not replace the existing broad Slack API with another broad `ChatPlatform` interface. Use narrow
ports such as:

- `ConversationReader`
- `MessagePublisher`
- `StatusPublisher`
- `ArtifactStore`
- `ReactionPublisher`
- `MemberDirectory`
- `ChannelAdministrator`

Adapter conformance tests must cover pagination, retries, rate limits, edits, duplicate event IDs,
thread ancestry, removed files, private-channel visibility, stale controls, upload failures, and
out-of-order lifecycle events.

## 15. Coop execution

Coop remains the only model runtime so Responder preserves authenticated subscriptions, BYOC,
provider isolation, repository policy, and writable forks.

Start with three execution profiles:

| Profile | Purpose |
| --- | --- |
| `chat` | Conversation and small focused checks |
| `investigate` | Deep read-only operational work with tools |
| `engineer` | Isolated writable repository work and validation |

Profiles select a provider/model ladder, reasoning effort, repository policy, tool visibility,
resource budget, progress quiet interval, and versioned preset reference. A specialist consult is an
additional read-only attempt inside the same episode: the lead proposes `request_consult`, the host
selects an allowed preset and budget, and the resulting evidence returns to the lead. Consults are
selective tools for genuine ambiguity or specialist review, not an automatic second opinion on every
request.

Coop should provide fast paths internally by:

- reusing authenticated native sessions;
- prewarming eligible chat and investigation environments;
- retaining a bounded provider checkpoint separate from conversation memory;
- streaming typed operations;
- compacting or rotating transcripts without losing the episode context manifest;
- classifying errors into retryable, capacity, authentication, policy, malformed result, and
  terminal provider failures.

Responder never parses provider error prose to decide authority or success.

## 16. Governed tools and authority

| Concern | Authority owner |
| --- | --- |
| Slack membership, operator role, and visibility | Responder |
| Repository allowlist, fork, box, and writable policy | Coop |
| Infrastructure identity, pack trust, action policy, approval, redaction, audit | Emisar |
| Branch publication and lease protection | Responder plus Coop review evidence |
| Merge and deployment | Explicit external policy; not inferred from chat |

The authority snapshot used by an attempt is recorded in its context manifest. A model suggestion,
memory entry, channel preference, urgency claim, or previous approval cannot widen it.

Read-only operational tools may be used directly from conversation episodes. Mutating Emisar actions
remain governed by Emisar policy and may pause for approval. They do not require an incident room or
writable repository unless the requested outcome independently needs one.

## 17. Multiple repositories

Each goal may declare:

- one primary writable repository, or none;
- zero or more explicitly allowed read-only companion repositories;
- exact revisions for every repository included in an attempt;
- validation and publication contracts for the writable repository.

Cross-repository work uses a parent episode with child goals. Each writable child receives an
independent Coop fork. The parent coordinates compatibility evidence, publication ordering, and
communication.

Publication dependencies such as `must_merge_after` are typed and host-enforced. Responder refuses
to publish a dependent change before its prerequisite reaches the required state.

Do not mount an arbitrary parent directory and treat nested repositories as one writable tree. A
real monorepo is valid. Otherwise, explicit repository sets preserve isolation, review, cleanup, and
ownership.

## 18. Memory and committed knowledge

Responder does not have one undifferentiated memory system.

### 18.1 Committed knowledge

Stable repository and organizational knowledge belongs in version-controlled Markdown:

- `.agent/kb/` for descriptive subsystem maps, traps, and non-obvious behavior;
- `.agent/rules/` for normative engineering and operational rules;
- runbooks and repository documentation for maintained procedures and architecture;
- an optional dedicated organizational knowledge repository for cross-repository material.

Knowledge cards include sources, subsystem, updated date, and changelog. Responder indexes cards by
repository, path, visibility, and commit SHA, but reads the original Markdown when relevant. The
index is disposable and rebuildable; Git remains authoritative.

Ordinary conversation never silently edits committed knowledge. Responder may propose an update.
During an authorized engineering task, Coop may update a relevant card in the same reviewed commit
that established the knowledge.

### 18.2 Derived continuity

Conversation summaries and episode outcome summaries preserve:

- purpose and current situation;
- decisions and their sources;
- open goals and commitments;
- unresolved questions and blockers;
- referenced evidence, artifacts, repositories, and participants.

They are derived, bounded, visibility-scoped, expiring, and rebuildable. Public workspace summaries
may be recalled across public channels when repository or service context overlaps. Private channels
and DMs never cross their visibility boundary.

Compaction is deterministic:

```text
messages -> conversation summary
conversation summaries -> bounded continuity rollup
episode events -> outcome summary
```

Rollups retain source references. Compaction never promotes model prose into authority or current
evidence.

### 18.3 Runtime knowledge and freeform guidance

Typed preferences and operator-confirmed hints remain in the database because they require Slack
scope, expiry, precedence, review, and immediate application.

Examples:

- prefer threads in a channel;
- use deep health checks for an operator;
- map a channel to a repository;
- recognize an operator-confirmed service alias.

Preferences affect behavior or presentation. Confirmed hints aid retrieval. Neither proves live
health or authorizes a side effect.

Not every useful memory is a setting. A `GuidanceNote` preserves operator-confirmed natural-language
context such as "when reviewing Terraform plans for this team, lead with availability risk and
drift, not resource counts." It stores the original text, normalized summary, author, source message, workspace and
optional channel/service/repository scope, visibility, confirmation time, expiry, supersession, and
review history.

Guidance may steer interpretation, planning priorities, and communication. It is quoted as operator
context, not executed as a prompt, and cannot grant authority, prove a fact, create a schedule, or
override newer explicit input. Contradictory guidance is surfaced for review rather than silently
merged. Operators can inspect, disable, edit, or forget it from Slack.

### 18.4 Retrieval precedence

1. fresh authoritative evidence;
2. current repository, IaC, and committed knowledge at exact revisions;
3. current authority and typed configuration;
4. target conversation and active episode;
5. operator-confirmed hints and applicable guidance notes;
6. related summaries and rollups;
7. older evidence explicitly marked stale.

### 18.5 Service observation index

The service graph is initially a rebuildable observation index, not another infrastructure catalog.
It connects services, repositories, channels, owners, runbooks, dashboards, dependencies, and
deployment pipelines using source-attributed observations from repositories, IaC, Emisar, GitHub,
Slack configuration, and confirmed mappings. Resolution is a deterministic query over source
priority, exact revision, visibility, and freshness.

Do not add an independent contradiction lifecycle, authority ranking engine, or manually maintained
duplicate graph. When sources genuinely disagree, expose the sources and ask for an operator
decision. Store the resulting stable mapping as committed knowledge or a typed confirmed hint.

## 19. Progress and human communication

Progress is a typed episode event. Useful triggers include:

- the evidence plan is established;
- a material goal begins or completes;
- a hypothesis changes materially;
- an important finding is verified;
- a required dependency is unavailable;
- approval or operator input is required;
- work exceeds its configured quiet interval;
- verification begins or finds a regression.

Use native Slack status for lightweight phase activity. Use durable messages only for findings,
changed decisions, blockers, approvals, and useful handoffs.

Communication policy must:

- lead with the decision or useful finding;
- use plain professional language and explain unfamiliar terms;
- avoid repeating safety disclosures already established in the conversation;
- avoid raw provider errors, internal schema names, or tool dumps;
- vary acknowledgement and progress phrasing;
- omit irrelevant evidence sections and controls;
- use zero or one socially meaningful emoji by default;
- permit understated humor only after the useful answer in relaxed contexts;
- remain serious for incidents, security, approvals, customer impact, failed operations, and
  uncertainty.

Personality changes phrasing only. It never changes facts, evidence, priorities, routing, controls,
or authority.

## 20. Backpressure, failure recovery, and cleanup

### 20.1 Work admission and fairness

The existing durable work queue should evolve rather than be replaced. It needs:

- workspace and provider concurrency pools;
- per-episode leases and fencing;
- fair scheduling across conversations;
- priority for approvals, operator replies, and incident verification;
- bounded retries with classified backoff;
- explicit paused-capacity and blocked states.

Backpressure delays work; it does not generate repeated public failures.

### 20.2 Failure generations

User-visible failure deduplication is keyed by `(episode_id, blocker_class)`. Replacement attempts do
not create new public failures for the same logical blocker. A materially different blocker or a
new operator-requested retry creates a new generation.

### 20.3 Ownership-based cleanup

Every temporary resource records its owning workspace, episode, attempt, and retention class:

- Coop session and box;
- writable fork;
- downloaded attachment;
- generated artifact;
- provider checkpoint;
- pending effect;
- wakeup and subscription;
- delivery receipt;
- summary and rollup.

Cleanup never guesses ownership from names. It refuses to remove resources owned by active episodes,
unresolved approvals, unreviewed changes, pending publications, or live wakeups.

Terminal cleanup should stop boxes promptly, retain reviewable changes according to policy, expire
downloaded private files aggressively, and preserve durable events, evidence, receipts, and audit
records for their configured retention.

## 21. Target package boundaries

Keep the package structure small enough to enforce ownership without creating ceremony:

```text
internal/core/             canonical value types and event envelopes
internal/episode/          aggregate, reducer, projections, invariants
internal/policy/           engagement, effort, authority, communication
internal/evidence/         claims, ledger, completion assessment
internal/knowledge/        committed sources, continuity, retrieval
internal/orchestration/    application use cases and effect planning
internal/ports/            narrow platform and execution capabilities
internal/adapters/
  slack/
  coop/
  emisar/
  github/
  terraform/
  repository/
  sqlite/
```

Dependency direction:

```text
adapters -> ports -> orchestration -> episode/policy/evidence/knowledge -> core
```

Domain packages never import Slack SDKs, Coop clients, SQL drivers, GitHub clients, or Block Kit
types. The SQLite adapter is split by repository interface instead of remaining one broad store god
object.

Package extraction happens after lifecycle ownership is corrected. Moving the current competing
state into cleaner packages first would preserve the bugs.

## 22. Observability and exact replay

Every episode exposes an operator-safe timeline with:

- normalized inputs;
- destination changes;
- goals and state transitions;
- attempts and classified failures;
- context manifest IDs;
- evidence and claim assessments;
- accepted and rejected typed operations;
- effects, retries, and receipts;
- wakeups and deadlines;
- provider, model, preset, prompt, contract, and tool-schema versions.

Logs and metrics use workspace, episode, goal, attempt, effect, and wakeup IDs. They never include
credentials, private file content, raw prompts, hidden reasoning, or unredacted tool output.

Required operational metrics include:

- admission and acknowledgement latency;
- time to first useful finding;
- time to decision-ready result;
- episode and attempt outcomes;
- retry and blocker classes;
- queue age and provider utilization;
- duplicate suppression;
- stale-control reconciliation;
- wakeup lateness and abandoned-commitment count;
- artifact upload failures;
- memory and knowledge recall sources;
- cleanup backlog and leaked-resource detection.

## 23. Test and evaluation strategy

### 23.1 Testing layers

1. Pure reducer and policy unit tests.
2. Storage transaction, migration, lease, and idempotency tests.
3. Adapter conformance suites with scripted upstream behavior.
4. Deterministic historical episode replay with fake adapters and frozen time.
5. Recorded-tool real-model evaluation for planning, evidence use, and communication.
6. Small live canaries in dedicated test workspaces and channels.

### 23.2 Historical Slack corpus

Sanitize and convert the existing dogfooding history into fixtures covering:

- thread and channel routing corrections;
- references to older messages, screenshots, and files;
- stale controls and current-control replacement;
- schedules, delayed verification, and missing webhooks;
- standing assignments, event correlation, pause, expiry, and deduplication;
- transcript bounds, provider exits, rate limits, 400/409/500 responses;
- alerts requiring silence, reaction, focused response, or deep investigation;
- Terraform lifecycle transitions and exact-run identity;
- Emisar approvals without incident rooms;
- engineering task, PR, checks, merge, deployment, and verification follow-through;
- incident timelines and postmortem drafts derived from verified events;
- artifact generation and failed Slack upload;
- channel setup, cancellation, buttons, and compound preferences;
- cross-channel public recall and private-channel isolation;
- concurrent users, duplicate events, restarts, and cleanup.

Fixtures store canonical events and adapter observations, not Slack tokens or raw private payloads.

### 23.3 Corpus labeling and review

Historical expectations come from several signals:

- explicit operator corrections define strong labels for routing, context, depth, and usefulness;
- later messages and external lifecycle events establish whether a commitment was fulfilled;
- retries, duplicate failures, stale controls, and deleted channels establish hard invariants;
- reactions are weak preference signals and never the sole correctness oracle;
- model-generated candidate labels require human review before entering a release gate.

Keep the restricted raw export separately from sanitized fixtures. A fixture retains stable source
references so an authorized reviewer can audit how it was labeled without exposing private content
to ordinary CI or model evaluation.

### 23.4 Deterministic fixture shape

```yaml
case_id: screenshot_followup_survives_retry
initial_state: {}
events: []
adapter_fixtures: {}
expected:
  bound_destination: {}
  context_references: []
  required_effects: []
  forbidden_effects: []
  required_events: []
  terminal_state: completed
```

Global hard invariants are applied to every fixture by the harness. Individual fixtures specify only
case-specific outcomes.

### 23.5 Global hard invariants

- no effect targets anything except the episode's bound destination;
- changing destination requires a typed event and valid visible target;
- attempt context never loses a still-eligible referent;
- controls affect only their episode, revision, subject, and capability;
- stale controls render replacements;
- one public failure exists per logical blocker generation;
- an artifact is never claimed before upload succeeds;
- approvals and external waits hold no execution or conversation lease;
- schedules have a typed goal and resolved destination;
- no accepted commitment disappears without a terminal explanation;
- evidence target identity matches the claim target;
- a verdict vocabulary matches the question class;
- private context never appears outside its visibility scope;
- no external effect occurs without a validated outbox row and idempotency key;
- retries and restarts do not duplicate external effects;
- no model proposal widens authority.

### 23.6 Real-model evaluation

Use real models where judgment matters, but replay sanitized recorded tool results so cases are
repeatable. Assert typed operation kind, ordering constraints, target identity, evidence selection,
goal coverage, and terminal classification. Do not compare exact prose.

A calibrated judge scores only genuinely behavioral qualities:

- whether intervention was useful;
- whether the investigation was deep enough;
- whether progress messages were useful and non-repetitive;
- whether the answer was decision-ready;
- whether language was clear, concise, natural, and appropriately serious;
- whether humor, reactions, and emojis were contextually appropriate.

Run selected cases across supported provider/model profiles. Record all prompt, contract, tool,
preset, and model versions with the result.

### 23.7 Failure injection

Inject failures before and after every durable boundary:

- after inbox insert but before acknowledgement;
- after event append but before effect enqueue;
- after external success but before receipt persistence;
- during file download and upload;
- during Coop stream and typed-operation correction;
- while waiting for approval or webhook;
- during schedule claim and child-episode creation;
- during publication and deployment observation;
- during memory compaction and cleanup;
- across process restart and lease expiry.

### 23.8 Load, fairness, and privacy

Test simultaneous long investigations, short questions, approvals, and schedules across several
workspaces. Assert bounded acknowledgement latency, no conversation head-of-line blocking, fair
provider allocation, correct ordering within an episode, and strict visibility filtering.

### 23.9 Initial release gate

Start with four enforceable gates:

1. unit, race, storage, and adapter-contract tests;
2. deterministic historical replay with zero hard-invariant violations;
3. real-model evaluation above the configured semantic and communication thresholds;
4. live canary success in the designated test channel.

Expand the gate only when a new check has demonstrated signal and acceptable stability.

## 24. Capability preservation matrix

| Capability | Required target behavior |
| --- | --- |
| Mentions, DMs, and proactive messages | Normalized inbound events with target-centered context |
| Thread and channel switching | Episode-owned destination revision |
| Reactions | Typed signal effect; never evidence by itself |
| Attachments and screenshots | Content-addressed manifest references with visibility |
| Generated charts and files | Upload-before-claim invariant and retryable artifact state |
| Channel setup and conversational configuration | Typed wizard or proposal state attached to an episode |
| Slash commands and App Home | Management views over the same typed configuration and episode state |
| Durable preferences and rules | Typed, confirmed, scoped, expiring records |
| Freeform operator guidance | Confirmed, provenance-bearing, non-executable guidance notes |
| Cross-channel memory | Public organizational recall with strict privacy intersection |
| Standing assignments | Confirmed event template creates scoped episodes with bounded initiative |
| Incidents | Optional episode escalation and room artifact |
| Incident timeline and postmortem | Evidence-backed projections of episode and external lifecycle events |
| Runbook control-plane work | Governed Emisar operation without forcing a repository task |
| Engineering changes | Episode goal with isolated writable Coop fork |
| Diff and draft PR controls | Revision-bound projections shown only when applicable |
| Contextual next-step controls | Revision-bound offers generated only for valid episode capabilities |
| PR checks, merge, deployment, verification | Durable wakeups with webhook and poll fallback |
| Emisar actions and approvals | In-place governed action with authoritative approval URL |
| Scheduled and recurring work | Typed schedule creates a fresh child episode |
| Multi-repository work | Parent episode, child goals, one writable repo per child |
| Model choice and BYOC | Coop execution profiles and exact metadata |
| Progress updates | Typed events rendered through status and durable messages |
| Cleanup | Ownership-based lifecycle and retention policies |

No migration may remove a capability because its replacement package exists but its behavior is not
yet proven.

Proof is counted per capability, and so is deletion. A legacy path may be deleted once a replay
fixture proves the capability that path carries, and only the paths belonging to that capability may
go with it. Every other capability keeps its legacy path until its own fixture exists. A phase is
therefore never held shut as a whole by the least-covered capability inside it, and no capability is
ever deleted on the strength of a neighbour's proof.

A deletion that cannot name the one capability it rests on is not a per-capability deletion. Shared
plumbing — a path several capabilities route through — is proven only when every capability routing
through it is proven, because deleting it on one capability's fixture removes the others untested.

Each deletion is recorded where the proof is checked rather than where it is remembered:
`internal/episode_replay_coverage_test.go` carries a marker per deleted legacy path naming its
capability, and fails if that capability is an acknowledged gap, if it is absent from the corpus, or
if the deleted path reappears in the tree.

## 25. Migration plan

The migration fixes user-visible invariants before extracting packages.

### Phase 0: Freeze regressions and instrument ownership

- convert the known Slack failures into deterministic host fixtures;
- add global hard-invariant assertions;
- inventory current incident, run, commitment, delivery, schedule, publication, and control owners;
- record current prompt, model, preset, contract, and tool versions;
- add metrics for attempts, duplicate public failures, stale controls, and abandoned commitments.

Exit criteria:

- each known failure can be reproduced or represented by a fixture;
- current behavior has a measurable baseline;
- no production behavior changes yet.

### Phase 1: Episode owns attempts — landed

Every agent run in the deployed database carries an episode and an attempt, and
episodes with two and three attempts exist, so replacement attempts demonstrably
resume rather than fork. Commitments are keyed by episode as of schema 42: they
were keyed by run, and the projection reached the episode through the
originating run, so a promise made by a replacement attempt joined to nothing
and vanished from every view while still sitting in the table — 16 of 335 on the
deployed database. That is the hard invariant "no accepted commitment disappears
without a terminal explanation", and it was being violated silently.

What remains of this phase is deletion rather than construction: fifteen places
still bridge run and episode identity, and `agent_runs` remains the transport
table those bridges read.

Measured again on 2026-08-15, the first time under the per-capability rule: 174
occurrences across 37 non-test files, and not one of them is eligible to go.
Every remaining bridge is shared plumbing — delivery idempotency, the retention
fallback guards, the activity dedup key, the migration registry, the episode
kernel itself — so each is proven only when every capability routing through it
is, and seventeen are not.

The incident root is the case that matters, because it is the largest legacy path
and it looked like the obvious first deletion. It is not deletable on any single
fixture: engineering tasks are rows in the `incidents` table, the room's root
message gates the Coop session that every tool use needs, and the approvals hang
off `emisar_approvals.incident_id`. One legacy path therefore carries `incidents`,
`engineering-changes`, `mentions-dms-and-proactive-messages`, and
`runbook-control-plane-work` at once — four proven capabilities, which is four
reasons it cannot be deleted for one of them.

So the per-capability rule does not by itself unblock this phase's deletion, and
knowing that is the point of measuring rather than assuming. What stands in the
way is no longer an unproven capability waiting on dogfooding; it is a second
lifecycle that four proven capabilities share. Re-anchoring it is phase 5 work,
not deletion work, and the deletion this phase wants is downstream of that.

### Phase 1 (original plan): Episode owns attempts

- remove the one-to-one ownership from work episode to agent run;
- make every execution an attempt referencing an episode;
- re-key commitments and attempt continuity to the episode;
- classify attempt failures and deduplicate blocker generations;
- resume an episode with a replacement attempt after restart or provider failure.

Exit criteria:

- transcript-bound, child-closed, rate-limit, and restart fixtures preserve one episode;
- at most one public failure appears for one blocker generation;
- unrelated conversations continue while an episode retries.

### Phase 2: Bind destination and controls — destination landed, controls not started

The episode has carried `destination_channel_id`, `destination_thread_ts`, and
`destination_revision` since schema 47, and the binding is enforced rather than
only stored. `EnqueueSlackDelivery` refuses a delivery whose channel, thread, or
expected revision disagrees with the episode; `LeaseSlackDelivery` supersedes an
already-queued one with `episode destination changed` when the binding moves
under it; `ChangeEpisodeDestination` requires a typed reason, appends a
`destination_changed` event, and bumps the revision under optimistic concurrency
on the event sequence. Deliveries have carried `expected_episode_revision` and
`expected_destination_revision` since schema 68. Three of this phase's four items
are built and wired to callers, so the work here is narrowing what remains rather
than starting.

Two holes remain in the routing item. `status` and `reaction` deliveries are
exempt from the binding check deliberately, and a delivery enqueued with no
episode is invisible to both the enqueue check and the supersession sweep — seven
of the thirteen non-test enqueue sites pass no episode, so a card or file queued
before a destination change still posts to the surface the episode has left.
That is the second exit criterion, and it is the failure it names. Separately,
`bindEpisodeDestination` moves the episode to wherever the service decided to
post instead of refusing the disagreement, so a per-delivery divergence bumps the
revision rather than being caught by it.

The third item, episode revision controls, is not started. Three incompatible
schemes are in use: `slack_status_generations` keyed by `(channel_id, thread_ts)`,
which is exactly the conversation-scoped generation this phase names;
`publications.generation` keyed by incident; and, for every other control, no
generation at all — currency is decided by re-decoding the delivered message body
and asking whether it still renders that button, found by
`(incident_id, channel_id, message_ts)`.

That item is gated, not merely unstarted. `contextual-next-step-controls` and
`diff-and-draft-pr-controls` are both acknowledged gaps, so section 24 holds the
control path shut until a recorded stale-control replacement and a recorded
revision-bound control exist — which is what this phase's first exit criterion
asks for in the same words. The fixtures cannot be written; they have to happen
and be recorded within the retention window.

- store bound destination and destination revision on the episode;
- route acknowledgements, status, progress, cards, files, and finals through that binding;
- replace conversation-scoped control generations with episode revision controls;
- implement validated destination changes and current-control replacement.

Exit criteria:

- all routing and stale-control historical fixtures pass;
- acknowledgement and subsequent work never split across surfaces accidentally;
- controls from one episode cannot affect another episode in the same thread.

### Phase 3: Make context manifests monotonic

- persist one manifest lineage per episode;
- reconstruct target-centered channel and full-thread context;
- preserve still-eligible attachments, screenshots, reactions, edits, and referents across attempts;
- replace process-local history caches and attachment heuristics;
- content-address large inputs and generated artifacts.

Exit criteria:

- `try again`, `^`, old-thread, screenshot, and file fixtures pass across restart;
- privacy deletion and expiry remove context with an auditable reason;
- replay reconstructs the exact manifest references.

### Phase 4: Use one typed result protocol

- replace parallel watch and agent report schemas with ordered typed operations;
- remove legacy folding into free-text side-effect fields;
- validate operations incrementally and correct malformed output in the same attempt;
- construct tasks, schedules, action requests, and artifacts from typed operands.

Exit criteria:

- no model field can directly cause an external side effect;
- empty scheduled messages and partially saved compound instructions are impossible by construction;
- malformed operations do not discard earlier accepted evidence or progress.

### Phase 5: Re-anchor projections to episodes

- move incident, engineering task, approval, publication, and follow-up ownership to episode IDs;
- make incident rooms optional artifacts;
- derive commitments, controls, coverage, status, publication state, timelines, and postmortem drafts
  from events;
- preserve delivery and idempotency receipts independently of optional presentation records.

Exit criteria:

- Emisar approval completes in an ordinary thread without an incident;
- engineering work follows PR, checks, merge, deployment, and verification from a normal thread;
- duplicate review cards and unrelated controls no longer appear.

### Phase 6: Generalize wakeups and schedules

- implement typed timers, retries, approval waits, operator waits, subscriptions, polling fallback,
  and deadlines;
- create fresh child episodes for recurring schedules;
- create scoped episodes from confirmed standing assignments with deterministic correlation;
- reconcile out-of-order GitHub, Terraform, alert, and deployment events;
- expose overdue or blocked commitments in App Home and diagnostics.

Exit criteria:

- delayed, recurring, approval, PR, deployment, and verification journeys survive restart;
- lost webhooks are recovered through polling;
- zero accepted commitments are silently abandoned.

### Phase 7: Goals and multiple repositories

- normalize compound requests into goal nodes;
- add prerequisite ordering and bounded independent execution;
- bind one writable repository and explicit read-only companions per writable goal;
- coordinate publication dependencies and parent-episode communication.

Exit criteria:

- multi-instruction fixtures complete or block every requested outcome explicitly;
- cross-repository work preserves isolation and exact revisions;
- partial failure does not corrupt completed independent goals.

### Phase 8: Committed knowledge and continuity

- index `.agent/kb/`, `.agent/rules/`, runbooks, and repository documentation by exact revision;
- unify visibility-filtered continuity retrieval;
- preserve confirmed freeform guidance separately from typed preferences and derived summaries;
- separate provider checkpoints from conversation summaries;
- build the minimal rebuildable service observation index;
- add propose-to-PR knowledge updates.

Exit criteria:

- committed knowledge is never duplicated as independent truth;
- public cross-channel recall and private isolation fixtures pass;
- stale indexes can be deleted and rebuilt from sources.

### Phase 9: Extract modules and retire legacy paths

- extract the final package boundaries once ownership is stable;
- split the broad store and Slack APIs behind narrow ports;
- remove process-local lifecycle maps and caches;
- delete old incident-root, watch-result, routing, memory, and control paths;
- forbid new imports that violate dependency direction.

Exit criteria:

- one authoritative path exists for every lifecycle and effect;
- no indefinite dual writes or fallback reads remain;
- the complete capability matrix and release gate pass.

## 26. Migration rules

- Migrate one invariant at a time and keep each change deployable.
- Add the historical failure fixture before changing its behavior.
- Do not extract packages while the underlying ownership is still duplicated.
- Do not dual-write indefinitely; compare projections, cut over, then delete the legacy path — one
  capability at a time, each deletion resting on that capability's own fixture and recorded by the
  marker section 24 requires.
- Preserve unrelated work and repository policy during schema and fork migrations.
- Include restart, retry, stale-input, and cleanup tests in every lifecycle change.
- Record schema, prompt, contract, and adapter versions required to replay pre-migration episodes.
- Treat a user-visible regression as a release blocker, not a follow-up documentation item.

## 27. Quality targets

- zero authority or cross-workspace visibility violations;
- zero unsupported success claims;
- zero abandoned accepted commitments;
- zero duplicate external effects under retry or restart;
- under 1% premature final answers in the evaluation corpus;
- under 2% regretted proactive interventions;
- over 95% recall where a strong operational teammate should intervene;
- over 90% of durable progress messages rated useful;
- bounded acknowledgement latency under configured load;
- every known production failure class represented by a deterministic regression;
- every release passes deterministic replay, real-model evaluation, and live canary gates.

## 28. Not yet

The following are compatible extension points, not committed implementation scope:

- a separately deployed microservice architecture;
- a general-purpose workflow or DAG scheduler;
- a temporal knowledge graph with independent contradiction and supersession workflows;
- manually maintained duplicate service catalogs;
- unrestricted automatic Markdown knowledge writes from ordinary chat;
- more than the three default Coop execution profiles;
- automatic multi-model consultation on every request;
- a second model runtime outside Coop;
- automatic merge, deployment, rollback, or cross-repository compensation;
- shadow execution of all production traffic;
- counterfactual replay across every historical model;
- a large release gate whose checks have not demonstrated stable signal.

## 29. Open decisions and recommended defaults

| Decision | Recommended default |
| --- | --- |
| Event retention | Keep episode events and effect receipts longer than message bodies |
| Episode reopen | Create a child episode unless an explicit active wait is being resolved |
| Destination changes | Operator request or deterministic policy only |
| Provider retries | Resume episode with a fresh attempt and preserved manifest |
| Goal scheduling | Ordered prerequisites plus bounded independent execution |
| External subscriptions | Webhook first, polling fallback, hard deadline |
| Standing assignments | Confirmed typed scope, bounded outputs and budget, explicit expiry |
| Knowledge authority | Git for committed knowledge; typed database for scoped hints/preferences |
| Freeform guidance | Confirmed and scoped, non-executable, reviewable, expiring |
| Service relationships | Rebuildable source observation index |
| Cross-channel recall | Public workspace context only; private conversations stay isolated |
| Incident rooms | Optional escalation artifact, never a prerequisite for tools |
| Publication gates | Run when configured; recommend rather than fabricate a hard blocker |
| Humor | Restrained, contextual, and disabled for serious operational states |

## 30. Definition of architectural completion

The architecture is complete when:

- every accepted work item is owned by one episode that survives failed attempts;
- destination, context, controls, progress, waits, and effects are episode-owned and replayable;
- incidents, engineering tasks, commitments, schedules, and publications no longer compete as root
  lifecycles;
- compound and multi-repository work represents every requested outcome explicitly;
- approvals, PRs, deployments, and scheduled verifications resume without holding workers;
- committed Markdown knowledge, derived continuity, evidence, and typed preferences remain distinct;
- Slack, Coop, Emisar, GitHub, repository, and storage adapters pass independent conformance tests;
- historical failures replay deterministically with zero hard-invariant violations;
- real-model evaluations and live canaries demonstrate natural, proactive, decision-ready behavior;
- legacy ownership paths, process-local lifecycle state, and indefinite dual writes are deleted;
- operators can inspect why Responder acted, which context it used, what it still owes, and exactly
  what would happen next.

The intended result is not merely cleaner code. It is a Responder that can be trusted as a durable,
proactive teammate because its initiative, evidence, communication, memory, and authority have clear
owners and independently testable contracts.
