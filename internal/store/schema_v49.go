package store

// schemaV49 records how long each attempt took, and where the time went.
//
// Migration 48 answered what an attempt spent in tokens. It did not answer what
// it spent in wall-clock, and neither did anything else: episode duration can be
// subtracted out of two timestamps, but "the answer took four minutes" and "the
// model took four minutes" are different faults with different fixes, and
// nothing recorded which one had happened. An operator asking why a reply was
// slow had one number, and it was the only number that could not tell them.
//
// Three spans, because there are three places a turn waits and they fail
// independently. usage_queued_ms is Coop holding the turn before a provider
// picked it up — a busy session or an exhausted ladder. usage_provider_ms is the
// provider working. usage_host_ms is Responder not yet having noticed the turn
// finished; it polls, so that gap is real, is nobody else's, and is the one span
// this repository can actually fix.
//
// usage_provider_ms is not split into inference and tool calls. Coop's turn
// record carries queued_at, started_at and finished_at and nothing between them,
// and its activity states are session lifecycle rather than what the model is
// doing. The split would have to be invented, and an invented split in a latency
// report is a guess wearing a measurement's clothes.
//
// usage_timed_turns is the fourth column and it carries two jobs. It is the
// divisor: an attempt runs several turns when the host rejects a result and
// sends it back as a correction, so the sums are totals and a per-turn figure
// needs the count. It is also the recorded flag — zero sums are ambiguous
// between "instant" and "unmeasured", and a turn that failed while still queued
// has no started_at to subtract from, so it contributes no span and must not
// enter the divisor either.
//
// Milliseconds. Turns run for seconds to minutes, so sub-millisecond resolution
// would be precision nobody has, and an integer count of them reads directly in
// a sqlite shell without a unit conversion in the reader's head.
//
// ADD COLUMN with a constant default, the same as migration 48 and for the same
// reason: SQLite fills existing rows in place, so no table is rebuilt and no row
// is copied. context_manifests is referenced by context_manifest_refs ON DELETE
// CASCADE, and reaching for the rebuild recipe here would take those references
// with it — which is the failure that cost 9934 episode events when
// work_episodes was rebuilt with foreign keys on. Nothing here belongs in
// tableRebuildMigrations because nothing here rebuilds a table.
const schemaV49 = `
ALTER TABLE context_manifests ADD COLUMN usage_timed_turns INTEGER NOT NULL DEFAULT 0;
ALTER TABLE context_manifests ADD COLUMN usage_queued_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE context_manifests ADD COLUMN usage_provider_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE context_manifests ADD COLUMN usage_host_ms INTEGER NOT NULL DEFAULT 0;
`
