# Testing Responder

Responder uses four test layers. They intentionally prove different things.

## Fast customer check

Run this while changing Slack behavior, incident workflow, memory, or response contracts:

```bash
make customer-check
```

It runs the Go suite with fake Slack, Coop, Emisar, and GitHub boundaries, then replays the redacted
customer-response corpus through the same strict parsers used in production. It does not use
credentials, call a model, create Slack channels, publish a pull request, or touch infrastructure.

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
| Slack app manifest, scopes, membership diagnostics, and managed Coop supervision remain usable | `internal/slackui/client_test.go`, `internal/app/coop_supervisor_test.go` |

## Live acceptance

Offline tests cannot prove that a real Slack workspace, current Coop build, AI provider account,
Emisar policy, and installed MCP catalogs agree. Before a release or after changing those
integrations, run `responder doctor`, start the service with the intended customer configuration,
and exercise a bounded read-only acceptance set:

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
