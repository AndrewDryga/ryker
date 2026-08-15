# Changelog

## 0.1.0

- **A verified fix stops evaporating.** Phase 1 made a finished episode recallable; the knowledge in
  it still died with the thread. A completed episode whose closing assessment named how the fix was
  checked — `episode_outcomes.verified`, the same field the remediation ladder counts, not a second
  definition of the word — may now carry two new typed offers. `offer_runbook_draft` proposes that
  an Emisar action this episode ran and verified become an unpublished runbook draft;
  `offer_kb_card` proposes a `.agent/kb/` card for durable behaviour that is not an action at all.
  Both propose and nothing more. The host refuses any offer whose episode did not verify anything,
  and refuses a runbook naming an action identity it has no successful approval row for — then
  builds the draft from the ROW rather than the claim, so no byte a model typed reaches Emisar. The
  confirmation button carries an identity and no content: the offer is read back out of the
  episode's own event stream and re-validated through the same validator that accepted it, the
  operator is re-authorized on both axes, and a payload older than a day or clicked in another
  channel creates nothing. Confirmed, a runbook becomes a draft Emisar holds and publishes only for
  a human, and a card becomes an engineering task on the existing propose-to-PR path, ending at a
  draft pull request Responder never merges. Postmortem drafts now list their incident's tracked
  commitments — title, lifecycle state and a link to the thread — in place of the checkbox reading
  "assign remaining corrective actions and owners". The decisions are pure functions in
  `internal/knowledgeoffer` with table tests and no database; `internal/service` ends this change
  186 lines smaller than it started, with its Slack-file policy extracted to `internal/slackfile`.

- **An incident is told what changed.** It is the first question of every real outage and Responder
  could not answer it, while the facts went past its own hands three times a day: a deploy
  notification arriving on a webhook became a signal or nothing at all, the publication follower
  watched Responder's own pull requests merge without ledgering the merge, and the approval watcher
  read mutating Emisar runs to terminal state and kept only the approval row. `change_events`
  (migration 76) is one append-only row per recorded change, ingested from exactly those three
  sources — no new polling — and keyed by the source's own identity so a redelivery, a rewound poll
  cursor, and a re-read terminal run all address the row that is already there. A new `kind: change`
  webhook route maps a deploy payload through the same dot paths, the same authentication, and the
  same replay window as every other route; a merge or a correlated deployment is written inside the
  transaction that records the lifecycle event, because written afterwards it could simply be
  absent. Incident and operational-assessment prompts gain a `recent_changes` layer scoped to the
  implicated services and repositories — resolved from the channel's repository binding, the firing
  alert's labels, and the target identity of every piece of evidence gathered so far — within
  `limits.change_window` (6h) and capped at `limits.max_recent_changes` (10). It drops second under
  budget pressure, after recalled history and before the channel transcript, recording its own
  omission so a thin answer can be explained. A change is a hint and never authority: it cannot
  trigger work, and naming one as the cause of an alert still requires a `record_evidence`
  operation bound through the existing cause gate. The trace page shows exactly which changes a
  turn was given and why each was selected.

- **A kept correction promotes itself, and quality can fail a release.** Reviewing a correction was
  never the bottleneck: an operator clicked Keep in App Home and then `make promote-corrections` had
  to be run by hand in a checkout, which is the step that stopped happening — three fixtures in the
  pipeline's whole life. The maintenance lane now drains approved candidates into
  `testdata/eval/regressions.jsonl` itself, bounded by
  `limits.max_auto_promoted_fixtures_per_week` (5), writing only into a configured repository that
  already holds the corpus, and only after re-parsing the corpus with the new fixture in place. One
  that fails that check is held back rather than retried, and says so on the Decisions page — the
  human's remaining job is demotion, not admission. Separately, `make model-release-check` can now
  fail because quality dropped: baselines are committed files under `testdata/eval/baselines/`,
  compared per case, on the overall pass rate, and on the mean judge score, with
  `make eval-baseline-update CORPUS=<name>` recording a new one from a run that already happened so
  a regression is always a diff somebody approved.

- **Responder keeps its own repositories current.** There was no `git fetch` anywhere in this
  product, so "current repository content" — second in the evidence hierarchy, above configuration
  and confirmed memory — meant whatever a human last remembered to pull. Declare a repository with
  `github: owner/name` and Responder clones it into `<state_dir>/repos/owner/name` on
  `bootstrap-coop`, refreshes it on the maintenance lane every
  `limits.repository_fetch_interval` (15m), and pays for a bounded fetch before a turn whose clone
  has lapsed. It never modifies the work tree: updates are fetch plus fast-forward, a dirty clone is
  reported rather than reset, and a corrupt one is re-cloned beside and swapped in at the same path.
  Each attempt's context manifest now records the revision and when it was last fetched, so how old
  the code the model read was finally has an answer. A fetch that fails degrades to recorded
  staleness — never a blocked turn — and surfaces in `responder doctor` and as
  `responder_repository_fetch_failures` on `/metrics`, deliberately outside every signal that means
  "work is not moving". The GitHub credential stays host-side on the hermetic path publication
  already used: a per-invocation header, never a file, an argument, a Coop policy, or anything
  inside an agent box. `path:` still works; exactly one of the two is now required.

- **Fast development and exact candidate proof.** `make focus` formats changed Go files and runs
  only their owning package tests, while the deterministic batch and full gates parallelize
  independent checks and shard the large service race suite. A committed binary is now proven once
  against its commit, checksum, toolchain, and platform, then reused for canary, promotion, normal
  deployment, and unattended rollout without weakening the independent clean-runner CI gate.
- **Cross-provider model failover.** Session policies may name an ordered target ladder
  (`target: [claude:opus/max@oncall, codex:gpt-5.6-sol/xhigh@oncall]`). Coop rotates a rate-limited
  session onto the next free rung mid-turn and re-delivers the same work; `responder doctor`
  verifies every rung's credential, not just the one sessions start on; and an exhausted ladder
  waits until the reset instant the provider named without spending a retry attempt.
- **Provider trouble never reaches the channel.** A refusal, quota, rate limit, or dropped stream
  pauses the original message with a reaction and keeps the work queued instead of posting
  "Responder could not complete this check" into a shared room. Transient stream drops retry
  immediately; refusals requeue from all three lanes, including finalization, without counting
  attempts.
- **One deployment path.** `scripts/deploy.sh` builds an immutable commit-named binary, reloads the
  launch-agent definitions (not merely kickstarts them), and fails unless every running process is
  on the deployed commit; `--stage` prepares a candidate without rotating anything. The
  quality-watch fixer deploys through the same script, ending a path where validated fixes were
  reported deployed while the pinned binaries kept running old code.
- **Episode replay coverage ratchet.** The capability matrix is parsed from the migration document
  itself; a capability with neither a fixture nor an acknowledged gap fails the build, fixtures are
  recorded only from sanitized real history, and the first incident fixture (a real escalation into
  a room, closed the same day) joins the corpus.

- **Reliability and maintenance pass.** The Slack write slot now defers its scheduler item instead
  of reporting success, ending a busy loop that issued thousands of database transactions per second
  for a second after every Slack message. Shutdown waits for the service workers to drain before the
  store and Coop connections close. Every bound on operator and model text is UTF-8 safe through one
  shared helper, so a title or error containing an emoji can no longer be stored as invalid UTF-8.
  Audit, timeline, and incident-failure writes log their errors rather than discarding them.
- **Hermetic Git publication.** The isolated publication checkout no longer inherits the service
  environment or the operator's global and system Git configuration, so no credential is visible to
  a Git subprocess and no configured hook path can run in it. Command output is bounded while the
  process runs, and every commit identifier is validated before it reaches a command line.
- **Schema baseline.** The first forty migrations are collapsed into one readable baseline. Fresh
  installs create the current schema directly instead of replaying four decades of table rebuilds,
  and the unused episode effect ledger is dropped. Deployed databases upgrade in place after the
  usual verified private backup.
- **Context-aware humor.** Emisar may add a brief, understated joke in relaxed or playful Slack
  conversation while remaining direct and professional by default. High-risk and stressful
  situations stay serious, and humor is excluded from evidence, memory, titles, controls, and
  approval or action records.
- **Plain-language Slack responses.** User-facing answers now default to clear professional
  language, explain necessary technical terms, match the requested depth, and reuse established
  context for simple explanations instead of repeating an investigation. Progress labels and saved
  evidence summaries now use operator-facing language rather than internal workflow terminology.
- **Reaction-aware conversation.** Emisar now observes additions and removals of emoji reactions on
  its own Slack messages, retains them as ordered conversation context, and refreshes current
  reaction state without starting a separate agent turn. Reactions remain social feedback only and
  never authorize an approval, repository change, incident, or infrastructure action.
- **Statistical model release gate.** Real-model evaluation now includes human-calibrated Slack
  quality judging, deterministic Block Kit UX validation, labeled proactivity precision and recall,
  repeated per-case variance gates, digest-bound private baselines, stateful cross-channel and
  old-thread scenarios, independent evidence re-checks, public Coop lifecycle assertions, and an
  opt-in writable task case that verifies the actual commit, changed paths, and Coop review instead
  of trusting completion prose.
- **Team-aware participation.** Shared-channel triage now maintains a compact operational situation
  with active topics and open loops, applies a host-enforced attention budget, supports bounded
  lightweight standard or workspace-custom Slack reactions, and projects every accepted agent run
  as a durable Slack-visible commitment. Explicit mentions summon read-only triage in every channel
  where Emisar is a member, independent of proactive-channel configuration. Delivered answers open
  a bounded channel-or-thread continuation window so teammates can follow up without repeating the
  mention.
- **Progressive onboarding.** New channel setup starts with safe one-click defaults and expands to
  the existing typed conversational wizard only when an operator chooses customization.
- **Durable work scheduler.** One lease-token scheduler now owns control, background, per-incident,
  and maintenance work without in-memory retry clocks or overlapping timer loops. It reclaims
  expired leases, isolates incident failures, bounds agent finalization, loads fresh Slack context,
  orders cards and native statuses monotonically, exposes queue and heartbeat health, and creates a
  verified private backup before schema migration.
- **Typed Slack behavior.** Explicit operator requests can offer bounded investigation preferences
  or read-only channel rules with normalized confirmation cards, scope, expiry, source filters,
  deterministic matching, ordered execution, retry deduplication, management controls, and
  lifecycle cleanup. Arbitrary remembered prose never becomes an executable instruction.
- **Conversational channel setup.** New-channel onboarding offers typed Slack buttons, accepts
  natural-language answers, follows operators safely between channel and thread, rejects stale or
  unrelated controls, makes the always-invited operator baseline explicit, and saves nothing until
  the complete channel behavior is confirmed.
- **Slack-native incident rooms.** Authenticated Grafana and generic webhooks create correlated,
  deduplicated incident channels with accessible stateful cards, durable manual handoffs,
  progressive thread updates, immediate working states, and lifecycle-aware controls.
- **Isolated Coop investigations.** Each incident receives a policy-bound Coop session and fork
  with Emisar MCP access, bounded budgets, change inspection, review, cancellation, and parking.
- **Crash-safe delivery.** SQLite-backed webhook, Slack, outbox, and turn queues preserve
  idempotency across restarts, expose terminal failures, and support explicit audited replay.
- **Production operations.** The distribution includes strict configuration, preflight checks,
  systemd and nginx examples, Prometheus health surfaces, signed checksums, and provenance
  attestations.
- **Managed foreground Coop.** Optional Coop supervision starts the local session controller,
  waits for readiness, restarts unexpected exits, strips Responder secrets from the child, and
  shuts the process group down with Responder.
