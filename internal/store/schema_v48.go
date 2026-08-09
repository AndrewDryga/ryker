package store

// schemaV48 records what each attempt spent, in tokens.
//
// context_manifests already froze which model answered an attempt — provider,
// model, reasoning_effort — but nothing anywhere recorded what that answer
// cost. Coop only learned to report it in its schema v5, so until now there was
// no number to keep: the control plane could list a hundred finished attempts
// and not one token count for any of them, and the Usage page had nothing to
// read.
//
// Columns on context_manifests rather than a usage table. Exactly one usage
// figure exists per attempt and the manifest is already the per-attempt row, so
// a separate table would add a join and a second row to keep in step with no
// second fact to hold.
//
// usage_last_turn_id is the fifth column and it is not decoration. The counts
// accumulate, because one attempt can run several Coop turns, and the write
// happens on the way out of a terminal turn — a path that runs again if the
// staging that follows it fails. Without an idempotency key that retry would
// add the same turn's tokens twice and the total would drift upward with no way
// to tell inflated numbers from real ones. Keyed on the turn already recorded,
// the repeat matches nothing and does nothing.
//
// Cached input is stored apart from the input total because Coop reports it
// apart. Every provider prices a cache read differently, so a column that
// folded the two together could not be turned back into a cost.
//
// ADD COLUMN with a constant default, deliberately: SQLite fills existing rows
// in place, so no row is copied and none can be dropped. This is not the
// rebuild recipe that migration 47 needed — context_manifests is referenced by
// context_manifest_refs ON DELETE CASCADE, and a rebuild here would take those
// references with it, which is the failure that cost 9934 episode events when
// work_episodes was rebuilt with foreign keys on. Nothing here is added to
// tableRebuildMigrations because nothing here rebuilds a table.
//
// NOT NULL DEFAULT 0 rather than nullable. It looks like it throws away the
// difference between "no provider measured this turn" and "the turn was free",
// but Coop cannot report that difference either: it stores the same 0 for both
// and derives Usage.Recorded from whether any count exceeds zero. A nullable
// column would offer a distinction with nothing to populate it, so every
// attempt that ran before this migration reads as not recorded, which is what
// it is.
const schemaV48 = `
ALTER TABLE context_manifests ADD COLUMN usage_input_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE context_manifests ADD COLUMN usage_cached_input_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE context_manifests ADD COLUMN usage_output_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE context_manifests ADD COLUMN usage_reasoning_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE context_manifests ADD COLUMN usage_last_turn_id TEXT NOT NULL DEFAULT '';
`
