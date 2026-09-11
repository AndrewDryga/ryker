.DEFAULT_GOAL := dev-check

.PHONY: retention-simulation product-e2e elixir-product-e2e live-acceptance live-acceptance-wrapper-check eval-world-pack eval-world-smoke eval-world eval-host-replay eval-replay model-release-check eval-trend customer-check elixir-unit elixir-test elixir-check elixir-release elixir-release-check elixir-install elixir-activate elixir-candidate-check control-plane-js-check shellcheck watchdog-check dev-check check release-check clean

ELIXIR_INSTALL_PREFIX ?= $(HOME)/.local/libexec/responder
RESPONDER_ELIXIR_RELEASE ?= $(ELIXIR_INSTALL_PREFIX)/current/bin/responder
ELIXIR_VERSION ?=
LIVE_CHANNEL ?=
DEV_CHECK_JOBS ?= 4
EVAL_HISTORY ?= $(HOME)/.local/state/responder/eval-history

$(EVAL_HISTORY):
	@mkdir -p "$@"

elixir-unit:
	MIX_ENV=test scripts/elixir-mix.sh test --no-start --exclude database $(ELIXIR_TEST)

elixir-test:
	scripts/elixir-test.sh $(ELIXIR_TEST)

# Thirty accelerated days of workspace cleanup through real custody; minutes, not
# hours, and deliberately outside the fast gate. Evidence lands in artifacts/.
retention-simulation:
	RESPONDER_TEST_ISOLATED=1 scripts/elixir-test.sh --include simulation \
		test/responder/retention/thirty_day_simulation_test.exs

elixir-check:
	bash scripts/test-release-build-isolation.sh
	RESPONDER_TEST_ISOLATED=1 scripts/elixir-test.sh --check

elixir-release:
	@version=$$(scripts/elixir-release-version.sh); \
		RESPONDER_ELIXIR_VERSION="$$version" MIX_ENV=prod \
		scripts/elixir-mix.sh do clean --only prod + release responder --overwrite

elixir-release-check: elixir-release
	@version=$$(awk '{print $$2}' _build/prod/rel/responder/releases/start_erl.data); \
		archive="_build/prod/responder-$$version.tar.gz"; \
		digest=$$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$archive" | awk '{print $$1}'; else shasum -a 256 "$$archive" | awk '{print $$1}'; fi); \
		scripts/check-elixir-release.sh "$$archive" "$$version" "$$digest"

elixir-install: elixir-release-check
	@version=$$(awk '{print $$2}' _build/prod/rel/responder/releases/start_erl.data); \
		archive="_build/prod/responder-$$version.tar.gz"; \
		digest=$$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$archive" | awk '{print $$1}'; else shasum -a 256 "$$archive" | awk '{print $$1}'; fi); \
		scripts/install-elixir-release.sh "$$archive" "$$version" "$$digest" "$(ELIXIR_INSTALL_PREFIX)" --local-build

elixir-activate:
	@test -n "$(ELIXIR_VERSION)" || { echo "ELIXIR_VERSION is required" >&2; exit 2; }
	scripts/activate-elixir-release.sh "$(ELIXIR_INSTALL_PREFIX)" "$(ELIXIR_VERSION)"

elixir-candidate-check: elixir-release-check
	@version=$$(awk '{print $$2}' _build/prod/rel/responder/releases/start_erl.data); \
		archive="_build/prod/responder-$$version.tar.gz"; \
		digest=$$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$archive" | awk '{print $$1}'; else shasum -a 256 "$$archive" | awk '{print $$1}'; fi); \
		scripts/check-elixir-candidate.sh "$$archive" "$$version" "$$digest"

elixir-product-e2e:
	scripts/elixir-test.sh \
		test/responder/acceptance/live_test.exs \
		test/responder/control_plane/conversation_lab_end_to_end_test.exs \
		test/responder/control_plane/router_test.exs \
		test/responder/slack/end_to_end_test.exs \
		test/responder/slack/question_end_to_end_test.exs \
		test/responder/slack/artifact_end_to_end_test.exs \
		test/responder/slack/task_end_to_end_test.exs \
		test/responder/slack/incident_rooms_test.exs \
		test/responder/github/end_to_end_test.exs \
		test/responder/webhooks/end_to_end_test.exs \
		test/responder/emisar/end_to_end_test.exs \
		test/responder/state/schedules_test.exs \
		test/responder/state/automations_test.exs \
		test/responder/state/memories_test.exs \
		test/responder/state/behaviors_test.exs \
		test/responder/coop_fleet/failover_end_to_end_test.exs \
		test/responder/evals/world_runner_test.exs

product-e2e: elixir-product-e2e

live-acceptance:
	@test -n "$(LIVE_CHANNEL)" || { echo "LIVE_CHANNEL must be the joined Slack test channel ID"; exit 2; }
	RESPONDER_ELIXIR_RELEASE="$(RESPONDER_ELIXIR_RELEASE)" \
		scripts/elixir-live-acceptance.sh "$(LIVE_CHANNEL)"

live-acceptance-wrapper-check:
	scripts/elixir-live-acceptance_test.sh

eval-world-pack:
	MIX_ENV=test scripts/elixir-mix.sh responder.eval world-pack

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
	RESPONDER_TEST_ISOLATED=1 scripts/elixir-test.sh \
		test/responder/episodes/replay_test.exs \
		test/responder/evals/world_case_test.exs \
		test/responder/evals/world_concurrency_test.exs \
		test/responder/evals/world_coverage_test.exs \
		test/responder/evals/world_runner_test.exs

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

dev-check:
	+$(MAKE) --no-print-directory -j$(DEV_CHECK_JOBS) elixir-check control-plane-js-check eval-replay shellcheck watchdog-check live-acceptance-wrapper-check

check: dev-check retention-simulation
	scripts/test-eval-trend.sh

release-check: check elixir-candidate-check

clean:
	rm -rf dist _build cover
