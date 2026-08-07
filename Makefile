.DEFAULT_GOAL := dev-check

.PHONY: promote-corrections build install test product-e2e live-acceptance eval eval-health eval-quality eval-judge-calibration eval-proactive eval-scenarios eval-evidence eval-productivity eval-memory eval-episode-replay eval-live-canary model-release-check eval-replay customer-check dev-check quality-watch-check race lint tidy-check actionlint staticcheck vulncheck check snapshot release-check clean

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X github.com/AndrewDryga/responder/internal/version.Version=$(VERSION)
INSTALL_DIR ?= $(HOME)/.local/bin
CONFIG ?= .responder/responder.yaml
LIVE_CHANNEL ?=
EVAL_REPEAT ?= 3
TASK_EVAL_POLICY ?=

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

product-e2e:
	go test ./internal/service -run '^(TestCustomerJourney|TestProductJourney)' -count=1 -v

live-acceptance:
	@test -n "$(LIVE_CHANNEL)" || { echo "LIVE_CHANNEL must be the joined Slack test channel ID"; exit 2; }
	RESPONDER_LIVE_CONFIG="$(abspath $(CONFIG))" RESPONDER_LIVE_CHANNEL="$(LIVE_CHANNEL)" \
		go test ./internal/service -run '^TestLiveSlackAcceptance$$' -count=1 -v

eval:
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/live.jsonl

eval-health:
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/health-verdict.jsonl --judge

eval-quality:
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/live.jsonl --judge --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 --min-mean-quality 4

eval-judge-calibration:
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/quality-calibration.jsonl --calibrate-judge \
		--min-overall-pass-rate 1 --min-case-pass-rate 1

eval-proactive:
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/proactive.jsonl --repeat "$(EVAL_REPEAT)" \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.67 \
		--min-proactive-precision 0.90 --min-proactive-recall 0.90 \
		--max-false-interruption-rate 0.10

eval-scenarios:
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/scenarios.jsonl --scenarios --judge --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 \
		--min-proactive-precision 0.90 --min-proactive-recall 0.90 \
		--max-false-interruption-rate 0.10 --min-mean-quality 4

eval-evidence:
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/evidence.jsonl --judge --verify-evidence \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 --min-mean-quality 4

eval-productivity:
	@test -n "$(TASK_EVAL_POLICY)" || { echo "TASK_EVAL_POLICY must name a disposable writable Coop policy"; exit 2; }
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/productivity.jsonl \
		--task-policy "$(TASK_EVAL_POLICY)" --judge \
		--min-overall-pass-rate 1 --min-case-pass-rate 1 --min-mean-quality 4

eval-memory:
	go run ./cmd/responder eval --config "$(CONFIG)" \
		--input testdata/eval/memory.jsonl --judge --verify-evidence --repeat 2 \
		--min-overall-pass-rate 0.90 --min-case-pass-rate 0.50 --min-mean-quality 4

eval-episode-replay:
	go run ./cmd/responder eval --config "$(CONFIG)" --episode-replay \
		--input testdata/eval/episode-replay.jsonl --min-overall-pass-rate 1

eval-live-canary:
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/live.jsonl --canary \
		--min-overall-pass-rate 1 --min-case-pass-rate 1

model-release-check: eval-judge-calibration eval-quality eval-proactive eval-scenarios eval-evidence eval-memory eval-episode-replay eval-live-canary

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
REGRESSION_CORPUS = testdata/eval/regressions.jsonl

promote-corrections:
	@echo "== gate before promotion (establishing a clean baseline) =="
	@$(MAKE) dev-check
	@echo "== promoting reviewed corrections =="
	go run ./cmd/responder promote-fixtures --config "$(CONFIG)"
	@echo "== gate after promotion =="
	@$(MAKE) dev-check || ( \
		echo ""; \
		echo "The gate was green before promotion and is not now, so the"; \
		echo "corrections just promoted are what broke it. They are still in"; \
		echo "$(REGRESSION_CORPUS) — read them before deciding whether the"; \
		echo "fixture is wrong or the product is. Revert with:"; \
		echo "    git checkout $(REGRESSION_CORPUS)"; \
		exit 1 )

race:
	go test -race ./...

lint:
	test -z "$$(gofmt -l .)"
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

check: tidy-check lint quality-watch-check actionlint staticcheck test eval-replay race build vulncheck

# Signing is CI-only because keyless Sigstore needs GitHub's OIDC identity.
snapshot:
	goreleaser release --snapshot --clean --skip=sign

release-check: check snapshot
	scripts/check-release.sh dist
	test "$$(bin/responder version)" = "$(VERSION)"
	bin/responder help >/dev/null

clean:
	rm -rf bin dist coverage.out
