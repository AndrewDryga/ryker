# Slack experience

## Message contract

Every operational message must stand on its own for an operator who has not read the configuration
or implementation. It should answer, in this order:

1. **What happened or what is true now.**
2. **What that means for Responder's observable behavior.**
3. **Where the behavior applies and what takes precedence.**
4. **Whether work, code, infrastructure, or incident state changed.**
5. **What the operator can do next, using the exact Slack command when appropriate.**

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

Configured operators can converse anywhere in the incident channel without an `@mention`.
Responder admits ordinary top-level messages and thread replies, keeps them in the same Coop
conversation, and follows the operator's current location: a channel message gets a channel
response and a thread reply gets a reply in that thread. An operator may say `switch to a thread`
or `back to the channel`; Emisar acknowledges the move at the new location before continuing.
Mentions and replies to the pinned card are explicitly direct; for ambient room conversation, the
agent may stay silent when a human teammate would have nothing useful to add. Thread-scoped
engineering tasks are the deliberate exception: their authorization and working copy remain bound
to the source thread. Each accepted operator message is one ordered Coop request. Responder
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

When enabled, Slack's native assistant status appears immediately after accepted operator input and
cycles through semantic milestones such as topology mapping, live Emisar checks, source
reconciliation, coverage assessment, and response preparation. Slack clears it only when the reply,
silence decision, incident handoff, or user-facing failure has been handled. Parked and blocked
state remains on the card rather than using a misleading persistent typing indicator.

## Agent surfaces

App Home shows durable open-incident, active-session, failed-work, incident-history, saved-memory,
and active-commitment counts plus the current incident rooms, work Emisar owes the team, compact
channel situations, and bounded memory controls. The Agent Messages tab offers suggested prompts
for infrastructure health, alert explanation, and open work. A direct message always starts
read-only triage and does not require proactive mode or an `@mention`.

The **Investigate message** shortcut runs the same ordered read-only triage against a
selected message and replies in its thread. Direct messages and shortcuts do not create incidents
merely because they identify a problem; they can offer the same explicit incident button.

An explicit repository-change request can produce a **Start engineering task** button. Until a
configured full-member operator confirms it, no writable session or fork is created. Confirmation
posts a durable task card in the same Slack thread and creates an isolated Coop working copy. The
initial task turn may edit, validate, and commit repository files under Coop policy, but cannot
merge, push, deploy, sign, or mutate infrastructure. Ordinary replies in the source thread continue
the same task session without an `@mention`; unrelated channel messages never enter it. Slash
commands cannot identify a thread, so task controls live on the task card.

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

### Conversational channel setup

Responder periodically reconciles the bot's authoritative Slack channel memberships. An
absent-to-present transition queues one durable setup session for that channel and posts the first
question. This is intentionally not based on `member_joined_channel`: Slack only sends that event
after the bot is already a member, so it cannot report the bot's own initial join. Membership state
survives restarts, suppresses duplicate cards, and makes remove/re-add start a fresh setup. The
first card offers **Use safe defaults**, **Be proactive**, and **Customize**. The first two save a
complete safe configuration without forcing a wizard: deployment-default repository, in-place
alert replies, and no additional incident invitees. Customize asks one question at a time:

1. participation: mentions only, proactive, or shadow;
2. code context: one exact configured repository or repository-set key;
3. app alerts: reply in place, offer an incident, or automatically create one;
4. additional incident audience: no one beyond configured operators, or validated Slack members
   and user groups.

Every closed typed choice is rendered as a Slack button; context choices are generated from the
configured repository and repository-set catalog. A repository set identifies one primary
writable/publishable repository and an operator-owned Coop policy containing pinned read-only
companions. Configured operators are always invited to incident rooms, so the
audience step offers **No additional invitees** and accepts member or user-group mentions for any
additional audience. Natural-language answers remain available for operators who prefer
conversation. Each question records its top-level message or thread root.
Replies are admitted only from those known setup threads, while top-level answers are accepted only
from a configured operator during the active 30-minute session. Other channel messages continue
through normal routing. Ambiguous answers produce a scoped clarification and do not advance the
draft.

The setup follows the operator rather than forcing one presentation. Answer in the channel and the
next question appears in the channel; answer in a setup thread and it stays in that thread. Saying
`switch to a thread`, `continue here so we do not pollute the channel`, or `back to the channel`
re-renders the current question at that location without changing the typed draft. All later
controls are bound to the durable setup ID, channel, actor, current step, revision, and expiry, so a
stale button or unrelated thread cannot advance the session.

The confirmation card says **Nothing is saved yet**, shows every typed value, names its expiry and
safety boundary, and carries only a stored setup ID. **Save configuration**, **Start over**, and
**Cancel** re-read the durable session, workspace, actor, channel, thread, revision, and expiry
before acting. Saving affects listening, repository context, Slack-app alert escalation, and room
invitations only. It never authorizes repository changes, Emisar approvals, deployments, or
infrastructure mutations.

Channel setup is more specific than the workspace override and deployment default, while an
explicit per-channel `/responder` override remains the emergency override. Confirmed channel
deletion removes its membership observation, setup sessions, and saved configuration.

`slack.watch_channels` is the static default list for shared operational feeds such as
`#infra-alerts`. Responder must be invited to every configured channel, and `responder doctor`
checks membership. The list supports public and private channels and may overlap
`slack.summon_channels`. The summon list is a static preflight expectation; it does not restrict
explicit mentions in other channels where the bot has been invited.

Operators can change proactivity without editing the file or restarting Responder:

```text
/responder proactive on
/responder proactive off
/responder proactive inherit
/responder proactive global on
/responder proactive global off
/responder proactive global inherit
```

The effective setting uses the explicit channel override first, then confirmed channel setup, then
the workspace override, then the static `watch_channels` default. Global `on` watches all channels where Responder is invited and
receives message events. A per-channel `off` can opt out of that default, and a per-channel `on`
can opt in while the workspace default is off. `inherit` deletes the corresponding durable
override. Responder verifies current channel membership before accepting a per-channel `on`.

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
evidence route, or entity relationship correction. Responder answers normally and adds a
host-owned confirmation button that states the scope and expiry. Until that button is confirmed,
nothing is stored. A later correction replaces the same logical entry. App Home lists active saved
memory with individual forget confirmations. Saved entries are never presented as live health or
authority; every future investigation must verify them against current repositories and live tools.
Same-channel evidence can be recalled from the existing evidence ledger, while evidence from other
private channels is never injected.

Behavior memory is a separate typed facility. An explicit request such as `when I ask about
infrastructure health, always do a deep check` can offer a `health_check_depth=deep` preference.
An explicit request such as `when you see a Terraform plan here, report its main diff and red
flags` can offer a channel standing rule. The model may select only a supported preference value or
trigger/action pair; Responder never persists the original prose as an executable instruction.

Every behavior offer is a host-rendered confirmation card. It states the normalized behavior,
scope, expiry, source filter when applicable, and the boundary that it remains read-only and cannot
create incidents, edit files, deploy, approve, or mutate infrastructure. Confirmation requires a
configured full workspace operator. That operator may make an explicit behavior setup request in
any channel where Responder is invited, even if ordinary mentions and proactive triage are disabled
there. This exception admits only the typed setup turn; it does not turn the channel into a summon
channel. Preferences resolve in operator, channel, repository, then workspace order. Rules are
channel-scoped and match only Terraform plans, deployments, or operational alerts from the
configured `human`, `app`, or `any` source.

An enabled standing rule can admit only its matching message type when broad proactive triage is
off. The resulting turn uses the current channel transcript and available read-only tools, shows
native pending progress, and must reply in the source message's thread. It cannot silently convert
the message into an incident. The channel queue preserves Slack timestamp order and a durable
rule/source-event key prevents duplicate execution after redelivery or restart. Shadow mode records
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
cannot modify infrastructure or files from this shared-channel session, and the host accepts only
one validated decision:

- stay silent for noise, routine success or recovery notifications, duplicates, and ambient
  conversation;
- add one context-appropriate Slack reaction when acknowledgement is useful but a prose reply would
  interrupt the team;
- reply concisely where the human is speaking when they address Responder and channel context or a
  bounded read-only investigation provides enough evidence;
- attach an `Open incident room` confirmation when a human-reported problem may benefit from
  coordinated investigation, without creating anything yet;
- attach a `Start engineering task` confirmation when an operator explicitly requests repository
  changes, without weakening the shared channel's read-only boundary;
- open a normal dedicated incident automatically for a credible unresolved monitoring-app alert, or
  directly when a human explicitly asks to open, create, start, or declare an incident.

An ordinary human health question is never sufficient host authorization for automatic incident
creation, even if the model identifies an unhealthy component. The offer button explains that no
incident exists yet and requires a configured full-member operator. The original Slack input stores
the offered title durably, so a restart does not change what the button approves. Repeated clicks are
idempotent.

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
same durable per-channel order as messages, invalidate cached Slack history, and appear in the next
conversation turn alongside the current bounded reaction counts and reacting member IDs. A reaction
does not start an agent turn or produce a reply by itself. Removed reactions are retained only as
historical context and are not treated as current agreement. No emoji reaction can authorize an
incident, approval, repository change, deployment, or infrastructure mutation.

Engineering-task offers follow the same authorization, source-message binding, restart durability,
and idempotency rules. Their source threads use task-specific cards and lifecycle copy rather than
presenting repository work as an alert incident. Dedicated Slack rooms remain reserved for incident
coordination.

An approved or permitted incident decision retains the original Slack message as evidence,
acknowledges the source thread, and enters the same channel, root-card, isolated-fork, and
policy-controlled investigation workflow as webhook and manual incidents. Every admitted watched
message is one accepted request in its channel's ordered triage session. Responder extends exhausted
watched and incident sessions automatically up to the effective `coop.turn_limit`. Operators can
inspect or change that safety ceiling with `/responder turn-limit`; Coop policy and service-wide
limits remain authoritative.

An explicit mention in a summon-enabled watched channel is routed through the same read-only triage
session and gets responder-targeting priority. Only explicit incident wording bypasses
classification and starts a manual incident. Slack also emits the same mentioned message through
the ordinary channel-message subscription; Responder acknowledges that duplicate and admits only
the `app_mention` event.

## Slash command

The shipped Slack app registers one command with deterministic subcommands:

```text
/responder status
/responder work
/responder commitments
/responder incidents
/responder incidents open [page]
/responder incidents all [page]
/responder proactive on|off|inherit
/responder proactive global on|off|inherit
/responder shadow on|off|inherit
/responder shadow global on|off|inherit
/responder turn-limit
/responder turn-limit 100..10000|inherit
/responder turn-limit global 100..10000|inherit
/responder timeline
/responder evidence
/responder handoff
/responder memory
/responder preferences
/responder rules
/responder update
/responder changes
/responder review
/responder stop
/responder close
/responder help
```

Slack does not provide application-defined autocomplete for text after a slash command. The
manifest therefore uses a short `help | status | work | incidents | preferences | rules` usage hint instead of
putting every argument in the picker. Running `/responder` without arguments or selecting `help`
returns an interactive guide with read-only buttons for channel status, open incidents, and all
incident history.

The same handler is conversationally reachable for supported operator requests. For example,
`@Emisar how are you configured here?`, `show open incidents`, `show evidence`, `enable proactive
mode`, and `reconfigure this channel` map to the existing typed status, directory, intelligence,
setting, and setup handlers. Conversational results are posted in the request thread; slash results
remain ephemeral. Unsupported or ambiguous operational questions continue through normal
evidence-backed triage rather than being guessed into a command.

`incidents` lists open incidents newest first. Each compact entry contains the title, a native
Slack channel mention, plain-language activity, firing-alert count, incident ID, repository, and
start time. Archived, deleted, or unreachable rooms use their retained `#channel-name` plus a
plain-language lifecycle label instead of a broken channel mention. `incidents all` includes closed
history. Pagination and history use read-only buttons, private-channel access remains enforced by
Slack, and the response is visible only to the requesting operator.

`status` leads with effective behavior, explains why that behavior won the precedence chain,
describes proactive and shadow behavior, explains mention handling, translates each override layer,
and documents any incident attached to the channel. It never relies on raw values such as
`inherit`, `parked`, or `responder.yaml` to explain behavior. Proactive and shadow changes are
durable and audited. Incident-control acknowledgements
describe the requested effect and direct the operator to the pinned incident thread for the
authoritative result. Slash commands and button controls run in the control lane, so an off or stop
command does not wait behind a running agent run.

`work` and its `commitments` alias list every active request accepted by Emisar, newest first.
Each item names the request, source conversation, queued/working/finishing/blocked state, current
status, and next operator action. The list is a projection of the durable agent-run scheduler, so
restart or delivery retry cannot make promised work disappear.

`preferences` lists the effective operator, channel, repository, and workspace investigation
defaults. `rules` lists this channel's standing rules, source filters, expiry, last run, and run
count. Both directories expose state-aware enable, disable, edit, and delete controls. App Home
shows the same bounded controls for current behavior entries.

## Controls

Card buttons change with state rather than presenting actions that cannot succeed:

- provisioning or holding: **Close incident**;
- active turn: **Stop current run**, and **View diff** only when Coop reports changed
  files;
- waiting for input: **Ask agent for update**, **Close incident**, and change controls only when
  Coop reports changed files;
- safety-ceiling blocked: **Close incident**, an action-needed explanation with the exact
  `/responder turn-limit` command, and change controls only when Coop reports changed files;
- closed: read-only change controls only when the preserved working copy contains changed files;
  otherwise no controls.

- **Ask agent for update** requests fresh verified facts, hypothesis, changes, blockers, and next
  action.
- **View diff** reads Coop's typed fork summary and posts a bounded, sanitized first page in the
  task thread. **Previous page**, **Next page**, and **Refresh diff** update that same message
  instead of adding thread noise. Every page carries the complete patch digest and byte range; if
  the fork changes between clicks, Responder restarts at page one rather than combining snapshots.
  File groups show their total count and say how many paths are omitted from the compact summary.
  It does not start an agent turn.
- **Run readiness check** compares the isolated changes with the current repository, checks rebase,
  runs configured validation and policy gates, and reports whether the result is ready for external
  review. It never publishes, merges, signs, or deploys.
- **Create draft PR** repeats the readiness review, retrieves and verifies Coop's complete
  content-addressed patch artifact when the inline preview is truncated, reproduces the exact
  approved tree in an isolated checkout, and publishes only a lease-protected Responder branch.
  After publication the task shows **View draft PR** and **Update draft PR**. These controls cannot
  merge or deploy.
- **Stop current run** cancels only the active agent turn. The session, queue, and fork remain.
- **Close incident/task** closes the Coop session. Clean zero-change or durably published workspace
  state is reclaimed after the configured grace period; dirty or unpublished changes are retained.
- **Discard retained work** appears only on a closed engineering task with unpublished changes. Its
  confirmation authorizes Coop to delete clean committed work after an exact discard-plan check.
  Dirty uncommitted files are still refused.

Routine evidence-backed replies lead with the concise conclusion and record counts instead of
dumping the source ledger into the conversation.
`/responder timeline` reads durable lifecycle, operator, finding, and failure events.
`/responder evidence` shows the latest source ledger and material unknowns.
`/responder handoff` prepares an evidence-backed shift summary. Closing also posts a post-incident
draft that does not invent impact, root cause, owners, or corrective actions.

Shared-channel operational mutation is not exposed through Slack. In an existing incident, a
configured operator can directly request one exact operational action. Responder submits it only
through Emisar. If Emisar requires approval, the incident thread receives an **Approval required in
Emisar** card with the exact action, immutable runner and pack references, expiry, and a **Review
approval in Emisar** link. Opening the link is navigation, not approval; no action has run, and the
decision remains in Emisar's authenticated console and audit trail.
The exact whole-message command equivalents, including legacy and help controls, are:

```text
!respond status
!respond update
!respond changes
!respond review
!respond stop
!respond extend
!respond close
!respond help
```

`!respond extend` remains accepted for compatibility, but it only explains automatic capacity and
the `/responder turn-limit` command; it does not allocate a manually chosen number of turns.

Natural-language approximations do not execute controls. A message such as “maybe stop after this”
is an operator turn, not a cancellation.

## Authorization

Workspace membership is not authorization. Responder requires both:

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
