# Elixir episode kernel

This is the first isolated module of the replacement Responder. It is deliberately not connected to
Slack, Coop, the Go runtime, or the legacy SQLite database yet.

## Boundary

The caller is a future trusted ingress adapter inside Responder. It must resolve Slack and source-system
events into stable episode keys, native input IDs, revisions, destinations, logical turn references,
and host-owned transition references. User and app text is data inside the bounded payload; it cannot
choose an episode ID, destination, owner, or authority.

The kernel owns only:

- immutable destination and history linkage;
- one durable owner at a time;
- chronological input custody;
- input and event waits with explicit trigger inputs;
- result-to-delivery custody;
- owner-fenced terminal cancellation that retires queued work and waits;
- natural idempotency and stale-revision rejection; and
- an immutable event transcript plus a current projection in one transaction.

It performs no network calls and starts no model. Offline replay uses the same reducer as persistence.

## Legacy test parity

The checked-in [Go lifecycle test parity](elixir-episode-kernel-go-parity.md) assigns every test in the
scoped legacy lifecycle files to this kernel or a named future replacement module. Its fast drift test
prevents a relevant Go regression case from disappearing unnoticed during the staged rewrite.

The next completed boundary is the [generic Slack admission module](elixir-slack-admission.md), which
uses this kernel without teaching the host about individual Slack apps or provider message formats.

## Cutover deletion map

Later modules must reach parity before the replacement runtime is wired. At the final cutover, delete
the superseded Go paths instead of keeping a permanent compatibility mode:

- operation-array folding, carry, and correction retry protocols;
- persisted phase/progress ticks and synthetic episode rechecks;
- duplicate alert assessment, coverage, finding, and operational-goal writers;
- duplicate engineering lifecycle state outside Coop tasks;
- legacy wakeup context reconstruction and destination fallback routing; and
- writable use of the old SQLite episode, attempt, progress, outcome, and wakeup projections.

The old corpus remains read-only test provenance. It is not imported as active runtime state.
