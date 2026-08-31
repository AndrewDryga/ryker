# Elixir replacement cutover

This runbook performs the one clean production transition from the legacy Go/SQLite service to the
Elixir/PostgreSQL service. It does not create a compatibility reader or a dual-write period. The old
binary and a frozen SQLite snapshot remain rollback artifacts for a bounded window; only necessary
live state is imported into the replacement.

The cutover imports:

- unexpired operational memory and guidance;
- enabled or paused standing assignments and schedules that still have a next occurrence;
- explicitly reviewed unfinished episodes; and
- explicitly reviewed open input/event waits whose parent episode is also imported.

Terminal episode history, completed attempts, progress projections, outcomes, and the wider legacy
corpus remain in the read-only SQLite archive. They do not become replacement runtime state.

## Preconditions

Do not start the writer freeze until all of these are true:

1. `make elixir-check`, `make elixir-product-e2e`, and deterministic host replay are green at the
   exact candidate commit.
2. The production-surface model-world gate has passed for the exact policy digests in the candidate
   configuration.
3. Credentialed Slack, GitHub, Emisar, delivery-loss, and remote-worker acceptance journeys have
   passed against the exact release and policy digests.
4. The immutable Elixir release, configuration, secrets, PostgreSQL backup, and rollback owner are
   ready, but no replacement platform listener is accepting production input.
5. The configured `cutover_profiles` cover every `(authority, repository)` pair that may be selected
   for import. Unknown placement fails the entire import.

The importer accepts exactly the final legacy Go schema, not merely any positive schema version. The
frozen database must report schema version `90`, and the canonical digest of every non-SQLite object
in `sqlite_schema` must be
`e9aaa44b42dac7b2afe4e5740bcf6e4d24b9f93c2c2182781374e12e6643c535`. Inventory records both values
in the sealed source document; preparation and the PostgreSQL ledger enforce them again. Any mismatch
means the source binary/schema is not the reviewed cutover source and the cutover must stop.

Use an owner-private directory on the production host for all artifacts. Commands below assume the
exact candidate checkout is `/srv/responder-candidate`, the legacy database is
`/var/lib/responder/responder.db`, and the artifact directory is `/var/lib/responder/cutover`.
Replace those paths with the real absolute paths before the freeze.

## 1. Freeze every legacy writer

Stop legacy admission, workers, delivery, schedules, and maintenance as one service. Do not start the
replacement yet. Verify no process has the legacy database open and record the freeze time in UTC.
The cutover timestamp is the first instant for which the replacement owns chronology; it must not be
invented later during review.

Create the artifact directory before the maintenance window and make it owner-only:

```bash
install -d -m 0700 /var/lib/responder/cutover
```

After the legacy service is stopped, create a standalone SQLite snapshot and verify it. `VACUUM INTO`
is run only against the quiescent database; the source database itself remains untouched for rollback.

```bash
sqlite3 /var/lib/responder/responder.db \
  "VACUUM INTO '/var/lib/responder/cutover/responder-frozen.db'"
chmod 0600 /var/lib/responder/cutover/responder-frozen.db
sqlite3 -readonly /var/lib/responder/cutover/responder-frozen.db 'PRAGMA quick_check;'
sha256sum /var/lib/responder/cutover/responder-frozen.db \
  > /var/lib/responder/cutover/responder-frozen.db.sha256
test ! -e /var/lib/responder/cutover/responder-frozen.db-wal
test ! -e /var/lib/responder/cutover/responder-frozen.db-shm
```

The quick check must print exactly `ok`. If a writer restarts, a sidecar appears, or the source changes
before inventory completes, abort the cutover and repeat the freeze from the beginning.

## 2. Seal and inspect the inventory

From the exact candidate checkout, create the manifest once. The destination is exclusive and mode
`0600`; the command refuses to overwrite an earlier artifact or inspect a live WAL snapshot.

```bash
cd /srv/responder-candidate
MIX_ENV=prod mix responder.cutover inventory \
  /var/lib/responder/cutover/responder-frozen.db \
  /var/lib/responder/cutover/manifest.json \
  slack:T0123456789 \
  2026-08-30T18:00:00.000000Z
```

Inspect the sealed file, not only the command summary:

```bash
jq '.manifest.summary, .manifest.items[] | {id, decision, source}' \
  /var/lib/responder/cutover/manifest.json
```

Every item whose inventory decision is `review` must receive an explicit `import` or `skip` decision.
Open waits may be imported only with their parent episode. Unknown source tables, predicates,
recurrences, authorities, repositories, actor filters, or destinations are blockers; never rewrite
them to a wider default.

Create `/var/lib/responder/cutover/review.json` with mode `0600`:

```json
{
  "decisions": {
    "episode:legacy-episode-id": "import",
    "wait:legacy-wait-id": "import"
  },
  "manifest_sha256": "the manifest.json top-level sha256 field",
  "operator_ref": "operator:andrew",
  "reviewed_at": "2026-08-30T18:05:00.000000Z",
  "version": 1
}
```

`manifest_sha256` is the top-level `sha256` inside `manifest.json`; it is not the SHA-256 of the file
printed by the inventory command. The review timestamp must be UTC and cannot precede the cutover
timestamp.

## 3. Prepare the durable plan

Preparation writes the sealed manifest, review digest, operator, and one row per decision to the
PostgreSQL cutover ledger. It starts only a temporary repository process; it does not start admission,
Work, delivery, or platform listeners.

```bash
MIX_ENV=prod mix responder.cutover prepare \
  /var/lib/responder/cutover/manifest.json \
  /var/lib/responder/cutover/review.json
```

Record the returned `run_id`. Repeating the exact command is idempotent. Reusing the same manifest
with different review bytes is rejected.

Before apply, inspect the plan through the database owner connection:

```sql
SELECT id, status, manifest_sha256, review_sha256,
       source_schema_version, source_schema_sha256,
       operator_ref, item_count
FROM responder_cutover_runs
WHERE id = '<run-id>';

SELECT kind, decision, status, count(*)
FROM responder_cutover_items
WHERE run_id = '<run-id>'
GROUP BY kind, decision, status
ORDER BY kind, decision, status;
```

The run must be `prepared`; every imported item must be `pending`, every skipped item must be
`skipped`, the source schema must match the exact version and digest above, and the counts must match
the reviewed manifest.

## 4. Apply atomically

Take and verify a PostgreSQL backup immediately before apply. Then import using the exact production
configuration that will start the replacement:

```bash
MIX_ENV=prod mix responder.cutover apply \
  '<run-id>' \
  /etc/responder/responder-elixir.yaml
```

The import holds the global cutover lock and is atomic. It creates explicit cutover provenance rather
than fake model offers, confirmations, or provider sessions. Unfinished episodes receive fresh local
Work custody under the reviewed policy digest; old provider-native session IDs remain archive data.
Any invalid item, missing placement, constraint failure, or dependency rolls the complete import back
to `prepared`.

Verify the applied ledger before starting listeners:

```sql
SELECT status, applied_at, item_count
FROM responder_cutover_runs
WHERE id = '<run-id>';

SELECT status, count(*)
FROM responder_cutover_items
WHERE run_id = '<run-id>'
GROUP BY status
ORDER BY status;
```

The run must be `applied`; every non-skipped item must be `applied` with nonempty target references and
a target fingerprint. Verify the imported memory, behavior, schedule, episode, wait, and Work counts
against `manifest.summary` before enabling any production input.

## 5. Activate one writer and verify

Start the immutable Elixir release with the reviewed configuration. Keep the Go service stopped. There
must never be two Slack sockets, webhook/GitHub listeners, schedule dispatchers, or delivery workers
owning the same production identity.

Before declaring the cutover live, require all of the following:

- `/healthz` and `/readyz` are green for every configured runtime;
- no cutover item is pending or failed;
- admission, Work, delivery, approval, publication, schedule, event-wait, and retention queues have no
  unexplained claimable or blocked work;
- one authorized Slack thread continuation reaches its bound thread exactly once;
- one GitHub comment or review event and one reaction round-trip through their configured binding;
- one generic webhook reaches its configured delivery adapter;
- one governed Emisar approval resumes only its exact episode; and
- one remote worker disconnect/reclaim path preserves session, state-tool, and delivery fencing.

Record the candidate version, configuration digest, policy digests, cutover run ID, queue snapshot, and
acceptance receipts together. A green deterministic gate is not evidence that these live integrations
ran. No separate canary or promote state is required: recovery comes from the verified PostgreSQL
backup, frozen SQLite source, immutable releases, and the bounded rollback procedure below.

## 6. Bounded rollback

Rollback is allowed only while every imported target still has its original fingerprint. It refuses
to erase memory that was recalled, automation that fired, work that was claimed, an episode that
advanced, or a schedule that dispatched.

If rollback remains safe:

1. stop all Elixir admission, workers, delivery, and platform listeners;
2. preserve the PostgreSQL database and logs for diagnosis;
3. run the exact rollback command;
4. verify the run is `rolled_back` and every applied item is `rolled_back`;
5. restart the old binary against the untouched legacy database; and
6. verify old readiness and one private input before reopening normal traffic.

```bash
cd /srv/responder-candidate
MIX_ENV=prod mix responder.cutover rollback '<run-id>' operator:andrew
```

An error such as `cutover_target_changed` is a hard stop, not permission to delete rows manually. At
that point use the PostgreSQL backup and an incident-specific recovery plan that preserves already
visible effects.

## 7. Close the window

After the sustained production soak and queue/journey review:

- retain the frozen SQLite database, its hash, the old binary, the manifest, review, run ID, and
  acceptance evidence under the configured audit retention;
- allow normal retention to replace copied legacy item bodies with a bounded `retention: pruned`
  marker after the audit horizon and terminal cutover state; source hashes, target references, target
  fingerprints, review identity, and the immutable frozen SQLite artifact remain the audit proof;
- remove legacy launch/systemd wiring so it cannot reacquire platform identities;
- delete superseded Go runtime paths and temporary cutover scaffolding in a separately reviewed
  change; and
- keep the old corpus read-only as audit/fixture provenance until its retention decision is executed.

Do not re-enable a legacy reader or dual-write path after the window. New state belongs only to the
replacement PostgreSQL model.
