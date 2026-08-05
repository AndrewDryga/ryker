# Responder Development

Use the narrowest validation that proves the current edit while iterating:

1. Run the owning package or named test after each code change, for example
   `go test ./internal/service -run '^TestName$' -count=1`.
2. Run `make dev-check` before committing. It is the fast deterministic repository gate.
3. Run `make check` once before shipping changes that affect concurrency, persistence,
   security, release behavior, or broad shared contracts. CI and release workflows always
   run it.
4. Run live Slack, Coop, or Emisar acceptance only when the changed integration boundary
   requires it. Do not substitute live smoke tests for focused offline tests.

Do not repeatedly run the whole-tree race detector, vulnerability scan, or credentialed
model evals during ordinary edit-test cycles.
