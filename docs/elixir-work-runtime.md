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
tools own durable records. The generic Delivery module owns external message and reaction custody.

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
9. Model workers cannot claim delivery work. A separate bounded Delivery pool claims the frozen
   intent, renews its independent lease across bounded provider I/O, selects only a trusted transport
   adapter, and records a typed external receipt atomically.

## Reliability rules

- Process clocks do not decide leases or retry time; PostgreSQL does.
- A worker cannot choose episode policy. Admission chooses only the abstract conversational,
  standard, or deep class and maps it through a host-owned profile. Existing episodes retain their
  pinned policy across deploys and later classifications.
- Every class policy carries Coop's model-independent authority digest. The three classes must share
  it, each eligible fleet worker must advertise it, and the created Coop session must return it.
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
- Every model-visible input carries one immutable host-issued `source_ref`. Slack and GitHub inputs
  use their opaque platform source references; a generic input uses its episode-admission reference.
  State tools can therefore cite or propose memory from the current instruction without guessing a
  raw platform ID or an internal database key.
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
- Delivery retries are bounded independently from model execution. Permanent platform errors and
  exhausted transient retries preserve the exact accepted result in operator-rearmable blocked
  custody instead of polling a provider forever. Operators inspect or rearm that immutable intent by
  durable reference with `mix responder.delivery list|show|rearm`; a rearm starts a separately audited
  retry generation with a fresh bounded attempt budget.

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
- separate work and delivery claim phases;
- a supervised optional worker pool reaching a validated delivery intent; and
- generic Slack/GitHub delivery settling only after an exact typed receipt.

The expanded parity manifest assigns 230 retained Go tests to replacement owners. Stage 3 claims only
the cases its tests already prove. Typed state-tool carry and privileged GitHub completion guards are
owned by their dedicated modules. Generic transport rendering and external response-loss
reconciliation are described in
[platform adapters and delivery](elixir-platform-adapters.md).

## Model behavior evaluation

The checked-in Work corpus uses the production prompt, universal final-result schema, and semantic
validator. Its offline suite proves that semantic rejection remains in the same Coop turn, that
byte-identical correction attempts receive distinct attempt-bound validation keys, and that a
host-valid but behaviorally wrong result fails instead of being silently accepted.

```console
scripts/elixir-test.sh test/responder/evals
MIX_ENV=test mix responder.eval work-pack
MIX_ENV=test mix responder.eval work --config /absolute/responder-elixir.yaml
MIX_ENV=test mix responder.eval world-pack
make eval-world-smoke CONFIG=/absolute/responder-elixir-eval.yaml
make eval-world CONFIG=/absolute/responder-elixir-eval.yaml
```

`work-pack` compiles the sanitized narrow final-contract corpus without a model. Its live command runs each case through
the dedicated `model_evals.socket` in an isolated Coop session under `model_evals.no_tools_policy`,
which must be read-only and expose no
tools. It currently covers a useful direct answer, the Slack/GitHub/platform-adapter product
boundary, and shadow-mode no-delivery. Accepted cases are closed, checked with Coop's exact discard
plan, and discarded only when the workspace is clean. Unsafe cleanup fails the eval and retains the
session for inspection.

The separate world lane proves behavior with tools. `eval-world-smoke` runs eight high-value cases
once at a strict 100% floor. The release `eval-world` gate runs the full corpus three times for a
dedicated candidate policy and a separately pinned baseline policy in the exact same deterministic
world, enforcing aggregate, per-case, hard-invariant, `UNRUN`, and paired-regression limits. One
versioned scenario directory is shared
by deterministic host replay and real-model execution. Its production Responder state tools are real
and lease-authorized against an empty disposable PostgreSQL database; its metrics, scheduler, GitHub,
and similar external tools are a strict recorded cassette. Calls match important normalized
arguments rather than a global order, controlled failures are replayed per rule, and unmatched calls
return a bounded error instead of fabricated data. Visible output goes only to the inert `eval`
transport. Hard checks run first, then a tool-free judge session scores every human-language rubric
criterion exactly once. Missing judge evidence remains `UNRUN`, never green.
The eval socket cannot equal the production Coop socket. Before any model turn, Responder verifies the
exact policy digest and Coop's public `repository_read_only` bit; the dedicated daemon is deployed
without production environment, credentials, network mutation tools, or project MCP configuration.

## Configuration

`Responder.Work.Runtime` is optional. Its trusted configuration contains only:

- `socket`: local Coop Unix socket;
- `worker_ref`: stable identity prefix for this local worker pool;
- `concurrency`: optional local slot count, from 1 through 32 (default 4); and
- `source_and_action_tools`: optional exact names from the MCP catalog exposed by the pinned Coop
  policy; these names make the frozen model context truthful but confer no authority; and
- optional bounded polling and receive timeouts.

The Work runtime does not contain a model router. The adapter freezes a three-class Work profile at
ingress, admission selects one abstract class, and Coop resolves the selected policy to its immutable
target. The recommended targets are Terra/medium for conversational work, Sol/medium for standard
work, and Sol/xhigh for deep work. Keep those three policies authority-equivalent. Writable task
execution remains a separate confirmed contributor policy rather than a `deep` side effect.

Obtain both `policy_digests` and `policy_authority_digests` from
`coop sessions policies --policies /etc/coop/session-policies.yaml --json`. Copy the matching full
digest and shared authority digest into every Work profile and worker advertisement; never derive or
hand-write either digest in Responder.

For example:

```elixir
config :responder, :work,
  socket: "/var/lib/responder/coop/control.sock",
  worker_ref: "responder-work:host-a",
  concurrency: 4,
  platform_tools: ["list_runners", "find_actions"],
  poll_interval_ms: 250,
  receive_timeout_ms: 30_000
```

The YAML field is named `work.source_and_action_tools`; the internal runtime option is
`platform_tools`. The configured names must exactly match tools actually supplied to that Coop
policy by its owner-private MCP configuration. Responder never reads MCP credentials, and an
incoming Slack, GitHub, webhook, or Conversation Lab message cannot add a tool or change this list.
All of those sources share the same trusted Work runtime. Conversation Lab also installs a loopback
implementation of the exact Slack chat capability schemas: `list_slack_channels`, `search_slack`,
`read_slack_source`, `set_slack_reaction`, and `post_slack_message`. In a Lab turn those tools expose
one virtual workspace scoped to the current Lab conversation. Reads return only its durable messages;
reactions and confirmed additional posts use the ordinary platform-action outbox but settle back into
the local timeline. Human feedback reactions on delivered replies are passive ordered episode events:
they do not wake work, but both the bounded add/remove history and current counts are frozen into the
next logical turn. Lab message edits and deletes use the same stable-item revision contract as provider
adapters. Every result identifies the adapter as emulated with external effects disabled.
This lets the model make the same chat/tool/card choices without generating Slack test traffic or
receiving a Slack credential. Configured repository and Emisar tools remain real and retain the exact
Work policy authority. Incident offers start a real linked Work episode in the Lab under that pinned
authority; the virtual incident stays in the Lab timeline instead of fabricating a Slack channel.
Slack workspace audience rules, real workspace data, and Slack API provisioning still require the
authenticated Slack adapter and its disposable live qualification.

All slots must reach the same Coop daemon. The persisted Coop session ID is not yet paired with a
routable execution endpoint, so this stage does not claim cross-machine lease takeover. Durable
execution placement and takeover are a later boundary.

The worker never accepts a policy, repository, provider, credential, Slack destination, or tool set
from an incoming event. Those are admitted and pinned by their owning boundaries.

## Retention and cleanup

`Responder.Retention.Runtime` owns both remote workspace cleanup and local data horizons. For every
terminal episode it closes only the exact Coop session recorded in PostgreSQL, waits the configured
grace period, fetches an exact discard plan, and then:

- discards a clean workspace with no unreviewed changes;
- discards clean committed work only after its publication is durable;
- retains dirty or unpublished work for an operator; and
- blocks on crossed session identity, authority, or ambiguous cleanup instead of guessing.

Blocked cleanup exposes its exact phase and bounded diagnostic in the local control plane. A
confirmed operator may rearm that same phase without changing the frozen session identity. A clean
workspace retained only for unpublished, unmerged commits may be explicitly discarded, but that
action always obtains a fresh Coop plan with unmerged acceptance; dirty work remains retained. Both
actions are idempotent and leave an audit row.

Large ingress, prompt, candidate, validation, delivery, and artifact bodies are redacted on the
operational horizon only after all of the episode's Coop sessions are proven discarded. The episode
event stream remains coherent until `episode_history_seconds`; it is never thinned one event at a
time. Open waits, blocked turns, pending approvals, live schedules, unpublished changes, active
incident rooms, and unresolved state records pin that history regardless of age. Compact session and
delivery receipts remain until `audit_data_seconds`. Pruning runs in bounded batches and short
transactions so retention cannot monopolize a busy database. Every table has an executable retention
class, and every age/lease comparison uses PostgreSQL time.
