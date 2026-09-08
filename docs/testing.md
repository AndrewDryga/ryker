# Testing Responder

Responder uses four test layers plus a statistical model-release gate. They intentionally prove
different things; no single green command is presented as proof of the whole product.

## Elixir replacement gates

The replacement runtime has its own PostgreSQL-backed deterministic gate. Run the owning test while
iterating and the complete Elixir gate before treating the replacement slice as ready:

```bash
scripts/elixir-test.sh test/responder/evals
make elixir-check
```

The model corpora can also be compiled without credentials or executed through the configured local
Coop daemon:

```bash
MIX_ENV=test mix responder.eval admission-pack
MIX_ENV=test mix responder.eval work-pack
MIX_ENV=test mix responder.eval world-pack
MIX_ENV=test mix responder.eval admission --config /absolute/responder-elixir.yaml
MIX_ENV=test mix responder.eval work --config /absolute/responder-elixir.yaml
make eval-world-smoke CONFIG=/absolute/responder-elixir-eval.yaml
make eval-world CONFIG=/absolute/responder-elixir-eval.yaml
```

Admission evals score lifecycle routing, relation selection, and the abstract Work class. Work evals use the production prompt, final
schema, and host validator, including same-turn semantic correction and candidate-attempt identity.
The YAML must declare a dedicated `model_evals.socket`, `model_evals.no_tools_policy`, and
`model_evals.world_policy`; the full paired gate also requires
`model_evals.world_baseline_policy`. Every name and digest must be distinct from
the admission policy, every repository policy, and the other eval policies. The admission and narrow Work commands use the isolated
read-only/no-tools eval policy. They close and discard only a
Coop-proven clean workspace; a dirty or ambiguous workspace is retained and fails the run. These
commands do not publish Slack or GitHub messages and do not mutate Emisar.

`world-pack` compiles the single versioned scenario bundles and their exact tool catalogs without a
model. `eval-world-smoke` runs eight representative scenarios once at a 100% floor.
`eval-world` runs the complete corpus three times for both the candidate and baseline policies against
the exact same deterministic worlds. It requires at least 90% aggregate success, at least two of three
passes per case, no more than 10% paired baseline regressions, and zero hard-invariant, execution,
cleanup, or `UNRUN` candidate failures. Hard-invariant counts include only scenario assertions;
execution and cleanup errors are reported separately and always block qualification.
The runner stops at the first failed or unrun observation to preserve its database. Remaining
repeats and lanes are explicitly reported as unrun, without further model calls. This includes
baseline failures: run the remaining cases in a new isolated invocation after inspection.
Both are interactive product lanes: they use the real episode kernel, Work executor,
lease-scoped Responder state tools, semantic repair, and an inert evaluation delivery adapter. Only
external source systems are served by the checked-in deterministic cassette. A second isolated Coop
session judges the human-language rubric after all hard and trajectory checks pass; an unrun rubric
is never counted as a pass. The eval socket cannot equal the production Coop socket. Responder fetches
every created eval session before submission and requires Coop's public `repository_read_only` bit;
the dedicated daemon must have no production environment, credentials, network mutation tools, or
project MCP configuration. A distinct policy name alone is not an authority boundary. The database
name is mandatory and the runner refuses any database with
pre-existing episodes. The world policy must expose only disposable eval repositories and the
fabricated tool world through a TLS gateway reachable by the
disposable Coop sandbox; never point this command at a production database or platform adapter.
Each invocation creates its own database. A successful run drops it; a failed run preserves and names
it for custody inspection. Detailed reports are atomically written mode `0600` and include every
repeat, lane, runtime identity, threshold, and paired verdict.

Scheduled `wait_wakeup` checkpoints are bounded opportunities, not required model
turns. Once the preceding accepted turn has settled delivery and its episode is
complete, remaining checkpoints appear in `runtime.skipped_checkpoints` with the
original scenario index and timestamp, not as fabricated inputs or executions.
Noncomplete episodes still require the exact open wait and active subscription.
Scenario source bodies and cassette timestamps remain unchanged. Replayed inputs
label their shifted timestamp as ingress time and include `world_replay_clock`
metadata with the original scenario/source date and the separate simulated host
receipt date. The model and judge both receive that distinction; a historical
apply must not become today's deployment merely because a replay ran today.
Timers still use the exact persisted due time, and source-event continuations
still must occur after the live wait began. Passing those mechanics does not
qualify present-day health or decide whether an inconclusive completion was
sufficiently persistent.

The world matrix's Terraform `reconnect` credit is tied to a harvested positive
Slack-source continuation that actually reaches an injected second-turn submit
response loss. The host regression requires one session, two remote submits,
exact operation-journal reconciliation, accepted validation, and settled inert
delivery. The older invalid-matcher sequence is preserved separately as a
negative test: it cannot reach that fault and earns no credit. This is controlled
host fault injection, not a claim that a real network reconnect was observed in
the harvested model run. Loading a scenario alone is not execution evidence.

`make eval-host-replay` runs the deterministic side of those same scenario bundles. The bundle owns
the recorded tool calls, invalid candidates, semantic repairs, and final candidates, so the replay
cannot turn green by hard-coding a friendlier model path in a separate test callback. It uses fake
Coop and inert delivery only; no credentialed model or external platform is contacted.

The legacy Go gates below remain relevant until cutover, but they are not required merely to prove an
Elixir-only edit during iteration.

Passing these deterministic and model gates is necessary but does not activate the replacement. The
separate [Elixir replacement cutover runbook](elixir-cutover.md) requires isolated platform acceptance,
a sealed one-shot live-state import, queue verification, and a bounded rollback decision before the
new runtime owns production input.

## Tests run against a real database

Parallel PostgreSQL tests must use suite-owned conversation/workspace identities. Sandbox rollback
does not release transaction-scoped advisory locks until the test ends: unrelated tests using
`slack:T123:C456` can block each other even though their rows are isolated. Publication fixtures
derive a destination from their unique suffix; transport integration tests pass their configured
`conversation_ref` explicitly. Do not increase production lock timeouts to hide fixture collisions.

`internal/service` and `internal/httpapi` take `*store.Store` directly rather than an interface,
so every service test opens a real SQLite database in a temporary directory. That is deliberate.

The store is where most of Responder's correctness lives — lease fencing, idempotency keys,
conflict detection, retention, migrations — and those are properties of SQL and its constraints,
not of Go code. A mock store would assert that we called the methods we expected to call, which is
the one thing we already know. Testing through the real schema is what catches a broken unique
index, a migration that drops a column something still reads, or a lease that two workers can hold.

The cost is runtime, and it is currently small: the service suite runs in about 3 seconds and the
store suite in about 2. Collapsing the migration chain into a baseline was what made that true —
each test database used to replay forty migrations.

**Revisit this if** the service suite passes roughly 30 seconds, or a genuine unit of pure logic
cannot be reached without constructing a database. The first is a real cost; the second usually
means the logic belongs in its own package instead — `internal/recall`, `internal/decision` and
`internal/provider` were all extracted for exactly that reason and are tested with no database at
all. Introducing a mock store to avoid an extraction is trading a real signal for a fake one.

## Fast customer check

Run this while changing Slack behavior, incident workflow, memory, or response contracts:

```bash
make customer-check
```

It runs the Go suite, the named end-to-end customer journeys, and the redacted response-contract
replay with fake Slack, Coop, Emisar, and GitHub boundaries. It does not use
credentials, call a model, create Slack channels, publish a pull request, or touch infrastructure.

Run only the end-to-end customer journeys while iterating on a workflow:

```bash
make product-e2e
```

These journeys exercise the service through admitted Slack inputs and durable queues rather than
calling individual renderers directly. They cover the reviewed draft-PR boundary, scoped behavior
controls, setup that follows an operator between channel and thread, cancellation without partial
configuration, incident-directory pagination, and explicit cleanup of retained task work.

The corpus in `testdata/eval/golden.jsonl` covers:

- silence during ambient human conversation, lightweight reaction decisions, and routine recovery
  notifications;
- evidence-backed health answers that reconcile repository and live Emisar state;
- human incident offers versus automatic incidents for credible monitoring-app alerts;
- engineering-task, operational-memory, preference, and standing-rule confirmation offers;
- addressed follow-ups and Terraform standing-rule responses;
- prompt-like text in untrusted app payloads;
- authoritative Emisar approval holds without false success claims;
- unknown coverage, no-change task conclusions, response bounds, and forbidden overclaims.

Add a redacted case whenever shadow evaluation or a customer report exposes a distinct decision
failure. Keep cases about observable behavior, not model phrasing.

## Real model evaluation

Run this after changing prompts, model configuration, MCP tools, or the repository policy:

```bash
make eval CONFIG=../emisar/.responder/responder.yaml
responder eval --config ../emisar/.responder/responder.yaml --json
```

`responder eval` calls the configured real model for every case in
`testdata/eval/live.jsonl`. It uses the same watch or incident prompt builders, repository binding,
Coop policy, model credentials, MCP configuration, parsers, and behavioral scorer as production.
Cases run sequentially in isolated Coop sessions. After each case, Responder closes the session,
asks Coop for a discard plan without accepting dirty or unmerged work, and discards only a proven
clean workspace. A dirty workspace or failed cleanup fails the case and retains the session for
inspection.

Each model case has a ten-minute default ceiling, independent from the short Coop HTTP request
timeout. Use `--case-timeout` for a tighter diagnostic run; per-case latency assertions in the
corpus still fail slow behavior even when the transport ceiling is larger.

The command attaches to an already-running managed Coop when available, or supervises a temporary
one. It never sends Slack messages, creates Responder database records, or grants approvals. The
model and tools can still incur provider cost and inspect the configured repository and live
read-only systems, so use a non-mutating Coop policy and explicit test credentials.

The live corpus covers ordinary decisions plus conversational addressee and interruption scoring,
lightweight reactions, open-loop situation continuity, adversarial context ordering, alert recovery,
prompt injection, operator authorization, credential handling, incident admission latency,
host-valid evidence enums and freshness, confirmed preferences, and confirmed standing-rule
execution. Assertions are applied after the same host sanitization and typed offer validation used
for Slack, so evidence or controls that production would discard cannot make a case pass.

Use a name or tag filter for focused iteration, repeat high-risk cases to sample model variance, and
write private sanitized results for diagnosis:

```bash
responder eval --config ../emisar/.responder/responder.yaml \
  --case security --repeat 2 --results /tmp/responder-security-eval.json
```

Each result includes the sanitized raw model response and case duration. The results file is
written with mode `0600`. Latency budgets, required evidence sources, fresh observation counts,
coverage layers, forbidden claims, governed offers, pending approvals, and proposal counts are
scored as behavioral contracts rather than exact answer wording. Alert-rule cases can additionally
require a typed `alert_assessment`, verdict, immediate action, and long-term solution. Pair those
assertions with repository and fresh operational evidence requirements so a fluent symptom summary
cannot pass as an investigation.

### Deterministic episode replay

Use real-model episode replay for reproducible, multi-step operational behavior without depending
on today's production state:

```bash
make eval-episode-replay CONFIG=../emisar/.responder/responder.yaml
```

Cases in `testdata/eval/episode-replay/<deployment>.jsonl` contain an ordered, sanitized episode
timeline and sanitized recorded tool results. Responder still calls the configured real model
through Coop and
uses the production prompt, parser, typed result operations, Slack renderer, and behavioral scorer.
The replay prompt forbids live tool calls and makes the recording the complete evidence boundary.
Every case must include both event and tool-result fixtures; unsanitized, duplicate, unordered, or
malformed fixtures are rejected before a model session starts.

This differs from `--replay`: checked-output replay calls no model, while episode replay tests how
the real model reasons over a stable work episode. Recordings should contain atomic source results,
timestamps, contradictions, and terminal events rather than copied transcripts or secrets.

One corpus per deployment, replayed against that deployment's config. They cannot be merged: a
fixture that names a repository needs the config that has it, and no single `CONFIG` could reach a
pass rate of 1 across both. `DEPLOYMENT` selects the corpus and must match the config passed in.

### Promoted corrections

When the host corrects a model result, the correction is queued as a fixture candidate. An operator
keeps or discards each one in App Home or the control plane, and the kept ones become replay
fixtures in `testdata/eval/regressions.jsonl`.

Keeping one is the decision; copying it into the corpus is not, and the copying is what stopped
happening — the pipeline produced three fixtures in its life because `make promote-corrections` had
to be remembered after every review. So the maintenance lane drains kept corrections itself, at most
`limits.max_auto_promoted_fixtures_per_week` (default 5), into whichever configured repository
already contains the corpus. Nothing is promoted before the corpus has been re-parsed with the new
fixture in place; one that would not decode, or whose name is already taken, is held back instead
and requires operator review rather than being retried. This fixture-candidate
curation workflow belongs to the Go tooling; the current Elixir control plane
has no keep/discard queue. Episode timelines expose retained response checks for
inspection, not fixture promotion. `make promote-corrections` still exists in
the Go tooling and does the same thing on demand, with the
credentialed gate on both sides of it.

The human's remaining job is demotion: read the diff the drain leaves in the checkout, and revert
what should not have been kept. Replay the corpus with:

```bash
make eval-regressions CONFIG=../emisar/.responder/responder.yaml
```

**This is the gate on a promoted correction.** Nothing offline can be. `make dev-check` proves a
promoted case decodes, has a unique name, names a real capability from section 24, and does not
duplicate an episode already in the corpus — every shape failure, and none of the behavior. Proving
that a kept lesson still holds means replaying it against the real model, which is credentialed and
costs model calls, so it is deliberately not part of the fast deterministic gate.

`make promote-corrections` runs both tiers before and after promoting, so a failure is attributable
to the corrections rather than to something already broken. It is the right place for a credentialed
check because it already opens the live database and already needs a config; it is not an ordinary
edit-test cycle. `make model-release-check` runs `eval-regressions` too, so a promoted lesson that
stops holding blocks a model release.

Unlike the per-deployment replay corpora, the promoted corpus is a single file. That is only safe
because the recorder never writes a repository onto a fixture, and
`TestThePromotedCorpusBindsNoRepository` fails if that stops being true. The honest response to that
failure is to split the corpus per deployment, not to lower its pass rate.

After deterministic episode replay, run the small changing-world canary:

```bash
make eval-live-canary CONFIG=../emisar/.responder/responder.yaml
```

The canary uses only cases tagged `canary` in the live corpus. It verifies that the configured model,
authenticated Coop account, repository projection, and current read-only tools still work together.
`make model-release-check` runs deterministic episode replay, promoted corrections, and then this
canary in addition to the quality, proactivity, scenario, and evidence gates.

### Stateful behavior and human quality

Single-turn cases are necessary but insufficient. Run the stateful scenarios to keep one real Coop
conversation alive across multiple model turns:

```bash
make eval-scenarios CONFIG=../emisar/.responder/responder.yaml
```

`testdata/eval/scenarios.jsonl` covers cross-channel operational continuity, old-thread summaries,
conversation addressee inference, restart recovery, and firing/recovery ordering. Each step uses the
production watch prompt, the preceding structured conversation memory, bounded message history, and
related same-repository conversation summaries. A simulated restart round-trips all evaluator state
and reconnects to the same Coop session before the next turn.

Rendered responses pass through the production Slack message builders before scoring. The
deterministic Slack UX check rejects missing fallback text, oversized messages or blocks, duplicate
action IDs, invalid action URLs, leaked transport JSON, and repeated safety boilerplate. With
`--judge`, a separate real model turn scores the exact rendered Slack surface for human likeness,
conversation fit, directness, productivity, Slack fit, and evidence discipline.

Compound cases can set `min_reply_messages` to prove that the model preserved distinct requested
outcomes instead of silently dropping or collapsing them. The service suite separately proves that
ordered parts survive durable delivery in both normal channel triage and incident/task sessions,
stay in one Slack destination, and attach evidence or controls only to the final part. The live
corpus includes a real-model, repository-backed three-instruction case.

The quality judge is itself calibrated against human-labeled good and bad examples:

```bash
make eval-judge-calibration CONFIG=../emisar/.responder/responder.yaml
make eval-quality CONFIG=../emisar/.responder/responder.yaml
```

The calibration corpus contains concise good answers as well as bureaucratic acknowledgements,
wrong-addressee interruptions, unsupported success claims, protocol leaks, and walls of internal
output. A judge-model or prompt change cannot pass the model release gate if it stops separating
those examples.

### Proactivity, evidence, and productive outcomes

Use the labeled interruption corpus for classification statistics rather than a few anecdotes:

```bash
make eval-proactive CONFIG=../emisar/.responder/responder.yaml EVAL_REPEAT=3
```

It reports true and false positives and negatives, precision, recall, and false-interruption rate
across repeated samples. The default Make target requires at least 0.90 precision and recall, no
more than 0.10 false interruptions, and a 0.67 per-case pass rate.

For decision-material operational answers, `--verify-evidence` starts a separate isolated model
session with the same read-only repository and tools. The verifier must independently re-check the
claims rather than trust the first response's citations:

```bash
make eval-evidence CONFIG=../emisar/.responder/responder.yaml
```

This is observable outcome verification, not raw tool-trace inspection. Coop intentionally keeps
ACP frames, raw tool payloads, hidden reasoning, and box logs out of its public event contract.
Responder verifies the public turn lifecycle, the structured evidence, an independent re-check,
and the resulting Slack answer without weakening that boundary.

Writable productivity evaluation is explicit and disposable:

```bash
make eval-productivity \
  CONFIG=/path/to/eval-responder.yaml \
  TASK_EVAL_POLICY=responder-eval-write
```

The evaluation config must bind the `responder` repository and the named Coop policy must allow
writes only in an isolated evaluation fork, prohibit push/deploy, and configure the real review
gate. The case requires a focused commit, an exact changed path, no forbidden paths, and a
publishable Coop review. Responder captures the changes and review before discarding the
evaluator-owned fork. Draft-PR publication against the exact reviewed tree remains covered by the
offline customer journey; a real GitHub PR is deliberately not created by the default model gate.

### Variance, baselines, and release gates

Repeated results are aggregated per logical case. Threshold flags fail the command on weak overall
pass rate, per-case flakiness, proactivity precision/recall, false interruptions, mean quality, or
regression from a private baseline:

```bash
responder eval --config ../emisar/.responder/responder.yaml \
  --input testdata/eval/proactive.jsonl --repeat 5 \
  --min-case-pass-rate 0.8 \
  --min-proactive-precision 0.9 \
  --min-proactive-recall 0.9 \
  --max-false-interruption-rate 0.1 \
  --write-baseline /secure/path/proactive-baseline.json

responder eval --config ../emisar/.responder/responder.yaml \
  --input testdata/eval/proactive.jsonl --repeat 5 \
  --baseline /secure/path/proactive-baseline.json \
  --max-regression 0.1
```

A baseline written this way, and every detailed result report, is written mode `0600` as private
state. Cases are compared by name: one the baseline does not know is not a regression, so a corpus
that grew by promotion is still compared rather than refused, and one the baseline knows that is
missing from the run fails — deleting a fixture must not be a way to make its regression disappear.

### The trend

Every model evaluation target writes its complete result into `$(EVAL_HISTORY)`, which defaults to
`~/.local/state/responder/eval-history`. Read the series back with:

```bash
make eval-trend
```

It prints, per target and in time order, the pass rate and the mean judge score, with the change
from that target's previous run.

This exists because the judges were already doing the work and the answer was being discarded. The
quality rubric scores six dimensions per case, the evidence verifier independently re-checks the
claims, and `--calibrate-judge` scores the judge itself — and every one of those numbers went to
stdout and nowhere else, because `--results` was passed by nothing and CI reads only the exit code.
A gate that only ever reports pass or fail can tell you the bot is not broken. It cannot tell you
whether it is getting better, and that was the question nobody could answer.

The directory is private state, not a checked-in artifact: results carry sanitized model output and
are written mode `0600`. Nothing prunes it automatically — deleting evaluation evidence on a timer
would destroy the only record of when a regression started — so it grows by about one file per
model evaluation and is pruned by hand.

For enforcement rather than observation, the reviewed baselines are committed under
`testdata/eval/baselines/`, named for the target that records them, and every target in
`model-release-check` passes the one that exists. The run fails when a case, the overall pass rate,
or the mean judge score drops beyond `--max-regression` (a rate, 0 to 1) or
`--max-quality-regression` (judge points, 1 to 5 — the judge's scale is not a rate, and one knob for
both would be either meaningless for the rate or unusable for the score). A corpus with no committed
baseline yet runs its ordinary thresholds and nothing else.

Recording one is deliberately a separate act:

```bash
make model-release-check CONFIG=../emisar/.responder/responder.yaml
make eval-trend
make eval-baseline-update CORPUS=quality
git diff testdata/eval/baselines
```

The update reads the newest result the corpus already filed in `$(EVAL_HISTORY)` rather than
re-running it, and refuses a run with a failed or unevaluated case — a baseline records what a clean
run achieved. It writes a file and stops, because a baseline that refreshed itself after every green
run is how a quality floor walks downhill one acceptable step at a time. The trend is the record;
the committed baseline is the ratchet, and the diff is where it is approved.

Run the complete credentialed model gate before changing the production model, prompt, tools, or
Coop policy:

```bash
make model-release-check CONFIG=../emisar/.responder/responder.yaml
```

That target calibrates the judge, scores ordinary response quality, measures proactive behavior,
runs stateful scenarios, independently verifies high-risk evidence, and replays the promoted
corrections. Add `make eval-productivity` when a disposable writable policy is available. Every one
of those runs leaves a result behind, so `make eval-trend` afterwards shows what the release
changed.

Use `responder eval --replay` or `make eval-replay` only for deterministic contract replay. That
path does not evaluate model behavior and is named accordingly.

## Development gate

Use the mechanical focused loop while editing. It derives owning Go packages from the current
diff, formats changed Go files, checks changed shell scripts, and runs only those package tests:

```bash
make focus
make focus FOCUS_PACKAGE=./internal/service FOCUS_TEST='^TestName$'
```

Before committing, run the fast deterministic repository gate:

```bash
make dev-check
```

`make dev-check` runs independent module, formatting, vet, shell, Go-test, contract-replay, and
build checks concurrently. It deliberately leaves the
whole-tree race detector, Staticcheck, actionlint, vulnerability scan, and quality-watch
suite to the full gate. Running bare `make` is equivalent to `make dev-check`.

After committing a releasable batch, run `make elixir-release-check` and
`make elixir-candidate-check`. They build the exact commit's immutable OTP release, verify its
operator assets and digest before extraction, then migrate and boot it against disposable
PostgreSQL, restart it against the same database, and boot once more from a verified backup restore.
Deployment itself is one ordinary writer replacement; restart and rollback use
PostgreSQL custody plus immutable old/new releases, not a canary/promote state machine.

## Release gate

```bash
make check
make release-check
```

`make check` runs independent checks concurrently and covers both replacement and retained legacy
contracts, including formatting, static analysis, unit/integration tests, replay, race checks,
production builds, and vulnerability analysis. `make release-check` also builds and boots the
Elixir candidate and inspects every signed-release input. A real-model eval is credentialed, costly,
and nondeterministic, so
it is an explicit pre-release/model-change gate rather than part of ordinary offline CI.

The customer journeys are distributed across package tests at the boundary that owns the outcome:

| Customer expectation | Primary automated proof |
| --- | --- |
| Signed webhooks are admitted once and conflicting replays fail | `internal/httpapi/handler_test.go` |
| A firing alert creates one room, one Coop session, and a bounded Slack result | `internal/service/service_test.go` |
| A human question replies in place without automatically creating an incident | `internal/service/service_test.go` |
| Nearby messages provide ordered context and late work cannot reply out of order | `internal/service/service_test.go`, `internal/store/work_test.go` |
| Preferences and standing rules are inert until confirmed and remain read-only | `internal/service/behavior_test.go`, `internal/store/behavior_test.go` |
| Matched standing rules can ignore intermediate lifecycle events and act on later evidence | `internal/service/behavior_test.go`, `internal/service/service_test.go`, `testdata/eval/proactive.jsonl` |
| Scheduled tasks are typed, confirmed, DST-aware, non-overlapping, restart-safe, and dispatched through the normal agent pipeline | `internal/service/schedule_test.go`, `internal/store/schedule_test.go`, `internal/slackui/message_test.go`, `testdata/eval/proactive.jsonl` |
| Evidence, coverage, approvals, and Slack controls are host validated | `internal/service/report_test.go`, `internal/slackui/message_test.go` |
| Draft PR publication uses the exact reviewed task tree and is unavailable to incidents | `internal/service/customer_journey_test.go`, `internal/publisher/github_test.go` |
| Published tasks follow GitHub checks and merge state, deduplicate replays, and route exactly matched deployment/Terraform signals back to the original thread | `internal/publisher/github_test.go`, `internal/store/lifecycle_test.go`, `internal/service/service_test.go`, `internal/slackui/message_test.go` |
| Interrupted work resumes, retries remain bounded, and cleanup preserves unpublished changes | `internal/service/service_test.go`, `internal/store/work_test.go` |
| Resolved work whose Slack room was deleted is closed and ownership-checked before cleanup | `internal/store/lifecycle_test.go`, `internal/service/service_test.go` |
| Slack app manifest, scopes, membership diagnostics, and managed Coop supervision remain usable | `internal/slackui/client_test.go`, `internal/app/coop_supervisor_test.go` |
| Slack screenshots and documents are bounded, authenticated, type-checked, passed to Coop, retained only for the turn, and preserved when an engineering task is accepted | `internal/service/attachments_test.go`, `internal/service/service_test.go`, `internal/coop/client_test.go`, Coop `internal/session/store_test.go` and `internal/cli/session_artifact_test.go` |
| Generated images and charts remain outside the text transcript, are tied to one completed turn, digest-checked, uploaded to the same conversation, and reconciled without duplicates | `internal/service/service_test.go`, `internal/coop/client_test.go`, Coop `internal/cli/session_acp_test.go`, `internal/cli/session_output_test.go`, and `internal/session/store_test.go` |
| Accepted work has a durable effort/authority contract, rate-limited progress, restart-safe commitments, and coverage-driven completion | `internal/service/work_episode_test.go`, `internal/store/work_episode_test.go`, `testdata/eval/live.jsonl` |

Real-model prompts receive the same host work-episode contract as production. Deep health, incident,
and matched-alert cases require a completion assessment; the evaluator rejects a final answer that
omits required layers, labels material unknowns decision-ready, or reports a blocker without an
external blocker type, evidence of attempted routes, and an action that would actually unblock it.
The regression suite also rejects "query more data" as a blocker when the current read-only session
can continue that work. This makes premature-final-answer regressions visible in the ordinary model
release gate rather than only during manual Slack testing.

## Live acceptance

Offline tests cannot prove that a real Slack workspace, current Coop build, AI provider account,
Emisar policy, installed MCP catalogs, and Slack renderer agree. The opt-in replacement acceptance
runs from the immutable installed Elixir release against its active PostgreSQL queues. It posts only
to an existing joined, non-Connect channel named `#test` or ending in `-test`:

```bash
set -a
source ../emisar/.responder/local.env
set +a
make live-acceptance \
  CONFIG=../emisar/.responder/responder.yaml \
  LIVE_CHANNEL=C0123TEST
```

The test injects uniquely identified synthetic configured-operator inputs because a bot token cannot
impersonate a human. It does not start a second Slack socket or a second product runtime: the active
deployment must claim Admission, remote Work, and Delivery from the same database. Outputs cross the
real Slack API, configured model, remote Coop worker, repository checkout, and state-tool boundary.
The proof requires two distinct settled turns in one episode, one Coop session, and the exact root
thread, with nonempty rendered replies and typed external receipts. The JSON report says explicitly
that the inputs were synthetic and records the immutable release version and durable identities.

This narrow automatic lane does not confirm offers or exercise mutating authority. The broader
manual acceptance matrix below remains mandatory before production cutover. The same matrix is
rendered, with configuration availability, at `http://127.0.0.1:4321/manual-tests`.

Before the live run, use `responder doctor` to verify the installed App scopes and current
workspace configuration. Then qualify these large features in disposable destinations:

1. **Conversation Lab.** Open `http://127.0.0.1:4321/lab`, start a conversation, and ask for a
   concise answer. Send a follow-up that depends on it and confirm the Lab shows one episode and one
   Coop session with two logical turns. Ask a material question, answer it, and verify the same task
   resumes. Upload a bounded text file and image, ask for a generated image, and verify exact input
   artifact custody plus a turn-scoped local preview. Edit a sent message, then delete another, and
   verify each remains one stable logical item with increasing revisions. Add and remove feedback
   emoji on a Responder reply; it must update the visible current count without starting work, then
   appear as bounded context after the next message. Exercise one model-requested reaction and the native
   task, memory, schedule, automation, and publication controls. Ask it to list, search, and read the
   current virtual workspace across completed episode boundaries, including one uploaded file through
   `files` search and a `document` read. Then explicitly request an additional message: verify the model uses the
   Slack-compatible tools, the post remains inert until the local confirmation is clicked, and no Slack
   request occurs. Ask it to prepare an incident, confirm the local incident card, and verify a linked
   policy-pinned Work episode starts in this timeline without a Slack API request and inspect its
   evidence-backed postmortem. On a confirmed task, inspect its exact Coop diff plus host-rendered timeline,
   evidence ledger, and handoff, then exercise readiness review, explicit draft publication, and delivery
   check from the task card. Restart Responder while the next answer
   is pending; expect one eventual reply and no duplicate Work or Delivery row.
2. **Slack conversation.** Mention Responder in an approved `*-test` channel. Expect native progress
   followed by one reply in the exact root thread. Send an ordinary authorized follow-up without an
   `@mention`; expect the same episode/thread and a compact continuation rather than another full
   briefing. Repeat in a DM and verify it continues the current nonterminal DM episode without ever
   crossing into a shared-channel thread.
3. **Slack task and progress cards.** Request a harmless repository task. Confirm the host-owned task
   offer, then exercise status, progress repaint, run-now/resume where offered, and Stop. Double-click
   or replay every button payload; expect one audited transition and the same repainted card. Stop
   during a running Coop turn and verify remote cancellation is terminal before the episode cancels.
   Continue one disposable task through readiness review and draft-PR publication. Move that
   Responder-owned PR branch to a different harmless commit, click **Check delivery**, and expect the
   task card to become action-required with **Review latest state** and **Discard candidate**. Review
   latest state must create a new review generation, require a new publish approval, update the same
   PR number, and use the exact observed remote head as its force-with-lease expectation. Move the
   branch again after review but before publication; Responder must report a conflict and must not
   overwrite the newer head. Replay the old action payload and expect a stale-generation rejection.
4. **Slack reactions and files.** Add and remove a standard or configured custom emoji reaction on a
   live Responder reply and verify one normalized passive-feedback event, current member/count state,
   and no model turn until another message arrives. Ask Responder to react to a source message and verify
   exact source-message targeting plus idempotent `already_reacted` handling. Upload a bounded text
   file and image; verify authenticated byte fetch, type/size checks, turn-scoped artifact custody,
   and same-thread delivery. Create one disposable incident room and verify audience, topic,
   bookmarks, pinned card, lifecycle repaint, and cleanup without a duplicate room.
5. **GitHub issue conversation.** Comment on a disposable issue as an authorized actor. Expect one
   reply on that issue using the configured installation/repository binding. Edit and then delete
   the source comment; verify stable item revisions remain owned by the original episode and a stale
   revision cannot create or move work.
6. **GitHub PR review.** Request a review on a disposable pull request and verify a review summary is
   posted through the PR review endpoint. Reply inside an inline review thread and verify Responder
   uses the exact root review comment rather than an issue comment or another thread. Test comments
   and review comments separately because GitHub exposes different APIs for each.
7. **GitHub emoji reactions.** On both an issue comment and a PR review comment, exercise `+1`, `-1`,
   `laugh`, `confused`, `heart`, `hooray`, `rocket`, and `eyes`. Expect the native reaction endpoint,
   the exact authenticated target, and one durable receipt per requested operation. A repeated
   delivery must reconcile the same reaction instead of creating another action.
8. **Universal webhook.** Send a signed arbitrary JSON object with unique occurrence ID, stable item
   ID, and configured destination. Expect Responder to report exact observed fields while labeling
   unknown vendor meaning. Exact replay must be a duplicate; a changed body under the occurrence ID
   must conflict; revision 2 under the stable item must remain in the original episode. Content must
   never choose its own destination, policy, repository, reaction, or posting authority. For local
   qualification, bind the route to the exact Conversation Lab ref so the accepted reply is visible
   without generating Slack traffic; the configured production route may instead target Slack or
   GitHub through its registered adapter.
   After merging the disposable draft PR, send a second event whose body is the exact
   publication lifecycle body documented in `webhooks.md`, with the
   `X-Responder-Event-Type: responder.publication_lifecycle.v1` header, a `deployment` or
   `terraform` kind, and an exact recorded PR URL, branch, commit, or merge SHA. A successful signal
   must create one verification wakeup. Change the reference to a substring, add an extra envelope
   field, or send equivalent prose; each must be accepted as ordinary input without advancing the
   publication verification lifecycle.
9. **Stateful model behavior.** Ask for evidence, a progress update, a required goal, memory, a
   schedule, an operator question, and a governed Emisar action in separate safe conversations.
   Confirm offers before activation. Verify waits release leases, exact triggers resume once, open
   goals prevent premature completion, and an Emisar link never claims success before authoritative
   completion. Force one invalid final and one lost validation response; expect same-turn repair and
   one accepted result.
10. **Recovery and cleanup.** Restart at frozen-submit, accepted-result, and post-sent/pre-receipt
    points; expect exact operation reconciliation and no duplicate visible effect. Restore a fresh
    `pg_dump` into a disposable database and boot the same immutable release against it. Complete
    clean, dirty, and unmerged repository tasks and verify close/discard/retain behavior plus the
    typed rearm controls in Failures and Workspaces.

For every journey, keep the corresponding Conversation Lab, Episodes, Failures, Workspaces, and
Usage pages open. A visible message is not sufficient proof: its exact destination, episode owner,
accepted candidate receipt, delivery receipt, and terminal/retry state must also be correct.

Use test channels and non-production read-only actions. Destructive or approval-granting acceptance
tests belong in a dedicated environment, never in the default release gate.
