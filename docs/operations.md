# Operations

## Processes

Run one Coop session controller and one Responder process per state directory. They must share a
restricted Unix user in v1 because the Coop socket is mode `0600`.
Responder holds a non-blocking lock in `state_dir`; a second process exits instead of competing for
Slack and incident ownership.

In the default external mode (`coop.supervise: false`), startup order is:

1. load secrets;
2. run `responder bootstrap-coop`;
3. authenticate each policy target with `COOP_CONFIG_DIR=<bootstrap_dir> coop login <agent>@<account>`;
4. start `coop sessions serve`;
5. run `responder doctor` to validate database integrity, current Coop bootstrap content, bot
   scopes, configured operators, invite users, summon channels and watch channels, an actual
   Socket Mode WebSocket handshake, and authenticated Emisar MCP initialization plus the required
   tool catalog; it does not execute an infrastructure action;
6. start `responder serve`;
7. wait for `/readyz`.

For a one-command foreground process, configure:

```yaml
coop:
  supervise: true
  binary: /usr/local/bin/coop
  state_dir: /var/lib/responder/coop
  policies: /etc/responder/session-policies.yaml
  restart_delay: 5s
  socket: /var/lib/responder/coop/control.sock
```

Run `bootstrap-coop` and authenticate the policy targets once, then run only `responder serve`.
Responder rejects a stale private Coop projection or a socket already owned by another controller,
starts `coop sessions serve`, and waits for its readiness before authenticating Slack. An exit
before initial readiness fails Responder startup. An unexpected exit after readiness is logged and
restarted after `restart_delay`. Responder sends the managed process group `SIGTERM` and reaps it
on shutdown.

`responder doctor` also supports managed mode: it starts Coop, checks the socket and the rest of the
preflight, and stops Coop before returning. Known Slack, webhook, and Emisar secret variables are
removed from the child environment. Coop receives `COOP_CONFIG_DIR=<bootstrap_dir>` and loads the
private tool projection written by `bootstrap-coop`. Optional `coop.additional_mcp_file` and
`coop.additional_env_file` sources must be absolute, owner-private regular files. Their servers and
MCP-only environment values are merged into each turn; Responder retains the `emisar` server name
and rejects Slack, webhook, and Emisar credential overrides.

Managed foreground mode requires the Responder caller to have every permission Coop needs,
including Docker access. Keep the split units for a hardened systemd installation so the Responder
process itself does not receive the `docker` supplementary group.

Responder exits when initial database, Coop, Slack authentication, Emisar MCP authentication, or
the required Emisar tool catalog check fails. An external supervisor should restart Responder with
a bounded delay.

## Health

| Endpoint | Meaning |
| --- | --- |
| `/healthz` | the process can use its durable database |
| `/readyz` | the database responds, Slack and Coop are ready, every scheduler lane has a fresh heartbeat, and no due or running work exceeds the stall threshold |
| `/metrics` | Prometheus-format incident, delivery, scheduler queue, lease-age, heartbeat-age, and failure counters |

The webhook endpoint can durably accept work before Slack reconnects, but load balancers should use
`/readyz` when dependency-complete handling is required.

`responder status` and `responder failures` inspect the current database schema without migrating
it and do not require Slack or Coop. Stop Responder before upgrading to a binary that needs a
database migration; startup holds the process lock, creates and verifies a private pre-migration
snapshot, then applies migrations.

## Post-fix Slack replay

Use a saved Slack message to verify the complete deployed path after a fix:

```bash
responder replay slack \
  --config /etc/responder/responder.yaml \
  --url 'https://workspace.slack.com/archives/C0123/p1785652207489039' \
  --expect reply \
  --timeout 20m
```

The owning `responder serve` process must be running. The command opens the current schema without
migrating it, clones the original persisted Slack payload behind a fresh envelope and event ID,
and lets the live scheduler process it. Text, attachments, actor, channel, thread, and source
timestamp are preserved. A saved ambient human message is treated as explicitly addressed for
the replay so normal stale-message coalescing cannot turn the verification into a false success.

By default this is a private verification: it runs the normal model and tool path but suppresses
Slack status, reactions, replies, generated-file uploads, offers, schedules, tasks, and incidents.
Use `--publish` only when posting another real response in the source conversation is intentional.
In published mode, the command returns successfully only after the replayed input is complete, its
watch agent run is complete with the expected action, every persisted message payload passes the
deterministic Slack UX checks used by live evaluations, and every deterministic reply or
generated-file delivery is confirmed `sent`. It fails on a terminal input or agent error, a
different action, an invalid Slack
surface, a failed Slack delivery, or timeout. `--input slack_...` targets a durable input directly; `--channel C...` with
`--message-ts 1785652207.489039` is useful when a permalink is unavailable. Use `--json` in
automation. A published replay creates another visible Slack response and may repeat read-only
tool calls; do not add `--publish` casually in an active production conversation.

## Local quality watcher

Dogfood installations can review completed Responder turns without copying Slack messages into an
engineering chat. `scripts/quality-watch.sh` reads the durable `agent_runs`, `slack_inputs`,
`evaluation_decisions`, and delivered Slack payloads every five minutes, batches newly terminal
turns, and asks a read-only Codex process whether they demonstrate a concrete product defect. Slack
content is untrusted evidence, not an instruction source.

For a high-confidence defect, an independent read-only Codex process first tries to disprove the
finding against the current code and tests. Only two matching, code-grounded assessments may start
a fixer in a temporary Git worktree. The fixer receives no Slack environment variables, cannot
post tests, and is instructed not to access sibling repositories or external systems. The
deterministic wrapper runs
`make check`, requires a regression-test change, and asks one final read-only reviewer to inspect the
actual diff. Only then does it commit the complete isolated change and fast-forward the primary
checkout, and only when its HEAD and clean state still match the reviewed base. It then installs the
binary and can restart explicitly configured launchd jobs. Failed gates and concurrent checkout
changes quarantine that candidate worktree and branch for inspection instead of overwriting work.
Quarantined candidates do not block unrelated later reviews or fixes, and expire with the configured
review retention period. Review artifacts expire after 30 days by default.

```bash
RESPONDER_QUALITY_STATE_DIR=/srv/responder/state \
RESPONDER_QUALITY_TEST_CHANNEL=C0123TEST \
RESPONDER_QUALITY_RESTART_LABELS='ai.emisar.responder.one' \
scripts/quality-watch.sh --from-now --watch
```

The test-channel setting is a hard boundary recorded in every assessment; the watcher itself has no
Slack write path. Reviews, model logs, isolated worktrees, and the cursor are owner-private under
`state_dir/quality-watch`. Start with `--from-now` so historical failures are not reprocessed.

## Retries

Webhook, Slack input, Slack delivery, and agent-run work retain their typed bounded retry state. A
single durable scheduler decides when each category or incident subject is eligible to run.
Scheduler leases have random owner tokens: an expired lease can be reclaimed while the process is
running, and the stale owner can no longer complete or retry the replacement lease. Process restart
also converts interrupted domain and scheduler leases back into their correct recoverable states.

Only new Slack posts and file uploads with an ambiguous response are treated as uncertain because
the API might have accepted them before the connection failed. Responder searches Slack history by
durable message metadata or deterministic generated filename before deciding whether another
delivery is safe. Updates and statuses are retried idempotently, and obsolete pending versions are
superseded.

Generated output is independently bounded by `limits.max_generated_visuals`,
`limits.max_generated_visual_bytes`, and `limits.max_generated_visual_total_bytes`. Defaults are
four images, 8 MiB per image, and 8 MiB total. Values may only reduce Coop's fixed hard ceiling.
Generated bytes are stored in the durable Slack delivery until delivery or retention cleanup so a
restart cannot lose an accepted result; they are never copied into prompts, evidence, or memory.

Coop requests reuse the same idempotency key and frozen request body. Non-retryable Coop conflicts
stop the action and remain visible; they are never rewritten with a guessed revision.

Watched Slack feeds use one current Coop session generation per configured channel. Messages are
serialized by Slack message timestamp within each channel and can proceed independently across
channels.
`coop.prewarm_conversation_sessions` prepares the bounded conversation lane and its authenticated
ACP execution environment in the background for up to 20 recently active or statically configured
channels. Recent durable conversation lanes take priority, so dynamically joined Slack channels
remain warm across Responder restarts. The default is four. Each warmed lane uses a normal Coop session; the operator-owned Coop policy must
also opt in with `warm_idle_timeout`. Coop reuses the same native model session and boxed ACP process
until that idle lease expires, then removes the process and projected credentials. Session rotation,
retention, provider-account selection, and policy enforcement are unchanged.
`slack.watch_settle_delay` requires a quiet period after the newest queued message before
classification; the default is 350 milliseconds. The request freezes the freshest ordered context
again immediately before model submission, so this delay is only a short burst debounce rather
than the source of conversation ordering. `slack.watch_context_messages` freezes the latest
chronological channel transcript into each triage request; the default is 20 and the allowed range
is 10 through 50. Once classification queues an agent run, the source Slack input is complete and
cannot exhaust retries during a long model call. The agent run takes its own lease and freezes the
freshest ordered context immediately before submission. One run executes per conversation, while
later inputs can still be admitted and included in subsequent context. A delayed event older than
an already completed decision is retained and audited but cannot produce an out-of-order reply.
Slash commands and button controls have priority over ordinary conversation delivery.

Socket Mode does not replay events emitted while Responder is offline. On startup, Responder reads
the bounded recent history of channels where it is present and proactive, shadowing, or following a
standing app-message rule. Missing external-app messages are admitted through the same canonical
message identity as live events, so catch-up cannot duplicate work already received over Socket
Mode. `slack.startup_history_window` controls the lookback (15 minutes by default, `0s` disables it,
and 24 hours is the maximum). Human conversation is never replayed by startup catch-up.

Slack apps can update an existing notification as work moves from planning to applied, errored,
discarded, or another terminal state. Slack does not reliably deliver every attachment-only edit as
an Events API message. Responder therefore re-reads only external-app messages that visibly describe
an in-progress lifecycle. `slack.external_message_reconcile_interval` controls the polling interval;
`slack.external_message_reconcile_window` bounds how long the exact message is followed. A changed
message is admitted as a new ordered input and evaluated normally. This is lifecycle synchronization,
not Terraform-specific classification.

## Scheduled tasks

A configured operator creates a schedule by mentioning Emisar with a task and time, for example:

```text
@Emisar in 4 hours, check whether the rollout is healthy and summarize any blockers
@Emisar every Monday at 09:00, prepare a production health review
@Emisar on day 1 of each month at 10:30 Europe/London, summarize SLO and incident trends
```

Responder asks the model only to normalize an explicit request into a typed offer. The host checks
the repository, recurrence, timestamp, IANA timezone, interval, task size, expiry, operator, and
credential-like content. An operator must click **Schedule this** before a row is created. Use
`/responder schedules` in the destination channel to run, pause, resume, replace, or delete tasks.

One-time schedules require an exact future instant. Interval schedules may omit a start instant and
then begin after one interval. Daily, weekly, and monthly schedules use the operator's Slack profile
timezone when none is stated; Responder computes each next local occurrence so DST transitions are
handled by the Go timezone database. A monthly day that does not exist is skipped rather than moved.

Each due occurrence is inserted in `scheduled_task_runs` before its synthetic Slack input and normal
triage `agent_run` are queued. The `(task_id, scheduled_for)` key prevents duplicate dispatch after a
restart, and an active-occurrence check prevents overlap. `catch_up: latest` runs one current catch-up
after downtime; `skip` records an occurrence as missed when it is older than
`limits.schedule_misfire_grace`. Current Coop and Emisar policy is re-evaluated on every run. A
schedule cannot cache a credential, approval, or permission, and a requested mutation can still
pause for authoritative Emisar approval.

The scheduler limits are `limits.max_scheduled_tasks`, `limits.max_schedules_per_channel`, and
`limits.schedule_misfire_grace`. Deleting a Slack channel deletes its schedules. Removing a
repository binding prunes its schedules during maintenance. Expired tasks and terminal occurrence
records age out with operational retention.

## Long-running work progress

Accepted model-backed work has a durable episode and remains an active commitment until it reaches
a terminal state, an exact blocker, or an Emisar approval hold. Responder refreshes native Slack
status and appends a bounded progress event while a run remains active. Configure the quiet
interval with `limits.episode_progress_interval` (default `2m`, allowed `30s` through `1h`). This is
an observability interval, not a deadline: deep investigations continue until their coverage and
completion contract is satisfied or the run's normal retry policy is exhausted.

Progress events report phases and material milestones, never hidden reasoning or raw tool output.
Slack controls stay on the control lane while long-running Coop turns remain on the background
lane, so an approval, stop, or configuration action is not blocked by investigation work.

An exact blocker is an external boundary, not a remaining investigation step. The structured result
records its kind, attempted evidence routes, material gaps, and external unblock action. Responder
retries a deep turn that merely proposes more read-only queries, while a genuine blocked result stays
open and renders those details explicitly in Slack.

Bot channel joins create a durable `configuration_sessions` row with a 30-minute expiry. The setup
root timestamp, initiator, current question, typed draft, revision, and status are stored before
later answers can advance it. Thread answers must match the root; top-level answers require a
configured full-member operator. Saving creates or replaces one `channel_configurations` row and
increments its revision. Explicit Slack channel overrides remain higher priority; confirmed setup
then precedes workspace and deployment defaults.

The saved app-alert policy applies only to authenticated Slack app messages. Human health questions
never auto-create incidents. Incident rooms created from that source channel invite configured
operators and deployment invitees plus the saved users and the current Slack members of saved user
groups. A missing or inaccessible group blocks room preparation visibly rather than silently
dropping responders. Channel deletion removes configuration and active drafts. Maintenance prunes
expired and terminal setup sessions with the other bounded operational state.

The host does not accept a human health question as authorization to create an incident. Human
triage can reply with findings and persist an incident offer; a configured full-member operator must
confirm its `Open incident room` button. Explicit human incident requests and credible unresolved
external-app alerts may create directly. Incident creation is keyed to the original Slack event, so
button retries and repeated clicks cannot create duplicate incidents.

The shared triage session also cannot edit repository files. For an explicit repository-change
request, the agent returns a durable engineering-task offer instead of telling the operator to
start another client session. A configured full-member operator must confirm **Start engineering
task**. The resulting room uses an isolated writable Coop fork and task-specific Slack copy; file
edits, tests, and commits are permitted by the dedicated prompt and remain bounded by the
repository's Coop policy. Merge, push, signing, deployment, and infrastructure mutation remain
forbidden.

### Repository sets

Use a repository set when one investigation needs declared context from several independent Git
repositories. Responder's `repository_sets` entry names the primary configured repository and the
Coop policy:

```yaml
repositories:
  infrastructure:
    display_name: Infrastructure
    coop_policy: infrastructure-observe
    conversation_policy: infrastructure-conversation
    path: /srv/repos/infrastructure
repository_sets:
  platform:
    display_name: Platform
    primary: infrastructure
    coop_policy: platform-observe
    conversation_policy: platform-conversation
```

`conversation_policy` is optional. When configured, direct conversational messages use that bounded
Coop policy and its authenticated provider account. The policy can expose the same read-only
repository and MCP tools as the investigation policy; the model decides which evidence it needs.
Requests that require a writable isolated fork still use the separately confirmed engineering-task
path. Omitting `conversation_policy` preserves the single investigation-lane behavior.

The Coop session policy controls the provider, model, reasoning effort, and authenticated account:

```yaml
policies:
  platform-observe:
    target: codex:gpt-5.6-sol/xhigh@oncall
  platform-conversation:
    target: codex:gpt-5.6-terra/low@oncall
```

The target syntax is `agent:model/effort@account`. Responder does not silently override it. A
conversation policy is the fast bounded lane for ordinary replies; current-state questions,
standing-rule alerts, and other tool-backed work escalate to the repository or repository-set
`coop_policy`. Edit the owner-private session policy to change either lane, then restart Responder's
managed Coop so new or rotated sessions bind the updated target. There is intentionally no Slack
command that lets a channel member change the provider account or model policy.

The corresponding owner-private Coop policy is the only place that binds companion aliases to host
paths:

```yaml
policies:
  platform-observe:
    repository: /srv/repos/infrastructure
    companions:
      - name: backend
        repository: /srv/repos/backend
      - name: control-plane
        repository: /srv/repos/control-plane
    # target and resource limits omitted here
```

At session creation Coop pins every repository to its current commit. The primary gets the normal
isolated writable fork. Companions get detached, clean snapshot worktrees mounted read-only at
`/coop/repositories/<alias>`. Public session data contains only the alias, in-box path, and commit;
host paths remain inside Coop. Review, GitHub publication, and cleanup apply to the primary tree,
while discard also removes every owned companion snapshot. A repository set supports at most 32
companions.

Keep the Responder set's `primary` and the Coop policy's `repository` aligned. This deliberate
two-part declaration separates publication ownership from local mount authority: Slack and model
output can select only the configured set key and can never introduce a path or mount.

Compact channel situation stores channel purpose, situation summary, current goal, active topics,
verified topology, decisions, open loops, unresolved questions, and evidence references.
`coop.watch_session_max_turns` defaults to 40 and
`coop.watch_session_max_age` defaults to 24 hours. Responder rotates only an idle session, preserves
the compact memory, and uses a generation-specific idempotency key. Rotation bounds provider
context without discarding operational corrections.

Operator-confirmed durable memory is a separate bounded facility. Responder offers it only after a
configured operator explicitly asks to remember or save an alias, channel repository binding,
evidence route, entity relationship, or open-ended collaboration guidance.
The button shows the scope and expiry before writing. Entries are unique by scope, subject, and
predicate, so a correction replaces the prior value rather than creating a duplicate. App Home
shows workspace-visible and operator-visible entries; `/responder memory` shows the exact entries
visible in the current channel, memory capacity, recall activity, and consolidation status.
`/responder memory review` presents stale or duplicate candidates one at a time. No review mutates
memory until a full workspace operator chooses keep, merge, or forget. Forgotten values are
removed; audit records retain only the entry ID, scope, predicate, actor, and outcome. Replacement
history stores hashes rather than old memory values.

`limits.max_memory_entries` and `limits.max_memory_entries_per_scope` bound active memory. Entries
expire after 7, 30, 90, or 365 days and maintenance deletes expired values. A confirmed Slack
channel deletion immediately removes entries scoped or visible only to that channel. Retrieval is
an exact scope and visibility match; Responder does not search another private channel. Saved
operational memory remains a potentially stale hint: live tools, current repository content, and
deployment configuration take precedence. Guidance is advisory model context; the current request
and host safety policy take precedence, and guidance cannot trigger work, count as evidence, or
authorize incidents, changes, approvals, or mutations. Personal workspace guidance is visible only
to its operator and can follow them across channels. Recent source-attributed evidence is retrieved
from the existing same-channel evidence ledger and is not duplicated into memory.

The background memory pass runs every `memory.dreaming_interval`. It compacts conversation
summaries older than `memory.compact_after` into weekly rollups. Public conversations are grouped by
repository; private conversations are grouped only within their Slack channel. Each rollup retains
bounded goals, topics, open loops, topology, decisions, unresolved questions, and source references.
The source rows are deleted only in the same transaction that saves their rollup. At
`memory.pressure_percent` of `memory.max_conversation_summaries`, compaction accelerates toward
`memory.target_percent` but never compacts the latest hour. Rollups are capped by
`memory.max_rollups` and expire on the normal conversation-memory schedule.

Operator-confirmed entries remain outside this automatic synthesis. Recall counts and timestamps
drive review suggestions after `memory.review_stale_after`; exact duplicate guidance is also
flagged. Reviews are proposals, not background edits. This follows the continuity, freshness, and
reviewability goals described in OpenAI's
[Memory and new controls for ChatGPT](https://openai.com/index/chatgpt-memory-dreaming/) without
making remembered prose executable or authoritative.

Operator-confirmed behavior is stored separately from factual operational memory:

- Preferences use the closed catalog `health_check_depth=quick|standard|deep`,
  `response_detail=concise|standard|detailed`, and
  `response_location=follow_context|prefer_thread|prefer_channel`. Effective precedence is
  operator, channel, repository, then workspace; response location excludes repository scope.
- Standing rules use the closed trigger/action pairs
  `terraform_plan/review_terraform_plan`, `deployment/verify_deployment`, and
  `operational_alert/triage_alert`. Each rule is channel-scoped and restricts its source to
  `human`, `app`, or `any`.

Natural-language requests only create inert offers. The confirmation card shows the normalized
entry, scope, expiry, and safety boundary; a configured full workspace operator must confirm it
before the host writes state. `/responder preferences` and `/responder rules` provide enable,
disable, edit, and delete controls. Editing asks for a replacement natural-language request because
the replacement must pass the same typed parser and confirmation boundary. Confirmed guidance can
enter model context as advice, but arbitrary prose is never an executable trigger or authority. An
explicit typed setup request from a configured operator is
admitted in any channel where Responder is invited; ordinary mentions in that channel still follow
the summon and proactive settings.

Rules use deterministic host matching before the model runs. They can admit their one typed message
class while broad proactive triage is off, but remain read-only, reply in the source thread, and
cannot create an incident, edit files, deploy, approve, or mutate infrastructure. Channel input
leases preserve Slack timestamp order; the unique `(rule_id, source_input)` execution record makes
redelivery and retry idempotent. `limits.max_preferences`,
`limits.max_preferences_per_scope`, `limits.max_standing_rules`, and
`limits.max_rules_per_channel` bound active and disabled unexpired entries. Maintenance removes
expired entries and run records. Confirmed channel deletion removes channel behavior immediately,
and repository reconciliation removes orphaned repository preferences.

`responder.yaml` remains the deployment default. `/responder proactive` writes audited overrides
to the owner-private database. Resolution order is channel override, workspace override, then the
static `slack.watch_channels` list. `inherit` deletes an override instead of copying a stale
default. `/responder turn-limit` stores capacity-ceiling overrides in the same table with the same
precedence. `/responder shadow` stores dry-run evaluation overrides with the same precedence;
shadow mode still performs read-only classification and evidence collection, but cannot post,
offer, or create an incident. Back up these settings with the rest of `responder.db`.

Proactive turns return an addressee and four `0..3` interruption dimensions: urgency, confidence,
novelty, and ownership. The host sums those dimensions after parsing. Ambient replies below
`slack.proactive_reply_attention_threshold` and reactions below
`slack.proactive_reaction_attention_threshold` are converted to silence; defaults are `7` and `4`.
Higher values make a deployment quieter. Explicit requests bypass the score, while human-addressed
ambient messages remain suppressed.

Accepted model-backed work is recorded in `commitments` at queue time and projected from
`agent_runs`, which remains the execution authority. `/responder work`, conversational requests
such as `what are you working on?`, and App Home expose queued, working, finishing, blocked, and
cancelled state. Maintenance does not create a second work lifecycle: commitment retention follows
the underlying agent run.

## Evidence

Agent prose is not the evidence ledger. Structured observations record claim, observation, source
type and name, target, freshness, confidence, optional HTTPS source URL, and observation time.
Coverage records whether hardware, host, runtime, scheduler, workload, dependency, application,
SLO, and recent-change layers are healthy, degraded, unhealthy, unknown, or not applicable.
`/responder evidence`, `/responder timeline`, `/responder handoff`, and `/responder postmortem` read
these durable records. The remediation timeline is a deterministic chronological projection over
signals, agent runs, explicit operator and lifecycle events, proposals, Emisar approval-bound runs,
and draft-PR publication. Those source rows remain canonical, so retries cannot create a second
version of an approval or executed action in the incident record. Closing an incident posts a
post-incident draft and leaves unknown impact, root cause, ownership, and follow-up explicitly
unassigned.

Model-proposed and autonomous operational actions are disabled. A configured operator can directly
request one exact action from any Slack conversation; Responder must use Emisar's governed action
flow and does not require an incident. A `pending_approval` result is stored and rendered with a
link to the exact Emisar approval request. Slack never records the decision and never bypasses
Emisar policy. Responder monitors the exact run in its durable background queue, updates the
original Slack card as the run advances, and automatically resumes the same conversation when the
run becomes terminal. Waiting does not occupy a Slack conversation lane or a Coop/model turn. The
terminal continuation calls `wait_for_run` for the original run, cannot repeat `run_action`, and
uses only read-only tools to verify the live effect before posting a concise result. Restart
recovery rehydrates unfinished monitors from `responder.db`; transient status-check failures use
bounded backoff without losing the run identity.

Draft-PR follow-up uses the same durable-worker pattern. `github.followup_interval` controls GitHub
check and merge polling; `github.delivery_correlation_window` controls how long a merged
publication remains eligible for exact cross-channel deployment and Terraform correlation. The
operator can use **Check delivery** in the task thread for an immediate read-only refresh. The
`publication_followups` row is the current polling cursor, while `publication_lifecycle_events`
is the deduplicated event ledger used by the task timeline. Neither path grants merge, deploy, or
infrastructure authority.

## Evaluation rollout

Use channel or workspace shadow mode before enabling proactive replies broadly:

```text
/responder shadow on
/responder shadow global on
/responder shadow inherit
```

Review durable evaluation records and service audit output, redact representative model outputs,
and add behavioral contracts to `testdata/eval/live.jsonl`. Run the real configured model:

```bash
make eval CONFIG=.responder/responder.yaml
responder eval --config .responder/responder.yaml --json
```

For a deterministic parser and response-envelope check, add redacted outputs to
`testdata/eval/golden.jsonl` and run `make eval-replay`. The replay is part of offline CI but is not
a model eval. The real eval calls the configured model through isolated Coop sessions and scores
strict watch decisions and incident response envelopes, including confirmation-offer types,
evidence sources, coverage states, approval holds, response bounds, and forbidden overclaims. See
[`testing.md`](testing.md) for the customer-journey matrix and bounded live acceptance set.

## Capacity

`limits.max_active_incidents` bounds open Coop sessions. Additional admitted incidents can still
receive durable records and Slack channels, then display a holding state until session capacity is
available.

`limits.max_open_incidents` separately bounds all incidents that are not closed, including records
waiting for a session. New occurrences that would exceed it are rejected transactionally before
channel creation and remain visible as failed webhook or Slack work. Closing an incident releases
one slot. Set this above `max_active_incidents`.

Responder automatically adds Coop capacity when an authorized request reaches an exhausted session.
`coop.extend_turns` is the internal allocation chunk; it is not an operator-facing estimate.
`coop.turn_limit` is the default lifetime safety ceiling, measured in accepted requests rather than
tool calls or investigation steps. The shipped default is 1000. Authorized operators can inspect or
override it per channel or workspace with `/responder turn-limit`; channel override, workspace
override, then deployment configuration is the precedence order. At the ceiling, the pending
request, session, and fork are preserved, and raising the ceiling resumes incident work. Coop's
policy and service-wide hard limits remain authoritative.

`limits.max_webhook_attempts`, `limits.max_slack_input_attempts`,
`limits.max_delivery_attempts`, and `limits.max_agent_run_attempts` independently bound poison work.
Normal scheduling deferrals and Coop progress polls do not consume these failure budgets. Terminal
failures are counted by `responder_work_failed`.
For configuration upgrades, the retired `max_outbox_attempts` value seeds any of these four budgets
that are not explicitly set; new configurations should use only the specific names.

`limits.control_workers`, `limits.background_workers`, and `limits.maintenance_workers` bound
parallel work in each scheduler lane. Increase `background_workers` when one installation serves
many active channels; conversation keys continue to serialize work belonging to the same Slack
conversation. Each value must be between 1 and 32.

`limits.worker_interval` controls how quickly an idle scheduler lane checks for newly due work.
`limits.work_lease` bounds ownership of one scheduler item; expiry permits safe reclamation with a
new lease token and must exceed `limits.worker_stall_after`. `limits.worker_stall_after` is the
readiness and handler-timeout threshold for lane heartbeats, due queue age, and running work age,
and must be at least `coop.request_timeout`.

Memory gauges are exported as `responder_memory_entries_active` and
`responder_memory_entries_expired`. Maintenance logs include the number of expired entries pruned.

Inspect terminal failures locally:

```bash
responder failures --config /etc/responder/responder.yaml
responder failures --config /etc/responder/responder.yaml --json
```

After fixing the underlying credential, configuration, or dependency problem, stop Responder and
retry exactly one item:

```bash
responder retry --config /etc/responder/responder.yaml webhook hook_...
responder retry --config /etc/responder/responder.yaml slack slack_...
responder retry --config /etc/responder/responder.yaml delivery delivery_...
responder retry --config /etc/responder/responder.yaml agent_run run_...
```

The command refuses to run while Responder owns the state directory. It preserves the original
payload, persisted context or frozen Coop revision, and idempotency key, resets the failure budget,
and appends an audit event. A failed uncertain Slack post always returns through history
reconciliation before another send is possible. An agent run that already reached a terminal Coop
result is shown as non-retryable; send a new Slack message to start a new run instead. The retired
`outbox` and `turn` kind names remain compatibility aliases. There is deliberately no bulk retry.

## Backups

The database is:

```text
<state_dir>/responder.db
```

Before every automatic schema upgrade, Responder creates a SQLite-consistent `VACUUM INTO` snapshot
under:

```text
<state_dir>/backups/responder-v<old>-to-v<new>-<timestamp>.db
```

Startup verifies `PRAGMA quick_check`, verifies that the snapshot still has the source schema
version, sets file mode `0600`, and aborts before migration if any step fails. Only the three newest
files matching Responder's migration-backup name are retained; unrelated files are never removed.

For an operator-initiated point-in-time backup outside an upgrade, stop Responder, copy
`responder.db`, then restart it. The Coop state and repository forks are separate and must be backed
up according to Coop's operating policy. Never restore only one side and assume session mappings
still match; run `doctor`, `status`, and `failures` after recovery.

## Secret rotation

Webhook and Slack secrets are read at process startup and must contain at least 16 bytes. Rotate
them in the secret environment and restart Responder.

The Emisar key is copied by `bootstrap-coop` into Coop's owner-private environment file. Rotate it
by parking active turns, stopping Coop and Responder, updating the environment, rerunning
`bootstrap-coop`, and restarting Coop followed by Responder. `bootstrap-coop` refuses to rewrite
configuration while the Coop socket is accepting connections. The same file sets
`EMISAR_CLIENT=responder`; the command never prints the key. Apply changes to optional additional
MCP or environment sources with the same stop, bootstrap, and restart sequence.

## Release verification

Release archives include the binary, example configuration, systemd and reverse-proxy deployment
files, documentation, license, changelog, and security policy. Download the archive,
`checksums.txt`, and `checksums.txt.bundle` from the same GitHub Release. Authenticate the checksum
manifest first, then verify the archive and its GitHub build provenance:

```bash
tag=vX.Y.Z
arch=amd64
artifact="responder_${tag#v}_linux_${arch}.tar.gz"
cosign verify-blob checksums.txt \
  --bundle checksums.txt.bundle \
  --certificate-identity "https://github.com/AndrewDryga/responder/.github/workflows/release.yml@refs/tags/${tag}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
awk -v file="$artifact" '$2 == file { print $1 "  " file }' checksums.txt |
  sha256sum --check
gh attestation verify "$artifact" \
  --repo AndrewDryga/responder \
  --signer-workflow AndrewDryga/responder/.github/workflows/release.yml \
  --source-ref "refs/tags/${tag}"
```

On macOS, replace `sha256sum --check` with `shasum -a 256 --check`. The checksum comparison alone
does not authenticate the manifest; do not skip cosign verification for a production install.

## Retention and garbage collection

Closing work closes its Coop session and records a cleanup intent. After
`retention.closed_session_grace`, Responder requests Coop's exact discard plan:

- clean zero-change work is reclaimed;
- a clean published task is reclaimed because its reviewed tree is durable in the draft PR;
- dirty work is always retained;
- clean committed but unpublished work is retained until publication or explicit operator disposal;
- only exact session IDs recorded by Responder are eligible. Fork name patterns are never ownership.

`retention.operational_data` bounds completed Slack inputs, webhook payloads, Slack deliveries,
agent runs, classifier decisions, and rotated channel intelligence after its Coop cleanup
completes. `retention.closed_work` bounds closed incidents and their detailed evidence after Coop
cleanup completes. `retention.audit_data` bounds the smaller
audit and cleanup ledger. Maintenance checkpoints the SQLite WAL and runs `PRAGMA optimize` after
pruning. Coop leaves a small discarded-session tombstone for its own audit while deleting the
workspace and private ACP state.

Operational memory has its own per-entry expiry and active-entry caps. The same maintenance pass
deletes expired values and entries bound to repository keys no longer present in configuration.
Confirmed Slack channel deletion removes channel-scoped and channel-visible memory immediately.
These deletions do not copy forgotten values into the audit ledger.

A task must be published before it is closed because Coop reviews only open, parked sessions.
Closing a changed unpublished task therefore warns that the work will be retained. Its closed task
card keeps **View diff** and adds **Discard retained work**; that destructive control
accepts clean unpublished commits only after a second exact Coop plan and still refuses dirty files.

Deleting or archiving a Slack incident room does not delete or close the incident record. Responder
stores the room as `deleted` or `archived`, retains its channel ID and name, blocks an open incident,
preserves the Coop session and isolated fork, and makes pending room deliveries terminal instead of
retrying a destination that cannot accept them. The incident directory labels the unavailable room
without emitting a broken Slack channel mention.

Slack lifecycle events are authoritative for deletion. Periodic channel inspection can mark a room
`unreachable` when Slack returns `channel_not_found`, but that state deliberately means unavailable
or inaccessible, not confirmed deleted. Restore the app's access or rebind the incident room before
continuing. Room deletion does not bypass the ownership and publication checks used by cleanup.
