.DEFAULT_GOAL := dev-check

.PHONY: promote-corrections build install test product-e2e live-acceptance eval eval-health eval-quality eval-judge-calibration eval-proactive eval-scenarios eval-evidence eval-productivity eval-memory eval-episode-replay eval-regressions eval-live-canary eval-trend model-release-check eval-replay customer-check dev-check quality-watch-check eval-trend-check race lint tidy-check actionlint staticcheck vulncheck check snapshot release-check clean

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X github.com/AndrewDryga/responder/internal/version.Version=$(VERSION)
INSTALL_DIR ?= $(HOME)/.local/bin
CONFIG ?= .responder/responder.yaml
LIVE_CHANNEL ?=
EVAL_REPEAT ?= 3
TASK_EVAL_POLICY ?=

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

quality-watch-check:
	scripts/quality-watch.sh --help >/dev/null
	jq -e '.type == "object" and .additionalProperties == false' scripts/quality-watch-assessment.schema.json >/dev/null
	jq -e '.type == "object" and .additionalProperties == false' scripts/quality-watch-fix-review.schema.json >/dev/null
	scripts/test-quality-watch.sh

eval-trend-check:
	scripts/test-eval-trend.sh

product-e2e:
	go test ./internal/service -run '^(TestCustomerJourney|TestProductJourney)' -count=1 -v

live-acceptance:
	@test -n "$(LIVE_CHANNEL)" || { echo "LIVE_CHANNEL must be the joined Slack test channel ID"; exit 2; }
	RESPONDER_LIVE_CONFIG="$(abspath $(CONFIG))" RESPONDER_LIVE_CHANNEL="$(LIVE_CHANNEL)" \
		go test ./internal/service -run '^TestLiveSlackAcceptance$$' -count=1 -v

eval: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/live.jsonl \
		$(call history,live)

# Health verdicts are tenant-shaped: every case names tenant-infra, and only the
# tenant deployment configures it. Running this against emisar failed every case
# one model call at a time, reporting a missing config key as a provider
# refusal — so the corpus had never run anywhere. DEPLOYMENT is declared for the
# same reason eval-episode-replay declares it, and the eval command refuses the
# corpus up front rather than discovering it per case.
eval-health: DEPLOYMENT = tenant
eval-health: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/health-verdict.jsonl --judge \
		$(call history,health-$(DEPLOYMENT))

eval-quality: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/live.jsonl --judge --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 --min-mean-quality 4 \
		$(call history,quality)

eval-judge-calibration: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/quality-calibration.jsonl --calibrate-judge \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 \
		$(call history,judge-calibration)

eval-proactive: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/proactive.jsonl --repeat "$(EVAL_REPEAT)" \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.67 \
		--min-proactive-precision 0.90 --min-proactive-recall 0.90 \
		--max-false-interruption-rate 0.10 \
		$(call history,proactive)

eval-scenarios: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/scenarios.jsonl --scenarios --judge --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 \
		--min-proactive-precision 0.90 --min-proactive-recall 0.90 \
		--max-false-interruption-rate 0.10 --min-mean-quality 4 \
		$(call history,scenarios)

eval-evidence: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/evidence.jsonl --judge --verify-evidence \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 --min-mean-quality 4 \
		$(call history,evidence)

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

eval-memory: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/memory.jsonl --judge --verify-evidence --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 --min-mean-quality 4 \
		$(call history,memory)

# One corpus per deployment, replayed against that deployment's config.
#
# They cannot be merged. A fixture that names a repository needs the config that
# has it, and the two deployments configure different ones — so a single run
# would fail every fixture belonging to the other deployment with
# "repository ... is not configured" and no single CONFIG could ever reach a
# pass rate of 1.
#
# DEPLOYMENT selects which corpus to replay; it must match the config passed in.
DEPLOYMENT ?= tenant

eval-episode-replay: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --episode-replay \
		--input testdata/eval/episode-replay/$(DEPLOYMENT).jsonl --min-overall-pass-rate 1 \
		$(call history,episode-replay-$(DEPLOYMENT))

# Replay the corrections an operator kept. This is the only thing that can fail
# because a promoted lesson stopped holding.
#
# It is not split per deployment like eval-episode-replay because a promoted
# fixture never names a repository — the recorder does not write that field —
# so nothing in this corpus needs one deployment's configuration over another's.
# TestThePromotedCorpusBindsNoRepository holds that invariant so this stays true.
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
		$(call history,regressions)

eval-live-canary: | $(EVAL_HISTORY)
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/live.jsonl --canary \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 \
		$(call history,live-canary)

# Read back what the judges scored. This is the only thing that answers "is it
# getting better?", and until the results were written down nothing could.
eval-trend:
	scripts/eval-trend.sh "$(EVAL_HISTORY)"

model-release-check: eval-judge-calibration eval-quality eval-proactive eval-scenarios eval-evidence eval-memory eval-episode-replay eval-regressions eval-live-canary

eval-replay:
	go run ./cmd/responder eval --replay --input testdata/eval/golden.jsonl

customer-check: test product-e2e eval-replay

# Fast deterministic feedback for normal development. CI and releases use check.
dev-check: tidy-check lint test eval-replay build

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
	go test -race ./...

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

check: tidy-check lint quality-watch-check eval-trend-check actionlint staticcheck test eval-replay race build vulncheck

# Signing is CI-only because keyless Sigstore needs GitHub's OIDC identity.
snapshot:
	goreleaser release --snapshot --clean --skip=sign

release-check: check snapshot
	scripts/check-release.sh dist
	test "$$(bin/responder version)" = "$(VERSION)"
	bin/responder help >/dev/null

clean:
	rm -rf bin dist coverage.out
