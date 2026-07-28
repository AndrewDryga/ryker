# Responder

[![CI](https://github.com/AndrewDryga/responder/actions/workflows/ci.yml/badge.svg)](https://github.com/AndrewDryga/responder/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/AndrewDryga/responder?sort=semver)](https://github.com/AndrewDryga/responder/releases/latest)

Responder turns authenticated alerts into focused Slack incident rooms backed by isolated
[Coop](https://github.com/AndrewDryga/coop) sessions and Emisar MCP access.

It is a single-host incident controller for pragmatic on-call teams:

- accepts bounded Grafana or mapped JSON webhooks;
- triages human and monitoring-app messages in configured Slack alert feeds, answering human
  questions in place and opening incidents only from credible app alerts, explicit requests, or
  operator-confirmed offers;
- correlates related signals and deduplicates webhook delivery;
- records source-attributed evidence, health-layer coverage, and an incident timeline separately
  from agent prose;
- creates one Slack channel and one pinned investigation card per incident occurrence;
- creates one Coop session and isolated fork under a predeclared repository policy;
- forwards only operator messages, concise agent responses, and review evidence;
- parks between turns, resumes the same agent conversation, and survives process restarts;
- exposes an App Home, Agent Messages tab, message shortcut, semantic progress, and
  deterministic controls for status, evidence, handoff, changes, review, draft PR publication,
  retained-work disposal, stop, and close;
- investigates live infrastructure through Emisar's policy-controlled read-only actions.

Responder does not merge, deploy, sign commits, or grant infrastructure authority. Coop owns the
fork and agent boundary. When explicitly configured, Responder can reproduce Coop's exact approved
tree, push only a lease-protected Responder branch, and create or update a draft GitHub pull
request. Emisar owns infrastructure policy, approval, execution, and audit.

## Quick start

Requirements:

- Go 1.26.5 or a released Responder binary;
- Coop with the local session API (`coop sessions serve`);
- a Slack workspace app created from [`deploy/slack-app-manifest.yaml`](deploy/slack-app-manifest.yaml)
  and configured using the [Slack app guide](docs/slack-app.md);
- an observe-scoped Emisar API key in `EMISAR_API_KEY`;
- a TLS reverse proxy for public webhook delivery.

After creating the Slack app, upload [`deploy/slack-app-icon.png`](deploy/slack-app-icon.png),
create an app-level token with `connections:write`, and use that `xapp-` value as
`SLACK_APP_TOKEN`. The manifest enables Socket Mode and contains the complete supported event,
scope, interactivity, and presentation configuration.

Install the current source build for your user:

```bash
make install
```

This writes `~/.local/bin/responder`; override `INSTALL_DIR` when needed. For a system installation
from source:

```bash
make build
sudo install -m 0755 bin/responder /usr/local/bin/responder
```

Or install the binary at the root of an unpacked release archive:

```bash
sudo install -m 0755 ./responder /usr/local/bin/responder
```

Release archives have a signed checksum manifest and GitHub build provenance. Verify them before
installation using the commands in [`docs/operations.md`](docs/operations.md#release-verification).

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

To expose additional MCP servers to every Responder turn, set `coop.additional_mcp_file` to an
owner-private `0600` file using the standard `{"mcpServers": {...}}` shape. Put any MCP-only
`NAME=value` credentials in a separate `coop.additional_env_file`, also owner-private. Responder
merges those sources into Coop's private projection, reserves the `emisar` server name, and refuses
to project configured Slack or webhook secrets. Stop Coop and rerun `bootstrap-coop` after either
source changes.

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

For a one-command foreground trial, set `coop.supervise: true` in Responder's configuration. Both
`doctor` and `serve` then launch Coop with the configured binary, state, policies, socket, and
private agent configuration. `doctor` stops its temporary child after preflight; `serve` restarts
Coop after unexpected exits and stops it when Responder shuts down:

```bash
sudo -u responder -g docker env \
  SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" \
  SLACK_APP_TOKEN="$SLACK_APP_TOKEN" \
  EMISAR_API_KEY="$EMISAR_API_KEY" \
  GRAFANA_WEBHOOK_TOKEN="$GRAFANA_WEBHOOK_TOKEN" \
  GENERIC_WEBHOOK_SECRET="$GENERIC_WEBHOOK_SECRET" \
  responder serve --config /etc/responder/responder.yaml
```

Responder refuses managed mode when another process owns the configured Coop socket. It also
removes the configured Slack, webhook, and Emisar variables from the child process environment;
Coop receives Emisar access through the private files written by `bootstrap-coop`, which project
`EMISAR_CLIENT=responder` into every incident box for client attribution.

With `coop.supervise: false`, start `coop sessions serve` separately or use the shipped split
systemd units. Then verify local state, Coop, Slack, and the authenticated Emisar MCP tool catalog:

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

Both systemd processes use the same restricted Unix account because Coop's v1 socket is owner-only.
Only the Coop unit receives the `docker` supplementary group; the Responder process does not.

`doctor` and `serve` initialize Emisar MCP with the configured token and require the operational
tools Responder depends on. This validates authentication and the tool catalog without executing an
infrastructure action. Every Coop turn also receives a mandatory claim-based evidence policy:
repository files establish declared topology and implementation, Emisar is preferred for live
infrastructure checks, and other available MCP servers or tools are used when they own relevant
evidence. A missing local cloud CLI is never treated as evidence that Emisar is unavailable.

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

Mention the bot in a configured summon channel to ask a question or request read-only work:

```text
@Responder investigate elevated checkout latency in production
```

Responder investigates and replies in that thread without creating an incident. An operator can ask
it to `open an incident for elevated checkout latency` to create one directly, or approve an
`Open incident room` offer after seeing the findings. In an incident channel, configured operators
can talk to Responder anywhere without repeating an `@mention`. It reads top-level messages and
threads, replies in the originating conversation when addressed or when it has something useful to
add, and may stay silent for ambient chatter. The pinned card updates in place with alert evidence,
investigation state, and only currently valid controls. Incident channels are private by default,
and all configured operators are invited automatically.

Shared-channel triage remains read-only. When an operator explicitly asks Responder to change
repository files, the reply can include a **Start engineering task** button instead of sending the
operator to another client. Confirmation keeps the task in that Slack thread and creates an isolated
writable Coop fork, where Responder can inspect, edit, test, and commit under the configured
repository policy. Later replies in the same thread continue the same session without an
`@mention`; unrelated channel messages remain in read-only triage. It does not create an incident,
and it does not merge, push, deploy, sign, or mutate infrastructure.

`slack.watch_channels` supplies the initial per-channel defaults. Operators can then configure
proactivity from Slack:

```text
/responder status
/responder incidents
/responder incidents all
/responder proactive on
/responder proactive off
/responder proactive inherit
/responder proactive global on
/responder proactive global off
/responder proactive global inherit
/responder shadow on
/responder shadow off
/responder shadow inherit
/responder timeline
/responder evidence
/responder handoff
/responder turn-limit
/responder turn-limit 1000
/responder turn-limit global 1000
```

The effective order is channel override, workspace override, then `responder.yaml`. Global `on`
therefore watches every channel where Responder is a member and receives events, while a channel
override can opt in or out. `inherit` removes that Slack override. Responder reads human and
external-app messages in Slack timestamp order and gives each decision a chronological transcript
of the latest 20 admitted channel messages. It waits for a two-second quiet period so nearby human
replies are visible, then chooses whether to stay silent, reply in the source message's thread, or
escalate. Human messages do not automatically become incidents: Responder answers in place and can
attach an `Open incident room` button when coordinated work would help. Only a configured operator
can approve that button. A credible unresolved monitoring-app alert can open automatically, and an
explicit human request to open, create, start, or declare an incident is honored directly. Both the
context size and settling delay are configurable. An explicit repository-change request can instead
offer a **Start engineering task** transition in the same thread to a writable isolated fork. A configured summon
mention starts the same read-only triage conversation; explicit incident wording remains
deterministic.

The Agent Messages tab supplies suggested health, alert, incident, and handoff prompts. The
message shortcut **Investigate message** starts the same read-only triage for a selected
message even when ordinary proactive listening is off. Long checks keep a native Slack progress
indicator with semantic milestones until the reply or a clear failure is posted.

Each shared operations channel keeps compact durable memory for the current goal, verified topology,
decisions, open questions, and evidence references. Responder rotates the underlying Coop session
after `coop.watch_session_max_turns` or `coop.watch_session_max_age` while preserving that summary.
`/responder shadow` runs the classifier and records its decision, evidence, and coverage without
posting or creating an incident.

`/responder incidents` lists open incidents with native Slack channel mentions and labels retained
channel names when a room is archived, deleted, or unavailable;
`/responder incidents all [page]` includes closed history. `/responder help` explains the complete
command surface and provides read-only buttons for current-channel status and incident directories.
Slack exposes only one static usage hint for a slash command, so the manifest keeps that picker text
short and moves detailed guidance into this interactive response. The same command also exposes
`timeline`, `evidence`, `handoff`, `update`, `changes`, `review`, `publish`, `stop`, and `close` in an
incident room. Closing posts an evidence-grounded post-incident draft. Responder automatically
allocates more Coop session capacity as authorized requests arrive. `/responder turn-limit` shows
or changes the channel or workspace lifetime safety ceiling; operators do not estimate how many
turns an investigation needs. Commands are deterministic, operator-authorized, durably processed,
and never interpreted by the model.

New incident channels use the validated `slack.channel_prefix` setting, which defaults to `ems`.
For example, `channel_prefix: sre` produces names beginning with `sre-`. Changing the setting does
not rename existing Slack channels.

Only configured operator user IDs who are full members of the configured workspace can steer an
incident agent or approve an incident offer. Watched-channel messages can produce only a
host-validated ignore, reply, incident offer, or permitted incident decision; they cannot invoke
incident controls or invent a repository or policy. Engineering-task offers bind to an exact
configured repository; when several are plausible, Responder asks the operator instead of silently
using the default.
Infrastructure access remains constrained by the selected Coop and Emisar policies. Slack guests
and external Slack Connect identities are denied. See
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

`responder status --json` returns both lifecycle counters and the bounded incident directory.
`responder failures` lists retryability and the retained error for failed Slack, webhook, outbox,
turn, publication, and cleanup work.

State is one owner-private SQLite database in `state_dir`. Slack inputs, webhook events, outgoing
messages, turn submissions, incident mappings, channel lifecycle, structured evidence, coverage,
channel memory, timelines, evaluation decisions, and audit records are durable.
Bounded retention removes expired operational payloads and closed work. Coop cleanup is restricted
to exact session IDs recorded by Responder: clean closed sessions and sessions whose reviewed tree
is durable in a draft PR are discarded after a grace period, while dirty or unpublished work is
retained. Deleting a Slack room does not itself discard work. See
[`docs/operations.md`](docs/operations.md) for retry and recovery behavior.

## V1 scope

V1 supports one Slack workspace and one repository binding per incident. Multiple routes can select
different repository policies. It can publish an explicitly authorized reviewed tree as a draft
GitHub pull request, but cannot merge, deploy from repository changes, archive Slack channels, or
execute model-selected containment. Operational mutation remains in operator-controlled Emisar
workflows until Slack approval can be bound to an exact host-validated request schema.

Run the full gate with:

```bash
make check
```

`make eval` parses the checked-in redacted JSONL decision fixtures. It verifies response-envelope
compatibility and expected actions; it does not call or score a model. Use shadow mode to collect
candidate decisions safely, review and redact them, then promote representative cases into
`testdata/eval/golden.jsonl` before changing prompts or models.

`make snapshot` builds the exact unsigned release archive layout locally; `make release-check`
runs the full gate, builds both Linux archives, checks every checksum and required deployment file,
and smoke-tests the host binary. On Linux it also executes the packaged native binary. See
[`docs/releasing.md`](docs/releasing.md) for the tag and publication contract.
