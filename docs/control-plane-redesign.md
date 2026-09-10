# Responder control-plane redesign

Status: primary workspace implemented; remaining stages are tracked below.
Deployment identity is the running process's x-responder-version header, not this plan.
Updated: 2026-09-05.

## Current execution: performance and three design passes

### Operator-console refinement

Remove product-template chrome that has no runtime contract: invented operator
profiles, workspace identities, presence claims, generic breadcrumbs, slogans,
decorative empty-state illustrations and repeated Lab promotions. This is an
execution console, not an account dashboard. Keep real access checks unchanged.

1. Navigation exposes requests, incidents, failures, cost and test tools directly;
   automation, context and configuration remain reachable on desktop and mobile.
2. Use a narrow, quiet navigation rail and a document-oriented main area. Page
   titles name the job. Empty states give one relevant next action. Preserve live
   freshness controls, worker availability, upcoming work and real-tool warnings.
3. Regressions prove removal of invented identities without losing routes, live
   status, drafts, actions or retained execution content. Preserve the pending
   native Slack confirmation-preview correction. Verify the changed UI boundary;
   the separate known continuity DateTime-sort defect is not part of this slice.

Browser-rendered acceptance requires an attached browser. Do not claim visual
review or deployment merely because component tests passed.

The operator's latest correction is authoritative: readable typography, useful
density and vertical rhythm, actions beside the relevant state, and one complete
scrollable execution story. Tabs and a separately scrolling event picker are not
an acceptable primary execution view.

1. Remove mandatory model-side filesystem/schema-validation round trips in Coop
   while retaining its exact-schema validator, bounded repair, semantic acceptance,
   cancellation and recovery. Measure the existing greeting again with existing
   credentials; do not claim queue tuning fixes inference time.
2. Qualify the fast admission path against recorded lifecycle cases. Keep Work
   routing unchanged, no keyword-based guesses, no undocumented OAuth API usage.
3. Design pass one: 16px reading text, legible metadata, high contrast, a consistent
   4px spacing scale and less page/card padding. Preserve the correct Slack preview
   dimensions independently from the surrounding operator UI.
4. Design pass two: combine inputs, admission, submitted requests, tool activity,
   decisions, delivery and recovery into one chronological document. Show retained
   instructions/context inline; long raw artifacts may use disclosure, but reading
   the execution must not require switching tabs. Keep stable anchors and honest
   bounds for older/expired history.
5. Design pass three: expose contextual actions, elapsed-time attribution and
   mobile layouts. Review rendered pages at desktop and narrow widths when the
   browser is attached; no visual-acceptance claim without screenshots.
6. Focused regressions after each edit, the fast precommit gate, one shipping gate
   for changed shared execution contracts, then exact-release deployment and a
   bounded live before/after check. No repeated whole-tree race/eval loops.

Current qualification: the original greeting took 135.8 seconds with millisecond
queue waits. Removing redundant schema-file/tool work reduced a same-target sample
to 93.4 seconds. That sample still required a semantic repair; its apparent
26-second Work queue was actually first-attempt execution misattributed when Coop
reset the start timestamp. Preserve first-start timing and distinguish mandatory
task validation from redundant JSON Schema checking. No authority check is removed.
Luna/low admission passed five recorded routing/lifecycle cases in 13.6–16.1 seconds
per case using the existing Emisar profile. Work targets remain unchanged.

The three source design passes are implemented. Regression coverage includes
continuous content, redaction, tied event order, bounded older attempts, retained
results without timing, and existing artifact deep links. Rendered desktop/mobile
acceptance remains pending because the in-app browser has no attached connection.
Deployment and post-deployment latency must be verified separately; these numbers
are individual samples, not a p95 or a reliability benchmark.

This is the current plan for the Elixir control plane, fast admission, model
observability, the learning flywheel, and simpler configuration. It supersedes
the technology and layout proposals in [Control plane](control-plane.md), while
preserving that document's product capabilities. [Architecture
next](architecture-next.md) remains the lifecycle and authority contract.

## Product contract

### From-zero UX correction (approved 2026-09-05)

The operator rejected the old dashboard and the incremental shell around it.
The primary workflows must be native HEEx/LiveView components, not legacy HTML
snapshots with a new stylesheet. Design the application around operator jobs:
an activity inbox, a conversation and execution inspector, a conversation test
bench, and a native Slack specimen workbench. Put configuration and diagnostics
in secondary navigation. Empty states explain what to do; no landing-page grid
of zero counters. Retain functional legacy routes while migrating their bodies.

Implement in order: shared navigation and visual primitives; activity projection
with readable requests, search and status filters; conversation and execution
detail; Lab and Card Lab; secondary operational pages. Preserve durable action
contracts and test each owning boundary. Qualify and install the actual release
before calling any of this usable at the existing localhost address.

Use existing Coop credential profiles. A new API key is not a user prerequisite:
the classifier implementation must fit supported existing authentication, and
must not repurpose subscription OAuth as an undocumented public API credential.
The operator selected **Emisar #test** for native Slack specimens and transitions.
Resolve and verify its workspace and channel before posting; never use Blitz.

### Current native workspace slice (2026-09-05, source implementation)

Activity, episode conversation/timeline, retained-request inspection, Conversation
Lab, and Slack Card Lab are now native HEEx views. Navigation is shared with
confirmed HTTP actions, including mobile Manage. Operational secondary routes
still retain their existing bodies inside that shell; this is not the completed
whole-product migration.

The review board found and the implementation closed: lost Usage drill-down
filters, changing inspector selection during refresh, hidden admission recovery,
stale edited/deleted input summaries, disappearing earlier answers, draft loss
after delayed send receipts, stale submitted-edit restoration, notification
backlogs, silent projection exceptions, missing mobile navigation, and missing
Lab validation/announcements. Cost drill-downs preserve live/shadow/all scope.
Refresh reconciliation never rewrites retained model artifacts.

Card Lab has native family/state navigation, wide/compact preview, payload
inspection, pure local transitions, feedback, and explicit channel-name review.
Slack retry confirmation uses the frozen post state; reconciliation is bounded
to the request creation window and execution is interrupted before its lease
expires. Exhausted expired claims stop at the same eight-attempt limit.

Pre-installation evidence: make dev-check passed, including 1,803 Elixir tests
with 90% coverage, 80 host-replay tests, 22 recorded contract replays and seven
draft/validation JavaScript tests. Named offline integration checks traverse HTTP
confirmation, persistent specimen custody, the delivery worker and the Slack
client through posting, rate limiting, retry and in-place update. Active leases
exclude concurrent updates. These are not native browser acceptance.
Live Slack acceptance verified the existing bot in Emisar `#test`, posted one
incident-room specimen, and updated the same message from provisioning to
resolved. Slack read-back confirmed the exact receipt, metadata and eight Block
Kit blocks. That check also exposed own app messages entering admission because
app identity masked bot identity. A harvested-payload regression covers posts,
edits and deletes; self checks now precede actor projection. Other apps remain
eligible inputs. The in-app browser provider lists no browser, so rendered
visual acceptance remains unverified; API read-back is not a visual review.

A real Conversation Lab smoke check completed with the existing Emisar Coop
profile and Terra/medium, including durable admission usage. It took about 128
seconds end to end. Existing credentials work, but this does not meet the speed
requirement and is not evidence that fast classification is complete.

The shipping gate also exposed a pre-existing cross-clock readiness defect:
PostgreSQL's card refresh timestamp could precede an application's offer timestamp.
A deterministic clock-skew regression now preserves acceptance of the exact
rendered offer, while unseen offers and crossed destinations remain rejected.
The immutable rendered offer reference, not cross-clock ordering, is the proof.
Migration round trips include every new version and retain the earlier rollback
refusal tests. The retention registry now explicitly owns classifier artifacts,
synthetic Slack specimens, and compact accounting.

Fast classifier execution, the complete learning workflow, v2 configuration,
provider-invocation/descendant accounting and estimates remain separate open
stages. Existing Coop credential profiles remain the required authentication
path. Do not mistake the new inspection UI or parallel admission slots for a
completed low-latency classifier implementation.

An operator should be able to open a conversation and immediately understand:

- what the person asked and what Responder has answered;
- what it is doing now, how long that has taken, and whether intervention helps;
- exactly which retained instructions, messages, context, and tools were supplied
  to each model call;
- why a decision was accepted, rejected, escalated, or retried;
- what every attempt consumed, including admission and unsuccessful attempts;
- what feedback became a correction, regression case, or model improvement.

Slack, GitHub, and Conversation Lab use the same durable processing pipeline.
The Lab has the same configured model and governed tool capabilities as its
selected repository context, including Emisar. Testing must not require sending
messages to Slack. Card Lab remains a separate, exhaustive card-state workbench.

### Card Lab must render in real Slack too

Every message specimen, including `/card-lab/incident-room/provisioning`, needs
an explicit **Post to Slack** action with a workspace/channel confirmation and
a link to the posted message. Use the configured Emisar workspace, never the
Blitz workspace. Selecting or browsing a specimen never posts automatically.
Retain delivery state and the exact payload revision; offer updating the same
posted specimen through its states, not a new message for every transition.
Reconcile uncertain delivery outcomes without duplicate posts. Mark specimens
as test content and isolate their controls from real incident/task actions.

The in-browser preview should follow Slack Block Kit typography, spacing,
fields, sections, context, buttons, and overflow behavior. Clearly label it an
approximation; actual Slack is the rendering authority. Message, App Home,
modal, and thread-status specimens must use their correct Slack surface rather
than pretending every payload is a chat message. Explain prerequisites and
unsupported surface actions honestly. Preserve state-specific feedback and link
it to the specimen revision and posted receipt when present. Verify posting,
in-place transitions, authorization/CSRF, unsafe-action isolation, retries, and
native Slack rendering before calling the workbench complete.

Speed is an end-to-end requirement. Reliability includes semantic quality as
well as crash recovery: a fast, schema-valid answer that silently ignores an
important message is a regression.

## Current evidence and first acceptance case

The inspected `ingress-input:ee33b16b-710c-4da4-a47b-72a7392872d1` episode took
about 57 seconds before admission committed and another 82 seconds for Work to
finish with "Hello! How can I help?". The page's roughly 1.4-minute elapsed time
excluded admission. Its missing source-message join, withheld retained prompt,
and inconsistent repair counts made this difficult to discover in the UI.

The admission call used Terra/medium through a Coop agent session, including
workspace preparation and tool-based JSON validation. The 30-second host
deadline caused a deferred reconciliation of the same remote operation, rather
than a second independent model call. Extending that deadline alone cannot
remove the latency. These observations are a baseline for this case, not a
general attribution of all latency to inference.

The first usable slice must make this conversation readable, show the complete
elapsed time, expose admission progress and the retained request, and avoid
making the same trivial conversation wait through a general-purpose agent
workflow merely to classify it.

## 1. LiveView throughout the control plane

Use Phoenix LiveView, HEEx components, and Phoenix.PubSub over Bandit. Phoenix
and LiveView are new dependencies in this checkout; pin compatible versions and
package all assets in the release. No CDN or external telemetry. Keep styling
small and owned by the application, with server-rendered charts where useful.

Replace the control-plane Plug entry point with a Phoenix endpoint, migrating
routes in slices. Preserve existing URLs, action contracts, loopback binding,
and the separate Slack, GitHub, state-tool, and fleet listener boundaries.
Use Phoenix session/CSRF protection and explicit same-origin WebSocket checks.
Do not broaden network exposure as part of this migration.

### Committed state drives live views

- PostgreSQL remains the source of truth. A LiveView process owns presentation
  state only; it never owns admission, Work, delivery, or a job lease.
- Emit compact transactional PostgreSQL notifications for relevant committed
  changes and bridge them to scoped PubSub topics. Notifications carry domain
  references, never prompts, message bodies, credentials, or tool payloads.
- Notifications are invalidation hints, not a durable event log. Subscribe before
  the initial snapshot, re-query affected projections, coalesce bursts, and
  resnapshot on reconnect. A bounded periodic reconciliation catches lost hints.
  Rolled-back writes must never appear as committed progress.
- Update records selectively with LiveView streams. Keep ordering, filters,
  expanded inspectors, selection, scroll position, and unsent chat drafts stable.
  Show a "new items" affordance when inserting rows would move what someone is
  reading. Auto-follow transcripts only while the reader is at the bottom.
- Show disconnected, reconnecting, last-observed, and stale states truthfully.
  Pausing the visual feed never pauses the worker.
- Recheck durable state and authority on every action. Disable invalid controls
  with an explanation; stale forms must not repeat or bypass an operation.
- Read external provider/worker status centrally at an appropriate cadence, then
  publish observed changes. Each browser must not independently poll providers.

Coverage includes Overview, episodes, incidents, failures, decisions, schedules,
subscriptions, channels, repositories, workspaces, memory, usage,
Usage, Configuration, Conversation Lab, Card Lab, feedback, and test journeys.
"Real time" means changes appear as they are committed or observed; an external
service with no push signal must display the age of its last observation.

## 2. Fast admission with preserved authority and recovery

### Execution path

Admission needs a bounded, no-tools structured classifier. Remove repository
forking, an agent tool loop, shell-based schema validation, and unnecessary
round trips from that path. Work continues to use full Coop sessions.

Keep classifier execution behind the trusted Coop execution/credential boundary.
First verify whether Coop has a suitable durable, no-workspace inference API;
do not assume an existing session API provides that behavior. If it does not,
the implementation needs a bounded Coop capability with request identity,
reconciliation, cancellation, usage, and pinned model configuration. Do not
silently create a second provider-credential or production execution path in
Responder to make a latency graph look better.

Start qualification with a genuinely small/low-reasoning hosted classifier.
Select the actual target using the harvested admission corpus and latency
measurements; a model family name is not proof that it is fast enough. Keep the
user-selected Work routing unchanged:

| Work class | Model | Reasoning |
|---|---|---|
| Conversational | Terra | Medium |
| Standard | Sol | Medium |
| Deep | Sol | Xhigh |

The classifier protocol is provider-neutral so that an authenticated,
organization-local endpoint can replace the hosted target later without
changing admission semantics. Local hosting and training are future work;
the data collection and evaluation loop are in this implementation plan.

### Safe decisions and escalation

- Preserve frozen input/context, candidate bounds, revisions, destination checks,
  authority checks, leases, execution generations, and atomic admission commit.
- Deterministic handling is appropriate for authenticated explicit controls,
  already-seen duplicates, and other events whose action the host already knows.
  It is not a greeting/keyword rule that guesses whether a message belongs to
  an episode. Historical lifecycle and mistaken-merge regressions remain gates.
- The fast classifier proposes the existing semantic decision, or explicitly
  abstains. Escalate abstentions, unsupported cases, and invalid decisions to a
  qualified stronger classifier. Confidence self-reports alone are insufficient.
- Define eligible traffic from evaluated cases and structural capabilities.
  Measure false ignores, false starts/merges, missed continuation, incorrect Work
  class, and lifecycle errors separately. Never hide a regression in an average.
- An unknown remote outcome is reconciled by the same request identity. A
  deadline-driven escalation has a durable generation and a single fenced
  winner; late responses cannot create duplicate episodes or Work. Account for
  both calls if both consumed inference. Exhaustion remains visible and
  recoverable, never converted to an implicit ignore or permissive default.
- Bound concurrency and queue size, with fairness between conversations and
  preserved ordering within a conversation. One slow classifier must not occupy
  the sole admission execution slot indefinitely. Overload becomes explicit
  backpressure with durable custody, not dropped inputs.
- Run independent read-only preparation concurrently where safe. Do not launch
  speculative Work or external side effects before admission commits.

### Visible progress

Persist admission attempt boundaries and outcome facts: received, queued,
context prepared, execution requested, provider started when observed,
response received, host validation, escalation/retry, and committed/blocked.
Show timestamps, durations, the actual target, deadline/retry reason, and last
confirmed activity. Do not invent percent complete or stream private reasoning.

Distinguish execution attempts from lease claims, host reconciliation polls,
validation preflights, and semantic correction turns. Responder must not call
three rejected validation preflights "zero repairs" without explaining the
different categories.

### Performance acceptance targets

These are proposed release targets, not current measurements or guarantees:

- Durable input acknowledgement: p95 under one second on the supported local
  topology, excluding the upstream platform's delivery delay.
- Committed state to connected UI: p95 under 500 ms on that topology.
- Ordinary eligible admission: p50 at most one second and p95 at most three
  seconds with a warm provider; report cold starts and escalation separately.
- A simple no-tools conversational reply: target p95 under ten seconds end to
  end. Instrument Work startup too; removing admission latency alone cannot meet
  this target if Work still takes a minute.

Measure under a documented offered load with queue depth, sample size, and
per-class semantic results. A candidate missing reliability gates is not
promoted to satisfy a latency target. Statistical testing cannot prove zero
future errors; preserve runtime safeguards and make residual semantic risk
observable and reversible through a pinned model configuration change.

## 3. The episode as a readable case file

Use the existing Emisar visual language: compact typography, quiet dividers,
clear status semantics, and three to six scan targets per table with secondary
facts stacked below primary facts. Preserve the desktop schedule rail where
useful and collapse it on narrower screens. Avoid an undifferentiated grid of
cards and UUID columns.

Group navigation by operator job: Activity, Inspect, Improve, and Settings. The
episode header leads with the user's request, human-readable source, repository,
current phase, total elapsed time, and cost coverage. Put raw identifiers,
digests, revision numbers, and transport metadata in a technical-details drawer
with copy actions. Missing names must be labeled as unresolved, not invented.

The default episode view combines:

1. The conversation and the latest answer or precise current wait.
2. A phase timeline: input, admission, context, Work, validation, delivery,
   follow-up. Timing begins at input receipt, not episode creation.
3. An expandable attempt list with instructions/context, model output, tools,
   corrections, usage, and outcome for each actual invocation.
4. Evidence, decisions, approvals, related work, and delivery receipts in context.

Keep accepted model output, rejected candidates, and the actual delivered
message distinct. A model finishing does not mean Slack/GitHub delivery landed.
Deep-link to a phase, attempt, tool call, context section, or failure. Filters and
time windows stay in the URL. Provide bounded pagination and lazy loading so
large histories remain inspectable without loading everything into a socket.

### What the model actually received

Provide a dedicated, redacted model-request inspector, rather than relying on
the current general-purpose safe metadata projection:

- Responder system/developer instructions and the exact retained submitted
  prompt, with role boundaries where recorded;
- source messages, recent conversation, summaries, memory, repository revisions,
  selected evidence, and explicit omissions or truncation reasons;
- tool names, schemas, output contract, effective execution target, and enforced
  capability scope;
- response, parse/validation result, repair instructions, tool arguments and
  results where retained and safe, and delivery transformation;
- a readable view plus sanitized raw request and a comparison between attempts.

Freeze request artifacts at submission time; do not rebuild a past prompt using
today's templates. Label Responder's submitted request separately from any Coop
wrapper or provider-owned instruction that was not exposed to Responder. Never
claim the complete provider request is available when only one layer is stored.
Do not collect private chain-of-thought.

Redact before sending data to the browser, exports, logs, or a learning dataset.
State that redacted text differs from the retained original; preserve the
original artifact's digest for identity without presenting redacted bytes as an
exact byte-for-byte export. Render text safely, not as executable HTML. Show
"not recorded", "redacted", "truncated", and "expired" as different conditions.
Historical absent tool bodies or expired artifacts cannot be reconstructed.

Separate bounded inspection artifacts from short-lived operational session
bodies in the retention design. Pin unresolved/live work as today; use explicit
retention for sensitive request bodies, reviewed training examples, and compact
audit receipts. Do not retain all prompts forever merely to improve the UI.

## 4. Cost is a first-class property of work

Introduce durable per-invocation accounting across admission, escalation, Work,
repair, cancelled/failed attempts, and subordinate tasks. Record the effective
provider/model/effort, token dimensions, measured flags, start/finish boundaries,
and provider cost when supplied. Polling the same cumulative measurement must
not repeatedly add it; use immutable invocation identity and explicit revisions.

Show provider-reported cost and estimated token cost separately. Estimates use
versioned, effective-at-execution rate cards and the provider's actual token
semantics, including cached and reasoning tokens; do not double count overlapping
dimensions. Missing usage is unknown, not zero. Report partial coverage such as
"3 of 4 calls measured". Subscription token estimates are not an actual invoice.

Each episode/task shows own cost and inclusive descendant cost without counting
shared children twice. Usage can drill down from organization/time window to
repository, integration, model, episode, task, and invocation. Include admission
spend even when no episode was created. Keep historical prices reproducible;
changing today's configuration must not silently rewrite yesterday's estimates.

## 5. Restore the learning flywheel

The learning loop captures corrections, reviews fixture candidates, promotes
approved cases into a replay corpus, and compares model profiles. Reuse those
semantics rather than building a disconnected analytics dashboard. The current
admission fixtures and `Responder.Evals.AdmissionCase` are the starting corpus.

The new durable loop is:

1. Capture a sanitized input/context/output/host-outcome record for model calls,
   with model and configuration versions, timing, cost, and organization scope.
2. Associate user corrections, operator feedback, and downstream outcomes with
   the specific decision. Slack/GitHub reactions are weak feedback signals, not
   automatically a correct label; distinguish custom emoji and platform events.
3. Review proposed cases in the control plane. Separate host bugs from model
   mistakes; record reviewer, label provenance, rationale, and approval/rejection.
   Stronger-model suggestions are proposals, not ground truth.
4. Promote approved, sanitized cases idempotently into a versioned regression
   corpus. Include a representative sample of accepted traffic, not only failures.
   Keep deterministic host replay separate from credentialed model evaluations.
5. Compare candidate and baseline on per-class quality, corrections, abstentions,
   latency, and cost. Every report pins dataset, prompt/contract, actual model,
   effort, provider, and configuration; do not repeat the old attribution gap
   where replay quality could not be joined to an actual model identity.
6. Approve an explicit model configuration change only after quality gates pass.
   Keep the prior target recoverable. Use ordinary deployment and database
   recovery; do not reintroduce a canary/promote deployment state machine.

Hold out conversations/lifecycle families and later time windows together to
prevent train/eval leakage. Never include context that arrived after the
decision in the classifier's replay input. Keep organizations' datasets and
visibility boundaries separate. Capture/export is bounded, auditable, and
retention-aware; data is not automatically sent to a training provider.

A bounded off-critical-path shadow queue may compare a stronger classifier or
propose labels. Its budget and failures must not slow live admission. Future
local training consumes the approved org-specific dataset; merely accumulating
messages is not a training pipeline, and a new local model must pass the same
held-out reliability gates before taking live decisions.

## 6. Configuration from the operator's point of view

Today, `admission.policy.name` selects a trusted Coop execution policy and
`digest` pins its exact content. A policy controls more than a model: depending
on the execution lane it includes repository/tool/credential access and limits.
The authority digest prevents a change of Work class from widening permissions.
These protections remain necessary. Requiring operators to duplicate policy
maps, opaque hashes, timeouts, and polling intervals throughout YAML is not the
intended product interface.

The new configuration has three comprehensible responsibilities:

- Connection: the deployment identity, database/secret references, and trusted
  execution connection are configured once.
- Behavior and access: choose models, repositories, permitted capabilities,
  integrations, and retention using named purposes and human-readable durations.
- Effective execution: Responder resolves reviewed worker policies, validates
  grants, and pins immutable revisions internally. Show a readable effective
  configuration and provenance in the UI.

The following is a **proposed v2 model section**, not valid input for the current
v1 loader and not a complete deployment configuration:

```yaml
version: 2
models:
  admission: fast
  conversational:
    model: gpt-5.6-terra
    reasoning: medium
  standard:
    model: gpt-5.6-sol
    reasoning: medium
  deep:
    model: gpt-5.6-sol
    reasoning: xhigh
```

`fast` is a shipped, qualified preset resolved to an exact provider/model/effort
and escalation target when configuration is applied. It must not float silently
between calls. `explain` and the UI show those actual targets, preset revision,
and effective limits. Advanced users can specify an explicit qualified target.
The final v2 schema must define the whole configuration, not just this fragment.

Implementation requirements:

- Repository bindings select a shared model profile by default. Lab and Slack/
  GitHub reference the same repository context; no copied Work-policy block.
  Keep explicit overrides only where behavior or authority really differs.
- Separate model choice from capability grants. Resolve/generate policy pins
  from reviewed configuration; never manufacture a permission the independently
  enrolled worker has not granted. Show requested versus available capabilities
  and actionable mismatch errors. Contributor and schedule authority remains
  explicit where it differs from ordinary conversational Work.
- Generate the machine lock/receipt from configuration and trusted worker
  attestations. Operators review semantic changes, not hand-written digests.
  Recovery always retains the original effective configuration of active work.
- Default polling, lease, retry, and provider deadlines centrally. Optional
  expert overrides belong in one documented advanced section, with durations
  such as `30s`, validation, and an explanation of their effect. Changing a UI
  progress deadline must not accidentally change custody or provider cancellation.
- Secrets use environment/secret references and never render in effective config.
  Do not turn one large YAML file into several mandatory files that repeat it.
- Provide validate, explain, and v1-to-v2 migration tooling. These commands are
  planned, not currently available. Migration must resolve real worker policies,
  detect unknown fields and missing grants, show semantic differences, and
  preserve all supported v1 capabilities, including fleet, repository sets,
  integrations, schedules, retention, and evaluation isolation.
- Move the example, docs, doctor/status, deployment loader, tests, and local
  development setup together. Do not publish an example the release cannot load.
  Retire legacy input support only after migration and recovery are proven.

## 7. Implementation order and proof

### Implementation evidence (2026-09-05)

- Added native Slack message specimen posting to the plan and implementation:
  destination review, CSRF-bound confirmation, frozen Block Kit, stored delivery
  state, same-message updates, and lost-response reconciliation. Native App Home,
  modal, and thread-status launching still require their separate surface work.
- Reproduced the reported missing source link and admission-excluding elapsed
  time in failing tests, then corrected both projections.
- Corrected local Slack formatting and added HTML-inert rendering tests.
- The focused control-plane/Slack group passes 91 tests in about four seconds.
  Tests use a fresh isolated database because the pre-existing shared test DB
  lacked an already-versioned activity column. No production DB was changed.
- Phoenix 1.8.10 and LiveView 1.2.9 dependencies are pinned and compile cleanly.
  The endpoint, loopback/origin guards, locally served assets, live shell,
  transactional PostgreSQL invalidation bridge, and reconnect reconciliation are
  implemented. Six focused live/notification/server tests pass. Browser visual
  and draft/reconnect acceptance is still outstanding: the in-app browser
  currently reports no available browser connection.
- A separate request inspector reads frozen Work submissions with sanitized
  instructions, context, tool contracts/activity, candidate, and delivery views;
  it labels absent historical admission prompts and expired artifacts honestly.
  The 47-test inspector/projection/router/live regression group passes in about
  four seconds. Full inspector comparison, readable context components, and
  future admission artifact custody remain in progress.
- Admission now has four bounded slots with SQL-enforced ordering across each
  destination conversation. Tests cover concurrent claims and retry backoff;
  unrelated conversations can progress independently. The 82-test focused
  admission/inbox/configuration/readiness group passes in under two seconds.
  This is queue isolation, not proof of faster inference. The required no-tools
  classifier API is absent from the inspected Coop session implementation.
- New admission executions now journal their frozen submitted bytes, pinned
  policy, observed remote identity, milestones, response, and validated telemetry.
  Same-generation retries reuse the frozen submission; stale executors cannot
  update another generation. Committed status is written with the input decision.
  Lab shows observed admission phases and links to the request inspector before
  an episode exists. Prompt artifacts follow input retention, while fingerprints
  and compact measurements remain until input audit expiry. The 76-test focused
  admission/inspection/retention/router group passes in under four seconds.
- Fast inference, full accounting/learning, simplified configuration, complete
  UX and browser/native acceptance, release qualification, and deployment remain
  in progress or unimplemented. The evidence above is not whole-plan completion.

### Subsequent implementation evidence and acceptance prerequisites

- Episode pages now lead with a HEEx case-file component: retained source text,
  the current wait, accepted reply versus confirmed delivery, and expandable
  identity details. Source text is sanitized before rendering. The surrounding
  LiveView shell still reprojects legacy pages; selective domain streams and the
  complete page-by-page migration are not finished.
- Added compact `execution_usage` custody separate from expiring prompts and
  operational rows. Work records submission, observed running/terminal state,
  cancellation and accepted timing; admission records submission and observed
  usage before an episode exists. Input commit attaches its accounting records
  to the eventual episode. Generations remain distinct, current owners are
  fenced, and repeated cumulative telemetry is never summed twice. Sparse later
  polls cannot erase known usage. Usage combines this ledger with explicitly
  unmatched legacy snapshots, including unaccepted bound turns, and separates
  live/shadow execution. Episode pages show measured-cost coverage.
- Cost qualification still needs per-provider invocation and child-task
  attribution, versioned token-price estimates, provider-specific overlapping
  token semantics, and compact-accounting retention configuration. The current
  execution-level ledger is not falsely labeled full per-model-call accounting.
  Recorded regressions now cover false measured prices, missing-price token
  preservation, bigint overflow, failed/cancelled accounting, sparse polls,
  generation fencing, and survival after operational-record removal.
- The Lab composer uses the same CSRF-protected durable action with an explicit
  acceptance receipt. Live patches preserve the form and selected files. Text
  is cleared only after acceptance, and a newer draft is retained. Unknown
  network outcomes never trigger automatic resubmission. Three offline Node
  tests cover these transitions and now run in both repository gates. Browser
  interaction and visual proof remain outstanding.
- The final focused Elixir regression batch for this slice passes 156 tests in
  about eight seconds. A separate 137-test accounting/projection/retention batch
  also passed. These are focused offline results, not full release qualification
  or production-like acceptance. No credentialed model tests were run for these
  UI edits.
- The read-only Coop architecture review confirmed that the existing session
  service cannot provide tool-free/workspace-free inference. It needs a separate
  durable inference resource, direct-provider adapter, recovery/cancellation
  lifecycle and explicit outbound-worker capability. No Coop source, worker
  credential or running process was changed during that review.
- Checked the configured Emisar and personal Codex credential shapes without
  exposing secrets: both use ChatGPT sign-in, not API-key authentication. No
  `OPENAI_API_KEY` was found in the checked ambient/shared Coop configuration.
  The operator subsequently required use of those existing profiles. The
  direct-public-API proposal is not an approved reason to require new credentials.
  Verify a supported execution path with the existing authentication instead.
- Native Slack acceptance is authorized in Emisar #test; destination resolution
  and verification remain to be performed. The in-app browser was rechecked and
  still reports no available connection. No speculative Slack destination was used.
- All changes remain source-only: no commit, `make dev-check`, full `make check`,
  release installation, service restart, live model call or Slack specimen post
  has occurred. The existing listener on port 4321 has not been replaced.

### Ordered slices

Each step is independently reviewable; there is no prerequisite to finish every
page before an operator gets a usable episode view.

| Step | Owning code and change | Done condition |
|---|---|---|
| 1. Admission truth and baseline | `admission/executor.ex`, ingress custody, `control_plane/episode_trace.ex`, new attempt records; repair source joins, elapsed boundaries, and validation counts | Named regression tests reproduce the reported episode's presentation errors; admission failure/retry facts survive restart; a bounded baseline attributes queue, setup, provider, and host time |
| 2. LiveView foundation and first case file | `mix.exs`, `control_plane/server.ex`, router, new endpoint/LiveViews/components, transaction notifications | Episode and Lab update from committed DB changes without reload; rollback, lost notification, reconnect, CSRF/origin, stable draft/selection, and stale action tests pass |
| 3. Fast classifier | `admission/worker.ex`, executor, decision/commit, Coop capability if needed, admission corpus | No-workspace classifier path meets measured latency/semantic gates; abstention, fallback, lease expiry, crash, overload, duplicate and late-result races retain single-commit behavior |
| 4. Request and tool inspector | Work submission/activity, admission artifacts, trace projection, retention, LiveView inspectors | Historical submitted bytes remain attributable; redaction/XSS/omission/expiry tests pass; all retained attempts are reachable with bounded pagination |
| 5. Complete accounting | `work/measurement.ex`, admission measurement, new invocation accounting, Usage projections | Failed/cancelled/admission/child calls count once; partial/missing usage, provider cost versus estimates, effective prices, and cached/reasoning dimensions have focused tests |
| 6. Whole control-plane UX | Replace monolithic `control_plane/html.ex` pages with shared HEEx; migrate operator projections/actions | Every existing route/action and card state has a retained capability and live-update check; keyboard/narrow-screen, empty/loading/error/disconnected states are verified |
| 7. Reviewed learning loop | `evals/`, correction/feedback persistence, fixture promotion, review and comparison views | A harvested correction flows through review into deterministic replay; rejected/unreviewed examples cannot enter the approved set; org isolation, deduplication, leakage, model attribution, and promotion denial are tested |
| 8. Simple configuration | `runtime_configuration.ex`, example YAML, effective-config/doctor views, worker policy resolution, migration | Real v1 configs translate without authority expansion; unsupported values fail clearly; restart resumes pinned old work; all shipped examples validate |
| 9. Release acceptance | Integration journeys, focused load/recovery tests, release/deployment scripts | Qualified immutable release is running; health/readiness and the reported episode, Lab, Slack/GitHub card/delivery boundaries are checked on that release |

Paths in the table are relative to `lib/responder/` unless otherwise stated.
Add migrations under `priv/repo/migrations/` and owning tests under
`test/responder/`. Before implementing the Coop capability or Phoenix wiring,
verify the actual dependency API and pin supported contracts.

For each production bug, first add the test that fails for the actual defect,
using harvested data. Run the owning Elixir tests during iteration. Run
`make dev-check` before committing and `make check`
once before shipping the persistence/security/shared-contract changes. Model
quality qualification is a separate bounded gate, never an unbounded repeated
whole-tree test loop. Run credentialed model evaluations when the classifier or
prompt contract changes, not for CSS or LiveView edits.

Browser acceptance must cover a populated real case, a long episode, missing
historical artifacts, delayed admission, retries, reconnects, multiple tabs,
unsent drafts, keyboard navigation, and narrow screens. If the browser backend
is unavailable, report that limitation; HTTP assertions are not visual proof.
Live Slack/GitHub acceptance is required for changed platform boundaries, not
for every layout iteration. Record exact code/test/deployment evidence, and
never describe a plan, a passing gate, or a local preview as a deployed feature.

## References

- [Original control-plane capabilities](control-plane.md).
- [Admission lifecycle contract](elixir-ingress-admission.md) and
  [harvested Slack admission corpus](elixir-slack-admission-corpus.md).
- [Testing and the historical regression flywheel](testing.md).
- [OpenAI latency guidance](https://developers.openai.com/api/docs/guides/latency-optimization):
  choose appropriately sized models, minimize unnecessary generation/round trips,
  and parallelize independent work; these are design inputs, not measured latency
  promises for this runtime.
