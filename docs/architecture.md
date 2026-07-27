# Architecture

## Boundaries

Responder is the incident and conversation layer above Coop:

```text
Grafana or generic webhook
          |
          v
Responder HTTP admission -> SQLite inbox and incident correlation
          |
          +-> Slack Socket Mode and Web API
          |     channel + pinned thread + operator conversation
          |
          +-> Coop Unix socket
                declared policy -> fork -> short-lived agent box
                                   |
                                   +-> Emisar MCP
```

The layers have distinct authority:

| Concern | Owner |
| --- | --- |
| Webhook auth, incident correlation, Slack identity, inbox/outbox | Responder |
| Repository allowlist, agent target, budgets, fork, box, review | Coop |
| Infrastructure identity, observe/mutate policy, approval, audit | Emisar |
| Push, pull request publication, merge, signing, deployment | External human-controlled workflow |

The Slack and Emisar tokens are never submitted through the Coop session API. `bootstrap-coop`
writes the Emisar key to Coop's dedicated owner-private `env` file, while `mcp.json` references it
by environment-variable name. Coop projects those files into a turn only while its short-lived box
runs.

## Durable model

SQLite runs in WAL mode with full synchronous writes and one connection. It stores:

- normalized signals and incident occurrences;
- webhook delivery state and body digests;
- Slack inputs admitted before Socket Mode acknowledgement;
- outgoing Slack messages with caller-owned IDs;
- Coop turn submissions with stable idempotency keys and frozen revisions;
- Slack channel, root timestamp, Coop session, and event cursor mappings;
- bounded audit facts for denied and privileged actions.

One serialized reconciliation loop leases a small amount of each work type. HTTP and Socket Mode
handlers only validate and persist input. This keeps acknowledgements short and avoids concurrent
incident workers fighting over SQLite or Slack rate limits.

## Incident identity and correlation

Webhook delivery, signal, incident occurrence, Slack thread, Coop session, and Coop turn are
different identities.

For Grafana:

1. `fingerprint` identifies a signal.
2. `groupKey` identifies the preferred incident group.
3. If `groupKey` is absent, configured labels form the group.
4. If none of those labels exists, the signal identity is the group.

For generic input, `mapping.incident_id` is preferred. Configured labels are the fallback.

An existing non-closed occurrence with the same correlation key is reused inside
`correlation_window`. Duplicate webhook delivery never repeats work. A manually closed or old
resolved occurrence is immutable; a later firing creates a new occurrence.

## Slack delivery

New messages use a durable outbox ID in Slack message metadata. If a request times out after Slack
may have accepted it, Responder does not post again immediately. It searches recent channel history
for that metadata, confirms the original message, or retries only after confirming absence.

The root-card send and root timestamp binding commit in one SQLite transaction. Channel creation
has no client idempotency key, so a timeout is recovered by deterministic channel name. Responder
adopts a same-name channel only when it was created by this bot near the incident creation time.

Thread posts and dirty root-card updates alternate through a conservative Slack write slot. A
failed card update keeps its durable dirty version and receives in-memory exponential backoff;
another incident card or queued thread reply can proceed instead of being starved. Responder posts
completed paragraphs or turns, never token-streaming tool output or routine raw webhook refreshes.
Alert source links expose their destination hostname and omit query strings and fragments before
leaving the service.

## Coop delivery

Every mutation has a stable idempotency key:

```text
responder:session:<incident_id>
responder:turn:<turn_submission_id>
responder:review:<slack_input_id>
responder:stop:<slack_input_id>
responder:extend:<slack_input_id>
responder:close:<slack_input_id>
```

Revision-bearing actions freeze the observed session and revision before the call. A lost response
replays the exact request. A revision conflict is surfaced instead of silently guessing a new
action.

Coop events are consumed by durable sequence cursor. Terminal turns are fetched from Coop and only
their bounded assistant message or terminal error is rendered into Slack.

## Deliberate limits

This v1 is a single-host, single-workspace service. SQLite and a local owner-only Coop socket are
the simplest reliable fit. A later multi-tenant Emisar control plane should use an outbound worker,
tenant-scoped identity, and a server database. It should not expose Coop's local socket over TCP.
