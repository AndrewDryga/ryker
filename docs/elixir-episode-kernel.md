# Elixir episode kernel

This is Ryker's lifecycle core. It remains independent from Slack, GitHub, and Coop, and is
composed by the generic ingress, admission, Work, Delivery, and state-tool modules.

## Boundary

The caller is a trusted ingress adapter inside Ryker. It must resolve platform and source-system
events into stable episode keys, native input IDs, revisions, destinations, logical turn references,
and host-owned transition references. User and app text is data inside the bounded payload; it cannot
choose an episode ID, destination, owner, or authority.

The kernel owns only:

- one immutable progress home (the episode destination) and history linkage;
- a per-message origin projection: every admitted input keeps the exact transport, conversation,
  thread, native root/reply kind, and source identity it came from, so answers return to the
  input's own thread while progress stays at the home;
- scoped correlation claims: a validated occurrence identity (workspace or security domain plus the
  reporting source namespace) has at most one active owning episode, which is the only
  cross-conversation uniqueness fence. Each claim carries its own lifecycle state, so one recovered
  run or alert never states that the incident is over; a finished or cancelled episode retires its
  claims, so a later report of the same object starts its own work instead of being refused;
- one durable owner at a time;
- chronological input custody;
- input and event waits with explicit trigger inputs;
- result-to-delivery custody;
- owner-fenced terminal cancellation that retires queued work and waits;
- natural idempotency and stale-revision rejection; and
- an immutable event transcript plus a current projection in one transaction.

It performs no network calls and starts no model. Offline replay uses the same reducer as persistence.
Origins are projected in the same transaction as the `input_admitted` event and are rebuilt from the
ledger; the migration backfill derives a Slack root or reply from the retained identities (a root
binds its own timestamp as thread) and records `conversation` for everything else rather than
guessing native provenance. Claims are never backfilled: they exist only once a trusted source
identity has been validated at admission. Only an identity the adapter itself resolved may be
claimed — a GitHub item reference, or a typed publication-lifecycle run whose state the adapter also
authenticates. A service name, alert rule, URL, or old incident id quoted inside app text is a
ranking clue and never an exclusive claim, because two genuine incidents can share it.

## Correcting a routing mistake

Correlation is a judgement, so it can be wrong in both directions. `Ryker.Episodes.Corrections`
repairs it through the governed operator action boundary, which makes each correction idempotent by
its action reference and records who confirmed it:

- **merge** moves every effective input of one episode into another, moves its trusted occurrence
  claims with that evidence, and retires it as an active routing and work owner. A retired source is
  never offered as a candidate again, so the next message cannot recreate the split.
- **split** detaches named inputs from an episode; they belong to no work until one admits them again.
- **reassign** moves named inputs from one episode to another existing one.

Nothing is rewritten. The event ledger, the submitted prompts built from it and every delivery
receipt stay exactly as they were; the origin row that held the old membership remains, marked
ineffective and pointing at the correction that moved it, and the correction row keeps the original
membership, the actor, the confirmation and the reason.

A correction is refused rather than guessed. Both episodes are locked in identifier order and the
first custody that would have to act on the moved evidence blocks it by name: a running turn, an
undelivered answer, an open event wait, a pending platform action, an unfinished publication, or an
active schedule. A source that is merely waiting is stopped through the kernel's own owner-fenced
cancellation, which retires its queued work and waits; no completed action is rerun, no approval
becomes new authority, and no accepted answer is cancelled. Removing evidence also installs the next
session generation, so the following turn starts from a Coop session whose transcript never saw the
removed text instead of relying on last-step redaction.

The [generic ingress and admission module](elixir-ingress-admission.md) uses this kernel without
teaching the host about individual Slack apps, GitHub payload shapes, webhook senders, or provider
message formats.
