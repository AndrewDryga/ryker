# Responder

Responder turns authenticated alerts into focused Slack incident rooms backed by isolated
[Coop](https://github.com/AndrewDryga/coop) sessions and Emisar MCP access.

It is a single-host incident controller for pragmatic on-call teams:

- accepts bounded Grafana or mapped JSON webhooks;
- correlates related signals and deduplicates webhook delivery;
- creates one Slack channel and one pinned investigation thread per incident occurrence;
- creates one Coop session and isolated fork under a predeclared repository policy;
- forwards only operator messages, concise agent responses, and review evidence;
- parks between turns, resumes the same agent conversation, and survives process restarts;
- exposes deterministic Slack controls for status, changes, review, stop, and close.

Responder does not merge, push, deploy, sign commits, or grant infrastructure authority. Coop owns
the fork and agent boundary. Emisar owns infrastructure policy, approval, execution, and audit.

## Quick start

Requirements:

- Go 1.26.5 or a released Responder binary;
- Coop with the local session API (`coop sessions serve`);
- a Slack workspace app created from [`deploy/slack-app-manifest.yaml`](deploy/slack-app-manifest.yaml);
- an observe-scoped Emisar API key in `EMISAR_API_KEY`;
- a TLS reverse proxy for public webhook delivery.

After creating the Slack app, enable Socket Mode and create an app-level token with
`connections:write`; use that `xapp-` value as `SLACK_APP_TOKEN`.

Build and install from a source checkout:

```bash
make build
sudo install -m 0755 bin/responder /usr/local/bin/responder
```

Or install the binary at the root of an unpacked release archive:

```bash
sudo install -m 0755 ./responder /usr/local/bin/responder
```

Then create the service account and configuration:

```bash
getent passwd responder >/dev/null || \
  sudo useradd --system --home-dir /var/lib/responder --shell /usr/sbin/nologin responder
sudo install -d -o root -g responder -m 0750 /etc/responder
sudo install -d -o responder -g responder -m 0700 /var/lib/responder
sudo install -o root -g responder -m 0640 \
  config/responder.example.yaml /etc/responder/responder.yaml
sudo install -o root -g responder -m 0640 \
  deploy/coop/session-policies.example.yaml /etc/responder/session-policies.yaml
sudo install -o root -g responder -m 0640 \
  deploy/systemd/responder.env.example /etc/responder/responder.env
```

The account-creation command keeps an existing `responder` user. Edit the Slack IDs, repository
path, Coop policy, webhook route, and `/etc/responder/responder.env`. For a manual foreground trial,
export the same variables:

```bash
export SLACK_BOT_TOKEN='xoxb-...'
export SLACK_APP_TOKEN='xapp-...'
export EMISAR_API_KEY='...'
export GRAFANA_WEBHOOK_TOKEN='...'
export GENERIC_WEBHOOK_SECRET='...'
```

Every configured secret must contain at least 16 bytes. Use independently generated random values
for webhook authentication.

Create Coop's private MCP projection:

```bash
sudo -u responder env EMISAR_API_KEY="$EMISAR_API_KEY" \
  responder bootstrap-coop --config /etc/responder/responder.yaml
```

Authenticate the agent account into that same dedicated Coop configuration:

```bash
sudo -u responder env COOP_CONFIG_DIR=/var/lib/responder/coop/agents \
  coop login codex@oncall
```

The policy repositories must already be canonical Git worktrees owned by or writable to
`responder`; cloning them as that account under `/srv/repos` is the simplest setup:

```bash
sudo install -d -o responder -g responder -m 0700 /srv/repos
sudo -u responder git clone <infrastructure-repository-url> /srv/repos/infrastructure
sudo -u responder git clone <backend-repository-url> /srv/repos/backend
```

Start Coop with that dedicated configuration:

```bash
sudo -u responder -g docker env COOP_CONFIG_DIR=/var/lib/responder/coop/agents \
  coop sessions serve \
  --state /var/lib/responder/coop \
  --policies /etc/responder/session-policies.yaml \
  --socket /var/lib/responder/coop/control.sock
```

Then verify local state, Coop, Slack, and the presence and current projection of the Emisar token:

```bash
sudo -u responder env \
  SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" \
  SLACK_APP_TOKEN="$SLACK_APP_TOKEN" \
  EMISAR_API_KEY="$EMISAR_API_KEY" \
  GRAFANA_WEBHOOK_TOKEN="$GRAFANA_WEBHOOK_TOKEN" \
  GENERIC_WEBHOOK_SECRET="$GENERIC_WEBHOOK_SECRET" \
  responder doctor --config /etc/responder/responder.yaml
```

For a supervised installation, install the units from `deploy/systemd/`, then enable
`responder.service`; it starts Coop first:

```bash
sudo install -o root -g root -m 0644 \
  deploy/systemd/coop-responder.service /etc/systemd/system/coop-responder.service
sudo install -o root -g root -m 0644 \
  deploy/systemd/responder.service /etc/systemd/system/responder.service
sudo systemctl daemon-reload
sudo systemctl enable --now responder.service
sudo systemctl status coop-responder.service responder.service
curl -f http://127.0.0.1:8080/readyz
```

Both processes use the same restricted Unix account because Coop's v1 socket is owner-only. Only
the Coop unit receives the `docker` supplementary group; the Responder process does not.

`doctor` validates that the configured Emisar token is present and exactly projected into Coop. The
first real investigation validates its server-side scope and MCP authorization; Responder does not
make an infrastructure request during preflight.

## Webhooks

The service listens on loopback. Publish only `/v1/hooks/` through a TLS reverse proxy. Health and
metrics can remain local.

Grafana route:

```bash
curl -f \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer example-secret' \
  -H 'X-Responder-Event-ID: grafana-delivery-123' \
  --data-binary @grafana-alert.json \
  http://127.0.0.1:8080/v1/hooks/grafana
```

Grafana's alert fingerprint is the stable signal identity. Its `groupKey` is the preferred incident
correlation key; configured labels are the fallback. A resolved, unclosed incident can reactivate
in its existing channel. A firing signal after manual close creates a new occurrence, channel, and
fork.

Generic routes use deliberately small dot-path mappings. See
[`docs/webhooks.md`](docs/webhooks.md). There is no embedded scripting language.

## Slack

Mention the bot in a configured summon channel to start a manual incident:

```text
@Responder investigate elevated checkout latency in production
```

Responder acknowledges the request in that thread, then creates the incident channel. In the
incident channel, collaborate by replying to the pinned card. No repeated mention is needed.
Incident channels are private by default; all configured operators are invited automatically.

Only configured operator user IDs who are full members of the configured workspace can steer the
agent. Slack guests, bots, and external Slack Connect identities are denied. See
[`docs/slack-ux.md`](docs/slack-ux.md) for the complete interaction contract.

## Operations

```bash
responder status --config /etc/responder/responder.yaml
responder status --config /etc/responder/responder.yaml --json
responder failures --config /etc/responder/responder.yaml
responder retry --config /etc/responder/responder.yaml outbox out_...
curl -f http://127.0.0.1:8080/healthz
curl -f http://127.0.0.1:8080/readyz
curl -f http://127.0.0.1:8080/metrics
```

State is one owner-private SQLite database in `state_dir`. Slack inputs, webhook events, outgoing
messages, turn submissions, incident mappings, and audit records are durable. See
[`docs/operations.md`](docs/operations.md) for retry and recovery behavior.

## V1 scope

V1 supports one Slack workspace and one repository binding per incident. Multiple routes can select
different repository policies. It preserves Coop forks for review but does not publish GitHub pull
requests, merge, deploy, archive Slack channels, or execute automatic containment. Those require a
separate explicit authority and should not be hidden in the conversational bridge.

Run the full gate with:

```bash
make check
```
