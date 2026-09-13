# Testing Responder

Responder has separate deterministic, model-evaluation, release, and live-acceptance boundaries.
No one command proves all four.

## Focused development tests

Run the owning ExUnit file while editing:

```bash
scripts/elixir-test.sh test/responder/work/executor_test.exs
```

Parallel PostgreSQL tests must use suite-owned conversation and workspace identities. Sandbox
rollback does not release transaction-scoped advisory locks until the test ends, so unrelated tests
must not reuse shared fixture identities. Do not increase production lock timeouts to hide fixture
collisions.

## Deterministic repository gates

Before committing, run:

```bash
make dev-check
```

It checks formatting, compilation warnings, Credo, migrations, and the whole ExUnit suite in a
freshly created test database, plus the control-plane JavaScript tests and ShellCheck. Nothing in
it calls a model. It is the gate for every commit and every deploy.

`make coverage` runs the suite with coverage instrumentation and writes the report under `cover/`.
It is not part of any gate.

`make eval-host-replay` runs the deterministic side of the checked-in scenario bundles with fake
Coop and inert delivery. It does not call a model or an external platform. The same files run
inside `make dev-check`; the standalone target isolates them in their own database.

For customer-facing Slack, incident, memory, or response-contract changes, run:

```bash
make customer-check
```

This adds the Elixir end-to-end customer journeys. Run only those journeys with
`make product-e2e` while iterating on a workflow.

The full deterministic gate is:

```bash
make check
```

It adds the isolated host replay, the watchdog and live-acceptance wrapper tests, the accelerated
thirty-day retention simulation, and the evaluation-trend script's self-test. CI runs it on every
push. Run it locally before a tagged release or when a change touches retention custody or the
release scripts, not before every deploy.

## Model evaluation

The current evaluation runners are owned by the Elixir runtime. Corpora can be compiled without
credentials:

```bash
MIX_ENV=test scripts/elixir-mix.sh responder.eval admission-pack
MIX_ENV=test scripts/elixir-mix.sh responder.eval work-pack
MIX_ENV=test scripts/elixir-mix.sh responder.eval world-pack
```

Admission and Work can be run through the isolated evaluation Coop daemon:

Evaluation authority is supplied explicitly through the evaluation environment and is refused
if it matches a reviewed production policy binding:

```bash
export RESPONDER_EVAL_SOCKET=/absolute/evaluation-coop/control.sock
export RESPONDER_EVAL_NO_TOOLS_POLICY=responder-eval-no-tools-v1
export RESPONDER_EVAL_NO_TOOLS_POLICY_DIGEST=SHA256
export RESPONDER_EVAL_WORLD_POLICY=responder-eval-world-v1
export RESPONDER_EVAL_WORLD_POLICY_DIGEST=SHA256
export RESPONDER_EVAL_WORLD_BASELINE_POLICY=responder-eval-world-baseline-v1
export RESPONDER_EVAL_WORLD_BASELINE_POLICY_DIGEST=SHA256
```

```bash
MIX_ENV=test scripts/elixir-mix.sh responder.eval admission
MIX_ENV=test scripts/elixir-mix.sh responder.eval work
```

The world evaluation exercises the real episode kernel, Work executor, lease-scoped state tools,
semantic repair, and inert evaluation delivery against checked-in deterministic worlds:

```bash
make eval-world-smoke
make eval-world
```

`eval-world-smoke` runs the representative smoke scenarios once. `eval-world` runs the complete
candidate and baseline matrix three times against the same deterministic worlds and enforces the
configured aggregate, per-case, paired-regression, hard-invariant, execution, and cleanup limits.

Both run through `scripts/elixir-world-eval.sh`, which splits the plan into shards that run at
once. The full matrix is 186 observations at about 93 seconds each; one VM ran them one after
another and took 4.8 hours. Each shard is its own `mix responder.eval world --shard I/N` VM on
its own campaign database and its own worker-gateway and state-tools ports (the configured
`RESPONDER_WORKER_PORT` and `RESPONDER_STATE_TOOLS_PORT` each advanced by two per shard, with the
port of `RESPONDER_WORKER_PUBLIC_URL` rewritten to match), running the slice it is dealt from the
same ordered plan: scenario/repeat pairs go round-robin, so a candidate and its baseline always
share a shard. `RESPONDER_WORLD_EVAL_SHARDS` (default 4, also a `make` variable) is the most
shards that run; `mix responder.eval world-shards` previews how many the plan fills, so
`--repeat 1 --case X` starts one VM, not four. A shard writes its results with no verdict, and
`mix responder.eval world-merge` joins the partial results into the one report — same shape,
same summary code, same thresholds and exit status as a single run — that the trend tooling reads.
Per-shard logs and partial results sit beside the report in `<report>.shards/`; a shard that
fails fails the run without a merge and leaves them there. Each shard holds a pool of ten
PostgreSQL connections, so the server the campaign databases live on must allow ten per shard
on top of whatever else is connected to it.

The YAML must configure dedicated `model_evals.socket`, `model_evals.no_tools_policy`, and
`model_evals.world_policy` values. The full paired gate also requires
`model_evals.world_baseline_policy`. These identities must be isolated from production policies and
repositories. The evaluation database must contain no pre-existing episodes. Each observation runs
against its own database, copied from the migrated campaign database its shard creates and always
drops, so no observation sees another's custody and a failed one never stops the rest of the plan.
An observation that passed drops its database; one that failed or faulted preserves it, and both
the shard and the merged run name it at the end for custody inspection.

Detailed reports are written mode `0600` under `$(EVAL_HISTORY)`, which defaults to
`~/.local/state/responder/eval-history`. Inspect the series with:

```bash
make eval-trend
```

Passing deterministic and model gates does not deploy the runtime.

## Release qualification

```bash
make release-check
```

This runs the deterministic gate, builds and inspects the immutable Elixir release, and exercises
the candidate against disposable PostgreSQL. Signing remains CI-only because keyless Sigstore uses
GitHub's OIDC identity.

## Live acceptance

Offline checks cannot prove that the current Slack workspace, Coop worker, provider account,
policies, and installed release agree. The opt-in acceptance lane runs from the immutable installed
Elixir release and posts only to an existing joined, non-Connect channel named `#test` or ending in
`-test`:

```bash
set -a
source ../emisar/.responder/local.env
set +a
make live-acceptance LIVE_CHANNEL=C0123TEST
```

The lane injects uniquely identified synthetic configured-operator inputs because a bot token
cannot impersonate a human. It does not start a second Slack socket or product runtime. The proof
requires two settled turns in one episode, one Coop session, the exact root thread, nonempty rendered
replies, and typed external receipts.

This automatic lane does not confirm offers or exercise mutating authority. Use the manual matrix at
`http://127.0.0.1:4321/manual-tests` for broader product qualification, and keep deployment and live
proof distinct in the handoff.
