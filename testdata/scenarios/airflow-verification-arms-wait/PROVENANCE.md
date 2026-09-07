# Airflow verification scope

The initial event retains its bounded verification objective and now includes
the original Terraform notification from `context_9a9c4ac87f5e52330c266f277e234f22`,
episode `episode_run_9cbd448e67a15696c4453516482c57ac` in the retained Blitz ledger.
That manifest pins `blitz-infra` read-only at
`99183465ac95a33f1312a4f4973b66b736a55606`.

Two exact, line-numbered excerpts from that revision restore information the
old scenario omitted:

- `terraform/environments/production/app_datalake.tf:602–610`: Airflow's
  production Google Cloud container declaration.
- `terraform/environments/va1/apps/apps_datalake_server.tf:1–10`: Airflow is
  deliberately not ported to VA1 and remains in GCP.

Each excerpt records the SHA256 of its complete source file. These are supplied
source excerpts, not a claim that the evaluation worker has the whole checkout.
They establish repository intent and environment, never deployment success.
No later runtime observations are copied into the initial input.

`gcp.deployment` and `gcp.backend_health` are evaluation-only cassette facades,
not advertised Emisar or Google API names. They replace incorrectly named Nomad
facades while preserving the same harvested observations, source references,
argument checks and required verification calls. Monitoring still reports the
original missing application-telemetry boundary. Finding creation, bounded waits
and honest separation of verified health from unavailable evidence remain required.

The two scheduled entries are generic `wait_wakeup` opportunities, not a required
number of model turns. A durably settled `complete` episode skips any remaining
checkpoints and reports their original positions and timestamps separately from
executed turns. Every actual wait still requires exact active custody. Their historical
timestamps are provenance only, not a simulation clock or an instruction to
choose a resolution. Checkpoints carry no actor or authority. The simulator
snapshots the exact active subscription's persisted `poll_after`, then calls
the production `EventWaits.resume_at/3` transaction with that explicit time.
Production rechecks current custody and derives timer, source poll fallback, or
hard-deadline resolution from the stored wait. The saved submission supplies the
actual system actor; evaluation verifies its bound destination, source, wait
references, and empty external capabilities before assigning source-event authority.

The retained host replay still chooses source waits dated in 2099. Those model
outputs, matchers, source kinds, and later source observations remain unchanged;
they prove deterministic host mechanics, not realistic wait duration or fresh
model quality. Fresh models may choose a supported `after`, `at`, or source wait.
A separate harvested regression retains the real model's 10-minute `after`
decision and documents its clock/ID substitutions in
`test/responder/evals/fixtures/airflow_after_observation_window.PROVENANCE.md`.
Neither timer nor poll fallback impersonates a matching external source event.
World reports expose the historical scenario timestamp separately from the exact
persisted due time, actual source/actor/destination, and forced host routing.
Only wakeup inputs use that explicit simulated time. Record creation and tool
execution still use PostgreSQL wall time, including the anchor for each new
`after` timer. This is not a fully virtualized world clock and does not establish
monotonic due times across successive timers.

The mixed clock also prevents this fixture from qualifying fresh deployment or
health: source `observed_at` values remain August 27 while the ingress timestamp
is rebased. Cassette responses advance per tool call, not elapsed time. A uniform
timestamp shift would not solve this: the first observation is 33 minutes and
47 seconds after the original input, later than a ten-minute wake. Do not invent
fresh readings, expose future observations, or relabel stale evidence as current.
The retained quality rubric is unchanged; stopping after an inconclusive check
remains a separate model-quality question. The harvested completion regression
in `test/responder/evals/fixtures/airflow_completes_after_timer.json` qualifies only
terminal checkpoint mechanics, with the original failed report preserved.
