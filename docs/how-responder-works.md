# How Responder Works

This guide follows one message from admission through Slack delivery and explains where state,
memory, authority, retries, and cleanup live. It describes the current single-host implementation,
not a future multi-tenant design.

Conversational responses follow the operator's current Slack location. Top-level conversation stays
in the channel, thread conversation stays in that thread, and explicit requests to move are
host-parsed before model execution. Multi-step configuration sessions persist every message root
they own so moving between channel and thread does not lose state or admit unrelated replies.

## 1. System map and authority boundaries

```mermaid
flowchart LR
  subgraph Sources["External inputs"]
    Human["Slack members"]
    SlackApps["Slack apps<br/>Terraform, Grafana, CI"]
    Webhooks["Authenticated webhooks<br/>Grafana or mapped JSON"]
  end

  subgraph Responder["Responder process"]
    Socket["Slack Socket Mode<br/>event admission"]
    HTTP["HTTP webhook admission<br/>verify + normalize"]
    DB[("SQLite WAL<br/>durable queues and state")]
    Control["Control lane<br/>Slack admission + delivery"]
    Background["Background lane<br/>incidents + agent runs"]
    Router["Host-owned routing<br/>authorization + policy"]
    Renderer["Host-owned Slack rendering<br/>Block Kit + controls"]
    Publisher["Optional draft PR publisher<br/>exact reviewed tree only"]
    Supervisor["Optional Coop supervisor"]
  end

  subgraph SlackPlane["Slack control plane"]
    SlackAPI["Slack Web API"]
    Threads["Threads, incident rooms,<br/>pinned cards, App Home"]
  end

  subgraph CoopPlane["Coop execution boundary"]
    CoopAPI["Owner-private Unix API"]
    Session["Session + revision + budget"]
    Fork["Isolated repository fork"]
    Box["Short-lived agent box"]
    Agent["Agent model"]
  end

  subgraph Tools["Evidence and action tools"]
    Repo["Current repository"]
    Emisar["Emisar MCP<br/>infrastructure authority"]
    Other["Other configured MCPs<br/>or approved tools"]
    GitHub["GitHub"]
  end

  Human --> Socket
  SlackApps --> Socket
  Webhooks --> HTTP
  Socket -->|"persist before ACK"| DB
  HTTP -->|"persist before 202"| DB
  DB <--> Control
  DB <--> Background
  Control --> Router
  Background --> Router
  Router <--> CoopAPI
  Supervisor -.-> CoopAPI
  CoopAPI --> Session --> Fork --> Box --> Agent
  Agent --> Repo
  Agent --> Emisar
  Agent --> Other
  Router --> Renderer --> SlackAPI --> Threads
  Publisher --> GitHub
  Background <--> Publisher
  Human <--> Threads
```

Authority is deliberately split:

| Boundary | Owner | Responder cannot bypass it |
| --- | --- | --- |
| Slack identity, event admission, conversation routing, durable queues | Responder | Slack membership and configured operator checks |
| Repository allowlist, fork, agent target, box, revision, turn budget | Coop | Coop policy and revision conflicts |
| Live infrastructure identity, action schemas, policy, approval, execution, audit | Emisar | Emisar authorization and approval decisions |
| Draft branch publication | Responder publisher | Exact Coop-reviewed tree, lease-protected branch, draft PR only |
| Merge, signing, deployment | External human-controlled workflow | No Responder operation exists for these actions |

Slack and webhook secrets stay in Responder. The Emisar key is projected into the short-lived Coop
box through Coop's private configuration; it is not sent in prompts. Slack never receives Coop's
filesystem or terminal protocol.

### The work-episode kernel

Every accepted model-backed request creates one durable work episode before execution. Four
independent decisions define it:

| Policy | Stored decision | What it controls |
| --- | --- | --- |
| Engagement | Slack admission and attention score | Whether Responder should participate |
| Effort | `conversational`, `focused_check`, `operational_assessment`, `incident_investigation`, or `engineering_task` | How much evidence and validation completion requires |
| Authority | `read_only`, `repository_write`, or `governed_operation` | Which external effects the host and downstream policy may permit |
| Communication | channel context, reply location, preferences, and native status | Where and how Responder communicates |

Effort never grants authority. A deep health review can remain read-only, and a narrowly scoped
governed operation can require approval without becoming an incident investigation. The episode
stores its objective, required coverage, completion criteria, phase, next action, and an ordered
progress ledger. This state survives process restarts and is also the source of active commitment
bookkeeping.

Operational assessments and incident investigations may finish only when every required layer is
assessed and the result is decision-ready, or when Responder reaches a real external boundary. A
blocked result must classify that boundary as an unavailable source, denied access, required
operator input, an authority boundary, or a tool failure; record what it already attempted; name
every material gap; and state the external action that unblocks the work. "Query the metrics" or
"investigate the errors" is unfinished read-only work, not a blocker. The host rejects and retries
that result instead of presenting it as final.

A healthy host probe alone therefore cannot complete an end-to-end production-health request.
When a genuine blocker remains, Slack adds a compact *Assessment incomplete* section showing what
is still unverified, what Responder already tried, and what must happen next. The durable episode
remains open rather than silently turning a partial assessment into completed work.

## 2. Slack event admission and routing

Socket Mode handlers do minimal synchronous work: validate the workspace and event shape, persist a
deduplicated `slack_inputs` row, and only then acknowledge Slack. The worker makes the expensive
decision later. A persistence or policy-resolution failure before that point is not acknowledged,
so Slack can redeliver the envelope instead of Responder silently losing it.

Nothing that talks to Slack happens on the socket consumer, including work that looks trivial.
Refreshing suggested prompts or the App Home is a Slack round trip, so those are admitted as
ordinary inputs and performed by the control lane; doing them inline would hold the single consumer
and delay admission of every event behind them.

Reactions are admitted too. Adding or removing an emoji on one of Responder's own messages is
retained as ordered conversation context and refreshes the current reaction state without starting
a separate agent turn. A reaction is social feedback: it never authorises an approval, a repository
change, an incident, or an infrastructure action.

```mermaid
flowchart TD
  Event["Slack event"] --> Valid{"Expected workspace<br/>and supported event?"}
  Valid -- No --> AckIgnore["ACK and ignore"]
  Valid -- Yes --> Own{"Responder's own message?"}
  Own -- Yes --> AckIgnore
  Own -- No --> Kind{"Event kind"}

  Kind -- "Slash command" --> Persist["Persist slack_inputs<br/>by envelope/event ID"]
  Kind -- "Button or shortcut" --> Persist
  Kind -- "Channel lifecycle" --> Persist
  Kind -- "Direct message" --> Persist
  Kind -- "@mention" --> Persist
  Kind -- "Ordinary human message" --> HumanGate{"Existing incident/task thread,<br/>proactive channel, or rule match?"}
  Kind -- "External app message" --> AppGate{"Proactive channel<br/>or rule match?"}

  HumanGate -- No --> AckIgnore
  HumanGate -- Yes --> Persist
  AppGate -- No --> AckIgnore
  AppGate -- Yes --> Persist

  Persist --> Ack["ACK Slack"]
```

Slack channel-join events for the bot are admitted immediately and atomically record the durable
setup input and membership transition. Separately, a bounded scheduler calls `users.conversations`
to reconcile only conversations the bot belongs to. It detects any missed absent-to-present
transition and persists a synthetic `channel_joined` input. Both paths are durable and deduplicated,
so restarts cannot duplicate or lose onboarding.

After acknowledgement, the durable worker applies the more expensive authorization and conversation
routing:

```mermaid
flowchart TD
  Lease["Worker leases input"] --> Workspace{"Correct workspace?"}
  Workspace -- No --> Terminal["Fail and audit"]
  Workspace -- Yes --> Route{"Host routing"}

  Route -- "Lifecycle" --> Lifecycle["Mark channel active,<br/>archived, unreachable, or deleted"]
  Route -- "Membership transition" --> Setup["Start durable typed<br/>channel setup"]
  Route -- "Slash command" --> Slash["Run deterministic command"]
  Route -- "Button" --> Action["Validate action payload,<br/>operator, age, scope, and target"]
  Route -- "Known incident or task thread" --> Conversation["Queue ordered turn in<br/>that exact conversation"]
  Route -- "Direct message or shortcut" --> Triage["Read-only shared-channel triage"]
  Route -- "Explicit mention" --> Summon{"Explicit incident request<br/>from configured operator?"}
  Route -- "Explicit typed behavior request" --> Triage
  Route -- "Proactive or standing-rule match" --> Triage
  Route -- "No eligible route" --> Done["Finish without a response"]

  Summon -- Yes --> ManualIncident["Create manual incident occurrence"]
  Summon -- No --> Triage
```

Important routing behavior:

- A direct message or **Investigate message** shortcut always enters read-only triage.
- When Slack reports that the bot joined a channel, Responder opens one durable setup conversation.
  Operator answers advance a host-owned typed draft; a confirmation button bound to the stored
  session ID is required before settings change.
- Supported conversational controls are normalized into the same command handlers as
  `/responder`. Read results are threaded publicly; slash results remain ephemeral.
- An explicit `@mention` always summons read-only triage in any channel where Emisar is a member.
  Proactive participation, shadow evaluation, and app-alert policy remain channel-configured.
- A successfully delivered triage reply opens a 30-minute continuation window at that channel or
  thread location. Human follow-ups are admitted without another mention; a reply that starts a
  thread from Emisar's top-level answer is treated as the same exchange.
- Messages already bound to an incident room or engineering-task thread stay in that conversation.
- Broad proactivity and deterministic standing rules are separate. A rule can admit its matching
  event while general proactive triage is off.
- A typed standing-rule match starts a model evaluation but does not force speech. The model may
  ignore an intermediate or duplicate event, react, or reply when the message and read-only tools
  provide a useful result. Later lifecycle updates are evaluated fresh. Terraform findings still
  require the exact plan or a read-only lookup of that run; commit history is context, not a
  substitute.
- Human senders must be active full workspace members. Incident steering and confirmations require
  a configured operator.
- Responder ignores its own posts, foreign-workspace events, unsupported subtypes, guests, and
  Slack Connect users that do not satisfy the membership boundary.

## 3. One complete shared-channel triage turn

This is the path used for direct messages, message shortcuts, summon mentions, proactive channel
messages, and standing-rule matches.

```mermaid
sequenceDiagram
  autonumber
  participant S as Slack
  participant A as Admission
  participant DB as SQLite
  participant W as Responder worker
  participant C as Coop
  participant G as Agent
  participant T as Repo / Emisar / other tools

  S->>A: Event envelope
  A->>DB: INSERT slack_inputs<br/>dedupe envelope_id and event_id
  DB-->>A: Persisted
  A-->>S: ACK

  W->>DB: Lease next eligible Slack input
  Note over W,DB: Slash/actions are prioritized.<br/>Only active admission work serializes a channel.
  W->>DB: Match standing rules and INSERT agent_runs
  W->>DB: Create durable work episode + commitment<br/>effort, authority, coverage, completion criteria
  W->>DB: Mark Slack input done
  W->>DB: Queue native pending status
  Note over W,DB: Slack input retry budget stops here.<br/>Long model work has its own failure budget.

  W->>DB: Lease next eligible agent run
  W->>DB: Enforce one active run per conversation
  W->>DB: Wait for channel settle delay
  W->>DB: Reject late input if a newer decision already completed
  W->>DB: Load or create channel session generation
  W->>C: Refresh current session state
  C-->>W: Open / exhausted / terminal + revision

  opt Target message has supported Slack files
    W->>S: Authenticated bounded file download
    S-->>W: Private bytes
    W->>W: Verify Slack host, size, media type,<br/>content signature, and SHA-256
    W->>C: Submit typed image/resource artifacts<br/>with the text prompt
  end

  alt Terminal session
    W->>DB: Detach session, preserve compact memory
    W->>DB: Queue owned-session cleanup
    W->>C: Create next generation
  else Exhausted session
    W->>C: Extend within configured automatic ceiling
  end

  W->>DB: Assemble target-centered 10-50 message window
  W->>DB: Load exact conversation summary,<br/>related public workspace summaries,<br/>confirmed memory, evidence, preferences, and repository binding
  W->>DB: Persist exact context snapshot on agent_runs
  W->>C: Submit turn with session revision<br/>and generation-aware idempotency key
  C->>G: Start short-lived agent box
  G->>T: Inspect declared topology and fresh evidence
  T-->>G: Source-attributed observations
  opt User requested an image or chart and a capable tool is available
    G->>G: Write bounded image to the per-turn output directory<br/>or return typed ACP image content
    C->>C: Store content-addressed output outside the text transcript
  end
  G-->>C: Strict JSON decision envelope
  C-->>W: Terminal turn

  W->>W: Strict parse, bound, sanitize, validate
  W->>W: Enforce episode completion<br/>or continue the same accepted work
  W->>W: Enforce host attention threshold<br/>after addressee and interruption scoring
  W->>DB: Stage terminal result on agent_runs
  W->>DB: Persist evidence and coverage separately
  W->>DB: Append terminal or blocked episode progress
  W->>DB: Transaction: decision once + channel session state<br/>+ conversation summary update

  alt ignore
    W->>DB: Audit silence
  else react
    W->>W: Validate and normalize one Slack emoji name
    W->>S: Add lightweight standard or workspace reaction
  else reply
    W->>DB: Queue rich delivery at the safe response location
  else reply with generated visuals
    W->>C: Fetch exact completed-turn artifacts
    W->>W: Verify type, size, digest, title, and alt text
    W->>DB: Queue prose and durable file uploads<br/>to the same conversation
  else reply with inert offer
    W->>DB: Queue response + host-owned confirmation button
  else allowed automatic app alert
    W->>DB: Create correlated incident occurrence
  end

  W->>DB: Record standing-rule run once, if matched
  W->>DB: Queue pending-status clear
  W->>DB: Finish agent run<br/>commitment becomes done or blocked
  W->>S: Deliver queued post/update/status
```

Attachment bytes are deliberately turn-scoped. Responder stores Slack-owned file metadata so a
durable retry can repeat the authenticated download, but it never serializes a private URL or file
body into the prompt, compact conversation memory, evidence ledger, or Slack response. Coop stores
the bounded payload only until the turn completes, fails, or is cancelled, then deletes it. When a
triage answer offers an engineering task, accepting that offer queues the initial writable turn
against the original Slack input so the same screenshot or document reaches the isolated task fork.

The model does not return arbitrary Slack blocks or inline binary data. It returns a strict decision
envelope containing prose, optional references to exact current-turn image artifacts, evidence,
coverage, compact memory, and at most one inert offer. Responder owns buttons, file uploads,
confirmation dialogs, mentions, approval links, accessibility text, limits, and persistence.

Generated visuals are a typed output channel, not memory or evidence. Coop accepts only bounded
PNG, JPEG, WebP, and GIF files from a fresh per-turn directory or typed ACP image/resource blocks,
then removes the directory. Responder fetches only artifacts explicitly referenced by the final
decision, rechecks their SHA-256 and byte count, and queues them after the reply at the same channel
or thread location. A deterministic filename lets uncertain Slack uploads reconcile exactly once.
Charts must cite their underlying observations and time range; creative images may have no evidence.

For shared-channel work, accepted decisions are:

| Decision | Effect |
| --- | --- |
| `ignore` | Audit the decision and post nothing |
| `reply` | Post a bounded rich response where a human is speaking; keep app alerts and standing rules in the source thread |
| Reply plus incident offer | Show **Open incident room**; create nothing until confirmed |
| Reply plus engineering-task offer | Show **Start task**; create no writable fork until confirmed |
| Reply plus incident and prepared-fix offers | Show **Open incident room** and **Prepare code fix** independently; carry the confirmed fix objective into a thread task only after operator confirmation |
| Reply plus memory/preference/rule offer | Show a typed confirmation; save nothing until confirmed |
| Automatic incident | Allowed for a credible unresolved monitoring-app alert, not an ordinary human health question |

## 4. Memory, context, evidence, preferences, and rules

Responder does not have one undifferentiated memory. It has separate stores because conversation
continuity, factual hints, current evidence, and executable behavior require different trust and
retention rules.

All of it competes for one bounded turn. When the assembled context does not fit, the host chooses
what to drop rather than letting the transport cut the middle out of a structured payload: prior
evidence first, then summaries of other conversations, then the referenced transcript, then
synthesized continuity, then older channel messages down to a floor, and operator-confirmed memory
last because someone put it there deliberately. The target message is never dropped, and every
omission is reported to the model as `context_omitted` — silently thinner context reads as
confident ignorance, while a stated gap is a reason to ask.

Confirmed memory is chosen by relevance to the current request rather than by recency, with an
exact identifier match on an alias, evidence route, or relationship correction always included.
Ordering by recency alone would mean the more the agent is taught, the less of it surfaces.

```mermaid
flowchart TB
  subgraph Inputs["Context assembled for one turn"]
    Recent["Target-centered Slack transcript<br/>root + nearest replies<br/>10-50 messages"]
    Compact["Exact conversation summary<br/>goal, topology, decisions,<br/>open questions, evidence refs"]
    Related["Related compact summaries<br/>same channel, repository,<br/>public workspace"]
    Confirmed["Operator-confirmed memory<br/>aliases, bindings, routes,<br/>entity corrections"]
    Evidence["Recent same-channel evidence<br/>claim + observation + source + time"]
    Preferences["Effective typed preferences<br/>operator, channel,<br/>repository, workspace"]
    Rules["Host-matched standing rules<br/>typed trigger + action + source"]
    Repository["Current repository content"]
    Live["Fresh live evidence<br/>Emisar and other authoritative tools"]
    Config["Current Responder configuration"]
  end

  Prompt["Bounded trusted/untrusted<br/>prompt assembly"]
  Agent["Agent decision"]
  Validate["Host validation"]

  Recent --> Prompt
  Compact --> Prompt
  Related --> Prompt
  Confirmed --> Prompt
  Evidence --> Prompt
  Preferences --> Prompt
  Rules --> Prompt
  Repository --> Prompt
  Live --> Agent
  Config --> Prompt
  Prompt --> Agent --> Validate

  Validate -->|"structured memory"| CompactStore[("conversation_memories.state_json")]
  Validate -->|"evidence"| EvidenceStore[("evidence + coverage")]
  Validate -->|"inert memory offer"| MemoryCard["Confirmation card"]
  Validate -->|"inert behavior offer"| BehaviorCard["Confirmation card"]
  MemoryCard -->|"operator click"| MemoryStore[("memory_entries")]
  BehaviorCard -->|"operator click"| BehaviorStore[("responder_preferences<br/>or standing_rules")]
  Rules -->|"source input once"| RuleRuns[("standing_rule_runs")]
```

### Memory layers

| Layer | Stored in | Writer | Purpose | Trust and lifetime |
| --- | --- | --- | --- | --- |
| Exact Slack context | Slack history plus `slack_inputs`, then snapshotted in `agent_runs.context_json` | Context assembler | Preserve the thread root and messages nearest the target while avoiding unrelated threads | Raw event context only; 10-50 messages and operational-data retention |
| Compact conversation situation | `conversation_memories.state_json` | Agent result after host validation | Carry purpose, situation, goal, active topics, topology, decisions, open loops, unresolved questions, and evidence references across turns | Continuity, not current-health proof; 90-day default retention |
| Related workspace situations | Recent `conversation_memories` selected at prompt assembly | Host-owned context selection | Recall overlapping work from the same channel, repository, and public workspace channels | Bounded to eight summaries; private channels never cross channel boundaries |
| Channel session state | `channel_memories.state_json` | Agent result after host validation | Preserve a fallback while the per-channel Coop session rotates | Session continuity, not the organizational memory boundary |
| Evidence ledger | `evidence`, `coverage`, `timeline_events` | Host after strict agent-report parsing | Preserve source-attributed observations independently of prose | Same-channel recall; time and source remain visible |
| Confirmed durable memory | `memory_entries` | Configured operator click | Durable mapping or open-ended collaboration guidance | Mapping is an untrusted hint; guidance is advice, never evidence or authority; both have scope, expiry, and caps |
| Work commitments | `commitments` projected from `agent_runs` | Host when it accepts model-backed work | Show what Emisar owes, current progress, and the next operator action | Execution state, not prompt memory or evidence |
| Preferences | `responder_preferences` | Configured operator click | Typed investigation depth or response detail | Closed catalog; precedence and expiry are host-owned |
| Standing rules | `standing_rules` | Configured operator click | Typed channel subscription such as Terraform-plan review | Host matches trigger deterministically; read-only |
| Rule executions | `standing_rule_runs` | Host | Prevent the same rule/source event from running twice | Idempotency record, later pruned |
| Incident intelligence | Incident, signals, agent runs, evidence, coverage, explicit events, proposals, Emisar approvals, publication | Webhook, host, agent, operators | Coordinate one incident or engineering task and derive its remediation timeline and postmortem | Bound to that work occurrence; source rows remain canonical |

### Evidence precedence

```mermaid
flowchart LR
  Fresh["1. Fresh authoritative<br/>live evidence"] --> Repo["2. Current repository<br/>content"]
  Repo --> Configuration["3. Current Responder<br/>configuration"]
  Configuration --> ConfirmedHint["4. Operator-confirmed<br/>memory hint"]
  ConfirmedHint --> OlderEvidence["5. Older source-attributed<br/>evidence"]
```

Higher items resolve conflicts with lower items. Memory never proves current health, carries a
credential, grants approval, or authorizes a mutation. The model cannot write confirmed memory,
preferences, or rules directly.

### Typed behavior setup and execution

```mermaid
sequenceDiagram
  autonumber
  participant O as Operator
  participant R as Responder
  participant DB as SQLite
  participant S as Slack
  participant A as Terraform app
  participant C as Coop agent

  O->>R: "When you see a Terraform plan here,<br/>review its diff and red flags for 30 days"
  R->>C: Read-only interpretation turn
  C-->>R: rule_offer with allowlisted fields
  R->>R: Validate operator, channel, repository,<br/>trigger/action pair, source, TTL, capacity
  R->>S: Proposed standing rule card
  Note over R,DB: Nothing is stored yet
  O->>S: Click Enable standing rule
  S->>R: Signed Slack interaction
  R->>R: Validate payload age, source event,<br/>operator, scope, and normalized offer
  R->>DB: Upsert one logical typed rule
  R->>S: Standing rule enabled

  A->>R: New Terraform plan message
  R->>DB: Deterministic text/source match
  R->>C: Read-only review with repository context
  C-->>R: Threaded assessment
  R->>DB: Record rule_id + source_input once
  R->>S: Reply in Terraform message thread
```

### Learned conversation knowledge

Beside operator-confirmed memory, Responder retains what it learned from a conversation without
anyone confirming it. A completed turn may return `update_memory` carrying typed knowledge items —
a decision, a constraint, a fact, a rationale — each with a status, a confidence, and a link to the
exact Slack message it came from.

This is deliberately weaker than confirmed memory and is labelled as such in the prompt. It is
included only when the host finds concrete lexical overlap with the current request, tentative
items are context rather than conclusions, and nothing learned this way can authorise work,
approve an action, or serve as evidence that a claim is currently true. It exists so the agent
does not ask the same question twice, not so it can act on something nobody agreed to.

### Product feedback

When a message is clearly about Responder itself — a correction, a suggestion, an explicit
complaint about how it behaved — the turn may return one `record_feedback` operation. That is
stored, not acted on. Operational frustration about an outage, a provider, or a person is not
Responder feedback and is not recorded as such.

Open feedback appears on the App Home, grouped by category, where a configured operator can
dismiss it or convert it into durable guidance. Conversion writes an ordinary guidance entry
through the same validation as any other memory, so the model can record feedback but only a
person can turn it into behaviour. Raw feedback never re-enters a prompt: otherwise anyone could
shape how the agent works by typing a complaint into a channel.

Arbitrary remembered prose never becomes an executable trigger or authority. Confirmed open-ended
guidance may steer future model turns, but it cannot initiate work, count as evidence, authorize an
incident or change, approve an action, or override the current request or host policy. Deterministic
behavior remains in the closed host catalog:

- preferences: `health_check_depth`, `response_detail`, and `response_location`;
- triggers: `terraform_plan`, `deployment`, and `operational_alert`;
- actions: `review_terraform_plan`, `verify_deployment`, and `triage_alert`;
- sources: `human`, `app`, or `any`.

## 5. Shared triage, incident rooms, and engineering tasks

```mermaid
flowchart TD
  Source["Slack message or webhook"] --> Mode{"Required work"}

  Mode -- "Question, alert explanation,<br/>health check" --> Shared["Shared-channel triage<br/>persistent policy-governed Coop session"]
  Shared --> SharedResult["Reply, stay silent,<br/>or offer explicit next work"]

  Mode -- "Credible monitoring alert<br/>or explicit incident request" --> Incident["Incident occurrence"]
  Incident --> Room["Dedicated Slack room<br/>topic + invited operators + pinned card"]
  Room --> IncidentSession["One isolated Coop fork<br/>incident policy"]
  IncidentSession --> Investigate["Ordered investigation turns"]
  Investigate --> CloseIncident["Close incident"]

  Mode -- "Explicit repository change request" --> TaskOffer["Engineering-task offer"]
  TaskOffer --> Confirm{"Operator confirms?"}
  Confirm -- No --> NoTask["No writable session"]
  Confirm -- Yes --> ThreadTask["Thread-scoped task record<br/>in the source Slack thread"]
  ThreadTask --> TaskSession["Isolated Coop fork<br/>engineering policy"]
  TaskSession --> Changes["Edit, validate, commit,<br/>review exact tree"]
  Changes --> Publish{"Publish requested<br/>and publishable?"}
  Publish -- No --> Retain["Retain reviewed work"]
  Publish -- Yes --> DraftPR["Lease-protected branch<br/>and draft PR"]
  DraftPR --> Followup["Durable GitHub checks<br/>and merge follow-up"]
  Followup --> External["Human merge/deploy workflow"]
  External --> Correlate["Exact PR / branch / SHA<br/>delivery correlation"]
  Correlate --> ThreadTask
```

An engineering task uses the same durable work model as incident work but stays attached to the
source thread. Dedicated rooms are reserved for incidents. A shared-channel triage session cannot
edit files; the operator confirmation creates the separate writable task session.

## 6. Emisar tools and approval handoff

```mermaid
sequenceDiagram
  autonumber
  participant O as Configured operator
  participant S as Slack
  participant R as Responder
  participant C as Coop agent box
  participant E as Emisar

  O->>S: Exact operational request in any conversation
  S->>R: Durable Slack input
  R->>C: Prompt under declared policy
  C->>E: Discover exact action and immutable target
  E-->>C: Authorized read, denial, or pending_approval

  alt Read-only or immediately authorized result
    C-->>R: Structured evidence and outcome
    R-->>S: Evidence-backed response
  else Pending Emisar approval
    E-->>C: run + operation + pack + runner<br/>request ID + HTTPS approval URL + expiry
    C-->>R: Exact structured pending approval
    R->>R: Validate operator turn, immutable refs,<br/>Emisar origin, URL path, request ID, expiry
    R->>R: Persist conversation-bound emisar_approvals hold
    R-->>S: Approval required card<br/>Review approval in Emisar link
    O->>E: Review in Emisar console
    E->>E: Policy-owned approval, dispatch, and audit
    O->>S: Ask Responder to continue/check status
    R->>C: Continue exact wait_for_run chain
    C->>E: Read authoritative run result
    E-->>C: Completed, failed, denied, or expired
    C-->>R: Verified terminal result
    R-->>S: Outcome with evidence
  end
```

The Slack link never approves an action. Approval authorizes Emisar to dispatch; it is not proof of
successful execution. A later read of the exact run establishes the outcome.

## 7. Durability, ordering, retries, and garbage collection

```mermaid
flowchart LR
  subgraph Runs["Durable agent run states"]
    Pending["pending"] --> Preparing["preparing"]
    Preparing --> Running["running"]
    Running --> Applying["applying"]
    Applying --> Finalizing["finalizing"]
    Finalizing --> Done["completed / failed / cancelled"]
    Preparing --> Retry["pending + next_attempt_at"]
    Finalizing --> Applying
  end

  subgraph Once["Exactly-once or idempotent boundaries"]
    SlackOnce["Slack envelope/event ID"]
    WebhookOnce["Route + delivery ID<br/>and body digest"]
    DecisionOnce["source_input + mode"]
    RuleOnce["rule_id + source_input"]
    CoopOnce["Stable operation keys<br/>plus session generation"]
    DeliveryOnce["Caller-owned Slack delivery ID"]
  end

  subgraph Recovery["Recovery"]
    LostSlack["Unknown Slack POST result"] --> SearchSlack["Search metadata in history"]
    SearchSlack -->|"found"| ConfirmPost["Mark delivered"]
    SearchSlack -->|"absent"| RetryPost["Retry later"]
    TerminalSession["Closed or discarded watch session"] --> Detach["Detach session binding<br/>preserve compact memory"]
    Detach --> NextGeneration["Create next generation"]
    NextGeneration --> CleanupQueue["Queue owned session cleanup"]
  end

  subgraph GC["Maintenance"]
    Expire["Expire old inputs, evidence,<br/>memory, preferences, rules, audits"]
    Reconcile["Find orphaned Responder sessions"]
    Plan["Coop discard plan pins<br/>revision + workspace state"]
    Guard{"Workspace safe?"}
    Discard["Discard owned fork/session"]
    Block["Block cleanup and report why"]
    Reconcile --> Plan --> Guard
    Guard -- "clean, or verified published tree" --> Discard
    Guard -- "dirty, or unpublished unmerged work" --> Block
  end
```

Key properties:

- SQLite uses WAL mode, full synchronous writes, and one connection.
- One durable scheduling index stores only work identity, lane, conversation key, priority, due
  time, retry state, and lease token. Domain payloads remain in typed tables.
- Expired scheduler leases are reclaimed during normal operation. Lease-token checks stop a stale
  worker from completing work reclaimed by another worker.
- Slack inputs are leased in timestamp order within a channel, but only an actively processing
  input holds that channel. Once it queues an agent run, it is complete and cannot exhaust retries
  while the model works.
- The control lane prioritizes slash commands and buttons; long Coop work runs independently in the
  background lane.
- A short settle delay lets nearby messages enter the context snapshot before submission. Responder
  reads channel history around the target or paginates an old thread, merges it with already
  admitted inputs, excludes unrelated threads, guarantees the root and target are present, and
  persists the resulting ordered snapshot on the run for exact restart reuse.
- After the first summarized turn in a conversation, the stored last-message timestamp becomes the
  Slack history cursor. Later turns load only the delta plus the compact summary.
- A delayed older event cannot reply after a newer channel decision has completed.
- Coop create results are refreshed through `GET` because an idempotent create replay describes the
  original creation state, not necessarily the current session state.
- Replacement watch sessions use generation-aware create and run keys.
- Posts, updates, and statuses use one durable, coalescing Slack delivery ledger. Ambiguous posts
  reconcile by metadata before retry; updates retry idempotently; per-thread status generations
  ensure an older progress write cannot supersede a newer clear.
- A terminal failed watch run queues a user-facing failure, clears pending status, detaches the
  session while preserving compact memory, and queues cleanup.
- Automatic cleanup operates only on exact Responder-owned session IDs. It never accepts dirty
  work, and it accepts unmerged work only after the exact reviewed tree has been durably published.
- Channel deletion removes conversation summaries, channel-scoped memory, preferences, and rules.
  Repository reconciliation removes orphaned repository-scoped state. Normal maintenance prunes raw
  operational data and compact conversation summaries on their separate schedules. Older summaries
  are first consolidated into bounded weekly rollups: public channels by repository and private
  channels only within that channel. Source summaries are removed transactionally only after their
  rollup is durable. Confirmed operator memory is never rewritten by this process; stale and exact
  duplicate candidates enter a separate operator review queue.
- Accepted work carries a progress deadline. Maintenance surfaces an episode that has stopped
  advancing in its own thread, once per progress generation, naming the current state and what an
  operator can do. A second interval with no progress moves the episode to blocked rather than
  repeating the notice: an operator should see a state, not a second reminder. This is what makes
  "nothing accepted is silently abandoned" a property rather than an intention.

## 8. Main durable records

```mermaid
flowchart TB
  SlackInput[("slack_inputs")] --> Evaluation[("evaluation_decisions")]
  SlackInput --> RuleRun[("standing_rule_runs")]
  SlackInput --> Evidence[("evidence / coverage")]
  SlackInput --> WorkOffer["Incident or task offer"]

  Webhook[("webhook_events")] --> Signals[("signals")]
  Signals --> Incident[("incidents")]
  WorkOffer --> Incident

  SlackInput --> AgentRuns[("agent_runs")]
  Incident --> AgentRuns
  Incident --> Deliveries[("slack_deliveries")]
  SlackInput --> Deliveries
  Incident --> Timeline[("timeline_events")]
  Incident --> Proposals[("action_proposals")]
  Incident --> Approvals[("emisar_approvals")]
  Incident --> Publication[("publications")]
  Publication --> PublicationFollowup[("publication_followups")]
  PublicationFollowup --> PublicationEvents[("publication_lifecycle_events")]

  Signals --> Remediation["derived remediation record"]
  AgentRuns --> Remediation
  Evidence --> Remediation
  Timeline --> Remediation
  Proposals --> Remediation
  Approvals --> Remediation
  Publication --> Remediation
  PublicationEvents --> Timeline
  Remediation --> SlackViews["timeline / handoff / postmortem"]

  ChannelMemory[("channel_memories")] --> Evaluation
  ConversationMemory[("conversation_memories")] --> PromptContext
  ConversationMemory --> Dreaming["deterministic memory consolidation"]
  Dreaming --> Rollups[("memory_rollups")]
  Rollups --> PromptContext
  Memory[("memory_entries")] --> PromptContext["Future prompt context"]
  Memory --> Reviews[("memory_review_items")]
  Preferences[("responder_preferences")] --> PromptContext
  Rules[("standing_rules")] --> RuleRun
  Evidence --> PromptContext
  ChannelMemory --> PromptContext

  Incident --> Cleanup[("coop_cleanup")]
  ChannelMemory --> Cleanup
  Scheduler[("work_items")] --> SlackInput
  Scheduler --> Webhook
  Scheduler --> AgentRuns
  Scheduler --> Deliveries
  StatusGeneration[("slack_status_generations")] --> Deliveries
```

These are logical relationships. Not every arrow is a database foreign key; some are deliberately
bound by stable source IDs and idempotency keys so admission and recovery can remain independent.
