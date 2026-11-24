# Changelog

## 0.6.6

- Fresh Compose installations and development boxes use PostgreSQL 19. Existing
  Compose installations can follow the [database upgrade procedure](docs/operations.md#upgrade-the-bundled-postgresql-18-database-to-19)
  to retain their data. The installer detects a running older database before replacing it.
- Slack receipt history, knowledge lookups and workspace cleanup continue to use
  their indexes on PostgreSQL 19.
- Updated Postgrex to 0.23.0 and Phoenix LiveView to 1.2.15.

## 0.6.5

- A Slack mention can pick up the original request and its constraints from a
  thread parent or the preceding message in a direct conversation.
  Ryker distinguishes a queued task card from a delivered one, and a merged pull
  request shows the last CI result GitHub reported.
- For planned jobs, Ryker can ask which identity the job will use before code exists.
  When verification needs an operator, Ryker asks for the exact result and checks
  later audit evidence in the original request's scope.
- Interrupted Coop work can resume from its saved state. GitHub CI repair updates
  appear when a repair round starts.
- The repository picker groups search results and keeps import actions below them.
- Updated `db_connection` to 2.10.3 to address CVE-2026-133555.

## 0.6.4

- Automatic GitHub issue triage requires repository write access. Ryker rechecks
  permission and the issue text before starting work.
- A comment or review on a maintainer's pull request can request work only when
  its sender has write access. Repository auto-add requires a trusted installation.

## 0.6.3

Ryker checks for group DM history permission during Slack setup. This permission lets
it look for an existing reply or task card before posting, so a retry can avoid
posting a duplicate. Existing Slack installations can add `mpim:history` to the bot
scopes and reinstall the app to grant it.

## 0.6.2

- **Cleanup can recover when a worker's planning response is lost.** When the worker
  confirms the previous safety check failed internally, Ryker requests a fresh check.

- **Add repositories has a compact search toolbar and a sticky footer.** Search shares
  a row with the selection buttons when there is room, and the Add buttons stay in view
  while you scroll the list.

## 0.6.1

- **Cleanup failures are easier to scan.** The reason and actions come first, and the
  checklist opens on demand. Known worker error codes appear when Ryker has saved them.

- **Repository imports have their own GitHub setting.** The picker shows already-added
  repositories without a checkbox. Set automatic imports under Integrations → GitHub.

- **The environment's repository picker keeps search beside bulk selection.** The selected
  count and default repository are shown below the list.

## 0.6.0

- **Build presets on the Models page.** **Add preset** opens a page that picks the lead's models
  and each role's with the same rows every list of models uses: a model, a reasoning effort, fast
  mode and an account, with fallbacks in order. A role gives a second opinion, does the work it's
  given, or works inside the lead's session, and says when the lead should call it. Ryker saves
  the recipe Coop's export would hold, so pasting that export is gone. A preset that code reviews
  run can't gain a role that changes files.

- **Saving a card on the Models page keeps the preset choices.** Saving Requests or Model accounts
  took Code reviews and Code changes off the page until it was reloaded.

## 0.5.1

- **Routing can recover from a worker interruption.** Messages keep their retry budget
  while the worker is still running their command or is within its reconnect window.
  After a successful worker response, recent messages stopped by a command timeout
  get one recovery attempt using their original operation keys.

## 0.5.0

- **Fast mode.** Each model on the Models page has a Fast box beside its effort. Ticked, the
  worker runs that model in its provider's fast mode, about twice as fast: Codex's Fast tier, which
  uses more of the plan's allowance, or Claude's fast mode, billed at a higher rate. A model
  without a fast mode runs at standard speed. Such a job goes only to a worker on a co:op that
  accepts fast targets, so deploy the new worker image too. Cost estimates still use each model's
  standard prices.

## 0.4.0

- **No more deadlocks between a worker's poll, a command and a task's turn.** Sending a command,
  and retention's cleanup, now lock the workers holding a session before the session, the order a
  poll and placement already used. PostgreSQL broke a three-way cycle of these twice on 21 Nov.

- **A worker's progress isn't held up by redaction.** Preparing a worker's events read the
  configured secrets once per field of every event while the worker's row was locked; a large
  batch ran past the 15-second limit and lock waits piled up behind it. They're read once per
  batch now. A tool's answer no longer fails when the check for new thread messages that follows
  it times out on a busy task.

- **A worker that missed an acknowledgement catches up.** A worker resends events Ryker already
  kept when it never heard they were kept (its VM replaced mid-poll, for example). Ryker refused
  the whole batch as a conflict, 20,000 times over six hours for one VA1 worker. Events it already
  holds are now checked against what it stored, and the rest are applied.

- **A submodule Ryker can't fetch stops a task at once and is named.** A submodule whose
  `.gitmodules` entry is missing, listed twice or not a GitHub repository used to read as GitHub
  failing for a moment: the task retried eight times, then said Ryker couldn't get the code from
  GitHub. It now stops on the first try, and the failure page names the repository and the
  submodule's path. A repository's RYKER.md write stops on such a submodule, or one Ryker was never
  given, until the next daily check instead of retrying every minute.

- **Kinds of work still on the models Ryker shipped move to the newest.** GPT-6.2 Sol replaces
  GPT-5.6 Sol, and GPT-6.1 Terra replaces GPT-5.6 Terra for conversation, on upgrade and on new
  installations; both cost less. A model you chose yourself, and every fallback, stays.

- **Presets are added on the Models page.** Paste what `coop presets NAME --export-job` prints
  under Settings › Models › Presets, instead of placing a file in the controller's state volume.
  Code reviews and Code changes offer a preset once one can run, and aren't shown while there is
  nothing to choose. A file placed under `/var/lib/ryker/presets` is no longer read: paste it
  instead.

- **Calmer type and a wider menu.** Text is a step smaller than in 0.3.0 (body 16 px, nothing
  under 13 px), and the left menu is wider, with its items lined up under the logo.

- **A worker's storage reads against its disk.** In use shows everything on the worker's disk out
  of its size ("29.1 / 300 GiB"), and the bar shows how full the disk is, turning amber once the
  worker reaches the free-space reserve and stops taking new copies.

- **A caveat is a small amber clock, not a line of text.** A worker's storage reading that is out
  of date, an account whose limit is used up, and an account check that may be stale show a clock
  whose tooltip says why. Integrations › GitHub shows the day's event count with the connection,
  and Disconnect sits beside Replace credentials.

## 0.3.2

- **Worker VM disks can grow in place.** Increase the backing filesystem first, then raise
  `DATA_GIB` and restart the worker. The VM grows its existing disk under the worker lock and
  preserves enrollment, sign-ins and working copies.

## 0.3.1

- **Claude Fable 5.2, GPT-6.2 Astra and Sol, and GPT-6.1 Terra can be chosen.** They are priced
  and offered on the Models page, on new installations and on upgrade, without replacing a price
  you already saved: Fable 5.2 at $8 in, $0.20 cache reads and $40 out per million tokens, GPT-6.2
  Astra at $8, $0.40 and $40, GPT-6.2 Sol at $2, $0.10 and $10, and GPT-6.1 Terra at $1, $0.05 and
  $5. Workers run a newer co:op, with Claude Code 2.1.330 and its editor adapter 0.109.0, the
  first to accept Fable 5.2, and Codex 0.170.0. Deploy the new worker image too: older workers
  refuse Fable 5.2.

## 0.3.0

- **Upgrade the controller before the workers.** Workers built from this release report each
  model account's limits in their poll, and an older controller refuses a poll it cannot read.
  Deploy the new controller image first, then the new worker image.

- **Settings › Models shows each account's limits.** Under every model account is what its
  provider last reported: each window's use and reset ("5-hour limit · 18% left · resets in 42
  min"), credits, the plan, and when the worker checked. A model whose account has used up a
  window says so beside its account.

- **Claude models can be chosen.** Claude Opus 5.5, Sonnet 5.5, Haiku 5.5 and Fable 5.1 are
  priced and offered on the Models page, on new installations and on upgrade, without replacing a
  price you already saved.

- **Slack and GitHub setup guides.** Integrations › Slack walks through creating Ryker's Slack app
  from its manifest, with a link that opens Slack's form already filled in and the manifest to
  copy. Integrations › GitHub follows GitHub's own App form from top to bottom: the Redirect URI,
  the webhook URL and a webhook secret shown with a copy button before anything is saved (the same
  one after a reload), the permissions and events to set, then the App ID and key to bring back.
  Replacing a connected App's key keeps its webhook secret.

- **Connecting a worker you run yourself.** While no worker has connected, Settings › Advanced
  shows the steps: install co:op, sign in the model accounts, make a one-time token here, then run
  the commands it shows, with this installation's worker address and certificate authority filled
  in.

- **Environments.** The repository search has its own field, and Select all and Select none act
  on what the search shows. A newly connected Emisar account serves no environment until you
  choose it there; until now the first account was saved on every environment that had none.

- **Add repositories** says when each repository last changed, newest first.

- **Setup** finishes its last step with any reply Ryker delivered in Slack, in any channel, a
  quick reply included.

- **Easier to read.** The console's type is larger, and every page shares one column: the same
  left edge and width for its header, cards and forms.

- **Fixes.** A restore that Coop refused while a repository's default branch had not been
  refreshed is sent again under a new key instead of failing the work.

## 0.2.2

- Ryker is rebuilt in Elixir. It installs with Docker Compose (`./install.sh`), keeps every queue
  in PostgreSQL, runs model work on Coop workers enrolled over mutual TLS, and has a local web
  console. The 0.1.0 notes below describe the earlier Go release, then named Responder.

- The Linux amd64 controller and Coop VM are available from GitHub Container Registry.
  Use the pinned image digests in the release’s `container-images.txt` to deploy them.

## 0.1.0

- **Standing authority stops being something you type.** `/responder assignments create
  repo=... class=... budget=... days=... paths=... signal=...` was the only way to grant a standing
  assignment, and it was the last verb in the emergency kit that handed out authority rather than
  reading or revoking it. It asked an operator to compose six bounds on unattended pull-request work
  without ever seeing what they would produce, and then confirmed their typing rather than the
  grant: a miscounted `paths=` was a repository-wide grant that read as a narrow one. It is now
  `offer_assignment`, a typed operation the model emits when an operator asks for standing work in
  words. The host normalizes every bound — the repository trimmed, the change class folded onto the
  closed allowlist, the budget and expiry filled in when the sentence did not say, the empty and
  duplicate path globs dropped, the signal collapsed to one line — and posts a confirmation card
  stating the normalized grant. Nothing exists before the click.

  The confirmation carries the memory-offer discipline in full, because this is the widest authority
  a single button in this product grants. Operator-only and workspace-membership checked again at
  the click rather than assumed from the card; the button value carries an episode id and an
  operation id and no bounds at all, so the offer is read back out of the episode's own event stream
  and re-validated through the validator that accepted it; a payload issued in another channel or
  more than twenty-four hours ago grants nothing. And what it creates is still shadowed — v78's
  refusal stands, `internal/assignments.Normalize` is the only constructor of the value the store
  would refuse, and clearing the flag remains a separate decision with an audit behind it.

  `assignments` stays a kept verb for `list`, `pause`, `resume` and `delete`: reading a channel's
  grants and taking one back are what an operator reaches for when Responder is the problem.
  `create`, `add` and `new` answer with a worked example of the sentence that replaced them, because
  an operator who typed a command that worked last week did not typo. `internal/assignments` lost
  its Slack import and its dependency on `internal/decision` to get here — `internal/investigation`
  validates the operation through `assignments.ValidateOffer`, so the bound a model reads in a
  correction is the bound the operator's click is measured against, rather than two copies that can
  disagree about what was granted.

- **An ambiguous incident stops walking its hypotheses one at a time.** The gate that decides
  whether an investigation has earned parallel branches landed pure and unwired; this connects it,
  as child episodes under the lead's incident. After a lead sweep's result is applied, the host
  recomputes claim clusters from the ledger the turn just wrote and answers the lead's own
  `plan_goal` proposals: admitted, each goal becomes a read-only child episode sharing the lead's
  incident — which is what makes the ledger shared for free, since `ListEpisodeEvidence` unions an
  incident's evidence into every episode under it — and refused, the reason lands on the lead's
  timeline as a sentence, because a trace that ran serially cannot otherwise be told from a broken
  feature. Branches record evidence, coverage and goal state; a branch completion completes only
  its own child and never the lead, and the branch's own turn is kept rather than discarded because
  the evidence the synthesis is waiting for is in it. The last branch to stop queues the lead's
  synthesis on the merged ledger, and only the lead completes the work. No migration:
  `work_episodes.parent_episode_id` has existed since v47.

  The fourth serializer is the one this had to defeat. `incidents.active_turn_id` reads as a
  per-incident gate and is really a per-session one — that column describes the lead's Coop session
  — so the first branch to submit would have parked every sibling behind a turn on a session none
  of them use. Branches are exempted from it in the lease and given forks of their own, serialized
  instead by the branch conversation key that already defeats the other two layers; restart
  recovery stops handing a branch the incident's session for the same reason. The 307-line
  orchestration is `internal/branching` and the reads are `internal/store/fanoutstore`, so
  `internal/service` grows by 25 lines of call sites and the gate itself still needs no database to
  test its refusals.

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
