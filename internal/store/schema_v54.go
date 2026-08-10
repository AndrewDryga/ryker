package store

// schemaV54 gives the quality watcher's findings somewhere to live.
//
// scripts/quality-watch.sh reads every completed turn, asks an assessor whether
// it reveals a product defect, and then asks a second adversarial reviewer to
// disprove it. Both halves work: over the first week it reviewed 220 batches,
// answered "no defect" 80 times, and the challenger killed 23 proposed defects
// that did not survive contact with the code.
//
// Nothing kept the 60 that did survive. The only durable trace of a confirmed
// defect was a quarantined worktree nobody opens and one line in a log that
// rotates, so a week of real analysis of real production turns reached no
// person at all. This table is where a finding lands instead.
//
// It records both verdicts. A rejection is not noise: it is the challenger
// visibly earning its place, and an operator reading a run of them learns that
// the assessor is over-eager in a way no aggregate would show.
//
// The columns are the assessment schema flattened
// (scripts/quality-watch-assessment.schema.json), with the arrays kept as JSON
// text because they are read whole and displayed whole, never filtered on.
// disposition says what happened after the finding was recorded — 'recorded'
// when nothing else was attempted, and the fixer path overwrites it with
// 'quarantined', 'integrated', or 'declined' when it runs. artifacts is the
// review-directory prefix holding the full prompts and transcripts, which
// expire on the same horizon the row does, so the pointer never outlives what
// it points at.
//
// The writer is the watcher itself, over sqlite3, not a Store method: the
// dashboard already reads this database through its own read-only connection,
// and Store is at its exported-method budget. A plain CREATE TABLE, so nothing
// here belongs in tableRebuildMigrations and no existing row is touched.
const schemaV54 = `
CREATE TABLE quality_findings (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL DEFAULT '',
  episode_ids TEXT NOT NULL DEFAULT '[]',
  channel_id TEXT NOT NULL DEFAULT '',
  verdict TEXT NOT NULL CHECK (verdict IN ('confirmed', 'rejected')),
  disposition TEXT NOT NULL DEFAULT 'recorded',
  severity TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  expected_behavior TEXT NOT NULL DEFAULT '',
  evidence TEXT NOT NULL DEFAULT '[]',
  code_evidence TEXT NOT NULL DEFAULT '[]',
  suspected_components TEXT NOT NULL DEFAULT '[]',
  regression_test TEXT NOT NULL DEFAULT '',
  challenger_summary TEXT NOT NULL DEFAULT '',
  challenger_evidence TEXT NOT NULL DEFAULT '[]',
  artifacts TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE INDEX quality_findings_recent_idx ON quality_findings(created_at DESC);
`
