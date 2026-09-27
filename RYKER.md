# RYKER.md

Written by Ryker from `e07c3c9` on 2026-09-27.

## Purpose

Ryker is a persistent engineering and operations teammate backed by isolated Coop sessions and governed Emisar access. Engineering teams use it through Slack, GitHub, webhooks, and a web console to answer questions, investigate incidents, change code, and prepare reviewed work. Its Elixir service keeps durable work and conversation state in PostgreSQL; Coop runs agents, and Emisar controls infrastructure authority.

## Components

- [lib/ryker/](lib/ryker/) — Elixir application, domain logic, integrations, and supervised runtime processes.
- [lib/ryker/ingress/](lib/ryker/ingress/) — Receives normalized inputs and maintains durable inbox custody.
- [lib/ryker/admission/](lib/ryker/admission/) — Decides how incoming inputs enter conversations and work.
- [lib/ryker/episodes/](lib/ryker/episodes/) — Platform-independent lifecycle kernel, event history, correlation, and replay.
- [lib/ryker/work/](lib/ryker/work/) — Builds agent submissions and manages durable sessions, turns, execution, and cancellation.
- [lib/ryker/delivery/](lib/ryker/delivery/) — Tracks and delivers accepted outputs to their platform destinations.
- [lib/ryker/slack/](lib/ryker/slack/) — Slack admission, interactions, rendering, and client integration.
- [lib/ryker/github/](lib/ryker/github/) — GitHub App integration for repository comments, reviews, and onboarding.
- [lib/ryker/webhooks/](lib/ryker/webhooks/) — Authenticated universal webhook and alert adapters.
- [lib/ryker/coop_fleet/](lib/ryker/coop_fleet/) — Manages enrolled remote workers and fleet execution.
- [lib/ryker/emisar/](lib/ryker/emisar/) — Integrates governed operational actions and approval tracking.
- [lib/ryker/control_plane/](lib/ryker/control_plane/) — Phoenix web console for conversations, activity, configuration, and operational inspection.
- [lib/ryker/state/](lib/ryker/state/) — Durable product records, including memory and conversation continuity.
- [lib/ryker/learning/](lib/ryker/learning/) — Background learning batches, execution, and memory rebuilding.
- [lib/ryker/publication/](lib/ryker/publication/) — Reviewed repository publication and GitHub draft PR workflows.
- [lib/ryker/evals/](lib/ryker/evals/) — Scenario execution, deterministic replay support, and model evaluation reporting.
- [lib/mix/tasks/](lib/mix/tasks/) — Operator diagnostics, replay, credential import, worker management, and evaluation commands.
- [config/](config/) — Compile-time, environment-specific, and runtime configuration.
- [priv/repo/](priv/repo/) — Ecto migrations and supporting SQL schema files.
- [priv/static/](priv/static/) — Control-plane JavaScript, CSS, fonts, and product artwork.
- [test/](test/) — ExUnit tests, integration fixtures, test support, and JavaScript tests.
- [testdata/](testdata/) — Recorded inputs, protocol fixtures, and scenario bundles.
- [scripts/](scripts/) — Toolchain wrappers, database-backed tests, evaluations, release qualification, deployment, and lifecycle helpers.
- [deploy/](deploy/) — Compose support, service-manager templates, proxy configuration, and Slack app configuration.
- [docs/](docs/) — Architecture contracts, testing guidance, operations, release procedures, and design documents.
- [site/](site/) — Static product website and user documentation.
- [brand/ryker/](brand/ryker/) — Ryker artwork and product-specific identity guidance.
- [.github/workflows/](.github/workflows/) — Pull-request and main-branch CI plus tag-triggered public releases.
- [.agent/kb/rules/](.agent/kb/rules/) — Repository rules referenced by contributor guidance, including branding and Slack-card review.
- [Makefile](Makefile) — Defines deterministic gates, evaluations, release builds, and qualification targets.
- [mix.exs](mix.exs) — Defines the OTP application, dependencies, and packaged Elixir release.
- [.tool-versions](.tool-versions) — Pins Erlang 28.4.1 and Elixir 1.19.5-otp-28.
- [Dockerfile](Dockerfile) — Builds the Elixir service into a runtime container.
- [compose.yml](compose.yml) — Defines the installation stack, including PostgreSQL, Ryker, and bundled Coop services.
- [compose.test.yml](compose.test.yml) — Provides disposable PostgreSQL for local deterministic tests.

## Build, test and run

- `./install.sh` — Installs and starts the Compose deployment; requires Docker Compose v2 and prints the local setup URL. From [README.md](README.md).
- `scripts/compose.sh status` — Shows the installed Compose stack's status. From [README.md](README.md).
- `scripts/compose.sh logs` — Reads logs from the Compose installation. From [README.md](README.md).
- `scripts/compose.sh restart` — Restarts the Compose installation. From [README.md](README.md).
- `scripts/elixir-test.sh test/ryker/work/executor_test.exs` — Runs an owning ExUnit file; the wrappers check the pinned toolchain, fetch missing dependencies, start test PostgreSQL, and migrate it. From [docs/testing.md](docs/testing.md).
- `make elixir-unit` — Runs tests without starting the application and excludes database-tagged tests. From [Makefile](Makefile).
- `make elixir-test` — Runs ExUnit against the shared test database. From [Makefile](Makefile).
- `make dev-check` — Pre-commit gate: formatting, warnings-as-errors, Credo, migrations, ExUnit excluding slow capacity tests, JavaScript tests, and ShellCheck; no model calls. From [Makefile](Makefile).
- `make check` — Full CI gate, including slow tests, isolated replay, script checks, retention simulation, and evaluation-trend self-test. From [Makefile](Makefile).
- `make customer-check` — Runs product journeys and deterministic host replay. From [Makefile](Makefile).
- `make product-e2e` — Runs the selected end-to-end product journeys. From [Makefile](Makefile).
- `make eval-replay` — Runs deterministic episode and evaluation replay tests in an isolated database. From [Makefile](Makefile).
- `make control-plane-js-check` — Runs the control-plane JavaScript tests with Node's test runner. From [Makefile](Makefile).
- `make coverage` — Runs ExUnit with coverage instrumentation and writes a report under cover. From [Makefile](Makefile).
- `make eval-world-pack` — Compiles the scenario corpus and tool catalogs without model credentials. From [Makefile](Makefile).
- `make eval-world-smoke` — Runs representative model scenarios once; requires dedicated evaluation Coop policies and environment. From [Makefile](Makefile).
- `make eval-world` — Runs the full paired candidate/baseline model matrix with dedicated evaluation policies and regression limits. From [Makefile](Makefile).
- `make elixir-release` — Builds the production Elixir release with an exact Git-derived version. From [Makefile](Makefile).
- `make elixir-release-check` — Builds and validates the release archive. From [Makefile](Makefile).
- `make elixir-candidate-check` — Qualifies the release against disposable PostgreSQL, including migrations, restart, backup, and restore. From [Makefile](Makefile).
- `make release-check` — Runs the full deterministic gate and release candidate qualification. From [Makefile](Makefile).
- `make live-acceptance LIVE_CHANNEL=C0123TEST` — Runs opt-in acceptance from an installed release against a joined Slack test channel after loading the deployment environment. From [docs/testing.md](docs/testing.md).

## Deploy and release

- Run make dev-check before committing. Run make check for tagged releases and changes to retention custody or release scripts. From [AGENTS.md](AGENTS.md).
- For the configured host deployment, commit first and run scripts/deploy.sh from a clean tree. It qualifies the archive and rehearses pending migrations on a restored live backup before replacing the service. From [scripts/deploy.sh](scripts/deploy.sh).
- The host deploy installs an immutable release, updates current, restarts systemd or launchd, and verifies health, readiness, and the exact running version. From [scripts/deploy.sh](scripts/deploy.sh).
- For a public release, start from clean, current main, run make release-check, finalize the top changelog section, commit it, and create an annotated semantic-version tag. From [docs/releasing.md](docs/releasing.md).
- Obtain explicit confirmation before publication, then push main and the version tag separately. Never rewrite a published tag or its assets. From [docs/releasing.md](docs/releasing.md).
- A v* tag triggers the release workflow, which checks main ancestry and release notes, runs the full gate, builds the Linux amd64 archive, signs checksums, records provenance, and publishes the verified GitHub Release. From [.github/workflows/release.yml](.github/workflows/release.yml).
- Public artifact publication does not automatically deploy production; an operator installs and configures the target deployment. From [docs/releasing.md](docs/releasing.md).
- The documented Compose lifecycle starts with ./install.sh; use scripts/compose.sh backup before scripts/compose.sh upgrade, then verify readiness and the running version. From [docs/operations.md](docs/operations.md).

## Conventions

- Use Ryker naming, supplied artwork, and mint; consult the referenced brand rules before UI, naming, or branding changes. From [AGENTS.md](AGENTS.md).
- For Slack-card changes, follow both Slack design rules, reuse native payloads, validate the Builder envelope, and include fresh direct Builder links. From [AGENTS.md](AGENTS.md).
- Replace pre-v1 interfaces completely: update callers, tests, links, and docs together without compatibility aliases or dual paths; preserve historical data. From [AGENTS.md](AGENTS.md).
- Run the owning test after each code change and one dev-check on the final tree before committing. From [AGENTS.md](AGENTS.md).
- Production fixes need a regression test proven to fail before the fix; assert behavior, name the invariant, and explain the defect's cost. From [AGENTS.md](AGENTS.md).
- Harvest model fixtures from real recorded results and prompts; do not invent them. Deterministic tests must not call models. From [AGENTS.md](AGENTS.md).
- Test host mishandling with ExUnit; evaluate model-output problems with world evaluations. Use the smoke evaluation for prompt wording and the full matrix for contract or schema changes. From [AGENTS.md](AGENTS.md).
- Run live integration acceptance only when the changed boundary requires it; keep preview, test, deployment, and live evidence distinct. From [AGENTS.md](AGENTS.md).
- Commit and deploy completed changes; report precisely which version is running rather than equating a green gate with deployment. From [AGENTS.md](AGENTS.md).
- Production Coop workers are enrolled and upgraded independently; Ryker host deployment must not install or restart them. From [AGENTS.md](AGENTS.md).

## Where to look

- Understand lifecycle ownership and episode transitions: [docs/elixir-episode-kernel.md](docs/elixir-episode-kernel.md)
- Change ingress routing or admission: [docs/elixir-ingress-admission.md](docs/elixir-ingress-admission.md)
- Understand agent execution and recovery: [docs/elixir-work-runtime.md](docs/elixir-work-runtime.md)
- Change an agent's Work prompt: [lib/ryker/work/prompt.ex](lib/ryker/work/prompt.ex)
- Add a database migration: [priv/repo/migrations/](priv/repo/migrations/)
- Change the web console: [lib/ryker/control_plane/](lib/ryker/control_plane/)
- Change browser behavior or styles: [priv/static/](priv/static/)
- Change Slack cards: [lib/ryker/slack/renderer/](lib/ryker/slack/renderer/)
- Configure Slack scopes and app capabilities: [deploy/slack-app-manifest.yaml](deploy/slack-app-manifest.yaml)
- Change GitHub comments or review handling: [lib/ryker/github/](lib/ryker/github/)
- Change webhook mappings: [docs/webhooks.md](docs/webhooks.md)
- Change repository publication: [lib/ryker/publication/](lib/ryker/publication/)
- Understand retained memory and learning: [docs/memory-implementation-spec.md](docs/memory-implementation-spec.md)
- Add or inspect evaluation scenarios: [testdata/scenarios/](testdata/scenarios/)
- Choose the appropriate test gate: [docs/testing.md](docs/testing.md)
- Inspect remote-worker behavior: [lib/ryker/coop_fleet/](lib/ryker/coop_fleet/)
- Operate, back up, or restore an installation: [docs/operations.md](docs/operations.md)
- Prepare a public release: [docs/releasing.md](docs/releasing.md)
- Change service startup and supervision: [lib/ryker/application.ex](lib/ryker/application.ex)
- Update public product documentation: [site/docs/](site/docs/)

## Open questions

- What is the supported publication path for the Compose release directory and container images? README.md describes that installation, but the checked-in release workflow publishes Elixir archives and installation helpers.
- What is the recommended source-development console startup procedure? Test setup is automated, but config/dev.exs disables the runtime owner and the main setup documentation focuses on Compose.
