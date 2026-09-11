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

It checks the Elixir release-build boundary, formatting, compilation warnings, Credo, migrations,
ExUnit coverage, deterministic host replay, control-plane JavaScript, shell scripts, and the
watchdog.

`make eval-host-replay` runs the deterministic side of the checked-in scenario bundles with fake
Coop and inert delivery. It does not call a model or an external platform.

For customer-facing Slack, incident, memory, or response-contract changes, run:

```bash
make customer-check
```

This adds the Elixir end-to-end customer journeys. Run only those journeys with
`make product-e2e` while iterating on a workflow.

The broader deterministic gate is:

```bash
make check
```

It adds the evaluation-trend script's deterministic self-test used by CI and release qualification.

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

The YAML must configure dedicated `model_evals.socket`, `model_evals.no_tools_policy`, and
`model_evals.world_policy` values. The full paired gate also requires
`model_evals.world_baseline_policy`. These identities must be isolated from production policies and
repositories. The evaluation database must contain no pre-existing episodes. Successful runs drop
their database; failed runs preserve and name it for custody inspection.

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
