# Docker Compose operations

Docker Compose is the supported Ryker deployment. The canonical project contains PostgreSQL and
the immutable Ryker image, stores their data in named volumes, and keeps installation roots in the
owner-only `.ryker/compose.env` file. Do not copy Slack, GitHub, Emisar, model-provider, or webhook
credentials into that file; configure integrations in the local setup UI, where Ryker encrypts
them in PostgreSQL.

PostgreSQL is the durable authority for ingress, episodes, Work, delivery, waits, schedules,
approvals, publication, worker placement and retention. Restarting containers recovers that
custody; it does not create a second deployment state.

## Install

Requirements are Docker, Docker Compose v2, OpenSSL, curl and tar. From a release directory run:

```bash
./install.sh
```

The installer creates `.ryker/` with mode `0700` and `compose.env` with mode `0600`. On the first
run it generates the database password, checkpoint key, credential-encryption key and state-tools
token. Later runs reuse them. It starts the project, waits for `/healthz` and `/readyz`, verifies
the `x-ryker-version` header, and prints one setup URL.

The control UI, GitHub listener and universal webhook listener bind to `127.0.0.1` by default.
Change a bind address only when the surrounding network boundary is understood. External GitHub
and webhook senders need an HTTPS reverse proxy to the exact signed ingress paths; do not publish
the control UI, health, readiness or metrics endpoints.

## Setup and connection states

Open the setup URL printed by the installer (`/setup`). It leads through six required steps, one
at a time:

1. connect and verify Slack;
2. connect and verify the GitHub App;
3. import selected repositories, or add every repository available to the App;
4. invite Ryker to a Slack channel;
5. choose that channel’s environment; and
6. send one real Slack request and receive its delivered answer.

An **environment** is where Ryker works: the repositories work in it may use, in order (work
changes the first and only reads the others), and at most one Emisar account. Importing a
repository adds it to the default environment and creates one named "Default" when there is none,
so there is no separate step for environments. A channel Ryker joins starts in the default
environment; one it joined before any existed has none, and step 5 chooses one on the channel's
page (or from Ryker's welcome message in Slack). Chat and every conversation without its own
choice work in the default environment. Environments are managed under **Work › Environments**.

Ryker notices steps 4 and 6 itself, and step 5 as soon as a joined channel has an environment.
Connecting Emisar is the one recommended extra: it is optional and never blocks setup, but without
it Ryker cannot act on anything that is running. A connected account is watched for approval
decisions at once, and the installation's first account is given to every environment that has
none, creating "Default" first when no environment exists yet. A later account, or an environment
added later, is chosen on the Environments page; the Emisar page counts the environments without
an account. Every integration is managed afterwards
under **Integrations**, and models, retention, prices and advanced placement under **Settings**.

The UI treats four facts separately: a setting can be saved, the runtime revision can be applied,
an integration can be connected, and a real request can be live-tested. One does not imply the
next. Learning is on by default. Proactive participation, publication, scheduled reports and
destructive authority remain off until explicitly enabled.

## Routine lifecycle

Use the shipped helper so every operation uses the same project and owner-only environment:

```bash
scripts/compose.sh status
scripts/compose.sh logs
scripts/compose.sh stop
scripts/compose.sh start
scripts/compose.sh restart
```

`stop` and `uninstall` retain PostgreSQL data, Ryker state and encryption roots. `uninstall`
removes the stopped containers and network while leaving the named volumes and `.ryker/compose.env`
in place.

## Upgrade

Set `RYKER_IMAGE` and `RYKER_VERSION` in `.ryker/compose.env` to the authenticated immutable release
you intend to run, then:

```bash
scripts/compose.sh backup
scripts/compose.sh upgrade
```

Upgrade pulls the selected image when applicable, rebuilds only a local development image, starts
the replacement, runs migrations through the container entrypoint, and verifies health, readiness
and the exact version header. Enrolled remote workers are not restarted or modified.

## Backup and restore

Create a backup while the project is running:

```bash
scripts/compose.sh backup
```

The resulting owner-only archive under `.ryker/backups/` contains a custom-format PostgreSQL dump
and the exact generated environment needed to decrypt stored credentials and checkpoints. Store it
as sensitive material.

Restore with:

```bash
scripts/compose.sh restore .ryker/backups/ryker-YYYYMMDDTHHMMSSZ.tar.gz
```

Restore refuses an archive whose cryptographic roots differ from an existing installation. With no
existing installation state it restores the archived roots first, starts only PostgreSQL, replaces
the database, then starts Ryker and verifies the exact running version. A missing, wrong or damaged
root must fail; never generate a replacement key for an existing database.

## Destruction

Stopping Ryker is recoverable. Deleting volumes and keys is not. The destructive path requires an
explicit phrase:

```bash
RYKER_DESTROY_CONFIRM=delete-ryker-data scripts/compose.sh destroy
```

This removes the Compose volumes and generated environment. It cannot recover encrypted
credentials, checkpoints or historical evidence without a backup. The helper says exactly what it
removed after the operation.

## Health and recovery

| Endpoint | Meaning |
| --- | --- |
| `/healthz` | the process can use PostgreSQL |
| `/readyz` | configured runtimes are alive and due custody is making progress |
| `/metrics` | queue, lease, delivery, placement and retention measurements |

When readiness fails, inspect `scripts/compose.sh status`, then `scripts/compose.sh logs`. In the UI,
inspect the failed request and its exact custody phase before retrying a visible effect. Do not edit
leases, operation keys, receipts or episode rows by hand; the typed retry and reconcile controls
preserve the fences that make recovery safe.

## Names that still say responder

The product is Ryker. A few wire names remain `responder-*` because Coop workers, webhook senders,
or previously delivered GitHub markers own those contracts. They change only with the other party:

- Coop capability and binding names such as `responder-state`;
- the Coop worker configuration field `responder_url`;
- webhook signature and event headers beginning `x-responder-`;
- the `responder.publication_lifecycle.v1` event type; and
- the hidden `<!-- responder-delivery:… -->` marker on already delivered GitHub comments.

The source repository is also still published at the externally owned
`github.com/AndrewDryga/responder` URL even though the product and images are Ryker.

These compatibility contracts are not product branding and must not be renamed independently.
