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
| `/readyz` | workers run, Coop is ready, and Slack Socket Mode is connected |
| `/metrics` | Prometheus-format incident, queue, failure, and delivery counters |

The webhook endpoint can durably accept work before Slack reconnects, but load balancers should use
`/readyz` when dependency-complete handling is required.

`responder status` and `responder failures` inspect the current database schema without migrating
it and do not require Slack or Coop. Stop Responder before upgrading to a binary that needs a
database migration; startup holds the process lock while applying migrations.

## Retries

Webhook, Slack input, Slack outbox, and Coop turn work use bounded exponential delay. Process
restart converts an interrupted lease back into retryable state.

Slack send failures are treated as uncertain because the API might have accepted the message before
the connection failed. Responder searches Slack history by durable message metadata before deciding
whether another post is safe.

Coop requests reuse the same idempotency key and frozen request body. Non-retryable Coop conflicts
stop the action and remain visible; they are never rewritten with a guessed revision.

Watched Slack feeds use one current Coop session generation per configured channel. Messages are
serialized by Slack message timestamp within each channel and can proceed independently across
channels.
`slack.watch_settle_delay` requires a quiet period after the newest queued message before
classification; the default is two seconds. `slack.watch_context_messages` freezes the latest
chronological channel transcript into each triage request; the default is 20 and the allowed range
is 10 through 50. A running triage turn leaves the durable Slack input retryable until its strict
ignore, reply, or incident result is available. A delayed event older than an already completed
decision is retained and audited but cannot produce an out-of-order reply. Slash commands and
button controls have priority over queued conversation in their channel.

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

Compact channel memory stores the current goal, verified topology, decisions, unresolved questions,
and evidence references. `coop.watch_session_max_turns` defaults to 40 and
`coop.watch_session_max_age` defaults to 24 hours. Responder rotates only an idle session, preserves
the compact memory, and uses a generation-specific idempotency key. Rotation bounds provider
context without discarding operational corrections.

Operator-confirmed operational memory is a separate bounded facility. Responder offers it only
after a configured operator explicitly asks to remember, save, or correct one of four supported
facts: an alias, a channel repository binding, an evidence route, or an entity relationship.
The button shows the scope and expiry before writing. Entries are unique by scope, subject, and
predicate, so a correction replaces the prior value rather than creating a duplicate. App Home
shows workspace-visible and operator-visible entries; `/responder memory` shows the exact entries
visible in the current channel and provides permanent forget controls. Forgotten values are
removed; audit records retain only the entry ID, scope, predicate, actor, and outcome.

`limits.max_memory_entries` and `limits.max_memory_entries_per_scope` bound active memory. Entries
expire after 7, 30, 90, or 365 days and maintenance deletes expired values. A confirmed Slack
channel deletion immediately removes entries scoped or visible only to that channel. Retrieval is
an exact scope and visibility match; Responder does not search another private channel. Saved
memory remains a potentially stale hint: live tools, current repository content, and deployment
configuration take precedence. Recent source-attributed evidence is retrieved from the existing
same-channel evidence ledger and is not duplicated into memory.

`responder.yaml` remains the deployment default. `/responder proactive` writes audited overrides
to the owner-private database. Resolution order is channel override, workspace override, then the
static `slack.watch_channels` list. `inherit` deletes an override instead of copying a stale
default. `/responder turn-limit` stores capacity-ceiling overrides in the same table with the same
precedence. `/responder shadow` stores dry-run evaluation overrides with the same precedence;
shadow mode still performs read-only classification and evidence collection, but cannot post,
offer, or create an incident. Back up these settings with the rest of `responder.db`.

## Evidence

Agent prose is not the evidence ledger. Structured observations record claim, observation, source
type and name, target, freshness, confidence, optional HTTPS source URL, and observation time.
Coverage records whether hardware, host, runtime, scheduler, workload, dependency, application,
SLO, and recent-change layers are healthy, degraded, unhealthy, unknown, or not applicable.
`/responder evidence`, `/responder timeline`, and `/responder handoff` read these durable records.
Closing an incident posts a post-incident draft and leaves unknown impact, root cause, ownership,
and follow-up explicitly unassigned.

Model-proposed and autonomous operational actions are disabled. A configured operator can directly
request one exact action from an existing incident conversation; Responder must use Emisar's
governed action flow. A `pending_approval` result is stored and rendered with a link to the exact
Emisar approval request. Slack never records the decision and never bypasses Emisar policy.
After the operator decides in Emisar, reply in the incident thread or use **Ask agent for update**;
Responder follows the same `wait_for_run` continuation and reports the authoritative terminal
result plus post-action verification.

## Evaluation rollout

Use channel or workspace shadow mode before enabling proactive replies broadly:

```text
/responder shadow on
/responder shadow global on
/responder shadow inherit
```

Review durable evaluation records and service audit output, redact representative model outputs,
and add them to `testdata/eval/golden.jsonl`. Run:

```bash
make eval
responder eval --input testdata/eval/golden.jsonl --json
```

The replay gate validates strict watch decisions and incident response envelopes, including minimum
evidence and coverage counts. It does not call a model, Slack, Coop, or infrastructure.

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

`limits.max_outbox_attempts` bounds poison webhook, Slack input, and Slack output retries. Terminal
failures are counted by `responder_work_failed`.

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
responder retry --config /etc/responder/responder.yaml outbox out_...
responder retry --config /etc/responder/responder.yaml turn turn_...
```

The command refuses to run while Responder owns the state directory. It preserves the original
payload, frozen Coop revision, and idempotency key, resets the attempt budget, and appends an audit
event. Failed Slack outbox work always returns through Slack history reconciliation before another
send is possible. A turn that already reached a terminal Coop result is shown as non-retryable;
send a new Slack message to start a new turn instead. There is deliberately no bulk retry.

## Backups

The database is:

```text
<state_dir>/responder.db
```

For the simplest consistent backup, stop Responder, copy `responder.db`, then restart it. The Coop
state and repository forks are separate and must be backed up according to Coop's operating policy.
Never restore only one side and assume session mappings still match; run `doctor`, `status`, and
`failures` after recovery.

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

`retention.operational_data` bounds completed Slack inputs, webhook payloads, outbox deliveries,
turn submissions, classifier decisions, and rotated channel intelligence after its Coop cleanup
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
