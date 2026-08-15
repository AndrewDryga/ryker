package migrationddl

// V83 records which endings the self-improvement pass has already judged.
//
// The pass in .agent/skills/self-improve/SKILL.md §6 reads terminal episodes'
// full timelines with a frontier model and is run daily. Nothing on disk said
// which traces yesterday's pass had read, so every pass re-read the whole
// history to find the few endings that were new — the cost of a daily review
// grew with the corpus it reviews, which is the shape that stops a daily
// review from being daily. The operator asked for this ledger on 2026-08-15.
//
// lifecycle_state, attempts and completed_at are the fingerprint of what the
// reviewer actually saw. A review is not a fact about an episode id, it is a
// fact about an ENDING, and endings move: a blocked episode revives, spends
// one more attempt, and finishes somewhere else. Keyed on the id alone the
// ledger would answer "already judged" for a trace nobody has read. The three
// columns together are what re-opens a review, and they are stored rather than
// recomputed because the comparison is against what was true when the reviewer
// read it, not against what is true now.
//
// completed_at defaults to the empty string where work_episodes.completed_at
// is nullable, because the empty string compares as a value and NULL does not:
// a fingerprint column that is NULL on both sides makes its equality test
// answer NULL, and an episode whose review matched in every other column would
// never leave the queue.
//
// No foreign key, for V81 and V82's reason: work_episodes expires on the
// episode-history horizon and this ledger is meant to outlive the traces it
// judged, so a cascade would let one table's clock decide the other's
// deletions — here by handing a pass back an ending it has already read the
// day retention pruned the episode.
//
// No index either: episode_id is the primary key, and it is the only lookup
// the pending query makes into this table.
const V83 = `
CREATE TABLE episode_reviews (
  episode_id TEXT PRIMARY KEY,
  reviewed_at TEXT NOT NULL,
  reviewer TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  lifecycle_state TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  completed_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
`
