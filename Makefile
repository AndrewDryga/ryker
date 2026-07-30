.DEFAULT_GOAL := check

.PHONY: build install test eval eval-replay customer-check race lint tidy-check actionlint staticcheck vulncheck check snapshot release-check clean

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X github.com/AndrewDryga/responder/internal/version.Version=$(VERSION)
INSTALL_DIR ?= $(HOME)/.local/bin
CONFIG ?= .responder/responder.yaml

build:
	go build -trimpath -ldflags "$(LDFLAGS)" -o bin/responder ./cmd/responder

install:
	install -d "$(INSTALL_DIR)"
	go build -trimpath -ldflags "$(LDFLAGS)" -o "$(INSTALL_DIR)/responder" ./cmd/responder
	@echo "installed $(INSTALL_DIR)/responder ($(VERSION))"

test:
	go test ./...

eval:
	go run ./cmd/responder eval --config "$(CONFIG)" --input testdata/eval/live.jsonl

eval-replay:
	go run ./cmd/responder eval --replay --input testdata/eval/golden.jsonl

customer-check: test eval-replay

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

check: tidy-check lint actionlint staticcheck test eval-replay race build vulncheck

# Signing is CI-only because keyless Sigstore needs GitHub's OIDC identity.
snapshot:
	goreleaser release --snapshot --clean --skip=sign

release-check: check snapshot
	scripts/check-release.sh dist
	test "$$(bin/responder version)" = "$(VERSION)"
	bin/responder help >/dev/null

clean:
	rm -rf bin dist coverage.out
