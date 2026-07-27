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
   scopes, configured operators, invite users and summon channels, an actual Socket Mode WebSocket
   handshake, and Emisar token presence; it does not call an Emisar tool;
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
private Emisar projection written by `bootstrap-coop`.

Managed foreground mode requires the Responder caller to have every permission Coop needs,
including Docker access. Keep the split units for a hardened systemd installation so the Responder
process itself does not receive the `docker` supplementary group.

Responder exits when initial database, Coop, or Slack authentication fails. An external supervisor
should restart Responder with a bounded delay.

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

## Capacity

`limits.max_active_incidents` bounds open Coop sessions. Additional admitted incidents can still
receive durable records and Slack channels, then display a holding state until session capacity is
available.

`limits.max_open_incidents` separately bounds all incidents that are not closed, including records
waiting for a session. New occurrences that would exceed it are rejected transactionally before
channel creation and remain visible as failed webhook or Slack work. Closing an incident releases
one slot. Set this above `max_active_incidents`.

`coop.extend_turns` is the fixed allowance added by an authorized **Extend budget** action. Coop's
global and policy limits remain authoritative.

`limits.max_outbox_attempts` bounds poison webhook, Slack input, and Slack output retries. Terminal
failures are counted by `responder_work_failed`.

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
`EMISAR_CLIENT=responder`; the command never prints the key.

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

## Incident retention

Closing an incident closes its Coop session and preserves the fork, event history, reviews, Slack
channel, and local audit state. V1 has no automatic destructive retention. Use an explicit
human-controlled process for later fork discard or Slack archival.
