package store

const schemaV67 = `
CREATE TABLE replay_cancellations (
  run_key TEXT PRIMARY KEY,
  replay_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  turn_id TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL CHECK (state IN ('pending', 'completed')),
  failure_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX replay_cancellations_due_idx
  ON replay_cancellations(state, next_attempt_at, created_at);
`
