---
name: self-improve
description: Walk every queue in this repo that needs judgment — pending corrections, memory review, quality findings, blocked decisions, uncovered findings, eval health — decide each item, fix confirmed bugs test-first, and finish by deploying. Run periodically with a frontier model.
---

# Self-improve: the deliberate pass over everything awaiting judgment

You are running the periodic self-improvement session for Responder. The instruments
already collect; your job is to DECIDE and to FIX. Work the sections in order — each
ends with a concrete action, never just a summary. Respect CLAUDE.md throughout
(test-first with a red run, fixtures harvested never invented, dev-check before
commits, finish by deploying, say plainly what is running).

Ground rules for the whole pass:

- Live DBs are read-only from the shell: `sqlite3 "file:<db>?mode=ro&immutable=1"`.
  Paths: blitz `~/Projects/blitz/.responder/state/responder.db`, emisar
  `~/Projects/os/emisar/.responder/state/responder.db`. Timestamps are UTC.
  `immutable=1` snapshots the file and never sees the live WAL, so a read taken
  right after one of your own POSTs can show the old state — verify writes and
  build act-on-id lists with plain `mode=ro` (still read-only), and keep
  `immutable=1` for bulk stable scans. The first pass lost a batch to this:
  a stale pending-list re-sent already-actioned ids and the refusal stopped
  the whole batch.
- Every WRITE goes through a sanctioned path: the control plane's POST actions on
  loopback (they call the same service handlers as the Slack buttons and write their
  own audit rows), the `responder` CLI, or code changes through the normal gate.
  Never write to the DBs directly.
- The control plane is at the deployment's `listen:` address (see each
  responder.yaml). `curl` GETs freely; POSTs are the two-step confirm forms — read
  the page's form fields first.
- A decision you cannot make from the evidence is written down as a decision card
  (a `50_blocked/` task with decision.md), not guessed.

## 1. Response corrections — inspect the episode and preserve the regression

Use the episode timeline and its model request inspector to read retained response
checks: what the model saw, what Responder refused, and what happened next. The
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

- The stale/duplicate review queue: control plane Memory page (keep and dismiss are
  wired), or `/responder memory review` in Slack.
- Also read the current memory_entries and conversation rollups with fresh eyes:
  `SELECT subject_key, predicate, substr(value_json,1,80), scope_kind, expires_at,
  recall_count FROM memory_entries ORDER BY recall_count DESC`. Entries recalled
  often but wrong are worse than entries never recalled — verify the top-recalled
  ones against reality (the repo, the live config, Emisar) and forget or supersede
  what drifted.
- Never edit operator-confirmed memory silently; use the review actions so the
  supersession trail stays honest.

## 3. Quality findings — the watcher's confirmed defects

- Findings page on the control plane (or `SELECT * FROM quality_findings ORDER BY
  created_at DESC` on blitz). Each row survived an adversarial challenger.
- For each unaddressed finding: reproduce it (the row names file/symbol evidence and
  the episodes it came from), then fix it the repo's way — the failing test FIRST,
  watched red on the pre-fix code, then the fix, then the gate.
- `make findings-coverage` lists confirmed findings whose suggested test does not
  exist. Write the missing tests or claim renamed specs with `// Covers:` lines.
  The backlog must be a number that reaches zero, not one that drifts.

## 4. Blocked decisions and stale queue state

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

## 5. Eval and cost health — is it getting better?

- `responder audition --config <deployment yaml>` — corrections-per-attempt and
  cost per lane per model. A lane whose rate jumped is a regression to diagnose
  (host-vs-prompt split again); a lane whose cost dwarfs its quality difference is
  a routing decision to propose.
- `responder correction-rate --days 7` on both DBs; compare against the last pass.
- `make eval-trend` for the recorded corpus history; if a case flaps run-to-run,
  either fix the prompt ambiguity it exposes or mark the flake with evidence —
  never let a flaky case train everyone to ignore the gate.
- Chronic failures in `testdata/eval/` cases: decide prompt-side vs host-side and
  open the task on the right side.

## 6. Episodes with fresh eyes — the unprompted review

The host keeps the review ledger, so this section never re-reads an ending it has
already judged. Walk `GET /episodes?review=pending` on each deployment's control
plane: every terminal episode with no review row, plus any whose ending MOVED
since its last review (a blocked episode that revived and completed, a new
attempt) — the fingerprint brings those back by itself, so never re-open reviewed
episodes "just in case". Oldest first, and drain the queue: the pass is daily and
the queue only stays short if every run empties it.

Read each pending trace end-to-end. You are looking for what the watcher's rubric
misses: answers that were accepted but unhelpful, corrections that fired repeatedly
on one episode, context the budget dropped that would have changed the answer
(the trace shows omissions), recall/change-ledger layers that surfaced the wrong
thing. Each concrete defect becomes a task with the episode id as evidence.

Then mark the episode reviewed — defects found or not — via the episode page's
review form (`POST /actions/episodes/review`, two-step confirm like every control
plane write), with a one-line verdict as the note: what the episode did, and
either "no defect" or the task id you filed. The note is the review journal. An
episode left unmarked is an episode the next pass pays to read again, and a mark
without a note is a review that cannot be audited.

## 7. Record what only now exists

Check `internal/episode_replay_coverage_test.go`'s acknowledged gaps against the
last few days of real history. Retention prunes fast — if a gap's real occurrence
happened recently (a room-less approval, a standing-assignment evaluation, a
completed schedule run), record it NOW with
`responder record-episode --config <yaml> --episode <id> --capability <slug>`,
append to the corpus, delete the gap line, and let the ratchet climb.

## 8. Close the loop

- Land every fix through the gate (dev-check; the full `make check` and
  `eval-prompts` tiers per CLAUDE.md's rules for what changed).
- Deploy with `scripts/deploy.sh` and say what is running.
- Update the weekly picture: what was decided, what was fixed, what was deferred
  and why — a short digest in the session, and durable notes only where the repo's
  own records (task states, decision cards, audit rows) don't already carry it.
