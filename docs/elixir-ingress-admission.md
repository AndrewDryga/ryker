# Elixir ingress and admission

This is the admission boundary of the replacement Responder. It accepts a bounded event from a
trusted adapter, stores it before reasoning, asks Coop for one generic model decision, validates that
decision, and commits it with the episode transition in PostgreSQL.

Slack, GitHub, and authenticated webhooks are adapters over the same input contract. Tagged webhook
transforms derive trusted Grafana or configured mapped-JSON identity and bounded fields; generic
admission and the model remain provider-neutral and interpret only the resulting content.

The module composes with the optional Slack Socket Mode, GitHub App, and universal-webhook runtimes.
Each adapter starts only when its strict trusted runtime configuration is present; deployment and live
acceptance remain separate evidence from implementation.

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
The GitHub adapter binds signed issue comments, pull-request reviews, inline review comments, and
issue/pull-request lifecycle events to one configured repository and their exact discussion thread.
It offers GitHub's native reaction set only for live comment types that GitHub can react to.
Every webhook binds the event to the destination in trusted route configuration.

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

`adapter.kind: universal` uses that header contract unchanged. `adapter.kind: grafana` accepts an
authenticated batch of 1–500 Grafana alerts and derives stable alert-cycle and occurrence identities.
`adapter.kind: mapped_json` selects only configured bounded object paths and derives one alert. The
specialized transforms do not require Responder metadata headers because their authenticated bodies
own source identity; an HMAC request signs those absent header values as empty strings. A Grafana
batch is recorded atomically. The complete configuration and mapping contract is documented in
[`webhooks.md`](webhooks.md).

Routes are explicit configuration. Each route owns its secret, payload limit, clock-skew limit, and
destination. The payload cannot override them. The listener defaults to loopback and starts only when
`:responder, :webhooks` is configured.

A configured Conversation Lab can be the trusted destination for a loopback/manual route by using
`transport: control_plane` and the same exact `control-plane:lab:<uuid>` value for both
`conversation_ref` and `thread_ref`. This exercises webhook ingestion, admission, Work, and local
delivery without posting test traffic to Slack. Arbitrary payload fields still cannot select the Lab,
policy, repository, or any other authority; those remain route configuration.

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

Bearer routes send one `Authorization: Bearer <secret>` header. HMAC routes send
`X-Responder-Timestamp: <Unix seconds>` and
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

For example, signing the exact body bytes in Elixir is:

```elixir
timestamp = Integer.to_string(System.system_time(:second))
path = "/v1/hooks/universal"
event_id = "provider-event-123"
item_id = "provider-item-42"
event_type = "changed"
occurred_at = "2026-08-28T12:00:00Z"
revision = "2"

signed =
  Enum.join(
    [timestamp, path, event_id, item_id, event_type, occurred_at, revision, raw_body],
    "\n"
  )

signature =
  :crypto.mac(:hmac, :sha256, secret, signed)
  |> Base.encode16(case: :lower)

headers = [
  {"x-responder-timestamp", timestamp},
  {"x-responder-signature", "v1=" <> signature},
  {"x-responder-event-id", event_id},
  {"x-responder-item-id", item_id},
  {"x-responder-event-type", event_type},
  {"x-responder-occurred-at", occurred_at},
  {"x-responder-revision", revision}
]
```

## GitHub webhook

The optional GitHub App listener exposes one shared webhook URL. After validating the App-level raw
body signature, the host selects one repository binding from the signed installation and repository
IDs:

```text
POST /v1/github
Content-Type: application/json
X-GitHub-Delivery: <required unique occurrence ID>
X-GitHub-Event: issue_comment | pull_request_review | pull_request_review_comment | issues | pull_request
X-Hub-Signature-256: sha256=<HMAC-SHA256 of the raw request body>
```

The host binding fixes the GitHub App installation, repository numeric ID, repository full name,
webhook secret, Responder bot identity, authorized sender IDs, and body limit. Signed payload fields
can select only an item inside that repository; they cannot redirect the resulting episode or later
delivery to another repository. Self-authored events and unlisted actors are authenticated and
acknowledged as ignored before they can spend model or Work authority.

Supported comment actions normalize into the same `message`, `edit`, and `delete` event kinds used by
other sources. Issue comments on pull requests stay in the PR conversation. Inline review comments
retain their root review-comment thread. GitHub issue and review comments expose exactly GitHub's
supported reaction names: `+1`, `-1`, `laugh`, `confused`, `heart`, `hooray`, `rocket`, and `eyes`.
Deleted comments and top-level review submissions do not advertise a reaction operation.

Supported issue and pull-request lifecycle actions normalize as generic `event` inputs with stable
issue or pull identities across revisions. A lifecycle event for a pull request already published by
Responder remains publication-owned; an unmatched pull request and every issue lifecycle event use
ordinary generic admission.

GitHub conversation turns can read one of six bounded context sections and search issues/PRs inside
only the configured repository. Repository identity, subject number, review-thread root, credential,
and destination are derived from the active episode. The model chooses only the section, bounded page
cursor, result limit, search text, kind, and state.

An open confirmable offer is rendered with `/responder confirm <record-ref>`. The Router recognizes
that exact syntax only on a newly created, authenticated issue comment and consumes it before model
admission. It rechecks the configured actor, exact current discussion, original settled delivery
receipt, offer kind, and repository contributor policy, then calls the same durable confirmation
service used by Slack and Conversation Lab. Duplicate webhook delivery or a repeated command returns
the existing resource. Cross-thread, stale, malformed, incident-task, and publication commands fail
closed without creating model work. This syntax cannot approve reviews, merge, deploy, or write
repository content.

```yaml
repositories:
  responder:
    path: /srv/responder
    github_repository: octo/example
    github_binding: github-main
    base_branch: main
    conversation_policy:
      name: responder-conversation-v1
      digest: <64 lowercase hexadecimal characters>
    standard_policy:
      name: responder-standard-v1
      digest: <64 lowercase hexadecimal characters>
    deep_policy:
      name: responder-deep-v1
      digest: <64 lowercase hexadecimal characters>
    contributor_policy:
      name: responder-contributor-v1
      digest: <64 lowercase hexadecimal characters>
    schedule_policy:
      name: responder-scheduled-write-v1
      digest: <64 lowercase hexadecimal characters>

github:
  api_url: https://api.github.com
  app_id: 12345
  private_key_env: GITHUB_APP_PRIVATE_KEY
  webhook_secret_env: GITHUB_WEBHOOK_SECRET
  ip: 127.0.0.1
  port: 4319
  bindings:
    github-main:
      repository: responder
      installation_id: 41
      repository_id: 99
      responder_actor_id: 7
      authorized_actor_ids: [7, 8]
```

The named environment value may be the complete PEM or its single-line standard-base64 encoding.
Use the encoded form in the shipped systemd `EnvironmentFile`.
The GitHub App must subscribe to issue comments, pull-request reviews, pull-request review comments,
issues, and pull requests for the corresponding adapter and lifecycle paths to receive those events.

The supervised runtime contains both `server` and `tokens` components: `server` owns the shared
webhook listener and trusted bindings, while `tokens` signs short-lived App JWTs and mints the exact
repository-scoped installation token used by delivery and publication. See
[`config/responder-elixir.example.yaml`](../config/responder-elixir.example.yaml) for the complete
strict runtime document.

As with the universal listener, public exposure belongs behind the normal ingress proxy. A `202`
means the normalized event is durably queued. `ping` is authenticated and acknowledged without
creating work. An ignored self/unlisted-actor event returns `200` and creates no inbox row.

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

It also chooses one abstract `work_class` for work-producing actions. `reply` requires
`conversational`; `start_episode` and `continue_episode` require `standard` or `deep`; `react` and
`ignore` require `null`. The host maps that bounded class through the adapter-owned Work profile:

| Work class | Recommended Coop target | Intended use |
| --- | --- | --- |
| `conversational` | `codex:gpt-5.6-terra/medium` | ordinary questions, chat, and small lookups |
| `standard` | `codex:gpt-5.6-sol/medium` | normal investigations and tool-backed work |
| `deep` | `codex:gpt-5.6-sol/xhigh` | difficult, high-ambiguity, or high-consequence reasoning |

The model never returns a provider, model, effort, policy name, repository, credential, or write
authority. Those remain trusted configuration. The three class policies for one route must carry
the same Coop-computed `authority_digest`; startup, fleet placement, and session binding enforce it.
A deeper model is not permission to write. Confirmed
engineering work moves through its separately authorized contributor policy. Existing episodes keep
their already-pinned policy and native Coop session even if a later input is classified differently
or configuration changes.

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
receipt. Candidate identity includes Coop's positive attempt as well as the digest: every reject or
accept key names that attempt, so two byte-identical repair attempts cannot replay one another's
validation result.

One admission execution also has a host-owned elapsed budget, 30 seconds by default. Session-operation
and turn polling share that deadline as well as the existing poll-count bound. Crossing it releases the
dispatcher back to durable Inbox retry/backoff rather than occupying the admission worker indefinitely;
the frozen input, context, execution generation, and Coop operation keys remain available for exact
reconciliation on the next attempt.

After a decision, Coop has already parked and cleaned the provider runtime. Responder also asks Coop to
close the isolated admission session. Episode Work sessions are separately owned by the retention
runtime: it closes the exact recorded Coop session, observes a grace period, reviews Coop's exact
discard plan, refuses dirty or unpublished work, and discards only a clean or already-published
workspace. No cleanup path infers ownership from a repository or branch name.

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
- signed GitHub issue comments, PR reviews, inline review threads, and native comment reactions;
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
choice quality remains a separate recorded-context evaluation suite. The downstream Work, state,
scheduling, approval, publication, retention, and platform-delivery modules now consume this
admission boundary. Privileged GitHub review decisions and cross-host Coop session placement remain
outside this module's contract. Generic Slack/GitHub reply and reaction delivery is described in
[platform adapters and delivery](elixir-platform-adapters.md).
