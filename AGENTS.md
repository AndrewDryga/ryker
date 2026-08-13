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

## Every fix carries the test that would have caught it

A fix without a test is a fix with a scheduled return date. On 2026-08-13 eight defects
were found in one day; seven were ordinary Go tests nobody had written, and several were
variants of bugs fixed the week before. The diagnosis was never the bottleneck.

So, for anything that reached production:

1. **Write the test first, and watch it fail on the previous commit.** Revert your fix, run
   the test, see it fail for the reason you expect, restore. A test that passes before the
   fix proves nothing, and this catches the common case where the test asserts something
   adjacent to the actual defect.
2. **Assert the behaviour, not the plumbing.** Check the decision before the error so the
   failure message names what went wrong rather than whatever the store said about a write
   that should never have happened.
3. **Name the test after the invariant**, not the function:
   `TestAttemptedRunSurvivesANewerContextualMessage`, not `TestAdmitTriageRun`.
4. **Record the cost in the comment.** "Thirty of these in two days, on episodes that then
   spent every attempt they had" is why the test exists; a future reader deleting it as
   redundant needs to know what it is holding shut.

The model's answer is an **input**, not a dependency. Almost every defect here is the host
mishandling a well-formed result — suppression rebuilding a reply it had just cleared, a 409
read as "this work is finished", a whole result discarded because `confidence` was `3`
instead of `"high"`. Reproduce those with a recorded result string and `newFakeCoop()`. No
test in `dev-check` may call a model: `make eval-replay` runs its recorded cases in under a
second with no credentials, and that is the standard to hold.

Fixtures are harvested, never invented. `agent_runs.result_json` holds hundreds of real model
answers and `context_manifests.submitted_prompt` the prompts that produced them, so the exact
result that broke production is already on disk.

### Where each kind of test belongs

- **Host mishandled a valid result** → Go test beside the code. Deterministic, no model.
- **Model produced an invalid or unusable result** → `make eval-prompts`. That is a prompt
  problem, and no amount of host testing fixes it. Run it when prompts, contracts, or
  operation schemas change.
- **The machine stopped working** → no test catches this. `scripts/watchdog.sh` does.

The split is diagnostic. When a correction fires repeatedly on one episode, ask which side it
belongs to before writing anything: a correction the model *cannot* satisfy is a host bug, and
a correction it simply *did not* satisfy is a prompt bug. Ranking the recorded corrections by
repeats-per-episode finds both — the worst was 6.6, telling the model to pick from an empty
list of verdicts.

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
