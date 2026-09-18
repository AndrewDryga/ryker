# Elixir ingress and admission

This is the admission boundary of the replacement Ryker. It accepts a bounded event from a
trusted adapter, stores it before reasoning, asks Coop for one generic model decision, validates that
decision, and commits it with the episode transition in PostgreSQL.

Slack, GitHub, and authenticated webhooks are adapters over the same input contract. Tagged webhook
transforms derive trusted Grafana or configured mapped-JSON identity and bounded fields; generic
admission and the model remain provider-neutral and interpret only the resulting content.

The module composes with the optional Slack Socket Mode, GitHub App, and universal-webhook runtimes.
Each adapter starts only when its strict trusted runtime configuration is present; deployment and live
acceptance remain separate evidence from implementation.

## Trusted envelope

Every adapter produces `Ryker.Ingress.Input` with:

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
X-Ryker-Event-ID: <required unique occurrence ID>
X-Ryker-Item-ID: <optional stable item ID shared by revisions; defaults to event ID>
X-Ryker-Event-Type: <optional hint>
X-Ryker-Occurred-At: <optional UTC ISO-8601 timestamp>
X-Ryker-Revision: <optional positive integer, default 1>
```

The body may be any JSON value: object, array, string, number, boolean, or null. A `202` response means
the exact input is durably queued; it does not claim that model work has finished. An exact retry
returns the original receipt. Reusing the event identity with different data returns `409`.

`adapter.kind: universal` uses that header contract unchanged. `adapter.kind: grafana` accepts an
authenticated batch of 1–500 Grafana alerts and derives stable alert-cycle and occurrence identities.
`adapter.kind: mapped_json` selects only configured bounded object paths and derives one alert. The
specialized transforms do not require Ryker metadata headers because their authenticated bodies
own source identity; an HMAC request signs those absent header values as empty strings. A Grafana
batch is recorded atomically. The complete configuration and mapping contract is documented in
[`webhooks.md`](webhooks.md).

Routes are explicit settings. Each source owns its own credential reference, destination and
repository context; the payload limit and clock-skew limit are code defaults. The payload cannot
override any of them. The listener defaults to loopback and starts only when at least one webhook
source is enabled.

A configured direct conversation can be the trusted destination for a loopback/manual route by using
`transport: control_plane` and the same exact `control-plane:lab:<uuid>` value for both
`conversation_ref` and `thread_ref`. This exercises webhook ingestion, admission, Work, and local
delivery without posting test traffic to Slack. Arbitrary payload fields still cannot select the conversation,
policy, repository, or any other authority; those remain route configuration.

The settings owner publishes the assembled runtime under these application keys; a test can put the
same shape directly:

```elixir
config :ryker, :admission,
  policy: "admission-read-only",
  socket: "/var/run/coop/control.sock",
  worker_ref: "ryker:admission:local"

config :ryker, :webhooks,
  ip: {127, 0, 0, 1},
  port: 4080,
  routes: %{
    "universal" => %{
      auth: {:hmac_sha256, System.fetch_env!("RYKER_WEBHOOK_SECRET")},
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
`X-Ryker-Timestamp: <Unix seconds>` and
`X-Ryker-Signature: v1=<hex HMAC-SHA256>`. The signed bytes are these newline-separated values in
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
webhook secret, Ryker bot identity, authorized sender IDs, and body limit. Signed payload fields
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
Ryker remains publication-owned; an unmatched pull request and every issue lifecycle event use
ordinary generic admission.

GitHub conversation turns can read one of six bounded context sections and search issues/PRs inside
only the configured repository. Repository identity, subject number, review-thread root, credential,
and destination are derived from the active episode. The model chooses only the section, bounded page
cursor, result limit, search text, kind, and state.

An open confirmable offer is rendered with `/ryker confirm <record-ref>`. The Router recognizes
that exact syntax only on a newly created, authenticated issue comment and consumes it before model
admission. It rechecks the configured actor, exact current discussion, original settled delivery
receipt, offer kind, and repository contributor policy, then calls the same durable confirmation
service used by Slack and direct conversations. Duplicate webhook delivery or a repeated command returns
the existing resource. Cross-thread, stale, malformed, incident-task, and publication commands fail
closed without creating model work. This syntax cannot approve reviews, merge, deploy, or write
repository content.

This is durable settings, edited under **Settings**, not a configuration file:

- **Repositories** holds one row per repository — its reference, display metadata, GitHub
  repository slug, base branch and optional publication checkout path.
- **Execution policies** binds each purpose (conversational, standard, deep, contributor,
  schedule) to a reviewed worker policy for that repository or context. The digest and authority
  digest are copied from the authenticated worker advertisement; nothing types one.
- **GitHub** holds the App identity, and **GitHub repository bindings** holds one verified
  binding per repository: installation ID, repository ID, the Ryker actor ID and the exact
  authorized actor IDs.
- `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` and `GITHUB_WEBHOOK_SECRET` come from the deployment
  environment under those fixed names. Credentials being present does not enable GitHub; the saved
  connection does, and the runtime refuses to enable it when the environment names a different app.

The private-key environment value may be the complete PEM or its single-line standard-base64 encoding.
Use the encoded form in the shipped systemd `EnvironmentFile`.
The GitHub App must subscribe to issue comments, pull-request reviews, pull-request review comments,
issues, and pull requests for the corresponding adapter and lifecycle paths to receive those events.

The supervised runtime contains both `server` and `tokens` components: `server` owns the shared
webhook listener and trusted bindings, while `tokens` signs short-lived App JWTs and mints the exact
repository-scoped installation token used by delivery and publication. See
the Settings page of the local console for the saved settings and the effective assembled values.

As with the universal listener, public exposure belongs behind the normal ingress proxy. A `202`
means the normalized event is durably queued. `ping` is authenticated and acknowledged without
creating work. An ignored self/unlisted-actor event returns `200` and creates no inbox row.

## Durable queue

`Ryker.Ingress.Inbox` is the natural slot for one source occurrence. PostgreSQL stores the exact
normalized input before any model call. Workers claim the oldest eligible row with `FOR UPDATE SKIP
LOCKED`; an opaque expiring lease fences the eventual decision and retry update.

A process crash leaves the input claimable after lease expiry. A transient Coop failure releases it
with bounded exponential backoff measured from the time the failure occurred. It does not consume the
episode's model-attempt budget because no episode turn has started yet.

Confirmed failed Coop operations get a fresh durable execution generation; ambiguous transport
failures retain the original operation key for reconciliation. An interrupted or budget-exhausted turn,
or an operation whose outcome Coop cannot prove, leaves explicit blocked custody instead of silently
replaying an unsafe mutation.

A terminal failed model turn also blocks immediately: Coop has already finished its own provider
recovery, so automatically resubmitting the frozen request cannot repair its configuration or account.
The input retains the provider's actual error and the next safe execution generation for an explicit
operator retry after repair. A transport timeout while a turn is still running keeps its existing
operation identity and remains retryable.

## Generic model decision

The provider receives one bounded prompt containing:

- the current source, actor kind, event kind, time, and content or compact preview;
- the frozen local backdrop: the thread root, the messages that preceded this one in that exact
  place, and the latest eligible thread and parent-channel summaries, with a manifest saying what
  the bundle actually contains;
- up to twenty opaque candidate episodes from every conversation this source may correlate with;
- each candidate's source-backed digest, lifecycle state, match evidence and allowed relations;
- compact chronological first/latest input previews, which supplement the digest and never replace it.

The exact JSON Schema is attached once as Coop's output contract rather than copied into the prompt.

### Correlation scope

Only joined, non-private, non-externally-shared channels of the same Slack workspace correlate with
each other. Direct messages, private channels, externally shared channels, other workspaces and
every non-Slack transport stay inside their own conversation, and an episode that has gathered
evidence anywhere outside the incoming source's scope is not offered at all — its digest, state and
existence would leak that scope. Reading across conversations never confers posting permission,
repository access or action authority.

### Bounded retrieval and the best twenty

Four indexed lanes fill a pool of at most 200 eligible episodes, each returning its own best 50:
source-backed identity matches, this exact thread, resource and objective text matches, and recent
active work as a fallback for weakly worded input. The exact source item's existing owner is
resolved separately, so no lane cap can hide the episode that owns a revision.

Ranking then chooses at most twenty options from explicit, tested features: a proven occurrence
identity first, then direct source references, then thread gravity, then resource and objective fit,
then channel proximity, active state and — only as a tie-breaker — recency. Up to four places are
reserved for supported matches outside the incoming thread, so more than twenty nearby options
cannot bury the one matching episode in another channel; unused reserved places return to the common
pool. The frozen context records every lane's result, what was examined and offered, the feature
values behind each option, and why the cutoff fell where it did. The control plane shows that
receipt beside the frozen context as "Routing evidence", so an operator can tell a bounded search
from a missing one without reading the shortlist and guessing. The episode trace says the rest: an
episode whose evidence arrived in more than one conversation names those conversations, its one
progress home, how many of its trusted signals are still firing and its retained case, and every
audited merge, split or reassignment appears as its own step with the actor, the confirmation and
the reason.

Thread identity is the full transport, conversation and thread triple. The same Slack thread
timestamp in two channels is two different threads and carries no shared gravity.

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

When the route already selected a repository, the context carries `repository_source_kinds` and a
`start_episode` decision may also set `repository_source` to one of `{"kind":"default"}`,
`{"kind":"branch","name":"feature/payments"}`, `{"kind":"pull_request","number":514}` or
`{"kind":"commit","sha":"<full lowercase 40- or 64-character object id>"}`. The selector names only
a source inside that repository; it never names a repository, remote, URL, path, tag or raw ref, and
it grants no publication authority. Every other action, and every route without a repository, must
send `null`: `continue_episode`, `reply`, `react` and `ignore` keep whatever source their work
already pinned (`invalid_decision: repository_source`), and a selector on a route without a
repository is rejected before an episode exists (`admission_rejected:
repository_source_not_available`). A malformed selector is refused, never repaired. The host
supplies `default` for a new repository-backed episode when the model chose nothing, and the chosen
selector is frozen in the same transaction that pins the Work policy. See
[elixir-work-runtime.md](elixir-work-runtime.md) for how Coop resolves and Ryker verifies it.

The model never returns a provider, model, effort, policy name, repository, credential, or write
authority. Those remain trusted configuration. The three class policies for one route must carry
the same Coop-computed `authority_digest`; startup, fleet placement, and session binding enforce it.
A deeper model is not permission to write. Confirmed
engineering work moves through its separately authorized contributor policy. Existing episodes keep
their already-pinned policy and native Coop session even if a later input is classified differently
or configuration changes.

It cannot return a destination or raw episode ID. A history-only link always keeps the current event's
destination; it never turns an old thread into the new reply target.

### Membership, origins and one home

An episode is one piece of work, not one conversation. Membership is per message: every admitted
input keeps the exact transport, conversation, thread, native root or reply kind, and source
identity it arrived with, so evidence from several conversations can meet in one episode while each
message remains answerable where it was written. The episode keeps one progress home — the
destination it started with — and adding evidence never moves it, so new origins cannot subscribe
every contributing channel to repeated status and final replies.

Cancelled work stays history-only. Work pinned to a different repository is offered as history and
never as the same work, because merging evidence must not broaden a pinned session's authority.
Completed work may be continued only inside the continuation window or by the exact source item's
owner, which is the one candidate rank can never displace.

## Coop and validation

The optional admission worker talks only to Coop's private Unix socket under a configured read-only
policy. One input gets one isolated admission session. Session and turn creation use stable operation
keys, so a lost HTTP response reconciles the existing operation instead of starting another model
turn.

Coop validates the JSON Schema. It then holds the exact bytes unpublished for host semantic review.
Ryker checks the action against the frozen candidate set and source capabilities. If that check
fails, the complete useful error goes back to the same Coop turn and the model repairs its answer.
Ryker accepts only a completed turn whose message digest matches Coop's durable semantic-validation
receipt. Candidate identity includes Coop's positive attempt as well as the digest: every reject or
accept key names that attempt, so two byte-identical repair attempts cannot replay one another's
validation result.

One admission execution also has a host-owned elapsed budget, 30 seconds by default. Session-operation
and turn polling share that deadline as well as the existing poll-count bound. Crossing it releases the
dispatcher back to durable Inbox retry/backoff rather than occupying the admission worker indefinitely;
the frozen input, context, execution generation, and Coop operation keys remain available for exact
reconciliation on the next attempt. Because Coop was still creating the session or running the turn,
that release is a wait, not a failure: it does not count against the input's eight attempts. Coop's
turn timeout ends a turn that never finishes, and readiness names an input left pending.

After a decision, Coop has already parked and cleaned the provider runtime. Ryker also asks Coop to
close the isolated admission session. Episode Work sessions are separately owned by the retention
runtime: it closes the exact recorded Coop session, observes a grace period, reviews Coop's exact
discard plan, refuses dirty or unpublished work, and discards only a clean or already-published
workspace. No cleanup path infers ownership from a repository or branch name.

## Atomic admission

Admission locks the inbox row and applies the input command, optional wait resumption, and inbox
decision in one database transaction. Any failure rolls everything back. Every path that admits an
input takes the same short conversation lock before its episode lock, including input written outside
the model-admission worker.

The local backdrop is captured before that transaction opens, behind a cutoff at this input's own
occurrence, so a message that arrives while the decision is being made — including one already queued
for Ryker — can never enter an earlier context, and no authorized provider read runs while a
database snapshot is held.

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
- cross-conversation candidate recall against more than a hundred nearer distractors, lane
  saturation, mandatory source ownership, and the privacy negatives above;
- the frozen local backdrop: thread roots, top-level selection, cutoffs, provider pagination and
  provider failure, and summary freshness including after-cutoff revisions;
- admission/episode transaction rollback, shared conversation-lock ordering, and concurrent episode
  creation; and
- the harvested Slack lifecycle corpus described in the [corpus review](elixir-slack-admission-corpus.md).

These tests use recorded decisions or a deterministic fake Coop API; they never call an LLM. Model
choice quality remains a separate recorded-context evaluation suite. The downstream Work, state,
scheduling, approval, publication, retention, and platform-delivery modules now consume this
admission boundary. Privileged GitHub review decisions and cross-host Coop session placement remain
outside this module's contract. Generic Slack/GitHub reply and reaction delivery is described in
[platform adapters and delivery](elixir-platform-adapters.md).
