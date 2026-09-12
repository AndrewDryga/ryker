# Elixir platform adapters and delivery

Slack is not a special Responder input. It is one authenticated adapter over the same bounded ingress,
episode, Work, and Delivery contracts used by GitHub and the universal webhook.

```text
platform request
    -> authenticated adapter
    -> generic Ingress.Input
    -> generic admission and episode routing
    -> generic Work final result
    -> durable Delivery intent
    -> trusted platform publisher
```

This split is deliberate. Platform code translates identities, capabilities, threads, API calls, and
receipts. The model interprets arbitrary content. The host alone chooses destinations, credentials,
Coop policy, and available operations.

## Inbound adapters

Every adapter returns `Responder.Ingress.Input` with the same source identity, actor, event identity,
stable item identity and revision, arbitrary bounded JSON content, source capabilities, and host-owned
destination.

| Adapter | Accepted input | Host-derived destination | Model-visible native action |
| --- | --- | --- | --- |
| Slack | message, edit, delete | workspace, channel, exact thread | reply; reaction on a live message |
| GitHub | issue comment, PR review, inline review comment, issue/PR lifecycle | configured repository and exact discussion | reply; GitHub reaction on a live comment; bounded context/search |
| Universal webhook | any JSON scalar or document with explicit occurrence identity | configured route | reply only by default |
| Grafana webhook | 1–500 firing or resolved alerts per authenticated delivery | configured route | reply only by default |
| Mapped JSON webhook | configured bounded fields from one JSON object | configured route | reply only by default |

The universal endpoint intentionally has no platform guesser. A sender can post any authenticated JSON
payload and the model can classify it, but the payload cannot grant reactions or invent a delivery
target. Grafana and mapped-JSON transforms sit immediately above that source-neutral boundary: they
derive provider identity, lifecycle revision, correlation, and bounded content before producing the
same `Ingress.Input`. They cannot choose destination, authority, Work profile, or implementation
module. A future integration adds another small trusted transform only when it needs native identity,
revision, threading, or capabilities.

GitHub App webhook signatures cover the raw body at one App webhook URL. Only after signature
verification does the host select a binding from the signed installation ID plus repository ID, then
checks the configured repository name, explicit authorized sender IDs, and Responder bot sender ID.
Self-authored and unlisted-actor events are acknowledged without entering the queue. Other configured
bot actors remain valid inputs. Slack authentication remains at the owning Slack gateway; its adapter
receives only the already-authenticated event.

GitHub revisions combine the provider timestamp with a host-owned action rank: create, then edit, then
delete. This keeps a delayed edit from resurrecting a comment whose delete webhook with the same
timestamp was already admitted. A database allocator supplies collision slots without trusting arrival
order as source chronology. Issue and pull-request lifecycle events retain one stable provider item
identity across opened, edited, synchronized, closed, and other supported revisions. Published pull
requests continue through publication-owned lifecycle handling; unmatched lifecycle events use the
ordinary generic adapter path.

Feedback on a pull request published by Responder is a host-owned continuation, not a fresh generic
conversation. After authentication and normalization, the adapter matches the exact configured
repository plus recorded pull-request number in `episode_publications`. Issue comments on that PR,
submitted reviews, and inline review comments enter the publication lifecycle ledger and resume the
original writable engineering episode and Coop session. The signed feedback cannot select another
episode, repository, or policy; unmatched GitHub discussion continues through ordinary generic
admission. The resumed Work turn keeps the authenticated GitHub actor, item identity, revision, and
payload, but remains bound to the engineering task's original delivery thread and pinned repository
authority. Generic GitHub conversations still expose the eight native emoji reactions; publication
feedback is routed for task work rather than converted into a crossed-platform reaction target.

Authorized Coop readiness reviews run whenever a delivery adapter is configured, even without
GitHub publication credentials. The optional `publication` configuration adds the exact
GitHub-bound repository allowlist; without it, the existing publication worker can review and
deliver results but cannot publish a PR. An attempted publication retains its reviewed candidate
and reports `publication_repository_not_configured` until the binding is configured. This does
not grant task, publication, merge, or deployment authority.

GitHub Work turns expose `read_github_conversation` for one bounded page of the host-bound issue or
pull request and `search_github` for repository-scoped issue/PR search. Sections cover the subject,
issue discussion, review summaries, review comments, one exact inline review thread, and changed
files. The host derives repository, subject number, and review root from the episode destination;
the model supplies none of those authority fields. Pages contain at most 20 items, cursors stop after
page 10, text is bounded per item, search rejects repository/org/user qualifiers, and every search
result is checked against the configured repository.
Discussion and review sections also include the bound subject body. Review context reuses parents
already returned and fetches at most four missing parents, checking their exact PR identity; deleted
or omitted parents remain explicitly unavailable/partial. Search attaches up to five discussion items
only to the current subject's hit. Other subjects do not acquire access through the current-subject
reader. Subject-only and changed-file reads remain focused.

## Outbound delivery

A visible Work result becomes an immutable `delivery_pending` row. A reaction admission atomically
creates a separate immutable reaction outbox row. Message and reaction workers have independent
bounded pools and leases. A publisher runs outside model custody while the dispatcher renews its
delivery lease at a bounded cadence. Transient failures retry with exponential backoff up to the
configured attempt limit. Permanent failures and exhausted retries enter durable `blocked` custody;
an operator can fix credentials/configuration and rearm the exact frozen intent. Slack `Retry-After`
and GitHub `Retry-After`/rate-limit reset headers extend the host backoff; an ordinary GitHub 403 remains
a permanent authorization failure instead of being mislabeled as throttling. A recognized GitHub
throttle without usable timing waits at least 60 seconds. Error status and headers remain available
even when an upstream proxy returns a non-JSON error body.

Blocked custody is inspected and rearmed only by its opaque delivery reference:

```console
mix responder.delivery list
mix responder.delivery show DELIVERY_REF
mix responder.delivery rearm DELIVERY_REF
```

`list` and `show` expose bounded routing identifiers, retry state, and error detail, never credentials
or the frozen model document. `rearm` preserves that exact document and destination, clears the old
lease/error, resets the attempt budget, and increments a durable retry generation for audit. It is safe
only after the operator has corrected the reported provider/configuration fault. These commands start
only the repository and its database dependencies; they do not start webhook listeners, admission,
Work, or Delivery workers in the operator shell.

`Responder.Delivery.Adapters` is an explicit trusted registry keyed by durable transport name. It never
turns request content into a module name or credential lookup. A publisher receives only:

- the durable delivery reference;
- the already-bound transport, conversation, and thread;
- the exact message or emoji document; and
- for reactions, the exact source item reference.

A platform call does not settle local state. The publisher must return a typed receipt containing the
same delivery reference, transport, conversation, and thread. PostgreSQL records that receipt and the
episode transition atomically. Crossed receipts are rejected.

## Slack translation

Messages use `chat.postMessage` with the bound channel, optional `thread_ts`, and opaque
`responder_delivery` metadata containing the durable delivery reference. Before every post, including
the first attempt, the client searches the exact channel or thread with
`include_all_metadata=true` for that metadata. A lost HTTP response therefore reconciles the
already-visible message rather than creating another one.

Unstructured model text up to 12,000 characters is posted in Slack's standard Markdown block, with
link/media unfurling disabled. Longer valid replies are preserved in bounded plain-text sections
instead of being truncated. The top-level `text` fallback always contains the same neutralized
message. Slack control forms such as `<!channel>` and `<@U…>` are escaped before either rendering
path, so ordinary model prose cannot notify a channel or impersonate a typed mention. A future typed
mention operation may reinsert only host-authorized identities.

Reactions use `reactions.add` against the exact source message timestamp. Slack's `already_reacted`
response is treated as the successful idempotent state.

Native assistant thread status is derived from durable Inbox and episode ownership rather than model
prose. Queued, admitting, working, delivery, and waiting phases become bounded status text; terminal
and blocked phases become an empty clear. Blocking a Work turn leaves its episode working, so a
parked task is read from its owning turn and clears too, ranked below a new input on the same
thread so the arriving message still reports itself. A PostgreSQL row per workspace/channel/thread owns the
desired text, retry, lease, delivered generation, and 90-second refresh. Every semantic change or
refresh advances the generation, so an older in-flight receipt cannot settle a newer update or clear
after restart. Slack writes are paced at three seconds per thread and call the verified
`assistant.threads.setStatus` shape with `channel_id`, `thread_ts`, and `status`.

## GitHub translation

Issue conversation replies use the issue-comments API. A pull-request-root result creates a native
pull-request review summary. Inline review-thread replies use the pull-request review-comment reply
API and retain the exact root comment. GitHub comment and review creation have no request idempotency
key, so Responder includes an opaque marker derived from the delivery reference and searches every
bounded page before creating. If it cannot prove absence within the safety bound, it retries later
instead of risking a duplicate.

Unstructured `@user` and `@org/team` forms are neutralized before posting so model prose cannot trigger
notifications. Privileged typed mention support, if added, must resolve and authorize identities in
the host first.

GitHub reactions use the distinct issue-comment and pull-request review-comment reaction endpoints.
The supported model choices are exactly `+1`, `-1`, `laugh`, `confused`, `heart`, `hooray`, `rocket`,
and `eyes`.

An engineering `request_task` proposal requires a non-null configured Responder repository
reference; an incident proposal may use null. The task interface accepts 1–256 letters, digits,
underscores, dots, colons, or hyphens. A GitHub `owner/repo` name or local checkout path does not
automatically provide that reference or authorize a writable task. Missing and incompatible
references return actionable `repository_required` and `invalid_repository_reference` errors.
If no usable binding is supplied, explain the requested work and ask for repository configuration;
do not guess a mapping. Proposals remain inert until their existing confirmation and placement
checks succeed.

Open engineering-task, schedule, automation, memory, preference, guidance, and standing-assignment
offers include an exact command such as `/responder confirm record:task_offer:...`. Only a configured
GitHub actor may submit it, and the host consumes it before generic model admission. Confirmation
reloads the referenced record, its settled delivery receipt, and its source episode; the current
repository discussion must match that original conversation and thread. The webhook body identity is
the confirmation receipt, so replay is idempotent. Incident-task and publication offers deliberately
do not gain this command.

Approving a PR, requesting changes, submitting a review, merging, or changing repository contents is
not a generic emoji or reply. Each is a separate privileged typed operation with its own authority and
validation boundary.

## Trusted runtime configuration

Credentials remain behind zero-argument host callbacks and are fetched for every HTTP request.
Responder signs a short-lived RS256 App JWT from the host-owned private key, mints a token scoped to
the exact configured installation and repository, caches it only until the refresh window, and rotates
it before expiry. No installation token is stored in an ingress, delivery, publication, or Work row.
`github.private_key_env` accepts either the complete PEM or its single-line standard-base64 encoding;
the shipped systemd environment file uses base64 because it cannot safely carry a multiline PEM.

```elixir
alias Responder.Delivery.JSONClient
alias Responder.GitHub.Client, as: GitHubClient
alias Responder.GitHub.Publisher, as: GitHubPublisher
alias Responder.Slack.Client, as: SlackClient
alias Responder.Slack.Publisher, as: SlackPublisher

{:ok, slack_http} =
  JSONClient.new(
    base_url: "https://slack.com/api",
    finch: Responder.CoopFinch,
    receive_timeout: 30_000,
    token_provider: fn -> {:ok, System.fetch_env!("SLACK_BOT_TOKEN")} end
  )

{:ok, slack_client} = SlackClient.new(http: slack_http, requester: JSONClient)

github_http = configured_repository_scoped_github_app_client

{:ok, github_client} = GitHubClient.new(http: github_http, requester: JSONClient)

config :responder, :delivery,
  worker_ref: "responder-delivery:host-a",
  max_attempts: 8,
  message_concurrency: 2,
  reaction_concurrency: 1,
  adapters: %{
    "slack" => %{
      binding: %{
        workspaces: %{
          "T0123456789" => %{api: SlackClient, client: slack_client}
        }
      },
      message_publisher: SlackPublisher,
      reaction_publisher: SlackPublisher
    },
    "github" => %{
      binding: %{
        bindings: %{
          "github-main" => %{
            api: GitHubClient,
            client: github_client,
            repository_full_name: "octo/example",
            repository_id: 99
          }
        }
      },
      message_publisher: GitHubPublisher,
      reaction_publisher: GitHubPublisher
    }
  }
```

The Slack token callback remains host configuration. GitHub uses the supervised App installation-token
provider described above; a static installation token is not a supported production configuration.

Both the GitHub listener and Delivery runtime are optional and start only when configured. This work
does not silently enable either in a running deployment.

## Deterministic proof

The fast suite covers signed and crossed GitHub webhook payloads, GitHub comment/review/lifecycle
normalization, same-timestamp create/edit/delete ordering, bounded repository context and search,
exact-thread idempotent confirmations, GitHub and Slack native emoji targets, lost message-response
reconciliation, bounded pagination, typed receipt fencing, provider-directed rate-limit delays,
operator inspection/rearm, independent message/reaction leasing, and full
signed-GitHub-to-delivered-work and signed-GitHub-to-delivered-reaction paths. Tests use scripted
provider clients; they call neither a model nor the public Slack or GitHub network.
