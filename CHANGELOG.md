# Changelog

## Unreleased

<!--
Everything below is prepared for the first tagged release. To cut it:
  1. change the heading above this block to "## v0.1.0 - <date>" and delete this comment
  2. re-express minimumUpgradableVersion in internal/store/schema.go against the released
     version rather than "oldest deployed database" (its comment says how)
  3. tag and push; the release workflow does the rest
Nothing here needs writing first — this is the whole preparation.
-->

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
