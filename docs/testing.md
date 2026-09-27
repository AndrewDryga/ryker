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

It checks formatting, compilation warnings, Credo, migrations, and the ExUnit suite except slow
capacity tests in a freshly created test database, plus the control-plane JavaScript tests and
ShellCheck. Nothing in it calls a model. It is the gate for every commit and every deploy;
`make check` also runs the slow capacity tests.

`make coverage` runs the suite with coverage instrumentation and writes the report under `cover/`.
It is not part of any gate.

`make eval-replay` runs the deterministic side of the checked-in scenario bundles with fake
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

It adds the isolated host replay, the watchdog, deploy and live-acceptance script self-tests, the
accelerated thirty-day retention simulation, and the evaluation-trend script's self-test. CI runs it on every
push. Run it locally before a tagged release or when a change touches retention custody or the
release scripts, not before every deploy.

## Model evaluation

The evaluation runner is a Mix task. It, the `Ryker.Evals` modules and the local Unix-socket Coop
client they drive live in `evals/`, which compiles only in development and test; the release
check refuses an archive that carries any of them. The scenario corpus, with each scenario's exact
tool catalog, can be compiled without credentials:

```bash
MIX_ENV=test scripts/elixir-mix.sh ryker.eval world-pack
```

Use a dedicated evaluation worker enrolled with a separate, persistent evaluation controller,
never the production controller. `connect` starts the owner-private socket; the per-observation
gateway and disposable database are not the worker's enrollment controller:

```bash
coop sessions connect --controller https://eval-controller.example \
  --token-file /absolute/eval-worker-token --state /absolute/evaluation-coop
```

Provision the controller and enroll the worker separately before running evals. The harness does
not start that controller. The worker needs its own provider login and enough capacity for the
concurrent shards. Select model targets explicitly; the harness computes immutable job digests:

```bash
export RYKER_EVAL_SOCKET=/absolute/evaluation-coop/control.sock
export RYKER_EVAL_JUDGE_TARGET='<provider:model/effort@account>'
export RYKER_EVAL_WORLD_TARGET='<provider:model/effort@account>'
export RYKER_EVAL_BASELINE_TARGET='<provider:model/effort@account>'
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

The evaluation environment must name `RYKER_EVAL_SOCKET`, `RYKER_EVAL_JUDGE_TARGET` and
`RYKER_EVAL_WORLD_TARGET`; the paired gate also requires `RYKER_EVAL_BASELINE_TARGET`.
Every job has an empty read-only repository, no companions and no project environment or MCP.
Only subject turns receive the scenario controller tools; judges receive none. This does not
disable provider-native tools or internet access. Captured source excerpts are checked immutable
input artifacts, labelled with their provenance, not live repository checkouts.
No production settings are inherited. The evaluation database must be empty. Each observation runs
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

### Eval cases from feedback

Memory › Feedback › What to fix lists the requests people were unhappy with, each with Ryker's own
diagnosis of what went wrong (`Ryker.Improvement`). Accepting one keeps it as an eval case. GitHub
requests are analyzed too but cannot be accepted yet: a world scenario replays
Slack and Chat messages, and the export does not write GitHub events.
**Download eval cases** there, or `MIX_ENV=prod mix ryker.eval_cases --output DIR`, writes each
accepted case as a world scenario directory: `scenario.json`, `tool-catalog.json` (the standard
catalog, by reference), `routing.json` (each routing decision's exact prompt and answer) and
`PROVENANCE.md` (what happened, the diagnosis, and what is still to fill in).

The scenario holds the person's messages up to their first negative feedback as its events, with
Slack people, the workspace and channels renamed, and the diagnosis's expectation as its quality
rubric. Move a directory into `testdata/scenarios/`, fill in what its `PROVENANCE.md` lists (the
world's repositories and tool answers, hard and trajectory checks, the actors' authority, and a
recorded good answer with the `host-replay` tag if it should also run in `make eval-replay`), and
run it alone:

```bash
scripts/elixir-world-eval.sh ~/.local/state/ryker/eval-history/feedback.json \
  --case feedback-20260927-3f2a9c1b --repeat 1
```

## Release qualification

```bash
make release-check
```

This runs the deterministic gate, then builds the immutable Elixir release archive and checks it
structurally: the bytes match their trusted digest before anything is listed or extracted, every
path is safe, the executable, every migration in the tree and every operator asset in
`release-assets.txt` are present, no development dependency ships, and the migration entry point
boots. Signing remains CI-only because keyless Sigstore uses GitHub's OIDC identity. Neither
qualifies nor deploys the running installation; `scripts/deploy.sh` does that (see the project
instructions, "Finish by deploying").

## Live acceptance

Offline checks cannot prove that the current Slack workspace, Coop worker, provider account,
policies, and deployed release agree. The opt-in acceptance lane runs inside the deployed `ryker`
container, against the installation's own durable settings and database, and posts only to an
existing joined, non-Connect channel named `#test` or ending in `-test`:

```bash
make live-acceptance LIVE_CHANNEL=C0123TEST
```

`scripts/elixir-live-acceptance.sh` runs
`docker compose exec ryker /opt/ryker/bin/ryker eval 'Ryker.Acceptance.Live.run_from_env!()'`
with the channel and `RYKER_LIVE_TIMEOUT_SECONDS` (default 600) as the container's environment.
Nothing is copied out of `.ryker/compose.env`, no second Ryker runs, and the lane requires the
running release to report the version it was built as.

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
