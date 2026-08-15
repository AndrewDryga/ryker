package migrationddl

// V76 adds the ledger that answers "what changed?".
//
// It is the first question of every real incident and Responder could not
// answer it deterministically. The facts were already passing through the
// process and being thrown away: a deploy notification arriving on a webhook
// became a signal or nothing at all, the publication follower watched
// Responder's own pull requests merge without ledgering the merge, and the
// approval watcher read mutating Emisar runs to terminal state and kept only
// the approval row. Three sources already in hand, and nowhere to ask what
// happened in the last six hours.
//
// The primary key is derived from source and source_identity rather than
// generated — see changeledger.EventID. Every one of those three adapters is
// at-least-once by construction: a webhook redelivers, a poll cursor rewinds on
// restart recovery, and the approval watcher reads a terminal run again after a
// lost response. A generated id would make each of them responsible for
// remembering that; a derived one makes the second write address the first row.
// The UNIQUE below is therefore redundant against the key today and is stated
// anyway, because it is the invariant, and an invariant that lives only in a
// hashing function is one a later refactor can drop without noticing.
//
// services_json and repositories_json rather than a scope table: the recall
// window is six hours and the candidate set is dozens of rows, so scope
// matching is a pass in changeledger.Select over rows SQLite already returned.
// A join would have to cap before it could match, which is the one thing this
// query must not do — the ten newest changes in the estate are usually not the
// ten that are about this incident.
const V76 = `
CREATE TABLE change_events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  source_identity TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('deploy', 'merge', 'infra_apply', 'flag', 'config')),
  occurred_at TEXT NOT NULL,
  services_json TEXT NOT NULL DEFAULT '[]',
  repositories_json TEXT NOT NULL DEFAULT '[]',
  actor TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  source_ref TEXT NOT NULL DEFAULT '',
  revision TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  UNIQUE(source, source_identity)
);

CREATE INDEX change_events_window_idx ON change_events(occurred_at DESC);
`
