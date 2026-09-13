# Security model

## Report a vulnerability

Do not include credentials, incident evidence, customer logs, or working exploit details in a
public issue. Use the repository's
[private vulnerability report](https://github.com/AndrewDryga/responder/security/advisories/new)
with the affected version, impact, and a minimal reproduction.

## Trust boundaries

Ryker is trusted with Slack application credentials, webhook secrets, the worker-gateway
certificate authority, and the workspace checkpoint key. Coop is trusted with provider credentials
and the configured repository policies. Emisar independently authorizes infrastructure actions.

The owner-only Coop Unix socket is a local transport boundary, not malicious-process isolation when
Ryker and Coop use the same Unix account. Systemd hardening reduces accidental exposure but
does not change that fact.

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

- Use a dedicated Unix account. Keep mutable state and Coop state directories owner-only at
  mode `0700`; keep root-owned service configuration at directory mode `0750` and file mode `0640`.
- Terminate TLS at a maintained reverse proxy and publish only `/v1/github` and `/v1/hooks/`.
- Keep `/healthz`, `/readyz`, `/metrics`, PostgreSQL, and the Coop socket private.
- Enroll each Coop worker with `mix ryker.coop_worker enroll` and keep its enrollment token,
  identity, and journal owner-private. Workers connect outbound over mutual TLS; never expose the
  operator control plane to reach a worker.
- Grant Docker socket access only to the Coop process. The shipped systemd unit adds the `docker`
  supplementary group to Coop, not to Ryker.
- Coop never receives Ryker's Slack, webhook, GitHub, or Emisar secrets: the fleet protocol carries
  placement identities and the bounded submission only. Emisar access comes from Coop's own
  owner-private configuration.
- Use observe-only Emisar credentials when Slack should only investigate. To support explicit
  operator-directed actions, use a narrowly scoped Emisar credential whose server-side policy,
  approval, runner validation, and audit remain authoritative; prompts never grant authority.
- Do not add GitHub, deploy, merge, or signing credentials to the agent box.
- Verify the checksum manifest's keyless cosign bundle, the selected archive checksum, and GitHub
  build provenance before installing a release.
