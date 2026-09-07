.DEFAULT_GOAL := dev-check

.PHONY: eval-prompts findings-coverage findings-coverage-check watchdog-check promote-corrections build install test product-e2e elixir-product-e2e live-acceptance eval eval-health eval-quality eval-judge-calibration eval-proactive eval-scenarios eval-world-pack eval-world-smoke eval-world eval-host-replay eval-evidence eval-productivity eval-memory eval-episode-replay eval-regressions eval-live-canary eval-trend eval-baseline-update model-release-check eval-replay customer-check focus elixir-unit elixir-test elixir-check elixir-release elixir-release-check elixir-install elixir-activate elixir-candidate-check dev-workflow-check dev-check candidate canary promote quality-watch-check eval-trend-check race lint tidy-check actionlint staticcheck vulncheck check snapshot release-check clean

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X github.com/AndrewDryga/responder/internal/version.Version=$(VERSION)
INSTALL_DIR ?= $(HOME)/.local/bin
ELIXIR_INSTALL_PREFIX ?= $(HOME)/.local/libexec/responder
RESPONDER_ELIXIR_RELEASE ?= $(ELIXIR_INSTALL_PREFIX)/current/bin/responder
ELIXIR_VERSION ?=
CONFIG ?= .responder/responder.yaml
LIVE_CHANNEL ?=
EVAL_REPEAT ?= 3
TASK_EVAL_POLICY ?=
WORLD_EVAL_DATABASE ?=
FOCUS_PACKAGE ?=
FOCUS_TEST ?=
DEV_CHECK_JOBS ?= 4
CHECK_JOBS ?= 4

# Where a model evaluation leaves its result, and where make eval-trend reads
# them back.
#
# The judges were already running and already scoring. Three of them — the
# quality rubric, the evidence verifier, and the judge-the-judge calibration —
# computed a number per case and then threw it away, because --results was
# passed by nothing but a unit test and two doc examples, and CI reads only the
# exit code. Every release could say "the gate passed" and none of them could
# say whether the answers were getting better or worse.
#
# Outside the repository on purpose: a result carries sanitized model output and
# is written mode 0600, so it is private state, not a checked-in artifact. This
# directory is never pruned automatically — deleting evaluation evidence on a
# timer is how you lose the only record of when a regression started. It grows
# by roughly one file per model evaluation; prune it by hand.
EVAL_HISTORY ?= $(HOME)/.local/state/responder/eval-history

# One results file per run, named for the target that produced it so the trend
# can group them, and stamped so it can order them.
#
# The stamp is taken in the recipe rather than at parse time. A parse-time
# $(shell date) is the moment make started, so model-release-check — which is
# eight credentialed evaluations and can run for an hour — would file every one
# of them under the same instant and lose the order they actually ran in.
history = --results "$(EVAL_HISTORY)/$(1)-$$(date -u +%Y%m%dT%H%M%SZ).json"

# Where the reviewed numbers live, and how a run is held to them.
#
# eval-trend prints a table; a table is not a gate. MaxBaselineRegression had
# existed in EvaluationGateOptions for months with no target passing --baseline,
# so nothing in this repository could fail because quality dropped — only
# because it fell under an absolute floor that was set once and never moved.
#
# A baseline is a committed file, so a regression is a diff someone approved and
# never drift. $(call baseline,NAME) is empty when testdata/eval/baselines/NAME.json
# does not exist yet, which is how a corpus that has never recorded one still
# runs its ordinary thresholds instead of failing to open a missing file.
# TestACommittedBaselineNamesCasesTheCorpusStillHas keeps a recorded one honest
# offline, so a stale baseline is a dev-check failure rather than an hour of
# credentialed evaluation ending in "corpus digest does not match".
#
# Two tolerances because they are two units. Pass rates are 0 to 1; the judge
# scores 1 to 5, and 0.05 of a judge point is noise rather than a regression.
EVAL_BASELINES = testdata/eval/baselines
MAX_REGRESSION ?= 0.1
MAX_QUALITY_REGRESSION ?= 0.3
baseline = $(if $(wildcard $(EVAL_BASELINES)/$(1).json),--baseline $(EVAL_BASELINES)/$(1).json \
	--max-regression $(MAX_REGRESSION) --max-quality-regression $(MAX_QUALITY_REGRESSION))

$(EVAL_HISTORY):
	@mkdir -p "$@"

build:
	go build -trimpath -ldflags "$(LDFLAGS)" -o bin/responder ./cmd/responder

install:
	install -d "$(INSTALL_DIR)"
	go build -trimpath -ldflags "$(LDFLAGS)" -o "$(INSTALL_DIR)/responder" ./cmd/responder
	@echo "installed $(INSTALL_DIR)/responder ($(VERSION))"

test:
	go test ./...

elixir-unit:
	MIX_ENV=test scripts/elixir-mix.sh test --no-start --exclude database $(ELIXIR_TEST)

elixir-test:
	scripts/elixir-test.sh $(ELIXIR_TEST)

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
		scripts/check-elixir-candidate.sh \
		"$$archive" "$$version" "$$digest" \
		"testdata/release/responder-component.yaml"

quality-watch-check:
	scripts/quality-watch.sh --help >/dev/null
	jq -e '.type == "object" and .additionalProperties == false' scripts/quality-watch-assessment.schema.json >/dev/null
	jq -e '.type == "object" and .additionalProperties == false' scripts/quality-watch-fix-review.schema.json >/dev/null
	scripts/test-quality-watch.sh

eval-trend-check:
	scripts/test-eval-trend.sh

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
		scripts/elixir-live-acceptance.sh "$(abspath $(CONFIG))" "$(LIVE_CHANNEL)"

eval: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/live.jsonl \
		$(call history,live)

# Health verdicts are blitz-shaped: every case names blitz-infra, and only the
# blitz deployment configures it. Running this against emisar failed every case
# one model call at a time, reporting a missing config key as a provider
# refusal — so the corpus had never run anywhere. DEPLOYMENT is declared for the
# same reason eval-episode-replay declares it, and the eval command refuses the
# corpus up front rather than discovering it per case.
eval-health: DEPLOYMENT = blitz
eval-health: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/health-verdict.jsonl --judge \
		$(call history,health-$(DEPLOYMENT))

# A tolerance is set per target because the repeats are set per target.
#
# One sample of a two-repeat case is half its rate, so a per-case comparison at
# 0.1 fails the release for the ordinary run-to-run variance REGRESSION_REPEAT
# exists to absorb. On the judged corpora the signal that survives that noise is
# the judge mean over every sample, which is why those targets carry a loose
# rate tolerance and lean on --max-quality-regression; the unjudged corpora run
# one sample per case, where a rate that moved is a case that flipped.
eval-quality: MAX_REGRESSION = 0.5
eval-quality: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/live.jsonl --judge --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 --min-mean-quality 4 \
		$(call baseline,quality) $(call history,quality)

eval-judge-calibration: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/quality-calibration.jsonl --calibrate-judge \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 \
		$(call baseline,judge-calibration) $(call history,judge-calibration)

eval-proactive: MAX_REGRESSION = 0.34
eval-proactive: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/proactive.jsonl --repeat "$(EVAL_REPEAT)" \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.67 \
		--min-proactive-precision 0.90 --min-proactive-recall 0.90 \
		--max-false-interruption-rate 0.10 \
		$(call baseline,proactive) $(call history,proactive)

eval-scenarios: MAX_REGRESSION = 0.5
eval-scenarios: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/scenarios.jsonl --scenarios --judge --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 \
		--min-proactive-precision 0.90 --min-proactive-recall 0.90 \
		--max-false-interruption-rate 0.10 --min-mean-quality 4 \
		$(call baseline,scenarios) $(call history,scenarios)

eval-world-pack:
	MIX_ENV=test mix responder.eval world-pack

# This lane creates and drops its own uniquely named PostgreSQL database. The
# runner also refuses any pre-existing application row before granting a model
# a state capability.
eval-world-smoke: | $(EVAL_HISTORY)
	scripts/elixir-world-eval.sh "$(abspath $(CONFIG))" \
		"$(EVAL_HISTORY)/world-smoke-$$(date -u +%Y%m%dT%H%M%SZ).json" \
		--tag smoke --repeat 1 \
		--min-overall-pass-rate 1 --min-case-pass-rate 1

eval-world: | $(EVAL_HISTORY)
	scripts/elixir-world-eval.sh "$(abspath $(CONFIG))" \
		"$(EVAL_HISTORY)/world-$$(date -u +%Y%m%dT%H%M%SZ).json" \
		--repeat 3 --paired-baseline \
		--min-overall-pass-rate 0.9 --min-case-pass-rate 0.6666666666666666 \
		--max-paired-regression 0.1

eval-evidence: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/evidence.jsonl --judge --verify-evidence \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 --min-mean-quality 4 \
		$(call baseline,evidence) $(call history,evidence)

# Every case names the responder repository, which neither live deployment
# configures today, so this needs a config that does. Declared rather than
# discovered: the eval command now refuses a corpus whose repositories are
# absent before it spends a model call on finding out.
eval-productivity: DEPLOYMENT = responder
eval-productivity: | $(EVAL_HISTORY)
	@test -n "$(TASK_EVAL_POLICY)" || { echo "TASK_EVAL_POLICY must name a disposable writable Coop policy"; exit 2; }
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/productivity.jsonl \
		--task-policy "$(TASK_EVAL_POLICY)" --judge \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 --min-mean-quality 4 \
		$(call history,productivity)

eval-memory: MAX_REGRESSION = 0.5
eval-memory: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/memory.jsonl --judge --verify-evidence --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 --min-mean-quality 4 \
		$(call baseline,memory) $(call history,memory)

# One corpus per deployment, replayed against that deployment's config.
#
# They cannot be merged. A fixture that names a repository needs the config that
# has it, and the two deployments configure different ones — so a single run
# would fail every fixture belonging to the other deployment with
# "repository ... is not configured" and no single CONFIG could ever reach a
# pass rate of 1.
#
# DEPLOYMENT selects which corpus to replay; it must match the config passed in.
DEPLOYMENT ?= blitz

eval-episode-replay: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --episode-replay \
		--input testdata/eval/episode-replay/$(DEPLOYMENT).jsonl --min-overall-pass-rate 1 \
		$(call baseline,episode-replay-$(DEPLOYMENT)) $(call history,episode-replay-$(DEPLOYMENT))

# Replay the corrections an operator kept. This is the only thing that can fail
# because a promoted lesson stopped holding.
#
# It is not split per deployment like eval-episode-replay because a promoted
# fixture never names a repository — the recorder does not write that field —
# so nothing in this corpus needs one deployment's configuration over another's.
# TestThePromotedCorpusBindsNoRepository holds that invariant so this stays true.
eval-regressions: MAX_REGRESSION = 0.34
eval-regressions: | $(EVAL_HISTORY)
	@if [ ! -f "$(REGRESSION_CORPUS)" ]; then \
		echo "$(REGRESSION_CORPUS) does not exist: no correction has ever been promoted,"; \
		echo "so there is no kept lesson to replay. That is an empty gate, not a passed one."; \
		exit 0; \
	fi; \
	set -x; \
	go run ./cmd/responder eval --config "$(CONFIG)" --episode-replay \
		--input "$(REGRESSION_CORPUS)" --repeat $(REGRESSION_REPEAT) \
		--min-case-pass-rate $(REGRESSION_CASE_RATE) \
		$(call baseline,regressions) $(call history,regressions)

# Does the prompt let the model produce a result Responder can use?
#
# Not whether the answer is good — that is eval-quality. This asks the narrower
# question: given what the prompt says, can the model return a response the host
# accepts without correcting it? The harness runs the host's own correction
# pipeline against the answer and fails on any correction, so a failure here is
# a prompt defect by construction: the host had already said everything it was
# going to say.
#
# Every case is drawn from a correction that fired in production. Run it when
# prompts, contracts, or operation schemas change. It calls a real model, so it
# is deliberately outside dev-check.
eval-prompts: | $(EVAL_HISTORY)
	@docker info >/dev/null 2>&1 || { \
		echo "eval-prompts: Docker/OrbStack is not running — every boxed case would fail fast" >&2; \
		echo "and the tally would blame the prompts for a dead runtime. Start it and retry." >&2; \
		exit 1; }
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/prompts.jsonl \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 \
		$(call history,prompts)

# The deploy-speed tier. The full gate above runs ten live investigations and
# takes half an hour, which is the wrong price for a wording change — on
# 2026-08-14 an operator's fix sat behind it and the operator said so. Five
# smoke-tagged cases (~five minutes) cover the envelope, the operations
# schema, the conversation dialect, the session handoff, and the knowledge
# offers; run this before
# deploying a prompt WORDING change. The full run stays for contract, schema,
# or operation-list changes and for release checks, and may run after a deploy
# as information rather than in front of it as a queue.
eval-prompts-smoke: | $(EVAL_HISTORY)
	@docker info >/dev/null 2>&1 || { \
		echo "eval-prompts-smoke: Docker/OrbStack is not running; start it and retry." >&2; \
		exit 1; }
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/prompts.jsonl \
		--case smoke --min-overall-pass-rate 1 --min-case-pass-rate 1 \
		$(call history,prompts-smoke)

eval-live-canary: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/live.jsonl --canary \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 \
		$(call baseline,live-canary) $(call history,live-canary)

# Read back what the judges scored. This is the only thing that answers "is it
# getting better?", and until the results were written down nothing could.
eval-trend:
	scripts/eval-trend.sh "$(EVAL_HISTORY)"

# Record the numbers this release is allowed to hold, from the run that just
# happened.
#
# The workflow, deliberately manual in both directions:
#
#   1. make model-release-check          — every corpus runs and files a result
#   2. make eval-trend                   — read whether it moved, and which way
#   3. make eval-baseline-update CORPUS=quality
#   4. git diff testdata/eval/baselines  — the numbers a release will be held to
#   5. commit it, or do not
#
# Step 4 is the point. Rebaselining automatically after a green run is how a
# quality floor walks downhill one acceptable step at a time, so this writes a
# file and stops. It reads the newest result the corpus recorded rather than
# re-running it: the run already happened, and for the credentialed corpora
# re-running costs an hour of model calls to measure what is already on disk.
#
# A promoted fixture changes the corpus, and the gate compares by case name, so
# growth needs no new baseline — only a rename or a deletion does, and
# TestACommittedBaselineNamesCasesTheCorpusStillHas says so offline.
CORPUS ?=
eval-baseline-update:
	@test -n "$(CORPUS)" || { echo "CORPUS must name a corpus, e.g. CORPUS=regressions"; exit 2; }
	go run ./cmd/responder eval-baseline --history "$(EVAL_HISTORY)" \
		--corpus "$(CORPUS)" --write "$(EVAL_BASELINES)/$(CORPUS).json"

model-release-check: eval-judge-calibration eval-quality eval-proactive eval-scenarios eval-world eval-evidence eval-memory eval-episode-replay eval-regressions eval-live-canary

eval-host-replay:
	RESPONDER_TEST_ISOLATED=1 scripts/elixir-test.sh \
		test/responder/episodes/replay_test.exs \
		test/responder/evals/world_case_test.exs \
		test/responder/evals/world_concurrency_test.exs \
		test/responder/evals/world_coverage_test.exs \
		test/responder/evals/world_runner_test.exs

eval-replay: eval-host-replay
	go run ./cmd/responder eval --replay --input testdata/eval/golden.jsonl

customer-check: test product-e2e eval-replay

# The edit loop. With no arguments it formats changed Go files and runs only
# their owning package tests; set FOCUS_PACKAGE and FOCUS_TEST for one exact
# test. This is intentionally mechanical and incomplete. Candidate proof is
# where the whole committed tree is judged.
focus:
	RESPONDER_FOCUS_PACKAGE="$(FOCUS_PACKAGE)" RESPONDER_FOCUS_TEST="$(FOCUS_TEST)" scripts/focus-check.sh

dev-workflow-check:
	scripts/test-dev-workflow.sh

# Which confirmed findings asked for a test and never got one.
#
# The assessor writes the test spec for every defect it confirms, and for
# months nothing read that column. This names the tests that were asked for,
# so the backlog is a number that can go down rather than a database nobody
# opens. It reads the deployment databases, so it runs here rather than in CI.
findings-coverage:
	scripts/findings-coverage.sh \
		"$$HOME/Projects/blitz/.responder/state/responder.db" \
		"$$HOME/Projects/os/emisar/.responder/state/responder.db"

findings-coverage-check:
	scripts/test-findings-coverage.sh

# The watchdog's failure mode is silence, and so is its healthy state. It is
# gated here because the only way to know it still fires is to break something
# on purpose every time the tree changes.
watchdog-check:
	scripts/watchdog_test.sh

# Fast deterministic feedback for a completed edit batch. Independent checks
# run concurrently; CI and candidate promotion still use the complete gate.
.PHONY: control-plane-js-check
control-plane-js-check:
	node --test test/js/*_test.mjs

dev-check:
	+$(MAKE) --no-print-directory -j$(DEV_CHECK_JOBS) tidy-check lint test elixir-check control-plane-js-check eval-replay build dev-workflow-check findings-coverage-check watchdog-check

# These three targets are the frozen legacy Go/launch-agent rollback path. The
# Elixir service uses elixir-release-check plus elixir-candidate-check and one
# normal PostgreSQL-backed writer replacement; it has no canary/promote state.
candidate:
	scripts/candidate-check.sh

canary:
	scripts/self-deploy.sh --canary

promote:
	scripts/self-deploy.sh --promote

# promote-corrections turns reviewed corrections into regression cases and
# proves the result still passes the gate.
#
# The gate runs twice on purpose. The first run establishes that the tree was
# already green, so a failure after promotion is attributable to the corrections
# rather than to whatever was already broken — without that, a promotion gets
# blamed for a pre-existing failure and the correction is discarded for nothing.
#
# Promotion appends to the corpus before the second gate runs, so a failure
# leaves the new cases in the working tree. That is deliberate: they are the
# evidence needed to decide whether the fixture or the product is wrong. Revert
# with `git checkout $(REGRESSION_CORPUS)` once that decision is made.
#
# The post-gate is two tiers, and they prove different things.
#
# dev-check is offline and always runs. It proves the promoted cases decode,
# have unique names, name a real capability, and do not duplicate an episode
# already in the corpus — the whole class of failure that used to reach a
# reviewer as a broken deployment. It cannot prove behavior. Replaying a fixture
# needs the real model, and dev-check must stay runnable in an ordinary
# edit-test cycle, so it is honestly incapable of failing because a promoted
# lesson stopped holding.
#
# eval-regressions is that second tier, and it is the real gate on a promoted
# case. It is credentialed and costs model calls, which is affordable here and
# nowhere else: promote-corrections already opens the live database and already
# needs a configuration, so it is not an ordinary edit-test cycle. For a long
# time the post-gate was dev-check alone, whose eval step replays golden.jsonl,
# so the corpus promotion had just written was structurally unreachable — the
# gate could not fail because of a promoted regression, and the four cases
# promoted on 2026-08-08 were never replayed against a model at all.
REGRESSION_CORPUS = testdata/eval/regressions.jsonl

# The corpus is replayed three times per case and judged on the majority, not
# on one perfect run.
#
# It used to demand an overall pass rate of 1 against a real model, which is a
# gate that cannot hold: five credentialed runs on one afternoon produced a
# materially different response to the same fixture every time. Every class of
# defect fixed today stayed fixed, and the score still moved run to run — so a
# single failing sample proved nothing, and a gate that cries regression at
# noise gets switched off by the second week.
#
# Three samples with a two-thirds bar is the smallest thing that separates the
# two: a lesson that genuinely broke fails all three, and a model that varied
# fails one. It is a per-case bar rather than an overall one deliberately —
# averaged across cases, two flaky samples in different fixtures look identical
# to one fixture that regressed outright.
#
# Nine model calls per run, and only where credentials already exist. Raise
# REGRESSION_REPEAT if a case turns out to be flakier than that resolves.
REGRESSION_REPEAT ?= 3
# 0.66 and not 0.67: two passes out of three is 0.6667, and a bar of 0.67
# rejects it by four ten-thousandths. The first run under this gate failed a
# case that had passed twice for exactly that reason, which is a bar that
# forbids the thing it was written to allow.
REGRESSION_CASE_RATE ?= 0.66

promote-corrections:
	@echo "== gate before promotion (establishing a clean baseline) =="
	@$(MAKE) dev-check
	@$(MAKE) eval-regressions CONFIG="$(CONFIG)"
	@echo "== promoting reviewed corrections =="
	go run ./cmd/responder promote-fixtures --config "$(CONFIG)"
	@echo "== gate after promotion (offline: shape, names, capabilities) =="
	@$(MAKE) dev-check || ( \
		echo ""; \
		echo "The gate was green before promotion and is not now, so the"; \
		echo "corrections just promoted are what broke it. They are still in"; \
		echo "$(REGRESSION_CORPUS) — read them before deciding whether the"; \
		echo "fixture is wrong or the product is. Revert with:"; \
		echo "    git checkout $(REGRESSION_CORPUS)"; \
		exit 1 )
	@echo "== gate after promotion (real model: does the lesson still hold?) =="
	@$(MAKE) eval-regressions CONFIG="$(CONFIG)" || ( \
		echo ""; \
		echo "The promoted corrections replay against the real model and do not"; \
		echo "reach the corrected outcome. This is the check the offline gate"; \
		echo "cannot perform, and a failure here is the useful one: either the"; \
		echo "fixture asserts something the product never actually does, or the"; \
		echo "product regressed. They are still in $(REGRESSION_CORPUS)."; \
		echo "Revert with:"; \
		echo "    git checkout $(REGRESSION_CORPUS)"; \
		exit 1 )

race:
	scripts/race-shards.sh

# gofmt walks the filesystem, not the module, so it descends into
# .claude/worktrees — the scratch checkouts parallel agents work in. Those are
# copies of this same repository holding somebody else's uncommitted work, and
# the gate reported one of them as this tree being unformatted. Worse, the
# obvious fix is to run gofmt -w, which edits a file out from under whoever is
# writing it. `go list` asks the module instead, so the gate only ever sees the
# tree it is gating.
lint:
	test -z "$$(gofmt -l $$(go list -f '{{.Dir}}' ./...))"
	go vet ./...
	shellcheck scripts/*.sh

actionlint:
	go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7

tidy-check:
	go mod tidy -diff

staticcheck:
	go run honnef.co/go/tools/cmd/staticcheck@v0.7.0 ./...

vulncheck:
	go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...

# The strict gate remains complete, but independent phases no longer wait for
# one another. The race target performs its own balanced test sharding.
check:
	+$(MAKE) --no-print-directory -j$(CHECK_JOBS) tidy-check lint quality-watch-check eval-trend-check dev-workflow-check actionlint staticcheck test elixir-check control-plane-js-check eval-replay race build vulncheck

# Signing is CI-only because keyless Sigstore needs GitHub's OIDC identity.
snapshot:
	goreleaser release --snapshot --clean --skip=sign

release-check: check snapshot elixir-candidate-check
	scripts/check-release.sh dist
	test "$$(bin/responder version)" = "$(VERSION)"
	bin/responder help >/dev/null

clean:
	rm -rf bin dist coverage.out _build cover
