# Go lifecycle test parity

This inventory prevents the replacement Responder from losing behavior already protected by the Go
suite. The machine-readable source is
[`elixir-episode-kernel-go-parity.json`](elixir-episode-kernel-go-parity.json). A fast Elixir test reads
the current Go source and fails when a scoped test is added, removed, renamed, duplicated, or left
without a replacement owner.

## Scope

The first inventory covers every test in 20 cohesive lifecycle files: episode reduction, persistence,
outcomes, waits, source correlation, Slack delivery, run ownership, retries, and cancellation. It maps
208 Go tests. It is complete for those files, not for all 2,373 Go tests in the repository.

Mixed subsystems are brought into scope when their replacement module starts. That module must expand
this manifest before its Go implementation can be deleted. This avoids classifying unrelated product
tests now while still making the cutover boundary explicit and mechanically checked.

## Replacement owners

| Owner | Go tests | What must preserve them |
|---|---:|---|
| `episode_kernel` | 8 | Durable identity, owner, queue, wait, result and cancellation transitions. |
| `source_ingress` | 50 | Generic Slack intake, model admission, chronology, correlation, wakeups and thread binding. |
| `slack_gateway` | 44 | Atomic outbox custody, response-loss reconciliation, status, reactions, artifacts and routing. |
| `coop_runtime` | 61 | Session isolation, provider recovery, leases, replay, turn capacity and cancellation. |
| `final_protocol` | 24 | Candidate admission, correction, silence, completion and result supersession. |
| `engineering_github` | 7 | Approval, task continuation, publication and GitHub lifecycle. |
| `memory_recall` | 5 | Outcome projection, visibility, recall and reopened/cancelled behavior. |
| `automation_waits` | 4 | Scheduled work, retry timing, overdue custody and recurring execution. |
| `legacy_archive` | 5 | Read-only historical migration/provenance; these do not become new runtime behavior. |

## Already represented in Stage 1

Nineteen old tests already have a direct kernel test or harvested replay fixture. Every test assigned to
`episode_kernel` has one; ten additional integration tests retain their future owner while also naming
the Stage 1 invariant they build on. Important examples are:

- deterministic replay and explicit reopening;
- exact operator-answer admission;
- chronological messages in one conversation;
- immutable destination and delivery ownership;
- wakeup and owner fencing across restart;
- terminal cancellation of a wait and its deadline;
- a new Grafana cycle using the new card;
- linked history never supplying the current Slack destination;
- response-loss idempotency for cancellation and admission; and
- a newer contextual message queueing behind active work instead of destroying it.

These matches prove the lower-level invariant only. A Go Slack-delivery or source-correlation test stays
assigned to its future integration module even when Stage 1 already protects its underlying destination
or queue behavior.

## Stage 2 host proof and pending model proof

Four source-ingress tests now have direct deterministic generic-admission equivalents. They cover
exact-thread wait resumption and newer context queueing behind active work without replacing its owner.

Eleven additional source-ingress cases have harvested Slack contexts but remain explicitly pending
model evaluations. They cover an active lifecycle retaining its first card, a new cycle using its new
card while linking history, arbitrary app input without count/status heuristics, and distinct external
runs remaining separate. Replaying a recorded decision proves only that the host applies that decision
safely; it does not prove a model will choose it.

The fixtures contain provider text because that is what Slack really delivered. Production admission
code does not branch on those providers or phrases. Old tests whose purpose was to parse specific alert
wording, links, or run syntax remain assigned to `source_ingress` until they are represented by model
evaluation cases; they must not be reintroduced as deterministic host string matching.

## Maintenance rule

Run `make elixir-check` after changing a scoped Go test or this manifest. The parity test reports:

- `unmapped`: tests present in Go but absent from the manifest; and
- `stale`: manifest entries whose Go test no longer exists.

Do not delete a scoped Go implementation until every test assigned to its replacement module has an
equivalent deterministic test, replay fixture, or deliberately documented archive-only disposition.
