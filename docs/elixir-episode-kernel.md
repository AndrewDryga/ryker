# Elixir episode kernel

This is the lifecycle core of the replacement Responder. It remains independent from Slack, GitHub,
Coop, and the legacy SQLite database, and is now composed by the generic ingress, admission, Work,
Delivery, and state-tool modules.

## Boundary

The caller is a trusted ingress adapter inside Responder. It must resolve platform and source-system
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

The [generic ingress and admission module](elixir-ingress-admission.md) uses this kernel without
teaching the host about individual Slack apps, GitHub payload shapes, webhook senders, or provider
message formats.

## Cutover deletion map

The replacement modules now compose the kernel through generic ingress, admission, Work, delivery,
state, publication, approval, retention, Slack, and GitHub boundaries. Wiring them into the deployed
service still requires authorized live Slack, GitHub, and Emisar acceptance. At that final cutover,
delete the superseded Go paths instead of keeping a permanent compatibility mode:

- operation-array folding, carry, and correction retry protocols;
- persisted phase/progress ticks and synthetic episode rechecks;
- duplicate alert assessment, coverage, finding, and operational-goal writers;
- duplicate engineering lifecycle state outside Coop tasks;
- legacy wakeup context reconstruction and destination fallback routing; and
- writable use of the old SQLite episode, attempt, progress, outcome, and wakeup projections.

The one-shot [Elixir replacement cutover](elixir-cutover.md) imports only reviewed necessary live
state: unexpired memory, behavior, schedules, unfinished episodes, and their open waits. The wider old
corpus remains read-only audit and fixture provenance; it is never a replacement runtime reader or a
dual-write target.
