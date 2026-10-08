# Elixir work runtime

The Work runtime turns one admitted episode into durable, locally pooled model work. It is deliberately
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
tools own durable records. The generic Delivery module owns external message custody and the routing responses (a quick reply's messages and the reactions on the person's message, each sent once and in order) that routing sends without Work.

## End-to-end flow

1. Admission commits the input and pins Ryker's trusted execution settings in the same transaction.
2. One slot in the local worker pool claims only a `turn` owner using PostgreSQL time and
   `FOR UPDATE SKIP LOCKED`.
3. The runtime freezes the exact self-contained first briefing, including each input's own origin,
   the episode's participating conversations and one home, the state of its trusted occurrence
   signals, and the same surrounding conversation the routing decision was made against, read back
   from that decision's frozen snapshot rather than fetched again. A continuation in the same healthy
   Coop session sends only new input plus a parent-submission reference.
4. Coop creates the session and turn under stable operation keys derived from immutable local rows.
5. Ryker stores each candidate's exact bytes, SHA-256, and attempt before validation.
6. The universal validator returns every hard, actionable violation at once. Rejection continues in
   the same Coop turn and session.
7. Ryker freezes the exact accept or reject mutation before calling Coop. Lost responses are
   reconciled by operation key and current turn state.
8. A validated accept atomically stores the result and advances the episode. A visible result becomes
   `delivery_pending`; deliberate silence settles immediately with an audited reason.
9. Model workers cannot claim delivery work. A separate bounded Delivery pool claims the frozen
   intent, renews its independent lease across bounded provider I/O, selects only a trusted transport
   adapter, and records a typed external receipt atomically.

## Reliability rules

- Process clocks do not decide leases or retry time; PostgreSQL does.
- No background worker polls on a fixed timer. Each wakes when the context that owns its rows
  announces a change after commit (`Ryker.PollingWorker`'s `wake_on/1`; routing on the inbox, Work
  and Work replies on a request's topics, routing responses and model actions on their own, and so
  on), and otherwise sleeps until the earliest row it could claim falls due by the clock: a retry's
  backoff, a running turn's polling window, an unrenewed lease, a timer, a schedule's occurrence or
  a follow-up's next check, each read from its own queue's index. A ten-second safety net catches
  anything nobody announced, and a stream of announcements never makes a worker poll more than four
  times a second. Measured on 2026-09-27 with every worker running against an empty database, an
  idle install went from about 107 commits a second to about 8.
- A read sent to a Coop worker (a session, a turn, its changes, an output artifact) answers only
  the caller that asked, and that caller waits about as long as Ryker waits on Coop, 30 seconds.
  Two minutes after a read was asked Ryker stops sending it, so a worker that has it cancels it
  when its lease runs out instead of running it ahead of newer work after a long command, and a
  read never sent fails when its placement ends. A command someone waits on by its key is sent
  until it is answered.
- A worker cannot choose episode policy. Admission chooses only the abstract conversational,
  standard, or deep class and maps it through a host-owned profile. Existing episodes retain their
  pinned policy across deploys and later classifications.
- A task that stopped before any worker took its session runs again on settings as they are now
  (2026-10-03). "Run the task again" reuses that session and keeps its policy name. It takes the
  policy's digests, the environment's repositories and its Emisar account from current settings,
  and pins its job again. A session a worker has taken keeps its authority.
- Ryker derives each class's model-independent authority digest from its trusted job settings.
  The three classes must share that authority. Workers advertise capabilities and capacity, not
  policy names or digests; the created session must return the exact frozen job identity and digest.
- Every new repository-backed session carries one immutable repository source, frozen in the same
  transaction that pins policy, digests, the environment and its repository context. Admission may select
  `{"kind":"default"}`, `{"kind":"branch","name":...}`, `{"kind":"pull_request","number":...}` or
  `{"kind":"commit","sha":...}` inside the already selected repository; the host supplies `default`
  when nobody chose. Workspace-free work carries no selector. Ryker resolves the selector into
  exact commits and freezes that source inside the immutable job before placement. Both the
  evaluation client and fleet send that job through `POST /v1/sessions`; a changed retry conflicts
  instead of rebinding, and the fleet refuses authority other than what custody persisted.
  Rotation, failover and checkpoint restore copy the predecessor's selector verbatim; a checkpoint
  taken from another source never seeds a replacement. An active session is never rebound; another
  source is new linked work through a confirmed `request_task`.
- Exact source selection belongs to the frozen job. Repository work requires
  `repository-freshness:2`; workers do not advertise policies, repositories or a separate
  source-selector capability. Missing freshness support refuses creation before code is used.
- The frozen job is a version-2 JobSpec (Coop `job-setup:2`, 2026-10-04): beside its sources it
  names its whole setup, and the worker applies nothing from the repository's own settings.
  Work gets an empty environment and the caps every job carries (4 CPUs, 8 GiB, 4096 processes;
  Docker refuses a CPU cap above the host's cores). A working copy's `check` is the repository's
  `gate:` from `.agent/project.yaml` at the job's base commit, split into argv the way Coop splits
  it (`Ryker.CoopFleet.JobCheck`); a read-only job and a repository without a gate get no check,
  and such a review is not publishable. A gate GitHub cannot read now is a wait
  (`coop_worker_source_unavailable`), never a job frozen without it. Sessions are placed only on
  workers advertising `job-setup:2`.
- Version-1 jobs are refused. The move to version 2 carried the sessions that still held one
  until 2026-10-08, when the last were closed; sessions retained from then are cleaned up as any
  other, since a cleanup receipt is checked against the stored job whatever its version.
- Submodules are pinned with their source, and Coop stages every gitlink it declares. Each one must
  come from one of two places:
  - a repository Ryker was given, read through its GitHub binding;
  - a public GitHub repository, pinned as `public:<owner>:<name>` and granted to the worker with
    `"public": true` and no token, so the worker fetches it anonymously. Such a grant is given only
    for a submodule the job vendors.

  A submodule from any other repository stops the job at once. The error is
  `coop_worker_source_refused`, or `coop_worker_companion_refused` for a read-only repository of
  the environment. Either error names the repository and the submodule.
- Ryker resolves the selector through the authorized GitHub repository. Coop fetches and verifies
  that frozen source and returns the session's
  version-1 `source` binding (`requested`, `remote_identity`, `default_ref`, `default_commit`,
  `selected_ref`, `selected_commit`, merge-base `base_commit`, `admitted_tree`, `resolved_at`, plus
  `pull_request_number` and optional `pull_request_expected_head` for a pull request). Ryker
  refuses the workspace (`coop_protocol_error: repository_source`) unless the binding answers the
  exact persisted request, its derived ref matches, and the session's creation base is the
  binding's `base_commit` (the workspace itself starts at `selected_commit`). Every non-default
  selection also needs its own `source` freshness receipt
  naming the derived ref, or the exact object id for a commit, so a locally cached object is never
  accepted as remote proof (`coop_protocol_error: repository_freshness`). Workspace-free jobs
  carry no repository source. Historical sessions remain inspectable but cannot acquire new
  execution authority by reinterpreting an old local policy.
- The validated binding is exposed to the model as `work.workspace.source`: a fact about where the
  checkout starts, never publication authority. Engineering completion still requires a committed
  tree beyond `admitted_source_tree`; review-only work may finish unchanged. Publication keeps its
  own Ryker-owned branch rule, so a selected human branch or pull request cannot become a push
  target merely because it was checked out.
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
- An active remote turn must be cancelled through Work custody. Ryker first freezes the intent,
  reconciles Coop's idempotent cancellation, and only then cancels or transfers the episode owner.
  The stop goes to the worker that holds the run whatever policy version it runs now, since
  cancelling and closing do no policy work. The one other proof it accepts is that worker's removal
  from Ryker, which revokes everything the run could still reach Ryker with. A stop unconfirmed
  after eight attempts keeps retrying and is listed on Failures with what would let it finish.
- If Stop races a prepared create or submit before a remote resource is known, Ryker calls Coop's
  exact operation fence. The fence either prevents that mutation from starting or returns the
  operation/resource that already won the race. Cleanup never creates fresh work after authority was
  revoked, and a lookup miss or timeout is never treated as proof of absence.
- The exact accepted result survives newer queued input. New input advances only after the accepted
  visible reply is delivered, or after deliberate no-delivery settlement.
- An accepted reply is bound to the origin of the newest input that instructed it, and that target is
  frozen on the turn at acceptance. A question asked in a new thread is answered in that thread even
  when the episode's progress home is another channel; default progress keeps the single home, so
  contributing conversations are never subscribed to repeated status or final replies. A later input
  from somewhere else cannot move or erase an answer that was already accepted, and a delivery
  receipt from any other destination still fails to settle it. Only a destination deleted for good
  moves it: a reply owed to a deleted incident room is rearmed, with the same content and delivery
  reference, for the alert thread the room was opened from, and an attempt already in flight
  finishes first.
- Delivery retries are bounded independently from model execution. Permanent platform errors and
  exhausted transient retries preserve the exact accepted result in operator-rearmable blocked
  custody instead of polling a provider forever. Failures in the console lists that immutable
  intent and says what stopped it, and its action (such as Post the reply again) rearms it by
  durable reference; a rearm starts a separately audited retry generation with a fresh bounded
  attempt budget. From a source checkout that reaches the database, `mix ryker.delivery
  list|show|rearm` does the same; the Compose image has no Mix.

## Memory and background learning

PostgreSQL owns memory; a warm Coop session is an execution optimization, not the durable owner.
The memory pipeline has separate read, learn, and act decisions:

1. Admission returns only `action`, `episode_ref`, `messages`, `reactions`, `relation`, `reason`,
   `repository`, `repository_source` and `work_class`; `messages` are the words of a quick reply and
   `reactions` the emoji routing adds. Beside them it may say how the sender feels about Ryker's
   last answer (`sentiment`), which is kept only as feedback on that answer and is never part of
   the decision. Its schema has no `observation` or `knowledge` output. Committing a retained input
   records a bounded original-message excerpt and its exact source receipt, including for silence.
2. The optional `Ryker.Learning.Runtime` coalesces decided input revisions in the same writable
   scope and execution mode. A revision belongs to one durable batch. Quiet/max-delay clocks start
   when admission made it eligible, not when the historical source message happened. A revision
   that started Work becomes eligible only once that Work has come to rest (answered, waiting for
   a person or an event, blocked, cancelled or closed), and its clocks start then; however long the
   Work runs, neither clock forces it earlier.
3. `Ryker.Learning` freezes the selected original inputs, eligible existing subjects, prompt,
   schema, policy digest, and remote operation identities. It is the sole model writer of topic
   knowledge. The learner can return no change without replying or creating an episode.
4. Work receives selected authorized knowledge plus recent uncovered source excerpts. Its separate
   `update_conversation_summary` tool proposes a conversation handover; that handover becomes
   recallable only when the associated Work candidate is accepted.
5. Confirmed facts, preferences, guidance, waits, goals, and operational authority retain their
   existing owners. Learned prose cannot confirm a preference, start an incident, or grant a tool
   permission. Shadow learning never authorizes live delivery or crosses into live memory scope.

### Explicit reusable answers

Work checks applicable memory and authorized discovery before asking for a missing operational
identifier. `request_input.remember` names one fact's subject and applicability; the question
explains that an operator's answer will be remembered. A typed reply or native choice retains
its exact question, authenticated actor and source revision. `remember_answer` interprets that
answer as a minimal value, verifies the current live Work binding and configured operator,
and saves through the existing operational-memory domain without another confirmation click.
An unrelated or ambiguous reply is not a confirmed mapping. Failed saves must not be reported
as remembered, and the durable accepted answer remains available to retry.

These facts use explicit installation-global ownership: the customer installation's database,
not a channel or an alias for workspace scope. Applicability distinguishes workloads and
environments. Because every conversation recalls them, a Slack answer is kept only when it was
given in a public channel Ryker is in, the rule a memory offered for a whole workspace or
repository follows; one from a private channel or a direct message is refused with
`answer_memory_private_source`. Recall crosses conversations but does not expose the source body
or navigation. Active global facts have no automatic expiry and survive ordinary transcript
cleanup. Explicit answer edits/deletions and source-channel deletion revoke the saved fact;
reviewed corrections and Forget use the existing memory controls. A delayed answer cannot override
a later answer, reviewed correction or explicit Forget. Memory never grants execution access or
proves live health.

Questions support up to ten full choices. Up to five render as distinct short buttons; longer
answers remain visible above their numbered controls. Six to ten use a native radio group and
an explicit Submit answer button, with no initial selection. Radio changes do not admit work;
only the authenticated submit payload's state for this exact immutable question is accepted.
Missing selections and selections for another question are rejected. A typed thread reply is
an alternative. Both paths retire the original controls through the existing durable Slack
repaint queue while retaining the question and the separate human answer.

A question may keep event-only source watches and pending Emisar approvals open in the same
result. The input request remains the sole continuation owner; source updates queue until its
answer. Reconciliation keeps the original matcher through the question and resumed Work, including
restoration of a missing subscription, and the oldest watch holds the episode's one subscription.
The continuation can return to that same watch. A timer fires only while it owns its task's wait,
so one that owns it takes the subscription from a watch beside it; the watch stays open and takes
the subscription back when a question or an approval owns the wait again. An open wait stays open
while its task runs, and only a finished task's waits are dismissed.

### One subject, several updates

The learning result is `{updates: [...], reason: "...", people: [...]}`; `people` is there only
when a person's own message is among the inputs. Each `people` item names one such message
(`source_input_id`), a short `key` and what the author said about themselves (`fact`, or null to
take back what that key held), which `Ryker.People` keeps; apps, bots and alerts teach nothing
about a person. Every `updates` item selects exact offered `source_input_ids` and one action:

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
that gap. This covers Ryker-accounted disclosures, not untracked native or live-platform reads.
The producer's accumulated session dependencies are conservative: later disclosures can invalidate
an earlier record. They do not extend its source lifetime or copy all roots onto every record.
Producer reads take a nonblocking shared session lock. Busy producers are temporarily unavailable,
not revoked: frozen work yields and retries without spending a model failure attempt or stopping
the episode. Optional history can be omitted while that producer is busy.

### Background execution and recovery

Learning uses a controller-authored empty-source job, its configured model ladder, one worker,
batches of up to 16 inputs, a five-minute quiet delay, and a 30-minute maximum coalescing delay
(`Ryker.Defaults`): ten quiet seconds made nearly every message a pass of its own.
The job has `repository_read_only=true`, no work environment and no check, no companions,
and no controller state/action tools; Coop reports the session's `project_env=false` and
`project_mcp=false`, which Ryker checks before it submits anything. No host scratch repository is configured.
A returned controller binding digest is rejected before source
submission. Coop still owns an execution fork and exposes provider built-in tools. Read-only
restricts the repository mount, not writable output/scratch or the provider home; network egress
is not disabled by these job fields. Instructions prohibit native external actions, but this is
an integration-free read-only sandbox, not enforced no-tools execution. Production learning uses
the existing outbound fleet adapter, not an extra local Coop runtime.

Batch states are `queued`, `running`, `applied`, `no_change`, `deferred`, `superseded`, and
`dropped`: a person dropped a stopped batch, so Ryker no longer learns from its messages, and its
attempts and why it stopped stay recorded. A
PostgreSQL lease fences execution and acceptance. Provider calls occur outside database
transactions. Lost create, submit, or validation responses reconcile the frozen operation key;
uncertainty never buys a fresh model execution. Before another judgment starts, the previous remote
turn must have exact stop proof. After twelve rapid unresolved reconciliations, the scope stays
fenced and only reconciliation retries hourly; unrelated scopes can continue. An attempt that never
froze a submission has no turn: when its worker session can never be addressed again, it stops on
that local proof and the batch continues with a fresh job from the current settings. A
session without the isolation above is bound, refused before any source is sent, and holds new
attempts under that settings digest until the configuration changes.

Three host starts are allowed initially for one batch, shared by provider failures, semantic
rejection, and match corrections. Provider-internal attempts have their own frozen-job limit;
three host starts are not necessarily three model invocations. Restart, generation changes, source
invalidation after a start, and receipt pruning do not erase spent starts. An audited operator
retry grants exactly one additional start against the displayed `budget_version`: its ceiling is
the lifetime starts already spent plus one. Duplicate or stale requests cannot increase that grant.
Missing source authority, another active batch, or unresolved older remote work blocks retry.
Owned sessions use the existing close/plan/discard retention custody, including after failure.

Explicit operator retry and rebuild reselection use the current trusted learning settings for the
next attempt, recording old and new configuration identities in the audit. Prior attempts and spent
starts are immutable. Automatic worker recovery reconciles an outstanding attempt under its own
pinned job; a new attempt a batch prepares on its own adopts the current trusted settings and
freezes a new job before placement. Missing or invalid current
configuration blocks a new grant, while replaying an already recorded action returns its original
receipt without another start.

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

Through the Work MCP endpoint, Slack and direct-conversation message lookups return a shared `related_memory` section:
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

Direct-conversation search uses signed, caller/query-bound keyset continuation over current retained
originals and includes nonmatching neighbors inside the requested date bounds. It rechecks the live
session, ownership and lease before local reads or effects. Its coverage names
the retained-conversation basis and 200-message retention window; it is not proof of full Slack history.
Queued inputs for the active Chat episode cannot enter source reads or neighbors. Current revision
selection happens before that exclusion, so withholding a queued edit does not resurrect its old text.

Slack file and canvas reads retain available creation/edit dates and up to four known shares in the
authorized channel. Each known share can expand through the existing original reader. Shares are
not proof of a unique originating thread, and other channels' shares are not disclosed. File search
keeps the same provenance plus a document-reader descriptor. A provider preview is explicitly partial;
external bookmarks remain link metadata. Chat files retain their authenticated checksum, input date,
conversation and a working descriptor for the original supplying message.

GitHub discussion/review reads add the bound subject body. Review replies reuse parents on the page
or read at most four missing parents, verifying each against the current PR before disclosure.
Deleted and budget-omitted parents have explicit coverage. Repository search adds up to five discussion
items only for a hit matching the current subject; other subjects keep their body and an honest
current-subject-reader limitation. Files and subject-only reads stay focused. Through Work MCP, these
GitHub lookups also recheck the active caller after provider I/O and obey the 128-KiB response cap.
Chat source reads start with a centered window, then use signed source/range/turn-bound cursors to
expand beyond its consumed interval without repeating originals. The exact anchor remains available
on later pages. Retained native source-item receipts resolve to the admitted local original; they are
not treated as an interchangeable reader ID. Memory navigation stays inside the same Chat conversation.
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
`waiting_for_event`. A waiting result names every open wait its task holds, and one of them owns the
task's wait: the question for `waiting_for_input`, otherwise the timed wait that falls due first,
else the approval that expires first. Approvals and event-only watches ride beside a question;
approvals, later timed waits and event-only watches ride beside a timed owner. A wait whose deadline
passed can no longer resume its task, so a result leaves it out and acceptance answers it. The host
validates identifiers, authority, pending state, destination, receipts, and exact bytes. It does not
deterministically judge prose quality, root cause, or domain completeness.

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

The model-world scenarios use the production prompts, schemas, and semantic validators. The
offline Coop-runner suite proves that an unreadable quality judgment is rejected for repair in the
same Coop turn, that byte-identical repair attempts receive distinct attempt-bound validation
keys, and that a well-formed failing judgment fails instead of being silently accepted.

```console
scripts/elixir-test.sh test/ryker/evals
MIX_ENV=test mix ryker.eval world-pack
make eval-world-smoke
make eval-world
```

`world-pack` compiles every versioned scenario and its exact tool catalog without a model. The
quality judge runs each completed observation through the dedicated `RYKER_EVAL_SOCKET`
using `RYKER_EVAL_JUDGE_TARGET`, an empty-source read-only job, and no controller or project tools.
Provider-native tools are not disabled. Judge sessions are closed, checked with Coop's exact discard
plan, and discarded only when the workspace is clean. Unsafe cleanup fails the eval and retains the
session for inspection.

The world lane proves behavior with tools. `eval-world-smoke` runs the nine smoke-tagged scenarios
once at a strict 100% floor. The release `eval-world` gate runs the full corpus three times for a
dedicated candidate target and a separately pinned baseline target in the exact same deterministic
world, enforcing aggregate, per-case, hard-invariant, `UNRUN`, and paired-regression limits. One
versioned scenario directory is shared
by deterministic host replay and real-model execution. Its production Ryker state tools are real
and lease-authorized against an empty disposable PostgreSQL database; its metrics, scheduler, GitHub,
and similar external tools are a strict recorded cassette. Calls match important normalized
arguments rather than a global order, controlled failures are replayed per rule, and unmatched calls
return a bounded error instead of fabricated data. Visible output goes to inert Slack, GitHub and
Chat publishers that record each delivery and send nothing. Hard checks run first, then an isolated judge session scores every human-language rubric
criterion exactly once. Missing judge evidence remains `UNRUN`, never green.
Production has no Coop socket for the eval socket to be confused with: product builds reach Coop
only through the enrolled worker fleet, and the local socket client lives in `evals/`, which no
release compiles. Before any model turn, Ryker verifies the
exact job reference/digest and Coop's public `repository_read_only` bit; the dedicated worker runs
without production environment, credentials, network mutation tools, or project MCP configuration.

## Configuration

`Ryker.Work.Runtime` is optional. Its trusted configuration contains only:

- `api` and `client`: the Coop adapter every slot shares. Product assembly builds the outbound
  fleet client (`Ryker.CoopFleet.Client`) for the selected worker workspace; there is no local
  Coop socket option, and a configuration without an adapter does not start;
- `worker_ref`: stable identity prefix for this worker pool;
- `concurrency`: optional slot count, from 1 through 32 (default 4);
- `platform_tools`: optional exact names from the MCP catalog offered to the worker;
  these names make the frozen model context truthful but confer no authority;
- `connected`: optional, whether Slack and GitHub are running, so work tells a person what is
  actually connected rather than what is saved;
- `state_tools_endpoint`, `state_tools_secret` and `state_tool_capabilities`: optional, where a
  worker reaches Ryker's state tools, the secret each turn's token for them is derived from, and
  which of them it may call (the default set when an endpoint is given); and
- optional bounded polling and receive timeouts.

The Work profile an adapter freezes at ingress comes from an **environment** and describes all of
it: `environment_ref`, its `repositories` in order (the first is the default choice), the three
class policies (`policies`) of each read and write repository, its `parallel_goal_limit` and its
optional `emisar_connection_ref`. A read-only repository has no policies: every session mounts it
beside the working copy, and no work can choose to change it. Which repository a piece of work
changes is chosen per task, from the environment's read and write repositories: the routing decision names it on `start_episode` (see
[elixir-ingress-admission.md](elixir-ingress-admission.md)), a proposed task names it in
`request_task.repository`, a schedule keeps the one its confirmed offer named, and `reply` and
`continue_episode` keep whatever their work already pinned. `WorkProfile.policy_for(profile, class,
repository_ref)` returns that repository's policy for the class with the session's
`repository_context`: the chosen repository as the working copy and every other repository of the
environment mounted read-only beside it, so every session in an environment sees all of its
repositories. A session records the `environment_ref` it ran in; history outlives the settings row,
so neither is a foreign key. Work outside any environment keeps its single-repository or bare shape.

A Slack channel's work runs in the environment the channel chose, or in none; each Chat conversation
runs in the environment chosen for it (the default environment when it starts, "No environment", or
another chosen while it is open, for the messages that follow), and outside any environment while
its environment cannot run work; a webhook source names its own; an incident room keeps the
environment of the conversation it was opened from; GitHub events for a repository run in the
environment whose default repository it is, else the first (by ref) that holds it, else on the
repository alone, with that repository as the default choice. A confirmed task changes the
repository it names, under its environment's job template for that repository: the conversation's own
environment when that holds it, else the first environment (by ref) that does. Ryker freezes the
primary repository and companions, exact commits, model targets and execution bounds in one job
before placement. Coop fetches those repositories directly; it has no local policy catalog or
Ryker-owned checkout mount. Environment templates carry the `repository_ref` they are for.
GitHub tools accept any repository of the session's environment. There
are no repository groups and no per-purpose Emisar routes.

The Work runtime does not contain a model router. The adapter freezes a three-class Work profile at
ingress, admission selects one abstract class, and Ryker freezes that class's configured target in
the job. Keep conversational, standard and deep templates authority-equivalent. Writable task
execution remains a separate confirmed contributor grant rather than a `deep` side effect.

Ryker derives template and authority digests from its own settings. It also persists the complete
job and its digest before the first remote operation. Retries and restarts use that exact job;
operators never copy digests from workers or maintain a second policy configuration.

For example, where `fleet_client` is the client assembly built for the workspace:

```elixir
config :ryker, :work,
  api: Ryker.CoopFleet.Client,
  client: fleet_client,
  worker_ref: "ryker-work:host-a",
  concurrency: 4,
  platform_tools: ["list_runners", "find_actions"],
  poll_interval_ms: 250,
  receive_timeout_ms: 30_000
```

There is no YAML field; the runtime option is `platform_tools` (the evaluation settings pass the
same list as `source_and_action_tools`). The configured names must exactly match tools supplied by
the turn's controller-tools binding. An
incoming Slack, GitHub, webhook, or direct-conversation message cannot add a tool or change this list.
All of those sources share the same trusted Work runtime. Direct conversations also install a loopback
implementation of the exact Slack chat capability schemas: `list_slack_channels`, `search_slack`,
`read_slack_source`, `set_slack_reaction`, `post_slack_message`, and `post_slack_update`. In a Chat
turn those tools expose one virtual workspace scoped to the current Chat conversation. Reads return
only its durable messages; reactions, Work updates and confirmed additional posts use the ordinary
platform-action outbox but settle back into the local timeline. Human feedback reactions on
delivered replies are passive ordered episode events: they do not wake work, but both the bounded
add/remove history and current counts are frozen into the next logical turn. Chat message edits and deletes use the same stable-item revision contract as provider
adapters. Every result identifies the adapter as emulated with external effects disabled.
This lets the model make the same chat/tool/card choices without generating Slack test traffic or
receiving a Slack credential. Configured repository and Emisar tools remain real and retain the exact
Work policy authority. Incident offers start a real linked Work episode in the conversation under that pinned
authority; the virtual incident stays in the conversation instead of fabricating a Slack channel.
Slack workspace audience rules, real workspace data, and Slack API provisioning still require the
authenticated Slack adapter and its disposable live qualification.

`post_slack_update` lets live Slack and Chat work post a short message into its own conversation
before the answer: an early acknowledgement, a partial finding, or what it is doing next. It goes at
once, through the platform-action outbox, to the thread the turn's answer goes to (the input it
answers, over the episode's home). A turn posts at most three, in slots `update:1` to `update:3`;
the same words again are the same update, and a fourth is refused as `update_limit_reached`. An
update may name only the Slack entities the answer may (the same mention authority, rendering and
validation as the final reply). Observe-only runs and GitHub threads never see it.

`set_slack_reaction` is numbered the same way: at most three reactions a turn, in `reaction:1` to
`reaction:3`; the same emoji on the same message asked again is the same reaction (one taken back and
put on again is a new one), and a fourth is refused as `reaction_limit_reached`. Each update and each
reaction is sent only after every earlier one of its kind in the turn is delivered, and the final is
accepted only once all of them are, so they always read before the answer in Slack, in Chat and on
the timeline.

All slots share that one adapter. The fleet client places each session on an enrolled worker and
records the placement durably, so no slot addresses a Coop daemon of its own.

The worker never accepts a policy, repository, provider, credential, Slack destination, or tool set
from an incoming event. Those are admitted and pinned by their owning boundaries.

## Worker inspection evidence

A Coop worker can export one bounded, versioned account of a session it hosts: the network posture
the session was admitted under, what its newest run was observed doing, the session-wide receipt,
and the host-approved Coop task bound into its workspace. `Ryker.CoopFleet.SessionEvidenceDocument`
is the consumer half of that contract, held to the producer by the golden fixtures in
`testdata/protocol/coop-session-evidence*.json`, which Coop's own exporter test writes.

Collection is an observation and never changes what it observed. The capture runs at the completion
boundary beside narration sync, its result is discarded, and a worker that does not advertise
`session-evidence` is simply not asked. A failing, raising or contract-violating export cannot
spend a model call, alter frozen prompt bytes, change a decision or add an external effect.

Recording keys on the capture's content rather than its clock. A worker keeps no transition ledger,
so what it can honestly offer is the session as it stands; Ryker records a series of those
snapshots, and a poll that found nothing changed advances the times on the state already recorded
instead of manufacturing a history of identical rows. That is also the idempotency rule: a
redelivered command, a retried capture and two concurrent captures of one state converge on a
single row, with the unique index as the arbiter rather than a read-then-write.

Every section of the export states its own availability, because the reads behind them fail
independently: `unavailable`, `no_run` and `not_filtered` lead an operator to three different
investigations. Counters cross the wire as unsigned decimal strings and are stored as canonical
JSON text, because a collector value above 2^53 must survive both a browser and the database
unrounded, and a null counter is a metric nobody measured rather than a zero.

One sealed filtered run also appends a `network` session event carrying its grouped refusals, which
lands in the Work activity timeline in chronological position while the session-wide totals stay in
the capture. The fleet protocol must admit that event kind: a validator that knew only the activity
kinds rejected the whole poll when one arrived, so a single filtered run would have stopped the
worker polling at all. Only the three promised denial fields cross, and a destination the session
policy withheld arrives as the literal "name withheld".

`ControlPlane.WorkerEvidence` projects the newest capture per session into the episode's cards and
keeps four distinctions the page must not lose. Configured is not enforced — a captured policy says
what a session may reach, and only the enforcer layer's own observation says it was enforced.
Unknown is not zero — an unmeasured counter renders as Not recorded, and an unreadable registry
renders its cause rather than an absence of traffic. Withheld is not absent — a refusal whose
destination the session policy did not export says so. And a snapshot is not a history — the task
card is as of its capture, and a later capture never rewrites an earlier one.

Opening Network shows what the numbers can and cannot be trusted for: the four collector layers
with their own statuses, coverage per metric rather than one blanket word, what the collector lost
or truncated, the raised alerts explaining why a number may be wrong, the run and gateway epoch the
observation belongs to, and the session receipt with the run references it aggregated. Final and
complete are independent there — a closed session's receipt can be final and honestly partial — and
a filtered session that has not run still shows its provisional receipt, because "nothing has run
yet" is what the export exists to distinguish from a run that saw nothing.

The three cards render together under one Worker evidence heading. The approved design seats
Network access inside Work setup and the Network summary inside Work activity. The timeline has a
Work setup card for each Work run, but it does not hold Network access yet, and there is no Work
activity card, so the placement is still pending while the content is not. The section reads the
episode identity the page snapshot carries, so that identity is part of the snapshot rather than
something a card resolves for itself.

## A refused change goes back to its work

A confirmed task's completed turn arms its trusted review (`Publication.Custody`); Coop rebases the
committed change onto the latest base, runs the repository's gate in its trusted box, scans it, and
returns `publishable`, `gate`, `rebase`, `policy_findings` and `not_publishable_reasons`.
`Publication.Review.remedy/1` sorts a refusal, and `Publication.FixLoop` acts on it without a person
(Andrew, 2026-09-28: "it should be automatic feedback loop, agent needs to get errors from CI, fix
them without me doing a man in the middle"):

- **Fix** — `gate_failed`, `rebase_conflict`, `gate_modified_candidate`. Delivering the review posts a
  one-line notice instead of the refusal card, and in the same transaction admits a host-written input
  into the task's episode (actor and source `system:publication-review`, turn
  `turn:publication-fix:<publication>:g<review generation>`). The input names the causes in the
  host's words, says what to do about each, and hands over the failed gate's complete output when
  it was read (below). Work runs it as a new turn in the same session. When that turn commits and
  completes, the ordinary readiness path re-arms the same publication and the new commit is
  reviewed.
- **Check again** — `parent_moved`, `source_moved`, `fork_owner_active` alone. Storing the review
  starts a fresh review generation 30 seconds later instead; nothing is posted and no turn is spent.
- **A person** — any policy finding (a possible credential above all, even beside failed checks),
  `no_changes`, `gate_not_configured`, `gate_startup_error`, a gate that did not run, and any code
  Ryker cannot read. The refusal card is delivered as before.

Three fix rounds and three re-checks per publication (`fix_rounds`, `recheck_rounds`); after that
the refusal is delivered and the task card says `I tried to fix it 3 times; …`.
`fix_review_generation` names the review a round answers, so a round is running only while that
review is the publication's current one: a re-arm, **Review latest state** or **Discard candidate**
ends it without anyone clearing it. A round starts only for a confirmed task's publication whose
episode is at rest (`complete`) and whose task grant still stands; a refusal that lands while a
person's own follow-up runs leaves that turn alone, because its commit is reviewed afresh. The
delivery takes the conversation and episode locks before the publication's, the order Work and
admission already use, so a fix round and a completing turn never wait on each other.

The agent gets the failed gate's complete stdout and stderr, not an excerpt Ryker chose (Andrew,
2026-09-28: "Ryker should get full access to errors, warnings and all other output to work, like
any llm model would, it's a sandbox!!"). After a failed gate's review that could start a round,
the publication executor reads the output page by page through the Coop API adapter's optional
`read_review_gate_output/4` — `%{"output" => text, "next_cursor" => cursor | nil}` per page, or
`%{"lost" => reason}` when Coop could not capture or keep it — and `Publication.GateOutput` keeps
it as a `text/plain` input artifact, `gate-output.txt` (its last 4 MiB when longer; NUL bytes and
invalid UTF-8 mended), recorded beside the review as `review_gate_output`. The fix input carries the
file's descriptor, so the turn is handed the file, and its last 16 KiB inline as
`review.gate_output_end`; when Coop said it lost the output, the input says why and asks the agent
to run the gate itself. The read is best effort: an error, a reader that never finishes or an
unreadable page leaves the output unread and never fails the review.

Coop serves the output page by page from the job's own logs, with no opt-in, at
`GET /v1/sessions/{id}/reviews/{operation}/gate-output`, and says when it could not capture or keep
it. `Ryker.CoopFleet.Client` reads it through the fleet; a worker without that endpoint answers
with an error, the output stays unread, and the fix round tells the agent to run the gate itself.

## Retention and cleanup

`Ryker.Retention.Runtime` owns both remote workspace cleanup and local data horizons. For every
terminal episode it closes only the exact Coop session recorded in PostgreSQL, waits the configured
grace period, fetches an exact discard plan, and then:

- discards a clean workspace with no unreviewed changes;
- discards clean committed work only after its publication is durable;
- retains dirty or unpublished work for an operator; and
- blocks on crossed session identity, authority, or ambiguous cleanup instead of guessing.

A publication someone discarded is finished: cleanup and history retention wait only for one that
may still publish. Commits it never published keep its workspace retained, as any others do.

Each step goes to the worker that holds the session under whatever policy version and setup that
worker runs now: close, discard planning and discard do no policy work, and Coop's worker forwards
them without one. A worker that is away is waited for like any outage. A session whose worker was
removed from Ryker, or whose worker's Coop answers that it no longer knows it, ends with a
`worker_removed` or `remote_absent` receipt instead of waiting for a person who cannot help.

Blocked cleanup exposes its exact phase and bounded diagnostic in the local control plane. A
confirmed operator may rearm that same phase without changing the frozen session identity. A clean
workspace retained only for unpublished, unmerged commits may be explicitly discarded, but that
action always obtains a fresh Coop plan with unmerged acceptance; dirty work remains retained. Both
actions are idempotent and leave an audit row.

Before a finished episode becomes eligible for that history cleanup, `Ryker.Memories.Cases`
captures its compact case: the problem, the occurrence identities it was reported under, the
evidence-backed cause when one was actually established, what was attempted, how it ended, and the
links back to the sources. The case holds no raw payload, keeps the source identities it was built
from as lineage, and has no routine age expiry, so a matching incident a year later starts new work
with last year's record and its reviewed fix in hand while the transcript and Coop workspace that
produced it are still reclaimed on schedule. Capture is idempotent by content, so repeated close,
reopen, cleanup and restart events keep one case per intended revision rather than a record that
feeds on its own output.

A lesson drawn from a case is a draft until it is reviewed; only an approved lesson is presented as
a reusable procedure, and approving a new revision supersedes the one it replaces. Both are reached
from `search_memory`'s `case` kind and from the first Work briefing's `retained_cases`, always as
history: a past fix is advice about what worked once, never proof that this incident has the same
cause or permission to repeat it. Deletion is explicit and reaches everything derived — the case
text and every lesson are erased while the identity remains, and the next capture does not rebuild
a deleted case.

Routine expiry of a transcript is not a withdrawal, but somebody deleting a message the work was
built from, or editing it to say something else, is. Ryker withdraws the case as it receives the
change: a message's through ingress, and a review comment's on Ryker's own pull request through
publication follow-ups. A case already kept is found by the message identities it keeps and
redacted. Work that is still running, or finished but not yet captured, keeps its case
withdrawn, so capture never builds it. A typo fixed while the work runs therefore drops that work's
case. An edit that leaves the text as it was, as Slack reports a link's preview arriving, takes
nothing back, and neither does an app or a bot updating its own message, as an alert does when it
resolves. Deleting a Slack channel withdraws, the same way, every case of work that lived there or
that one of its messages joined: a case records every conversation its messages came from. A case
kept before 2026-09-28 is found by the conversation its work lived in, and by those of its messages
Ryker still held that day.

Large ingress, prompt, candidate, validation, delivery, and artifact bodies are redacted on the
operational horizon only after all of the episode's Coop sessions are proven discarded. The episode
event stream remains coherent until `episode_history_seconds`; it is never thinned one event at a
time. Open waits, blocked turns, pending approvals, live schedules, unpublished changes, active
incident rooms, and unresolved state records pin that history regardless of age. Compact session and
delivery receipts remain until `audit_data_seconds`. Worker inspection evidence holds exported
bodies — refused destinations, admitted rule texts, the agent's own task note — so it expires with
the episode's history and again with the session row it describes; a capture taken after expiry
records what is observed now and never revives the expired snapshot. Pruning runs in bounded
batches and short transactions so retention cannot monopolize a busy database. Every table has an executable retention
class, and every age/lease comparison uses PostgreSQL time.

The copies kept for training are the two deliberate exceptions: routing decisions
(`routing_examples`), a redacted copy of the prompt, the answer and the outcome, and settled Work
turns (`work_examples`), a redacted copy of the briefing, what the worker did and the result Ryker
accepted. Each is kept under its own limit while a person keeps it on, and erased when a person
forgets or deletes a message it quotes. [Training data](training-data.md) says what a copy holds,
when it is taken and how to export it.

One cleanup pass claims repeatedly under a bounded budget: at most `batch_limit` phases, at most
`batch_seconds` of wall time, and at most one phase per session. Candidates are ordered by
eligibility, the durable time the session became claimable — the owner's terminal time before
close, `discard_after` after it, and the publication time for work retained as unpublished and
unmerged. `Ryker.Retention.Custody.eligible_query/1` is the single definition of that set;
readiness and the operator preview read it rather than restating it, so a Work or learning backlog
can never be counted differently by the surface that reports it.

A pass stops claiming work for any worker that has already proved unreachable inside it. Outage
failures retry with bounded backoff forever and never exhaust `max_attempts`; a restart releases
the host's own leases, and a worker heartbeat newer than the failed attempt cancels its backoff.
A dirty retained workspace is replanned every `retained_recheck_seconds` from fresh Coop evidence.

`make retention-simulation` runs thirty accelerated days of this lifecycle through the real
custody, dispatcher and executor against a fake fleet: a pre-existing backlog, at least one
hundred completions per simulated day in bursts, dirty, unmerged, still-running and
publication-pinned work, a multi-day worker outage, host restarts and lost responses. It shadows
PostgreSQL's clock on its own connection, so eligibility, grace, backoff and retained rechecks
elapse without waiting, and writes the per-day inventory, high-water marks and latency to
`artifacts/`. It is part of `make check`, not the fast gate, because it takes minutes.

Each worker poll may carry a strictly validated `storage` object: measured capacity, free, reserve,
watermarks, inactive disposable bytes, protected bytes, optional unattributed bytes, and the
worker's own `open`/`refused` allocation decision. It is optional; absent means unknown, never
zero. Ryker stores the last report, counts the decrease in reported disposable bytes as
measured reclamation, and refuses to place new fork-requiring sessions on a worker that reports
`refused` while leaving cleanup, control, and existing-work recovery on that worker alone.
