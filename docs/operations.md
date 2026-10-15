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
the `x-ryker-version` header, and prints a link that signs you in and opens setup. The link works
once, within the hour; `scripts/compose.sh sign-in` prints another.

Beside Ryker the project runs the models it uses for voice messages and for routing's search by
meaning, on the CPU, each in its own image with the model inside: about 4 GB of images and 3.5 GB
of memory. The first install builds them, which downloads 2.8 GB. Ryker works without them, with
less: see Voice messages and Search by meaning below.

The control UI, GitHub listener and universal webhook listener bind to `127.0.0.1` by default.
Change a bind address only when the surrounding network boundary is understood. External GitHub
and webhook senders need an HTTPS reverse proxy to the exact signed ingress paths. Then set the
addresses they use in `.ryker/compose.env` and run `scripts/compose.sh start`, so the setup
pages show the URLs to give GitHub and each alert source:

```bash
RYKER_GITHUB_PUBLIC_URL=https://ryker.example.com/v1/github
RYKER_WEBHOOK_PUBLIC_URL=https://ryker.example.com
```

The console signs people in itself (Signing in, below), so a tunnel such as Cloudflare Tunnel
or Tailscale Serve can carry it to browsers elsewhere. Health and readiness answer anyone who
reaches them; metrics answer only at a loopback address, as the watchdog reads them.

Inside Compose the console admits only its own loopback and `RYKER_CONTROL_PEER`, the address
published traffic arrives from: the network's gateway, `172.30.42.1` (measured under OrbStack).
A Docker runtime that forwards published ports from another address answers every page with
"Loopback access only"; set `RYKER_CONTROL_PEER` in `.ryker/compose.env` to that
address and run `scripts/compose.sh start`. Every published request arrives from that one
address, a tunnel's included, so where a request came from says nothing about who sent it, and
every page asks its person to sign in. The console still listens only on loopback: Ryker refuses
to start unless `RYKER_CONTROL_BIND` is loopback, and a tunnel reaches it there.

Links Ryker posts into Slack, such as the weekly report's, open the control UI at
`RYKER_CONTROL_PUBLIC_URL`, which is `http://127.0.0.1:` and `RYKER_CONTROL_PORT` unless
`.ryker/compose.env` sets it. Set it to the address you open the UI at when that differs, such as
an SSH tunnel's local port. It must be HTTPS or a loopback HTTP address.

## Setup and connection states

Open the sign-in link the installer prints. It signs you in and opens setup (`/setup`), which
leads through six required steps, one at a time:

1. connect and verify Slack;
2. connect and verify the GitHub App: github.com's, or a GitHub Enterprise one given by its API
   URL (`https://<host>/api/v3` for Enterprise Server, `https://api.<name>.ghe.com` for
   Enterprise Cloud), and every link, git remote and pull request is then on that host;
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
scripts/compose.sh sign-in   # a link that signs you in to the console, for an hour
```

`stop` and `uninstall` retain PostgreSQL data, Ryker state and encryption roots. `uninstall`
removes the stopped containers and network while leaving the named volumes and `.ryker/compose.env`
in place. `start` builds a model's image the first time it is turned on, and a model that does not
start is reported without stopping Ryker.

## Upgrade

Upgrades build from the checkout: no Ryker container image is published, and a GitHub Release
carries the verified release archive ([releasing.md](releasing.md)). Move the checkout to the
release you intend to run (for example `git checkout vX.Y.Z`, or `git pull` for main), then:

```bash
scripts/compose.sh backup
scripts/compose.sh upgrade
```

Upgrade pins the release HEAD builds in `.ryker/compose.env`: an annotated `vX.Y.Z` tag's version,
else `0.1.0-source.g` and twelve digits of the commit, with the image `ryker:` and that version.
Upgrade, like install, builds the checkout as it is, so it refuses a checkout with uncommitted
changes, and when the checkout has an `origin` it refuses a HEAD that origin's `main` does not hold.
`start`, `restart` and `restore` never build: they run the pinned image, and fail if it is missing.

Upgrade pulls the pinned third-party images (such as PostgreSQL and the worker's Docker daemon), rebuilds
the Ryker image from the checkout, stops Ryker and runs the migrations with the new image as a step of
their own, as a deploy does, then starts the replacements and verifies health, readiness and the exact
version header. A migration that fails leaves Ryker stopped; restore the backup taken before. It keeps
the bundled worker that runs, and pins its image in `RYKER_COOP_IMAGE`; only a first upgrade with no
worker running builds one from the Dockerfile's Coop pin. A worker moves with `worker-upgrade`.
Enrolled remote workers are not restarted or modified.

```bash
scripts/compose.sh worker-upgrade
```

moves the bundled worker to the Coop `deploy/compose/coop/Dockerfile` pins, the one place that pin
lives: it builds `ryker-coop:` and the revision's first eight digits, copies the model sign-in aside
in the worker's volume (`agents.pre-*`, the newest two kept), prepares the new worker's box on the
live worker's volumes and Docker daemon while that worker keeps working
(`deploy/compose/coop/prewarm.sh`), waits up to ten minutes for the commands the worker is carrying
out (`RYKER_WORKER_IDLE_TIMEOUT`), then pins the image and replaces only the worker, which is back in
seconds. It keeps the image it replaced as the way back and removes older worker images. Run it on
the host of each install, after `git pull`.

An install on another machine can upgrade itself instead, with nobody on its host:
`scripts/install-auto-upgrade.sh` installs a launch agent there that runs `scripts/auto-upgrade.sh`
every five minutes, and `RYKER_UPGRADE_REF` in its `compose.env` names the branch of `origin` it
follows. With `RYKER_UPGRADE_REF=main`, as the tenant install has, every push to main reaches it
within minutes; a branch of its own, pushed on purpose (`git push origin main:tenant/NAME`), makes
each upgrade a choice.

It moves only forward: a branch that does not build on the commit that runs is refused. It takes a
backup, runs `upgrade`, and runs `worker-upgrade` when the commit pins another Coop. A failed upgrade
puts the checkout and the pin back, and restores the backup it took only when the release before no
longer serves, so an image that did not build loses nothing written since. That commit is not tried
again; the next push of the branch is. A worker that did not move leaves Ryker on the new release. Its backups are
named `pre-upgrade-*` and the newest five stay (`RYKER_KEEP_UPGRADE_BACKUPS`); while another lifecycle
command, such as the daily backup, holds the lock, it waits for the next round. Each attempt is a line in `~/.local/state/ryker-upgrade/upgrades.log` on the
host, and the watchdog here sees the new version through the install's readiness.

Once the new release is ready, upgrade removes this installation's older source builds
(`ryker:0.1.0-source.*`). It keeps the release it started and the one it replaced, which a restore
of the backup taken before the upgrade runs, and it never removes a tagged release or another tag.

A worker image built another way, for example from a Coop checkout ahead of the pin, is named in
`RYKER_COOP_IMAGE` by hand, and its Coop may keep the worker's state in a schema an older pinned
Coop refuses. Inside the worker's own Docker, the entrypoint removes the box bases of older Coop
builds and the images nothing is tagged as.

Repository knowledge runs with filtered networking: the model reaches its provider and nothing
else. Coop takes a filtered job only on a Docker daemon that `coop net setup` qualified, so the
worker's entrypoint runs it before the worker connects, and the worker's image carries the Docker
CLI and Buildx from its daemon's own image, which setup builds with. A failed setup is logged
(`docker logs ryker-ryker-coop-1`) and leaves only filtered jobs refused; the next worker start
tries again.

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

Take one every day on its own:

```bash
scripts/install-backup-schedule.sh 03:30
```

It installs a launch agent on this Mac that runs `scripts/scheduled-backup.sh` at that time of
day, in the Mac's time zone, 03:30 unless you give another. Each run takes the backup above,
pausing Ryker for under a minute, names it `scheduled-YYYYMMDDTHHMMSSZ.tar.gz`, and keeps the
newest 14 scheduled backups (`RYKER_KEEP_SCHEDULED_BACKUPS`). Backups you take yourself and
pre-deploy backups are never touched. The log is `~/.local/state/ryker-backup/backup.log`. Run the
install again to change the time. The archives stay on this disk, so copy one elsewhere now and
then: they are what a lost disk is restored from.

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

## Signing in

Everyone who opens the console signs in, on this host too: a tunnel's requests reach Ryker the
same way a browser here does. A link signs one person in once, and that browser stays signed in
until 30 days after it was last used. Ryker keeps links and sessions only as digests of their
tokens.

- Ryker's operators get a link in Slack: they send Ryker `/ryker sign-in`, or open Ryker's App Home
  and press **Open the console**. The link works for 15 minutes. The operators are the people
  chosen on Integrations › Slack, and the workspace's admins unless that page turns them off.
- Anyone signed in can invite someone outside Slack on Settings › Access. The invite link works
  once, within 7 days, under the name it was given.
- On this host, `scripts/compose.sh sign-in` prints a link that works for an hour. The installer
  prints one that opens setup.

Settings › Access lists the browsers signed in and signs any of them out. Ryker has no roles:
everyone signed in can see and change everything in this install.

The browser keeps its cookie for 30 days, and Ryker writes it again at most once an hour while the
console is in use, so quitting the browser doesn't sign anyone out. The cookie is signed with a key
derived from `RYKER_CREDENTIAL_KEY`, so signing in lasts through restarts, deploys and upgrades. A
new credential key signs every browser out.

A service that publishes the console can name a person too, and then nobody needs a link: a token
Cloudflare Access signed, at the published address, or Tailscale Serve's `Tailscale-User-Login`,
at a `*.ts.net` address. Serve's headers aren't signed, so Ryker ignores them anywhere else: through
another tunnel, anyone could send them.

## The console through Cloudflare

A Cloudflare Tunnel carries the console to people outside your network, such as another company's
team, without opening a port on this host. In Cloudflare Zero Trust, Networks › Tunnels: create a
cloudflared tunnel and run the install command it shows on this host. Give the tunnel a public
hostname, such as `ryker.example.com`, whose service is `http://localhost:4321`. Then set the
address in `.ryker/compose.env` and run `scripts/compose.sh start`, which recreates the container
with it:

```bash
RYKER_CONTROL_PUBLIC_URL=https://ryker.example.com
```

The links Ryker posts now open that address, and people sign in there as anywhere else.

Cloudflare Access is optional. With it, Cloudflare signs people in with Google (or a one-time code
sent to their email) before they reach the console, and Ryker signs them in from its token:

1. Settings › Authentication: add Google as a login method. It needs an OAuth client from Google
   Cloud whose redirect URI is `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`.
   Access's built-in one-time PIN needs no setup.
2. Access › Applications: add a self-hosted application for the tunnel's hostname, with a policy
   that allows the people or email domains who may use the console. The application's overview
   shows its audience (AUD) tag.
3. Add to `.ryker/compose.env`, then run `scripts/compose.sh start`:

```bash
RYKER_CLOUDFLARE_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com
RYKER_CLOUDFLARE_ACCESS_AUD=<the application's audience tag>
```

Ryker checks each request's Access token and records what each person changes under their email.
A request without one signs in with a link, as anyone else does.

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
minute it checks `/readyz` and the pinned version, the project's containers, the models beside
Ryker, blocked work in `/metrics` and the whisper servers on the Mac's GPU when `compose.env` names
them. A failed check becomes a macOS notification and a line in its log; a model that stopped is
reported as Ryker working with less. If the watchdog has gone, run the installer again; it reports
success only once the agent is registered.

The same watchdog can watch installs on other machines, where its notification would reach
nobody. Name their published origins in `RYKER_WATCH_REMOTE` in `compose.env`, separated by
spaces, such as `RYKER_WATCH_REMOTE=https://ryker.example.com`. Only `/readyz` is public at such an
address, so the watchdog asks that, keeps strikes and repeats for each install on its own, and
says when one is ready again. It also reads the version that answer names: once a day while an
install runs a commit that this checkout's `main` has left behind, and the oldest commit it lacks
is older than a day (`WATCHDOG_REMOTE_LAG_HOURS`), it says how many commits behind it is.

`scripts/doctor.sh` checks this checkout and host for the faults that each once cost an afternoon:
Docker not answering, the test PostgreSQL not as `compose.test.yml` says, test databases and gate
locks that stopped runs left, a stopped run's work in the shared test database, `deps` or `.elixir`
turned into links, worktrees that no longer exist, a disk under 50 GB free, a missing watchdog, and
a worker behind the Coop the Dockerfile pins. `--fix` repairs what is safe without a person; it never
restarts Docker, the install or a worker, nor touches the live database.

`scripts/status.sh` answers what runs where in one screen, read-only: `main` and whether it is
pushed, CI's run on it, this checkout's install (the version it serves against `main`, the version
`compose.env` pins, the bundled worker, the Docker disk, the newest backup and whether daily backups
are scheduled, and the watchdog's last check), and the readiness and version of every install
`RYKER_WATCH_REMOTE` names.

A Mac that sleeps pauses Ryker until someone wakes it. `scripts/install-keep-awake.sh` installs a
launch agent that runs `caffeinate -i -s` from login on, so the Mac doesn't sleep when idle or on
power, after a restart too, and a laptop rides out a power cut on its battery. A laptop still sleeps
when its lid is closed without an external display.

After a restart, Ryker comes back once someone logs in: Docker starts at login if it's set to (for
colima, `brew services start colima`), and Compose restarts Ryker's containers. With FileVault on, a
Mac waits at its unlock screen after a restart until someone types the password, and macOS doesn't
log in by itself. Restart such a host with `sudo fdesetup authrestart`, which unlocks the disk once
on the way back up. A crash, or a power cut longer than the battery lasts, still needs someone at
the Mac.

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

**Turn it on.** Compose runs Qwen2.5 3B Instruct beside Ryker once `.ryker/compose.env` turns its
profile on. `start` builds its image the first time, which downloads 2.1 GB:

```bash
COMPOSE_PROFILES=routing-model    # in .ryker/compose.env
scripts/compose.sh start
```

Then in Settings › Models › Local routing model choose Compare in the background, set the endpoint
to `http://routing-model:8080/v1` and the model to `qwen2.5:3b`. The server holds 16k tokens of
context; a routing prompt runs to several thousand. It runs on the CPU at a lower priority than
everything else in the project, and takes 4.4 GB of memory: in Docker on an M3 Pro it answered a
routing prompt of 4,500 tokens in 68 s, so the longest prompts run past the 120 s limit, where a
Mac's GPU took 3 to 6 s. Any other server that answers the OpenAI chat API with structured output
works too, such as Ollama, vLLM or LM Studio; give it at least 16k tokens of context, or it cuts the
prompt's start. From Ryker's container the machine it runs on is `host.docker.internal`, on Linux
too. Every routing prompt, with the message and its conversation, goes to that endpoint, so plain
http is accepted only for this machine, Compose's own `routing-model`, or a private network;
anywhere else needs https.

**Phase 2, the cascade, is not built.** The local model would answer first, and routing would fall
back to the provider model when the local answer is invalid or unsure, or for work that needs the
larger model. The agreement phase 1 measures, and what the provider spent on the messages the local
model agreed on, say whether that is worth building and what it would save.

## Voice messages

Ryker reads Slack voice messages, and audio or video sent to Chat, as the words spoken in them.
Compose runs whisper beside Ryker on the CPU: `whisper` writes the words with large-v3-turbo, and
`whisper-detect` hears the language with whisper's small model. Ryker cuts a recording at its
pauses, hears the language of the whole, and writes it half a minute at a time, since whisper reads
30 seconds at a time however short the audio. In Docker on an M3 Pro each of those passes takes
about 15 s: a 7-second message took 21 s and a 33-second one 40 s. Given the language of the whole,
large-v3-turbo still wrote an English sentence in a Ukrainian message in English, and garbled two
words of Spanish.

A recording gets 90 seconds whichever model reads it, and the servers three quarters of that, about
two minutes of speech on the CPU. Routing waits three minutes for a message's words, two
recordings' worth. When whisper cannot be reached, fails, answers something Ryker cannot read, or
runs out of its time, Ryker's own model inside its container reads the recording in the time left,
so no voice message is lost to a stopped, upgraded or slow service; the log says
`whisper service ...` with the reason. That model is whisper's base, quick and good with English,
and weak with other languages: it wrote a message that went from Ukrainian to English to Spanish as
Russian and Portuguese.

**Several languages.** Name the languages people speak here in `.ryker/compose.env` and run
`scripts/compose.sh start`:

```bash
RYKER_VOICE_LANGUAGES=uk,en,es   # two-letter codes
```

With several named, Ryker hears each part of a recording on its own and reads it in its own
language, chosen among them, preferring the language of the whole recording: whisper is sure of a
whole recording and unsure of a few seconds of it, and read short Ukrainian parts as Portuguese,
Croatian or Russian until the choice was narrowed. Neighbouring parts in one language are written
together. Each part costs 3 s on the CPU, and the small model heard a Spanish sentence as English,
so mixing languages is best served by a GPU.

**A Mac's GPU.** On a Mac, run whisper's large-v3 on the GPU instead:

```bash
scripts/voice-service.sh install    # whisper.cpp from Homebrew, the 3.1 GB model, two launchd services
```

Then set these in `.ryker/compose.env` and run `scripts/compose.sh start`, which recreates the
Ryker container with them:

```bash
RYKER_WHISPER_URL=http://host.docker.internal:8178
RYKER_WHISPER_DETECT_URL=http://host.docker.internal:8179
```

On an M3 Pro the GPU wrote a 33-second message in Ukrainian, English and Spanish in 21 seconds,
every part in the language spoken. Both servers listen only on 127.0.0.1;
`scripts/voice-service.sh status` says whether they answer, and `uninstall` stops them. The
Compose services keep running, unused.

## Search by meaning

When a message arrives, routing looks for the earlier work it may belong to. By words and
identifiers alone it misses a message that says the same thing in other words, or in Ukrainian or
Spanish about work discussed in English. Compose runs a multilingual embedding model (bge-m3) beside
Ryker as `embeddings`, and routing also searches by meaning.

Ryker computes a vector for each request as its text changes, in the background, four requests at
a time, and one for each message as it arrives: in Docker on an M3 Pro a short message took 0.3 to
0.7 s. While the model is down, or a message's vector takes over 3 s, routing searches by words and
identifiers, each request's "How" card says why the search by meaning did not run, and the
watchdog alerts. Any server that answers the OpenAI embeddings API works: set
`RYKER_EMBEDDINGS_URL` in `.ryker/compose.env`, and `RYKER_EMBEDDINGS_MODEL` when its model is not
bge-m3.

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

- the state-record identity `responder-state:v1`, which Ryker still hashes into every state write's
  operation id, so a write retried across a deploy finds the record it made instead of making two;
- webhook signature and event headers beginning `x-responder-`;
- the `responder.publication_lifecycle.v1` event type.

These compatibility contracts are not product branding and must not be renamed independently.
