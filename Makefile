.DEFAULT_GOAL := check

.PHONY: build test race lint check clean

build:
	go build -ldflags "-X github.com/AndrewDryga/responder/internal/version.Version=$${VERSION:-dev}" -o bin/responder ./cmd/responder

test:
	go test ./...

race:
	go test -race ./...

lint:
	test -z "$$(gofmt -l .)"
	go vet ./...

check: lint race build

clean:
	rm -rf bin coverage.out
