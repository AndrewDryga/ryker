# Testing Ryker

Ryker has separate deterministic, model-evaluation, release, and live-acceptance boundaries.
No one command proves all four.

## Focused development tests

Run the owning ExUnit file while editing:

```bash
scripts/elixir-test.sh test/ryker/work/executor_test.exs
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
MIX_ENV=test scripts/elixir-mix.sh ryker.eval admission-pack
MIX_ENV=test scripts/elixir-mix.sh ryker.eval work-pack
MIX_ENV=test scripts/elixir-mix.sh ryker.eval world-pack
```

Admission and Work can be run through the isolated evaluation Coop daemon:

Evaluation authority is supplied explicitly through the evaluation environment and is refused
if it matches a reviewed production policy binding:

```bash
export RYKER_EVAL_SOCKET=/absolute/evaluation-coop/control.sock
export RYKER_EVAL_NO_TOOLS_POLICY=ryker-eval-no-tools-v1
export RYKER_EVAL_NO_TOOLS_POLICY_DIGEST=SHA256
export RYKER_EVAL_WORLD_POLICY=ryker-eval-world-v1
export RYKER_EVAL_WORLD_POLICY_DIGEST=SHA256
export RYKER_EVAL_WORLD_BASELINE_POLICY=ryker-eval-world-baseline-v1
export RYKER_EVAL_WORLD_BASELINE_POLICY_DIGEST=SHA256
```

```bash
MIX_ENV=test scripts/elixir-mix.sh ryker.eval admission
MIX_ENV=test scripts/elixir-mix.sh ryker.eval work
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
another and took 4.8 hours. Each shard is its own `mix ryker.eval world --shard I/N` VM on
its own campaign database and its own worker-gateway and state-tools ports (the configured
`RYKER_WORKER_PORT` and `RYKER_STATE_TOOLS_PORT` each advanced by two per shard, with the
port of `RYKER_WORKER_PUBLIC_URL` rewritten to match), running the slice it is dealt from the
same ordered plan: scenario/repeat pairs go round-robin, so a candidate and its baseline always
share a shard. `RYKER_WORLD_EVAL_SHARDS` (default 4, also a `make` variable) is the most
shards that run; `mix ryker.eval world-shards` previews how many the plan fills, so
`--repeat 1 --case X` starts one VM, not four. A shard writes its results with no verdict, and
`mix ryker.eval world-merge` joins the partial results into the one report — same shape,
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
`~/.local/state/ryker/eval-history`. Inspect the series with:

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
source ../emisar/.ryker/local.env
set +a
make live-acceptance LIVE_CHANNEL=C0123TEST
```

The lane injects uniquely identified synthetic configured-operator inputs because a bot token
cannot impersonate a human. It does not start a second Slack socket or product runtime. The proof
requires two settled turns in one episode, one Coop session, the exact root thread, nonempty rendered
replies, and typed external receipts.

This automatic lane does not confirm offers or exercise mutating authority. Use the manual
qualification journeys below for broader product qualification, and keep deployment and live proof
distinct in the handoff.

## Manual qualification

These are the user-boundary journeys that no automatic lane covers. Run them after the
deterministic gates, with disposable channels, repositories and records. A journey is complete only
when both the visible platform effect and its durable Episode/Work/Delivery record agree; the
control plane's request timeline is the record to check after every visible effect. Skip the
journeys whose integration is not configured in this installation.

- **Direct conversation** (`/conversations`): ask for a concise answer, then a follow-up that depends on it and
  confirm one conversation with continued episode lineage. Answer a material question and confirm
  the same task session resumes. Upload a bounded text file and an image, then ask for one generated
  image. React locally and confirm one additional post without Slack traffic. Confirm a harmless
  task, inspect its diff/timeline/evidence/handoff, and exercise readiness, explicit draft
  publication and the delivery check. Confirm a local incident and read its postmortem without a
  Slack room. Restart Ryker while work is pending and confirm custody resumes from PostgreSQL
  without a duplicate reply.
- **Slack threads, cards and emoji**: mention Ryker in an approved test channel and confirm the
  reply stays in the exact thread. Request a task and verify the host-owned offer card, its status
  and progress repaints, Stop, and idempotent button retries. React with configured Unicode and
  custom emoji and confirm one normalized reaction input with no bot-loop echo. Upload a bounded
  attachment and create an incident room; verify authenticated fetch, audience, topic, bookmarks
  and cleanup. Card design is reviewed offline through the Slack-card workflow in
  `.agent/kb/rules/slack-card-design-workflow.md`, not through a runtime preview page.
- **GitHub comments, reviews and reactions**: comment on a disposable issue and verify the reply
  binds to that issue, installation and repository. Request a PR review and verify summaries and
  inline review-thread replies use their exact targets. Add all eight native reactions and confirm
  normalized semantics with idempotent delivery. Edit and delete source comments and verify stable
  item revisions cannot move work to another episode.
- **Universal signed webhook**: send an authenticated JSON object with a unique occurrence ID and a
  stable item ID, using the signing recipe in `docs/elixir-ingress-admission.md`. Confirm the model
  reports observed fields without inventing vendor meaning. Replay the exact request, then a changed
  body under the same ID, and expect duplicate then conflict. Send revision 2 for the stable item and
  verify ownership remains with its original episode.
- **State tools and long-running work**: create evidence, progress, a required goal and a task offer,
  and confirm each typed record is visible exactly once. Offer a memory and a schedule, confirm them
  through their host pages, and verify recurrence and expiration. Exercise input and event waits;
  confirm no worker lease is held while waiting and only the exact trigger resumes. Force one
  semantic correction and one lost response; confirm same-turn repair and exactly-once delivery.
- **Recovery and retention**: restart after a frozen submit, an accepted result and a delivery send,
  and reconcile each exact operation without duplication. Stop running work and verify the exact
  remote turn is fenced before local cancellation settles. Complete work with clean, dirty and
  unmerged workspaces and verify close/discard/retain decisions and rearm controls. Restore a
  database dump into a disposable database and boot the same release against it.
- **Operator workbench**: verify an incident room links its source and investigation episodes,
  lifecycle observations, evidence and sanitized publication state; that a schedule's recurrence,
  authority, destination, next occurrence and dispatched/missed history agree with PostgreSQL; that
  channels and repositories show configuration, membership, continuity and serving worker revisions
  without fetching Git live; and that Configuration and Usage render only allowlisted values, grant
  names, effective models, corrections, tokens, cost and timing.
