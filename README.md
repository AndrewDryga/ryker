# Ryker

[![CI](https://github.com/AndrewDryga/ryker/actions/workflows/ci.yml/badge.svg)](https://github.com/AndrewDryga/ryker/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/AndrewDryga/ryker?sort=semver)](https://github.com/AndrewDryga/ryker/releases/latest)

Ryker is a persistent engineering and operations teammate backed by isolated
[Coop](https://github.com/AndrewDryga/coop) sessions and governed Emisar access. Its core is
platform-neutral: Slack, GitHub comments and pull-request reviews, and authenticated webhooks are
adapters over the same ingress, episode, Work, and Delivery contracts. It can answer, investigate,
change code, and prepare reviewed work without turning every request into an incident.


It runs on one trusted host and:

- accepts arbitrary authenticated JSON through configured universal webhook routes without granting
  the payload authority over policy or destination;
- translates Grafana alert lifecycles and configured bounded mapped-JSON alerts into the same
  source-neutral ingress without provider rules in admission;
- handles GitHub issue comments, pull-request reviews, inline review comments, and GitHub's native
  reaction set through a repository-scoped App adapter;
- triages human and monitoring-app messages in configured Slack alert feeds, answering human
  questions in place and opening incidents only from credible app alerts, explicit requests, or
  operator-confirmed offers;
- correlates related signals and deduplicates webhook delivery;
- records source-attributed evidence, health-layer coverage, and an incident timeline separately
  from agent prose;
- creates one Slack channel and one pinned investigation card per incident occurrence;
- creates one Coop session and isolated fork under a predeclared repository policy;
- lets active full workspace members collaborate on contributor tasks for the repository assigned
  to their channel, without projecting shared MCP tools or environment secrets;
- keeps operator-capability tasks, incident steering, publication, destructive controls, and
  governed operational actions restricted to configured operators;
- parks between turns, resumes the same agent conversation, and survives process restarts;
- tracks every accepted investigation or engineering promise as durable work, and exposes it in
  the App Home and the web control plane;
- exposes an App Home, Agent Messages tab, message shortcut, semantic progress, lightweight
  acknowledgements, and
  deterministic controls for status, evidence, handoff, changes, review, draft PR publication,
  retained-work disposal, stop, and close;
- can return bounded generated images and evidence-backed charts in the same Slack conversation,
  when the configured agent has an appropriate image or chart tool;
- investigates live infrastructure through Emisar and can submit an exact, directly requested
  incident action to Emisar's policy and approval workflow.

Ryker does not merge, deploy, sign commits, or grant infrastructure authority. Coop owns the
fork and agent boundary. A contributor can prepare and review code in an isolated fork; a configured
operator must authorize Ryker to reproduce the exact approved tree, push a lease-protected
Ryker branch, and create or update a draft GitHub pull request. Emisar owns infrastructure
policy, approval, execution, and audit.

The adapter and delivery boundary is documented in
[Elixir platform adapters and delivery](docs/elixir-platform-adapters.md).

For memory-system design work, consult the
[memory research knowledge base](docs/research/memory-systems.md): external evidence, failure
patterns, pragmatic design decisions, and acceptance criteria. It is research, not a runtime contract.

## Quick start

The production service is the Elixir/PostgreSQL release. It uses one durable writer deployment;
process or host replacement recovers leases, frozen model submissions, delivery intents, waits,
schedules, and remote-worker placement from PostgreSQL. It does not require a canary/promote state
machine.

Requirements:

- PostgreSQL and the released Linux amd64 Elixir archive;
- at least one enrolled Coop fleet worker with the reviewed policy digests;
- the platform credentials for the integrations you enable in settings, listed in
  [`deploy/systemd/ryker.env.example`](deploy/systemd/ryker.env.example); and
- TLS termination for `/v1/github` and `/v1/hooks/<route>`.

Download the Elixir archive, `checksums.txt`, `checksums.txt.bundle`,
`install-elixir-release.sh`, `check-elixir-release.sh`, and
`activate-elixir-release.sh` from one GitHub Release. Authenticate the checksum manifest and every
executable helper before executing the installer; the installer repeats that verification, verifies
GitHub build provenance, verifies the archive digest before listing or extraction, and installs an
immutable version directory:

```bash
tag=vX.Y.Z
version=${tag#v}
artifact="ryker_${version}_elixir_linux_amd64.tar.gz"

cosign verify-blob checksums.txt \
  --bundle checksums.txt.bundle \
  --certificate-identity \
  "https://github.com/AndrewDryga/ryker/.github/workflows/release.yml@refs/tags/${tag}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
for helper in install-elixir-release.sh check-elixir-release.sh activate-elixir-release.sh; do
  awk -v file="$helper" '$2 == file { print }' checksums.txt | sha256sum --check
  chmod 0755 "$helper"
done
sudo ./install-elixir-release.sh \
  "$artifact" "$version" checksums.txt checksums.txt.bundle "$tag" \
  /usr/local/lib/ryker
```

Create the runtime account and copy the authenticated operator assets embedded in that same
release:

```bash
getent passwd ryker >/dev/null || \
  sudo useradd --system --home-dir /var/lib/ryker --shell /usr/sbin/nologin ryker
sudo install -d -o root -g ryker -m 0750 /etc/ryker
sudo install -d -o ryker -g ryker -m 0700 /var/lib/ryker
assets=/usr/local/lib/ryker/current/share/ryker
sudo install -o root -g ryker -m 0600 \
  "$assets/deploy/systemd/ryker.env.example" /etc/ryker/ryker.env
sudo install -o root -g root -m 0644 \
  "$assets/deploy/systemd/ryker.service" /etc/systemd/system/ryker.service
sudo install -o root -g root -m 0644 \
  "$assets/deploy/nginx/ryker.conf" /etc/nginx/conf.d/ryker.conf
```

Replace every placeholder in the owner-only environment file, install the worker gateway
CA/certificate files, then start normally. The service starts with no product configuration at
all: open `http://127.0.0.1:4321/configuration` and connect Slack, GitHub, repositories,
execution policies, webhook sources and retention there. Saves apply to the running service
without a deployment, and the page shows the saved revision beside the running one.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ryker.service
curl -f http://127.0.0.1:4321/healthz
curl -f http://127.0.0.1:4321/readyz
```

Then open `http://127.0.0.1:4321/conversations` for direct conversations with the
agent, without Slack, through the real durable product pipeline. The manual
qualification journeys for Slack, GitHub, webhooks, state tools and recovery are
in [`docs/testing.md`](docs/testing.md#manual-qualification).

The unit runs PostgreSQL migrations before opening listeners. See
[`docs/elixir-platform-adapters.md`](docs/elixir-platform-adapters.md) for Slack/GitHub/webhook
bindings, and [`docs/operations.md`](docs/operations.md) for backup, restart, rollback, and live
acceptance.

## Webhooks

The service listens on loopback. Publish only `/v1/hooks/` through a TLS reverse proxy. Health and
metrics can remain local.

Grafana route:

```bash
curl -f \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer example-secret' \
  --data-binary @grafana-alert.json \
  http://127.0.0.1:4320/v1/hooks/grafana
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

Ryker investigates and replies in that thread without creating an incident. An operator can ask
it to `open an incident for elevated checkout latency` to create one directly, or approve an
`Open incident room` offer after seeing the findings. In an incident channel, configured operators
can talk to Ryker anywhere without repeating an `@mention`. Outside incident rooms, a delivered
triage answer opens a bounded 30-minute conversation window for nearby follow-ups in the same
channel or thread location. It reads top-level messages and threads, replies in the originating
conversation when addressed or when it has something useful to add, and may stay silent for ambient
chatter. The pinned card updates in place with alert evidence,
investigation state, and only currently valid controls. Incident channels are private by default,
and all configured operators are invited automatically.

Alerts, ambient conversation, and inferred intent remain read-only. A configured operator can ask
for one exact operational change in the current Slack conversation; Ryker calls Emisar there,
without requiring an incident room. Emisar still owns target validation, policy, approval,
execution, and audit. A pending decision appears in the same conversation as a **Review approval in
Emisar** link. Ryker watches that exact run in the background, updates the existing card as it
progresses, and automatically posts the terminal result plus read-only verification in the same
conversation. Waiting consumes no model turn and survives a Ryker restart. When an active full
workspace member explicitly asks Ryker to change repository files, the reply can include a
concise **Start task** button instead of sending the teammate to another client. Confirmation by
any active full workspace member keeps the task in that Slack thread and creates an isolated
writable Coop fork, where Ryker can inspect, edit, test, and commit under the configured
repository policy. Later replies in the same thread continue the same session without an
`@mention`; unrelated channel messages remain in read-only triage. It does not create an incident,
and it does not merge, deploy, sign, or mutate infrastructure. Any active full workspace member can
collaborate in the task thread and inspect or review its changes. A configured operator must press
the publication control before Ryker can push the verified tree and create or update a draft PR.

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

The conversational surface is primary: ask `@Emisar` in your own words and the model classifies what
you meant, then the host executes it deterministically. Nothing is matched on substrings — a plain
sentence in a channel is never a command, whichever words are in it. The one exception is
`@Emisar reconfigure this channel`, which is read from text so it still works when the model is
unavailable, and it is read only when Ryker is addressed. The installation participation default
covers channels that never chose, and `/ryker` remains the recovery surface:

```text
/ryker status
/ryker proactive on|off|inherit
/ryker proactive global on|off|inherit
/ryker shadow on|off|inherit
/ryker shadow global on|off|inherit
/ryker assignments [list|pause|resume|delete]
/ryker help
```

That list is the whole of it. `/ryker` used to carry more than twenty subcommands —
directories, record reads, lifecycle controls, a turn ceiling — which made it a second product
surface that drifted from the conversational one beside it. Two months of audit found it used for
one deliberate `proactive on` per deployment and otherwise only for its own failures. What is left
is what has to work when nothing else does: no model runs, no Coop session is needed, and the answer
is private to whoever typed it. Everything else is a conversation, a button on a pinned card, the
App Home, or the web control plane — all of which can reach a task thread, which a command typed
into the channel composer cannot.

`assignments` is the exception, and it is now half an exception. Reading a channel's standing grants
and taking one back are things an operator wants reachable when the conversational path is what is
broken, so `list`, `pause`, `resume` and `delete` stay. Creating one left on 2026-08-15: say what you
want watched — "review every terraform plan here and open PRs for the drift, 2 a day, for 30 days" —
and Ryker answers with a confirmation card showing the normalized bounds it would grant. The
typed `create` still answers, with a pointer to that conversation.

The effective setting is the channel's own saved participation, or the installation default when it
never chose. Global `on`
therefore watches every channel where Ryker is a member and receives events, while a channel
setting can opt in or out. `inherit` clears the channel's own setting so it follows the default. Ryker reads human and
external-app messages in Slack timestamp order and gives each decision a chronological transcript
centered on the target message. The default 20-message window includes the thread root, nearest
preceding replies, the target, and up to three immediately following messages; top-level requests
receive the equivalent channel window. It waits for a two-second quiet period so nearby human
replies are visible, then scores addressee, urgency, confidence, novelty, and ownership. It chooses
whether to stay silent, add a lightweight reaction, reply where the sender is speaking, or
escalate. Ambient replies and reactions have separate configurable attention thresholds, while
direct requests remain eligible regardless of those thresholds. Human messages do not
automatically become incidents: Ryker answers in place and can
attach an `Open incident room` button when coordinated work would help. Only a configured operator
can approve that button. A credible unresolved monitoring-app alert follows the channel's
confirmed policy: reply in place, offer an incident button, or open automatically. An explicit
human request to open, create, start, or declare an incident is honored directly. Both the
context size and settling delay are configurable. An explicit repository-change request can instead
offer a **Start task** transition in the same thread to a writable isolated fork. A configured summon
mention starts the same read-only triage conversation; explicit incident wording remains
deterministic.

When a decision-ready diagnosis establishes a narrow repository fix, Ryker may also show
**Prepare code fix** beside **Open incident room**. The choices are independent: the incident room
coordinates operations, while the engineering task edits and validates code in the source thread.
The fix button creates no PR by itself; after a real diff exists, the task card exposes the separate
**Create draft PR** review control.

The Agent Messages tab supplies suggested health, alert, incident, and handoff prompts. The
message shortcut **Investigate message** starts the same read-only triage for a selected
message even when ordinary proactive listening is off. Long checks keep a native Slack progress
indicator with semantic milestones until the reply or a clear failure is posted.

### What Ryker remembers

Reading and replying are separate decisions. With `learning` configured, Ryker learns from
retained messages even when admission chooses silence or the bot runs in shadow mode. Admission
only routes the message; it does not write a model-generated note. A small background learning
pool groups related inputs and maintains useful subjects such as a rollout decision, an intended
configuration, or an unresolved problem. Ordinary chatter can produce no memory at all.

A subject has one stable identity and a history of updates. The learner receives relevant existing
subjects and either updates an exact offered version, proposes a genuinely different subject, or
explains why it cannot safely decide. Before accepting a new subject, the host checks for an
existing match. A changed title is not a new identity, and sharing a service name does not make
two incident occurrences the same incident. Learning changes understanding, never permission to act.

Memory has distinct jobs:

- **Source excerpts** preserve what a retained message actually said, with its source and time.
  They are available before background learning catches up; they are not another model summary.
- **Topics** keep the current source-linked understanding of a useful subject, including corrections
  and uncertainty. Related updates extend that subject instead of producing one note per message.
- **Conversation handovers** summarize accepted work so a later session can pick it up. Older
  handovers may be grouped into bounded rollups; that compaction itself does not call a model.
- **Confirmed facts, preferences, and guidance** retain explicit operator choices. Background
  learning cannot silently change them or turn them into operational authority.

Future turns receive a small selection of authorized context. The model can use `search_memory`
to search further, page through results, filter by source or content-change date, and follow a
retained Slack source into its surrounding conversation. Results are historical context, not proof
of current health, deployment, or approval. Private-channel context stays in its permitted scope;
public cross-channel context requires current membership checks. A hot Coop session is not the
memory database: episodes own execution sessions, while PostgreSQL owns retained knowledge.

Derived conversation memory expires under `retention.conversation_memory_seconds` (90 days in
the Elixir example configuration). Source edits, deletion, expiry, or lost visibility can make
derived content unavailable sooner. Reading it again does not renew the original source lifetime.
The memory pages show the source, change time, and expiry separately. Learning receipts distinguish
a useful update, a deliberate no-change result, and a failed or deferred batch. If `learning` is
absent from configuration, background learning is disabled; retaining messages alone is not learning.

The exact matching, retry, and recall boundaries are in
[the memory runtime contract](docs/elixir-work-runtime.md#memory-and-background-learning) and the
[implementation specification](docs/memory-implementation-spec.md).

An operator can ask
Ryker to remember an alias, channel-to-repository binding, evidence route, entity relationship
correction, or open-ended guidance such as `when explaining a fix to me, start with a simple
summary`. Ryker shows the normalized value, scope, and expiry in a confirmation card; nothing
is saved until an operator confirms it. Personal guidance can follow that operator across channels,
while channel and workspace guidance can encode explicit team conventions. Saved entries are
bounded, deduplicated by logical key, expire automatically, can be forgotten from App Home, and are
supplied to future model turns only as advisory context. Guidance cannot start work, authorize an
incident or change, approve an action, or count as operational evidence. The current request, host
safety policy, fresh live evidence, current repository content, and Ryker configuration always
take precedence. Recent structured evidence remains
source-attributed; compact related summaries carry continuity across channels without becoming
current-health proof.

Ryker records when confirmed memory and continuity rollups are recalled. A scheduled review
flags confirmed entries that have not been used or reviewed recently and identifies exact duplicate
guidance, but it never silently edits operator-confirmed memory. Memory health plus keep, merge, and
forget controls live in App Home; the control plane provides those controls and explicit edit.
Removed or superseded values are redacted to their digest rather than copied into review audit
state. These mechanisms are
inspired by the freshness, continuity, and reviewability goals in OpenAI's
[Memory and new controls for ChatGPT](https://openai.com/index/chatgpt-memory-dreaming/), while
retaining Ryker's stricter operational evidence and approval boundaries.

Ryker also supports two operator-confirmed behavior catalogs. Preferences are typed defaults
such as `health_check_depth=deep`, `response_detail=concise`, or
`response_location=prefer_thread`; their precedence is operator, channel, repository, then
workspace. Standing rules are typed channel subscriptions such as
`terraform_plan -> review_terraform_plan`, restricted to human, app, or any matching message. A
request such as `when I ask about infrastructure health, always do a deep check` or `when you see a
Terraform plan here, report its main diff and red flags` produces a confirmation card showing the
normalized behavior, scope, expiry, source filter, and fixed read-only safety boundary. Open-ended
guidance may be remembered as advisory model context, but arbitrary prose is never stored as an
executable trigger or authority. A configured operator can make this explicit
setup request in any channel where Ryker is invited, even when that channel is not otherwise a
summon or proactive channel.

App Home and the control plane list active and disabled entries with enable,
disable, edit, and delete controls. An enabled standing rule may admit only its deterministic
message type even when broad proactive triage is off. A match asks the model to evaluate the event;
it does not force a reply. The model may ignore an intermediate or duplicate event, react when that
is sufficient, or reply in the source thread when it has a useful result. Later lifecycle updates
are evaluated independently. Operational-alert replies must reconcile repository topology with
fresh live evidence and return a decision-ready verdict, impact, and next action. Confirmed or
likely issues also include an immediate mitigation and a durable solution; Ryker sends shallow
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
operator confirms it. App Home and the control plane list the current channel's tasks with run-now,
pause/resume, replace, and delete controls.

Schedules are durable wake-ups, not stored authority. Each occurrence enters the normal Slack/Coop
agent pipeline with fresh repository, tool, memory, authorization, and Emisar policy context. The
scheduler records each occurrence before dispatch, never overlaps two copies of the same task, and
uses IANA timezone calendar arithmetic so local times follow daylight-saving changes. `catch_up`
can run only the latest missed occurrence after downtime or skip it after the configured grace
period. One-time tasks complete after their occurrence; run-now remains available for an explicit
manual repeat. Expired tasks and old run records are removed by normal retention maintenance.

Source-event waits are durable subscriptions. They retain a bounded matcher, source kind, opaque
cursor, optional schedule, and terminal resolution in PostgreSQL. Reliable lifecycle notifications
can use an event-only wait with no polling or deadline. Authenticated Slack, GitHub, and generic
webhook inputs resume the exact episode; when loss protection is needed, a deadline and optional
earlier `poll_after` wake it with host-authored verification evidence. Unchanged observations can
retain the wait without posting. The control plane exposes subscription state and digests without
rendering source payloads.
`/ryker shadow` runs the classifier and records its decision, evidence, and coverage without
posting or creating an incident.

Every accepted model-backed request also creates a durable commitment before execution. The
commitment follows the underlying run through queued, working, finishing, done, blocked, or
cancelled state and survives restart. Ask `what are you working on?` or
open App Home to see the exact request, current status, and next operator action. This is distinct
from memory: a commitment is work Emisar owes the team, not a fact to reuse later.

App Home and the control plane list open incidents with native Slack channel mentions and label
retained channel names when a room is archived, deleted, or unavailable, including closed
history. `/ryker help` explains the emergency command kit and provides read-only buttons for current-channel status and incident directories.
Slack exposes only one static usage hint for a slash command, so the manifest keeps that picker text
short and moves detailed guidance into this interactive response. The same command also exposes
`timeline`, `evidence`, `handoff`, `postmortem`, `update`, `changes`, `review`, `publish`, `stop`, and
`close` in an incident room. The remediation timeline is derived from the alert, agent runs,
evidence, Emisar approvals, and draft-PR publication state instead of copying those
facts into a second incident system. Closing posts the same evidence-grounded post-incident draft
that the pinned card's postmortem control can regenerate from the durable record. Ryker automatically
allocates more Coop session capacity as authorized requests arrive. The `coop.turn_limit` deployment setting shows
or changes the channel or workspace lifetime safety ceiling; operators do not estimate how many
turns an investigation needs. Commands are deterministic, operator-authorized, durably processed,
and never interpreted by the model.

New incident channels use the validated `slack.channel_prefix` setting, which defaults to `ems`.
For example, `channel_prefix: sre` produces names beginning with `sre-`. Changing the setting does
not rename existing Slack channels.

Only configured operator user IDs who are full members of the configured workspace can steer an
incident agent, approve an incident offer, save durable behavior, schedule work, or request an
operational mutation. Any active full workspace member can start and collaborate on an engineering
task for the repository assigned to that channel. A configured operator must publish its reviewed
tree as a draft PR, stop or close the task, or discard retained work. Watched-channel messages can produce only a
host-validated ignore, reply, incident offer, or permitted incident decision; they cannot invoke
incident controls or invent a repository or policy. Member engineering-task offers expose only the
channel's configured repository; changing that boundary is an operator-owned channel setting.
Infrastructure access remains constrained by the selected Coop and Emisar policies. Slack guests
and external Slack Connect identities are denied. See
[`docs/slack-ux.md`](docs/slack-ux.md) for the complete interaction contract.

## Operations

These commands operate the current Elixir/PostgreSQL service.

```bash
MIX_ENV=prod mix ryker.doctor
MIX_ENV=prod mix ryker.status
MIX_ENV=prod mix ryker.failures
MIX_ENV=prod mix ryker.retry delivery 'delivery:...' \
  --operator U123 --action-ref retry-delivery-20260904-1
MIX_ENV=prod mix ryker.replay slack 'ingress-input:...' 'post-fix-check-1' \
  --operator U123 --action-ref replay-slack-20260904-1
MIX_ENV=prod mix ryker.replay show 'ingress-input:...' \

curl -f http://127.0.0.1:4321/healthz
curl -f http://127.0.0.1:4321/readyz
curl -f http://127.0.0.1:4321/metrics
```

These Mix tasks are short-lived database clients; run them with the same `DATABASE_URL` and runtime
configuration as the release. They do not start admission, Work, Delivery, Slack, or webhook
workers. `ryker.doctor` validates configuration, PostgreSQL, migration state, and durable queue
readiness. Process-local runtime and scheduler-progress truth remains available from the running
release at `/readyz`.

`ryker.status` emits lifecycle, queue, fleet, preflight, and failure counts as JSON.
`ryker.failures` lists stable error codes, diagnostic hashes, and retryability for blocked
admission, Work, delivery, Slack interaction repaint, Slack incident room, Emisar monitoring, and
cleanup custody.
`ryker.retry` dispatches only those seven typed recovery paths; semantic publication review is
not a generic infrastructure failure. Every mutation requires a configured Slack operator ID and
an operator-chosen action reference; the action, prior safe state, and outcome are committed in the
same PostgreSQL transaction so repeating that reference reconciles a lost response.

Work recovery also requires `--expected-recovery SHA256`, using the inspected
failure's `work_recovery.fingerprint`. The confirmation is bound to that exact
stopped turn: confirmed completion resumes saving the retained result without
rerunning the model, while a safely stopped execution may start a new logical turn.
A closed writable session without a confirmed checkpoint requires workspace
restoration, not a normal retry. Recovery pages show the redacted, attributed
accepted worker response separately from the host failure and next action.

`ryker.replay slack` accepts an exact retained `ingress-input:` reference plus an
operator-chosen idempotency reference. It preserves the normalized Slack content, attachments,
actor, destination, timestamp, capabilities, and frozen Work profile under a fresh event identity,
then records it in `shadow` mode. The normal admission, model, tools, and Work path runs, while the
shared host boundary forbids Slack status, reactions, messages, offers, schedules, tasks, incidents,
and every other visible platform effect. Repeating the same action reference is idempotent; use
`ryker.replay show` to inspect lifecycle state and the bounded accepted `decision_reason`
describing what the model would have done. Pruned or non-Slack sources fail closed.

PostgreSQL owns Slack inputs, webhook events, outgoing deliveries, Work, incident mappings,
channel lifecycle, structured evidence, memory, Emisar approval holds, timelines, evaluation
decisions, audit records, and scheduler custody. Normal release restart recovers pending work from
those rows; deployment backup and restore checks are described below.
Bounded retention removes expired operational payloads and closed work, and expires finished episode
history on a separate, much longer horizon because that record is what the replay-fixture corpus is
built from. No horizon deletes an episode a pending correction, open feedback, a live wakeup, an
unfinished run, or an open incident still depends on. Coop cleanup is restricted
to exact session IDs recorded by Ryker: clean closed sessions and sessions whose reviewed tree
is durable in a draft PR are discarded after a grace period, while dirty or unpublished work is
retained. Deleting a Slack room does not itself discard work. See
[`docs/operations.md`](docs/operations.md) for retry and recovery behavior.

## V1 scope

V1 supports one Slack workspace and one repository context per incident. A context may be one
repository or an explicit repository set: one primary writable/publishable repository and up to 32
operator-configured read-only companion repositories pinned at session creation. Multiple routes
can select different contexts and Coop policies. Ryker never accepts host paths from Slack or
model output; the local Coop policy is their only authority. It can publish an explicitly
authorized reviewed primary tree as a draft GitHub pull request, but cannot publish companion
changes, merge, deploy from repository changes, or archive Slack channels.
Automatic and inferred operational changes remain disabled. In any Slack conversation, a
configured operator may directly request one exact operational action. Emisar remains authoritative
for target validation, policy, approval, execution, and audit; Slack only links to the exact pending
approval returned by Emisar. Ryker monitors and reports that exact run but cannot approve it,
substitute another run, or repeat the mutation during terminal verification.

Run the owning Elixir test while editing:

```bash
scripts/elixir-test.sh test/ryker/work/executor_test.exs
```

Run the deterministic repository gate before committing, then deploy:

```bash
make dev-check
scripts/deploy.sh
```

`make check` is the full gate, which CI runs on every push; run it locally before a tagged
release. Use `make customer-check` for the Elixir product journeys and deterministic host replay.
Use `make model-release-check` (with the `RYKER_EVAL_*` environment set) only when the
model contract changes. Build and qualify the immutable Elixir release with:

```bash
make release-check
```

See [`docs/testing.md`](docs/testing.md) for test boundaries and
[`docs/releasing.md`](docs/releasing.md) for the tag and publication contract.

## License

Ryker is source-available under the [Business Source License 1.1](LICENSE). Non-production
use is free; production use requires a commercial license. Each version converts to the Apache
License 2.0 on its Change Date, currently 2030-09-14. Third-party fonts, artwork, dependencies,
and other materials distributed with separate license notices remain under those licenses.

For commercial licensing, contact `licensing@emisar.dev`.
