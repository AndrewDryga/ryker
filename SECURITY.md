# Security model

## Report a vulnerability

Do not include credentials, incident evidence, customer logs, or working exploit details in a
public issue. Use the repository's
[private vulnerability report](https://github.com/AndrewDryga/ryker/security/advisories/new)
with the affected version, impact, and a minimal reproduction.

## Trust boundaries

Ryker is trusted with Slack application credentials, webhook secrets, the worker-gateway
certificate authority, and the workspace checkpoint key. Coop is trusted with provider credentials
and the configured repository policies. Emisar independently authorizes infrastructure actions.

In the Docker Compose deployment Ryker and the bundled Coop worker are separate containers. The
worker reaches Ryker only through the outbound worker gateway over mutual TLS, and its boxes run
in a private Docker daemon container, never on the host's socket. That daemon container runs
privileged, as Docker in Docker requires. The one volume Ryker and the worker share holds the
worker's configuration; it is a transport boundary between processes of the same unprivileged
user ID, not malicious-process isolation.

## Controls

- Configuration rejects unknown fields and arbitrary repository or policy selection from input.
- The console listens on loopback, or in Compose on its container interface, where it admits only
  its own loopback and the address published traffic arrives from (`RYKER_CONTROL_PEER`, the
  network gateway). Other containers on that network, including the boxes the worker runs model
  work in, are refused, and Ryker does not start with the console published beyond host
  loopback (`RYKER_CONTROL_BIND`). Webhook bodies are bounded before parsing.
- Webhooks require constant-time bearer verification or timestamped HMAC verification. HMAC
  signatures bind the stable event ID used for deduplication.
- Slack input is persisted before acknowledgement and accepted only from configured full members.
- Alerts, Slack text, links, logs, and repository content are framed as untrusted data.
- Coop mutations use stable idempotency keys and compare-and-swap revisions.
- Slack output strips control codes, neutralizes mentions, redacts known token forms and configured
  secrets, and enforces a size limit.
- The agent receives no Slack token, webhook secret, merge key, signing key, or deployment authority.

Output redaction is defense in depth, not a complete data-loss-prevention system. Operators must
scope Emisar and provider credentials for incident response and keep sensitive repositories out of
policies that do not need them.

## Deployment

- Keep the installation state owner-only: `.ryker/` at mode `0700`, and `.ryker/compose.env` and
  every backup under `.ryker/backups/` at mode `0600`. They hold the database password and the
  encryption roots; a backup is as sensitive as the database it restores. A backup from
  `scripts/compose.sh backup` also holds `worker-state.tar.gz`, the bundled worker's model
  sign-in and identity key.
- Ryker and the worker run as an unprivileged user and keep mutable state in named volumes. Two
  containers do not: `volume-init` runs once as root to give the volumes to that user, and the
  worker's Docker daemon runs privileged. Never mount the host's Docker socket into Ryker or the
  worker; the worker's boxes belong to the private `ryker-coop-docker` daemon.
- Terminate TLS at a maintained reverse proxy and publish only `/v1/github` and `/v1/hooks/`.
- Compose publishes the console's port, which also serves `/healthz`, `/readyz` and `/metrics`,
  and the GitHub and webhook listeners on the host's loopback only, and PostgreSQL and the worker
  socket not at all. Keep it that way, or put the console behind Cloudflare Access or Tailscale
  Serve as `docs/operations.md` describes.
- Enroll each remote Coop worker with `scripts/compose.sh worker-token`, and drain, resume or
  revoke one with `worker-drain`, `worker-resume` and `worker-revoke`. Keep its enrollment token,
  identity, and journal owner-private. Workers connect outbound over mutual TLS; never expose the
  operator control plane to reach a worker.
- Coop never receives Ryker's Slack, webhook or Emisar secrets, or the GitHub App's private key.
  A worker gets short-lived installation tokens for one repository: one that can only read, to
  fetch the code it works on, and, for a publication someone approved, one that can push the
  branch and open the pull request. Work reaches Emisar through Ryker's own tool server, which
  forwards each call with the environment's Emisar key; the key stays on the Ryker host, and an
  Emisar answer that carries it is withheld.
- Use observe-only Emisar credentials when Slack should only investigate. To support explicit
  operator-directed actions, use a narrowly scoped Emisar credential whose server-side policy,
  approval, runner validation, and audit remain authoritative; prompts never grant authority.
- Do not add GitHub, deploy, merge, or signing credentials to the agent box.
- Verify the checksum manifest's keyless cosign bundle and the selected archive checksum
  (`scripts/check-release.sh`) and GitHub build provenance before installing a release.
