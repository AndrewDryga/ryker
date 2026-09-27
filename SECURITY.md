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
in a private Docker daemon container, never on the host's socket. The volumes the two share
(worker configuration and workspaces) are a transport boundary between processes of the same
unprivileged user ID, not malicious-process isolation.

## Controls

- Configuration rejects unknown fields and arbitrary repository or policy selection from input.
- The HTTP listener is loopback-only and webhook bodies are bounded before parsing.
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
  encryption roots; a backup is as sensitive as the database it restores.
- The containers run as an unprivileged user and keep mutable state in named volumes. Never mount
  the host's Docker socket into Ryker or the worker; the worker's boxes belong to the private
  `ryker-coop-docker` daemon.
- Terminate TLS at a maintained reverse proxy and publish only `/v1/github` and `/v1/hooks/`.
- The control UI, `/healthz`, `/readyz` and `/metrics` bind to loopback by default, and PostgreSQL
  and the worker socket are not published at all. Keep it that way.
- Enroll each remote Coop worker with `mix ryker.coop_worker enroll` and keep its enrollment
  token, identity, and journal owner-private. Workers connect outbound over mutual TLS; never
  expose the operator control plane to reach a worker.
- Coop never receives Ryker's Slack, webhook, GitHub, or Emisar secrets: the fleet protocol carries
  placement identities and the bounded submission only. Work reaches Emisar through Ryker's own
  tool server, which forwards each call with the environment's Emisar key; the key stays on the
  Ryker host, and an Emisar answer that carries it is withheld.
- Use observe-only Emisar credentials when Slack should only investigate. To support explicit
  operator-directed actions, use a narrowly scoped Emisar credential whose server-side policy,
  approval, runner validation, and audit remain authoritative; prompts never grant authority.
- Do not add GitHub, deploy, merge, or signing credentials to the agent box.
- Verify the checksum manifest's keyless cosign bundle and the selected archive checksum
  (`scripts/check-release.sh`) and GitHub build provenance before installing a release.
