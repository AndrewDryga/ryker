.DEFAULT_GOAL := dev-check

.PHONY: retention-simulation product-e2e elixir-product-e2e live-acceptance live-acceptance-wrapper-check eval-world-pack eval-world-smoke eval-world eval-host-replay eval-replay model-release-check eval-trend customer-check elixir-unit elixir-test elixir-check coverage elixir-release elixir-release-check elixir-install elixir-activate elixir-candidate-check control-plane-js-check shellcheck watchdog-check test-db-ready dev-check check release-check clean

ELIXIR_INSTALL_PREFIX ?= $(HOME)/.local/lib/ryker-elixir
RYKER_ELIXIR_RELEASE ?= $(ELIXIR_INSTALL_PREFIX)/current/bin/ryker
ELIXIR_VERSION ?=
LIVE_CHANNEL ?=
DEV_CHECK_JOBS ?= 4
EVAL_HISTORY ?= $(HOME)/.local/state/ryker/eval-history
# How many world-eval shards run at once; each is its own VM, campaign database
# and listener-port pair. Override with RYKER_WORLD_EVAL_SHARDS=8 on the
# make command line or in the environment.
RYKER_WORLD_EVAL_SHARDS ?= 4
export RYKER_WORLD_EVAL_SHARDS

$(EVAL_HISTORY):
	@mkdir -p "$@"

elixir-unit:
	MIX_ENV=test scripts/elixir-mix.sh test --no-start --exclude database $(ELIXIR_TEST)

elixir-test:
	scripts/elixir-test.sh $(ELIXIR_TEST)

# Thirty accelerated days of workspace cleanup through real custody; minutes, not
# hours, and deliberately outside the fast gate. Evidence lands in artifacts/.
retention-simulation:
	RYKER_TEST_ISOLATED=1 scripts/elixir-test.sh --include simulation \
		test/ryker/retention/thirty_day_simulation_test.exs

# ELIXIR_CHECK_ARGS is how dev-check leaves the `slow` capacity tests to the
# full gate; `make check` runs the same target with nothing excluded.
elixir-check:
	RYKER_TEST_ISOLATED=1 scripts/elixir-test.sh --check $(ELIXIR_CHECK_ARGS)

# Coverage instrumentation slows the suite and gates nothing; run it on demand.
coverage:
	RYKER_TEST_ISOLATED=1 scripts/elixir-test.sh --cover

# Incremental: only changed modules recompile. The version lives in the .app
# file, and Mix only rewrites that when mix.exs or the ebin directory changed,
# so compile.app is forced to stamp the exact commit — in its own invocation,
# because inside one `mix do` chain a task that already ran is skipped and the
# release then carried the previous commit's version. Previous release trees
# and archives are dropped first; a hundred of them once grew to two gigabytes.
elixir-release:
	@version=$$(scripts/elixir-release-version.sh); \
		rm -rf _build/prod/rel _build/prod/ryker-*.tar.gz; \
		export RYKER_ELIXIR_VERSION="$$version" MIX_ENV=prod; \
		scripts/elixir-mix.sh compile && \
		scripts/elixir-mix.sh compile.app --force && \
		scripts/elixir-mix.sh release ryker --overwrite

elixir-release-check: elixir-release
	@version=$$(awk '{print $$2}' _build/prod/rel/ryker/releases/start_erl.data); \
		archive="_build/prod/ryker-$$version.tar.gz"; \
		digest=$$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$archive" | awk '{print $$1}'; else shasum -a 256 "$$archive" | awk '{print $$1}'; fi); \
		scripts/check-elixir-release.sh "$$archive" "$$version" "$$digest"

elixir-install: elixir-release-check
	@version=$$(awk '{print $$2}' _build/prod/rel/ryker/releases/start_erl.data); \
		archive="_build/prod/ryker-$$version.tar.gz"; \
		digest=$$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$archive" | awk '{print $$1}'; else shasum -a 256 "$$archive" | awk '{print $$1}'; fi); \
		scripts/install-elixir-release.sh "$$archive" "$$version" "$$digest" "$(ELIXIR_INSTALL_PREFIX)" --local-build

elixir-activate:
	@test -n "$(ELIXIR_VERSION)" || { echo "ELIXIR_VERSION is required" >&2; exit 2; }
	scripts/activate-elixir-release.sh "$(ELIXIR_INSTALL_PREFIX)" "$(ELIXIR_VERSION)"

elixir-candidate-check: elixir-release-check
	@version=$$(awk '{print $$2}' _build/prod/rel/ryker/releases/start_erl.data); \
		archive="_build/prod/ryker-$$version.tar.gz"; \
		digest=$$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$archive" | awk '{print $$1}'; else shasum -a 256 "$$archive" | awk '{print $$1}'; fi); \
		scripts/check-elixir-candidate.sh "$$archive" "$$version" "$$digest"

elixir-product-e2e:
	scripts/elixir-test.sh \
		test/ryker/acceptance/live_test.exs \
		test/ryker/control_plane/conversation_lab_end_to_end_test.exs \
		test/ryker/control_plane/router_test.exs \
		test/ryker/slack/end_to_end_test.exs \
		test/ryker/slack/question_end_to_end_test.exs \
		test/ryker/slack/artifact_end_to_end_test.exs \
		test/ryker/slack/task_end_to_end_test.exs \
		test/ryker/slack/incident_rooms_test.exs \
		test/ryker/github/end_to_end_test.exs \
		test/ryker/webhooks/end_to_end_test.exs \
		test/ryker/emisar/end_to_end_test.exs \
		test/ryker/state/schedules_test.exs \
		test/ryker/state/automations_test.exs \
		test/ryker/state/memories_test.exs \
		test/ryker/state/behaviors_test.exs \
		test/ryker/coop_fleet/failover_end_to_end_test.exs \
		test/ryker/evals/world_runner_test.exs

product-e2e: elixir-product-e2e

live-acceptance:
	@test -n "$(LIVE_CHANNEL)" || { echo "LIVE_CHANNEL must be the joined Slack test channel ID"; exit 2; }
	RYKER_ELIXIR_RELEASE="$(RYKER_ELIXIR_RELEASE)" \
		scripts/elixir-live-acceptance.sh "$(LIVE_CHANNEL)"

live-acceptance-wrapper-check:
	scripts/elixir-live-acceptance_test.sh

eval-world-pack:
	MIX_ENV=test scripts/elixir-mix.sh ryker.eval world-pack

# Both world targets run through the sharded wrapper: RYKER_WORLD_EVAL_SHARDS
# VMs observe slices of one plan at once, and one merged report lands under
# $(EVAL_HISTORY) with the per-shard logs and partial results beside it in
# <report>.shards/.
eval-world-smoke: | $(EVAL_HISTORY)
	scripts/elixir-world-eval.sh \
		"$(EVAL_HISTORY)/world-smoke-$$(date -u +%Y%m%dT%H%M%SZ).json" \
		--tag smoke --repeat 1 \
		--min-overall-pass-rate 1 --min-case-pass-rate 1

eval-world: | $(EVAL_HISTORY)
	scripts/elixir-world-eval.sh \
		"$(EVAL_HISTORY)/world-$$(date -u +%Y%m%dT%H%M%SZ).json" \
		--repeat 3 --paired-baseline \
		--min-overall-pass-rate 0.9 --min-case-pass-rate 0.6666666666666666 \
		--max-paired-regression 0.1

model-release-check: eval-world

eval-host-replay:
	RYKER_TEST_ISOLATED=1 scripts/elixir-test.sh \
		test/ryker/episodes/replay_test.exs \
		test/ryker/evals/world_case_test.exs \
		test/ryker/evals/world_concurrency_test.exs \
		test/ryker/evals/world_coverage_test.exs \
		test/ryker/evals/world_runner_test.exs

eval-replay: eval-host-replay

customer-check: product-e2e eval-replay

eval-trend:
	scripts/eval-trend.sh "$(EVAL_HISTORY)"

control-plane-js-check:
	node --test test/js/*_test.mjs

shellcheck:
	shellcheck scripts/*.sh

watchdog-check:
	scripts/watchdog_test.sh

# A fresh Compose project cannot safely be created by two `up` processes at
# once. The full gate fans out two Elixir targets, so establish their shared
# PostgreSQL service before that fan-out; each target still gets its own DB.
test-db-ready:
	docker compose --project-name ryker-kernel --file compose.test.yml up --detach --wait episode-db >/dev/null

# The commit and deploy gate: everything deterministic that the suite itself
# proves, minus the `slow` capacity tests, and nothing that is already inside
# it. The full gate runs the suite complete, the host replay again in its own
# database, the script self-tests, and the simulation.
dev-check:
	+$(MAKE) --no-print-directory -j$(DEV_CHECK_JOBS) ELIXIR_CHECK_ARGS="--exclude slow" \
		elixir-check control-plane-js-check shellcheck

check: test-db-ready
	+$(MAKE) --no-print-directory -j$(DEV_CHECK_JOBS) \
		elixir-check control-plane-js-check shellcheck eval-replay watchdog-check live-acceptance-wrapper-check
	+$(MAKE) --no-print-directory retention-simulation
	scripts/test-eval-trend.sh

release-check: check elixir-candidate-check

clean:
	rm -rf dist _build cover
