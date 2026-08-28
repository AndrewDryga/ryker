# Elixir ingress and admission

This is the second isolated module of the replacement Responder. It accepts a bounded event from a
trusted adapter, stores it before reasoning, asks Coop for one generic model decision, validates that
decision, and commits it with the episode transition in PostgreSQL.

Slack is one adapter. The universal webhook is another. Neither path contains rules for Grafana,
Terraform, Better Stack, or any other sender. The model interprets the supplied content.

This module is not connected to the live Slack socket and is not enabled in any running Responder.

## Trusted envelope

Every adapter produces `Responder.Ingress.Input` with:

- source and event identity;
- actor identity and source capabilities;
- a host-owned delivery destination;
- occurrence time and revision; and
- arbitrary bounded JSON content.

Content cannot select a channel, thread, episode, model, Coop policy, or authority. The exact derived
episode command is validated before the input can enter the inbox.

The Slack adapter binds a top-level message to its own thread and preserves an existing reply thread.
The generic webhook binds every event to the destination in trusted route configuration.

## Universal webhook

The optional listener exposes:

```text
POST /v1/hooks/<configured-route>
Content-Type: application/json or application/*+json
X-Responder-Event-ID: <required unique occurrence ID>
X-Responder-Item-ID: <optional stable item ID shared by revisions; defaults to event ID>
X-Responder-Event-Type: <optional hint>
X-Responder-Occurred-At: <optional UTC ISO-8601 timestamp>
X-Responder-Revision: <optional positive integer, default 1>
```

The body may be any JSON value: object, array, string, number, boolean, or null. A `202` response means
the exact input is durably queued; it does not claim that model work has finished. An exact retry
returns the original receipt. Reusing the event identity with different data returns `409`.

Routes are explicit configuration. Each route owns its secret, payload limit, clock-skew limit, and
destination. The payload cannot override them. The listener defaults to loopback and starts only when
`:responder, :webhooks` is configured.

An isolated runtime can enable both halves with ordinary application configuration:

```elixir
config :responder, :admission,
  policy: "admission-read-only",
  socket: "/var/run/coop/control.sock",
  worker_ref: "responder:admission:local"

config :responder, :webhooks,
  ip: {127, 0, 0, 1},
  port: 4080,
  routes: %{
    "universal" => %{
      auth: {:hmac_sha256, System.fetch_env!("RESPONDER_WEBHOOK_SECRET")},
      destination: %{
        transport: "slack",
        conversation_ref: "slack:T0123456789:C0123456789",
        thread_ref: nil
      }
    }
  }
```

Internet exposure belongs behind the normal authenticated ingress proxy; the listener itself needs no
public interface.

Bearer routes send one `Authorization: Bearer <secret>` header. HMAC routes send a Unix timestamp and
`X-Responder-Signature: v1=<hex HMAC-SHA256>`. The signed bytes are these newline-separated values in
order:

```text
timestamp
request path
event ID
item ID or empty string
event type or empty string
occurred-at value or empty string
revision value or empty string
raw request body
```

Signing the identity and metadata prevents a captured body from being replayed as a new event. HMAC
timestamps must fall within the route's configured clock-skew window.

## Durable queue

`Responder.Ingress.Inbox` is the natural slot for one source occurrence. PostgreSQL stores the exact
normalized input before any model call. Workers claim the oldest eligible row with `FOR UPDATE SKIP
LOCKED`; an opaque expiring lease fences the eventual decision and retry update.

A process crash leaves the input claimable after lease expiry. A transient Coop failure releases it
with bounded exponential backoff measured from the time the failure occurred. It does not consume the
episode's model-attempt budget because no episode turn has started yet.

Confirmed failed Coop operations get a fresh durable execution generation; ambiguous transport
failures retain the original operation key for reconciliation. An interrupted or budget-exhausted turn,
or an operation whose outcome Coop cannot prove, leaves explicit blocked custody instead of silently
replaying an unsafe mutation.

## Generic model decision

The provider receives one bounded prompt containing:

- the current source, actor kind, event kind, time, and content or compact preview;
- up to twenty opaque candidate episodes from the same destination conversation;
- compact chronological first/latest input previews for each candidate;
- the relationships the host permits.

The exact JSON Schema is attached once as Coop's output contract rather than copied into the prompt.
The exact current thread is always offered first, so unrelated channel traffic cannot block its reply.
For a new top-level item, active work takes priority over completed history. If all active work does not
fit, the input waits without creating a Coop session and is reconsidered when capacity changes; it is
never silently classified from an incomplete set.

The model chooses one of:

- `start_episode`: begin new work, optionally linked to older history;
- `continue_episode`: add this input to one offered episode;
- `reply`: answer directly without a longer investigation;
- `react`: acknowledge with one emoji when the source supports reactions; or
- `ignore`: take no visible action and preserve a short factual reason.

It cannot return a destination or raw episode ID. A history-only link always keeps the current event's
destination; it never turns an old thread into the new reply target.

## Coop and validation

The optional admission worker talks only to Coop's private Unix socket under a configured read-only
policy. One input gets one isolated admission session. Session and turn creation use stable operation
keys, so a lost HTTP response reconciles the existing operation instead of starting another model
turn.

Coop validates the JSON Schema. It then holds the exact bytes unpublished for host semantic review.
Responder checks the action against the frozen candidate set and source capabilities. If that check
fails, the complete useful error goes back to the same Coop turn and the model repairs its answer.
Responder accepts only a completed turn whose message digest matches Coop's durable semantic-validation
receipt.

After a decision, Coop has already parked and cleaned the provider runtime. Responder also asks Coop to
close the admission session. Fleet-wide session retention and discard are intentionally owned by the
later session-lifecycle module; this isolated module is not activated before that boundary exists.

## Atomic admission

Admission locks the inbox row and applies the input command, optional wait resumption, and inbox
decision in one database transaction. Any failure rolls everything back. Every path that admits an
input takes the same short conversation lock before its episode lock, including input written outside
the model-admission worker.

The host snapshots candidates, the conversation's episode count, and the complete active episode ID set
under one short conversation lock. Only the bounded candidates enter the model prompt. Before a decision
creates work, the host checks the count and active IDs again under the same lock. If another input created
or reopened an episode while the model was deciding, the pending input is classified again with that
candidate visible. Continuing existing work relies on the selected episode's locked reducer state, so a
newer input queues and a newly started wait can be resumed without widening the destination. If a newer
revision of the exact source item is already in that episode, the older input is durably marked
superseded after the first classification instead of spending more model turns.

## Proof

Fast deterministic tests cover:

- arbitrary and scalar webhook payloads;
- trusted routing despite hostile payload fields;
- bearer and metadata-bound HMAC authentication, including stable item identity, freshness, replay,
  and size limits;
- exact retry and changed-retry conflict;
- distinct webhook occurrences updating one stable source item by revision;
- an unknown webhook through HTTP, durable queue, one Coop turn, and one episode;
- real Unix-socket HTTP requests to the Coop API;
- lost asynchronous operation responses;
- schema-valid but semantically invalid output repaired in the same turn;
- missing semantic-validation receipts being refused;
- lease fencing, expiry recovery, simultaneous workers, and retry timing;
- terminal operation generations, uncertain-result custody, and dynamic candidate-capacity recovery;
- exact-thread admission under channel load and one-turn supersession of stale source revisions;
- admission/episode transaction rollback, shared conversation-lock ordering, and concurrent episode
  creation; and
- the harvested Slack lifecycle corpus described in the [corpus review](elixir-slack-admission-corpus.md).

These tests use recorded decisions or a deterministic fake Coop API; they never call an LLM. Model
choice quality remains a separate recorded-context evaluation suite. Delivery, full investigation,
memory, automations, GitHub work, remote fleet placement, and final Slack rendering remain later
modules.
