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
  questions in place and opening incident rooms only from operator-confirmed offers or, where a
  channel is set to, credible app alerts;
- correlates related signals and deduplicates webhook delivery;
- records source-attributed evidence, health-layer coverage, and an incident timeline separately
  from agent prose;
- creates one Slack channel and one pinned investigation card per incident occurrence;
- creates one Coop session and isolated fork under a predeclared repository policy;
- lets active full workspace members start and collaborate on contributor tasks in their channel's
  environment;
- keeps operator-capability tasks, incident steering, the publication and destructive controls, and
  saved behavior restricted to configured operators, and leaves every change to running systems to
  Emisar's own policy and approvals;
- parks between turns, resumes the same agent conversation, and survives process restarts;
- tracks every accepted investigation or engineering promise as durable work, and exposes it in
  the App Home and the web control plane;
- exposes an App Home, Agent Messages tab, message shortcut, semantic progress, lightweight
  acknowledgements, and
  deterministic controls for status, evidence, handoff, changes, review, draft PR publication,
  retained-work disposal, stop, and close;
- can return bounded generated images and evidence-backed charts in the same Slack conversation,
  when the configured agent has an appropriate image or chart tool;
- investigates live infrastructure through Emisar and, when someone in the conversation asks for
  an exact change, submits it to Emisar, whose policy decides whether it runs and who approves it.

Ryker does not merge, deploy, sign commits, or grant infrastructure authority. Coop owns the
fork and agent boundary. A contributor can prepare and review code in an isolated fork. Publishing
is off until **Let Ryker open pull requests** is turned on under Integrations › GitHub; then Ryker
reproduces the exact approved tree, pushes a lease-protected Ryker branch, and creates or updates a
draft GitHub pull request, either because a configured operator pressed **Create draft PR** or
because the confirmed task named that repository (its draft grant). Emisar owns infrastructure
policy, approval, execution, and audit.

The adapter and delivery boundary is documented in
[Elixir platform adapters and delivery](docs/elixir-platform-adapters.md).

For memory-system design work, consult the
[memory research knowledge base](docs/research/memory-systems.md): external evidence, failure
patterns, pragmatic design decisions, and acceptance criteria. It is research, not a runtime contract.

## Quick start

Ryker’s supported installation is Docker Compose. Install Docker with Compose v2, check out this
repository (a release tag, for a release), then run:

```bash
./install.sh
```

The installer creates owner-only state in `.ryker/`, generates the database password and Ryker’s
cryptographic roots once, builds the Ryker and bundled Coop worker images from the checkout, starts
them with PostgreSQL and the worker's private Docker daemon, signs the worker in to its model account
(it reuses an existing Codex sign-in on the host, or asks), verifies health, readiness and the exact
running version, then prints the local setup URL. Running it again keeps the same
keys and volumes.

Slack, GitHub, Emisar and webhook credentials are entered in the setup UI and encrypted in
PostgreSQL. They never belong in Compose or `.ryker/compose.env`. The control UI and ingress ports
bind to loopback by default; publish only the signed webhook endpoints through HTTPS when external
services need to reach them.

Use the one lifecycle helper for routine operations:

```bash
scripts/compose.sh status
scripts/compose.sh logs
scripts/compose.sh restart
scripts/compose.sh upgrade
scripts/compose.sh backup
scripts/compose.sh restore .ryker/backups/ryker-YYYYMMDDTHHMMSSZ.tar.gz
scripts/compose.sh uninstall       # keeps data and keys
```

`destroy` is a separate confirmed operation because it deletes the database volume, stored work
and encryption keys. See [`docs/operations.md`](docs/operations.md) for backup, restore, exposure
and recovery details.

Then open `http://127.0.0.1:4321/conversations` for direct conversations with the
agent, without Slack, through the real durable product pipeline. The manual
qualification journeys for Slack, GitHub, webhooks, state tools and recovery are
in [`docs/testing.md`](docs/testing.md#manual-qualification).

The Ryker container runs PostgreSQL migrations before opening listeners. See
[`docs/elixir-platform-adapters.md`](docs/elixir-platform-adapters.md) for Slack/GitHub/webhook
bindings, [`docs/operations.md`](docs/operations.md) for backup, restore and recovery, and
[`docs/testing.md`](docs/testing.md#live-acceptance) for live acceptance.

## Webhooks

The service listens on loopback. Publish only `/v1/github` (GitHub App events) and `/v1/hooks/`
through a TLS reverse proxy (`deploy/nginx/ryker.conf` is an example); keep health and metrics local.

Grafana route:

```bash
curl -f \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer example-secret' \
  --data-binary @grafana-alert.json \
  http://127.0.0.1:4320/v1/hooks/grafana
```

Grafana's alert fingerprint and start time identify each alert, so its firing and resolved updates
are revisions of one item; `groupKey`, then the configured labels, is recorded as its grouping. A
webhook alert goes to the conversation its source names and never opens an incident room by itself:
rooms are opened from Slack.

Generic routes use deliberately small dot-path mappings. See
[`docs/webhooks.md`](docs/webhooks.md). There is no embedded scripting language.

## Slack

Mention the bot in any channel where it has been invited to ask a question or request read-only
work:

```text
@Ryker investigate elevated checkout latency in production
```

Ryker investigates and replies in that thread without creating an incident. Asking it to `open an
incident for elevated checkout latency`, or a problem that needs coordination, gets an incident
offer: **Create incident room** (only a configured operator can press it) creates the room, and
**Investigate** keeps the work in the thread without one. In an incident channel, configured operators
can talk to Ryker anywhere without repeating an `@mention`. Outside incident rooms, a delivered
triage answer opens a bounded 30-minute conversation window for nearby follow-ups in the same
channel or thread location. It reads top-level messages and threads, replies in the originating
conversation when addressed or when it has something useful to add, and may stay silent for ambient
chatter. The pinned card updates in place with alert evidence,
investigation state, and only currently valid controls. Incident channels are private by default,
and all configured operators are invited automatically.

Changes to running systems go only through Emisar, and Emisar decides them. Anyone in a
conversation Ryker serves can ask for an exact change; Ryker adds no operator check of its own, and
every work session in an environment with an Emisar account can use Emisar's tools. Emisar owns
target validation, policy, approval, execution, and audit, and no incident room is required. The
model is told not to treat an alert, ambient conversation or an inferred intent as a request to
act; that is an instruction, not a check. A pending decision appears in the same conversation as an
**Emisar review** card with a **Review in Emisar** link. Ryker watches that exact run in the
background, updates the card as it progresses, and continues the same conversation when it
finishes, verifying the effect with read-only evidence where it can. Waiting consumes no model turn
and survives a Ryker restart. When an active full
workspace member explicitly asks Ryker to change repository files, the reply can include a
concise **Start task** button instead of sending the teammate to another client. Confirmation by
any active full workspace member keeps the task in that Slack thread and creates an isolated
writable Coop fork, where Ryker can inspect, edit, test, and commit under the configured
repository policy. Later replies in the same thread continue the same session without an
`@mention`; unrelated channel messages remain in read-only triage. It does not create an incident,
and it does not merge, deploy or sign; any change to running systems still goes through Emisar. Any
active full workspace member can collaborate in the task thread and inspect or review its changes.
Publishing needs **Let Ryker open pull requests**; then the confirmed task opens its own draft PR
once its review is clean, or a configured operator presses **Create draft PR**.

Inviting `@Ryker` to a new channel saves safe defaults at once: the installation's participation
default (mentions only unless changed), the default environment, alerts investigated in their own
thread, and no additional incident invitees. The welcome offers **Be proactive** or **Mentions
only**, and **Customize** starts a four-question setup conversation for participation,
environment, app-alert escalation, and incident audience. An environment names the repositories
work may read (a task changes one of them and reads the rest) and the Emisar account it may use. The
final card shows the normalized typed values and safety boundary; nothing changes until the
configured operator who started the setup saves it. Typed choices use Slack buttons. Configured operators are always
invited to incident rooms;
the audience step either adds no one else or accepts member and user-group mentions for additional
invitees. Setup is one message in its thread that updates in place, and it expires after 30
minutes.

The conversational surface is primary: ask `@Ryker` in your own words and the model classifies what
you meant, then the host executes it deterministically. Nothing is matched on substrings — a plain
sentence in a channel is never a command, whichever words are in it. The one exception is
`@Ryker reconfigure this channel`, which is read from text so it still works when the model is
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

`assignments` is the exception, and it is now half an exception. A standing assignment is a
confirmed standing rule (the control plane's Rules page lists the same records). Reading a channel's
rules and taking one back are things an operator wants reachable when the conversational path is
what is broken, so `list`, `pause`, `resume` and `delete` stay. Creating one left on 2026-08-15: say
what you want watched — "review every Terraform plan posted here" — and Ryker answers with a card
showing the rule it would save. The typed `create` still answers, with a pointer to that
conversation.

The effective setting is the channel's own saved participation, or the installation default when it
never chose. Global `on`
therefore watches every channel where Ryker is a member and receives events, while a channel
setting can opt in or out. `inherit` clears the channel's own setting so it follows the default. Ryker reads human and
external-app messages in Slack timestamp order and gives each decision a chronological transcript
that ends at the target message: up to 20 earlier messages (a code default, not a setting) — for a
thread reply, the thread's root and the replies before it; for a top-level message, the channel
messages before it. There is no settling delay and there are no attention scores or thresholds:
the model chooses whether to stay silent, add a lightweight reaction, answer a simple message
itself at once (a greeting, a thanks, a question the conversation already answers), reply where
the sender is speaking, or start or continue work, and Ryker validates that choice. Human messages do not
automatically become incidents: Ryker answers in place and can attach an incident offer
(**Investigate** or **Create incident room**) when coordinated work would help. Only a configured
operator can press it. A credible unresolved monitoring-app alert follows the channel's confirmed
policy: investigate in the alert's thread, offer a room, or always open one. An explicit human
request to open, create, start, or declare an incident gets the offer; no phrase is matched. An
explicit repository-change request can instead offer a **Start task** transition in the same thread
to a writable isolated fork. A mention starts the same read-only triage conversation.

The Agent Messages tab supplies the manifest's suggested prompts: production health, explaining an
alert, and open work. The message shortcut **Investigate message** starts the same read-only triage
for a selected message even when ordinary proactive listening is off. While a request is in
progress, Slack's native status line names its stage (queued, deciding how to respond, working,
preparing the response), refreshed every 90 seconds and cleared once the request settles.

### What Ryker remembers

Reading and replying are separate decisions. With background learning on (the default; its switch
is on the control plane's Memory › Learning page), Ryker learns from
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
- **Conversation summaries** (handovers) summarize accepted work so a later session can pick it up.
  Older summaries are grouped into bounded weekly rollups; that compaction itself does not call a
  model.
- **Confirmed facts, preferences, and guidance** retain explicit operator choices. Background
  learning cannot silently change them or turn them into operational authority.

Future turns receive a small selection of authorized context. The model can use `search_memory`
to search further, page through results, filter by source or content-change date, and follow a
retained Slack source into its surrounding conversation. Results are historical context, not proof
of current health, deployment, or approval. Private-channel context stays in its permitted scope;
public cross-channel context requires current membership checks. A hot Coop session is not the
memory database: episodes own execution sessions, while PostgreSQL owns retained knowledge.

Derived conversation memory expires after the Conversation memory limit under Settings › Data
retention (90 days by default). Source edits, deletion, expiry, or lost visibility can make
derived content unavailable sooner. Reading it again does not renew the original source lifetime.
The memory pages show the source, change time, and expiry separately. Learning receipts distinguish
a useful update, a deliberate no-change result, and a failed or deferred batch. Turning learning off
stops background learning; retaining messages alone is not learning.

The exact matching, retry, and recall boundaries are in
[the memory runtime contract](docs/elixir-work-runtime.md#memory-and-background-learning) and the
[implementation specification](docs/memory-implementation-spec.md).

An operator can ask
Ryker to remember a fact (what a service is called, which repository holds it) or open-ended
guidance such as `when explaining a fix to me, start with a simple
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
guidance, but it never silently edits operator-confirmed memory. Memory health plus keep, edit,
merge and forget controls live in App Home and on the control plane's Memory › Facts page.
Removed or superseded values are redacted to their digest rather than copied into review audit
state. These mechanisms are
inspired by the freshness, continuity, and reviewability goals in OpenAI's
[Memory and new controls for ChatGPT](https://openai.com/index/chatgpt-memory-dreaming/), while
retaining Ryker's stricter operational evidence and approval boundaries.

Ryker also supports two operator-confirmed behavior catalogs. Preferences are typed defaults
such as `health_check_depth=deep`, `response_detail=concise`, or
`response_location=prefer_thread`; their precedence is operator, channel, repository, then
workspace. Standing rules are source-event automations: a source (Slack, GitHub or a webhook), an
exact filter on its events, the task, the channels Ryker reads and replies in, an optional
repository and an optional end. A request such as `when I ask about infrastructure health, always
do a deep check` or `when someone posts a Terraform plan here, review it for risky changes`
produces a confirmation card showing the normalized preference or rule and its fixed read-only
boundary. Open-ended
guidance may be remembered as advisory model context, but arbitrary prose is never stored as an
executable trigger or authority. A configured operator can make this explicit
setup request in any channel where Ryker is invited, even when that channel is not otherwise a
summon or proactive channel.

App Home and the control plane's Rules and Instructions pages list current and past entries with
pause, resume and delete controls. An enabled standing rule may admit only its deterministic
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
an SRE review`. Ryker replies with a confirmation card showing the task, when it runs (with its
timezone), what its runs may do and in which repository, and when it ends. Nothing runs until an
operator confirms it. App Home and the control plane's Schedules page list schedules with run-now,
pause/resume and delete controls; to change one, ask Ryker where it was set up.

Schedules are durable wake-ups, not stored authority. Each occurrence enters the normal Slack/Coop
agent pipeline with fresh repository, tool, memory, authorization, and Emisar policy context. The
scheduler records each occurrence before dispatch, never overlaps two copies of the same task, and
uses IANA timezone calendar arithmetic so local times follow daylight-saving changes. An occurrence
that cannot start within 15 minutes of its time is recorded as missed, and the next one still runs
on time. One-time tasks complete after their occurrence; run-now remains available for an explicit
manual repeat. Expired tasks and old run records are removed by normal retention maintenance.

Source-event waits are durable subscriptions. They retain a bounded matcher, source kind, opaque
cursor, optional schedule, and terminal resolution in PostgreSQL. Reliable lifecycle notifications
can use an event-only wait with no polling or deadline. Authenticated Slack, GitHub, and generic
webhook inputs resume the exact episode; when loss protection is needed, a deadline and optional
earlier `poll_after` wake it with host-authored verification evidence. Unchanged observations can
retain the wait without posting. The control plane's Follow-ups page lists each wait, what it waits
for and the request it continues, without rendering source payloads.
`/ryker shadow` runs the classifier and records its decision, evidence, and coverage without
posting or creating an incident.

Every accepted model-backed request is durable work before execution: it is recorded in
PostgreSQL, follows its run through working, waiting, complete or cancelled, and survives restart.
App Home's **In flight** section and the control plane's Activity page show the exact request, its
current status and what it waits for. This is distinct from memory: open work is what Ryker owes
the team, not a fact to reuse later.

App Home and the control plane list open incidents with native Slack channel mentions and label
retained channel names when a room is archived, deleted, or unavailable, including closed
history. `/ryker help` explains the emergency command kit as plain text.
Slack exposes only one static usage hint for a slash command, so the manifest keeps that picker text
short and moves detailed guidance into this response. Records and controls for incidents and tasks
live on their cards, not in the command: the remediation timeline is derived from the alert, agent
runs, evidence, Emisar approvals, and draft-PR publication state instead of copying those facts
into a second incident system, and the pinned card's **Postmortem draft** builds the
evidence-grounded post-incident draft from the durable record at any time, including after close.
When a session is exhausted, Ryker continues in a fresh one; the worker's own policy bounds a
session (the bundled worker allows 100 turns), and operators do not estimate how many turns an
investigation needs. Commands are deterministic, operator-authorized, durably processed,
and never interpreted by the model.

New incident channels use the validated channel prefix set under Integrations › Slack (the
`channel_prefix` setting), which defaults to `inc`. For example, the prefix `sre` produces names
beginning with `sre-`. Changing the setting does
not rename existing Slack channels.

Only configured operator user IDs who are full members of the configured workspace can steer an
incident agent, approve an incident offer, save durable behavior, or schedule work in Slack. Any
active full workspace member can start and collaborate on an engineering task in the channel's
environment. Only a configured operator can press **Create draft PR**, stop or close the task, or
discard retained work; the confirmed task's own draft grant can publish without a click. Changes to
running systems are Emisar's decision, not a Ryker permission. Watched-channel messages can produce only a
host-validated ignore, reply, incident offer, or permitted incident decision; they cannot invoke
incident controls or invent a repository, environment or policy. A member's engineering-task offer
stays inside the channel's environment: the task changes one of its repositories, chosen for that
task, and reads the others. Which environment a channel works in is an operator-owned channel
setting. Infrastructure access remains constrained by the environment's Emisar account and the
selected Coop policies. Slack guests and external Slack Connect identities are denied. See
[`docs/slack-ux.md`](docs/slack-ux.md) for the complete interaction contract.

## Operations

On the Docker Compose install, the release runs the two operator commands a person needs there:

```bash
scripts/compose.sh doctor
scripts/compose.sh worker-token WORKER_ID WORKSPACE_REF OPERATOR_REF
```

`doctor` checks that the saved settings were applied and the durable queues are ready.
`worker-token` prints a one-time enrolment token for a Coop worker the installation does not run
itself. Routine recovery on a Compose install is the control plane's Failures page.

The Mix tasks below run from a source checkout with Mix. The Docker Compose install publishes
neither PostgreSQL nor Mix, so they need a database you can reach with the installation's
`DATABASE_URL` and keys.

```bash
MIX_ENV=prod mix ryker.doctor
MIX_ENV=prod mix ryker.status
MIX_ENV=prod mix ryker.failures
MIX_ENV=prod mix ryker.retry delivery 'delivery:...' \
  --operator U123 --action-ref retry-delivery-20260904-1
MIX_ENV=prod mix ryker.replay slack 'ingress-input:...' 'post-fix-check-1' \
  --operator U123 --action-ref replay-slack-20260904-1
MIX_ENV=prod mix ryker.replay show 'ingress-input:...'

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
admission, Work, delivery, Slack interaction repaint, Slack incident room, Slack task card, Slack
thread status, Emisar monitoring, and cleanup custody.
`ryker.retry` dispatches only those nine typed recovery paths; semantic publication review is
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
those rows; backup and restore are in [`docs/operations.md`](docs/operations.md).
Bounded retention removes expired operational payloads and closed work, and expires finished request
history on its own horizon; each limit is 30 days by default (Settings › Data retention), and
operational data can never outlive request history. Only finished requests are pruned, and nothing
is pruned while an open wait, an unsettled run, a pending Emisar approval, a schedule, an
unpublished change, an incident room or open state still depends on it. Coop cleanup is restricted
to exact session IDs recorded by Ryker: clean closed sessions and sessions whose reviewed tree
is durable in a draft PR are discarded after a grace period, while dirty or unpublished work is
retained. Deleting a Slack room does not itself discard work. See
[`docs/operations.md`](docs/operations.md) for retry and recovery behavior.

## V1 scope

V1 supports one Slack workspace. Work happens in an **environment**: a set of repositories that
every piece of work in it can read, and at most one Emisar account. Channels, webhook sources and
Chat conversations each pick an environment; a task picks which repository of its environment it
changes, and the others (at most 32) are mounted read-only beside it. Ryker never accepts host
paths from Slack or model output; the local Coop policy is their only authority. It can publish an
explicitly authorized reviewed tree as a draft GitHub pull request, but cannot publish changes to
the read-only repositories, merge, deploy from repository changes, or archive Slack channels.
Anyone in a conversation Ryker serves may ask for one exact operational action; Ryker adds no
operator check of its own and sends it to Emisar, which remains authoritative for target validation,
policy, approval, execution, and audit. Slack only links to the exact pending approval returned by
Emisar. Ryker monitors and reports that exact run and cannot approve it; the model is told not to
act on alerts or inferred intent, and not to repeat the action or substitute another run while it
verifies one.

Run the owning Elixir test while editing:

```bash
scripts/elixir-test.sh test/ryker/work/executor_test.exs
```

Run the deterministic repository gate before committing, then deploy:

```bash
make dev-check
scripts/deploy.sh
```

`scripts/deploy.sh` deploys HEAD to the Docker Compose installation in this checkout: it refuses
a dirty tree or a HEAD that is not `main`'s, backs the database up into `.ryker/backups/`, builds
the image from a clean worktree of HEAD, replaces only the `ryker` container, waits for health,
readiness and the exact version header, and only then pins the version in `.ryker/compose.env`.

`make check` is the full gate, which CI runs on every push; run it locally before a tagged
release. Use `make customer-check` for the Elixir product journeys and deterministic host replay.
Use `make eval-world` (with the `RYKER_EVAL_*` environment set) only when the model contract
changes. Build and inspect the immutable Elixir release archive with:

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
