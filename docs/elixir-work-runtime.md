# Elixir work runtime

Stage 3 turns one admitted episode into durable, locally pooled model work. It is deliberately
generic: no Slack provider name, alert type, repository name, or incident checklist affects this
runtime.

## Boundary

The episode kernel remains the lifecycle authority. The Work module stores only the identities and
bytes needed to safely execute that episode through Coop:

- one immutable Coop session generation with its admission-pinned policy;
- one episode-scoped logical turn row;
- the exact frozen prompt, context, output schema, and contract version;
- the exact unpublished candidate and candidate attempt;
- the exact semantic verdict before Coop is mutated;
- one accepted result and, for a visible reply, one delivery intent;
- one fenced PostgreSQL lease and bounded failure state; and
- one durable remote-cancellation intent and proof.

There is no mirrored provider transcript, progress-event stream, attempt table, alert profile, or old
typed-operation union. Coop owns provider execution. The episode kernel owns lifecycle. Later state
tools own durable records. The generic Delivery module owns external message and reaction custody.

## End-to-end flow

1. Admission commits the input and pins a trusted Coop policy in the same transaction.
2. One slot in the local worker pool claims only a `turn` owner using PostgreSQL time and
   `FOR UPDATE SKIP LOCKED`.
3. The runtime freezes the exact self-contained first briefing. A continuation in the same healthy
   Coop session sends only new input plus a parent-submission reference.
4. Coop creates the session and turn under stable operation keys derived from immutable local rows.
5. Responder stores each candidate's exact bytes, SHA-256, and attempt before validation.
6. The universal validator returns every hard, actionable violation at once. Rejection continues in
   the same Coop turn and session.
7. Responder freezes the exact accept or reject mutation before calling Coop. Lost responses are
   reconciled by operation key and current turn state.
8. A validated accept atomically stores the result and advances the episode. A visible result becomes
   `delivery_pending`; deliberate silence settles immediately with an audited reason.
9. Model workers cannot claim delivery work. A separate bounded Delivery pool claims the frozen
   intent, renews its independent lease across bounded provider I/O, selects only a trusted transport
   adapter, and records a typed external receipt atomically.

## Reliability rules

- Process clocks do not decide leases or retry time; PostgreSQL does.
- A worker cannot choose episode policy. Admission chooses only the abstract conversational,
  standard, or deep class and maps it through a host-owned profile. Existing episodes retain their
  pinned policy across deploys and later classifications.
- Every class policy carries Coop's model-independent authority digest. The three classes must share
  it, each eligible fleet worker must advertise it, and the created Coop session must return it.
- A frozen submission never changes under one operation key, even after a process crash or deploy.
- Only a confirmed failure that produced no remote resource may spend a create or submit generation.
- Only `session_cleanup_error`, while the exact candidate still awaits validation, may spend a
  validation generation. Other confirmed validation failures block instead of looping.
- `operation_uncertain` never receives a new key unless the public remote resource proves the result.
- Candidate identity is `(attempt, SHA-256)`, so byte-identical correction attempts remain distinct.
- A completed validation receipt must carry that same attempt as well as the exact candidate digest;
  an older byte-identical receipt cannot settle a newer candidate.
- At most two exact current input envelopes advance into one turn. This keeps the original request
  and one correction together under the 160 KiB context ceiling; further inputs remain durably
  ordered for later turns instead of being truncated. If corrected work blocks again, the next
  recovery pair keeps the original request and the newly triggering correction; the consumed
  correction remains durable history instead of hiding newer feedback.
- Every model-visible input carries one immutable host-issued `source_ref`. Slack and GitHub inputs
  use their opaque platform source references; a generic input uses its episode-admission reference.
  State tools can therefore cite or propose memory from the current instruction without guessing a
  raw platform ID or an internal database key.
- Inputs still in `queued_input_refs` are future work, not compact history. They are absent from the
  current prompt until the kernel advances their exact envelopes into the next active pair.
- Actual transient failures use bounded exponential backoff and enter remote-stop custody after
  eight failed claims. A healthy running Coop operation or turn yields its lease without spending
  that failure budget.
- Interrupted, cancelled, budget-exhausted, or otherwise unsafe terminal turns are surfaced in
  blocked custody; the host does not silently replay a human instruction after Coop says send intent
  may have happened.
- An active remote turn must be cancelled through Work custody. Responder first freezes the intent,
  reconciles Coop's idempotent cancellation, and only then cancels or transfers the episode owner.
- If Stop races a prepared create or submit before a remote resource is known, Responder calls Coop's
  exact operation fence. The fence either prevents that mutation from starting or returns the
  operation/resource that already won the race. Cleanup never creates fresh work after authority was
  revoked, and a lookup miss or timeout is never treated as proof of absence.
- The exact accepted result survives newer queued input. New input advances only after the accepted
  visible reply is delivered, or after deliberate no-delivery settlement.
- Delivery retries are bounded independently from model execution. Permanent platform errors and
  exhausted transient retries preserve the exact accepted result in operator-rearmable blocked
  custody instead of polling a provider forever. Operators inspect or rearm that immutable intent by
  durable reference with `mix responder.delivery list|show|rearm`; a rearm starts a separately audited
  retry generation with a fresh bounded attempt budget.

## Memory and background learning

PostgreSQL owns memory; a warm Coop session is an execution optimization, not the durable owner.
The memory pipeline has separate read, learn, and act decisions:

1. Admission returns only `action`, `episode_ref`, `reaction`, `relation`, `reason`, and
   `work_class`. Its schema has no `observation` or `knowledge` output. Committing a retained input
   records a bounded original-message excerpt and its exact source receipt, including for silence.
2. The optional `Responder.Learning.Runtime` coalesces decided input revisions in the same writable
   scope and execution mode. A revision belongs to one durable batch. Quiet/max-delay clocks start
   when admission made it eligible, not when the historical source message happened.
3. `State.Learning` freezes the selected original inputs, eligible existing subjects, prompt,
   schema, policy digest, and remote operation identities. It is the sole model writer of topic
   knowledge. The learner can return no change without replying or creating an episode.
4. Work receives selected authorized knowledge plus recent uncovered source excerpts. Its separate
   `update_conversation_summary` tool proposes a conversation handover; that handover becomes
   recallable only when the associated Work candidate is accepted.
5. Confirmed facts, preferences, guidance, waits, goals, and operational authority retain their
   existing owners. Learned prose cannot confirm a preference, start an incident, or grant a tool
   permission. Shadow learning never authorizes live delivery or crosses into live memory scope.

### One subject, several updates

The learning result is `{updates: [...], reason: "..."}`. Every item selects exact offered
`source_input_ids` and one action:

| Action | Required meaning |
|---|---|
| `update` | Copy an offered writable `target_ref`, its `expected_version`, and unchanged `topic_key`; provide the revised `title`, `summary`, `topics`, and `anchors`. |
| `create` | Propose a distinct subject with those same subject fields, `target_ref: null`, and `expected_version: 0`. |
| `defer` | Return only the action, source input IDs, and a short reason; retain no new topic. |

An empty updates list is valid. A model-level `defer` is a completed no-change judgment, not a
failed batch that pauses the conversation. No output quota requires a memory for each message.

Topic identity is its host-issued UUID, not a title or a slug invented again on every message.
Up to eight exact source-supported identifiers or URLs may serve as matching anchors. The host
qualifies them to the authorized source scope; an anchor is a retrieval clue, not unique ownership.
Generic service names cannot merge distinct incidents by themselves. Before accepting `create`,
the host searches authorized existing subjects. An unoffered plausible match causes a bounded new
judgment with those alternatives, not a silent merge. Concurrent writes serialize per writable
scope, and updates must still match the offered exact version. Late source events may correct
understanding; event-time order alone is not a reason to drop them.

Normalized source membership records retain direct supporting sources separately from inherited
disclosures. Topic revisions refer to the membership version instead of copying an ever-growing
source array. Source edits, expiry, deletion, and current membership are checked before disclosure
and application. A title or excerpt is itself a disclosure. Future queued inputs are excluded even
when another memory document indirectly refers to them. Reading a source does not renew its lifetime.
Capacity errors are explicit; the host never silently drops source dependencies to accept a result.

Episode records and recalled answers follow those same source rules. Their exact stored projection
resolves to its producing turn and session; a new session inherits the producer's retained source
and knowledge dependencies before receiving the text. Source withdrawal therefore blocks both a
replacement briefing and acceptance after a tool read. Operator history remains a separate retained
view. Historical outcomes bind to the named turn, original input, and listed records, not the latest
mutable episode projection.

Successful disclosure attests the session's source and knowledge row counts, including tracked zero.
Missing or partially pruned custody is not treated as source-free prose, and later reads cannot heal
that gap. This covers Responder-accounted disclosures, not untracked native or live-platform reads.
The producer's accumulated session dependencies are conservative: later disclosures can invalidate
an earlier record. They do not extend its source lifetime or copy all roots onto every record.
Producer reads take a nonblocking shared session lock. Busy producers are temporarily unavailable,
not revoked: frozen work yields and retries without spending a model failure attempt or stopping
the episode. Optional history can be omitted while that producer is busy.

### Background execution and recovery

The example YAML enables `learning` with a trusted Coop policy/digest, one worker, batches of up
to 16 inputs, a 10-second quiet delay, and a 60-second maximum coalescing delay. Omitting the
section disables this runtime. Configuration must use a dedicated empty scratch repository with
`repository_read_only=true`, `project_env=false`, `project_mcp=false`, no companions, and no
Responder state/action tools; a returned Responder binding digest is rejected before source
submission. Coop still owns an execution fork and exposes provider built-in tools. Read-only
restricts the repository mount, not writable output/scratch or the provider home; network egress
is not disabled by these policy flags. Instructions prohibit native external actions, but this is
an integration-free read-only sandbox, not enforced no-tools execution. Production learning uses
the existing outbound fleet adapter, not an extra local Coop runtime.

Batch states are `queued`, `running`, `applied`, `no_change`, `deferred`, and `superseded`. A
PostgreSQL lease fences execution and acceptance. Provider calls occur outside database
transactions. Lost create, submit, or validation responses reconcile the frozen operation key;
uncertainty never buys a fresh model execution. Before another judgment starts, the previous remote
turn must have exact stop proof. After twelve rapid unresolved reconciliations, the scope stays
fenced and only reconciliation retries hourly; unrelated scopes can continue.

Three host starts are allowed initially for one batch, shared by provider failures, semantic
rejection, and match corrections. Provider-internal attempts have their own pinned-policy limit;
three host starts are not necessarily three model invocations. Restart, generation changes, source
invalidation after a start, and receipt pruning do not erase spent starts. An audited operator
retry grants exactly one additional start against the displayed `budget_version`: its ceiling is
the lifetime starts already spent plus one. Duplicate or stale requests cannot increase that grant.
Missing source authority, another active batch, or unresolved older remote work blocks retry.
Owned sessions use the existing close/plan/discard retention custody, including after failure.

Explicit operator retry and rebuild reselection use the current trusted learning policy for the
next attempt, recording old and new policy identities in the audit. Prior attempts and spent
starts are immutable. Automatic worker recovery still follows the batch's pinned policy; only
the operator action selects a replacement. Missing or invalid current configuration blocks a new
grant, while replaying an already recorded action returns its original receipt without another start.

After a host rejects an anchor, create match, or result shape, a fresh frozen prompt includes
`previous_attempt_error`: a bounded code and static repair instruction. It does not repeat the
rejected candidate or former source text. Feedback participates in the same prompt-byte limit;
old submitted bytes, source authorization, and the lifetime start counter remain unchanged.
Subject anchors must come from message content or an offered target, not sender/routing metadata.

### Recall and original context

`search_memory` is the single model memory-search tool. All fields are required; unused timestamps
and the first cursor are `null`:

```json
{
  "query": "Livebook",
  "scope": "repository",
  "kinds": ["fact", "guidance", "continuity"],
  "limit": 10,
  "cursor": null,
  "after": null,
  "before": null,
  "time_basis": "source"
}
```

`query` may be empty for date browsing. `after` is inclusive and `before` exclusive, both UTC.
`source` means the original message time for an excerpt, the latest supporting source time for
derived conversation context, and confirmation time for a confirmed item. `changed` means content
change/confirmation/edit time, never a retrieval counter. Explicit history keeps source excerpts
searchable after consolidation, while automatic briefing avoids those covered duplicates.

Excerpt, topic and handover hits may carry an additional shared `related_memory` section with
source-linked retained context. Primary `memories`, kind interleaving and cursor positions are
unchanged. The one-hop attachment scan uses the remainder of the same 64-candidate and 64-KiB
budget, excludes primary IDs before recall, and registers all disclosed documents together with
source-exposure custody. Attachment dates use content change time; an explicit `before` cutoff
excludes understanding created after that cutoff even when the primary uses original source time.
Exact confirmed-fact getters and fact-only search pages do not acquire unrelated conversation history.

Pages interleave requested kinds instead of letting facts consume the whole result budget.
Within each lane, stable content time and identity form a descending keyset. The host-signed cursor
binds the effective query, filters, scope, active execution binding, effective operator, and cutoff; it expires after an
hour and carries no caller-selected authority. Access and source eligibility are checked again on
every page. This is a live traversal, not a frozen database snapshot: changed or withdrawn rows may
disappear, and new content requires a fresh search. Continue until `exhausted` is true; a final
empty page is possible. Pages permit 1–20 results, 64 candidate visits, and 64 KiB of result
documents, with a five-second statement budget and explicit failure codes. Search takes the active
session lock without waiting, rechecks current turn ownership and lease, then takes the channel
authorization fence before updating any recall counters. Further lock waits are limited to one
second. SQL contention and budget failures return `memory_search_budget_exceeded`; they do not
return a successful empty page or commit partial accounting. Source reauthorization can separately
reject an invalidated context. Search follows the existing
session-before-channel order used by Work result acceptance and source exposure.

Retained Slack results can include a `source_read` or `source_reads` descriptor for the existing
`read_slack_source` tool. That reader independently checks present access. It is not permission to
search unrelated channels, and a derived summary is never presented as the original quotation.
An expired source cannot be reconstructed from a summary. Memory supports historical attribution;
current health, successful deployment, and operational authorization still need their owning evidence.

Slack search always requests surrounding context. Provider-selected neighbors are sorted, assigned
exact source references, deduplicated against the hit, and limited to two originals on each side
(4,096 UTF-8 bytes per optional excerpt). This is partial context, not an exhaustive transcript.
Known thread source descriptors retain both the root and an exact `anchor_ref`; unknown roots
remain message/surrounding reads. Memory search omits expansion descriptors for readers not exposed
to that turn and validates canonical source records before filtering navigation metadata.
Missing provider context triggers at most two original-reader expansions per search, with at most
twelve message-page requests across those expansions. Later hits retain a usable source-read
descriptor and explicit expansion-budget coverage. A source no longer present is omitted; the search
does not report that filtered page as complete. Provider-supplied context does not consume this fallback
allowance. Exact original reads, not provider non-supply, establish an empty complete neighborhood.

Source reads independently recheck the anchor on every page. Their bounded window contains up to
`limit` neighbors split around it; anchor and root are separate from those neighbors. Channel
history is newest-first and thread replies oldest-first, so the opposite side scans at most three
100-message provider pages. The other side takes one page. Coverage reports whether each side is
actually adjacent, partial, or carried on a previous page. Long scans can require continuation before
nearby originals are available on that side; an empty pending scan is not a complete neighborhood.
Trimmed originals remain reachable by seeking past the emitted edge. Cursors bind source, anchor,
view, range, limit, episode and turn, expire after one hour, and allow at most ten window responses.
Provider limits without a usable cursor do not imply a complete history.
The last allowed window reports `continuation_exhausted` rather than issuing an unusable cursor.
Its `source_reads` offer fresh bounded reads centered on known originals at the unfinished edges;
these are explicit wider expansions, not continuation of the exhausted cursor.
Thread reads fetch their exact root separately when the reply response omits it. Their first page
also includes a separate four-original `channel_context` around that root, excluding thread replies
and duplicate root text. Later thread pages refer back to that layer rather than repeating it.
Its `source_read` descriptor either continues the signed channel window or requests a wider original
window. Root plus both windows use at most ten message-page requests, in addition to channel metadata;
each layer reports its own coverage. The requested transcript's `complete` flag does not claim that
every optional context layer is complete.
Handovers and compacted rollups carry at most three original-source descriptors from their existing
source receipts. An absent saved excerpt does not erase a valid original receipt. Rollup scope remains
its actual repository or conversation scope; navigation to a supporting thread does not turn the
rollup itself into a thread summary.

Through the Work MCP endpoint, Slack and Conversation Lab message lookups return a shared `related_memory` section:
up to eight source-linked confirmed facts, guidance, topics, observations, handovers or rollups,
selected across at most twenty
unique lookup anchors. Eight is also the per-source maximum: this is one shared allowance, not eight
attachments multiplied by every hit. Shared memory documents appear once. The original caller remains the authority; selecting another public channel
does not impersonate that channel's episode. Derived attachments use the existing source eligibility
and session exposure checks. The SQL scan keeps the 64-candidate, 64-KiB and five-second budgets;
provider I/O happens before that transaction. A `before` bound also limits the attachment's content
change time. The combined response is bounded to 128 KiB. Optional memory yields to originals;
when originals alone exceed the cap, broader channel context yields before local neighbors.
Primary hits, exact anchors and roots remain. Overlapping originals use `context_reference: true`
with the `source_ref` of a body elsewhere in the same response. Deduplication is recalculated after
trimming, so a reference never depends on a removed body. Byte-trimmed windows report partial
coverage and `omitted_context` reader descriptors; search expansions restart before omitted context.
`source_result_too_large` means the required originals and coverage still cannot fit. These attachments
do not establish fresh operational state. Shared context is not recursively expanded.

Conversation Lab search uses signed, caller/query-bound keyset continuation over current retained
originals and includes nonmatching neighbors inside the requested date bounds. It rechecks the live
session, ownership and lease before local reads or effects. Its coverage names
the retained-conversation basis and 200-message retention window; it is not proof of full Slack history.
Queued inputs for the active Lab episode cannot enter source reads or neighbors. Current revision
selection happens before that exclusion, so withholding a queued edit does not resurrect its old text.

Slack file and canvas reads retain available creation/edit dates and up to four known shares in the
authorized channel. Each known share can expand through the existing original reader. Shares are
not proof of a unique originating thread, and other channels' shares are not disclosed. File search
keeps the same provenance plus a document-reader descriptor. A provider preview is explicitly partial;
external bookmarks remain link metadata. Lab files retain their authenticated checksum, input date,
conversation and a working descriptor for the original supplying message.

GitHub discussion/review reads add the bound subject body. Review replies reuse parents on the page
or read at most four missing parents, verifying each against the current PR before disclosure.
Deleted and budget-omitted parents have explicit coverage. Repository search adds up to five discussion
items only for a hit matching the current subject; other subjects keep their body and an honest
current-subject-reader limitation. Files and subject-only reads stay focused. Through Work MCP, these
GitHub lookups also recheck the active caller after provider I/O and obey the 128-KiB response cap.
Lab source reads start with a centered window, then use signed source/range/turn-bound cursors to
expand beyond its consumed interval without repeating originals. The exact anchor remains available
on later pages. Retained native source-item receipts resolve to the admitted local original; they are
not treated as an interchangeable reader ID. Memory navigation stays inside the same Lab conversation.
Observation custody compares exact original text and source identity separately from optional
navigation metadata, and still rejects altered prose or a different supplied thread.
The Work MCP response rechecks the active binding after provider I/O, even for an empty lookup.
Raw Slack matches and neighbors are filtered against inputs queued for a later turn; a requested
queued anchor is unavailable. This check and memory exposure share the same bounded transaction.

The implementation decisions and scope are recorded in the
[memory implementation specification](memory-implementation-spec.md). The schema snapshots and
model-evaluation obligations are documented in [memory evaluation](memory-evaluation.md).

## Universal final result

The model returns one small JSON document:

```json
{
  "delivery": "reply",
  "message": "Human-facing answer",
  "decision_reason": null,
  "outcome": {
    "state": "complete",
    "record_refs": [],
    "artifact_refs": []
  }
}
```

`delivery` is `reply` or `none`. Silence requires a short audited `decision_reason`; a direct human
request cannot silently disappear. `state` is `complete`, `waiting_for_input`, or
`waiting_for_event`. A waiting result must reference exactly one already-durable wait record. The
host validates identifiers, authority, pending state, destination, receipts, and exact bytes. It does
not deterministically judge prose quality, root cause, or domain completeness.

## What the fast tests prove

The deterministic suite uses PostgreSQL and a scripted Coop fake; it calls neither a model nor a
network service. It covers:

- simultaneous local-pool claims and stale-lease fencing;
- persisted policy, session, prompt, candidate, verdict, and result identity;
- same-session delta continuation instead of resending the full briefing;
- bounded exact input pairs with every remaining instruction retained in chronological custody;
- one-turn semantic repair;
- lost submit, validation, and cancellation responses;
- Stop racing both pre-send and already-admitted session/turn mutations;
- exact validation-cleanup recovery and unsafe validation failure blocking;
- remote cancellation before local cancellation or owner transfer;
- new input not erasing an accepted reply;
- question and event-wait continuation after delivery;
- bounded retry and permanent blocked custody;
- separate work and delivery claim phases;
- a supervised optional worker pool reaching a validated delivery intent; and
- generic Slack/GitHub delivery settling only after an exact typed receipt.

The Work-runtime suite claims only the cases its tests already prove. Typed state-tool carry and privileged GitHub completion guards are
owned by their dedicated modules. Generic transport rendering and external response-loss
reconciliation are described in
[platform adapters and delivery](elixir-platform-adapters.md).

## Model behavior evaluation

The checked-in Work corpus uses the production prompt, universal final-result schema, and semantic
validator. Its offline suite proves that semantic rejection remains in the same Coop turn, that
byte-identical correction attempts receive distinct attempt-bound validation keys, and that a
host-valid but behaviorally wrong result fails instead of being silently accepted.

```console
scripts/elixir-test.sh test/responder/evals
MIX_ENV=test mix responder.eval work-pack
MIX_ENV=test mix responder.eval work --config /absolute/responder-elixir.yaml
MIX_ENV=test mix responder.eval world-pack
make eval-world-smoke CONFIG=/absolute/responder-elixir-eval.yaml
make eval-world CONFIG=/absolute/responder-elixir-eval.yaml
```

`work-pack` compiles the sanitized narrow final-contract corpus without a model. Its live command runs each case through
the dedicated `model_evals.socket` in an isolated Coop session under `model_evals.no_tools_policy`,
which must be read-only and expose no
tools. It currently covers a useful direct answer, the Slack/GitHub/platform-adapter product
boundary, and shadow-mode no-delivery. Accepted cases are closed, checked with Coop's exact discard
plan, and discarded only when the workspace is clean. Unsafe cleanup fails the eval and retains the
session for inspection.

The separate world lane proves behavior with tools. `eval-world-smoke` runs eight high-value cases
once at a strict 100% floor. The release `eval-world` gate runs the full corpus three times for a
dedicated candidate policy and a separately pinned baseline policy in the exact same deterministic
world, enforcing aggregate, per-case, hard-invariant, `UNRUN`, and paired-regression limits. One
versioned scenario directory is shared
by deterministic host replay and real-model execution. Its production Responder state tools are real
and lease-authorized against an empty disposable PostgreSQL database; its metrics, scheduler, GitHub,
and similar external tools are a strict recorded cassette. Calls match important normalized
arguments rather than a global order, controlled failures are replayed per rule, and unmatched calls
return a bounded error instead of fabricated data. Visible output goes only to the inert `eval`
transport. Hard checks run first, then a tool-free judge session scores every human-language rubric
criterion exactly once. Missing judge evidence remains `UNRUN`, never green.
The eval socket cannot equal the production Coop socket. Before any model turn, Responder verifies the
exact policy digest and Coop's public `repository_read_only` bit; the dedicated daemon is deployed
without production environment, credentials, network mutation tools, or project MCP configuration.

## Configuration

`Responder.Work.Runtime` is optional. Its trusted configuration contains only:

- `socket`: local Coop Unix socket;
- `worker_ref`: stable identity prefix for this local worker pool;
- `concurrency`: optional local slot count, from 1 through 32 (default 4); and
- `source_and_action_tools`: optional exact names from the MCP catalog exposed by the pinned Coop
  policy; these names make the frozen model context truthful but confer no authority; and
- optional bounded polling and receive timeouts.

The Work runtime does not contain a model router. The adapter freezes a three-class Work profile at
ingress, admission selects one abstract class, and Coop resolves the selected policy to its immutable
target. The recommended targets are Terra/medium for conversational work, Sol/medium for standard
work, and Sol/xhigh for deep work. Keep those three policies authority-equivalent. Writable task
execution remains a separate confirmed contributor policy rather than a `deep` side effect.

Obtain both `policy_digests` and `policy_authority_digests` from
`coop sessions policies --policies /etc/coop/session-policies.yaml --json`. Copy the matching full
digest and shared authority digest into every Work profile and worker advertisement; never derive or
hand-write either digest in Responder.

For example:

```elixir
config :responder, :work,
  socket: "/var/lib/responder/coop/control.sock",
  worker_ref: "responder-work:host-a",
  concurrency: 4,
  platform_tools: ["list_runners", "find_actions"],
  poll_interval_ms: 250,
  receive_timeout_ms: 30_000
```

The YAML field is named `work.source_and_action_tools`; the internal runtime option is
`platform_tools`. The configured names must exactly match tools actually supplied to that Coop
policy by its owner-private MCP configuration. Responder never reads MCP credentials, and an
incoming Slack, GitHub, webhook, or Conversation Lab message cannot add a tool or change this list.
All of those sources share the same trusted Work runtime. Conversation Lab also installs a loopback
implementation of the exact Slack chat capability schemas: `list_slack_channels`, `search_slack`,
`read_slack_source`, `set_slack_reaction`, and `post_slack_message`. In a Lab turn those tools expose
one virtual workspace scoped to the current Lab conversation. Reads return only its durable messages;
reactions and confirmed additional posts use the ordinary platform-action outbox but settle back into
the local timeline. Human feedback reactions on delivered replies are passive ordered episode events:
they do not wake work, but both the bounded add/remove history and current counts are frozen into the
next logical turn. Lab message edits and deletes use the same stable-item revision contract as provider
adapters. Every result identifies the adapter as emulated with external effects disabled.
This lets the model make the same chat/tool/card choices without generating Slack test traffic or
receiving a Slack credential. Configured repository and Emisar tools remain real and retain the exact
Work policy authority. Incident offers start a real linked Work episode in the Lab under that pinned
authority; the virtual incident stays in the Lab timeline instead of fabricating a Slack channel.
Slack workspace audience rules, real workspace data, and Slack API provisioning still require the
authenticated Slack adapter and its disposable live qualification.

All slots must reach the same Coop daemon. The persisted Coop session ID is not yet paired with a
routable execution endpoint, so this stage does not claim cross-machine lease takeover. Durable
execution placement and takeover are a later boundary.

The worker never accepts a policy, repository, provider, credential, Slack destination, or tool set
from an incoming event. Those are admitted and pinned by their owning boundaries.

## Retention and cleanup

`Responder.Retention.Runtime` owns both remote workspace cleanup and local data horizons. For every
terminal episode it closes only the exact Coop session recorded in PostgreSQL, waits the configured
grace period, fetches an exact discard plan, and then:

- discards a clean workspace with no unreviewed changes;
- discards clean committed work only after its publication is durable;
- retains dirty or unpublished work for an operator; and
- blocks on crossed session identity, authority, or ambiguous cleanup instead of guessing.

Blocked cleanup exposes its exact phase and bounded diagnostic in the local control plane. A
confirmed operator may rearm that same phase without changing the frozen session identity. A clean
workspace retained only for unpublished, unmerged commits may be explicitly discarded, but that
action always obtains a fresh Coop plan with unmerged acceptance; dirty work remains retained. Both
actions are idempotent and leave an audit row.

Large ingress, prompt, candidate, validation, delivery, and artifact bodies are redacted on the
operational horizon only after all of the episode's Coop sessions are proven discarded. The episode
event stream remains coherent until `episode_history_seconds`; it is never thinned one event at a
time. Open waits, blocked turns, pending approvals, live schedules, unpublished changes, active
incident rooms, and unresolved state records pin that history regardless of age. Compact session and
delivery receipts remain until `audit_data_seconds`. Pruning runs in bounded batches and short
transactions so retention cannot monopolize a busy database. Every table has an executable retention
class, and every age/lease comparison uses PostgreSQL time.
