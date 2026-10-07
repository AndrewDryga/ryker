.DEFAULT_GOAL := dev-check

.PHONY: retention-simulation product-e2e live-acceptance live-acceptance-wrapper-check eval-world-pack eval-world-smoke eval-world eval-routing-replay eval-improvement-replay eval-replay eval-trend customer-check elixir-test elixir-check coverage elixir-release elixir-release-check release-dist control-plane-js-check shellcheck watchdog-check launch-agent-check model-download-check deploy-check test-db-ready dev-check check release-check clean

LIVE_CHANNEL ?=
DEV_CHECK_JOBS ?= 4
EVAL_HISTORY ?= $(HOME)/.local/state/ryker/eval-history
# How many world-eval shards run at once; each is its own VM, campaign database
# and listener-port pair. Override with RYKER_WORLD_EVAL_SHARDS=8 on the
# make command line or in the environment.
RYKER_WORLD_EVAL_SHARDS ?= 4
export RYKER_WORLD_EVAL_SHARDS

# sha256sum on Linux, shasum on macOS; both print "<digest>  <file>".
sha256 = $$(command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo 'shasum -a 256')
# The release that elixir-release just built: the version Mix stamped into
# start_erl.data, its archive, and the archive's digest. Defined once for
# every target that qualifies or packages that archive.
built_release = version=$$(awk '{print $$2}' _build/prod/rel/ryker/releases/start_erl.data) && \
	archive="_build/prod/ryker-$$version.tar.gz" && \
	digest=$$($(sha256) "$$archive" | awk '{print $$1}')

$(EVAL_HISTORY):
	@mkdir -p "$@"

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
# Warnings fail it, as they fail the image build, so a warning only the
# production compile raises fails CI, not the deploy (2026-10-04 review).
elixir-release:
	@version=$$(scripts/elixir-release-version.sh); \
		rm -rf _build/prod/rel _build/prod/ryker-*.tar.gz; \
		export RYKER_ELIXIR_VERSION="$$version" MIX_ENV=prod; \
		scripts/elixir-mix.sh compile --warnings-as-errors && \
		scripts/elixir-mix.sh compile.app --force && \
		scripts/elixir-mix.sh release ryker --overwrite

elixir-release-check: elixir-release
	@$(built_release) && scripts/check-elixir-release.sh "$$archive" "$$version" "$$digest"

# The directory CI publishes: the archive under its public name and the
# checksum manifest the release workflow signs.
release-dist: elixir-release-check
	@$(built_release) && rm -rf dist && install -d -m 0755 dist && \
		install -m 0644 "$$archive" "dist/ryker_$${version}_elixir_linux_amd64.tar.gz" && \
		(cd dist && $(sha256) ryker_*_elixir_linux_amd64.tar.gz > checksums.txt) && \
		echo "release directory: dist/ryker_$${version}_elixir_linux_amd64.tar.gz"

product-e2e:
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
		test/ryker/schedules/schedules_test.exs \
		test/ryker/behaviors/automations_test.exs \
		test/ryker/memories/memories_test.exs \
		test/ryker/behaviors/behaviors_test.exs \
		test/ryker/coop_fleet/failover_end_to_end_test.exs \
		test/ryker/evals/world_runner_test.exs

# Runs inside the deployed ryker container against the installation's own
# durable settings; see docs/testing.md "Live acceptance".
live-acceptance:
	@test -n "$(LIVE_CHANNEL)" || { echo "LIVE_CHANNEL must be the joined Slack test channel ID"; exit 2; }
	scripts/elixir-live-acceptance.sh "$(LIVE_CHANNEL)"

live-acceptance-wrapper-check:
	scripts/elixir-live-acceptance_test.sh

eval-world-pack:
	MIX_ENV=test scripts/elixir-mix.sh ryker.eval world-pack

# Both world targets run through the sharded wrapper: RYKER_WORLD_EVAL_SHARDS
# VMs observe slices of one plan at once, and one merged report lands under
# $(EVAL_HISTORY) with the per-shard logs and partial results beside it in
# <report>.shards/. eval-world is the model release gate.
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

# Asks the routing decisions in a routing examples export again with today's
# prompt and contract (docs/testing.md, Routing replay). Needs the eval worker
# and RYKER_EVAL_ROUTING_TARGET; EXAMPLES is the export's absolute path.
eval-routing-replay: | $(EVAL_HISTORY)
	MIX_ENV=test scripts/elixir-mix.sh ryker.eval routing-replay \
		--examples "$(EXAMPLES)" \
		--results "$(EVAL_HISTORY)/routing-replay-$$(date -u +%Y%m%dT%H%M%SZ).json"

eval-improvement-replay: | $(EVAL_HISTORY)
	MIX_ENV=test scripts/elixir-mix.sh ryker.eval improvement-replay \
		--runs "$(RUNS)" \
		--results "$(EVAL_HISTORY)/improvement-replay-$$(date -u +%Y%m%dT%H%M%SZ).json"

# The deterministic side of the checked-in scenario bundles and the recorded
# repository-knowledge answers, in a database of its own: `make check` runs it
# beside the full suite, and sharing ryker_test once made four world cases
# reject their supposedly disposable database.
eval-replay:
	RYKER_TEST_ISOLATED=1 scripts/elixir-test.sh \
		test/ryker/episodes/replay_test.exs \
		test/ryker/evals/knowledge_judge_test.exs \
		test/ryker/evals/world_case_test.exs \
		test/ryker/evals/world_concurrency_test.exs \
		test/ryker/evals/world_coverage_test.exs \
		test/ryker/evals/world_runner_test.exs

customer-check: product-e2e eval-replay

eval-trend:
	scripts/eval-trend.sh "$(EVAL_HISTORY)"

control-plane-js-check:
	node --test test/js/*_test.mjs

# Every tracked shell file, the container entrypoints and install.sh included.
shellcheck:
	shellcheck $(shell git ls-files '*.sh')

# The script self-tests: each breaks its subject on purpose, against a fake
# control plane and a fake Docker, and watches it complain.
watchdog-check:
	scripts/watchdog_test.sh

launch-agent-check:
	scripts/launch-agent_test.sh

model-download-check:
	scripts/model-download_test.sh

deploy-check:
	scripts/deploy_test.sh

# A fresh Compose project cannot safely be created by two `up` processes at
# once. The full gate fans out two Elixir targets, so establish their shared
# PostgreSQL service before that fan-out; each target still gets its own DB.
# A Coop box has no Docker; Coop started the same service as its sidecar.
test-db-ready:
	if command -v docker >/dev/null 2>&1; then \
		docker compose --project-name ryker-kernel --file compose.test.yml up --detach --wait episode-db >/dev/null; \
	fi

# The commit and deploy gate: everything deterministic that the suite itself
# proves, minus the `slow` capacity tests, and nothing that is already inside
# it. The full gate runs the suite complete, the host replay again in its own
# database, the script self-tests, and the simulation.
dev-check:
	+$(MAKE) --no-print-directory -j$(DEV_CHECK_JOBS) ELIXIR_CHECK_ARGS="--exclude slow" \
		elixir-check control-plane-js-check shellcheck

check: test-db-ready
	+$(MAKE) --no-print-directory -j$(DEV_CHECK_JOBS) \
		elixir-check control-plane-js-check shellcheck eval-replay watchdog-check launch-agent-check model-download-check live-acceptance-wrapper-check deploy-check
	+$(MAKE) --no-print-directory retention-simulation
	scripts/test-eval-trend.sh

release-check: check elixir-release-check

clean:
	rm -rf dist _build cover
