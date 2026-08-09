package store

// schemaV50 lets one standing assignment follow a Terraform run through its
// complete lifecycle. Earlier schemas split plan review from deployment
// verification and constrained both columns to those original pairs. That
// made the natural request "review plans, report failures, and verify applies"
// impossible to persist even after the host compiled it into a typed rule.
//
// SQLite cannot alter a CHECK constraint in place, so this rebuild spells out
// the table and copies every row. standing_rule_runs references this table with
// ON DELETE CASCADE; tableRebuildMigrations keeps foreign keys disabled around
// the transaction so dropping the old table does not erase that history, then
// verifies the references before accepting the migration.
const schemaV50 = `
CREATE TABLE standing_rules_rebuilt (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  repository TEXT NOT NULL,
  trigger_name TEXT NOT NULL,
  action_name TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  source_ref TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  trigger_count INTEGER NOT NULL DEFAULT 0,
  last_triggered_at TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(channel_id, trigger_name, action_name, repository, source_kind),
  CHECK (trigger_name IN (
    'terraform_plan', 'terraform_lifecycle', 'deployment', 'operational_alert'
  )),
  CHECK (action_name IN (
    'review_terraform_plan', 'monitor_terraform_lifecycle',
    'verify_deployment', 'triage_alert'
  )),
  CHECK (source_kind IN ('any', 'human', 'app'))
);

INSERT INTO standing_rules_rebuilt (
  id, channel_id, repository, trigger_name, action_name, source_kind,
  enabled, source_ref, actor_id, trigger_count, last_triggered_at,
  expires_at, created_at, updated_at
) SELECT
  id, channel_id, repository, trigger_name, action_name, source_kind,
  enabled, source_ref, actor_id, trigger_count, last_triggered_at,
  expires_at, created_at, updated_at
FROM standing_rules;

DROP TABLE standing_rules;
ALTER TABLE standing_rules_rebuilt RENAME TO standing_rules;

CREATE INDEX standing_rules_channel_idx
  ON standing_rules(channel_id, enabled, expires_at);
CREATE INDEX standing_rules_expiry_idx ON standing_rules(expires_at);
`
