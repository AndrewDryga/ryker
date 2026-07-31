# Testing Responder

Responder uses four test layers plus a statistical model-release gate. They intentionally prove
different things; no single green command is presented as proof of the whole product.

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
scored as behavioral contracts rather than exact answer wording.

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

Baselines and detailed result reports are written mode `0600`. They contain a canonical corpus
digest; adding or editing a case invalidates the old baseline instead of silently comparing
different tests.

Run the complete credentialed model gate before changing the production model, prompt, tools, or
Coop policy:

```bash
make model-release-check CONFIG=../emisar/.responder/responder.yaml
```

That target calibrates the judge, scores ordinary response quality, measures proactive behavior,
runs stateful scenarios, and independently verifies high-risk evidence. Add
`make eval-productivity` when a disposable writable policy is available.

Use `responder eval --replay` or `make eval-replay` only for deterministic contract replay. That
path does not evaluate model behavior and is named accordingly.

## Release gate

```bash
make check
make release-check
```

`make check` runs formatting and static analysis, unit and integration tests, the contract replay,
the race detector, a production build, and vulnerability analysis. `make release-check` also builds
and inspects release archives. A real-model eval is credentialed, costly, and nondeterministic, so
it is an explicit pre-release/model-change gate rather than part of ordinary offline CI.

The customer journeys are distributed across package tests at the boundary that owns the outcome:

| Customer expectation | Primary automated proof |
| --- | --- |
| Signed webhooks are admitted once and conflicting replays fail | `internal/httpapi/handler_test.go` |
| A firing alert creates one room, one Coop session, and a bounded Slack result | `internal/service/service_test.go` |
| A human question replies in place without automatically creating an incident | `internal/service/service_test.go` |
| Nearby messages provide ordered context and late work cannot reply out of order | `internal/service/service_test.go`, `internal/store/work_test.go` |
| Preferences and standing rules are inert until confirmed and remain read-only | `internal/service/behavior_test.go`, `internal/store/behavior_test.go` |
| Evidence, coverage, approvals, and Slack controls are host validated | `internal/service/report_test.go`, `internal/slackui/message_test.go` |
| Draft PR publication uses the exact reviewed task tree and is unavailable to incidents | `internal/service/customer_journey_test.go`, `internal/publisher/github_test.go` |
| Interrupted work resumes, retries remain bounded, and cleanup preserves unpublished changes | `internal/service/service_test.go`, `internal/store/work_test.go` |
| Resolved work whose Slack room was deleted is closed and ownership-checked before cleanup | `internal/store/lifecycle_test.go`, `internal/service/service_test.go` |
| Slack app manifest, scopes, membership diagnostics, and managed Coop supervision remain usable | `internal/slackui/client_test.go`, `internal/app/coop_supervisor_test.go` |
| Slack screenshots and documents are bounded, authenticated, type-checked, passed to Coop, retained only for the turn, and preserved when an engineering task is accepted | `internal/service/attachments_test.go`, `internal/service/service_test.go`, `internal/coop/client_test.go`, Coop `internal/session/store_test.go` and `internal/cli/session_artifact_test.go` |

## Live acceptance

Offline tests cannot prove that a real Slack workspace, current Coop build, AI provider account,
Emisar policy, installed MCP catalogs, and Slack renderer agree. The opt-in acceptance test posts
to an existing joined channel named exactly `#test` while using an isolated temporary Responder
database:

```bash
set -a
source ../emisar/.responder/local.env
set +a
make live-acceptance \
  CONFIG=../emisar/.responder/responder.yaml \
  LIVE_CHANNEL=C0123TEST
```

The test injects synthetic configured-operator inputs into that isolated database because a bot
token cannot impersonate a human. Outputs still cross the real Slack API, configured model, Coop
socket, repository checkout, and read-only MCP tools. It verifies a normal reply, same-thread
follow-up context, an inert preference offer plus explicit confirmation, and an engineering-task
offer without starting writable work. It fails on malformed or oversized Slack blocks, leaked
protocol JSON, incorrect routing, duplicate durable work, or an unexpected incident. Any clean
read-only Coop session it owns is discarded at the end; dirty or running work is retained for
inspection.

Before the live run, use `responder doctor` to verify the installed app scopes and current
workspace configuration. The broader release acceptance matrix remains:

1. Ask a health question and verify immediate native progress followed by a threaded answer with
   both repository and live evidence.
2. Send an ordinary follow-up without an `@mention` and verify it stays in the same conversation.
3. Ask for a repository change, confirm the engineering-task offer, inspect the change, and create
   a draft PR only after review.
4. Ask to remember a deep health preference and a Terraform plan rule; verify nothing is active
   before confirmation and matching behavior works afterward.
5. Use a test Emisar action that requires approval; verify Slack links to the exact Emisar approval
   and never claims the action ran before authoritative completion.
6. Restart Responder during a pending turn and verify one eventual result with no duplicate room,
   message, or agent submission.

Use test channels and non-production read-only actions. Destructive or approval-granting acceptance
tests belong in a dedicated environment, never in the default release gate.
