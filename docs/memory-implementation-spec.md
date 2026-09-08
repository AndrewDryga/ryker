# Memory maintenance and recall: implementation specification

Date: 2026-09-08. Baseline: `f664a3e10c8eec85cbbfea9feba5bc94ad0bcd62`.
Status: implementation awaiting final qualification after fifteen completed exact Fable reviews. The user authorized spec review, implementation,
verification, and deployment, and permits resetting memory data if that simplifies the cutover.
Research and rejected alternatives: [memory research](research/memory-systems.md).

## In plain English

Responder keeps original messages as evidence. A background learner reads a small group of new
messages, even when there is nothing useful to say back. It looks for existing related topics,
then updates one, creates a genuinely different topic, or saves nothing. Before accepting a new
topic, the host checks once more for an existing match the learner might have missed.

Topics hold the current understanding and its update history. Conversation handovers summarize
ongoing work; they are not another topic database. Confirmed preferences and guidance keep their
separate human-confirmation rules. Search finds relevant memories and links back to original
messages. None of these memories grants permission to act or proves that an old deployment is
still healthy.

If a topic loses its supporting sources, Responder stops using it. An operator can select current
originals to relearn the same topic, preserving its identity and history. Failed attempts stay
visible and have a fixed spending limit; restarting the worker does not buy unlimited retries.

## 1. Product contract and scope

Responder learns from authorized retained conversation inputs independently of replying.
One supervised background lane maintains current topic knowledge. It reads original Inbox
revisions, not model-written observations. Admission decides response/work routing; Work owns
execution; confirmed preferences/guidance remain operator-confirmed. No second agent runtime.

This change includes: topic identity/create checking, source-capacity repair, passive learning,
bounded failure recovery, useful existing memory search, operator progress/failure visibility,
recorded-world tests, and deployment. It does not add cross-transport sharing permissions,
automatic procedure promotion, embeddings, a graph database, or a model-visible omission index.
Current independently authorized GitHub source access and routed review feedback stay available.

## 2. Topic identity and update-or-create protocol

Topic UUID is identity. Titles and model-generated topic keys are not identity guarantees.
The writable scope remains transport/workspace/conversation/repository; recall does not grant
write authority. Keep `target_ref` and `expected_version` for exact updates.

Add a bounded `anchors` array to topic proposals/state: at most eight exact source identities,
each at most 512 bytes. An anchor must occur in an eligible source input or an offered target's
anchors; the host normalizes platform URLs and qualifies them with the authorized source scope.
It is an indexed matching clue, not authority and not necessarily a unique subject. A service,
thread, or PR may be associated with several topics. Do not impose uniqueness on generic anchors.

Candidate selection combines authorized exact anchors, direct source/reply relationships where
available, and PostgreSQL full-text matching. Search specific proposed titles/subjects instead
of relying only on whole-message boilerplate. Offer at most eight relevant topics, no unrelated
recent fallback. Pinned retry alternatives must remain included after ranking and prompt packing
or the attempt fails explicitly with a capacity error. Interleave the remaining thread, proposed-key
and lexical candidates, and interleave hits across input threads, so one busy thread or retry's keys
cannot consume every unreserved slot. The eight-slot selection is bounded discovery, not exhaustive
search or proof that all matching topics have been seen.

For an elliptical reply, use retained direct source membership to offer topics from its exact
conversation/thread even when no subject word is repeated. Match a root without a thread value by
its original message identity. The lookup still applies current source validity and the exact
writable scope; inherited background context is not a direct thread relationship. This supplies
candidates, not a forced merge. Include original native message, source-item and destination/thread
identities in the frozen learning input; never invent missing parent text.

The learning result contains `updates` plus a bounded explanation. Each item has an explicit
action (`update`, `create`, or `defer`), subject fields, source input IDs, and exact target/version
for updates. Empty updates means no durable change. `defer` retains an explanation and the input
reference; it does not create a topic. A contradictory statement about the same subject updates
that subject's history rather than automatically creating another one.

Before accepting any create, run one host-owned matching pass using its title, topic terms,
anchors, and eligible original source. If this finds an unoffered plausible existing topic,
reject the candidate as `learning_match_required`, pin those topic IDs in the batch's next
judgment, and ask for update/create/defer with those alternatives visible. This consumes the
same batch's judgment budget. A create can pass after the relevant alternatives were considered;
low similarity is not itself proof of novelty. No unlimited model-driven search loop.
Recheck the direct threads of that proposal's contributing source inputs too: another batch may
have learned the parent's topic after this judgment's briefing was frozen.

Fresh attempts include bounded static host feedback for a rejected anchor, matching collision or
invalid result shape. Count this feedback inside the same prompt budget. Do not echo the rejected
candidate, whose former source context may no longer be eligible. Anchors come from subject values
in message content or the offered target, not sender/routing metadata. Retry feedback changes the
next frozen attempt; it never rewrites a prior prompt or resets its spending budget.

Serialize creation decisions per writable scope with the existing transaction-lock idiom;
recheck matches while holding that scope lock. A competing insert either becomes a visible
candidate or causes a bounded retry. Existing updates still require the exact offered version.
An inaccessible/expired/over-capacity known target is not permission to silently reset it or
invent a differently named replacement. Return explicit unavailable/deferred state.

A new OOM occurrence is distinct history from last week's occurrence. A service topic may retain
several occurrences, but must preserve their separate chronology rather than overwrite an older
occurrence or present its resolution as the new one's recovery. An occurrence-specific topic must
not silently absorb a different occurrence. A resolution updates the same occurrence and may
update existing service context; it does not reopen old execution work. Do not require a new memory
row per incident when a maintained service topic is the useful unit of knowledge.

On update the key stays fixed, while the title may follow the current state. Create keys must be
unused; a collision is not an instruction to merge genuinely distinct subjects. Preserve material
decision/correction attribution and uncertainty. Detailed speaker chronology remains recoverable
through retained revisions and original source links; do not force every summary to list all speakers.

## 3. Source custody without copying an expanding history into every revision

Preserve the distinction between direct support and every source disclosed to the model.
All disclosed roots remain dependencies even when the model does not cite them. Reduce irrelevant
disclosure first; storage normalization is not a substitute.

Use a single canonical dependency format: raw input receipts plus immutable knowledge references.
Knowledge references identify UUID, generation, and through-version and resolve to materialized
terminal raw receipt rows, not recursive model-authored graphs. Unknown/malformed references fail
closed. Canonical encoded dependencies and expanded roots each have a host safety budget of
10,000 entries/8 MiB. Exceeding either is an explicit capacity failure, never truncation. In normal
learning, compact custody is sixteen raw inputs and at most eight topic references. Prompt bytes
have their own independent limit. Ten thousand is a supported ceiling, not unlimited memory.

Extend existing `conversation_knowledge_sources` to store every immutable receipt, keyed by
knowledge/generation/receipt fingerprint, with first introduced version and optional first direct
support version. Append only newly inherited receipts. Each revision stores a compact owner
reference rather than another full copy of all roots. Current state and historical through-version
lookups use the same source memberships. Later direct citation must not rewrite older attribution.

The same source rules apply to model-authored episode evidence and recalled outcomes, not just
objects called memory. A replacement session must not recover withdrawn text through `records`,
`get_work_state`, `related_outcomes`, or a previous delivery. Resolve each exact host-owned
projection to its producing turn/session and authorize that producer's sources before disclosure.
Register inherited source and knowledge dependencies in the receiving session so a later
revocation also prevents acceptance. Bind the projection to its canonical stored content; missing
producer custody fails closed. Keep raw operator/audit history separate from model-authorized reads.
An existing session with no exposure rows is not automatically source-free: it may predate this
custody or have missing rows. Successful exposure records source/knowledge row counts under the
same session lock, including an intentionally empty submission. Reuse requires that marker and
matching retained counts. This attests Responder-accounted disclosures, not untracked native or
live-platform reads. Failed exposure cannot initialize the marker.
The existing source-exposure table has no per-turn disclosure cutoff, so this uses the producer
session's accumulated dependencies conservatively. Later disclosures can make an earlier record
unavailable; do not claim precise per-record source attribution or copy every root onto every row.

Summaries and rollups retain bounded raw receipts plus exact compact topic-generation references;
no new summary membership tables. The real summary writer must preserve both from its producing
session, not flatten away a topic's generation fence. Identical covered raw roots need not be stored
twice, but an earlier raw lifetime must remain. Missing custody makes the optional handover
unavailable. They are current handovers rather than a growing per-update revision ledger. Their frozen
documents still bind to the exact state fingerprint. Existing session `SourceExposure` rows remain
the authority for all already disclosed sources, preserve the earliest lifetime, and are read up to
10,001 entries so overflow is explicit. Do not eagerly flatten knowledge references into every
LearningRun; doing so would recreate quadratic storage under a different table name.

`LearningSources` must resolve compact references for merge/validation/exposure and retention.
Replace eligibility SQL, source expansion, locked validation, and retention together. One path
for all set sizes: no JSON-small/relational-large fallback. Group root validation by unique
observation ID in deterministic lock order. Retain current shared-row locks across application;
do not introduce an unproved generation-fence optimization. Check access before selection and
again after acquiring source locks. Preserve existing session invalidation on revocation.

Admission observations become host-produced source excerpts rather than another model-written
memory layer: retain source identity and a bounded original-message excerpt with its single
source receipt. Remove `observation` and `knowledge` from the admission model output contract
and their model-write paths in the same change. This stops prior observation dependencies from
recursively accumulating. Original complete input remains available for learning and expansion.

Knowledge overflow, late evidence, and compaction failures are explicit. Never report successful
application when no change was saved. Late input is ordered by ingestion/revision for processing;
source event time is preserved for meaning, not used as a blanket discard test. A blocked
compaction group cannot permanently occupy the oldest maintenance window.

## 4. Durable background learning

Introduce `Responder.Learning.Runtime`, a bounded worker and a small durable batch owner reusing
`State.Learning` for frozen prompts/results and application. Configuration is an explicit optional
`learning` section with trusted policy/digest, concurrency, and spending/retry bounds. Product
examples enable it; missing setup is visible as disabled, not silently advertised as learning.

Defaults to evaluate: one worker, 16 inputs per batch, 10-second quiet delay, 60-second maximum
delay, 300-second lease, 30-second heartbeat, and three host execution starts per frozen batch.
Provider-internal contract attempts are bounded separately by the configured trusted Coop policy;
three host starts must never be presented as three actual model invocations.
Coalesce only the same writable scope and execution mode. Use database time. Input revisions
already assigned to an active or deferred batch cannot be claimed again under a different key.
New inputs do not mutate an attempted batch. Quiet/max-delay timers start when admission makes
an input eligible (`updated_at` on the decided Inbox entry), not its historical event or arrival
time; delayed admission must not defeat coalescing. Edits invalidate old source custody and become
new eligible revisions. Deletions revoke derived content and are acknowledged without learning prose.

Batch states: queued, running, applied, no_change, deferred, superseded. A batch table owns scope,
execution mode, lease owner/expiry, heartbeat, start count, next attempt time and error. A membership
table has Inbox entry ID as primary key, an exact batch FK and terminal reason. Claim and input
assignment are atomic; lease expiry recovers the same batch. A LearningRun gets `started_at` and
frozen remote operation identity before first submission; resume cannot set a second start.
Provider failure, semantic rejection and match correction have separate reasons but share the
absolute start budget. Source/version invalidation before a start is free; invalidating a completed
model execution does not undo its cost. No reset on a new generation or receipt pruning.
Recovery of a prepared but never-started run must pass through the durable counted-start boundary
before any remote execution. Reclaiming it cannot loop forever with zero starts or spend twice.
If one assigned original becomes unavailable, retire that membership rather than silently marking
its valid siblings processed. After proving any previous remote attempt stopped, prepare remaining
eligible originals within the same batch and lifetime budget. Preserve attempted manifests; do not
move survivors into a fresh batch to obtain more starts. Operator retry must not reopen unavailable
memberships, and validates only the surviving inputs it can actually retry.
Transient transport uncertainty resumes the same operation key, not a new billable judgment.
After the start budget is exhausted defer the whole batch with a visible reason; do not blame one input.
Retry delays are bounded. A conversation pauses new model starts temporarily after repeated
failed batches; other conversations continue. Operator retry is explicit and audited.
Each operator retry grants exactly one additional host start using the displayed budget version;
the lifetime start counter never resets. Duplicate action receipts cannot add another grant.
An early failed grant's unused allowance does not accumulate: the new ceiling is spent starts
plus one. The separate monotonic budget version prevents stale-form reuse as that ceiling changes.
Refuse the grant if source authority has expired, that scope is already active, or an earlier
remote turn lacks stop proof. A still-running remote operation requires custody reconciliation,
not permission to launch a duplicate.

Use Coop sessions with no product checkout, project environment, MCP, or Responder action tools.
The current Coop runtime requires an execution fork even for a read-only model call; pin a
dedicated empty scratch repository with `repository_read_only=true`, `project_env=false`, and
`project_mcp=false`. Do not describe these flags as disabling provider built-in tools: they
remove product capabilities and writable repository authority, not the provider's tool vocabulary.
Check those public authority fields and absence of companion repositories before submitting
any source text. Qualification must inspect the actual isolated execution and cleanup.
Reject any returned `responder_binding_digest`: the learner intentionally creates an unbound
session and must not receive Responder state/action tools through an unexpected binding.

The installed Coop runtime does not provide a no-native-tools or provider-only-network policy.
Read-only applies to the repository mount, with a writable `.coop-output` directory; provider
home and container scratch remain writable. The Codex ACP adapter starts in full-access mode,
and Coop automatically approves offered native-tool permissions. Disabling project MCP does
not remove those tools. Network egress is a runtime setting (`open` or `none`), not a learner
policy field; `none` also prevents the provider client reaching its model API. Do not describe
an empty repository as an offline or fully source-confined execution environment. Source-only
learning currently means bounded supplied evidence, source-data instructions and validated
update provenance, not proof that the model could not consult outside information.
If enforced no-native-tools execution is required for unattended activation, qualify that
capability in Coop/provider execution first; do not silently introduce a second model runtime.

Add execution kind `learning`, a
`learning_run_id` FK/pair uniqueness constraint, an external reference `responder-learning:<run UUID>`,
and the corresponding owner check to existing execution-session/fleet placement custody. Include
discarded learning sessions in retention cleanup. No Work timeline activity-sync callback: the
learning receipt owns its prompt, public result, producer, errors and execution identity. Use configured local
Coop only in the existing development topology; production uses the fleet client, not a new local
shortcut. Freeze the create/submit/validation identities; reauthorize sources immediately before
submission and result application. Lost create/submit/accept replies reconcile by operation key.
Record result before remote acknowledgment, then apply idempotently after exact validation.
Close/discard the owned session through existing proof-bearing retention custody, including after failure.
Never hold a DB transaction open during provider I/O. A lost lease forbids further local acceptance
or new provider calls by that worker; the next lease holder reconciles the exact outstanding keys.
Before a new judgment starts, prove the old remote turn stopped. Never treat a missing lookup as
proof of absence: use Coop's exact create/submit fence. Stop/cancel waits and unresolved remote
reconciliations have a separate twelve-step budget, followed by a final fence/cancel attempt and
visible operator custody if the provider remains unreachable. Cancellation keys bind run and exact
session revision; retrying cancellation cannot buy a new model turn.
After the rapid reconciliation budget is spent, retry only reconciliation once per hour. Keep the
whole writable scope fenced while any older turn lacks stop proof, even when new inputs arrive.
Recover the original batch and membership after connectivity returns; never give its remaining
budget to a fresh set of inputs.

A model's `defer` is a terminal no-change judgment with its explanation, not a conversation pause.
New evidence must still be eligible. Only execution/capacity failures pause new starts temporarily.
An applied result whose body later expires remains an applied receipt; restart must not parse a
missing body or infer a new judgment. Stop proof survives a local apply rejection after remote acceptance.

The learning lane provides no host-published replies, episode creation, Responder state tools,
or governed infrastructure actions. Its instructions prohibit responding or taking action through
native tools, but the existing provider sandbox does not technically disable those tools or their
external effects. Shadow/live inputs have the same learning semantics but do not cross
execution-mode boundaries. Recent raw excerpts remain available to admission/Work before
consolidation catches up.

## 5. Recall contract

Extend existing `search_memory`, not a second tool. Reuse tokenized PostgreSQL search for topic
queries; retain literal/exact-identifier matching. Use deliberate round-robin kind ordering
(facts, guidance, continuity, then each next result) instead of category starvation. Knowledge,
observations, and summaries remain labelled, with source expansion links. Existing completed-work
outcomes stay the destination-scoped `related_outcomes` briefing projection, not a new paginated
lane. A future outcome search must inherit the exact producing Work session's roots, not assume
that a summary covers its response or treat an unknown source reference as dependency-free.

Implement a host-signed cursor bound to normalized query, requested kinds, scope, active binding,
and a stable cutoff. Page size stays 1–20. Use per-kind stable keyset positions, not mutable
`last_recalled_at`/`updated_at`. Recheck authorization every page. Reject cursor tampering,
query/scope reuse, and expired cursor state. Return explicit exhausted/unavailable results rather
than a permanently nil cursor. Bound rows scanned and response bytes as well as visible count.

Time filters distinguish source occurrence from content change/confirmation time. Include retained
source references in results and reuse existing Slack source readers; do not invent original text
when only a derived summary remains. No cross-transport authorization expansion in this change.
The concrete fields are `time_basis` (`source` or `changed`), inclusive `after`, and exclusive
`before`, both UTC timestamps or null. Source time is the message's event time for an excerpt,
latest supporting message for a topic/handover, and human confirmation time for a confirmed item.
Changed time is content/confirmation/edit time, not recall counters. Explicit history search keeps
original excerpts reachable even after consolidation; automatic briefing still removes covered
duplicates. Empty query allows date browsing. Cursor lifetime is one hour, maximum4096 bytes.
Use the database clock for both cursor cutoffs and memory insertion/content-change timestamps.
Do not mix an Ecto host-generated insertion time with a database cutoff: clock skew can hide a
just-saved result. Preserve original source occurrence, human confirmation and inherited retention
times separately. This applies to topic revisions, excerpts, handovers/rollups, confirmed entries
and imported entries; a fixed-clock regression must cover both inserts and subsequent updates.
Each page permits64 candidate visits and64KiB of result documents; PostgreSQL statements time out
after five seconds with an explicit search-budget error. These are live keyset traversals, not a
transaction held across calls: revoked or edited rows disappear and new content requires a fresh
search. No claim that a last-page cursor freezes historical versions of every mutable store.

## 6. Operator experience and cutover

Current knowledge remains the main memory page. Show learning enabled/disabled, queued/deferred
batches, oldest unprocessed age, no-change receipts, and actionable error descriptions. A failed
batch links to its frozen input/result and permits bounded explicit retry. Observations are labelled
source excerpts; summaries are conversation handovers. Show change/source/expiry dates separately.

### Repairing unavailable knowledge

Provide one explicit **Relearn from current sources** action on the existing topic page. The
operator selects 1–16 retained, currently authorized original messages in the topic's exact
conversation/repository and one execution mode. Suggest the topic's former direct sources via
their current source revisions first. Also allow explicit selection of other current originals
in that same scope: otherwise deletion of every old original would make the topic permanently
unrepairable. The operator chooses the association; it is not an automatic same-subject claim.
Show message excerpts, source links and dates, with bounded search/pagination. No model execution
when no usable source is selected. This cannot modify confirmed facts, guidance or authority.
Keep up to sixteen explicit selections across search, pages and live refreshes within the same
browser tab. Store only their opaque revision receipts, never message text; clear selection when
the target/version changes and remove a visible source whose revision changed. Without browser
storage, explain that selection is limited to the current page. Never select sources automatically.

Reuse the existing audited operator action and learning batch/worker. A rebuild batch pins the
topic UUID/version/source generation and exact selected input revision/fingerprint receipts.
Keep ordinary exclusive input memberships untouched. Permit one rebuild batch per target
generation, with the normal scope lease and outstanding-remote fences. Repeated clicks return
the existing batch rather than creating another spending budget. Reselection is an explicit,
budget-version-checked action on that batch after old execution is proven stopped; spent starts
remain spent. Failed, no-change and deferred rebuilds must expose a usable bounded retry path.
If the topic advances within the same generation, reselection must explicitly confirm its current
version. A selection may change the batch to one new execution mode only after checking both old
and new scope activity; mixed-mode selections are rejected. Preserve the batch and prior attempts.
Display attempt history chronologically with batch-wide numbering, not the execution generation
that restarts when the frozen source selection changes.

Include rebuild identity and selection in the frozen attempt key and instruction/contract digest.
Use a fresh source-only session, no old topic title, prose, anchors, results or topic candidates.
Allow at most one proposed understanding (`create`) or defer, or an empty no-change result.
Host validation enforces this restriction even if the model ignores it. The host binds the
target identity; the normal automatic create check cannot reject the target's reserved key.
Any collision with another topic must fail explicitly, not silently merge its identity.

Only successful, source-reauthorized application changes the head: compare exact UUID/version/
generation under lock, preserve UUID and topic key, increment version and source generation,
and inherit only the newly disclosed valid roots. Preserve old revision/generation history for
operator inspection under existing retention. No-change, defer and failure leave the unavailable
head unchanged. Model-facing revision/reference eligibility requires the current generation;
old-generation warm sessions enter existing stale-session recovery. Merely validating old roots
is insufficient: an early revision can have valid roots even after a later revision made the
head unavailable. Retention and read-only audit inspection still resolve old generations.
Track compact knowledge dependencies disclosed through summaries and rollups too, not only topics
shown directly. Lock their current heads without waiting on a concurrent writer before first
disclosure; yield on contention and reject an already replaced generation. A warm session cannot
keep old-generation understanding usable merely because its original raw messages remain valid.

The user's reset permission applies to derived memory. The source-storage migration deliberately
resets topic heads and their cascading revisions/source memberships, rather than retaining a
second source representation or guessing missing historical receipts. Before applying this reset,
enumerate exact tables/rows and existing active sessions. Preserve unrelated episodes, ingress,
preferences/guidance, credentials, configuration, and delivery/work custody. Invalidate affected
sessions through existing source/session validity rules, not by erasing the evidence of exposure.
Retain a qualified database backup and drain affected active work before migration. Never run a
broad database or directory deletion. Report exact deleted counts and backup recoverability.

## 7. Owning implementation boundaries

- Topic matching/write: `state/knowledge.ex`, `knowledge_update.ex`, `learning.ex`, their schemas,
  owning tests, and a small `KnowledgeMatching` helper only if it removes actual duplicated logic.
- Source custody: `learning_sources.ex`, `knowledge_source.ex`, `knowledge_snapshot.ex`,
  `knowledge_retention.ex`, `observations.ex`, `continuity.ex`, owner schemas and one clean migration.
- Admission cut: `admission/decision.ex`, `admission/prompt.ex`, `admission.ex`, checked contracts,
  recorded evaluation adapters, and all owning tests. Preserve the unrelated routing policy.
- Worker/fleet: new `learning/` runtime/custody/executor modules; `runtime_configuration.ex`,
  `application.ex`, `work/session.ex`, fleet ownership/cleanup constraints and tests.
- Recall: `state_tools/fixed_tools.ex`, `state_tools/tools.ex`, memories/behaviors/continuity search,
  signed cursor helper and query indexes. Keep active-binding authorization.
- UI: existing memory page/projector, learning receipts, routes and tests; no duplicate dashboard.
- Documentation: research link, runtime/capability contracts, configuration examples, this spec.

## 8. Verification and completion

Implement in ordered slices, with focused tests after each change:

1. Matching/no-loss regressions: unrelated fallback, false new topic, different-subject non-merge,
   simultaneous creation, stale expected version, capacity omission, and late corrections.
2. Source representation: 129 successive updates and 1,000/10,000-root boundaries; structurally
   seed 9,999 historical revisions, then execute the actual next update without quadratic revision
   memberships. Label the structural seed rather than claim 10,000 model runs. Cover exposure,
   revocation/expiry races, fingerprint mismatch and unknown shapes.
3. Single writer: unmentioned keep decision, no-op chatter, raw-source input instead of derived
   note, rapid correction before background work, distinct incident recurrences.
4. Durable execution: restart at every remote boundary, stale lease, coalescing fairness,
   schema/semantic/create-check budget exhaustion, generation/pruning invariance and cleanup.
5. Recall/UI: real later pages, lexical paraphrase, kind diversity, dates, cursor tampering,
   permission changes, source expansion, useful operator errors and read-only inspection.
6. Harvested model evaluation: recorded Blitz decisions, Livebook intent, OOM lifecycle and
   duplicate-topic cases under pinned policy; held-out later questions, no later-event leakage,
   no public replay activity. Measure false splits/merges, answer quality, cost and learning lag.

Fixtures come from retained records; synthetic cardinality/concurrency expansion is labelled.
For production fixes prove the regression fails on prior behavior before applying the fix.
Run `make dev-check` before commit, `make check` once before shipping these shared contracts,
and the appropriate credentialed schema/prompt evaluation. Review the completed diff through
staff/security/rules/UX lenses and fix blockers. Commit only this task's changes.

Deploy the exact committed release, verify running version, `/healthz` and `/readyz`, and inspect
learning activation/receipts. `scripts/deploy.sh` requires Linux/systemd; this workstation is macOS.
Resolve the existing installed local release/launcher if that is the target, use the same immutable
archive qualification/install/version proof, and report that boundary honestly. Do not restart
or install independently managed Coop workers. No claim that a green test equals deployed behavior.

## Review record

Fable 5.1 (`claude-fable-5-1`) reviewed the full draft and owning Elixir code on 2026-09-08.
Its verdict was "not implementable as written", with concrete custody/schema gaps, not approval.
The public review is retained at
`/private/tmp/responder-memory-build.TJkOPg/fable-spec-initial.jsonl` (result record only).

Accepted corrections:

- Keep the unique scope/topic-key index as a final collision fence, despite UUID being identity.
  Turn a collision into a matching correction, not permission to replace a topic.
- Add explicit batch and exclusive input-membership tables; LearningRun alone is not a queue.
- Add the learning owner constraint, fleet external identity, and retention cleanup in one cut.
  Learning needs its own frozen result receipts, not Work timeline activity sync.
- Count host-rejected outputs as failures, while source/version invalidation does not spend the
  model-failure budget. Invalid attempts remain counted after diagnostic pruning.
- Keep latest source time monotonic, but never discard useful late input just because its event
  time is older. Remove unrelated candidate top-up in both learning and Work context.
- Replace source-note-based retention with full membership/introduced-version retention.
- Assess deterministic conversion before resetting; the implemented source-storage cut uses the
  explicitly authorized derived-topic reset, with backup and active-session qualification required.

Two review suggestions need correction before applying them:

- Removing admission's topic writes does not remove its use of source-derived routing context.
  Keep frozen source authorization and revalidation; removing all context custody would weaken it.
- Summary dependencies are the entire session's exposed roots, not just one source. Removing the
  summary capacity skip without fixing that root budget merely turns silent loss into repeated
  failure. Resolve storage/expansion consistently before calling that slice complete.

The first implementation slice is deliberately independent of these storage choices: regression-
proven removal of unrelated candidate fill, explicit late-input application, and bounded rejected
results. The full source/worker/recall slices remain required and are not claimed complete.

The second Fable review is retained in the same directory as `fable-spec-followup.jsonl` (result
record only). It agreed to preserve admission source custody, use fresh frozen generations for
matching corrections, count execution starts rather than merely failures, preserve case-sensitive
anchors, and normalize knowledge without adding summary-reference tables. It explicitly did not
give blanket approval before implementation/testing. The review identified every existing JSON
retention scan, session root cap and silent-success path as part of the required storage cut.
Its suggestion to pin writable alternatives from other channels is not adopted: recall scope is
not write scope. Current-channel/repository writable boundaries remain unchanged.

Fable's third, implementation-specific storage review is retained as `fable-spec-storage.jsonl`
(public result only). Its warm-session direct-versus-inherited count bug was reproduced and fixed,
with historical attribution and source revocation covered. Per-root exposure round trips were
replaced by bounded batches; repeated reads preserve earliest lifetime and do not rewrite rows.
Pruned summaries/rollups keep audit identities but release unused raw dependency lists, instead
of deleting their audit rows. Knowledge memberships remain because immutable revision references
still need their roots. Source/scope-capacity maintenance failures defer the affected group;
they do not roll back unrelated healthy maintenance. The 10k-source query timeout was traced
with actual PostgreSQL plans to repeated source scans under low row estimates and fixed with
parameterized indexed source lookups. These are focused slice results, not full-product approval.

Implementation reviews four through seven (`fable-spec-matching.jsonl`, `fable-spec-runtime.jsonl`,
`fable-spec-executor.jsonl`, `fable-spec-retry-boundary.jsonl`; public results only) drove the exact
anchor/source rules, one owned execution fork, stop-proof retention, bounded uncertainty, and
scope-wide reconciliation. A prepared attempt now belongs to its batch before a model starts.
An unresolved old remote turn blocks later batches in that scope and is reclaimed for hourly
reconciliation. Early operator retry grants one start, not the unused balance of an older grant.
The alleged policy-rotation mismatch was not reproduced: preparation pins the original batch's
policy/digest. A regression verifies that behavior; current config does not rewrite old attempts.

Review eight (`fable-spec-recall.jsonl`; public result only) identified confirmed-row revocation
and cross-lane locking gaps and required unknown source references to fail closed. Those fixes
are being regression-tested before release. It recommended keeping existing automatic outcomes
separate rather than adding an unaccounted result shape to search. The existing live Slack reader
rechecks access but records audit metadata rather than input-root lineage for all returned bodies;
this is a preexisting boundary limitation, not proof of complete warm-session revocation for live
platform reads. Source-reader custody beyond internal memory is not silently claimed solved here.

Review nine (`fable-spec-live-behavior-readable.jsonl`, public result only) compared the actual
HAProxy, draft-keep and chatter runs with their original inputs and held-out Work answers. The first
attempt could not read the private report directory and is not counted as a completed behavioral
review. The corrected read-only run verified chronology, absence of later-message leakage,
same-channel/cross-thread consolidation, no-change chatter, and retained cleanup receipts. It found
a tentative relationship restated as fact in the Work answer, a stale title, and unclear create-key
collision guidance. Targeted prompt changes and repeat live evaluation are required before approval.

Do not adopt the suggested short-message host skip: a brief "yes" can contain the important decision.
Batching amortizes listening cost without guessing which messages are meaningless. Nor do exact
phrase tests or mandatory actor-ID counts establish answer quality. Review the repeated answer
against source-supported meaning. Actor display-name enrichment is a possible later UI/context
improvement, not permission to infer identities or widen entity grants. Recurrence evaluation may
accept a service topic with clearly separate occurrences; it must not require one new memory per alert.

Review ten (`fable-spec-live-behavior-retry.jsonl`, public result only) checked a real rejected-anchor
replay that repeated identical prompts until its three starts were exhausted. It supported static,
bounded correction feedback without echoing a former candidate, weakening source checks, or
resetting the durable budget. Its clarifications distinguish complete URLs/standalone content
tokens from URL fragments and input metadata, and explain that one unsupported anchor rejects the
whole candidate. Later live runs exposed omitted thread identities and missing same-thread topic
candidates; both are host briefing defects with exact captured-input regressions, not reasons to
force a topic per message or increase the retry budget. Fresh behavioral qualification remains required.

Review eleven (`fable-spec-thread-candidates.jsonl`, public result only) verified original identity,
direct-source scope, root fallback and revocation, then found two bounded-ranking failures: eight
retry keys could displace a thread candidate, and one busy thread could hide another thread's topic.
Both were reproduced with structural cap tests before changing selection. The review also prompted
a thread-aware create recheck and static provider-contract-failure feedback; their tests first showed
an accepted duplicate create and an absent correction respectively. It did not grant blanket approval.

One review suggestion was not adopted: a second retrieval API to fix purported swallowed SQL
exceptions. `Knowledge.context/5` has no exception rescue; raised SQL errors propagate through the
outer `Learning.prepare/2` transaction, and nested rollback cannot commit a new learning attempt.
Initial locked source scope and final dependency authorization already reject lost eligibility.
Do not add a parallel API without a reproducible gap in that boundary.

Review twelve (`fable-spec-board-staff.jsonl`, public result only) found two restart/data-loss
blockers: an unstarted prepared run could bypass its counted-start transition, and one unavailable
input could supersede a whole batch of still-valid originals. It also found that an unavailable
topic has no repair path and that retry must not reopen invalid memberships. These are being
reproduced and fixed before release. The independent security review found evidence/outcome
prose could bypass source revocation in a replacement session; the source-custody contract above
now explicitly includes these projections. The preceding green deterministic gate is not approval
to ship these findings unresolved.

The suggested automatic reset of an unavailable topic on `create` is not adopted. It conflicts
with the no-silent-reset contract. An explicit audited rebuild from currently eligible originals
was approved in review thirteen; retained original history and spent execution budgets must survive it.

The independent maintainer review found the contract-failure feedback test exercised an unused
receipt-ingestion helper, while the actual executor collapsed the provider error into a generic
failure. Correctness must be proven through the live dispatcher/next-prompt path; move useful
receipt and budget invariants onto that path and make its recorder the single live path. Learning schema
construction must also name create/update semantics explicitly, not depend on `oneOf` array order.

Review thirteen (`fable-spec-repair-design.jsonl`, public result only) approved reusing the
existing learner for an explicit rebuild, with target-bound attempt identity, fresh dependencies,
exact scope/version checks and usable no-change retries. It also found an outcome-binding
liveness bug: recomputing a sibling episode's newest outcome invalidates an unchanged frozen
reference when later records or diagnostics arrive. Bind the named turn/event and each selected
record instead, keeping all source-derived prose attributable; do not merely ignore arbitrary
blocker text during validation.

Two review suggestions are deliberately corrected. A prior-direct-sources-only picker cannot
repair a topic after every old source is gone; explicitly authorized same-scope selection supplies
the missing recovery without automatic identity reassignment. Old roots alone do not invalidate
all historical warm exposures after rebuild (an earlier revision may predate the bad source),
so current-generation model eligibility is required. The source-count marker added during this
review also distinguishes tracked empty custody from missing/pre-upgrade exposure history.

Review fourteen (`fable-spec-final-repair.jsonl`, public result only) approved the owners it
inspected, subject to the full gate and deployment boundaries. It explicitly did not inspect the
real Continuity summary writer. The parallel security review then reproduced a missing-generation
dependency through actual summary acceptance, compaction and a topic rebuild; passing tests with
structurally seeded compact references had not proven the writer correct. The writer now preserves
the session's compact references alongside raw receipts. Real summary and rollup regressions passed;
the final combined gate remains required.

Fable also identified two retry interactions now regression-tested: a zero-start version conflict
must not impose an execution-failure cooldown on unrelated ordinary learning in that conversation,
and a new source-selection request must retain applicable static contract feedback from its batch's
previous attempt. Both intended failures were reproduced and their 64-test owning suite passed;
neither fix copies the previous model body or grants extra starts. The parallel
UX review reproduced earlier no-change attempts changing their labels when the current batch was
reselected; historical labels now use each attempt's own result, with a neutral label after pruning.
All 21 owning UI tests passed after the three intended failures were reproduced.

Its optional suggestions about avoiding neutral Slack repaints during transient lock contention and
hardening a repeated source-retirement race remain separate follow-ups, not implemented features.
The subsequent source-validation/packing timeouts led to a measured quadratic query regression
and a parameterized source lookup, preserving all validation predicates and limits. The complete
Elixir phase of the full gate then passed 2,793 tests; that result predates the final retry repair below.

Review fifteen (`fable-spec-closure-final.jsonl`, public result only) read the real summary writer,
generation/lifetime tests, validity query, immutable attempt labels, and isolated replay fixtures.
It found no blockers or majors, but identified one additional retry variant: a retired manifest
that never started could hide an older real failure's static correction. Both same-key retry and
new-selection fallback now skip such manifests; a later accepted judgment still clears obsolete
feedback. The two intended failures were reproduced, the success control remained valid, and all
96 owning tests passed. The final `make dev-check` passed 2,796 Elixir tests with zero failures
and 90.35% coverage, including this repair. The required `make check` also passed all three
Go race shards and its vulnerability scan; its earlier Elixir phase passed 2,793 tests before
the final feedback repair. The final deterministic gate reran the same full Elixir checks on
the repaired bytes. Go code and race scripts did not change between those runs.

The other two review suggestions are preventive follow-ups: count future filter work on additional
query-plan node types, and isolate a draft fixture that has no concurrent identity collision today.
Neither changes the current product contract. Fable's scoped approval is not permission to deploy
without the missing final provider-backed qualification or the required runtime readiness proof.
