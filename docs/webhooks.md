# Webhooks

Responder exposes one authenticated, source-neutral webhook edge with tagged transforms for
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

## Route configuration

Every route uses an explicit tagged adapter. Omitting `adapter` is equivalent to `universal` for
backward-compatible configuration.

```yaml
webhooks:
  ip: 127.0.0.1
  port: 4320
  routes:
    grafana:
      adapter:
        kind: grafana
        group_by_labels: [cluster, service]
      auth:
        kind: bearer
        secret_env: GRAFANA_WEBHOOK_TOKEN
      destination:
        transport: slack
        conversation_ref: slack:T0123456789:C0123456789
        thread_ref:
      work_profile:
        policy: responder-read-only-v1
        policy_digest: <64-lowercase-hex-digest>
        repository_ref: responder
      max_body_bytes: 40000
      max_clock_skew_seconds: 300
```

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
X-Responder-Timestamp: <Unix seconds>
X-Responder-Signature: v1=<hex HMAC-SHA256>
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

The metadata values are the exact `X-Responder-Event-ID`, `X-Responder-Item-ID`,
`X-Responder-Event-Type`, `X-Responder-Occurred-At`, and `X-Responder-Revision` request headers.
The timestamp must be within the route's configured clock-skew window. Universal routes require an
event ID. Grafana and mapped-JSON routes derive identity from the authenticated body, so those five
headers may be absent and are signed as empty strings. Changing either body or headers invalidates
the signature.

Webhook secrets must contain at least 16 bytes for bearer authentication and 32 bytes for HMAC.

## Universal JSON

`adapter.kind: universal` accepts any JSON value, including arrays and scalars, without interpreting
provider fields. The sender must supply a stable `X-Responder-Event-ID` for each occurrence.

```text
X-Responder-Event-ID: <required unique occurrence ID>
X-Responder-Item-ID: <optional stable item shared by revisions; defaults to event ID>
X-Responder-Event-Type: <optional bounded hint>
X-Responder-Occurred-At: <optional UTC ISO-8601 timestamp>
X-Responder-Revision: <optional positive integer; defaults to 1>
```

Universal input has reply capability only. Payload fields cannot grant reactions or choose a
platform target.

## Grafana alerts

`adapter.kind: grafana` accepts Grafana alert webhook JSON without Responder metadata headers. Each
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

```yaml
adapter:
  kind: mapped_json
  group_by_labels: [environment, service]
  mapping:
    event_id: event.id
    item_id: incident.alert_id
    incident_id: incident.id
    status: incident.state
    title: incident.title
    severity: incident.severity
    summary: incident.summary
    source_url: incident.url
    labels: incident.labels
    annotations: incident.annotations
    starts_at: incident.started_at
    ends_at: incident.ended_at
    revision: event.revision
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
