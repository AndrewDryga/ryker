package migrationddl

// V75 adds the projection that lets one episode inform another.
//
// Responder held hundreds of fully traced episodes — evidence, verdicts,
// verified fixes — and every new incident still started from zero, because the
// facts were spread across six tables keyed three different ways: evidence by
// source_input, usage by attempt_id, incidents by their own id. Nothing could
// ask "has this happened before" without a join nobody would write at triage
// time. One flat row per finished episode is what makes the question cheap.
//
// symptom_fingerprint is a normalized token set rather than prose because
// recall is lexical and deterministic, and fingerprint_source names where
// those tokens came from on every row. Retention has already pruned most old
// Slack inputs, so a backfilled row often cannot use the real trigger text and
// falls back to alert labels or the truncated objective. Mixing the two
// silently would make the corpus unmeasurable: a match on a 180-byte headline
// is a different claim from a match on what the operator actually wrote.
const V75 = `
CREATE TABLE episode_outcomes (
  episode_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL DEFAULT '',
  channel_id TEXT NOT NULL DEFAULT '',
  repository TEXT NOT NULL DEFAULT '',
  mode TEXT NOT NULL DEFAULT '',
  effort TEXT NOT NULL DEFAULT '',
  terminal_state TEXT NOT NULL,
  terminal_at TEXT NOT NULL,
  objective TEXT NOT NULL DEFAULT '',
  symptom_fingerprint TEXT NOT NULL DEFAULT '',
  fingerprint_source TEXT NOT NULL DEFAULT '',
  alert_group_key TEXT NOT NULL DEFAULT '',
  services_json TEXT NOT NULL DEFAULT '[]',
  root_cause TEXT NOT NULL DEFAULT '',
  remediation TEXT NOT NULL DEFAULT '',
  verification TEXT NOT NULL DEFAULT '',
  verified INTEGER NOT NULL DEFAULT 0 CHECK (verified IN (0, 1)),
  time_to_decision_seconds INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

CREATE INDEX episode_outcomes_recall_idx
  ON episode_outcomes(workspace_id, terminal_at DESC);
`
