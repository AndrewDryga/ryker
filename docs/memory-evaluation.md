# Memory evaluation

Memory has two different failure modes. A host can mishandle a valid update, or a model can choose
the wrong subject despite a valid contract. Test those separately. Passing deterministic host
tests does not prove that the learner understands conversations, and replaying a captured answer
does not count as a new model judgment.

## Latest acceptance checkpoint — 2026-09-09

The internal runtime implementation was deployed and verified healthy/ready at
`6a2803866ecb7f04728e4c4ce4724f3500118dc2`. Actual main
backup restore preserved every existing table count; main Coop and the private replay were not
restarted or changed. Learning uses `codex:gpt-5.6-sol/medium@personal`. Each of the three deferred
main batches received exactly one additional bounded start, preserving earlier attempts: two
ended with no change, and one earlier low-value topic remains retained as regression evidence.

Fresh memory qualification on `8d5d6a6` passed: an ordinary request produced no topic; three
messages maintained the same draft-retention topic; auth resolution and later recurrence stayed
distinct and were correctly recalled by a fresh Work question; a source-only rebuild updated the
same topic with a new source generation. Nine model turns completed, one native attempt each.
Reports are under `/private/tmp/responder-memory-qualification-final.8d5d6a6/`.

All nine Work smoke scenarios now have passing observations: seven on `e2cadb0`, then the
concurrent-feedback case repeated and the remaining Rivals/VA1 cases completed on `6a28038`.
The final three-case campaign ran once: seven Work turns plus three judge turns, one native
attempt each. Every session was discarded. Reports and public activity receipts remain under
`/private/tmp/responder-memory-qualification-final.e2cadb0/` and
`/private/tmp/responder-memory-qualification-final.6a28038/`.

Root inspected actual responses, tool results, and the generated PNG, not only judge scores.
Important qualifications:

- The first passing concurrency trace still exposed a real Activity/Custody deadlock and HTTP
  500. Its regression failed on old code; `6a28038` fixes the lock order. The repeat had no deadlock,
  but did recover from one rejected tool preflight using a consumed wait reference.
- Rivals retained one open proposal incorporating both follow-ups, superseding earlier versions.
  The earlier `e2cadb0` missing-workspace observation remains unrun; a pinned read-only companion made
  the final run possible. No repository change was executed or claimed.
- VA1 used four supported historical sources and correctly marked allocation health and deployed
  intent as unknown. Six other source calls were unmatched by the recorded world. This proves
  bounded reporting and fallback monitoring use, not the unvisited service-timeout recovery path.
- In the earlier artifact-delivery qualification, image delivery required two candidate repairs
  and an injected lost-delivery-response retry.
  The actual generated artifact was visually checked; this was recovery, not first-try success.
- The Work lane forces episode routing and uses inert publishers. It does not qualify natural
  Admission decisions, real Slack/GitHub posting, or unattended operations. The fresh memory
  question used automatic briefing selection, not broad cross-channel or noisy-search retrieval.
  Provider costs were not recorded; do not infer dollar totals from these reports.

Final deterministic qualification passed 2,810 Elixir tests with 90.41% coverage and 106
release-isolation tests. The initial full gate found two test-clock assumptions. A test-only repair preserved source times/content, and
the final full Elixir phase passed. The original failed gate remains failed evidence. The exact
committed release also passed archive, backup/restore, restart, and readiness qualification.
Deployment and gate receipts: `/private/tmp/responder-activity-lock-deploy.XQ4UXU/STATUS.md`.

Older checkpoints below preserve their original failures and unrun observations; they are not
retroactively relabelled passes. This checkpoint supersedes their pending deployment/qualification
status only for the specific cases above. Broader longitudinal retrieval quality remains a
separate evaluation, not a reason to add embeddings or another memory runtime without evidence.

## Keep evidence honest

The learning fixtures in `testdata/learning/` contain retained Blitz material:

- `retained-haproxy-lifecycle.json`: original firing and resolved inputs for the same allocation.
- `retained-auth-memory-recurrence.json`: three original auth resident-memory alerts: an initial
  firing, its resolution, and a later firing with a different start time on the same allocation.
  The later occurrence's resolution is deliberately excluded.
- `retained-draft-ai-suggestions-learning.json`: an exact source input and unchanged accepted
  learning result, with source run and digest provenance.
- `retained-draft-keep-thread.json`: the exact three original messages: the retention question,
  an attributed explanation of the prototype, and the later explicit decision to keep it.
  These are source inputs, not expected model answers.
- `recorded-draft-retention-create.json`: the exact accepted public result from isolated live
  `draft_c` generation 2. With the original thread it reproduces a later elliptical reply receiving
  no candidate despite an existing topic. This is host matching evidence, not a new semantic pass.
- `retained-fortnite-manual-correction.json`: the original release notice, a human concern that
  the update appeared stuck, and another human's clarification that the process is manual.
  Later testing and deployment messages are excluded, not supplied as hindsight.
- `retained-great-thanks.json`: an exact acknowledgement, used to test that chatter needs no topic.
- `recorded-no-change-result.json`: the exact accepted public answer to that acknowledgement.
  It tests immutable attempt labels after the batch is retried or reselected; the original
  answer's raw SHA-256 and the retained host canonical-string digest are recorded separately.
- `retained-livebook-briefing-memory.json`: selected historical briefing context, not a complete
  current infrastructure observation or a new-model result.
- `livebook-intended-zero/`: original Lab inputs and public responses, public native read
  receipts, and three exact Terraform files unchanged between the pre-report and later inspected
  Emisar commits. Two historical read outputs are explicitly withheld/truncated. The later
  corrected answer is evidence only, never input to the new model observation.
- `retained-blitz-release-knowledge.json`: a retained release-topic title, summary, and tags used
  for presentation tests; it does not contain original source inputs or a learning-run receipt.
- `retained-auth-wal-context-packing.json`: retained context used for packing regressions.
- `retained-output-contract-failure.json`: all exact rejected public bodies and corrections from
  an exhausted learning run. Preserve their bytes and digests, including malformed JSON.

The current `action`/`anchors` learning protocol differs from older captured results. Deterministic
host tests may explicitly project an old recorded subject into the new contract, but must label
that transformation as a host-contract adapter. Never overwrite the captured body or present an
adapted fixture as proof that a real model produced the new fields. Structural expansion for
cardinality, concurrency, or privacy tests is also host setup, not a harvested model decision.

Only public responses, progress, tool events, receipts, and original source inputs belong in these
fixtures. Do not copy provider-private reasoning. Source time remains historical; if a host test
rebases execution time to keep a wait or retention horizon valid, record that separately.

## Offline gates

Use an isolated PostgreSQL test database for owning memory tests:

```console
RESPONDER_TEST_ISOLATED=1 scripts/elixir-test.sh test/responder/learning test/responder/state/learning_test.exs test/responder/state/learning_failure_test.exs test/responder/state/knowledge_concurrency_test.exs test/responder/state/knowledge_sources_test.exs test/responder/state/learning_work_boundary_test.exs test/responder/state/knowledge_snapshot_capacity_test.exs test/responder/state_tools/memory_search_test.exs
RESPONDER_TEST_ISOLATED=1 scripts/elixir-test.sh test/responder/evals test/responder/capability_contract_test.exs
```

These prove durable ownership, exact versions, bounded starts, source revocation and capacity,
current-turn disclosure boundaries, and search pagination. They do not call a model. Run the
narrowest named test while iterating rather than repeatedly invoking the entire list.

Source-capacity tests also bound actual PostgreSQL query work, including repeated materialized
rows and rejected join pairs. Counting only physical index scans missed a quadratic validity
check: the covered packing/capacity pair reproduced about 50 million rejected pairs for 10,000
sources. The strengthened test failed before the parameterized observation lookup, then both
cases passed with about 20,000 scan operations and no rejected join pairs. The measured equality
query fell from 2,214 ms to 10 ms. Those timings describe this reproduction, not a latency promise.
The bad plan depended on stale statistics and preceding table/index history; it did not reproduce
in a fresh singleton run. Narrow coverage runs are not whole-repository coverage qualification.

Parallel security and retention fixtures use isolated custody identities. Reusing captured Inbox
IDs and Slack lock scopes across sandbox transactions caused artificial deadlocks between
source-first and episode-first setup. The regression reproduces that collision and verifies that
the isolated fixtures preserve original message bodies, event times, and model prose. Only host
source references are explicitly rebound. Do not disable parallelism or change production locks
to accommodate shared fixture identities.

The world scenarios pin the production Responder tool schemas separately from their recorded
external tool world. When a host tool schema changes, refresh only that generated portion:

```console
MIX_ENV=test scripts/elixir-mix.sh run --no-start scripts/refresh-world-tool-catalogs.exs
RESPONDER_TEST_ISOLATED=1 scripts/elixir-test.sh test/responder/evals/world_case_test.exs test/responder/evals/world_tools_test.exs
```

The script calls the actual registered `StateTools.Tools.list` with the world lane's capabilities.
It leaves external tool definitions, source data, model results, scenario expectations, and shared
catalog references unchanged. The existing all-scenario snapshot test fails on schema drift.
Refreshing a catalog is not a model evaluation and invalidates any claim that an older result
qualified the exact new tool contract.

Admission and Work pack commands rebuild prompts from current code without calling a model:

```console
MIX_ENV=test scripts/elixir-mix.sh responder.eval admission-pack
MIX_ENV=test scripts/elixir-mix.sh responder.eval work-pack
MIX_ENV=test scripts/elixir-mix.sh responder.eval world-pack
```

Admission fixtures already use the six routing fields; the pack uses the current strict schema.
The narrow Work corpus names tools but does not contain embedded search schemas. Do not manufacture
schema migrations inside those captured input bodies or add a permissive legacy admission parser.

## Real-model acceptance

Existing credentialed commands are:

```console
MIX_ENV=test scripts/elixir-mix.sh responder.eval admission --config /absolute/responder-elixir-eval.yaml
MIX_ENV=test scripts/elixir-mix.sh responder.eval work --config /absolute/responder-elixir-eval.yaml
make eval-world-smoke CONFIG=/absolute/responder-elixir-eval.yaml
make eval-world CONFIG=/absolute/responder-elixir-eval.yaml
```

Use dedicated evaluation policies, isolated databases, inert delivery, and the same recorded world
for candidate and baseline. No production Slack/GitHub writes or infrastructure mutations are
needed. The full schema/operation-list gate is required for a changed contract; the wording-only
smoke exception is not sufficient here.

The existing admission/final-result cases and tool-world scenarios do not by themselves exercise
longitudinal background learning. The dedicated lane drives the actual durable dispatcher, current
prompt/schema, source validation, topic application, and proof-bearing cleanup:

```console
MIX_ENV=test PGDATABASE=responder_learning_eval_haproxy scripts/elixir-mix.sh responder.learning_eval --database responder_learning_eval_haproxy --socket /absolute/evaluation-coop.sock --scratch /absolute/canonical-empty-git-repository --policy learning-eval-only --policy-digest POLICY_SHA256 --results /absolute/new-learning-report.json --scenario haproxy
```

Create and migrate the named disposable database first; configure its PostgreSQL connection with
the normal `PGHOST`, `PGPORT`, `PGUSER`, and `PGPASSWORD` variables. Do not set
`RESPONDER_ELIXIR_CONFIG` or start the Responder application. The task starts only Repo and Finch,
and refuses a nonempty database, a configured background runtime, or an existing report file.
The scratch repository must have an empty committed tree and no other files; its canonical path
and exact HEAD are checked. The public Coop session must report that HEAD as `base_commit`, the
configured policy digest, read-only repository access, no project environment/MCP, and no companions.
Policy names are not evidence of those properties: qualify the actual policy separately.
Also require an absent Responder binding digest. These checks prove the restricted project
integration boundary, not disabled provider-native tools, writable scratch/output, or network
egress. The learner's no-action instruction is not an enforced no-tools sandbox; do not report
the evaluation as proof of that stronger boundary.

`--scenario haproxy` (the default) feeds the firing and resolved inputs in two separate batches.
`--scenario auth-memory-recurrence` feeds the three recorded auth memory-pressure alerts. The
later occurrence must advance knowledge, either by updating a maintained service topic or by
creating a distinct occurrence topic. A structural pass does not establish correct status:
semantic review must verify that the earlier resolution is not carried forward as proof that
the later occurrence recovered. The optional authored probe asks for the latest recorded state.
`--scenario draft-keep` feeds the three harvested messages in order, using a separate empty database.
`--scenario unoffered-draft-match` freezes the first draft question with no offered topic, then
uses an explicitly structural concurrent writer to apply the exact captured creation from
`recorded-draft-retention-create.json`. Both evaluated provider responses are fresh model results:
the first must encounter the production match correction, and a later attempt must receive the
offered topic and finish within the same three-start lifetime budget. Updating that topic or
making no redundant change are valid; a distinct creation requires independent semantic review.
The report identifies the frozen request, captured writer, offered version, correction, and cleanup.
This is a controlled matching race, not a natural-discovery claim; `--probe` is not applicable.

### Recorded acceptance on September 8, 2026

The first complete candidate tool-world campaign finished 53 of 57 observations successfully,
with four failures and none unrun. Its aggregate gate **failed**: three Grafana observations
missed a required source result, and one GitHub observation missed its quality rubric. Preserve
those failures when qualifying corrections. The Grafana fixture did not supply the environment
required by its fabricated monitoring cassette; its separate, explicitly authored endpoint-scope
correction is documented beside the scenario without changing original source bodies or rubric.
The GitHub clarification also exposed a Rivals regression: the model treated an absent primary
reference as no target despite a relevant supplied companion. Its captured repository-context
fixture protects explicit target guidance; fresh model evaluations, not that text assertion,
must qualify whether the model now uses it correctly.

A separate 18-observation companion-wording campaign **passed all 18**, without replacing
those 57 observations: three Rivals, three GitHub, nine owning smoke cases, and three explicitly
corrected Grafana-world cases. Actual Rivals responses kept one relevant companion proposal
without claiming execution; GitHub responses requested the missing matching target without
repeating invalid task calls. All three corrected Grafana trajectories retrieved the exact
historical firing and resolution results for the same cycle, preserved the original source
times, and did not claim present-day health. All 18 episode-owned native Work sessions were
independently checked as discarded after completion.

That frozen campaign used runtime Rivals tool-catalog digest
`ae34adca36711fec319c5615c4130a971548b2a147c4a5bb412da5a6611bb7fb`; the scenario-local corrected
Grafana catalog was `90e72568f9041e7f0fb2be382d0afaddd9ed02263d85f874b4575892d5ea47ab`.
Later review corrected repository guidance from storage-only `context.*` paths to the actual
model-visible `work.*` projection. The 18 passes qualify the frozen wording, not that subsequent
wording correction or later security/recovery changes; their final owning smoke remains separate.

The dedicated real-model recurrence run used the exact auth fixture SHA256
`38c95395c9f0731346176e77080c5ae2e206f5af5e8ad0852b6db89ac656d836`. It maintained one topic through
versions 1→2→3, spent one start per input, and discarded all three learning sessions and the Work
probe session through normal custody. Independent manual review of both the topic and delivered
answer confirmed separate first-firing, first-resolution, and later-firing chronology. Neither
claimed that the earlier resolution recovered the later occurrence or proved present health.
This qualifies forced-route, same-conversation automatic recall, not cross-channel retrieval,
natural admission routing, or original-source expansion.

The controlled matching run froze a real first request with no offered topic, then structurally
applied the exact recorded create fixture SHA256
`e4db5cde8e5acaa421a3e3e5e38956a94f7330451d2b6c43d5bdc51e6aa4333f`. Its first actual model create
received `learning_match_required`; the second actual model judgment updated the newly offered
version-1 topic to version 2. One batch spent two of its three starts, with cancellation proof
before replacement and both sessions discarded. Manual review confirmed that the update kept the
question unresolved and did not infer deletion approval. It repeated existing content, so this
does not prove avoidance of redundant revisions; choosing no change is separately host-tested.

Both used an isolated read-only evaluation policy, no live publishers, retained original input
times, and explicit synthetic replay/concurrency setup. Structural checks and semantic review are
separate evidence; these two passes are not a claim that the full feature set is qualified.

The final draft-retention and Fortnite-correction observations each processed three original
inputs, used one learning start per input, maintained one topic through three revisions, and
discarded their three learning sessions and held-out Work session. Independent manual review
confirmed the attributed keep-draft decision and tentative explanation, and the manual-release
correction without inventing later deployment or testing. Earlier failed observations remain in
the audit record; these results qualify chronological, same-conversation learning and forced-route
automatic recall, not natural routing, cross-channel sharing, or unattended operational action.

The historical Livebook check ran one actual Work turn against the isolated three-file checkout.
The model read the repository and concluded that zero instances can be intentional, without
claiming that the historical workspace actually had `livebook_running=false` or that current
health was verified. Its first candidate was accepted and inertly delivered, and the native
session was discarded. This is an independently reviewed **manual semantic pass**; the automated
judge was not run. Two unauthorized goal-planning calls used native checkout name `primary`
where the host had no repository reference, followed by an invalid goal update. Those workflow
failures remain, as does a potentially low-value finding about unknown deployment intent.

A separate one-turn deletion test disclosed the exact retained HAProxy input to an actual native
session, with both frozen submission and source-exposure receipt. After remote completion but
before host acceptance, an explicitly structural deletion went through normal `Inbox.record`:
source revision `7154515056992116` became `7154515056992117`. The unchanged public model result
contained the source's allocation and `CONSTRAINT_MEMCG`, but normal acceptance rejected
`work_knowledge_context_stale`; no result, acceptance time, delivery reference, or publisher call
was created. The only actual submit preceded deletion. Normal cleanup discarded generation 1;
an operator retry reached the fresh generation-2 creation boundary, where the recorder stopped
before creation or another submit. The never-bound generation also received cleanup proof.
All eight structural checks passed and were independently reviewed. This qualifies the deletion
acceptance/session fence, **not** completed recovery, membership changes, expiry, future-input
isolation, provider forgetting, or live Slack delivery.

Two later one-turn observations separately exercised a source channel becoming private and
natural source expiry. The privacy case used explicitly structural public memberships and a
second public destination, then changed the source channel to private through the normal
membership owner after actual completion. The expiry case configured a disposable 120-second
memory lifetime before ingestion, preserved the actual retention receipt, and waited until
both host and database clocks passed its deadline. Neither source bodies nor historical source
times were changed. Each had one actual pre-boundary submit; normal acceptance rejected the
completed response, no delivery was created, and native/never-bound sessions were discarded.
Each passed eight structural checks. They qualify acceptance and session fences, not every
downstream copy: the subsequent security review found that an evidence ledger copy could reach
a replacement prompt without the original source check. The subsequent source-accounting repair
now has deterministic replacement-session and acceptance regressions; these earlier live
observations did not test that repair. Privacy here means loss of public cross-channel visibility, not a live membership
receipt, channel departure, or proof that the provider forgot text. Expiry does not prove
physical deletion of every retained copy.

The queued-input observation used the original draft question and the later original keep
decision. Normal Admission attached the later source after the earlier Work claim, and the
owning Knowledge API created an explicitly structural topic containing its verbatim text.
The actual earlier prompt and session roots excluded both queued raw source and derived topic;
the single actual answer left the decision unestablished. Its authored question inherited an
August 30 template timestamp, before the September 2 sources, and the answer noticed that.
Therefore prompt/root exclusion is proven, but the model's reason for not using the later
decision is not independently isolated as a natural chronological-quality result. The first
report passed seven checks and failed cleanup: the queued follow-up materialized during the
cleanup claim and hit the private no-new-session guard. Preserve that failed report. A separate
normal cancellation/retention receipt subsequently proved the unsubmitted follow-up absent
and discarded both sessions, with no new create or model submit. An earlier missing-history-window
preflight was unrun with zero remote work and normal never-bound cleanup.

The controlled memory-tool probe also passed its eight checks: actual source-dated search pages
contained 1, 1, then 0 results. Both original Slack-source reads were denied because the captured
world lacked a channel-authorization receipt. The answer correctly left original wording
unverified. This proves bounded pagination and honest denial, not successful original-source
expansion or natural discovery of an older decision amid noisy memory kinds.

A separate corrected expansion observation subsequently passed all eight checks with an
explicitly copied, digest-verified HAProxy fixture. The model made three source-dated search
calls with limit 1, reached the two distinct originals and exhaustion, then successfully called
`read_slack_source` for both. Each read rechecked explicitly structural current channel metadata
and returned the exact recorded body. Independent manual review confirmed correct event/message
chronology, the distinction between MEMCG and host RAM, and historical resolution versus current
health. Normal cleanup completed. This qualifies controlled same-channel pagination and original
expansion, not historical/live Slack authorization, natural discovery, or cross-channel retrieval.
Its earlier missing-fixture preflight stopped before remote work and is separately preserved.

`--scenario fortnite-correction` feeds the release notice, concern, and human correction in order.
The release notice may produce no memory or one topic; the human concern must then create or
update a topic, and the clarification must update that same topic rather than add a conflicting one.
With `--probe`, the later authored question asks whether it was stuck and what the team clarified.
Review must distinguish the initial concern from the attributed correction without inferring that
the update was subsequently deployed or tested; neither appears in the selected inputs.
`--scenario chatter` feeds the retained acknowledgement and requires no topic or revision; it does
not support `--probe`, because there should be no learned subject to retrieve.
Each batch must settle before the next source is imported. The checks require one stable topic ID
and successive revisions; they do not grade the factual meaning of the summary. Source bodies,
identities, and event times remain unchanged. The report explicitly labels silent shadow admission,
removed transport capabilities, replacement evaluation authority, and current ingestion receipts.
By default no episode or response is created. No production publisher is ever configured.

Add `--probe` to ask one authored held-out question after every learning batch has settled.
It uses normal Admission and Work custody, the production briefing and validator, and the
existing inert Slack evaluation publisher. The question is not harvested and is never fed to
the learning dispatcher. Its episode is deliberately live-mode: production shadow Work forbids
answers. This does not give it a public publisher, infrastructure tools, or write authority.
The report retains the exact Work submission, knowledge exposures, candidate, validation,
inert receipt and proof-bearing cleanup. Its structural check requires recalled knowledge and
a settled answer; factual accuracy still needs review against the harvested chronology.
This qualifies only automatic recall in the same conversation, not explicit `search_memory`
invocation, cross-channel recall, model routing, or delivery to a real Slack workspace.

The new private report contains public frozen prompts, exact candidate bodies (including malformed
ones), producer and validation identities, topic revisions, available provider usage/timestamps,
and cleanup receipts. A failed step stops later inputs and lists them as unrun. All custody remains
in PostgreSQL; never drop a failed evaluation database while remote work lacks stop proof.
Cleanup uses the normal retention dispatcher and never overrides dirty-work or unresolved-work guards.

Offline `learning_runner_test.exs` uses explicitly constructed fake-provider contract outputs to test
host plumbing only. It is not live-model evidence. Even a live structural pass requires semantic
review, and held-out questions must still run through ordinary Work recall. Until that evidence is
recorded, those behaviors remain unqualified even if every offline pack compiles.

Required harvested cases:

| Case | What must be demonstrated |
|---|---|
| Silent decision | An unmentioned decision to keep `draft-ai-suggestions` is retained without a reply and recovered in a later relevant question. |
| Intended zero scale | The recorded Livebook decision/code intent prevents an unsupported outage claim; later infrastructure status still needs fresh evidence. |
| One occurrence, several updates | Firing and resolved reports for the same HAProxy allocation update one subject, preserving uncertainty about recovery. |
| A later recurrence | Another occurrence or allocation is not silently merged into the previous incident lifecycle merely because it uses the same service. |
| Correction | A later attributable human correction changes current understanding without erasing the older claim's history. |
| No durable change | Chatter and duplicate boilerplate create no new topic and do not force a canned response. |
| Unoffered existing match | A proposed create encounters an existing relevant topic, receives bounded alternatives, and either updates its exact version or justifiably remains distinct. |
| Navigable recall | An older relevant decision remains reachable beyond the first page and across noisy kinds; the model follows an original source when needed. |
| Privacy and expiry | Newly private, withdrawn, expired, and future queued source content never improves the answer by leaking into memory or a warm session. |

### Remaining acceptance boundary at this checkpoint

This is the historical September 8 checkpoint; see the dated latest checkpoint above for follow-up results.

These are still required, not implied by the positive observations above:

- The corrective companion campaign completed 18/18, separately from the original failed
  57-observation campaign. The final nine-case Work smoke has a frozen runtime/corpus and green
  read-only policy/catalog preflight, but all nine observations remain **UNRUN**: the same provider
  profile hit its usage limit in the final rebuild check. Do not relabel the earlier 18 passes as
  qualification of later runtime bytes or change accounts to conceal the missing gate. That
  preflight also predates the final summary-generation, retry, and validity-query repairs: freeze
  the final committed runtime in a new evaluation directory and repeat preflight before resuming.
- The evidence-ledger revocation gap now has deterministic replacement-session and acceptance
  regressions, including inherited summary generations and missing/partial exposure custody.
  This does not qualify untracked native/platform reads or linearizable Slack revocation. Keep
  the queued-input observation's artificial question-time limitation separate from its exact
  prompt/root evidence.
- Distinguish controlled successful source expansion and authored pagination instructions from
  finding an older decision among noisy kinds without being told its answer; the latter remains
  a separate retrieval-quality qualification, not implied by the tool probe.
- Qualify duplicate boilerplate as no durable change. The single retained acknowledgement proves
  the narrower chatter case, not every repeated alert or redundant update.
- Independent reviews and deterministic gates are complete: the final `make dev-check` passed
  2,796 Elixir tests with zero failures and 90.35% coverage. An earlier 2,793-test phase preceded
  the final retry-feedback repair, which the final deterministic gate covers.
  Exact release qualification, deployment/readiness, and active background-learning receipts
  remain required. Model observations are not evidence that new code is running in the application.

### Final source-only relearning observation

One actual turn was submitted for an explicit rebuild using the exact retained resolved HAProxy
message. The earlier firing message and a captured historical learning result seeded only the
structurally unavailable old topic. Independent inspection verified that the frozen new prompt
contained the selected resolved original, an opaque target, and no old topic prose or candidates.
The provider returned a usage-limit failure with zero input/output tokens and no candidate. The
test-only Coop process also disappeared before the host collected its terminal receipt; its exit
cause is unknown. This is a failed availability observation, **not** a model-quality pass or a
successful topic rebuild. No second model submission was made.

The original failed report is retained at
`/private/tmp/responder-memory-rebuild.G1t34N/observation-1788898377381.json`. Separate cleanup
succeeded: the host recorded the actual failed-turn receipt, normal retention discarded the
session, and the task-owned temporary Coop process stopped. No create, submit, or validation call
was repeated; the frozen prompt and one-of-three start budget were preserved. To avoid waiting
an hour, only this disposable batch's reconciliation due time was explicitly moved forward.
That structural adjustment qualifies cleanup, not the one-hour timer or successful learning.
The separate receipt is
`/private/tmp/responder-memory-rebuild.G1t34N/cleanup-recovery-1788898879194.json`; it cannot turn
the failed observation into a pass. Main and replay processes and data were untouched.
Application to the same topic/new generation is proven by deterministic host tests only until an
available provider completes this contract. The final frozen Work smoke preflight and unrun list
are retained under `/private/tmp/responder-memory-final-smoke.EuTVdw/`.

Embeddings, a graph database, a model-visible omission index, automatic procedure promotion, and
new cross-transport sharing authorization are explicitly outside this implementation spec. They
must not become new acceptance prerequisites or be reported as implemented by these tests.

Hold out complete conversations or incident families and later time windows where practical.
Keep later messages out of earlier prompts. Judge the answer against source-supported meaning,
not a preferred exact summary or a required number of memories. Record factual correctness,
false merges, duplicate subjects, missed corrections, source attribution, unnecessary retrieval,
context bytes, latency, and cost. Separate policy/provider availability failures from model-quality
failures. Missing cases are `UNRUN`, not implicit passes.

Finally qualify the actual learning policy: inspect the read-only empty scratch checkout, absence
of project environment/MCP/companions, exact fleet ownership, and close/plan/discard receipts.
Deployment and readiness must name the exact running commit separately from all of these results.

## One-off request selectivity regression

The first recovered internal batch on `55193f4` completed successfully but saved an ordinary
read-only acceptance-check request as a topic. The result merely restated its steps and temporary
constraints as an unresolved intention. That is a learning-selection failure, not malformed
output or a host application failure. The exact source, submitted prompt and unwanted result
are retained in `testdata/learning/retained-one-off-acceptance-request.json`, with the stored
prompt/result digests and originating run ID.

`mix responder.learning_eval --scenario one-off-request` runs only that harvested input through
the current learner and requires no topic update. The captured answer is used solely to prove
that the offline evaluator rejects the old behavior; it is never supplied to the live learner.
This scenario has no recall probe because a successful run intentionally learns nothing.
Fresh model qualification must also retain meaningful decisions (such as the `draft-keep`
conversation), so fixing selectivity cannot silently become a blanket filter on requests.

## Distinguish planning from operational authority in evaluations

The Airflow Work qualification on `8d5d6a6` exposed an evaluator false positive: a read-only
goal labelled `schedule` was rejected even though it only described a bounded observation
step. Its two state updates then failed because the evaluator had rejected their parent.
The run created no recurring schedules; the separately validated `wait_for` owned the wait.

`plan_goal` creates planning records, not automations. The evaluator may accept read-only
check and schedule planning within the disclosed repository scope without permitting a
`schedule_offer`, standing assignment, writable repository, or governed operational action.
Keep positive captured-record coverage alongside those negative authority checks. Preserve
the original failed report; correcting an evaluator does not retroactively turn an unrun
quality judge or the remaining scenarios into passes.
