# Elixir work runtime

Stage 3 turns one admitted episode into durable, locally pooled model work. It is deliberately
generic: no Slack provider name, alert type, repository name, or incident checklist affects this
runtime.

## Boundary

The episode kernel remains the lifecycle authority. The Work module stores only the identities and
bytes needed to safely execute that episode through Coop:

- one immutable Coop session generation with its admission-pinned policy;
- one episode-scoped logical turn row;
- the exact frozen prompt, context, output schema, and contract version;
- the exact unpublished candidate and candidate attempt;
- the exact semantic verdict before Coop is mutated;
- one accepted result and, for a visible reply, one delivery intent;
- one fenced PostgreSQL lease and bounded failure state; and
- one durable remote-cancellation intent and proof.

There is no mirrored provider transcript, progress-event stream, attempt table, alert profile, or old
typed-operation union. Coop owns provider execution. The episode kernel owns lifecycle. Later state
tools own durable records. Transport gateways will own external delivery.

## End-to-end flow

1. Admission commits the input and pins a trusted Coop policy in the same transaction.
2. One slot in the local worker pool claims only a `turn` owner using PostgreSQL time and
   `FOR UPDATE SKIP LOCKED`.
3. The runtime freezes the exact self-contained first briefing. A continuation in the same healthy
   Coop session sends only new input plus a parent-submission reference.
4. Coop creates the session and turn under stable operation keys derived from immutable local rows.
5. Responder stores each candidate's exact bytes, SHA-256, and attempt before validation.
6. The universal validator returns every hard, actionable violation at once. Rejection continues in
   the same Coop turn and session.
7. Responder freezes the exact accept or reject mutation before calling Coop. Lost responses are
   reconciled by operation key and current turn state.
8. A validated accept atomically stores the result and advances the episode. A visible result becomes
   `delivery_pending`; deliberate silence settles immediately with an audited reason.
9. Model workers cannot claim delivery work. A later transport gateway will claim that phase
   separately.

## Reliability rules

- Process clocks do not decide leases or retry time; PostgreSQL does.
- A worker cannot choose episode policy. Existing episodes retain their pinned policy across deploys.
- A frozen submission never changes under one operation key, even after a process crash or deploy.
- Only a confirmed failure that produced no remote resource may spend a create or submit generation.
- Only `session_cleanup_error`, while the exact candidate still awaits validation, may spend a
  validation generation. Other confirmed validation failures block instead of looping.
- `operation_uncertain` never receives a new key unless the public remote resource proves the result.
- Candidate identity is `(attempt, SHA-256)`, so byte-identical correction attempts remain distinct.
- A completed validation receipt must carry that same attempt as well as the exact candidate digest;
  an older byte-identical receipt cannot settle a newer candidate.
- At most two exact current input envelopes advance into one turn. This keeps the original request
  and one correction together under the 160 KiB context ceiling; further inputs remain durably
  ordered for later turns instead of being truncated. If corrected work blocks again, the next
  recovery pair keeps the original request and the newly triggering correction; the consumed
  correction remains durable history instead of hiding newer feedback.
- Inputs still in `queued_input_refs` are future work, not compact history. They are absent from the
  current prompt until the kernel advances their exact envelopes into the next active pair.
- Actual transient failures use bounded exponential backoff and enter remote-stop custody after
  eight failed claims. A healthy running Coop operation or turn yields its lease without spending
  that failure budget.
- Interrupted, cancelled, budget-exhausted, or otherwise unsafe terminal turns are surfaced in
  blocked custody; the host does not silently replay a human instruction after Coop says send intent
  may have happened.
- An active remote turn must be cancelled through Work custody. Responder first freezes the intent,
  reconciles Coop's idempotent cancellation, and only then cancels or transfers the episode owner.
- If Stop races a prepared create or submit before a remote resource is known, Responder calls Coop's
  exact operation fence. The fence either prevents that mutation from starting or returns the
  operation/resource that already won the race. Cleanup never creates fresh work after authority was
  revoked, and a lookup miss or timeout is never treated as proof of absence.
- The exact accepted result survives newer queued input. New input advances only after the accepted
  visible reply is delivered, or after deliberate no-delivery settlement.

## Universal final result

The model returns one small JSON document:

```json
{
  "delivery": "reply",
  "message": "Human-facing answer",
  "decision_reason": null,
  "outcome": {
    "state": "complete",
    "record_refs": [],
    "artifact_refs": []
  }
}
```

`delivery` is `reply` or `none`. Silence requires a short audited `decision_reason`; a direct human
request cannot silently disappear. `state` is `complete`, `waiting_for_input`, or
`waiting_for_event`. A waiting result must reference exactly one already-durable wait record. The
host validates identifiers, authority, pending state, destination, receipts, and exact bytes. It does
not deterministically judge prose quality, root cause, or domain completeness.

## What the fast tests prove

The deterministic suite uses PostgreSQL and a scripted Coop fake; it calls neither a model nor a
network service. It covers:

- simultaneous local-pool claims and stale-lease fencing;
- persisted policy, session, prompt, candidate, verdict, and result identity;
- same-session delta continuation instead of resending the full briefing;
- bounded exact input pairs with every remaining instruction retained in chronological custody;
- one-turn semantic repair;
- lost submit, validation, and cancellation responses;
- Stop racing both pre-send and already-admitted session/turn mutations;
- exact validation-cleanup recovery and unsafe validation failure blocking;
- remote cancellation before local cancellation or owner transfer;
- new input not erasing an accepted reply;
- question and event-wait continuation after delivery;
- bounded retry and permanent blocked custody;
- separate work and delivery claim phases; and
- a supervised optional worker pool reaching a validated delivery intent.

The expanded parity manifest assigns 230 retained Go tests to replacement owners. Stage 3 claims only
the cases its tests already prove. Typed state-tool carry, GitHub completion guards, model behavior
evaluations, transport rendering, and external response-loss reconciliation remain later modules.

## Configuration

`Responder.Work.Runtime` is optional. Its trusted configuration contains only:

- `socket`: local Coop Unix socket;
- `worker_ref`: stable identity prefix for this local worker pool;
- `concurrency`: optional local slot count, from 1 through 32 (default 4); and
- optional bounded polling and receive timeouts.

For example:

```elixir
config :responder, :work,
  socket: "/var/lib/responder/coop/control.sock",
  worker_ref: "responder-work:host-a",
  concurrency: 4,
  poll_interval_ms: 250,
  receive_timeout_ms: 30_000
```

All slots must reach the same Coop daemon. The persisted Coop session ID is not yet paired with a
routable execution endpoint, so this stage does not claim cross-machine lease takeover. Durable
execution placement and takeover are a later boundary.

The worker never accepts a policy, repository, provider, credential, Slack destination, or tool set
from an incoming event. Those are admitted and pinned by their owning boundaries.
