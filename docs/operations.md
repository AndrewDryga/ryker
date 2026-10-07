# Docker Compose operations

Docker Compose is the supported Ryker deployment. The canonical project contains PostgreSQL and
the immutable Ryker image, stores their data in named volumes, and keeps installation roots in the
owner-only `.ryker/compose.env` file. Do not copy Slack, GitHub, Emisar, or webhook credentials
into that file; configure those integrations in the local setup UI, where Ryker encrypts them in
PostgreSQL. Sign the Coop worker in to its model account during install or with
`scripts/compose.sh model-login`; that sign-in stays in the worker's private volume, and a login
that does not finish puts the previous sign-in back.

One lifecycle command runs at a time. The `compose.sh` commands that start, stop or replace part
of the project (install, restore, start, stop, restart, upgrade, model-login, backup, uninstall,
destroy) hold `.ryker/lifecycle.lock` while they run and refuse while another command holds it. A
lock left by a process that is gone is taken over.

PostgreSQL is the durable authority for ingress, episodes, Work, delivery, waits, schedules,
approvals, publication, worker placement and retention. Restarting containers recovers that
custody; it does not create a second deployment state.

The bundled Coop worker uses the same outbound job API as a worker on another VM. Ryker supplies
each job's code identity and settings; Coop fetches code directly on its trusted host. There are no
worker policy files, generated worker JSON, or Ryker-side repository checkouts. The shared
`ryker-coop-config` volume carries only enrollment state and the controller CA; model workspaces
remain in the worker's private state volume.

## Install

Requirements are Docker, Docker Compose v2, OpenSSL, curl and tar. From a checkout of this
repository run:

```bash
./install.sh
```

The installer creates `.ryker/` with mode `0700` and `compose.env` with mode `0600`. On the first
run it generates the database password, checkpoint key, credential-encryption key and state-tools
token. Later runs reuse them. It starts the project, waits for `/healthz` and `/readyz`, verifies
the `x-ryker-version` header, and prints one setup URL.

The control UI, GitHub listener and universal webhook listener bind to `127.0.0.1` by default.
Change a bind address only when the surrounding network boundary is understood. External GitHub
and webhook senders need an HTTPS reverse proxy to the exact signed ingress paths. Then set the
addresses they use in `.ryker/compose.env` and run `scripts/compose.sh start`, so the setup
pages show the URLs to give GitHub and each alert source:

```bash
RYKER_GITHUB_PUBLIC_URL=https://ryker.example.com/v1/github
RYKER_WEBHOOK_PUBLIC_URL=https://ryker.example.com
```

Publish the console only through Cloudflare Access or Tailscale Serve, described below. A plain
reverse proxy or tunnel to it would hand everyone who reaches it the whole console, with health,
readiness and metrics.

Inside Compose the console admits only its own loopback and `RYKER_CONTROL_PEER`, the address
published traffic arrives from: the network's gateway, `172.30.42.1` (measured under OrbStack).
A Docker runtime that forwards published ports from another address answers every page with
"Loopback access only"; set `RYKER_CONTROL_PEER` in `.ryker/compose.env` to that
address and run `scripts/compose.sh start`. Every published request arrives from that one
address, so the console cannot tell who sent it: Ryker refuses to start unless
`RYKER_CONTROL_BIND` is loopback, since any other bind would admit anyone who can reach the host.

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

Upgrade, like install, builds the checkout as it is, so it refuses a checkout with uncommitted
changes. `start`, `restart` and `restore` never build: they run the pinned image, and fail if it
is missing.

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

A database re-baselined this way keeps its older rows in `schema_migrations`, so an earlier image
started against it still finds nothing to run.

A release refuses to start on a database that a newer release has migrated, and names the newer
migrations. Restore the backup taken before that release, or upgrade to that release again.

## Backup and restore

Create a backup while the project is running:

```bash
scripts/compose.sh backup
```

The helper pauses Ryker while it captures a consistent PostgreSQL dump, private state volume
(including encrypted checkpoint bodies), and the generated environment containing decryption
keys. Ryker then runs again while the helper archives the bundled worker's state as
`worker-state.tar.gz`: its model sign-in and its identity key, without the caches Coop downloads
again or its temporary files. The worker keeps working meanwhile, and a file it changes during the
archive does not fail the backup. It restarts the previously running controller even if the backup fails. Worker leases use
their normal expiry rules during this maintenance window; allow time for large bodies to copy.
Pre-deploy backups hold the database, the encrypted files and the environment, and not the
worker's state. A deploy keeps the newest ten of them and, past those, the newest of each of the
last seven days; the backups you take yourself are never removed. Each archive is written under a
hidden name and renamed once it is whole, so one cut short never looks like a good one. Store
these owner-only archives as sensitive material.

Restore with:

```bash
scripts/compose.sh restore .ryker/backups/ryker-YYYYMMDDTHHMMSSZ.tar.gz
```

Restore refuses an archive whose encryption keys (`RYKER_CHECKPOINT_KEY`, `RYKER_CREDENTIAL_KEY`)
differ from an existing installation's. The state-tools token may differ: a backup taken before
the token was rotated restores, and the current token stays. With no
existing installation state it restores the archived roots first, unless another checkout's
installation already owns this host's database volume. It pins the release the backup was taken
on, so restoring a pre-deploy backup rolls the deploy back; that release's image must be on this
host, or the restore stops before changing anything. It then checks the archive before
changing anything: it must hold the database dump, the environment and the encrypted files, and the
dump must read. Only then does it stop Ryker, restore the database beside the live one, and swap
the restored copy in once it is whole; the database Ryker ran on before stays as
`ryker_before_restore` until the next restore. A restore that fails leaves the previous database
as it was and Ryker stopped. It then restores the private state and, when the archive holds it,
the worker's state, starts the pinned image without
building anything, and verifies the exact running version. A missing, wrong or damaged root must
fail; never generate a replacement key for an existing database.

### Rotating the state-tools token

`RYKER_STATE_TOOLS_TOKEN` signs the token each turn gets for Ryker's tools, and the cursors of a
memory search. Rotate it when it may have been seen: replace it in place and start Ryker again.

```bash
sed -i '' "s|^RYKER_STATE_TOOLS_TOKEN=.*|RYKER_STATE_TOOLS_TOKEN=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')|" .ryker/compose.env
scripts/compose.sh start
```

On Linux, `sed -i` takes no `''`. Nothing is printed, and `start` recreates only the Ryker
container. A running turn keeps its tools, since Ryker finds a turn's token by its stored digest;
a memory search's next-page cursor handed out before the rotation is refused as invalid. Backups
taken before the rotation still restore.

## Destruction

Stopping Ryker is recoverable. Deleting volumes and keys is not. The destructive path requires an
explicit phrase:

```bash
RYKER_DESTROY_CONFIRM=delete-ryker-data scripts/compose.sh destroy
```

This removes the Compose volumes and generated environment. It cannot recover encrypted
credentials, checkpoints or historical evidence without a backup. The helper says exactly what it
removed after the operation.

## The console through Cloudflare Access

People who should not join your tailnet, such as another company's team, reach the console through
Cloudflare Access instead. Cloudflare signs them in with Google (or a one-time code sent to their
email), and only the people its policy names get through. Ryker checks each request's Access token
and records what each person changes under their email. Ryker has no roles: everyone the policy
lets in can see and change everything in this install.

In Cloudflare Zero Trust:

1. Settings › Authentication: add Google as a login method. It needs an OAuth client from Google
   Cloud whose redirect URI is `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`.
   Access's built-in one-time PIN needs no setup.
2. Networks › Tunnels: create a cloudflared tunnel and run the install command it shows on this
   host. Give the tunnel a public hostname, such as `ryker.example.com`, whose service is
   `http://localhost:4321`.
3. Access › Applications: add a self-hosted application for that hostname, with a policy that
   allows the people or email domains who may use the console. The application's overview shows
   its audience (AUD) tag.

Then set, in `.ryker/compose.env`:

```bash
RYKER_CONTROL_PUBLIC_URL=https://ryker.example.com
RYKER_CLOUDFLARE_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com
RYKER_CLOUDFLARE_ACCESS_AUD=<the application's audience tag>
```

and run `scripts/compose.sh start`, which recreates the container with the new settings. The
links Ryker posts now open that address. A request there
without a token Access signed for the application is refused; the console at `127.0.0.1` works as
before.

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

On a Mac, `scripts/install-watchdog.sh` installs `scripts/watchdog.sh` as a launch agent. Once a
minute it checks `/readyz` and the pinned version, the project's containers, blocked work in
`/metrics` and the helper servers `compose.env` names. A failed check becomes a macOS notification
and a line in its log. If the watchdog has gone, run the installer again; it reports success only
once the agent is registered.

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
words of a quick reply and the reason are not compared. Its page, See how it compares on the Local
routing model card in Settings › Models (`/settings/models/local-routing`), shows how many
comparisons ran, how many answers were valid and how many agreed, the median local time beside the
provider's, what the provider spent on those messages and the part of it on messages the local model
agreed on, the latest disagreements, and the latest answers routing's checks refused with why, such
as earlier work that was never offered; each opens its request. Comparisons are operational data and
leave with their message's bodies.

**Enable it on a Mac that runs Ryker.**

```bash
scripts/routing-model-service.sh install    # llama.cpp from Homebrew, Qwen2.5 3B Instruct (2.1 GB), one launchd service
```

Then in Settings › Models › Local routing model choose Compare in the background, set the endpoint
to `http://host.docker.internal:8181/v1` and the model to `qwen2.5:3b`. The server holds 16k tokens
of context; a routing prompt runs to several thousand. On an M3 Pro it answers a routing prompt in
3 to 6 s. Any other server that answers the OpenAI chat API with structured output works too, such as
Ollama, vLLM or LM Studio; give it at least 16k tokens of context, or it cuts the prompt's start.
The Compose project names the host `host.docker.internal` on Linux too. Every routing prompt, with
the message and its conversation, goes to that endpoint, so plain http is accepted only for this
machine or a private network; anywhere else needs https.

**Phase 2, the cascade, is not built.** The local model would answer first, and routing would fall
back to the provider model when the local answer is invalid or unsure, or for work that needs the
larger model. The agreement phase 1 measures, and what the provider spent on the messages the local
model agreed on, say whether that is worth building and what it would save.

## Voice messages

Ryker reads Slack voice messages, and audio or video sent to Chat, as the words spoken in them.
Out of the box it transcribes inside its container with whisper's small base model, which is
quick and good with English, and weak with other languages: it wrote a message that went from
Ukrainian to English to Spanish as Russian and Portuguese.

On a Mac, run whisper's large-v3 on the GPU instead:

```bash
scripts/voice-service.sh install    # whisper.cpp from Homebrew, the 3.1 GB model, two launchd services
```

Then set these in `.ryker/compose.env` and run `scripts/compose.sh start`, which recreates the
Ryker container with them:

```bash
RYKER_WHISPER_URL=http://host.docker.internal:8178
RYKER_WHISPER_DETECT_URL=http://host.docker.internal:8179
RYKER_VOICE_LANGUAGES=uk,en,es   # the languages people speak here, as two-letter codes
```

Ryker cuts a recording at its pauses and reads each part in its own language, chosen among the
languages people speak here, preferring the language of the whole recording: whisper is sure of
a whole recording and unsure of a few seconds of it, and read short Ukrainian parts as
Portuguese, Croatian or Russian until the choice was narrowed. Both servers listen only on
127.0.0.1; `scripts/voice-service.sh status` says whether they answer, and `uninstall` stops
them.

On an M3 Pro a 33-second message takes 24 seconds and a five-minute one 67, after Slack has been
answered. A recording gets 90 seconds whichever model reads it, and routing waits three minutes
for a message's words, two recordings' worth. When whisper cannot be reached, fails, answers
something Ryker cannot read, or stops answering, Ryker's own model reads the recording in the time
left, so no voice message is lost to a stopped or upgraded service; the log says
`whisper service ...` with the reason.

## Search by meaning

When a message arrives, routing looks for the earlier work it may belong to. By words and
identifiers alone it misses a message that says the same thing in other words, or in Ukrainian or
Spanish about work discussed in English. On a Mac, run a multilingual embedding model (bge-m3) on
the GPU and routing also searches by meaning:

```bash
scripts/embedding-service.sh install    # llama.cpp from Homebrew, the 635 MB model, a launchd service
```

Then set in `.ryker/compose.env` and run `scripts/compose.sh start`:

```bash
RYKER_EMBEDDINGS_URL=http://host.docker.internal:8180
```

Ryker computes a vector for each request as its text changes, in the background, and one for each
message as it arrives, in about 30 ms. The server listens only on 127.0.0.1; `status` says whether
it answers and `uninstall` stops it. While it is down, routing searches by words and identifiers,
each request's "How" card says why the search by meaning did not run, and the watchdog alerts. Any
server that answers the OpenAI embeddings API works; `RYKER_EMBEDDINGS_MODEL` names its model when
it is not bge-m3.

## Weekly report

Settings › Weekly report turns on one post a week in a Slack channel, at a day, time and zone you
choose, saying how Ryker's week went the way a teammate writes a weekly update: the PRs it opened
that week and the ones already merged, every PR still waiting for review and how long it has waited,
how many messages it handled, how long a typical (middle) reply took and how many were quick
answers, the questions it is waiting on people to answer, anything stuck, and a closing line on
feedback, what it learned and what the week's work cost (an estimate at API prices when the provider
reports no price, as a ChatGPT sign-in never does). It names no Slack request it merely answered and
gives no completion rate. Ryker writes it from PostgreSQL with no model turn. Invite Ryker to the
channel first. Preview this week's report on that page shows what a report sent now would say; Send
to the channel posts it there at once, titled as a preview, even while the report is off. A preview
is its own row in `weekly_reports` (`preview`) and never the week's report.

A report covers the seven days before its send time. Turning it on posts at the next send time,
never at once. Each week sent is a row in `weekly_reports`, written when the report falls due, so a
restart never posts a week twice; after an outage Ryker posts the latest missed report once. The
post goes through the delivery lanes with the same retries as a reply, and one Slack refuses is on
Failures as "Posting the weekly report stopped", with Post the report again. This release reads
times in `Etc/UTC` only.

## Names that still say responder

The product is Ryker. A few names remain `responder-*`: wire names Coop workers or webhook senders
own, which change only with the other party, and identities stored data already carries:

- retained tool activity naming `responder-state` (new Coop bindings use `controller-tools`);
- the state-record identity `responder-state:v1`, which Ryker still hashes into every state write's
  operation id, so a write retried across a deploy finds the record it made instead of making two;
- `responder_state_tools` in prompt contexts saved before the rename, which a request's page shows;
- webhook signature and event headers beginning `x-responder-`;
- the `responder.publication_lifecycle.v1` event type.

These compatibility contracts are not product branding and must not be renamed independently.
