# Changelog

## Unreleased

- **Team-aware participation.** Shared-channel triage now maintains a compact operational situation
  with active topics and open loops, applies a host-enforced attention budget, supports bounded
  lightweight standard or workspace-custom Slack reactions, and projects every accepted agent run
  as a durable Slack-visible commitment.
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
