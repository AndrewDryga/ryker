# Explicit status question during unfinished work

The human question and its later `?` follow-up, saved waiting-goal detail and backup observations are
harvested from the episode named in `scenario.json`. A status question went
unanswered while the model attempted original task completion, received two
independent continue judgments, and exhausted its output attempts.

Tenant identities are pseudonymized: the host is `cassandra-dbzrk101`, the
keyspace is `tenant_ks`, the source URL uses `example.test` with an invented
resource alias, and the Slack identities reuse the evaluation corpus. Source times and random internal UUIDs
are retained. Unnecessary invocation/process identities are omitted. The two
remaining-outcome lines are a concise projection of retained work, not a new
human instruction. No model answer or judgment is invented or replayed.

`backup.status` is a read-only evaluation facade over the captured status
observation. `post_slack_update` uses the shipped argument schema but an
explicitly authored, inert pending-intent stand-in: `eval-status-update` is not
a production action ref or a Slack receipt. It records tool choice in the
closed world, never sends a message, and cannot prove delivery or active-goal
custody. The rubric checks ordering and truthful status; the real request's
post-deployment action receipt must separately prove delivery. The existing
host progress-delivery tests own persistence, destination and deduplication.

The observation clock is intentionally historical. The evaluation runner
rebases ingress receipt timing onto its disposable execution clock; the source
observations remain historical replay evidence.
