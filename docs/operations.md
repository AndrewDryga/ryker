# Docker Compose operations

Docker Compose is the supported Ryker deployment. The canonical project contains PostgreSQL and
the immutable Ryker image, stores their data in named volumes, and keeps installation roots in the
owner-only `.ryker/compose.env` file. Do not copy Slack, GitHub, Emisar, or webhook credentials
into that file; configure those integrations in the local setup UI, where Ryker encrypts them in
PostgreSQL. Sign the Coop worker in to its model account during install or with
`scripts/compose.sh model-login`; that sign-in stays in the worker's private volume.

PostgreSQL is the durable authority for ingress, episodes, Work, delivery, waits, schedules,
approvals, publication, worker placement and retention. Restarting containers recovers that
custody; it does not create a second deployment state.

The bundled Coop worker uses the same outbound job API as a worker on another VM. Ryker supplies
each job's code identity and settings; Coop fetches code directly on its trusted host. There are no
worker policy files, generated worker JSON, or Ryker-side repository checkouts. The shared
`ryker-coop-config` volume carries only enrollment state and the controller CA; model workspaces
remain in the worker's private state volume.

New jobs do not use the historical `ryker-workspaces` Docker volume, but existing sessions may
still refer to workspaces in it. Do not treat a protocol upgrade as proof that those workspaces
are disposable. Preserve the volume and its mount while those sessions need recovery, and back it
up separately before a v1-to-v2 worker cutover: `scripts/compose.sh backup` includes Ryker state,
worker state, enrollment state and keys, but **not** `ryker-workspaces`. Keep the pre-cutover worker
state backup too; its database schema may advance when the new worker starts.

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

Links Ryker posts into Slack, such as the weekly report's, open the control UI at
`RYKER_CONTROL_PUBLIC_URL`, which is `http://127.0.0.1:` and `RYKER_CONTROL_PORT` unless
`.ryker/compose.env` sets it. Set it to the address you open the UI at when that differs, such as
an SSH tunnel's local port. It must be HTTPS or a loopback HTTP address.

## Setup and connection states

Open the setup URL printed by the installer (`/setup`). It leads through six required steps, one
at a time:

1. connect and verify Slack;
2. connect and verify the GitHub App;
3. import selected repositories, or add every repository available to the App;
4. invite Ryker to a Slack channel;
5. choose that channel’s environment; and
6. send one real Slack request and receive its delivered answer.

An **environment** is where Ryker works: a set of repositories, all of which every piece of work
in it can read, and at most one Emisar account. Each task changes one repository of the
environment, chosen for that task (Ryker picks it from what the request or alert is about; a
proposed task names it), and mounts the others read-only beside it; the order only names the
default choice, the first. Importing a repository adds it to the default environment and creates
one named "Default" when there is none, so there is no separate step for environments. A channel
Ryker joins starts in the default environment; one it joined before any existed has none, and
step 5 chooses one on the channel's page (or from Ryker's welcome message in Slack). A Chat
conversation starts in the default environment and can switch to another, or to none, while it is
open. Environments are managed under **Work › Environments**.

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

Upgrades build from the checkout: no Ryker container image is published, and a GitHub Release
carries the verified release archive ([releasing.md](releasing.md)). Move the checkout to the
release you intend to run (for example `git checkout vX.Y.Z`), set `RYKER_VERSION` in
`.ryker/compose.env` to that version and `RYKER_IMAGE` to the local tag to build (for example
`ryker:X.Y.Z`), then:

```bash
scripts/compose.sh backup
scripts/compose.sh upgrade
```

Upgrade pulls the pinned third-party images (such as PostgreSQL and the worker's Docker daemon), rebuilds
the Ryker image from the checkout, starts the replacements, runs migrations through the container
entrypoint, and verifies health, readiness and the exact version header. It rebuilds the bundled
worker's image from the Dockerfile's Coop pin only when `RYKER_COOP_IMAGE` is unset: an image named
there is a supplied build, and its Coop may keep the worker's state in a schema the pinned one
refuses. Enrolled remote workers are not restarted or modified.

For a worker-protocol change, first verify that the bundled-worker build pin or supplied image
actually speaks the new protocol, and plan the worker and controller cutover together. The normal
Ryker-only deploy does not upgrade Coop. Do not run a broad Compose upgrade against a controller
that cannot speak to the worker it would start; preserve waiting conversations through an explicit
transition or close them through the audited lifecycle before removing their old execution path.

## The schema baseline

Every Ryker schema starts from one migration, `20260926100000_baseline`: it creates the schema
that the 116 migrations before it built until 2026-09-26 (`priv/repo/schema/baseline.sql`), and
newer migrations follow it. There is nothing before it to roll back to; going back means
restoring a backup.

A database migrated through those earlier migrations already has that schema, so it records the
baseline as applied instead of running it, once, before its first upgrade past 2026-09-26:

```bash
scripts/compose.sh backup
docker exec ryker-database-1 sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "INSERT INTO schema_migrations (version, inserted_at) VALUES (20260926100000, now())"'
```

The Compose installation in this checkout was re-baselined this way on 2026-09-26. Its older
rows in `schema_migrations` stay, so an earlier image started against it still finds nothing to
run.

## Backup and restore

Create a backup while the project is running:

```bash
scripts/compose.sh backup
```

The helper pauses Ryker while it captures a consistent PostgreSQL dump, private state volume
(including encrypted checkpoint bodies), and the generated environment containing decryption
keys. It restarts the previously running controller even if the backup fails. Worker leases use
their normal expiry rules during this maintenance window; allow time for large bodies to copy.
Pre-deploy backups use the same database-and-files boundary. Store these owner-only archives as
sensitive material.

Restore with:

```bash
scripts/compose.sh restore .ryker/backups/ryker-YYYYMMDDTHHMMSSZ.tar.gz
```

Restore refuses an archive whose cryptographic roots differ from an existing installation. With no
existing installation state it restores the archived roots first, starts only PostgreSQL, replaces
the database and private state, then starts Ryker and verifies the exact running version. A
database containing file-backed checkpoints cannot start from an archive missing those files.
A missing, wrong or damaged root must fail; never generate a replacement key for an existing database.

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

## Local routing model

Ryker can try a small model you run yourself on routing, beside the provider model, to see
whether it could route as well (Settings › Models › Local routing model). This is phase 1, shadow
mode, and it only measures: routing always decides with the provider model and never waits for the
local one.

**What shadow mode measures.** With the mode at Compare in the background, each routing decision
Ryker accepts from the provider queues one comparison. One lane later sends the local model the
exact prompt the provider answered, with routing's response contract as structured output
(`response_format` `json_schema`), one question at a time. Each call is cut off after 120 s; an
unreachable model is asked again after 30 s, 2 min and 8 min, then given up. The answer goes through
routing's own checks, and it agrees when it would make Ryker do the same next: the same action,
earlier work, relation to that work, kind of work, repository, branch or commit, and emoji. The
words of a quick reply and the reason are not compared. Usage & cost shows how many comparisons
ran, how many answers were valid and how many agreed, the median local time beside the provider's,
what the provider spent on those messages and the part of it on messages the local model agreed on,
and the latest disagreements, each opening its request. Comparisons are operational data and leave
with their message's bodies.

**Enable it with Ollama on the Mac that runs Ryker.**

```bash
OLLAMA_CONTEXT_LENGTH=16384 ollama serve
ollama pull qwen2.5:3b
```

Then in Settings › Models › Local routing model choose Compare in the background, set the endpoint
to `http://host.docker.internal:11434/v1` and the model to `qwen2.5:3b` (or the small model you
pulled). A routing prompt runs to several thousand tokens, longer than Ollama's default context,
which would cut its start. The Compose project names the host `host.docker.internal` on Linux too.
Every routing prompt, with the message and its conversation, goes to that endpoint, so plain http is
accepted only for this machine or a private network; anywhere else needs https.

**Phase 2, the cascade, is not built.** The local model would answer first, and routing would fall
back to the provider model when the local answer is invalid or unsure, or for work that needs the
larger model. The agreement phase 1 measures, and what the provider spent on the messages the local
model agreed on, say whether that is worth building and what it would save.

## Weekly report

Settings › Weekly report turns on one post a week in a Slack channel, at a day, time and zone you
choose, saying how Ryker's week went: requests, feedback, what to fix, corrections, what it learned,
the failures that leave someone waiting, and cost. Ryker counts it from PostgreSQL with no model
turn. Invite Ryker to the channel first. Preview this week's report on that page shows what a report
sent now would say, and posts nothing.

A report covers the seven days before its send time. Turning it on posts at the next send time,
never at once. Each week sent is a row in `weekly_reports`, written when the report falls due, so a
restart never posts a week twice; after an outage Ryker posts the latest missed report once. The
post goes through the delivery lanes with the same retries as a reply, and one Slack refuses is on
Failures as "Posting the weekly report stopped", with Post the report again. This release reads
times in `Etc/UTC` only.

## Names that still say responder

The product is Ryker. A few wire names remain `responder-*` because Coop workers, webhook senders,
or previously delivered GitHub markers own those contracts. They change only with the other party:

- retained tool activity naming `responder-state`, and the immutable state-record identity `responder-state:v1` (new Coop bindings use `controller-tools`);
- webhook signature and event headers beginning `x-responder-`;
- the `responder.publication_lifecycle.v1` event type; and
- the hidden `<!-- responder-delivery:… -->` marker on already delivered GitHub comments.

These compatibility contracts are not product branding and must not be renamed independently.
