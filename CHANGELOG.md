# Changelog

## Unreleased

- **Typed Slack behavior.** Explicit operator requests can offer bounded investigation preferences
  or read-only channel rules with normalized confirmation cards, scope, expiry, source filters,
  deterministic matching, ordered execution, retry deduplication, management controls, and
  lifecycle cleanup. Arbitrary remembered prose never becomes an executable instruction.
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
