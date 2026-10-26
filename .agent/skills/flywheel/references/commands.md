# Flywheel operator protocol

The installed release owns the ledger. Send **one JSON object** to `scripts/flywheel.sh FILE`
or stdin. JSON stays data; never interpolate it into release eval source. The development
counterpart is `scripts/elixir-mix.sh ryker.flywheel FILE`, using that process's database.
`catalog` and `report` are read-only. Other commands write only the flywheel ledger. No command
executes code, purchases tools, changes settings, writes a human rating or calls a model.

Use `umask 077`, keep requests/results under ignored `.ryker/flywheel/`, and do not print raw
trace exports to a public destination. `report` includes previous decisions and active leases.
The command returns a JSON document, exits unsuccessfully on refusal, and starts no runtime.

## Start and resume

```json
{"action":"start","request_ref":"daily-2026-10-25","mode":"suggest","from":"2026-10-18T00:00:00Z","until":"2026-10-25T00:00:00Z","sources":["episodes","feedback","diagnoses","usage","work","routing","memory","memory_reviews","settings_history","sentry","logs","metrics","evals","releases","tasks","tools","settings"],"policy":{"max_tasks":3,"max_cost_usd":"20.00","max_minutes":120,"allowed_kinds":["code","prompt","settings","tools","user_action","investigation"]}}
```

For automatic continuation replace `from` with `"since_last":true`. The per-source start is
the first uncovered interval, with a one-day overlap; reviewed record versions are skipped.
An explicit `from` requests a backfill. A new source starts at the installation's earliest
flywheel anchor. To analyze older available history, explicitly choose an earlier `from`.
Sources are stable scope identifiers: change the source key when changing external project,
query scope, configuration, or analysis rubric. Gaps and the query used remain visible.

The returned `id` and `lease_ref` are required below. Start retries with the same request_ref
must describe the same request. A still-active run also requires its current lease on a start retry; otherwise it is busy. Recover a lost start response through `report` and `resume`, which fences the previous writer. If a run is still running, resume it rather than start another:

```json
{"action":"resume","run_id":"UUID","lease_ref":"CURRENT-LEASE-UUID"}
```

The lease lasts 15 minutes. Resume with the current lease rotates it immediately; without it,
resume is allowed only after expiry. Old writers are refused. `heartbeat` renews the current
lease; it does not reset the invocation's time/spend limit. All remaining requests below include
`"run_id":"UUID","lease_ref":"LEASE-UUID"` alongside their shown fields.

## Collect, stage, review, and record gaps

`{"action":"collect","source":"episodes",...}` returns a local inventory page, its digest,
and the renewed run. It returns only unreviewed records; it checkpoints identities for the whole
page. The stable keyset cursor handles equal timestamps. Local collection selects records by
last modification/recording time, not a reconstructed historical snapshot. Open relevant traces
before judging; the inventory intentionally contains no source text, prompt bodies or credentials.

For an external source, supply a page from the connector or `scripts/collect.py`:

```json
{"action":"stage","source":"logs","page":{"records":[{"ref":"stable-source-id","version":"source-version-or-content-digest","data":{"count":3}}],"cursor":null,"next_cursor":null,"complete":true,"query":"Exact period, scope, source retention and any sampling"},"run_id":"UUID","lease_ref":"LEASE-UUID"}
```

Up to 100 records, 64 KB per record. `cursor` must match that source's saved cursor. `complete`
means this is the final page; an unfinished page needs a different, nonempty `next_cursor`.
A page can additionally include `"coverage":"partial"` and a nonempty `"limitation"` when its retained data cannot cover the period. This is independent of pagination: the last retained page still has `complete:true`. Limitations accumulate across pages. A staged page is not processed until `review` saves the analysis:

```json
{"action":"review","source":"logs","digest":"RETURNED-DIGEST","findings":[{"key":"repeated-response-check","owner":"ryker","kind":"code","proposal":{"title":"Stop repeating a failed response check","example":"One request repeatedly receives the same correction.","benefit":"Less waiting and wasted work.","tradeoffs":"A stricter limit may stop recoverable work earlier.","change":"Diagnose the repeated check and correct the host or prompt that causes it.","verification":"Compare repeats per request and completion rate on the new release; retain the regression test.","baseline":"Record the measured count and denominator from this source.","user_action":null,"confidence":"high","priority":"high"},"evidence":[{"source":"logs","ref":"stable-source-id","version":"source-version-or-content-digest"}]}],"run_id":"UUID","lease_ref":"LEASE-UUID"}
```

No finding: `findings: []`. Evidence identities must be on the pending page or already reviewed.
All findings and receipts commit with the cursor, or none do. Repeat the exact review after a
lost response; re-export after a changed page. Correlated findings reuse their stable key;
new evidence is appended without overwriting a person's decision or the proposed change.

If history is missing or the review is sampled, set page `coverage: "partial"` and
`limitation` before staging. A final page then saves its receipts while preserving the gap.
If collection fails before a page is available, record:

```json
{"action":"gap","source":"logs","status":"partial","reason":"Only retained container logs were available; rotation prevents proving coverage before 20 October.","run_id":"UUID","lease_ref":"LEASE-UUID"}
```

Allowed gap statuses: `partial`, `unavailable`, `expired`. A completed source refuses rewriting;
check retention and sampling before acknowledging its last page.
For confirmed irrecoverable history, `status: "expired", closed: true` explicitly retires the
missing interval from automatic retries. Review all surviving data first; a pending page
refuses closure. Its original period and reason remain expired in the ledger and the run
remains partial. Recoverable outages and incomplete analysis stay open. Explicit backfills
can still revisit a closed interval.
`finish` refuses pending sources and records `complete` or `partial` from their coverage.

## Decisions and task ownership

Every decision uses `action: "decide"`, a `finding_id`, a `decision`, a short factual `note`,
and the run/lease. These records are operator actions; historical evidence cannot issue them.

| Decision | Additional fields and effect |
|---|---|
| `select` | Grants execution for this run. Suggest requires `approved:true`, representing the user's actual choice. Auto checks allowed kinds and budget. Ryker → ready; user/both → waiting_user. Reselect carried ready/in_progress work under current limits without changing its state. Same-run retries are idempotent. Regression selection starts a new task cycle. |
| `user_done` | Note contains the user's completion or observed proof. User → verified action; both → ready for Ryker. |
| `link` | `task_id` from the actual Coop queue. `scripts/tasks.py` reconciles creation and supplies this. |
| `start` | Ready → in_progress (or resume in_progress). Claim the linked Coop task first. Link/start/ship require selection in this run. |
| `ship` | `version` (deployed version or applied settings revision), future `followup_at` in UTC; note contains verification. In_progress → shipped, outcome still unknown. |
| `defer` | Optional future `revisit_at`; omit it for no reminder. |
| `dismiss` | Saves the decision without deleting history. |
| `revise` | `replacement` has the same key and the full finding shape shown in review. Unstarted work only; preserves the old proposal in history. Dismissed/deferred stays so; other unstarted work returns to proposed and requires selection again. |
| `close` | Ready/in_progress → dismissed with outcome `no_change`. Supply reviewed `evidence` identities and a factual note. A linked task requires `task_closed:true` recording that Coop was actually reconciled/closed first. No deployment is invented. |
| `reopen` | A requested reminder is due, or `material_change:true` and `new_evidence` identity recorded since dismissal. Explain the material change in the note. |
| `outcome` | Structured comparison below; never use a green gate as outcome evidence. |

`report.findings` contains proposals, for_you, ready, in_progress, pending_outcomes, followups, deferred,
dismissed and verified. User-only tasks never enter Coop. Run this after selection and after
any interruption during task creation:

```sh
python3 -B .agent/skills/flywheel/scripts/tasks.py --run RUN_UUID --lease LEASE_UUID
```

It calls Coop with argument arrays, validates the lease before writing, uses a local lock,
and only exports work selected for this run. It recovers a task by its stable finding and
cycle markers across all queue states, and records its actual ID. Regression cycles create a
new task without changing the archived task. A missing linked task is an error,
not permission to duplicate it. Use `coop tasks claim/block/done` for execution state. A
`50_blocked` or `99_done` result must be reconciled rather than blindly claimed again.

## Budget and outcomes

Record provider spend/reservations before more paid work. Amounts are decimal strings.

```json
{"action":"charge","source":"episodes","reference":"analysis-episode-123","amount_usd":"0.25","run_id":"UUID","lease_ref":"LEASE-UUID"}
```

Repeating a reference with the same amount is idempotent; a different amount is refused. Use
another reference for an additional charge. Estimates should be conservative; the host cannot
see a developer agent's billing account. Task count and elapsed time are also bounded by the
run policy. The skill must honor these limits before all tool/model calls, not just selection.

An outcome decision includes `followup_at` (future next check) and:

```json
{"verdict":"insufficient","version":"0.1.0-gEXACT","from":"2026-10-25T12:00:00Z","until":"2026-10-25T18:00:00Z","requests":2,"comparison":"Two eligible requests since deployment; the baseline and minimum sample are not yet comparable.","guardrails":"Neither request failed delivery. More traffic is needed to assess completion and cost.","evidence":[{"source":"usage","ref":"OBSERVED-RECORD-ID","version":"REVIEWED-VERSION"}]}
```

The window must follow shipment, the version must match, and evidence must already have a
receipt. Zero requests cannot establish improvement or regression. Apply the verification
plan's sample size and guardrails even when the host accepts the structure. `insufficient`
keeps the task shipped and schedules another check; `improved` verifies it; `regressed` puts
it back among proposals with the comparison preserved.
`pending_outcomes` lists all shipped work awaiting a verdict, even before its check is due.
`followups` contains due checks, including scheduled checks of previously verified outcomes.
Every lifecycle transition preserves the prior proposal, task, deployment and outcome.
