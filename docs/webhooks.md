# Webhooks

## Public edge

Responder only listens on loopback. Terminate TLS and enforce any network allowlist in a reverse
proxy. Publish `/v1/hooks/<route>` and keep `/healthz`, `/readyz`, and `/metrics` private.

Every request must:

- use `POST`;
- use `Content-Type: application/json`;
- stay under `limits.max_webhook_bytes`;
- authenticate with the route's configured mode;
- contain one JSON value.

`X-Responder-Event-ID` is an optional stable delivery ID. Without it, the SHA-256 body digest is
the delivery ID. Reusing an explicit ID with different content returns `409 Conflict`. Webhook
secrets must contain at least 16 bytes.

## Bearer authentication

Configuration:

```yaml
auth: bearer
secret_env: GRAFANA_WEBHOOK_TOKEN
```

Request:

```text
Authorization: Bearer <secret>
```

Exactly one Authorization header is accepted.

## HMAC-SHA256 authentication

Configuration:

```yaml
auth: hmac-sha256
secret_env: GENERIC_WEBHOOK_SECRET
```

Compute:

```text
hex(HMAC-SHA256(secret, timestamp + "." + event_id + "." + raw_request_body))
```

Send:

```text
X-Responder-Timestamp: <Unix seconds>
X-Responder-Signature: sha256=<lowercase hex digest>
X-Responder-Event-ID: <stable delivery ID, or omit>
```

The timestamp must be within five minutes of the service clock. Exactly one timestamp and signature
header are accepted. When the event ID header is omitted, sign an empty `event_id`, including both
period separators. Binding the event ID prevents an authenticated payload from being replayed under
a different deduplication identity.

## Grafana

`kind: grafana` accepts Grafana alert webhook JSON. Each entry in `alerts` becomes a normalized
signal. At most 500 alerts are accepted per delivery.

Signal fields are selected as follows:

| Normalized field | Grafana source |
| --- | --- |
| identity | `alerts[].fingerprint`, otherwise a stable labels/start digest |
| incident source | top-level `groupKey` |
| title | `summary`, `title`, `alertname`, then top-level title |
| severity | `severity`, `priority`, then `level` label |
| summary | `description`, `message`, then top-level message |
| link | panel, dashboard, generator, then external URL |

Only `http` and `https` links are retained.

Point the Grafana contact point at:

```text
https://responder.example.com/v1/hooks/grafana
```

Add `Authorization: Bearer ...` as a contact-point HTTP header. A stable delivery header is useful
but not required.

## Generic JSON

Generic mapping supports object dot paths only. It deliberately does not execute jq, CEL,
templates, shell, or user scripts.

Example payload:

```json
{
  "event": {"id": "evt-123"},
  "incident": {
    "id": "checkout-prod",
    "status": "firing",
    "title": "Checkout error rate",
    "severity": "critical",
    "summary": "5xx exceeded 10%",
    "url": "https://monitoring.example/incidents/checkout-prod",
    "started_at": "2026-07-27T01:00:00Z",
    "labels": {"environment": "prod", "service": "checkout"},
    "annotations": {"runbook": "checkout-errors"}
  }
}
```

Required mappings are `event_id`, `status`, and `title`. Supported firing states include `firing`,
`alerting`, `active`, `open`, and `triggered`. Supported resolved states include `resolved`, `ok`,
`closed`, `normal`, and `recovered`.

If `incident_id` is absent, configured `group_by_labels` values form the incident correlation key.
If none exists, the signal itself is isolated into its own incident.

## Change events

`kind: change` records what changed instead of opening an incident. A change route never creates a
signal, never opens an incident, and never starts work. Its rows reach an incident or operational
assessment prompt as `recent_changes` — correlation material scoped to the services that incident
implicates, inside the untrusted-context framing.

A change may be cited as the cause of an alert only through a proper `record_evidence` operation:
the host's cause gate still requires evidence IDs bound to recorded claims, so a `change_id` on its
own is never a cause.

Mapping supports the same object dot paths as generic JSON, and nothing else.

Example payload:

```json
{
  "event": {"type": "release"},
  "deployment": {
    "finished_at": "2026-08-14T11:50:00Z",
    "description": "checkout v41",
    "actor": {"login": "dana"},
    "sha": "9f21c0a",
    "url": "https://deploys.example/releases/41",
    "services": ["checkout", "cart"],
    "repositories": ["example/backend"]
  }
}
```

Matching route:

```yaml
webhooks:
  deploys:
    kind: change
    auth: hmac-sha256
    secret_env: DEPLOY_WEBHOOK_SECRET
    repository: backend
    change:
      kind: event.type
      occurred_at: deployment.finished_at
      summary: deployment.description
      actor: deployment.actor.login
      revision: deployment.sha
      source_url: deployment.url
      services: deployment.services
      repositories: deployment.repositories
```

Every mapping is optional. An unmapped `kind` records a `deploy`; an unmapped `occurred_at` records
when Responder received the delivery. `services` and `repositories` each accept one scalar or an
array of scalars, and the route's own `repository` is always added to the scope, so a route that
maps neither still records a recallable change.

| Change kind | Accepted values |
| --- | --- |
| `deploy` | `deploy`, `deployment`, `deployed`, `release`, `released`, `rollout` |
| `merge` | `merge`, `merged`, `pull_request`, `pr` |
| `infra_apply` | `infra_apply`, `apply`, `applied`, `terraform`, `terraform_apply` |
| `flag` | `flag`, `feature_flag`, `toggle`, `flag_change` |
| `config` | `config`, `configuration`, `setting`, `config_change` |

A mapped value outside this vocabulary is rejected with `400`. It is not silently recorded as a
deploy: a mapping typo should stop where an operator can see it rather than reach an incident
prompt as a change that never happened.

A feature-flag service needs no code beyond this route. Point `kind` at whatever the provider calls
its event and `services` at the flag's owning service:

```yaml
    change:
      kind: kind
      occurred_at: date
      summary: titleVerbose
      actor: member.email
      services: environment.name
```

Authentication, the replay window, and deduplication are identical to every other route. The
ledger's identity is the same `X-Responder-Event-ID` the signature binds, so a redelivery records
one change and a replay under a different event ID fails the signature. Change events are retained
on the episode-history horizon, outliving the webhook body that delivered them.
