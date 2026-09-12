# Responder Development

## Ryker identity and rename

The approved target identity is Ryker. Before branding, UI, naming or rename work, read
`.agent/kb/rules/ryker-brand.md` and the repo-local sources it names. Use supplied artwork and
Ryker mint, not the umbrella orange. The full code/repository/runtime rename is queued in the
redesign task; documentation or imported assets alone do not mean it has shipped.

## Slack-card design and review

Before creating or redesigning Slack cards, read
`.agent/kb/rules/slack-card-design-workflow.md` and `.agent/kb/rules/slack-presentation.md`.
Reuse the native-payload catalog, validate the exact Builder envelope, and include fresh direct
Builder links for each card-design change. Keep preview, visual, integration and deployment proof distinct.

## Pre-v1 replacements are clean cuts

Remove superseded routes and implementations and update every caller, link, test,
and document in the same change. Do not add redirects, compatibility aliases,
legacy fallbacks, temporary dual paths, or staged compatibility migrations.
Preserve user data; removing an old interface does not authorize deleting history.


## The gate

Use the narrowest validation that proves the current edit while iterating:

1. Run the owning test after each code change, for example
   `scripts/elixir-test.sh test/responder/work/executor_test.exs:120`. It runs against the
   shared test database and finishes in about a second.
2. Run `make dev-check` once before committing. It is the deterministic repository gate:
   formatting, warnings-as-errors, Credo, the whole ExUnit suite in a fresh database,
   control-plane JavaScript, and ShellCheck. It takes a few minutes and never calls a model.
3. Commit, then run `scripts/deploy.sh` (see "Finish by deploying").
4. `make check` is the full gate: dev-check plus the deterministic host replay in an
   isolated database, the watchdog and live-acceptance wrapper tests, the thirty-day
   retention simulation, and the eval-trend self-test. CI runs it on every push to origin.
   Run it locally before a tagged release or when a change touches retention custody or the
   release scripts, not before every deploy.
5. Run live Slack, Coop, or Emisar acceptance only when the changed integration boundary
   requires it. Do not substitute live smoke tests for focused offline tests.

Do not repeatedly run credentialed model evals during ordinary edit-test cycles. Agents
working in parallel run their owning tests; one `make dev-check` on the merged tree before
the commit is the gate, not one per agent.

## Every fix carries the test that would have caught it

A fix without a test is a fix with a scheduled return date. On 2026-08-13 eight defects
were found in one day; seven were ordinary deterministic tests nobody had written, and several were
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
   `attempted run survives a newer contextual message`, not `admit triage run`.
4. **Record the cost in the comment.** "Thirty of these in two days, on episodes that then
   spent every attempt they had" is why the test exists; a future reader deleting it as
   redundant needs to know what it is holding shut.

The model's answer is an **input**, not a dependency. Almost every defect here is the host
mishandling a well-formed result — suppression rebuilding a reply it had just cleared, a 409
read as "this work is finished", a whole result discarded because `confidence` was `3`
instead of `"high"`. Reproduce those with a recorded result and a deterministic test double. No
test in `dev-check` may call a model: `make eval-replay` runs its recorded cases in under a
second with no credentials, and that is the standard to hold.

Fixtures are harvested, never invented. `agent_runs.result_json` holds hundreds of real model
answers and `context_manifests.submitted_prompt` the prompts that produced them, so the exact
result that broke production is already on disk.

### Where each kind of test belongs

- **Host mishandled a valid result** → ExUnit test beside the owning module. Deterministic, no model.
- **Model produced an invalid or unusable result** → `make eval-world`. That is a prompt
  problem, and no amount of host testing fixes it. Run it when prompts, contracts, or
  operation schemas change.
- **The machine stopped working** → no test catches this. `scripts/watchdog.sh` does.

For a prompt wording change, `make eval-world-smoke` is the focused model gate. Run the full
`make eval-world` matrix for contract, schema, operation-list, and release changes. A live fix
waits for `dev-check` and nothing else.

The split is diagnostic. When a correction fires repeatedly on one episode, ask which side it
belongs to before writing anything: a correction the model *cannot* satisfy is a host bug, and
a correction it simply *did not* satisfy is a prompt bug. Ranking the recorded corrections by
repeats-per-episode finds both — the worst was 6.6, telling the model to pick from an empty
list of verdicts.

## Finish by deploying

Work is not done when the gate is green. It is done when the code is running.

Commit the change, then run `scripts/deploy.sh`. It refuses a dirty tree, builds the exact
Elixir release incrementally, qualifies the archive against a disposable PostgreSQL, rehearses
any migrations the live database has not applied on a restored backup of it, installs the
release under the immutable prefix, atomically updates `current`, restarts the service under
systemd on Linux or launchd on macOS, and waits for `/healthz`, `/readyz`, and the exact running
version header. PostgreSQL custody resumes pending admission, Work, delivery, schedule, and
remote-worker state after the normal one-writer restart; there is no canary/promote deployment
state. A deploy without new migrations takes about two minutes end to end.

Production Coop workers are enrolled and upgraded independently through the outbound fleet
protocol. Do not make the Responder deployment restart or install Coop. A deliberately configured
single local Coop worker remains a development/test topology, not a second production path.

Say plainly what is running. "The gate is green" and "the fix is live" are different claims, and
reporting the first as if it were the second sends an operator to debug a Slack failure against
code that is not the code producing it — which is exactly what happened, and why this rule exists.
Never describe something you have not deployed as deployed.
