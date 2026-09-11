# Slack experience

## Message contract

Every operational message must stand on its own for an operator who has not read the configuration
or implementation. It should answer, in this order:

1. **What happened or what is true now.**
2. **What that means for Responder's observable behavior.**
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
   `slack.channel_prefix` setting (`ems` by default);
2. a concise topic with the incident identity;
3. invited configured responders;
4. one pinned root card;
5. one Coop session and isolated fork.

The root card is the authoritative incident snapshot. It shows:

- plain-language alert and Responder states;
- severity, firing/total signals, repository, lifecycle times, and isolated fork;
- the latest alert summary and a validated alert-source link with its hostname visible when supplied;
- a prominent action-needed section when work is blocked;
- only controls that are valid for the current lifecycle state.

The top-level fallback text carries the same essential status for notifications and screen readers.
Responder updates this message in place and alternates card writes with thread delivery so a busy
conversation cannot leave the pinned snapshot stale.
Responder also persists the rendered card UI revision. A changed revision marks every writable
existing card dirty once during startup, so upgraded controls appear without waiting for unrelated
incident activity; failed Slack updates remain queued for retry.

Configured operators can converse anywhere in an incident channel without an `@mention`.
Responder admits ordinary top-level messages and thread replies, keeps them in the same Coop
conversation, and follows the operator's current location: a channel message gets a channel
response and a thread reply gets a reply in that thread. An operator may say `switch to a thread`
or `back to the channel`; Emisar acknowledges the move at the new location before continuing.
Mentions and replies to the pinned card are explicitly direct; for ambient room conversation, the
agent may stay silent when a human teammate would have nothing useful to add. Thread-scoped
engineering tasks are the deliberate exception: their authorization and working copy remain bound
to the source thread. Active full members may collaborate in a contributor task; operator-capability
tasks remain operator-only. Each accepted teammate or operator message is one ordered Coop request. Responder
allocates session capacity automatically; tool calls and investigation steps inside the request
are not counted separately.

The pinned-card thread remains the home for proactive investigation updates, alert-driven turns,
fork summaries, review evidence, and failures. Agent tool output, hidden reasoning, token streaming,
raw webhook refreshes, and raw patches are not relayed. Long output is bounded and visibly
truncated.

Agent-authored prose uses Slack's Block Kit `markdown` block, which lets Slack render standard
Markdown from the model without lossy `mrkdwn` translation. Responses may use proportional
headings, emphasis, links, quotes, lists, task lists, dividers, tables, inline code, and
language-tagged code blocks. Responder, not the model, owns buttons, menus, mentions, approvals,
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

When enabled, Slack's native assistant status appears immediately after accepted operator input and
cycles through semantic milestones such as topology mapping, live Emisar checks, source
reconciliation, coverage assessment, and response preparation. Slack clears it only when the reply,
silence decision, incident handoff, or user-facing failure has been handled. Parked and blocked
state remains on the card rather than using a misleading persistent typing indicator.

## Agent surfaces

App Home shows durable open-incident, active-session, failed-work, incident-history, saved-memory,
and active-commitment counts plus the current incident rooms, work Emisar owes the team, compact
channel situations, and bounded memory controls. Its destination-backed rows show the original
request and jump to the exact Slack channel or thread; memory and behavior rows link to their source
while the exact user still shares it. Operators can edit stale memory, run or manage schedules,
recover publication conflicts, and explicitly discard a clean retained unmerged workspace there;
dirty work remains protected. Schedule replacement returns to the source conversation so the new
request goes through normal confirmation. The Agent Messages tab offers the suggested
prompts declared in the app manifest — production health, alert explanation, and open work. A
direct message always starts
read-only triage and does not require proactive mode or an `@mention`.

The **Investigate message** shortcut runs the same ordered read-only triage against a
selected message and replies in its thread. Direct messages and shortcuts do not create incidents
merely because they identify a problem; they can offer the same explicit incident button.

An explicit repository-change request can produce a **Start task** button. Until an
active full workspace member confirms it, no writable session or fork is created. Confirmation posts
a durable task card in the same Slack thread and creates an isolated Coop working copy. Active full
members may collaborate there, edit, validate, and commit repository files under the contributor
policy, then inspect and review the changes. Shared operational MCP and environment credentials are
not projected. A configured operator must publish, stop, close, or discard task work. Nobody can
merge, deploy, sign, or mutate infrastructure through the contributor task. Ordinary replies in the
source thread continue the same task session without an `@mention`; unrelated channel messages never
enter it. Slash commands cannot identify a thread, so task controls live on the task card.

## Explicit summons

In any channel where Emisar is a member:

```text
@Emisar investigate production checkout errors
```

The user must be a full workspace member. Responder performs bounded read-only triage and follows
the user's current channel or thread location; no proactive channel configuration is required, and
the mention alone does not create an incident. A configured operator can say
`@Emisar open an incident for production checkout errors` to create one directly. Responder then
acknowledges the request, creates the dedicated room using `slack.default_repository`, and posts a
durable `Incident room ready` reply after configured responders are invited and the topic and root
pin are ready. If the open-incident limit is full, it replies in the summon thread with the action
required instead of silently dropping the request.

After Emisar answers, that channel location remains an active conversation for 30 minutes. Nearby
human follow-ups are admitted without another mention, including a reply that starts a thread from
Emisar's top-level answer. This window is anchored to the last successfully delivered Emisar triage
reply; silence does not extend it. Membership, chronological context, addressee classification,
attention policy, and per-conversation serialization still apply, so nearby human conversation can
be understood without forcing Emisar to interrupt it.

## Watched channels

### Channel welcome and optional setup

Responder admits the bot's own Slack channel-join event immediately and records the event, the
membership transition and a complete default configuration in one transaction: mentions-only
participation, the deployment-default repository, in-place alert investigation and no additional
incident invitees. Useful defaults need no click. A periodic reconciliation against the bot's
joined conversations is the recovery path for a missed event; it configures and welcomes only the
memberships it repaired itself, never already-joined channels, so a sweep cannot flood configured
channels with hellos. Membership state survives restarts, suppresses duplicate welcomes, and makes
remove/re-add post one fresh welcome for the new membership generation.

The welcome is one message per channel, generated entirely from the effective saved settings by the
same projection that answers `/responder status` and settings questions: repository access (typed
links when the repository names a GitHub repository), conversation participation, the actual alert
behavior, observation mode and incident invitations. It never says "alerts are handled separately".
Its controls follow the saved state: **Be proactive** and **Customize** on a mentions-only
channel, **Mentions only** and **Customize** on a proactive one, **Configure channel** alone while
observation mode or a `/responder` override is in effect (the welcome then says which override and
how `inherit` returns to the saved setting). Each control carries the configuration id and the
revision it was rendered from; the host rechecks operator authority, channel membership and that
exact revision before saving, and a participation change preserves the repository, alert policy
and invitations chosen earlier. Every save re-renders this same welcome in place with a short
notice such as **Settings updated.**; there is never a second introduction.

**Customize**, **Configure channel** and the addressed `reconfigure this channel` /
`configure this channel` request open the optional Q&A: one wizard message in the welcome thread
(or the thread the request was made in) that replaces itself after every step and explains each
option before asking for a choice, pairing the exact button label with what Responder will do:

1. conversations: **Mentions only**, **Be proactive** or **Observe only**;
2. repositories: the default repository for coding tasks when none is named — this only sets the
   default and never grants access;
3. alerts: **Investigate** in the alert's thread, **Offer a choice** between the thread and an
   incident room, or **Create automatically**;
4. invitations: **On-call responders only** (or **No invitations** when none are configured), or a
   reply with the members and user groups to add; configured on-call responders are always invited;
5. confirm: a plain-English summary of the choices with **Save settings**, **Start over** and
   **Cancel**, each explained.

Natural-language answers remain available for operators who prefer conversation; ambiguous answers
produce a scoped clarification and do not advance the draft. Controls are bound to the durable setup
id, channel, actor, current step, revision and 30-minute expiry, so a stale, copied or replayed
button cannot advance or save. Saving retires the wizard message, revises the saved configuration
and re-renders the welcome; cancelling or expiring leaves the saved settings and the welcome
untouched. Saving affects listening, repository context, Slack-app alert escalation and room
invitations only. It never authorizes repository changes, Emisar approvals, deployments or
infrastructure mutations.

A channel either chose its participation or inherits the installation default; there is no third
store. Confirmed channel deletion removes its membership observation, setup sessions and saved
configuration.

The installation participation default covers shared operational feeds such as `#infra-alerts`
without naming them one by one. Responder must be invited to every channel it participates in, and
`responder doctor` checks membership. Public and private channels behave the same way.

Operators can change proactivity without editing the file or restarting Responder:

```text
/responder proactive on
/responder proactive off
/responder proactive inherit
/responder proactive global on
/responder proactive global off
/responder proactive global inherit
```

The effective setting is the channel's own saved participation when it has one, and the installation
default otherwise. `global on` moves that default, so every channel that never chose follows it
immediately; a per-channel `off` opts out and a per-channel `on` opts in regardless. `inherit`
clears the channel's own setting so it follows the default again — it stores inheritance rather than
copying today's default. Responder verifies current channel membership before accepting a
per-channel `on`, and moving the installation default requires a saved operator.

Responder durably reads ordinary messages from active full workspace members and messages posted by
external Slack apps in each watched channel. It ignores its own messages, unsupported message
subtypes, foreign-workspace events, guests, and external Slack Connect users. Inputs are processed
in Slack timestamp order within a channel, while separate channels can progress independently.
Before deciding, Responder waits for a configurable quiet period after the newest queued message
(two seconds by default). This lets a nearby human reply become context instead of racing an agent
response. A delayed Slack event older than an already completed channel decision is retained and
audited but cannot produce an out-of-order reply.

Each watched channel has one persistent Coop triage session so a new message is interpreted in the
context of that feed. Immediately before submission, Responder reads recent Slack channel history
or the target thread, merges it with admitted inputs, removes timestamp duplicates, guarantees the
target message is present, and freezes a target-centered `slack.watch_context_messages` window.
The default is 20 messages and the allowed range is 10 through 50. A thread window keeps its root,
the nearest preceding replies, the target, and up to three immediately following messages. On the
first visit to an old thread, Responder follows Slack pagination to recover the newest tail instead
of mistaking the first page for recent context. Once a compact summary exists, its last message
timestamp becomes the cursor and later turns fetch only the delta.

This applies to explicit mentions even when broad proactive triage is off. Top-level context can
include ambient messages that were never Responder work, allowing the agent to recognize that two
people are talking to each other or that another person already answered. Raw messages from
unrelated threads are not mixed into the target thread. Compact situation memory is stored per
Slack conversation and retains purpose, situation summary, goal, active topics, verified topology,
decisions, open loops, unresolved questions, and evidence references. Each turn also receives a
bounded set of recent summaries from the same channel and from public channels across the
workspace, preferring the same repository. Private-channel summaries stay local unless a future
membership-aware path can prove the requester may read them. The underlying channel session rotates
after a configurable age or turn count while conversation summaries survive for the separately
configured retention period.

An operator may also explicitly ask Responder to remember a durable alias, repository binding,
evidence route, entity relationship correction, or open-ended collaboration guidance. A natural
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
instructions, real metadata (when and timezone, next run, catch-up, authority, repository binding,
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

Asking Responder for the active schedules, standing rules or saved knowledge in a channel
("what schedules are active?", "show standing rules", "what do you remember here?"), or pressing
**View schedules** / **View standing rules** on a settings reply, posts one saved-entity card per
item in that thread, with the same detail and removal controls. A page holds at most five items,
ordered by next run or recency, followed by "Showing 5 of N" with the exact total from the same
scoped query and a pointer to App Home for the complete list. Every item has its own delivery
identity, so a failed item is retried without posting earlier items again. An empty result says
so; a query that could not run says it could not load, and never "no schedules". Items scoped to
other channels, operators' private guidance and deleted or expired entities are never listed.

Behavior memory is a separate typed facility for deterministic controls. An explicit request such
as `when I ask about infrastructure health, always do a deep check` can offer a
`health_check_depth=deep` preference. `Prefer threads when replying to me` can offer
`response_location=prefer_thread`.
An explicit request such as `when you see a Terraform plan here, report its main diff and red
flags` can offer a channel standing rule. The model may select only a supported preference value or
trigger/action pair; Responder never persists the original prose as an executable trigger.

Every behavior offer is a host-rendered confirmation card. It states the normalized behavior,
scope, expiry, source filter when applicable, and the boundary that it remains read-only and cannot
create incidents, edit files, deploy, approve, or mutate infrastructure. Confirmation requires a
configured full workspace operator. That operator may make an explicit behavior setup request in
any channel where Responder is invited, even if ordinary mentions and proactive triage are disabled
there. This exception admits only the typed setup turn; it does not turn the channel into a summon
channel. Preferences resolve in operator, channel, repository, then workspace order. Rules are
channel-scoped and match only Terraform plans, deployments, or operational alerts from the
configured `human`, `app`, or `any` source.

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
An operational-alert reply must be decision-ready: Responder rejects a completion that merely
paraphrases symptoms or hands operators a generic checklist. The agent must reconcile declared
repository topology with fresh Emisar or monitoring evidence, classify the alert as confirmed,
likely, disproved, or still unverified, and explain impact. Confirmed or likely issues also require
an immediate mitigation and a durable root-cause solution. The same Coop run continues when this
quality contract is not met; the pending indicator remains visible while it gathers more evidence.
For Terraform review, the exact plan must come from the message or an available read-only tool,
never an inferred repository diff. The channel queue preserves Slack timestamp order, and a
durable rule/source-event key prevents duplicate execution after redelivery or restart. Shadow mode records
the matched decision and run without posting.

When a watched-channel run starts, Responder queues a native thread status explaining that it is
checking live systems with Emisar and that broad checks can take a few minutes. Statuses, replies,
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
cannot modify repository files from this shared-channel session. An exact operational mutation is
eligible only when a configured operator explicitly requests it and Emisar authorizes it. The host
accepts only one validated decision:

- stay silent for noise, routine success or recovery notifications, duplicates, and ambient
  conversation;
- add one context-appropriate Slack reaction when acknowledgement is useful but a prose reply would
  interrupt the team;
- reply concisely where the human is speaking when they address Responder and channel context or a
  bounded read-only investigation provides enough evidence;
- attach an incident offer when a human-reported problem may benefit from coordinated
  investigation, without creating anything yet. One offer owns both paths: **Investigate** starts
  durable read-only work in the existing thread under the incident policy, with no room and no
  invitations; **Create incident room** uses the configured incident policy and audience. The host
  serializes the two on the offer record, so concurrent opposite clicks start exactly one path and
  the other reports the control as no longer current. The confirmed offer says which path it took,
  and **Open incident room** appears only as a link once the room's channel exists;
- attach a `Start task` confirmation when a human teammate explicitly requests repository
  changes, without weakening the shared channel's read-only boundary;
- attach a `Prepare code fix` confirmation when a decision-ready confirmed or likely issue has a
  narrow repository-backed remediation; this can appear beside the incident offer, carries the
  exact fix objective into the task, and still requires review before draft-PR publication;
- open a normal dedicated incident automatically for a credible unresolved monitoring-app alert, or
  directly when a human explicitly asks to open, create, start, or declare an incident.

An ordinary human health question is never sufficient host authorization for automatic incident
creation, even if the model identifies an unhealthy component. The offer button explains that no
incident exists yet and requires a configured full-member operator. The original Slack input stores
the offered title, repository, and optional fix objective durably, so a restart does not change what
the button approves. Repeated clicks are idempotent.

Every decision includes a bounded attention assessment: intended addressee plus urgency,
confidence, novelty, and ownership scores. Responder applies this after the model returns, so a
model cannot bypass the interruption policy. Ambient prose replies require
`slack.proactive_reply_attention_threshold`; reactions require
`slack.proactive_reaction_attention_threshold`. Direct requests remain eligible. A human-directed
message cannot produce an ambient Emisar reply or reaction. Emisar may use any standard Slack emoji
or a workspace custom emoji visible in the supplied message context. The host validates and
normalizes the emoji name, permits only one reaction, and lets Slack reject names that are not
available in that workspace. A reaction acknowledges or signals; it never claims verification,
approval, remediation, or future work.

Emisar also observes reaction additions and removals on messages it posted. These events enter the
same durable episode order as messages and appear in the next
conversation turn alongside the current bounded reaction counts and reacting member IDs. A reaction
does not start an agent turn or produce a reply by itself. Removed reactions are retained only as
historical context and are not treated as current agreement. No emoji reaction can authorize an
incident, approval, repository change, deployment, or infrastructure mutation.

Engineering-task offers use active full workspace membership rather than incident-operator
authorization. They retain the same source-message binding, restart durability, and idempotency
rules. Their source threads use task-specific cards and lifecycle copy rather than presenting
repository work as an alert incident. Dedicated Slack rooms remain reserved for incident
coordination. A member offer is restricted to the repository assigned to its Slack channel and uses
that repository's contributor policy; only operators may publish or use destructive task controls.

An approved or permitted incident decision retains the original Slack message as evidence,
acknowledges the source thread, and enters the same channel, root-card, isolated-fork, and
policy-controlled investigation workflow as webhook and manual incidents. Every admitted watched
message is one accepted request in its channel's ordered triage session. Responder extends exhausted
watched and incident sessions automatically up to the effective `coop.turn_limit`. That ceiling is a
shipped host bound and no Slack control raises it. The reasoning is that a session
which has spent a thousand accepted requests is looping rather than short of room, and the card says
so; the cost is that an operator who reaches the ceiling mid-incident cannot clear it from Slack and
needs someone who can edit the configuration and redeploy. Coop policy and service-wide limits remain
authoritative.

An explicit mention in a summon-enabled watched channel is routed through the same read-only triage
session and gets responder-targeting priority. Only explicit incident wording bypasses
classification and starts a manual incident. Slack also emits the same mentioned message through
the ordinary channel-message subscription; Responder acknowledges that duplicate and admits only
the `app_mention` event.

## Slash command

The shipped Slack app registers one command, and this is the whole of it:

```text
/responder status
/responder proactive on|off|inherit
/responder proactive global on|off|inherit
/responder shadow on|off|inherit
/responder shadow global on|off|inherit
/responder assignments [list|pause|resume|delete]
/responder help
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
`status` says what Responder is doing in this channel and why. `proactive` and `shadow` change what
the channel is read for. Those are the controls an operator needs when a room will not stop talking
and the ordinary conversational path is the thing that is broken.

`assignments` is the fifth, and what is left of it belongs to the same argument: reading a channel's
standing grants and taking one back are what an operator reaches for when Responder itself is the
problem. Its `create` verb did not belong, and it left on 2026-08-15. A standing assignment is
scoped authority to open pull requests without a per-action click, and `create` asked an operator to
compose that as six `key=value` bounds and confirmed nothing but their own typing — a miscounted
`paths=` was a repository-wide grant that read as a narrow one. Asking in words now produces an
`offer_assignment` operation, and the host answers with a card stating the NORMALIZED bounds it
would store: repository, change class, daily budget, expiry, path globs, signal. Nothing exists
until the button is pressed, the click re-authorizes and re-reads the recorded offer, and what it
creates is still shadowed — the grant is evaluated by the real gate and opens nothing until that
flag is cleared as a separate decision. The typed verb answers with a pointer to that conversation.

Everything else moved to a surface that can reach further than the composer can. A removed verb
answers with the one line naming where it went, plus the whole of what is left. It does not answer
"unknown subcommand": an operator who typed a verb that worked last week did not misspell it, and
the capability still exists somewhere.

| Typed | Where it lives now |
| --- | --- |
| `incidents`, `work`, `commitments` | App Home's **In flight** and needs-you rows, the web control plane, or ask in the channel |
| `memory`, `preferences`, `rules`, `schedules` | App Home and the web control plane manage them; creating one stays conversational and is confirmed on a card |
| `feedback` | Say it. Feedback is recorded from what was said |
| `timeline`, `evidence`, `handoff`, `postmortem` | The **Record** row on the pinned incident or task card |
| `update`, `changes`, `review`, `publish`, `stop`, `close` | The buttons already on the pinned card, or ask in the thread |
| `extend` | Nothing. Responder allocates session capacity automatically |
| `turn-limit` | a worker execution bound, which is a deployment change |
| `assignments create` | Ask for the standing work in words; the `offer_assignment` card shows the normalized bounds and grants nothing until confirmed |

Slack does not provide application-defined autocomplete for text after a slash command, so the
manifest carries one short static usage hint and the whole guide lives behind `help`. The hint names
the four emergency verbs only, because it is a picker and not a catalogue. Running `/responder` with
no arguments returns the full guide: every verb that exists, one line on why there are so few, and a
read-only button for channel status.

No phrase table sits beside it. A keyword router used to rewrite plain operator messages into slash
subcommands, and it read every message in a proactive channel: "shadow traffic is on the new
cluster, ignore it" turned the channel silent, and "hey bob what are you working on?" posted the
commitment card at the room. Free text is now classified by the model and executed by the host, and
`@Emisar reconfigure this channel` is the one request still read from text — it has to survive the
model being unavailable, and it is read only when Responder is addressed.

`status` is the private form of the structured effective-settings view the welcome uses:
Conversations, Alerts, Repositories, Default repository, Incident invitations and Observation mode,
with a context line naming where the effective value came from (defaults, who saved the channel
setup, a `/responder` override, an incident room) and a **Configure channel** control that opens the
Q&A in the welcome thread. A settings question addressed to Responder in a channel — "what are
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

## Controls

Card buttons change with state rather than presenting actions that cannot succeed. Publication,
stop, close, and discard buttons may remain visible to make the operator handoff obvious, but the
host rejects them for nonoperators before any repository or session mutation:

- provisioning or holding: **Close incident**;
- active turn: **Stop current run**;
- waiting for input: **Ask agent for update** and **Close incident**;
- reviewing or publishing a draft PR: the card activity names the current publication stage,
  keeps any existing **Open PR** link, and hides review, publish, update, and
  close controls until the attempt finishes. Rendering this progress does not wait for another
  Coop change inspection;
- transient publication failure: the card shows the bounded last error, preserves
  any existing **Open PR** link, and offers **Retry publication** for that exact recovery
  generation;
- push or pull-request identity conflict: automatic retry stops. When Responder proves an exact
  App-owned PR and observed head, the card preserves **Open PR** and offers **Review latest state**
  plus **Discard candidate**. Without that remote identity, only the local **Discard candidate**
  action is available;
- stale draft PR: **Review latest state**, **Open PR**, **Check delivery**, and
  **Discard candidate** render from durable publication state without waiting for a fresh Coop
  inspection. Review latest state invalidates the prior approval and review, records the exact
  observed GitHub head, reruns Coop review, and can update the same PR only with a
  `--force-with-lease` compare-and-swap against that observed head;
- published draft PR: **Open PR** and **Check delivery** remain available independently of a
  transient Coop inspection failure;
- safety-ceiling blocked: **Close incident** and an action-needed explanation naming
  `coop.turn_limit`, saying plainly that raising it needs a deployment change;
- closed: read-only record controls only; otherwise no controls.

- **Ask agent for update** requests fresh verified facts, hypothesis, changes, blockers, and next
  action.
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
- A confirmed coding task carries its own draft grant. When the person who confirmed the task named
  this repository and the exact reviewed candidate came from that task's work, Responder opens the
  draft pull request itself: the card says it is opening the draft and offers no publication click,
  because a click could not change the candidate, the repository or the scope. Revoking the
  confirmation, confirming for a different repository, or a task with no repository leaves the
  candidate at **Create draft PR** for a person. The grant is publication only — merge, deployment
  and any other repository stay separate decisions — and an operator's **Discard candidate** is the
  last word on publishing that candidate.
- **Create draft PR** explicitly approves the retained review and its verified complete,
  content-addressed patch. The publisher reproduces that exact approved tree in an isolated
  checkout and publishes only a lease-protected Responder branch, using the configured GitHub
  App repository binding. On a blocked candidate whose checks could not finish, the same control
  offers an explicitly unverified draft: its confirmation names the repository and the check that
  never ran, and says that a draft waives nothing and neither merges nor deploys.
  After publication the task shows **Open PR** and **Check delivery**. Responder polls GitHub for
  check and merge transitions without occupying a model turn. Checks that fail on that exact head
  return the task to in-scope correction once, without a click and without widening the task; a
  hard deadline, a head that moved outside the publication, a close and a merge stay history for a
  person. After merge, matching deployment and
  Terraform app messages from other watched channels return to the original task thread only when
  the source message contains that publication's exact PR, branch, head SHA, or merge SHA. Loose
  topic, repository-name, and timing matches are rejected. An exact reference activates this
  correlation path even when ordinary proactive participation is off in the source channel; other
  app messages retain the channel's configured behavior. The poll interval and post-merge
  correlation window are configured under `github`; **Check delivery** refreshes GitHub state
  immediately. These controls cannot merge or deploy.
- **Stop current run** cancels only the active agent turn. The session, queue, and fork remain.
- **Close incident/task** closes the Coop session. Clean zero-change or durably published workspace
  state is reclaimed after the configured grace period; dirty or unpublished changes are retained.
- **Discard retained work** appears only on a closed engineering task with unpublished changes. Its
  confirmation authorizes Coop to delete clean committed work after an exact discard-plan check.
  Dirty uncommitted files are still refused.

Every work card's single overflow menu includes **Work record**. It opens a compact second-level
directory with **Timeline**, **Evidence**, **Handoff summary**, and **Postmortem draft**. This keeps
the primary card to one clearly owned menu while staying below Block Kit's five-option ceiling.

**Timeline** presents the chronological remediation record: alerts, agent runs, operator and
lifecycle events, Emisar approvals and terminal run results, and draft-PR publication. It derives
these entries from their canonical rows rather than copying them. **Evidence** shows the latest
source ledger and material unknowns. **Handoff summary** prepares an evidence-backed shift summary.
**Postmortem draft** regenerates the post-incident draft that closing also posts, including after
the incident has closed; it does not invent impact, root cause, owners, or corrective actions. All
four are host-rendered from the stored record — the model never writes a timeline.

These four were slash subcommands. A button carries the work it belongs to in its own value, so a
task thread can ask for its own handoff; the slash spelling resolved an incident by channel and
could not name a thread at all.

Routine evidence-backed replies lead with the concise conclusion and use plain professional
language instead of making the reader decode internal architecture, schemas, or workflow terms.
Necessary technical terms are explained when first used. Simple explanation, summary, and rephrase
requests reuse established conversation context unless the user asks for a fresh check or the prior
context is not enough. The footer describes saved supporting findings and assessed system areas in
ordinary language instead of dumping the source ledger into the conversation.

Emisar may use brief, understated humor in relaxed, successful, or explicitly playful conversation,
after giving the useful answer. Humor is optional and follows the team's tone; silence is better than
a forced joke. Incident response, customer impact, failures, security, approvals, access problems,
risk, and uncertain operational states remain straightforward. Humor never appears in evidence,
memory, titles, controls, approval text, timelines, or technical identifiers, and never targets a
person or their mistake.

Automatic, inferred, and model-proposed operational mutation is not exposed through Slack. In any
Slack conversation, a configured operator can directly request one exact operational action.
Responder submits it only through Emisar; no incident room is required. If Emisar requires
approval, the current conversation receives an **Approval required in
Emisar** card with the exact action, immutable runner and pack references, expiry, and a **Review
approval in Emisar** link. Opening the link is navigation, not approval; no action has run, and the
decision remains in Emisar's authenticated console and audit trail.
There is no text spelling of a control. An unadvertised `!respond <verb>` router used to read every
message in a thread carrying an incident and match eight verbs against it; it was removed on
2026-08-15. The pinned card above the thread carries stop, publish and close as buttons that
name what they do and refuse the people who may not press them, and a slash command run from the
composer cannot select a thread at all.

No message executes a control. A message such as “maybe stop after this” — or “!respond stop”, or
anything else — is an operator turn, not a cancellation.

## Authorization

Workspace membership alone does not grant operational authority. Incident steering, incident-offer
approval, durable behavior, schedules, and operational mutations require both:

- the Slack user ID is listed in `slack.operators`;
- Slack reports a current full member in `slack.team_id`.

Bots, app users, deleted users, guests, restricted users, strangers, and external Slack Connect
members cannot steer an incident session. Foreign-source channel events are dropped before
persistence. External apps are accepted only as untrusted classification evidence in explicitly
watched channels; they cannot invoke incident controls, select the repository or policy, or join
the resulting incident conversation. Coop and Emisar policy remains authoritative for any access
available to the triage session.
Only configured full-member operators can approve a watched-channel incident offer.
Denied actions are audited and receive a short explanation in the incident thread when possible.
The room-wide listening behavior does not weaken this boundary: only configured, authenticated
operators become Coop conversation turns.

The same operator and active full-member checks protect every `/responder` command. Slash command
text is parsed by the host as an exact command; it is never sent to the model.

Engineering tasks deliberately use a different boundary. Any active full member of the configured
workspace may confirm a channel-repository-bound task offer, collaborate in its source thread, and
use its non-destructive task controls. A configured operator must publish, stop, close, or discard
work. Guests, bots, restricted users,
strangers, and external Slack Connect members remain denied. Task authority never grants incident
control, durable behavior changes, scheduling, infrastructure mutation, merge, deployment, or
signing authority.

Buttons are also bound to the incident ID, channel, and root message timestamp. Stale or copied
controls are rejected.

## Failure behavior

Once a root card exists, incident failures are visible there and in accessible fallback text. A
failed or cancelled turn posts a concise thread message explaining what stopped, that the fork and
evidence remain, and how to continue. Failures before channel or root creation remain visible
through `responder status`, `responder failures`, metrics, and service logs. Manual capacity
rejection is also posted in the summon thread.

Active-session capacity puts an admitted incident into holding. The separate open-incident limit
rejects new occurrences before channel creation; webhook work remains retryable and manual summons
receive a direct explanation. Webhook admission remains durable during a temporary Slack or Coop
outage, while `/readyz` reports the disconnected dependency.

Closing never archives the channel or merges work. It schedules ownership-checked retention;
automatic cleanup refuses dirty and unpublished committed changes.
If a human archives or deletes an incident room, Slack's lifecycle event is persisted before
acknowledgement. An open incident becomes blocked, new turns and room writes stop, and the Coop
session, isolated fork, channel identity, and audit records remain. Unarchive events restore the
room. A missed `channel_not_found` response marks the room unavailable, not definitively deleted.
