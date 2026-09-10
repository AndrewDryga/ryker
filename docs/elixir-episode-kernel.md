# Elixir episode kernel

This is Responder's lifecycle core. It remains independent from Slack, GitHub, and Coop, and is
composed by the generic ingress, admission, Work, Delivery, and state-tool modules.

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

The [generic ingress and admission module](elixir-ingress-admission.md) uses this kernel without
teaching the host about individual Slack apps, GitHub payload shapes, webhook senders, or provider
message formats.
