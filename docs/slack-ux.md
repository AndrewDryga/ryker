# Slack experience

## Message contract

Every operational message must stand on its own for an operator who has not read the configuration
or implementation. It should answer, in this order:

1. **What happened or what is true now.**
2. **What that means for Ryker's observable behavior.**
3. **Where the behavior applies and what takes precedence.**
4. **Whether work, code, infrastructure, or incident state changed.**
5. **What the operator can do next, naming the exact card control or Slack command.**

User-facing copy translates internal workflow values such as `parked`, configuration inheritance,
and Coop session mechanics into plain operational language. Internal names may appear only when
they help diagnose a problem, and then they must be accompanied by a short explanation. A status
response must explicitly distinguish normal-channel proactive triage from incident-room
collaboration: attached incident rooms remain conversational even when proactive triage is off.

## Incident room

Each incident occurrence receives:

1. a deterministic channel named `<prefix>-MMDD-title-incidentid`, using the validated
   `slack.channel_prefix` setting (`inc` by default);
2. a concise topic with the incident identity;
3. invited configured responders;
4. one pinned root card;
5. one Coop session and isolated fork.

The root card is the authoritative incident snapshot. It shows:

- plain-language alert and Ryker states;
- severity, firing/total signals, repository, lifecycle times, and isolated fork;
- the latest alert summary and a validated alert-source link with its hostname visible when supplied;
- what the investigation is establishing: each goal it set, where that goal stands in the shared
  goal vocabulary (`✓` completed, `▸` working, `◷` waiting, `!` blocked, `−` excluded or cancelled,
  `○` ready) and what that state found, in the order they were set,
  newest attempts only and the first eight of them. It is the same composed ledger the engineering
  task card reads, not a second copy of it, and a room that set no goals shows no ledger;
- a prominent action-needed section when work is blocked;
- only controls that are valid for the current lifecycle state, with **Open evidence** as a button
  rather than a menu row, because what an investigation found is the subject of its card.

The top-level fallback text carries the same essential status for notifications and screen readers.
Ryker updates this message in place and alternates card writes with thread delivery so a busy
conversation cannot leave the pinned snapshot stale.
Ryker also persists the rendered card UI revision. Its card workers keep re-checking active cards
(task cards every two seconds, incident cards every five minutes) and repaint any card whose
revision or content changed, so upgraded controls appear without waiting for unrelated incident
activity; failed Slack updates remain queued for retry.

Configured operators can converse anywhere in an incident channel without an `@mention`.
Ryker admits ordinary top-level messages and thread replies, keeps them in the same Coop
conversation, and follows the operator's current location: a channel message gets a channel
response and a thread reply gets a reply in that thread. Mentions and replies to the pinned card are explicitly direct; for ambient room conversation, the
agent may stay silent when a human teammate would have nothing useful to add. Thread-scoped
engineering tasks are the deliberate exception: their authorization and working copy remain bound
to the source thread. Active full members may collaborate in a contributor task; operator-capability
tasks remain operator-only. Each accepted teammate or operator message is one ordered Coop request. Ryker
allocates session capacity automatically; tool calls and investigation steps inside the request
are not counted separately.

The pinned-card thread remains the home for proactive investigation updates, alert-driven turns,
fork summaries, review evidence, and failures. Agent tool output, hidden reasoning, token streaming,
raw webhook refreshes, and raw patches are not relayed. Long output is bounded and visibly
truncated.

Agent-authored prose uses Slack's Block Kit `markdown` block, which lets Slack render standard
Markdown from the model without lossy `mrkdwn` translation. A reply longer than the block's
12,000 characters is sent as plain-text sections instead. Responses may use proportional
headings, emphasis, links, quotes, lists, task lists, dividers, tables, inline code, and
language-tagged code blocks. Ryker, not the model, owns buttons, menus, mentions, approvals,
and other interactive or notification-bearing elements.

Investigation replies include a Sources footer only when the host can resolve the
cited source to a destination a tool in the same episode actually produced. Emisar
names the run it started; every other server must have returned that exact URL in
the retained output of a completed call. A URL the model wrote itself, one it only
passed into its own tool arguments, one our own state server read back out of the
saved records, a receipt from another episode, a call that failed, and a receipt
whose retention has expired all resolve to nothing. Linkless entries and oversized
links are omitted; repeated destinations appear once. The answer and valid inline
links remain unchanged, and the full authorized evidence stays in the episode even
when it cannot supply a Slack link.

When enabled, Slack's native assistant status appears as soon as Ryker has an input to decide on and
says in a few plain words what Ryker is doing. While it routes the message the line reads "is
queued…", "is deciding how to respond…" or "is waiting to try again…". Once work starts it reads "is
getting started…" until the worker reports something, "is thinking…" before the first tool, and then
a phrase for the tool the running turn last started, such as "is searching what it knows…", "is
searching Slack…", "is reading the code…", "is running a command…", "is asking Emisar to run an
action…" or "is writing the reply…"; "is posting the reply…" covers delivery. Every kind of tool has
one fixed phrase, and a tool Ryker has no phrase for reads "is working…", so no tool argument,
command, path, title or model text reaches the channel. A finished tool keeps its phrase until the
next one starts, and a turn that reports nothing for five minutes goes back to "is working…" rather
than naming a step it may no longer be doing. A new phrase is written at most once every three
seconds per thread, and an unchanged one is not written again until the refresh. Ryker refreshes it
every 90 seconds, inside Slack's two-minute expiry, and clears it once the work is complete,
cancelled, blocked or waiting. Parked and blocked state remains on the card rather than using a
misleading persistent typing indicator.

## Agent surfaces

App Home shows durable open-incident, active-session, failed-work, incident-history, saved-memory,
and active-commitment counts plus the current incident rooms, work Ryker owes the team, compact
channel situations, and bounded memory controls. Its destination-backed rows show the original
request and jump to the exact Slack channel or thread; memory and behavior rows link to their source
while the exact user still shares it. Operators can edit stale memory, run or manage schedules,
recover publication conflicts, and explicitly discard a clean retained unmerged workspace there;
dirty work remains protected. Schedule replacement returns to the source conversation so the new
request goes through normal confirmation. Its item sections are a capped digest, so **All
schedules**, **All standing rules** and **All saved knowledge** open the complete authorized list
of that collection in the same Home tab, ten rows to a page, with **Previous**, **Next** and **Back
to Home**. Each page is read again from the same scoped query the channel's own page is cut from,
under the channels the operator shares with Ryker at that moment, so a channel they have left
is gone from the next page. A page that could not be read says so and is never an empty list. The Agent Messages tab offers the suggested
prompts declared in the app manifest — production health, alert explanation, and open work. A
direct message is always read, with no proactive mode or `@mention` needed, and goes through the
same admission as any other message.

The **Investigate message** shortcut runs the same ordered read-only triage against a
selected message and replies in its thread. Direct messages and shortcuts do not create incidents
merely because they identify a problem; they can offer the same explicit incident button.

An explicit repository-change request can produce a **Start task** button. Until an
active full workspace member confirms it, no writable session or fork is created. Confirmation posts
a durable task card in the same Slack thread and creates an isolated Coop working copy. Active full
members may collaborate there, edit, validate, and commit repository files under the contributor
job settings, then inspect and review the changes. Ryker supplies the contributor's execution
authority and withholds the project environment and MCP servers from background
learning, so a member's task gets the tools configured for work in its environment, including the
environment's Emisar account. Publishing is off until **Let Ryker open pull requests** is turned
on; once it is, a confirmed task opens its own draft pull request when its review is clean (see
Controls). Only a configured operator can press **Create draft PR**, stop, close, or discard task
work. Nobody can merge, deploy or sign through the contributor task, and any change to running
systems still goes through Emisar's own policy and approvals. Ordinary replies in the
source thread continue the same task session without an `@mention`; unrelated channel messages never
enter it. Slash commands cannot identify a thread, so task controls live on the task card.

## Explicit summons

In any channel where Ryker is a member:

```text
@Ryker investigate production checkout errors
```

The user must be a full workspace member. Ryker performs bounded read-only triage and follows
the user's current channel or thread location; no proactive channel configuration is required, and
the mention alone does not create an incident. Asking in words,
`@Ryker open an incident for production checkout errors`, gets Ryker's incident offer: the model
decides to offer it, and no phrase is matched. A room is created only when a configured operator
presses **Create incident room** (or when the channel's alert setting opens one for a credible app
alert). Ryker then creates the dedicated room and, once configured responders are invited and the
topic and root pin are ready, posts "Incident room ready: #room. The investigation and its pinned
status card are now in that room." in the source thread. The room works
in the environment of the conversation it was opened from — the repositories that conversation
mounted and its Emisar account — whatever the channel has chosen since; new conversations in the
room run there too. At most 25 rooms can be open in a workspace. When that limit is full, no room
is created: the person who pressed the button gets only the generic private notice that the
control is no longer current, and an automatic room is not opened (the worker logs it).

After Ryker answers, that channel location remains an active conversation for 30 minutes. Nearby
human follow-ups are admitted without another mention, including a reply that starts a thread from
Ryker's top-level answer. The window counts from when the answered work completed, which is when
its reply was delivered; silence does not extend it, and work still running or waiting is always
continued. Membership, chronological context, and per-conversation serialization still apply, so
nearby human conversation can be understood without forcing Ryker to interrupt it.

## Watched channels

### Channel welcome and optional setup

Ryker admits the bot's own Slack channel-join event immediately and records the event, the
membership transition and a complete default configuration in one transaction: participation left
to the installation default (mentions only unless changed under Integrations › Slack), the default
environment (or no environment when none is the default), in-place alert investigation and no
additional incident invitees. Useful defaults need no click, and none of
them requires an environment to exist: joins, the reconciliation below and `/ryker status` work in
an installation that has none. A periodic reconciliation against the bot's
joined conversations is the recovery path for a missed event; it configures and welcomes only the
memberships it repaired itself, never already-joined channels, so a sweep cannot flood configured
channels with hellos. Membership state survives restarts, suppresses duplicate welcomes, and makes
remove/re-add post one fresh welcome for the new membership generation.

The welcome is one message per channel, generated entirely from the effective saved settings by the
same projection that answers `/ryker status` and settings questions: the channel's environment and
what work there may use (the repository it changes, linked when it names a GitHub repository, the
repositories it only reads, and Emisar when the environment has an account), conversation
participation, the actual alert behavior, observation mode and incident invitations. A channel with
no environment says it answers without any repos or Emisar and how to choose one; an environment
that cannot run work right now is named with that said, rather than read as none. It never says "alerts are handled separately".
Its controls follow the saved state: **Be proactive** and **Customize** on a mentions-only
channel, **Mentions only** and **Customize** on a proactive one, and **Configure channel** alone in
observation mode or an incident room. Under a `/ryker` override the welcome keeps those buttons and
adds a sentence naming the override and how `inherit` returns to the saved setting. Each control carries the configuration id and the
revision it was rendered from; the host rechecks operator authority, channel membership and that
exact revision before saving, and a participation change preserves the environment, alert policy
and invitations chosen earlier. Every save re-renders this same welcome in place with a short
notice such as **Settings updated.**; there is never a second introduction.

**Customize**, **Configure channel** and the addressed `reconfigure this channel` /
`configure this channel` request open the optional Q&A: one wizard message in the welcome thread
(or the thread the request was made in) that replaces itself after every step and explains each
option before asking for a choice, pairing the exact button label with what Ryker will do:

1. conversations: **Mentions only**, **Be proactive** or **Observe only**;
2. environment: every environment by name, each explained by what work in the channel would use
   there (the repository it changes, the ones it reads, Emisar), plus **No environment**, which
   answers without any repos or Emisar; choosing one decides which environment the channel uses
   and never changes what is in it. The step is asked even when no environment exists yet, with
   **No environment** as its only choice;
3. alerts: **Investigate here** (in the alert's thread), **Offer a room** (a choice between the
   thread and an incident room), or **Always open a room**;
4. invitations: **Nobody automatically**, or a reply with the members and user groups to add;
   the people chosen to manage Ryker are always invited (workspace admins are not, unless chosen);
5. confirm: a plain-English summary of the choices with **Save settings**, **Start over** and
   **Cancel**, each explained.

Natural-language answers remain available for operators who prefer conversation; ambiguous answers
produce a scoped clarification and do not advance the draft. Only the configured operator who
started the setup can answer it. Controls are bound to the durable setup id, channel, actor, current
step, revision and 30-minute expiry, so a stale, copied or replayed button cannot advance or save. Saving retires the wizard message, revises the saved configuration
and re-renders the welcome; cancelling or expiring leaves the saved settings and the welcome
untouched. Saving affects listening, the channel's environment, Slack-app alert escalation and
room invitations only. It never authorizes repository changes, Emisar approvals, deployments or
infrastructure mutations. The channel's page on the web chooses its environment the same way: a new
revision attributed to whoever chose it (`ChannelConfigurations.select_environment/4`), refused for
an environment nobody saved.

A channel either chose its participation or inherits the installation default; there is no third
store. A channel's environment is its own: **No environment** runs the channel's work outside any
environment, never in the default. Only a conversation with no setting of its own, such as a direct
message, runs in the default environment. Confirmed channel deletion removes its membership observation, setup sessions and saved
configuration.

The installation participation default covers shared operational feeds such as `#infra-alerts`
without naming them one by one. Ryker must be invited to every channel it participates in; the
membership reconciliation above repairs missed joins and leaves at startup and every five minutes.
Public and private channels behave the same way.

Operators can change proactivity from Slack, without restarting Ryker:

```text
/ryker proactive on
/ryker proactive off
/ryker proactive inherit
/ryker proactive global on
/ryker proactive global off
/ryker proactive global inherit
```

The effective setting is the channel's own saved participation when it has one, and the installation
default otherwise. `global on` moves that default, so every channel that never chose follows it
immediately; a per-channel `off` opts out and a per-channel `on` opts in regardless. `inherit`
clears the channel's own setting so it follows the default again — it stores inheritance rather than
copying today's default. A per-channel `on` needs the channel's saved configuration, which exists
once Ryker has joined and stays after it leaves; every `/ryker` command requires a configured
operator.

Ryker durably reads ordinary messages from active full workspace members and messages posted by
external Slack apps in each watched channel. It ignores its own messages, unsupported message
subtypes, foreign-workspace events, guests, and external Slack Connect users. Inputs are processed
in Slack timestamp order within a channel, while separate channels can progress independently.
There is no settling delay: each input is decided as soon as it is its turn. A delayed Slack event older than an already completed channel decision is retained and
audited but cannot produce an out-of-order reply.

Each input is decided in its own short Coop session, closed after the decision; what carries a
feed's context from one message to the next is the frozen transcript and the stored conversation
summaries. Before submission, Ryker freezes a transcript that ends at the target message: a
thread reply gets the thread's root and the replies before the target, and a top-level message
gets the top-level messages before it, never replies lifted out of other threads. The window holds
20 earlier messages by default (a code default between 10 and 20, not a setting), and nothing that
arrived after the target can enter it. Retained inputs are authoritative; a bounded read of Slack
history (at most three pages) fills only gaps that retention has already reclaimed, and the frozen
manifest says which happened.

This applies to explicit mentions even when broad proactive triage is off. Top-level context can
include ambient messages that were never Ryker work, allowing the agent to recognize that two
people are talking to each other or that another person already answered. Raw messages from
unrelated threads are not mixed into the target thread. A conversation summary is stored per
Slack thread and per channel and retains purpose, situation, goal, active topics, topology,
decisions, open loops, unresolved questions, evidence references and participants. Each turn also
receives a
bounded set of recent summaries from the same channel and from public channels across the
workspace, preferring the same repository. Private-channel summaries stay local unless a future
membership-aware path can prove the requester may read them. A work session is replaced when its
worker reports it exhausted, closed or discarded (Ryker's default job allows 100 turns),
when its knowledge context goes stale, when the model setting for its kind of work changes, or when
its worker is lost; Ryker has no age or turn-count rotation of its own. Conversation summaries
survive for the conversation-memory retention period.

An operator may also explicitly ask Ryker to remember a fact (what a service is called, which
repository holds it; the model can propose only these, saved as entity relationships) or open-ended
collaboration guidance. A natural
request such as `remember that when you explain fixes to me, start with a plain-language summary`
produces a confirmation card with the exact guidance, scope, and expiry. Personal guidance follows
that operator across channels; an explicit channel or team convention uses channel or workspace
visibility. Until the button is confirmed, nothing is stored. A later request with the same topic
replaces the logical entry. Guidance is advisory: it cannot trigger work, count as evidence, authorize an
incident or change, approve an action, or override the current request or host safety policy.
Operational mappings are likewise never presented as live health or authority; future
investigations verify them against repositories and live tools. Same-channel evidence can be
recalled from the evidence ledger, while evidence from other private channels is never injected.

### Saved entities and requested collections

Confirming a schedule, standing rule, preference, guidance or memory offer re-renders that message
as the saved entity through one shared projection: the stable title, the full readable purpose or
instructions, real metadata (when and timezone, next run, authority, repository binding,
destination, scope, visibility, expiry — "Until disabled" and "No expiry" are values, never
placeholders), a brief notice such as **Schedule saved** or **Schedule has been updated**, who saved
it and when, and one exact-resource removal control: **Delete schedule**, **Delete rule**,
**Delete preference**, **Delete guidance** or **Forget memory**. Each control carries the entity
reference and the revision it was rendered from and opens a native consequence dialog naming that
entity: removing a schedule or rule stops future work while history remains; forgetting memory does
not erase messages already sent. The click reruns the same authorized owners App Home uses, which
recheck workspace, current status and revision; a stale, copied or non-operator click is reported
as denied or no longer current and never as a deletion. After removal the message repaints to its
deleted state with no controls. An updated automation renders as the saved entity with its new
values and the update notice rather than a bare acknowledgement.

Asking Ryker for the active schedules, standing rules or saved knowledge in a channel
("what schedules are active?", "show standing rules", "what do you remember here?"), or pressing
**View schedules** / **View standing rules** on a settings reply, posts one saved-entity card per
item in that thread, with the same detail and removal controls. A page holds at most five items,
ordered by next run or recency, followed by "Showing 5 of N" with the exact total from the same
scoped query and a pointer to the complete list in an operator's App Home; the sentence names
operators because Home discloses operational detail to no one else. Every item has its own delivery
identity, so a failed item is retried without posting earlier items again. An empty result says
so; a query that could not run says it could not load, and never "no schedules". Items scoped to
other channels, operators' private guidance and deleted or expired entities are never listed.

Behavior memory is a separate typed facility for deterministic controls. An explicit request such
as `when I ask about infrastructure health, always do a deep check` can offer a
`health_check_depth=deep` preference. `Prefer threads when replying to me` can offer
`response_location=prefer_thread`.
An explicit request such as `when someone posts a Terraform plan here, review it for risky changes`
can offer a standing rule: a source-event automation naming its source (`slack`, `github` or
`webhook`), an exact filter on the event, the task, the channels it reads and replies in, an
optional repository and an optional end. The model may select only a supported preference value or
such a rule; Ryker never persists the original prose as an executable trigger.

Every behavior offer is a host-rendered confirmation card. It states the normalized behavior,
scope, expiry, source filter when applicable, and the boundary: "Read-only initiative in this
channel; it cannot approve, publish, deploy, or mutate infrastructure." A matching rule can still
start read-only work. Confirmation requires a configured full workspace operator in Slack (on
GitHub, `/ryker confirm` from someone with write access to the repository). That operator may make an explicit behavior setup request in
any channel where Ryker is invited, even if ordinary mentions and proactive triage are disabled
there. This exception admits only the typed setup turn; it does not turn the channel into a summon
channel. Preferences resolve in operator, channel, repository, then workspace order. A rule matches
an exact filter on events from its one source. The older Terraform-plan, deployment and
operational-alert rules with a `human`, `app` or `any` filter are still honored, but nothing
creates them any more.

After a successful automation, schedule, memory, preference, or guidance confirmation, Slack shows a
private acknowledgement and refreshes the original card to its confirmed state without the old button.
The update remains queued across a restart; clicking again does not duplicate the change. The original
accepted response remains in episode history even when its live card no longer says it is a proposal.
Source-event automation filters use the exact observed event payload and its input adapter (`slack`,
`github`, or `webhook`). Vendor names such as Terraform are not input adapters; a missing example must
be resolved before inventing a rule that would never match or enabling an unbounded channel listener.

An enabled standing rule can admit only its matching message type when broad proactive triage is
off. The resulting turn uses the current channel transcript and available read-only tools. A match
is an evaluation request, not an order to reply: the model may ignore an intermediate or duplicate
event, react when that is sufficient, or reply in the source thread when it has a useful result. It
cannot silently convert the message into an incident. Later lifecycle updates are evaluated fresh.
An operational-alert reply must be decision-ready: Ryker rejects a completion that merely
paraphrases symptoms or hands operators a generic checklist. The agent must reconcile declared
repository topology with fresh Emisar or monitoring evidence, classify the alert as confirmed,
likely, disproved, or still unverified, and explain impact. Confirmed or likely issues also require
an immediate mitigation and a durable root-cause solution. The same Coop run continues when this
quality contract is not met; the pending indicator remains visible while it gathers more evidence.
For Terraform review, the exact plan must come from the message or an available read-only tool,
never an inferred repository diff. The channel queue preserves Slack timestamp order, and a
durable rule/source-event key prevents duplicate execution after redelivery or restart. Shadow mode records
the matched decision and run without posting.

When a watched-channel input arrives, Ryker queues a native thread status naming its phase, as
described above. Statuses, replies,
and cards share the durable Slack delivery ledger, so restart does not lose them. The status is
refreshed before Slack's two-minute expiry and cleared only after the run replies, stays silent,
hands off to incident creation, or queues a user-facing failure. Every progress update and clear has
a durable per-thread generation, so delayed progress cannot resurrect a status after a clear. If
the failure explanation cannot be delivered, the ledger retains both the desired outcome and the
retry instead of leaving the user without a durable result.

For a question about current infrastructure health, operational state, or an alert, the agent can
inspect the repository for declared topology and use policy-authorized read-only tools, especially
Emisar for live state, before deciding. It also considers any other available MCP server or tool
that owns relevant evidence and reconciles disagreements between configured and observed state. It
cannot modify repository files from this shared-channel session. Changes to running systems go only
through Emisar: anyone in a conversation Ryker serves can ask for an exact change, and Emisar's
policy decides whether it runs and who must approve it (see Controls). The host accepts only one
validated decision:

- stay silent for noise, routine success or recovery notifications, duplicates, and ambient
  conversation;
- add one context-appropriate Slack reaction when acknowledgement is useful but a prose reply would
  interrupt the team;
- reply concisely where the human is speaking when they address Ryker and channel context or a
  bounded read-only investigation provides enough evidence;
- while longer work runs, post a short update into the thread when it helps the person follow
  along (an early acknowledgement, a partial finding, what Ryker is doing next): at most three per
  turn, in order, always before the answer, which still says everything. The thread's status line
  reads "is posting an update…" meanwhile;
- attach an incident offer when a human-reported problem may benefit from coordinated
  investigation, without creating anything yet. One offer owns both paths: **Investigate** starts
  durable read-only work in the existing thread under the incident policy, with no room and no
  invitations; **Create incident room** uses the configured incident policy and audience. The host
  serializes the two on the offer record, so concurrent opposite clicks start exactly one path and
  the other reports the control as no longer current. The confirmed offer says which path it took,
  and **Open incident room** appears only as a link once the room's channel exists;
- attach a `Start task` confirmation when a human teammate explicitly requests repository
  changes, without weakening the shared channel's read-only boundary;
- open a dedicated incident room automatically for a credible unresolved monitoring-app alert, when
  the channel's alert setting is **Always open a room**. A human's explicit request to open, create,
  start, or declare an incident gets the incident offer; a configured operator's **Create incident
  room** creates the room.

An ordinary human health question is never sufficient host authorization for automatic incident
creation, even if the model identifies an unhealthy component. The offer button explains that no
incident exists yet and requires a configured full-member operator. The original Slack input stores
the offered title and repository durably, so a restart does not change what the button approves. Repeated clicks are idempotent.

There are no attention scores or thresholds. The admission decision is one of ignore, react,
quick reply, reply, start work or continue existing work, with its reason, the work it relates to,
and the kind of work (conversational, standard or deep); Ryker validates it before acting on it.
A quick reply is a short answer routing writes itself for a person in Slack or Chat — "hi",
"thanks", "are you there?" — sent in the thread without starting work: one to three short messages
in the order routing wrote them, and up to three emoji on the person's message when it asked for
one or an emoji says it better. A reaction alone is up to three emoji. The thread stays engaged,
so the person's next message there reaches Ryker without a mention. Ryker may use
any standard Slack emoji or a workspace custom emoji visible in the supplied message context. The
host validates the emoji name, adds or removes one reaction per call on an exact current human
message (removing only reactions Ryker added), and lets Slack reject names that are not available
in that workspace. A reaction acknowledges or signals; it never claims verification,
approval, remediation, or future work.

Ryker also observes reaction additions and removals on messages it posted. These events enter the
same durable episode order as messages and appear in the next
conversation turn alongside the current bounded reaction counts and reacting member IDs. A reaction
does not start an agent turn or produce a reply by itself. Removed reactions are retained only as
historical context and are not treated as current agreement. No emoji reaction can authorize an
incident, approval, repository change, deployment, or infrastructure mutation.

Engineering-task offers use active full workspace membership rather than incident-operator
authorization. They retain the same source-message binding, restart durability, and idempotency
rules. Their source threads use task-specific cards and lifecycle copy rather than presenting
repository work as an alert incident. Dedicated Slack rooms remain reserved for incident
coordination. A member offer runs in its conversation's environment: it must name one of that
environment's repositories, runs under the environment's own contributor policy and keeps the
environment on the task's session. A conversation with no environment has no repository a task
could change. Only operators may press the publication and destructive task controls; a confirmed
task's own draft grant can open its draft pull request without a click (see Controls).

An approved or permitted incident decision retains the original Slack message as evidence,
acknowledges the source thread, and enters the same channel, root-card, isolated-fork, and
policy-controlled investigation workflow. Every admitted watched message is one accepted request,
decided in channel order. When a work session is exhausted, Ryker continues in a fresh one. The
bound is frozen in the Ryker-authored job (by default, 100 turns, 20 queued turns and a
one-hour turn timeout) and enforced by Coop within its service-wide limits. No Slack control
changes an existing job's limits; exhaustion creates a replacement session, not an extension.

An explicit mention goes through the same admission as any other input. Incident wording is not
matched as a phrase: the model decides to offer an incident room, and an operator's press creates
it. Slack also emits the same mentioned message through
the ordinary channel-message subscription; Ryker acknowledges that duplicate and admits only
the `app_mention` event.

## Slash command

The shipped Slack app registers one command, and this is the whole of it:

```text
/ryker status
/ryker proactive on|off|inherit
/ryker proactive global on|off|inherit
/ryker shadow on|off|inherit
/ryker shadow global on|off|inherit
/ryker assignments [list|pause|resume|delete]
/ryker help
```

`settings` and `config` are accepted spellings of `status`, `watch` of `proactive`, and
`assignment` of `assignments`.

There were twenty-odd. The catalogue grew a verb every time the product grew a capability, on the
assumption that anything worth doing is worth typing, and the result was a second interface to
everything: `incidents` paged a directory App Home already showed, `work` printed the commitment
card, and `memory`, `preferences`, `rules`, and `schedules` each managed a facility that is created
by conversation and confirmed on a card. Slack does not tell a slash command which thread the
composer is sitting in, so the verbs that mattered most during an engineering task — `update`,
`changes`, `stop`, `close` — resolved by channel and answered about the wrong work.

Four of those are the emergency kit: they reach no model and need no Coop session, so they answer
while an agent run is stuck or looping, and they answer privately to the operator who typed them.
`status` says what Ryker is doing in this channel and why. `proactive` and `shadow` change what
the channel is read for. Those are the controls an operator needs when a room will not stop talking
and the ordinary conversational path is the thing that is broken.

`assignments` is the fifth, and what is left of it belongs to the same argument: reading a channel's
standing rules and taking one back are what an operator reaches for when Ryker itself is the
problem. A standing assignment is a confirmed standing rule, the same record the control plane's
Rules page lists. Its `create` verb did not belong, and it left on 2026-08-15: it asked an operator
to compose a grant as six `key=value` bounds and confirmed nothing but their own typing — a
miscounted `paths=` was a repository-wide grant that read as a narrow one. Asking in words now
produces a rule offer card stating exactly what it would save: its source and filter, the task, the
channels it reads and replies in, the repository and when it ends, under the read-only boundary.
Nothing exists until **Enable automation** is pressed, and the click re-authorizes and re-reads the
recorded offer. The typed verb answers "Ask for the standing assignment in ordinary language. Ryker
will show its normalized read-only bounds for explicit confirmation."

Everything else moved to a surface that can reach further than the composer can. A removed verb
answers "Unknown `/ryker` subcommand `<verb>`." followed by the whole guide; the table below says
where each capability lives now.

| Typed | Where it lives now |
| --- | --- |
| `incidents`, `work`, `commitments` | App Home's **In flight** and needs-you rows, the web control plane, or ask in the channel |
| `memory`, `preferences`, `rules`, `schedules` | App Home and the web control plane manage them; creating one stays conversational and is confirmed on a card |
| `feedback` | Say it. Feedback is recorded from what was said |
| `timeline`, `evidence`, `handoff`, `postmortem` | The overflow menu on the incident or task card (**Open evidence** is a button on an incident card) |
| `update`, `changes`, `review`, `publish`, `stop`, `close` | The buttons on the pinned card (**Stop current run**, the close control, the publication controls), or ask in the thread |
| `extend` | Nothing. An exhausted session continues in a fresh one |
| `turn-limit` | A Ryker-authored job limit enforced by the worker |
| `assignments create` | Ask for the rule in words; the offer card shows what it would save and nothing exists until it is confirmed |

Slack does not provide application-defined autocomplete for text after a slash command, so the
manifest carries one short static usage hint and the whole guide lives behind `help`. The hint names
the four emergency verbs only, because it is a picker and not a catalogue. Running `/ryker` with
no arguments returns the full guide as plain text: every verb that exists and one line on why there
are so few.

No phrase table sits beside it. A keyword router used to rewrite plain operator messages into slash
subcommands, and it read every message in a proactive channel: "shadow traffic is on the new
cluster, ignore it" turned the channel silent, and "hey bob what are you working on?" posted the
commitment card at the room. Free text is now classified by the model and executed by the host, and
`@Ryker reconfigure this channel` (or `configure this channel`) is the one request still read from
text — it has to survive the model being unavailable, and it is read only as that exact phrase, in a
mention, from a configured operator.

`status` is the private form of the structured effective-settings view the welcome uses:
Conversations, Alerts, Environment (or No environment), Repositories (the one work changes, then
the ones it only reads), Incident invitations and Observation mode,
with a context line naming where the effective value came from (defaults, who saved the channel
setup, a change made on Ryker's settings page, a `/ryker` override, an incident room) and a **Configure channel** control that opens the
Q&A in the welcome thread. A settings question addressed to Ryker in a channel — "what are
your settings?", "how are you configured here?" — posts the same view as a reply in that thread.
Reading settings never mutates them. The view never relies on raw values such as `inherit`,
`parked`, or a configuration file to explain behavior. Proactive and shadow changes are
durable and audited. A pressed incident control acknowledges the requested effect and directs the
operator to the pinned incident thread for the authoritative result. Slash commands and button
controls both run in the control lane, so `proactive off` or **Stop current run** does not wait
behind a running agent run.

## Task progress

The task card carries one stable stage list for the whole task: Workspace setup, Planning,
Implementation, Self-review and checks, Draft PR, CI, and Review and merge. Stages never
disappear — waiting, failure, stopping, an explicit skip and unrecorded history change a stage's
glyph (`○ ▸ ◷ ✓ ! ↻ − ?`), not the list. The active stage and the active subtask are bold, and
`← 🙋 your turn` marks the stage that needs a person.

Workspace setup, Draft PR, CI and Review and merge are host facts: the Coop session binding,
publication custody, and the `episode_publication_followups` check and merge receipts. Planning,
Implementation and Self-review come from the model's own goals, which now carry an explicit
`stage` (`planning`, `implementation` or `self_review`); a child goal belongs to its parent's
stage. Implementation counts current logical leaves once — `Implementation · 4/6 subtasks` — so a
parent heading, another stage's goal and a superseded attempt are never counted. A plan that does
not exist yet has no denominator at all rather than `0/0`, and goals retained before typed stage
membership existed stay in a separate unrecorded row instead of being backfilled into a guess.

A completed goal is never reopened. When changed work needs a check to run again, the model plans
a successor attempt with `successor_of` naming the terminal goal it repeats, and the earlier
result stays exactly as recorded. `update_goal` carries `evidence_refs`, the citation records that
observed a result; a declared completion never overrides a failing, missing or stale host check.
Once newer implementation work lands after a publication, Self-review, Draft PR and CI show `↻`
against the published revision rather than a green check for work that was never checked.

Self-review and checks is never complete while a required check has no result. A candidate whose
trusted gate could not start, did not run or is not configured shows `!` with that missing check
named — `! Self-review and checks · docker: command not found` — and it keeps showing it after an
operator opens the draft. A gate that ran and failed is a result rather than a missing check, and
it fails the same stage with its own failure named — `! Self-review and checks · 2 tests failed`.
CI on the exact published head is a separate row and may well be green; it is not the trusted
gate, so Review and merge stays `○` instead of becoming `← 🙋 your turn`.

When the host is still holding a finished worker's working copy or its reply, Workspace setup
carries the cause — `! Workspace setup · no saved snapshot · session closed` — and the stages the
worker did reach keep their own dispositions. A pull request published earlier stays linked from
its Draft PR row, marked `↻ #91 · earlier snapshot, newer work not saved`.

When the work never started at all — the host blocked the turn before any worker turn was bound —
that same row says so in the host's own words instead of the saved error term:
`! Workspace setup · work never started · The worker rejected the operation: …`, with the worker's
own sentence quoted, redacted, bounded and escaped, and never the enum, the tuple or the session
identifier around it. Action needed carries the same cause and the step that answers it, so the
card names a condition rather than pointing at the episode. A saved error the host cannot
characterise keeps `! Workspace setup · work never started` and the generic notice, because a
cause nobody has is not one to invent.

## Controls

Card buttons change with state rather than presenting actions that cannot succeed. Publication,
stop, close, and discard buttons may remain visible to make the operator handoff obvious, but the
host rejects them for nonoperators before any repository or session mutation:

- provisioning or holding: **Close incident**;
- active turn: **Stop current run**;
- waiting for input: **Close incident**;
- reviewing or publishing a draft PR: the card activity names the current publication stage,
  keeps any existing **Open PR** link, and hides review, publish and close controls until the
  attempt finishes. Rendering this progress does not wait for another
  Coop change inspection;
- transient publication failure: the card shows the bounded last error, preserves
  any existing **Open PR** link, and offers **Retry publication** for that exact recovery
  generation;
- push or pull-request identity conflict: automatic retry stops. When Ryker proves an exact
  App-owned PR and observed head, the card preserves **Open PR** and offers **Review latest state**
  plus **Discard candidate**. Without that remote identity, only the local **Discard candidate**
  action is available;
- stale draft PR: **Review latest state**, **Open PR**, **Check delivery**, and
  **Discard candidate** render from durable publication state without waiting for a fresh Coop
  inspection. Review latest state invalidates the prior approval and review, records the exact
  observed GitHub head, reruns Coop review, and can update the same PR only with a
  `--force-with-lease` compare-and-swap against that observed head. A head that moved outside the
  publication is the one case an in-scope correction cannot re-arm on its own, so this control
  stays the operator's explicit decision to review against that head;
- published draft PR: **Open PR** and **Check delivery** remain available independently of a
  transient Coop inspection failure;
- workspace not recoverable yet: the worker finished, but the host could not save its working copy
  or could not release its reply. The card says so in plain language, says what to keep and whether
  the worker session is closed, and attributes the retained answer as the worker's own report
  rather than a check result. The only control it adds is **Review recovery**; there is no saved
  snapshot, so the diff control is withheld and nothing is offered that would create a draft or
  replay the completed work. An earlier pull request keeps its **Open PR** link, named on the card
  as the earlier snapshot without this work;
- closed: read-only record controls only; otherwise no controls.

- Diff reading is web-only. Slack never renders or pages a patch: the control plane owns the
  changes page, which reads Coop's typed fork summary one snapshot-bound page at a time, carries
  the complete patch digest and byte range, and says how many paths are omitted from the compact
  summary. Once a candidate has a pull request, **Open PR** is the change link on the card.
- A confirmed coding task automatically checks its completed, checkpoint-backed changes. There is
  no separate readiness permission button. The review compares the isolated changes with the
  current repository, checks rebase, runs configured validation and policy gates, and reports
  whether the result is ready for external review. Merge readiness requires a passed gate, clean
  rebase, no policy findings and a verified complete patch. A separate draft-shareability verdict
  decides whether one exact, security-clean snapshot is safe for a person to read: a gate that
  could not start, did not run or is not configured leaves the change shareable and names the
  missing check, while a failed gate, a rebase conflict, a policy finding, an inexact snapshot and
  any refusal the typed verdict cannot explain are never shareable. Shareability waives no check
  and grants no authority: the host never opens an unverified draft by itself, it offers one.
  Readiness never merges, signs, or deploys.
  Checks and follow-up Work share session custody, so a normal reply waits for an active review
  without consuming an execution attempt. Delivery and unrelated sessions continue independently.
- A confirmed coding task carries its own draft grant. When publishing is on (**Let Ryker open pull
  requests**, off by default), the confirmed task offer named this repository, and the exact
  reviewed candidate came from that task's work, Ryker opens the draft pull request itself,
  recorded as approved by the task's confirmer: the card says it is opening the draft and offers no publication click,
  because a click could not change the candidate, the repository or the scope. Revoking the
  confirmation, confirming for a different repository, or a task with no repository leaves the
  candidate at **Create draft PR** for a person. The grant is publication only — merge, deployment
  and any other repository stay separate decisions — and an operator's **Discard candidate** is the
  last word on publishing that candidate.
- **Create draft PR** explicitly approves the complete candidate retained by Coop. Ryker asks
  that worker to push the exact reviewed commit and its LFS objects directly to GitHub, using
  a short-lived repository-scoped App grant. The branch update checks its expected remote head;
  neither code nor credentials enter Ryker's publication records or the model sandbox.
  On a blocked candidate whose checks could not finish, the same control
  offers an explicitly unverified draft: its confirmation names the repository and the check that
  never ran, and says that a draft waives nothing and neither merges nor deploys.
  After publication the task shows **Open PR** and **Check delivery**, and a draft opened that way
  keeps saying which check never finished instead of reading as an ordinary reviewed pull request.
  Ryker reuses and updates that same authorized publication; an uncertain create reconciles
  against the App-owned pull request it already published rather than issuing another blind create.
  Ryker checks the pull request once when it is published, then refreshes it when GitHub reports
  check runs, check suites, statuses, workflow runs or pull-request events for that head, or when
  someone presses **Check delivery**; there is no timer, and waiting occupies no model turn.
  Checks that turn to failing on that exact head return the task to in-scope correction, once per
  failing head, without a click and without widening the task; a
  hard deadline, a head that moved outside the publication, a close and a merge stay history for a
  person. A correction that completes in scope re-arms the task's own publication for a fresh
  review and updates that same pull request: one task keeps one publication and one draft PR, the
  card returns to the reviewing stage with its **Open draft PR** link intact, and each review
  generation posts its own card rather than overwriting the superseded one. The prior generation's
  approval cannot carry a new candidate, so a corrected candidate is authorized again by the same
  task grant or waits for **Create draft PR**. A candidate the operator discarded is never
  resurrected, and a review, approval or publish phase still in flight keeps the publication it
  holds. After merge, matching deployment and
  Terraform app messages from other watched channels return to the original task thread only when
  the source message contains that publication's exact pull-request URL, branch, head SHA, or
  merge SHA for the same repository, within 30 days of publication. Loose topic, repository-name,
  and timing matches are rejected. An exact reference activates this
  correlation path even when ordinary proactive participation is off in the source channel; other
  app messages retain the channel's configured behavior. The 30-day window is fixed (it restarts
  when the pull request is reviewed again); **Check delivery** refreshes GitHub state immediately.
  These controls cannot merge or deploy.
- **Stop current run** cancels only the active agent turn. The session, queue, and fork remain.
- **Close incident**/**Close task** closes the Coop session. Clean zero-change or durably published
  workspace state is reclaimed after a fixed 15-minute grace period; dirty or unpublished changes are
  retained.
- **Discard retained work** appears in App Home, for configured operators, on a closed engineering
  task with unpublished changes (the control plane's Working copies page offers the same as
  **Discard unmerged**). Its confirmation authorizes Coop to delete clean committed work after an exact discard-plan check.
  Dirty uncommitted files are still refused.

Every work card has one overflow menu that lists its records directly: **Timeline**, **Evidence**,
**Handoff summary**, **Review recovery** on a task whose workspace or reply the host is still
holding, and **Postmortem draft** on an incident. This keeps
the primary card to one clearly owned menu while staying below Block Kit's five-option ceiling. An
incident card is the one exception: it carries **Open evidence** as a button and keeps the rest in
the menu, because on that card the findings are the subject rather than an aside.

**Timeline** presents the chronological remediation record: alerts, agent runs, operator and
lifecycle events, Emisar approvals and terminal run results, and draft-PR publication. It derives
these entries from their canonical rows rather than copying them. **Evidence** shows the latest
source ledger and material unknowns. **Handoff summary** prepares an evidence-backed shift summary.
**Postmortem draft** builds the post-incident draft from the durable record whenever it is asked
for, including after the incident has closed; closing does not post it, and it does not invent
impact, root cause, owners, or corrective actions.
**Review recovery** appears only while the host is holding a finished worker's working copy or its
reply: it shows the same brief the control-plane recovery page shows — the host failure in plain
language, what to restore, the workspace and delivery status, and the complete retained answer
attributed as the worker's own report. All of them are host-rendered from the stored record — the
model never writes a timeline.

These were slash subcommands. A button carries the work it belongs to in its own value, so a
task thread can ask for its own handoff; the slash spelling resolved an incident by channel and
could not name a thread at all.

Routine evidence-backed replies lead with the concise conclusion and use plain professional
language instead of making the reader decode internal architecture, schemas, or workflow terms.
Necessary technical terms are explained when first used. Simple explanation, summary, and rephrase
requests reuse established conversation context unless the user asks for a fresh check or the prior
context is not enough. The footer describes saved supporting findings and assessed system areas in
ordinary language instead of dumping the source ledger into the conversation.

Changes to running systems go only through Emisar, and Emisar decides them. Anyone in a
conversation Ryker serves can ask for an exact change; Ryker adds no operator check of its own.
Every work session in an environment with an Emisar account can use Emisar's tools (they come from
the worker's own MCP configuration) and Ryker's tool for recording the approval it then waits on.
Emisar's policy decides whether an action runs and who must approve it, and Emisar's audit records
the decision. The model is told not to treat an alert or other event as a request to act, and not
to run an action again or start a replacement run while it verifies one; those are instructions to
the model, not checks. No incident room is required. When an action waits for approval, the
conversation receives an **Emisar review** card: its status ("◷ Waiting for review." or how many
reviews are in), the reason, evidence and expected outcome from the review, the command or action,
and the runner, with **Review in Emisar** (later **Open in Emisar**) and **Open exact run**. On
GitHub the same request is a comment titled "Approval required in Emisar" with the action, runner,
pack and expiry. Opening the link is navigation, not approval; no action has run, and the decision
remains in Emisar's authenticated console and audit trail. Ryker watches that exact run and, when
it finishes, continues the same conversation with its result.
There is no text spelling of a control. An unadvertised `!respond <verb>` router used to read every
message in a thread carrying an incident and match eight verbs against it; it was removed on
2026-08-15. The pinned card above the thread carries stop, publish and close as buttons that
name what they do and refuse the people who may not press them, and a slash command run from the
composer cannot select a thread at all.

No message executes a control. A message such as “maybe stop after this” — or “!respond stop”, or
anything else — is an operator turn, not a cancellation.

## Authorization

Workspace membership alone does not grant operator authority. Incident steering, incident-offer
approval, durable behavior and schedules require both:

- the Slack user ID is one of the configured operators: a person chosen under Integrations ›
  Slack (`operators` in the Slack settings) or, while **Workspace admins and owners can manage
  Ryker** is on (the default, `workspace_admins_manage`), someone Slack's `users.info` lists as an
  admin or owner of the workspace. Ryker asks Slack when it matters and keeps the answer for a
  minute; a lookup that fails refuses. One check, `Ryker.Slack.Operators.operator?/2`, decides it
  for every surface below and for the saved settings themselves;
- Slack reports a current full member of the configured workspace (`workspace_ref`).

Changes to running systems are not on this list: Ryker does not decide them, and Emisar's policy
does (see Controls).

Bots, app users, deleted users, guests, restricted users, strangers, and external Slack Connect
members cannot steer an incident session. Foreign-source channel events are dropped before
persistence. External apps are accepted only as untrusted classification evidence in explicitly
watched channels; they cannot invoke incident controls, select the environment, repository or policy, or join
the resulting incident conversation. Coop and Emisar policy remains authoritative for any access
available to the triage session.
Only configured full-member operators can approve a watched-channel incident offer.
Denied actions are audited and receive a short explanation in the incident thread when possible.
The room-wide listening behavior does not weaken this boundary: only configured, authenticated
operators become Coop conversation turns.

The same operator and active full-member checks protect every `/ryker` command. Slash command
text is parsed by the host as an exact command; it is never sent to the model.

Engineering tasks deliberately use a different boundary. Any active full member of the configured
workspace may confirm a task offer for one of its conversation's environment's repositories,
collaborate in its source thread, and
use its non-destructive task controls. A configured operator must press the publication controls,
stop, close, or discard work (a confirmed task's draft grant can publish without a click; see
Controls). Guests, bots, restricted users, strangers, and external Slack Connect members remain
denied. Task authority never grants incident control, durable behavior changes, scheduling, merge,
deployment, or signing authority; a change to running systems remains Emisar's decision.

Buttons are also bound to the incident ID, channel, and root message timestamp. Stale or copied
controls are rejected.

## Failure behavior

Once a root card exists, incident failures are visible there and in accessible fallback text. A
failed or cancelled turn posts a concise thread message explaining what stopped, that the fork and
evidence remain, and how to continue. Failures before channel or root creation remain visible on
the control plane's Failures page, in metrics, and in service logs.

Active-session capacity puts an admitted incident into holding. The separate open-room limit (25
per workspace) refuses a new room before its channel is created, without an explanation in the
thread (see Explicit summons). Webhook admission remains durable during a temporary Slack or Coop
outage, while `/readyz` reports the disconnected dependency.

Closing never archives the channel or merges work. It schedules ownership-checked retention;
automatic cleanup refuses dirty and unpublished committed changes.
If a human archives or deletes an incident room, Slack's lifecycle event is persisted before
acknowledgement. An archived room pauses: its card says "The Slack room is archived. Unarchive it
to resume investigation and delivery.", room writes stop, and the Coop session, isolated fork,
channel identity, and audit records remain. Unarchive events
restore the room. A deleted channel never comes back, so Ryker closes its investigation the way
**Close as no longer needed** does (a run still working stops first, on its worker's answer), posts one fixed
note in the alert thread the room was opened from, *The incident room #name was deleted. Reply
here to pick it up.*, and closes the room with that reason, freeing its place in the open-room
limit. Slack names nobody in a deletion event, so the note names the room. A reply the
investigation finished but had not yet posted in the room goes, unchanged, to that alert thread
first, and the investigation closes after it; a reply Slack refuses there for good is never
dropped: it waits on the Failures page for a retry, and the room closes anyway. Once a person posts
that reply from Failures, the investigation closes too, rather than waiting for an answer, or
running again, in a room that is gone. A shadow room, or
one Ryker has no publisher for, closes without the note, and a note Slack refuses for good does
not hold the room open. A room still being set up closes at once. A missed `channel_not_found`
response marks the room unavailable, not definitively deleted.
