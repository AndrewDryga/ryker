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
- tracks every accepted investigation or engineering promise as durable work, and exposes it in
  App Home and through `/responder work`;
- exposes an App Home, Agent Messages tab, message shortcut, semantic progress, lightweight
  acknowledgements, and
  deterministic controls for status, evidence, handoff, changes, review, draft PR publication,
  retained-work disposal, stop, and close;
- can return bounded generated images and evidence-backed charts in the same Slack conversation,
  when the configured agent has an appropriate image or chart tool;
- investigates live infrastructure through Emisar and can submit an exact, directly requested
  incident action to Emisar's policy and approval workflow.

Responder does not merge, deploy, sign commits, or grant infrastructure authority. Coop owns the
fork and agent boundary. When explicitly configured, Responder can reproduce Coop's exact approved
tree, push only a lease-protected Responder branch, and create or update a draft GitHub pull
request. Emisar owns infrastructure policy, approval, execution, and audit.

See [How Responder works](docs/how-responder-works.md) for end-to-end diagrams covering Slack
message routing, Coop turns, memory, evidence, standing rules, incidents, approvals, retries, and
garbage collection.

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

A policy's `target` may instead be an ordered fallback ladder of up to four targets, which may
cross providers:

```yaml
    target: [codex:gpt-5.6/medium@oncall, claude@oncall]
```

Coop moves a rate-limited session to the next rung and re-delivers the same turn, so a usage limit
mid-incident costs a retry rather than the investigation. Sign in every rung — `responder doctor`
checks all of them, not just the one sessions start on.

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
Coop after unexpected exits and stops it when Responder shuts down. Before accepting Slack work,
managed startup verifies the real Coop box image and builds it when missing. `responder doctor`
fails with the exact `coop build` remediation when the execution image is unavailable:

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

Mention the bot in any channel where it has been invited to ask a question or request read-only
work:

```text
@Emisar investigate elevated checkout latency in production
```

Responder investigates and replies in that thread without creating an incident. An operator can ask
it to `open an incident for elevated checkout latency` to create one directly, or approve an
`Open incident room` offer after seeing the findings. In an incident channel, configured operators
can talk to Responder anywhere without repeating an `@mention`. Outside incident rooms, a delivered
triage answer opens a bounded 30-minute conversation window for nearby follow-ups in the same
channel or thread location. It reads top-level messages and threads, replies in the originating
conversation when addressed or when it has something useful to add, and may stay silent for ambient
chatter. The pinned card updates in place with alert evidence,
investigation state, and only currently valid controls. Incident channels are private by default,
and all configured operators are invited automatically.

Alerts, ambient conversation, and inferred intent remain read-only. A configured operator can ask
for one exact operational change in the current Slack conversation; Responder calls Emisar there,
without requiring an incident room. Emisar still owns target validation, policy, approval,
execution, and audit. A pending decision appears in the same conversation as a **Review approval in
Emisar** link. Responder watches that exact run in the background, updates the existing card as it
progresses, and automatically posts the terminal result plus read-only verification in the same
conversation. Waiting consumes no model turn and survives a Responder restart. When an operator
explicitly asks Responder to change repository files, the reply can
include a concise **Start task** button instead of sending the
operator to another client. Confirmation keeps the task in that Slack thread and creates an isolated
writable Coop fork, where Responder can inspect, edit, test, and commit under the configured
repository policy. Later replies in the same thread continue the same session without an
`@mention`; unrelated channel messages remain in read-only triage. It does not create an incident,
and it does not merge, push, deploy, sign, or mutate infrastructure.

Inviting `@Emisar` to a new channel first offers safe one-click defaults: mentions only or
proactive participation, the deployment repository, in-place app-alert replies, and no additional
incident invitees. **Customize** starts a four-question setup conversation for participation,
repository or repository-set context, app-alert escalation, and incident audience. A repository
set gives one primary writable repository plus exact-commit read-only companion snapshots. The
final card shows the normalized typed values and safety boundary; nothing changes until a
configured operator confirms it. Typed choices use Slack buttons. Configured operators are always
invited to incident rooms;
the audience step either adds no one else or accepts member and user-group mentions for additional
invitees. Emisar follows the operator between the channel and known setup threads, including
explicit `switch to a thread` and `back to the channel` requests, throughout the 30-minute setup.

The conversational surface is primary: ask `@Emisar how are you configured here?`, `show open
incidents`, `enable proactive mode`, or `reconfigure this channel`. Those phrases use the same
validated handlers below. `slack.watch_channels` supplies deployment defaults and `/responder`
remains the compatibility and recovery surface:

```text
/responder status
/responder work
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
/responder postmortem
/responder memory
/responder preferences
/responder rules
/responder turn-limit
/responder turn-limit 1000
/responder turn-limit global 1000
```

The effective order is explicit channel override, confirmed channel setup, workspace override, then
`responder.yaml`. Global `on`
therefore watches every channel where Responder is a member and receives events, while a channel
override can opt in or out. `inherit` removes that Slack override. Responder reads human and
external-app messages in Slack timestamp order and gives each decision a chronological transcript
centered on the target message. The default 20-message window includes the thread root, nearest
preceding replies, the target, and up to three immediately following messages; top-level requests
receive the equivalent channel window. It waits for a two-second quiet period so nearby human
replies are visible, then scores addressee, urgency, confidence, novelty, and ownership. It chooses
whether to stay silent, add a lightweight reaction, reply where the sender is speaking, or
escalate. Ambient replies and reactions have separate configurable attention thresholds, while
direct requests remain eligible regardless of those thresholds. Human messages do not
automatically become incidents: Responder answers in place and can
attach an `Open incident room` button when coordinated work would help. Only a configured operator
can approve that button. A credible unresolved monitoring-app alert follows the channel's
confirmed policy: reply in place, offer an incident button, or open automatically. An explicit
human request to open, create, start, or declare an incident is honored directly. Both the
context size and settling delay are configurable. An explicit repository-change request can instead
offer a **Start task** transition in the same thread to a writable isolated fork. A configured summon
mention starts the same read-only triage conversation; explicit incident wording remains
deterministic.

When a decision-ready diagnosis establishes a narrow repository fix, Responder may also show
**Prepare code fix** beside **Open incident room**. The choices are independent: the incident room
coordinates operations, while the engineering task edits and validates code in the source thread.
The fix button creates no PR by itself; after a real diff exists, the task card exposes the separate
**Create draft PR** review control.

The Agent Messages tab supplies suggested health, alert, incident, and handoff prompts. The
message shortcut **Investigate message** starts the same read-only triage for a selected
message even when ordinary proactive listening is off. Long checks keep a native Slack progress
indicator with semantic milestones until the reply or a clear failure is posted.

Each Slack conversation keeps a compact durable situation: channel purpose, current goal, active
topics, verified topology, decisions, open loops, unresolved questions, and evidence references.
Future turns receive the exact conversation summary, recent summaries from other conversations in
the same channel, and recent summaries from public channels across the workspace. Same-repository
work is preferred, while private-channel summaries never cross into another channel without a
membership proof. Responder rotates the underlying per-channel Coop session
after `coop.watch_session_max_turns` or `coop.watch_session_max_age` while preserving that summary.
Recent conversation summaries are consolidated into privacy-scoped weekly continuity rollups after
`memory.compact_after`, seven days by default, and expire after
`retention.conversation_memory`, 90 days by default. The background pass is deterministic: it
groups and bounds summaries the model already produced, so it adds no second model call. Public
channel summaries may roll up by repository; private summaries remain scoped to their channel.
Storage pressure can trigger earlier compaction while preserving the latest hour of conversation
context.
This session summary is separate from operator-confirmed durable memory. An operator can ask
Responder to remember an alias, channel-to-repository binding, evidence route, entity relationship
correction, or open-ended guidance such as `when explaining a fix to me, start with a simple
summary`. Responder shows the normalized value, scope, and expiry in a confirmation card; nothing
is saved until an operator confirms it. Personal guidance can follow that operator across channels,
while channel and workspace guidance can encode explicit team conventions. Saved entries are
bounded, deduplicated by logical key, expire automatically, can be forgotten from App Home, and are
supplied to future model turns only as advisory context. Guidance cannot start work, authorize an
incident or change, approve an action, or count as operational evidence. The current request, host
safety policy, fresh live evidence, current repository content, and Responder configuration always
take precedence. Recent structured evidence remains
source-attributed; compact related summaries carry continuity across channels without becoming
current-health proof.

Responder records when confirmed memory and continuity rollups are recalled. A scheduled review
flags confirmed entries that have not been used or reviewed recently and identifies exact duplicate
guidance, but it never silently edits operator-confirmed memory. `/responder memory` shows memory
health and `/responder memory review` provides keep, merge, and forget decisions. Replacements keep
a hash-only supersession record; old values are not copied into audit state. These mechanisms are
inspired by the freshness, continuity, and reviewability goals in OpenAI's
[Memory and new controls for ChatGPT](https://openai.com/index/chatgpt-memory-dreaming/), while
retaining Responder's stricter operational evidence and approval boundaries.

Responder also supports two operator-confirmed behavior catalogs. Preferences are typed defaults
such as `health_check_depth=deep`, `response_detail=concise`, or
`response_location=prefer_thread`; their precedence is operator, channel, repository, then
workspace. Standing rules are typed channel subscriptions such as
`terraform_plan -> review_terraform_plan`, restricted to human, app, or any matching message. A
request such as `when I ask about infrastructure health, always do a deep check` or `when you see a
Terraform plan here, report its main diff and red flags` produces a confirmation card showing the
normalized behavior, scope, expiry, source filter, and fixed read-only safety boundary. Open-ended
guidance may be remembered as advisory model context, but arbitrary prose is never stored as an
executable trigger or authority. A configured operator can make this explicit
setup request in any channel where Responder is invited, even when that channel is not otherwise a
summon or proactive channel.

`/responder preferences` and `/responder rules` list active and disabled entries with enable,
disable, edit, and delete controls. An enabled standing rule may admit only its deterministic
message type even when broad proactive triage is off. A match asks the model to evaluate the event;
it does not force a reply. The model may ignore an intermediate or duplicate event, react when that
is sufficient, or reply in the source thread when it has a useful result. Later lifecycle updates
are evaluated independently. Operational-alert replies must reconcile repository topology with
fresh live evidence and return a decision-ready verdict, impact, and next action. Confirmed or
likely issues also include an immediate mitigation and a durable solution; Responder sends shallow
symptom summaries back to the same run for more investigation. Terraform reviews still require the
exact plan; repository changes provide context but never replace it. Slack events remain ordered per
channel, and each rule
records its source event before incrementing its run count so retries cannot execute it twice.
Expiry, capacity limits, channel deletion, repository removal, and maintenance pruning bound all
durable behavior state.

Configured operators can also create one-time and recurring tasks in ordinary language: `remind me
in 4 hours`, `every weekday at 09:00 check production health`, or `on the first of each month prepare
an SRE review`. Emisar replies with a confirmation card containing the normalized task, destination,
repository, recurrence, timezone, next run, expiry, and safety boundary. Nothing runs until an
operator confirms it. `/responder schedules` lists the current channel's tasks with run-now,
pause/resume, replace, and delete controls.

Schedules are durable wake-ups, not stored authority. Each occurrence enters the normal Slack/Coop
agent pipeline with fresh repository, tool, memory, authorization, and Emisar policy context. The
scheduler records each occurrence before dispatch, never overlaps two copies of the same task, and
uses IANA timezone calendar arithmetic so local times follow daylight-saving changes. `catch_up`
can run only the latest missed occurrence after downtime or skip it after the configured grace
period. One-time tasks complete after their occurrence; run-now remains available for an explicit
manual repeat. Expired tasks and old run records are removed by normal retention maintenance.
`/responder shadow` runs the classifier and records its decision, evidence, and coverage without
posting or creating an incident.

Every accepted model-backed request also creates a durable commitment before execution. The
commitment follows the underlying run through queued, working, finishing, done, blocked, or
cancelled state and survives restart. Ask `what are you working on?`, run `/responder work`, or
open App Home to see the exact request, current status, and next operator action. This is distinct
from memory: a commitment is work Emisar owes the team, not a fact to reuse later.

`/responder incidents` lists open incidents with native Slack channel mentions and labels retained
channel names when a room is archived, deleted, or unavailable;
`/responder incidents all [page]` includes closed history. `/responder help` explains the complete
command surface and provides read-only buttons for current-channel status and incident directories.
Slack exposes only one static usage hint for a slash command, so the manifest keeps that picker text
short and moves detailed guidance into this interactive response. The same command also exposes
`timeline`, `evidence`, `handoff`, `postmortem`, `update`, `changes`, `review`, `publish`, `stop`, and
`close` in an incident room. The remediation timeline is derived from the alert, agent runs,
evidence, Emisar approvals, and draft-PR publication state instead of copying those
facts into a second incident system. Closing posts the same evidence-grounded post-incident draft
that `/responder postmortem` can regenerate from the durable record. Responder automatically
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
responder retry --config /etc/responder/responder.yaml delivery delivery_...
responder replay slack --config /etc/responder/responder.yaml \
  --url 'https://workspace.slack.com/archives/C0123/p1785652207489039'
curl -f http://127.0.0.1:8080/healthz
curl -f http://127.0.0.1:8080/readyz
curl -f http://127.0.0.1:8080/metrics
```

`responder status --json` returns both lifecycle counters and the bounded incident directory.
`responder failures` lists retryability and the retained error for failed Slack inputs, webhooks,
Slack deliveries, agent runs, publications, and cleanup work.
`responder replay slack` is a post-fix live verification tool. It clones the saved text,
attachments, actor, channel, thread, and timestamp behind a Slack permalink (or accepts
`--input` or `--channel` plus `--message-ts`), gives the clone a fresh idempotency identity, and
queues it through the running service. Replays are private by default: the normal model and tool
path runs, but Responder suppresses Slack status, reactions, messages, offers, schedules, tasks,
and incidents. The command validates the resulting action without impersonating a new user turn.
Add `--publish` only when another real response in the original Slack conversation is intentional;
published replay additionally requires confirmed delivery and deterministic UX validation of the
exact persisted message payload. Use `--expect react`, `ignore`, `incident`, or `any` only when
that outcome is intentional.

State is one owner-private SQLite database in `state_dir`. Slack inputs, webhook events, outgoing
Slack deliveries, agent runs, incident mappings, channel lifecycle, structured evidence, coverage,
channel memory, operator-confirmed operational memory, Emisar approval holds, timelines,
evaluation decisions, audit records, and the scheduler's compact work index are durable. Before a
schema upgrade Responder creates and verifies a private pre-migration snapshot and retains the three
newest migration backups.
Bounded retention removes expired operational payloads and closed work, and expires finished episode
history on a separate, much longer horizon because that record is what the replay-fixture corpus is
built from. No horizon deletes an episode a pending correction, open feedback, a live wakeup, an
unfinished run, or an open incident still depends on. Coop cleanup is restricted
to exact session IDs recorded by Responder: clean closed sessions and sessions whose reviewed tree
is durable in a draft PR are discarded after a grace period, while dirty or unpublished work is
retained. Deleting a Slack room does not itself discard work. See
[`docs/operations.md`](docs/operations.md) for retry and recovery behavior.

## V1 scope

V1 supports one Slack workspace and one repository context per incident. A context may be one
repository or an explicit repository set: one primary writable/publishable repository and up to 32
operator-configured read-only companion repositories pinned at session creation. Multiple routes
can select different contexts and Coop policies. Responder never accepts host paths from Slack or
model output; the local Coop policy is their only authority. It can publish an explicitly
authorized reviewed primary tree as a draft GitHub pull request, but cannot publish companion
changes, merge, deploy from repository changes, or archive Slack channels.
Automatic and inferred operational changes remain disabled. In any Slack conversation, a
configured operator may directly request one exact operational action. Emisar remains authoritative
for target validation, policy, approval, execution, and audit; Slack only links to the exact pending
approval returned by Emisar. Responder monitors and reports that exact run but cannot approve it,
substitute another run, or repeat the mutation during terminal verification.

Use the fast deterministic development gate while iterating:

```bash
make dev-check
```

Run the full CI and release gate once before shipping concurrency, persistence, security, or
shared-contract changes:

```bash
make check
```

`make customer-check` is the faster deterministic product-behavior gate: it runs the Go customer
journeys and replays the checked-in redacted JSONL response corpus through strict production
parsers. It does not call a model. `make eval CONFIG=/path/to/responder.yaml` is the actual
behavior eval: every case calls the configured model through its own Coop session, uses the
production prompts and tool configuration, scores the returned decision, then discards the
workspace only after Coop proves it is clean. Use shadow mode to collect candidate decisions
safely, review and redact them, then promote representative contracts into the replay or live
corpus before changing prompts or models. Use `--case`, `--repeat`, and `--results` for focused
variance testing and private sanitized diagnostics. `make model-release-check` additionally
calibrates the qualitative judge, evaluates the rendered Slack experience, measures proactive
precision and recall, runs multi-turn cross-channel and old-thread scenarios, and independently
re-checks high-risk operational claims, and replays the corrections an operator kept.
`make eval-productivity` adds an observable commit-and-review outcome when a disposable writable
Coop policy is available. Every model evaluation records its result, and `make eval-trend` prints
the pass rate and mean judge score over time so a release can say whether answers are improving
rather than only that the gate passed. See [`docs/testing.md`](docs/testing.md) for the coverage
matrix and bounded live acceptance set.

`make snapshot` builds the exact unsigned release archive layout locally; `make release-check`
runs the full gate, builds both Linux archives, checks every checksum and required deployment file,
and smoke-tests the host binary. On Linux it also executes the packaged native binary. See
[`docs/releasing.md`](docs/releasing.md) for the tag and publication contract.
