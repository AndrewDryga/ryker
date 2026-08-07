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

## Finish by deploying

Work is not done when the gate is green. It is done when the code is running.

Commit the change, then run `scripts/deploy.sh`. It refuses a dirty tree, builds
`responder-<sha>` into `~/.local/libexec/responder/`, repoints every `ai.emisar.responder.*`
launch agent that pins a binary, restarts them, and prints the processes that came back so the
claim is checked rather than assumed.

Every deployment sets `coop.supervise: true` against `~/.local/bin/coop`, so Coop restarts with
Responder. When a change spans both repositories, run `make install` in the Coop checkout first,
then deploy here.

Say plainly what is running. "The gate is green" and "the fix is live" are different claims, and
reporting the first as if it were the second sends an operator to debug a Slack failure against
code that is not the code producing it — which is exactly what happened, and why this rule exists.
Never describe something you have not deployed as deployed.
