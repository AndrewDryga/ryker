---
name: self-improve
description: Walk every queue in this repo that needs judgment — pending corrections, memory review, quality findings, blocked decisions, uncovered findings, eval health — decide each item, fix confirmed bugs test-first, and finish by deploying. Run periodically with a frontier model.
---

# Self-improve: the deliberate pass over everything awaiting judgment

You are running the periodic self-improvement session for Ryker. The instruments
already collect; your job is to DECIDE and to FIX. Work the sections in order — each
ends with a concrete action, never just a summary. Respect CLAUDE.md throughout
(test-first with a red run, fixtures harvested never invented, dev-check before
commits, finish by deploying, say plainly what is running).

Ground rules for the whole pass:

- The live PostgreSQL database is read-only from the shell. Its `DATABASE_URL`
  is in the deployment's runtime environment file
  (`~/.local/state/ryker/emisar/runtime.env` on this host); open it as
  `PGOPTIONS='-c default_transaction_read_only=on' psql "postgresql://${DATABASE_URL#ecto://}"`
  so a stray write fails instead of landing. Timestamps are UTC.
- Every WRITE goes through a sanctioned path: the control plane's POST actions on
  loopback (they call the same service handlers as the Slack buttons and write their
  own audit rows), the `mix ryker.*` operator tasks in `docs/operations.md`, or
  code changes through the normal gate. Never write to the database directly.
- The control plane listens on loopback at `http://127.0.0.1:4321`. `curl` GETs
  freely; POSTs are the two-step confirm forms — read the page's form fields first.
- A decision you cannot make from the evidence is written down as a decision card
  (a `50_blocked/` task with decision.md), not guessed.

## 1. Response corrections — inspect the episode and preserve the regression

Use the episode timeline and its model request inspector to read retained response
checks: what the model saw, what Ryker refused, and what happened next. The
current Elixir control plane has no fixture-candidate keep/discard queue. Do not
invent a Decisions page or send its obsolete actions.

- Inspect concrete rejected candidates with their exact submitted context.
- If the same correction repeats, diagnose whether the host mishandled a valid
  result or the model returned an unusable result, following AGENTS.md.
- Harvest the relevant recorded result into the owning deterministic regression
  test or prompt evaluation. Record the source episode and why the case matters.
- Fix confirmed defects test-first through the normal gate. Do not silently turn
  a model answer into a policy or an operator-confirmed memory.

## 2. Memory review — keep, merge, forget

- The stale/duplicate review queue: control plane Memory page (keep, merge, forget
  and dismiss are wired), or the Memory review section of App Home in Slack.
- Also read the current operational memory and conversation rollups with fresh eyes:
  `SELECT kind, subject, left(payload::text, 80), scope_kind, expires_at, recall_count
  FROM operational_memory_entries WHERE status = 'active' ORDER BY recall_count DESC`.
  Entries recalled often but wrong are worse than entries never recalled — verify
  the top-recalled ones against reality (the repo, the live config, Emisar) and
  forget or supersede what drifted.
- Never edit operator-confirmed memory silently; use the review actions so the
  supersession trail stays honest.

## 3. Blocked decisions and stale queue state

- `coop tasks decisions` lists every open decision card with its recommendation.
  Decide each one you have the evidence for; write the Resolution and unblock.
  Genuinely-operator-only calls (spending, external accounts, visible-behavior
  changes the operator has not sanctioned) stay blocked — but tighten their
  decision.md with anything learned since.
- Skim `10_in_progress/` for tasks whose agent died or whose work landed without
  close-out; reconcile against `git log` before assuming anything is undone.
- Groom `xx_backlog/`: promote what became urgent, close what shipped by other
  means (verify against the tree first — several backlog items have been
  superseded within days of filing).

## 4. Eval and cost health — is it getting better?

- The control plane's Usage page (`/usage`, windows of 24h, 7d, 30d and all) —
  corrections and cost per work kind, provider, model and effort. A lane whose
  correction rate jumped is a regression to diagnose (host-vs-prompt split again);
  a lane whose cost dwarfs its quality difference is a routing decision to propose.
  Compare the 7d window against the last pass.
- `make eval-trend` for the recorded corpus history; if a case flaps run-to-run,
  either fix the prompt ambiguity it exposes or mark the flake with evidence —
  never let a flaky case train everyone to ignore the gate.
- Chronic failures in the recorded eval cases (`testdata/eval/admission.json` and
  the worlds under `testdata/scenarios/`): decide prompt-side vs host-side and
  open the task on the right side.

## 5. Episodes with fresh eyes — the unprompted review

The host keeps the review ledger, so this section never re-reads an ending it has
already judged. List what is pending from the read-only shell:

```sql
SELECT e.key, e.state, e.updated_at
FROM episode_kernel_episodes e
LEFT JOIN episode_operator_reviews r
  ON r.episode_id = e.id AND r.semantic_version = e.semantic_version
WHERE e.state IN ('complete', 'cancelled') AND r.id IS NULL
ORDER BY e.updated_at;
```

That is every terminal episode with no review of its current ending, including
any whose ending MOVED since its last review (a blocked episode that revived and
completed, a new attempt) — the semantic version brings those back by itself, so
never re-open reviewed episodes "just in case". Each key opens as
`/timeline/<key>`. Oldest first, and drain the queue: the pass is daily and the
queue only stays short if every run empties it.

Read each pending trace end-to-end. You are looking for what the watcher's rubric
misses: answers that were accepted but unhelpful, corrections that fired repeatedly
on one episode, context the budget dropped that would have changed the answer
(the trace shows omissions), recall/change-ledger layers that surfaced the wrong
thing. Each concrete defect becomes a task with the episode id as evidence.

Then mark the episode reviewed — defects found or not — with the Timeline page's
"Mark ending reviewed" control (`POST /actions/episode/<key>/review`, two-step
confirm like every control plane write). The receipt records who reviewed which
exact terminal version and carries no note, so the verdict lives in the task you
filed (the episode key is its evidence) or, for "no defect", in the session
digest. An episode left unmarked is an episode the next pass pays to read again.

## 6. Close the loop

- Land every fix through the gate (dev-check; the full `make check` and
  `eval-world` tiers per AGENTS.md's rules for what changed).
- Deploy with `scripts/deploy.sh` and say what is running.
- Update the weekly picture: what was decided, what was fixed, what was deferred
  and why — a short digest in the session, and durable notes only where the repo's
  own records (task states, decision cards, audit rows) don't already carry it.
