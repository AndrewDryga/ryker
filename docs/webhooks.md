# Webhooks

Ryker exposes one authenticated, source-neutral webhook edge with tagged transforms for
provider payloads. Every accepted event becomes the same durable `Ingress.Input` used by Slack and
GitHub. Route configuration—not request content—owns the destination, Work profile, credentials,
payload limit, and transform.

## Public edge

The listener defaults to loopback. Terminate TLS and enforce any network allowlist and per-sender
request rate limit in a reverse proxy. Publish only `/v1/hooks/<route>`; keep `/healthz`, `/readyz`,
and `/metrics` private. Rate limits must account for Grafana's bounded fan-out of up to 500 alerts
per authenticated request.

Every request must:

- use `POST`;
- use `Content-Type: application/json` or `application/*+json`;
- fit the route's `max_body_bytes` limit, which cannot exceed 40,000 bytes;
- authenticate with the route's configured mode; and
- contain exactly one JSON value.

A `202 Accepted` response means the complete transformed input batch is durably queued. It does not
mean admission, model work, or delivery has finished.

```json
{
  "count": 2,
  "input_ref": "ingress-input:...",
  "input_refs": ["ingress-input:...", "ingress-input:..."],
  "status": "recorded"
}
```

An exact retry returns the original receipt with `status: duplicate`. Reusing a source occurrence
identity with different trusted content returns `409 Conflict`. A multi-alert Grafana request is
atomic: either every alert is recorded or none is.

## Source configuration

Sources are durable settings, edited under **Integrations → Webhooks**. There is no
configuration file. One saved source carries:

| Field | Meaning |
| --- | --- |
| Source name | The path segment: `/v1/hooks/<name>`. Stable; it is the route's identity. |
| Payload shape | `universal`, `grafana` or a custom mapping. A preset also fills in the authentication a provider supports and its grouping labels. |
| Authentication | Bearer token or HMAC-SHA256. There is no unauthenticated shape and no weaker fallback when verification fails. |
| Credential | A secret generated or imported for this source in guided setup. Ryker reveals a generated value once, stores it encrypted, and lets an operator rotate it without changing another source. |
| Destination | Transport plus conversation and thread reference. Validated against the configured outbound adapters when the runtime assembles. |
| Environment | The Ryker environment this source's work runs in: its repositories, its Emisar account and its reviewed policies. Chosen by name from the environments; the payload can never select it. |
| Correlate by labels | Label values that make events the same ongoing situation. |
| Custom field mapping | Dotted paths, for a custom shape only. Event ID, status and title are required. |
| Deployment lifecycle filter | Optional deployment environments, kinds, repositories and targets. |

The listener address and port, the 40 KB body limit and the 300-second clock-skew limit are
deployment and code defaults, not per-source settings. The Work profile comes from the
environment's reviewed policy bindings, so no form ever names a policy digest. An environment a
source uses cannot be removed until the source chooses another one.

**Check a payload** on the same page runs one pasted delivery through the exact transform the live
route uses and shows what it would record. It records nothing, opens no incident, submits no model
work and sends nothing: the route it builds for the check has no Work profile and a credential it
never uses.

Route names, mapping paths, and grouping labels are bounded. Mapped paths contain at most 16 object
segments and never index arrays. There is no jq, CEL, template, shell, dynamic module, or script
execution.

## Authentication

Bearer routes accept exactly one header:

```text
Authorization: Bearer <secret>
```

HMAC-SHA256 routes accept exactly one timestamp and signature:

```text
X-Ryker-Timestamp: <Unix seconds>
X-Ryker-Signature: v1=<hex HMAC-SHA256>
```

The signed bytes are these newline-separated values, including empty lines:

```text
timestamp
request path
event ID
item ID
event type
occurred-at value
revision value
raw request body
```

The metadata values are the exact `X-Ryker-Event-ID`, `X-Ryker-Item-ID`,
`X-Ryker-Event-Type`, `X-Ryker-Occurred-At`, and `X-Ryker-Revision` request headers.
The timestamp must be within the route's configured clock-skew window. Universal routes require an
event ID. Grafana and mapped-JSON routes derive identity from the authenticated body, so those five
headers may be absent and are signed as empty strings. Changing either body or headers invalidates
the signature.

Webhook secrets must contain at least 16 bytes for bearer authentication and 32 bytes for HMAC.

## Universal JSON

`adapter.kind: universal` accepts any JSON value, including arrays and scalars, without interpreting
provider fields. The sender must supply a stable `X-Ryker-Event-ID` for each occurrence.

```text
X-Ryker-Event-ID: <required unique occurrence ID>
X-Ryker-Item-ID: <optional stable item shared by revisions; defaults to event ID>
X-Ryker-Event-Type: <optional bounded hint>
X-Ryker-Occurred-At: <optional UTC ISO-8601 timestamp>
X-Ryker-Revision: <optional positive integer; defaults to 1>
```

Universal input has reply capability only. Payload fields cannot grant reactions or choose a
platform target.

## Grafana alerts

`adapter.kind: grafana` accepts Grafana alert webhook JSON without Ryker metadata headers. Each
entry in `alerts` becomes one normalized input; a delivery must contain between 1 and 500 alerts.

| Normalized field | Grafana source |
|---|---|
| stable alert cycle | route, `fingerprint` (or labels digest), and `startsAt` |
| occurrence | route, fingerprint, `startsAt`, normalized status, `endsAt`, and annotations |
| incident grouping | top-level `groupKey`, configured grouping labels, then alert identity |
| title | annotation `summary`, annotation `title`, `alertname`, then top-level `title` |
| severity | label `severity`, `priority`, then `level` |
| summary | annotation `description`, annotation `message`, then top-level `message` |
| source link | panel, dashboard, generator, then external URL |

Firing aliases are `firing`, `alerting`, `active`, `open`, and `triggered`. Resolved aliases are
`resolved`, `ok`, `closed`, `normal`, and `recovered`. Only HTTP and HTTPS source links are retained.
Firing and resolved occurrences for the same fingerprint and `startsAt` retain one stable item;
PostgreSQL assigns lifecycle revisions in receipt order.

Example contact-point request:

```bash
curl -f \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer example-secret-at-least-16-bytes' \
  --data-binary @grafana-alert.json \
  http://127.0.0.1:4320/v1/hooks/grafana
```

## Mapped JSON alerts

`adapter.kind: mapped_json` turns one JSON object into one normalized alert using configured object
paths. The payload is never copied wholesale into model context; only selected, bounded fields are
retained.

A custom source names one dotted path per field, for example `event.id` for the event ID,
`incident.state` for the status and `incident.title` for the title, with the optional
`item_id`, `incident_id`, `severity`, `summary`, `source_url`, `starts_at`, `ends_at`, `labels`,
`annotations` and `revision` paths alongside them. Written out, a saved mapping is:

```json
{
  "event_id": "event.id",
  "item_id": "incident.alert_id",
  "incident_id": "incident.id",
  "status": "incident.state",
  "title": "incident.title",
  "severity": "incident.severity",
  "summary": "incident.summary",
  "source_url": "incident.url",
  "labels": "incident.labels",
  "annotations": "incident.annotations",
  "starts_at": "incident.started_at",
  "ends_at": "incident.ended_at",
  "revision": "event.revision"
}
```

`event_id`, `status`, and `title` are required mappings. All other mappings are optional. Scalar
fields accept strings, numbers, or booleans; label and annotation values must also be scalar.
Timestamps must be ISO-8601 values. Source links must use HTTP or HTTPS.

`item_id` is the stable item when present, followed by `incident_id`, then `event_id`. An explicit
positive `revision` uses exact source revision semantics. Without it, distinct occurrences for the
same item receive revisions in durable receipt order. Incident correlation prefers `incident_id`,
then any configured grouping labels, then the stable item itself.

The actor is always the host-owned system actor configured by the route. No mapping can select or
impersonate a user, bot, destination, repository, or Work authority.

Request fields such as `destination`, `policy`, `repository`, `secret`, or `adapter` have no effect
unless a route explicitly maps one as ordinary bounded content. They can never alter trusted route
authority.

## Publication deployment and Terraform signals

Lifecycle evidence needs a dedicated authenticated route with exact host-owned authority. For
example:

Save a dedicated source for it: payload shape `universal`, HMAC authentication, its own registered
credential (not the one an alerting source uses), the destination channel, the Ryker environment
its work runs in, and a deployment lifecycle filter naming the deployment environments, kinds,
repositories and targets it may report — for example deployment environments `production`, kinds
`deployment` and `terraform`, repositories and targets `ryker`.

The route is projected as a system actor. Its environment, kind, repository, and target lists are
an allowlist, not hints. Only such a route may wake merged publication follow-up. Send the version
in the `X-Ryker-Event-Type: responder.publication_lifecycle.v1` header and use this exact JSON
request body:

```json
{
  "environment": "production",
  "kind": "deployment",
  "repository": "ryker",
  "references": [
    "https://github.com/acme/ryker/pull/91",
    "refs/heads/ryker/fix-91",
    "0123456789abcdef0123456789abcdef01234567"
  ],
  "run_ref": "deploy:production:1842",
  "state": "succeeded",
  "target": "ryker"
}
```

`kind` is `deployment` or `terraform`; `state` is `pending`, `succeeded`, or `failed`. The envelope
must match all four configured scope dimensions. References are bounded and compared by exact
equality only within publications for the named repository, using the recorded PR URL, full branch
ref, bare branch, publication commit, or merge SHA. Arbitrary prose, nested provider-specific
status fields, substring matches, ordinary app/bot/user inputs, and envelopes with extra or missing
fields do not wake an episode. The webhook's occurrence ID still owns replay and conflict semantics.
