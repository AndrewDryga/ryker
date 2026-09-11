# Elixir/PostgreSQL operations

The production Responder is one Elixir release backed by PostgreSQL. PostgreSQL
is the durable authority for ingress, episodes, Work, delivery, waits,
schedules, approvals, publication, remote-worker placement, and retention.
A process restart does not create a second deployment state: the replacement
claims expired or released custody from the same database and resumes it.

The systemd unit in `deploy/systemd/responder.service` is the canonical service
definition. It runs migrations before every start, starts the release in the
foreground, and lets systemd deliver `SIGTERM` directly to the BEAM process.
Run exactly one service against a production platform identity and database.

## Required files and secrets

Install these owner-controlled files before starting the service:

- `/etc/responder/responder-elixir.yaml`, derived from
  `config/responder-elixir.example.yaml`;
- `/etc/responder/responder.env`, derived from
  `deploy/systemd/responder.env.example` and mode `0600`;
- `/etc/systemd/system/responder.service`;
- `/usr/local/lib/responder/current`, the atomic symlink created by the release
  installer; and
- the remote Coop worker policies, certificates, repository mappings, and
  execution endpoints named by the reviewed configuration.

The environment file carries PostgreSQL, platform, checkpoint, and state-tool
secrets. The YAML file carries trusted platform bindings, repositories, Work
profiles and their immutable policy digests, delivery adapters, runtime
listeners, retention, and control-plane configuration. Webhook payloads and
fleet workers cannot choose any of those authorities.

Before every start, validate that:

- the database URL names the intended PostgreSQL database;
- Slack workspace IDs and GitHub App installation/repository bindings are
  exact;
- every universal-webhook destination has a configured outbound adapter;
- every enabled state tool has its owning runtime;
- every Work profile has the reviewed policy, full policy digest, and Coop-computed authority
  digest;
- every class policy resolves to the intended target (`conversational` to Terra/medium, `standard`
  to Sol/medium, and `deep` to Sol/xhigh), and all three have the same authority digest;
- fleet worker certificates are current and revoked workers are absent; and
- all listeners except the externally proxied webhook paths bind to loopback.

## Normal deployment

Commit the complete change and run the repository gate before deployment. The
canonical command is:

```bash
scripts/deploy.sh
```

It refuses a dirty tree, builds and proves the exact immutable Elixir archive,
boots it against a disposable PostgreSQL database, verifies a same-database
restart and a `pg_dump`/restore boot, installs the versioned release, atomically
moves `/usr/local/lib/responder/current`, restarts `responder.service`, and
waits for both `/healthz` and `/readyz`. It then requires the ready process's
`x-responder-version` header to match the exact installed release; inspecting
the `current` symlink alone is not proof that systemd is serving that build.

This is a normal one-writer restart, not a canary or promote workflow. Do not
start a second Slack socket, GitHub/webhook listener, scheduler, or delivery
worker against the same platform identities. Pending custody is recovered from
PostgreSQL after the replacement starts.

After the script succeeds, record:

```bash
/usr/local/lib/responder/current/bin/responder version
systemctl is-active responder.service
curl --fail http://127.0.0.1:4321/healthz
curl --fail http://127.0.0.1:4321/readyz
scripts/check-running-elixir-release.sh http://127.0.0.1:4321 EXPECTED_VERSION
curl --fail http://127.0.0.1:4321/metrics
```

Then execute the authorized live journeys in `docs/testing.md` and the guided
checklist at `http://127.0.0.1:4321/manual-tests`. Test results, installed
version, running version, and live platform receipts are separate evidence.

## Health and readiness

| Endpoint | Meaning |
| --- | --- |
| `/healthz` | the process can use PostgreSQL |
| `/readyz` | every configured runtime is alive, scheduler progress is fresh, and no due or active custody is stalled past its configured threshold |
| `/metrics` | Prometheus counters and gauges for queue depth, oldest due work, active lease age, scheduler progress, failures, placements, delivery, and retention |

Keep these endpoints on loopback. `deploy/nginx/responder.conf` exposes only the
signed GitHub and universal-webhook ingress paths. A routable control-plane bind
would expose operational counts and compete with production work for database
connections.

Readiness is deliberately stricter than liveness. A process can remain alive
while a scheduler lane stops advancing or one remote turn renews custody
forever. That condition must fail `/readyz`; it must not be hidden by a healthy
PID.

When readiness fails:

1. inspect the failed checks and queue ages in `/metrics` and the control plane;
2. inspect the owning episode, source/destination, attempt counts, and exact
   custody phase before retrying a visible effect;
3. verify PostgreSQL, configured listeners, and remote worker placement;
4. revoke or drain a compromised worker before moving its placement;
5. use the typed retry/reconcile control for the failed lane; and
6. restart only after preserving the logs and exact operation keys needed for
   reconciliation.

Never delete or rewrite a lease, operation key, receipt, or episode row by
hand. The recovery APIs preserve the fences that make a replacement safe.

### Read-only operator commands and typed recovery

Run the short-lived Mix tasks with the same `MIX_ENV=prod`, `DATABASE_URL`, and
absolute runtime configuration path as the release:

```bash
mix responder.doctor --config /etc/responder/responder-elixir.yaml
mix responder.status --config /etc/responder/responder-elixir.yaml
mix responder.failures --config /etc/responder/responder-elixir.yaml
mix responder.retry admission 'ingress-input:...' \
  --config /etc/responder/responder-elixir.yaml --operator U123 --action-ref retry-admission-20260904-1
mix responder.replay slack 'ingress-input:...' 'post-fix-check-1' \
  --config /etc/responder/responder-elixir.yaml --operator U123 --action-ref replay-slack-20260904-1
mix responder.replay show 'ingress-input:...' \
  --config /etc/responder/responder-elixir.yaml
```

The commands start only temporary database dependencies, never the Responder
worker tree. Doctor therefore reports configuration, database, migration, and
durable queue readiness; `/readyz` on the running release remains authoritative
for process-local workers and progress heartbeats. Failure output contains
stable error codes and diagnostic SHA-256 values but no raw provider error,
source body, prompt, rejected model candidate, token, or credential. Work failures
also show the redacted accepted final response, explicitly attributed to the worker.

For `work`, pass `--expected-recovery SHA256` from the inspected item's
`work_recovery.fingerprint`. A changed turn invalidates the confirmation. Confirmed
completion resumes host finalization on the same turn, without model replay.
If a writable session was closed before a workspace checkpoint was confirmed,
preserve and restore its working copy and task notes into a correctly bound fleet
workspace first; ordinary retry is unavailable.

Retry accepts only `admission`, `delivery`, `emisar`, `retention`,
`slack_incident`, `slack_interaction`, and `work`. Inspect the current item
first. Publication review is a semantic decision and deliberately has no
generic retry. The local control plane uses the same typed recovery service but
adds loopback Host checks, CSRF, and an exact-state confirmation page.
Every retry and replay requires a configured Slack operator ID and a unique
operator action reference. Its safe prior state and outcome are committed with
the mutation; repeat the same action reference after a lost response to obtain
the original outcome without running the mutation again.

Slack replay accepts only a retained live Slack message input with a frozen
Work profile. It mints a stable fresh event identity from the source and request
reference, records shadow custody, and never calls Slack. Repeating the same
action reference returns the first audited outcome. `show` reports admission,
episode, and Work lifecycle state plus the bounded accepted `decision_reason`
that says what the shadow model would have done; it never returns captured
content or unreleased model output.

## Set up code editing

“Couldn’t start” with the workspace-checkpoint connection error means the host
stopped before creating a coding session. It is not a failed repository check.
The direct connection (`work.execution: direct`) does not support saving and
restoring writable task workspaces. Use fleet execution for code-editing tasks;
do not bypass the preflight or keep retrying the unchanged setup.

The episode page distinguishes this proven startup failure from an older task
that ran and lost access to its workspace. It shows the task title, confirmation,
setup remedy and proposal/approval history first. Technical history stays
available below. Missing or expired telemetry alone never proves “no files
changed.” A completed proposal is not a completed code change.

An administrator must prepare the worker and its permissions before switching
execution. The following paths and identifiers are examples, not deployment
authority. Keep the current runtime configuration's other policies and tool grants.

1. Prepare a co:op session service with persistent storage, provider credentials,
   reviewed repository policies, and the repository's actual build tools. Run
   the daemon and connector as the same OS user. For an existing local daemon,
   inspect its exact socket and policies; do not start a duplicate service.

   ```bash
   coop sessions doctor --socket /var/lib/coop-sessions/control.sock
   coop sessions policies --policies /etc/coop/session-policies.yaml --json
   ```

   If this is a new worker, follow co:op's `docs/worker.md` and
   `docs/session-api.md` to start its session daemon under supervision.
   Copy the real policy and authority digests from the policy output. Obtain
   the expected sandbox digest, repository mapping and capability advertisements
   from the reviewed worker deployment—not placeholder hashes.

2. Configure the host's `coop_worker_gateway` with a reachable HTTPS origin,
   its trusted CA and signing key, server certificate/key, and checkpoint
   encryption key. The named checkpoint secret must decode from base64 to
   exactly 32 bytes. Preserve it: replacing it without a recovery plan can make
   existing saved work unreadable. Worker traffic uses outbound mutual TLS;
   do not expose the operator control plane to connect a remote worker.

3. Enroll the exact worker and workspace. In the Responder checkout, with the
   running release's `MIX_ENV=prod` and `DATABASE_URL` environment loaded:

   ```bash
   mix responder.coop_worker enroll WORKER_ID WORKSPACE_REF OPERATOR_REF
   ```

   This command prints the enrollment token once. Save only its token value in
   the worker's owner-private `enrollment_token_file` (mode `0600`); do not paste
   it into chat, command arguments or the worker JSON. This command does **not**
   accept `--config`. It uses the database environment, not the host YAML path.

   Complete co:op's `docs/examples/worker.json` with real identities, HTTPS origin,
   CA, socket, policy/authority digests, repositories, capabilities and capacity.
   `identity_file` must initially be absent; `journal_dir` must be persistent and
   private. Then start the connector under supervision:

   ```bash
   coop worker connect --config /etc/coop/worker.json
   ```

   Preserve its generated identity and complete journal across restarts.
   A quiet connector process is not proof that the worker is eligible.

4. In the existing host YAML, change only the relevant Work settings:

   ```yaml
   work:
     execution: fleet
     workspace_ref: YOUR_ENROLLED_WORKSPACE
     capability_names:
       - responder-state
     # Preserve the existing Work settings and source/action-tool grants.
   ```

   The workspace must exactly match enrollment. Preserve any additional required
   capabilities; do not remove requirements just to make placement succeed.
   Verify the selected worker advertises the task's repository, pinned policy and
   authority, compatible sandbox, required capabilities and available capacity.
   Validate the edited configuration with `mix responder.doctor --config
   /absolute/path/to/responder-elixir.yaml`, then restart the host through its
   normal deployment workflow. Do not restart or upgrade co:op as an incidental
   part of deploying a host UI change.

5. Before retrying the task, verify that a disposable workspace can be saved and
   restored, and run a small required repository check inside the **coding
   environment**. If its gate requires Docker, installing Docker on the host
   alone is insufficient: the worker's environment must have approved access to
   a working daemon. A host Docker socket grants broad host control; choose and
   explicitly approve that access or an isolated build environment separately.

After the connection changes, the episode offers “Retry task” again. This only
means the known connection blocker is gone; it does not certify worker readiness.
For a task proven never started, retry begins the approved task. For an older
task with existing edits and a closed, unsaved session, preserve and recover those
edits first; switching to fleet does not automatically restore them.

## Control plane and Conversation Lab

The loopback control plane provides:

- overview and effective configuration;
- episode, decision, finding, delivery, approval, publication, schedule,
  retention, and fleet views;
- failure drill-down and typed retry controls;
- Conversation Lab at `/lab`; and
- the guided manual matrix at `/manual-tests`.

Conversation Lab enters the same durable generic ingress, admission, episode,
Work, semantic-validation, and delivery pipeline as Slack, GitHub, and
webhooks. It uses the configured fixed Work profile. It is not a direct model
chat shortcut, and it cannot select policy, repository, destination, provider,
or credentials from browser input. Shared conversational behavior is identical
to Slack. Slack-owned API effects are emulated locally and labelled as such;
for example, an incident offer starts linked Work in the Lab rather than
claiming that a Slack channel was provisioned.

Keep the control plane loopback-only. Its Host and CSRF checks are part of the
authority boundary; do not publish it through the public webhook proxy.

## Platform acceptance

Run live acceptance only with explicit authority for the named test workspace,
repository, and channel/thread.

- Slack: thread and DM continuation, task/progress cards, questions, Stop,
  reactions and custom emoji, authenticated files, incident room, restart, and
  lost-response reconciliation.
- GitHub: issue comment revisions, pull-request review summary, inline review
  thread, edits/deletes, and all eight native reactions.
- Universal webhook: exact signed canonical bytes, duplicate/conflict,
  stable-item revisions, fixed Work profile, and configured delivery route.
- Model behavior: multi-turn evidence gathering, state tools, questions,
  waits/schedules/memory, governed approval, semantic repair, and recovery.
- Fleet: placement loss, certificate revocation, checkpoint/failover, stale
  bearer rejection, and exact output publication through the central host.

Offline E2E tests prove the host mechanics. The credentialed fabricated-world
evaluation proves model trajectory without external side effects. Live
acceptance proves platform grants and APIs. None substitutes for another.

## Model routing

Responder has two distinct model decisions. The short-lived admission session decides lifecycle
(`reply`, start, continue, react, or ignore), candidate relation, and an abstract Work class. It is a
classifier; the current setup uses Terra/medium. The durable Work session then uses
the class selected from the host-owned profile:

- conversational: Terra/medium;
- standard: Sol/medium;
- deep: Sol/xhigh.

The [redesign plan](control-plane-redesign.md#2-fast-admission-with-preserved-authority-and-recovery)
replaces admission's general-purpose agent path with a qualified fast classifier,
durable progress, and safe escalation. This is planned, not a deployed model
switch; Work routing above remains unchanged. The plan also replaces manual
policy/digest configuration with resolved immutable execution profiles. Until
that loader and migration ship, the v1 procedure below is still required.

The full policy and model-independent authority digests are generated from the exact Coop policy
file with:

```bash
coop sessions policies --policies /etc/coop/session-policies.yaml --json
```

Copy both returned maps into the Responder YAML and the worker connector configuration. The three
class policies must have one identical `authority_digest`; Responder rejects configuration, fleet
placement, or a returned Coop session that widens it. Use new versioned policy names when changing
targets; do not mutate the meaning of a policy still pinned by an active or recoverable episode.
Contributor, schedule, incident, and evaluation policies remain separate authority lanes, even when
they happen to use one of the same model targets.

## PostgreSQL backup and restore

Use physical or managed continuous backup in production and take an explicit
logical backup before migrations, platform-identity changes, and cutover:

```bash
install -d -m 0700 /var/lib/responder/backups
pg_dump --format=custom --file=/var/lib/responder/backups/responder-$(date -u +%Y%m%dT%H%M%SZ).dump responder
pg_restore --list /var/lib/responder/backups/responder-*.dump >/dev/null
```

Periodically prove restore into a different database:

```bash
createdb responder_restore_check
pg_restore --exit-on-error --no-owner --no-privileges \
  --dbname=responder_restore_check /var/lib/responder/backups/responder-TIMESTAMP.dump
DATABASE_URL=ecto://responder@127.0.0.1/responder_restore_check \
  /usr/local/lib/responder/current/bin/responder eval 'Responder.Release.migrate()'
dropdb responder_restore_check
```

Do not point a second live service at the restored database while the original
platform identities are enabled. Candidate checks use inert publishers and
disposable identities for this reason.

## Restart and crash recovery

A normal restart is:

```bash
systemctl restart responder.service
curl --fail http://127.0.0.1:4321/readyz
```

The replacement reconciles persisted operation keys before issuing a network
mutation. Work and delivery leases are opaque, fenced, and reclaimable. Remote
Coop placements and state-tool bearers are valid only for the exact current
session generation, turn, lease, and worker placement. Accepted delivery
documents and receipts survive newer input and restart.

If shutdown happens during a remote mutation or visible delivery, let the
typed reconciliation path determine whether the operation committed. Never
retry a post or validation manually from copied bytes.

A review can finish after a worker request times out. Responder reconciles its
original operation on the original placement and reads the saved review result;
the timeout receipt is retained and the gate is not rerun. This requires the Coop
daemon and connector's completed-review reconciliation support. Upgrade workers
independently of Responder; do not clear command receipts or change review keys to
work around an older worker.

Recovery also requires that original placement to remain active. If it has expired
or its authority changed, preserve the candidate and review history and inspect the
episode's recovery state before acting. A lookup is not permission to recreate the
session or grant a new worker access to its workspace.

## Worker drain and revocation

Use the audited fleet lifecycle commands to drain planned maintenance and
revoke a compromised worker. Revocation must invalidate all worker
certificates/bootstrap tokens, expire placements, fence commands, and remove
state-tool authority. A revoked worker cannot renew itself.

Writable work moves only from a verified bounded checkpoint. If safe takeover
cannot be proved, the episode remains visibly blocked for operator recovery; it
is not silently rebuilt with wider repository authority.

## Secret rotation

Rotate one authority boundary at a time:

1. install the new owner-private secret;
2. restart the service or owning worker;
3. verify readiness and the narrow acceptance journey;
4. revoke the old credential; and
5. record the effective binding and time.

GitHub installation tokens are short-lived and repository/purpose/permission
scoped. Slack and GitHub publication credentials stay in the central host.
Remote workers and models never receive them. Rotating the state-tools root
secret invalidates newly derived bearers; current placement/turn/lease checks
still fence every request.

## Retention

Keep the retention runtime enabled in product configurations. It closes and
discards terminal remote sessions, prunes only terminal and dependency-free
history, and removes artifacts only after relational custody proves there are
no live references. Active episodes, schedule occurrences with active child
work, pending delivery, approvals, publications, and cutover evidence are not
age-only garbage.

Historical import records and their provenance remain in PostgreSQL. The retired
Go-state import and rollback commands are no longer shipped; removing those tools
does not remove previously imported work or memory.

Inspect retention failures in the control plane before retrying. A failed close
or prune remains durable work; do not bypass it with direct deletes.

### Cleanup throughput and recovery

One cleanup pass runs per `poll_interval_ms`, advances at most `batch_limit`
phases, advances any one session at most once, and stops after `batch_seconds`
so a pass always fits inside its own poll. A worker that proves unreachable
during a pass stops being claimed for the rest of that pass, so one offline
worker cannot spend the budget the healthy ones need.

Queue age for cleanup is measured from eligibility — the durable time a session
became claimable, which for a normally completed session is its close time plus
`closed_session_grace_seconds`. Conversation time and the intentional grace
period are not stall. The readiness queue and the claim query are the same
query, so Work and learning backlogs are always counted the same way.

Outage-class failures (unreachable transport, worker capacity, 429, 5xx) retry
indefinitely with bounded backoff up to `retry_max_seconds`; they never consume
`max_attempts` and never become blocked, because an outage is not a verdict
about the session. Identity and authority failures still block and stay visible
for operator rearm. A successful phase resets the attempt count. On restart the
host releases the cleanup leases it wrote before the restart instead of waiting
out the lease clock, and a worker heartbeat that arrives after a failed attempt
makes that session's cleanup due again without waiting out the backoff.

A workspace retained because it is dirty is replanned every
`retained_recheck_seconds`, so work the user later committed or removed is
reclaimed automatically. Nothing about age or disk pressure ever authorizes
discarding dirty or unpublished work.

### Storage budget and allocation pressure

`disposable_bytes_limit`, `reclaim_target_seconds`,
`storage_high_watermark_bytes`, `storage_low_watermark_bytes` and
`storage_reserve_bytes` are the documented per-worker storage policy. They and
the draining settings (`batch_limit`, `batch_seconds`,
`retained_recheck_seconds`) carry the documented defaults from
`config/responder-elixir.example.yaml` when omitted, so an existing
configuration keeps starting; the retention horizons remain explicit.
Watermarks must be ordered and the reserve must be smaller than the high
watermark; configuration outside those bounds fails at startup.

Workers report their own measured storage in every poll. Responder never
estimates it: a worker that reports no `storage` object is unknown, not zero,
and its measurements are labelled stale once its heartbeat goes stale. When a
worker reports `allocation: refused`, Responder stops placing new
fork-requiring sessions on it and says why; cleanup, control, and recovery of
work already on that worker continue. Recovery follows the worker's own
reported return to `open`, so there is no second hysteresis to oscillate
against. This bounds workspace allocation; it does not bound arbitrary writes
made by an already running task inside its own fork.

## Release verification

Download the archive, signed checksum manifest, bundle, and all executable
helpers from the same GitHub Release:

```bash
version=X.Y.Z
tag=v$version
archive=responder_${version}_elixir_linux_amd64.tar.gz

cosign verify-blob checksums.txt \
  --bundle checksums.txt.bundle \
  --certificate-identity \
  "https://github.com/AndrewDryga/responder/.github/workflows/release.yml@refs/tags/$tag" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

for helper in install-elixir-release.sh check-elixir-release.sh activate-elixir-release.sh; do
  awk -v file="$helper" '$2 == file { print }' checksums.txt | sha256sum --check --strict
  chmod 0755 "$helper"
done

gh attestation verify "$archive" \
  --repo AndrewDryga/responder \
  --signer-workflow AndrewDryga/responder/.github/workflows/release.yml \
  --source-ref "refs/tags/$tag"

sudo ./install-elixir-release.sh \
  "$archive" "$version" checksums.txt checksums.txt.bundle "$tag" \
  /usr/local/lib/responder
```

The installer authenticates the manifest and provenance before extraction,
rejects unsafe archive paths and identity collisions, writes an immutable
version directory, and atomically updates `current`.

## Rollback

An ordinary release rollback selects a previously installed immutable Elixir
version only when its database contract is compatible:

```bash
sudo scripts/activate-elixir-release.sh /usr/local/lib/responder PREVIOUS_VERSION
sudo systemctl restart responder.service
curl --fail http://127.0.0.1:4321/readyz
```

Never roll a binary behind migrations or persisted contracts it cannot read.
