package store

import (
	"github.com/AndrewDryga/responder/internal/store/migrationddl"
	"github.com/AndrewDryga/responder/internal/store/schemaassets"
)

const currentSchemaVersion = 78

const connectionPragmas = `
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
`

const persistentPragmas = `
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
`

// baselineSchema is the complete current schema. Responder collapsed its first
// forty incremental migrations into this single statement once every deployed
// database had reached version 39: replaying four decades of table rebuilds on
// every fresh install cost startup time and made the live shape of a table
// impossible to read without mentally replaying the chain.
//
// Adding a change: append a schemaVN constant and its migrations entry, and
// leave this baseline alone. Regenerate it only when every deployed database
// has passed the new minimumUpgradableVersion.
const baselineSchema = schemaassets.Baseline

const baselineSchemaVersion = 40

// minimumUpgradableVersion is the oldest database this binary can migrate.
// Older databases predate the baseline and no released binary ever produced
// them, so failing loudly beats silently applying a partial schema.
//
// Defined against releases, as of v0.1.0: the oldest supported release is
// v0.1.0, whose fresh installs are created at the version-40 baseline and
// whose upgrades were proven from 39 — the newest schema any pre-release
// deployment ever ran. Nothing older was ever published, so nothing older is
// a migration target. Raise this only when a release drops support for the
// databases an older release produced, and say which release in this comment:
// the error an operator sees names a boundary, and the boundary must have
// been published somewhere they could have read.
const minimumUpgradableVersion = 39

const schemaV40 = `
-- The episode effect ledger was built ahead of its callers and no live path
-- ever planned, leased, or completed an effect. Remove it rather than carry an
-- unused lease surface beside the work_items scheduler that does own delivery.
DROP INDEX IF EXISTS episode_effects_due_idx;
DROP INDEX IF EXISTS episode_effects_episode_idx;
DROP TABLE IF EXISTS episode_effects;
`

const schemaV42 = `
-- Commitments were keyed by the agent run that made them, and the projection
-- reached the episode through work_episodes.agent_run_id — which names the
-- ORIGINATING run. A commitment made by a replacement attempt therefore joined
-- to nothing and vanished from every "what are you working on" view, while
-- still sitting in the table. On the database this migration was written
-- against, 16 of 335 were invisible.
--
-- A commitment is a promise to a person about a unit of work, not about the
-- transport attempt that happened to carry it, so the episode is its real key.
-- Re-keying makes the disappearance structurally impossible rather than fixed.
CREATE TABLE commitments_by_episode (
  episode_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

-- Earliest title wins: it is the promise as originally made, and a later
-- attempt restating it should not overwrite the words the operator saw first.
INSERT OR IGNORE INTO commitments_by_episode (episode_id, title)
SELECT r.episode_id, c.title
FROM commitments AS c
JOIN agent_runs AS r ON r.id = c.agent_run_id
WHERE r.episode_id != ''
ORDER BY r.created_at ASC;

DROP TABLE commitments;
ALTER TABLE commitments_by_episode RENAME TO commitments;
`

const schemaV43 = `
-- A standing assignment is how an operator grants scoped authority once instead
-- of confirming every action. It does not remove the confirmation Responder
-- relies on; it moves it earlier in time, which is the only way autonomous work
-- can keep the invariant that nothing acts without someone having said yes.
--
-- Every column here is a bound. change_class is an allowlist rather than free
-- text because free text means "Responder may change anything"; path_globs
-- narrows the repository because a repository is far too large a blast radius
-- to grant in one click; daily_budget and expires_at mean a forgotten
-- assignment decays instead of running forever.
CREATE TABLE standing_assignments (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  signal_pattern TEXT NOT NULL,
  repository TEXT NOT NULL,
  path_globs_json TEXT NOT NULL DEFAULT '[]',
  change_class TEXT NOT NULL CHECK (change_class IN (
    'dependency_upgrade', 'alert_threshold', 'flaky_test_quarantine',
    'observability', 'documentation'
  )),
  daily_budget INTEGER NOT NULL CHECK (daily_budget > 0 AND daily_budget <= 20),
  actor_id TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  confirmed_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX standing_assignments_channel_idx
  ON standing_assignments(channel_id, enabled, expires_at);

-- One row per action an assignment took. This serves two jobs that would
-- otherwise need separate bookkeeping: the unique constraint makes "one pull
-- request per issue" structural rather than a check someone has to remember,
-- and counting today's rows is the budget.
CREATE TABLE standing_assignment_actions (
  id TEXT PRIMARY KEY,
  assignment_id TEXT NOT NULL,
  correlation_key TEXT NOT NULL,
  episode_id TEXT NOT NULL DEFAULT '',
  outcome TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(assignment_id, correlation_key),
  FOREIGN KEY(assignment_id) REFERENCES standing_assignments(id) ON DELETE CASCADE
);

CREATE INDEX standing_assignment_actions_budget_idx
  ON standing_assignment_actions(assignment_id, created_at);
`

const schemaV44 = `
-- A correction is a regression fixture that writes itself: the host already
-- decided the model was wrong and said exactly why, which is a label no one had
-- to produce by hand. This table is the queue between that moment and the
-- corpus, because section 23.3 requires a human to review anything entering a
-- release gate — and because review is also what keeps the corpus from filling
-- with the same three mistakes.
--
-- expires_at is not housekeeping. A candidate nobody reviewed for a fortnight is
-- evidence about a prompt version that may no longer exist, and promoting it
-- later encodes a bug that was already fixed. Stale candidates must lapse rather
-- than wait forever.
CREATE TABLE fixture_candidates (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  capability TEXT NOT NULL DEFAULT '',
  correction_class TEXT NOT NULL,
  correction TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
  reviewed_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(episode_id, correction_class)
);

CREATE INDEX fixture_candidates_review_idx
  ON fixture_candidates(status, created_at);
`

// migrations maps a target schema version to the statement that reaches it
// from the version before. Versions at or below the baseline are absent
// because baselineSchema already produces them.
const schemaV41 = `
-- Product feedback lived in its own SQLite file beside the main database, which
-- put it outside the schema baseline, outside the verified pre-migration
-- backup, and outside every cross-table transaction. Feedback is durable
-- product state and belongs under the same guarantees as everything else.
CREATE TABLE feedback_items (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  message_ts TEXT NOT NULL DEFAULT '',
  target_message_ts TEXT NOT NULL DEFAULT '',
  user_id TEXT NOT NULL,
  source TEXT NOT NULL,
  category TEXT NOT NULL,
  sentiment TEXT NOT NULL,
  summary TEXT NOT NULL,
  details TEXT NOT NULL DEFAULT '',
  context_json BLOB NOT NULL,
  episode_id TEXT NOT NULL DEFAULT '',
  agent_run_id TEXT NOT NULL DEFAULT '',
  source_ref TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  resolved_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX feedback_items_workspace_status_updated
  ON feedback_items(workspace_id, status, updated_at DESC);
`

const schemaV45 = `
-- Schedule prompts can be much larger than Slack's interactive action value.
-- Keep the normalized proposal in SQLite and send Slack only this row's opaque
-- ID. Acceptance is an atomic pending -> accepted transition, so button retries
-- and conversational confirmations cannot create duplicate schedules.
CREATE TABLE schedule_proposals (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  actor_id TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  task_json BLOB NOT NULL,
  replace_task_id TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'expired')),
  accepted_task_id TEXT NOT NULL DEFAULT '',
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(team_id, channel_id, source_ref)
);

CREATE INDEX schedule_proposals_conversation_idx
  ON schedule_proposals(team_id, channel_id, thread_ts, actor_id, status, created_at DESC);
`

var migrations = map[int]string{
	40: schemaV40,
	41: schemaV41,
	42: schemaV42,
	43: schemaV43,
	44: schemaV44,
	45: schemaV45,
	46: schemaV46,
	47: schemaV47,
	48: schemaV48,
	49: schemaV49,
	50: schemaV50,
	51: schemaV51,
	52: schemaV52,
	53: schemaV53,
	54: schemaV54,
	55: schemaV55,
	56: migrationddl.V56,
	57: `ALTER TABLE context_manifests ADD COLUMN submitted_prompt TEXT NOT NULL DEFAULT '';`,
	58: migrationddl.V58,
	59: `ALTER TABLE incidents ADD COLUMN latest_update TEXT NOT NULL DEFAULT '';`,
	60: `
		ALTER TABLE publications ADD COLUMN attempt_input_id TEXT NOT NULL DEFAULT '';
		ALTER TABLE publications ADD COLUMN failure_code TEXT NOT NULL DEFAULT '';
		ALTER TABLE publications ADD COLUMN generation INTEGER NOT NULL DEFAULT 0;
		UPDATE publications SET generation = 1;
		UPDATE incidents SET card_version = card_version + 1
		  WHERE id IN (SELECT incident_id FROM publications);
	`,
	61: migrationddl.V61,
	62: `ALTER TABLE incidents ADD COLUMN task_pull_request_json TEXT NOT NULL DEFAULT '';`,
	63: `
		UPDATE publications SET state = 'published', failure_code = '', last_error = ''
		  WHERE state != 'published' AND pr_number > 0 AND published_at IS NOT NULL
		    AND incident_id IN (
		      SELECT incident_id FROM publication_followups
		      WHERE pr_state IN ('merged', 'closed')
		    );
		UPDATE incidents SET card_version = card_version + 1
		  WHERE id IN (SELECT incident_id FROM publication_followups);
	`,
	64: `
		ALTER TABLE slack_deliveries ADD COLUMN response_root INTEGER NOT NULL DEFAULT 0;
		ALTER TABLE slack_deliveries ADD COLUMN agent_run_id TEXT NOT NULL DEFAULT '';
		ALTER TABLE slack_deliveries ADD COLUMN agent_run_key TEXT NOT NULL DEFAULT '';
		ALTER TABLE slack_deliveries ADD COLUMN source_input_id TEXT NOT NULL DEFAULT '';
		UPDATE slack_deliveries AS delivery
		SET source_input_id = COALESCE((
		  SELECT run.source_id FROM agent_runs AS run
		  WHERE run.source_kind = 'watch' AND (
		    delivery.id = 'watch_reply_' || run.source_id OR
		    delivery.id GLOB 'watch_reply_' || run.source_id || '_part_*' OR
		    delivery.id GLOB 'watch_reply_' || run.source_id || '_visual_*' OR
		    delivery.id = 'watch_failure_' || run.source_id
		  ) ORDER BY run.created_at DESC, run.id DESC LIMIT 1
		), '')
		WHERE source_input_id = '';
		UPDATE slack_deliveries AS delivery
		SET agent_run_id = COALESCE((
		  SELECT run.id FROM agent_runs AS run
		  WHERE (delivery.source_input_id != '' AND run.source_kind = 'watch'
		         AND run.source_id = delivery.source_input_id) OR
		        delivery.id = 'out_run_' || run.id OR
		        delivery.id GLOB 'out_run_' || run.id || '_part_*' OR
		        delivery.id GLOB 'out_run_' || run.id || '_visual_*' OR
		        delivery.id = 'out_run_finalization_failure_' || run.id
		  ORDER BY run.created_at DESC, run.id DESC LIMIT 1
		), '')
		WHERE agent_run_id = '';
		UPDATE slack_deliveries AS delivery
		SET agent_run_key = COALESCE((
		  SELECT run.idempotency_key FROM agent_runs AS run
		  WHERE run.id = delivery.agent_run_id
		    AND run.idempotency_key NOT LIKE '%:recovery_%'
		), '')
		WHERE agent_run_key = '';
		UPDATE slack_deliveries
		SET response_root = 1
		WHERE operation IN ('post', 'file') AND (
		  id GLOB 'watch_failure_*' OR id GLOB 'out_run_finalization_failure_*' OR
		  id GLOB '*_part_999' OR id GLOB '*_visual_01' OR
		  ((id GLOB 'watch_reply_*' OR id GLOB 'out_run_*')
		    AND id NOT GLOB '*_part_???' AND id NOT GLOB '*_visual_??')
		);
	`,
	65: `
		ALTER TABLE incidents ADD COLUMN latest_update_run_id TEXT NOT NULL DEFAULT '';
		ALTER TABLE incidents ADD COLUMN latest_update_run_key TEXT NOT NULL DEFAULT '';
	`,
	66: `
		ALTER TABLE evaluation_decisions ADD COLUMN agent_run_id TEXT NOT NULL DEFAULT '';
		ALTER TABLE evaluation_decisions ADD COLUMN agent_run_key TEXT NOT NULL DEFAULT '';
		UPDATE evaluation_decisions AS decision
		SET agent_run_id = COALESCE((
		  SELECT run.id FROM agent_runs AS run
		  WHERE run.source_id = decision.source_input
		    AND run.idempotency_key NOT LIKE '%:recovery_%'
		  ORDER BY run.updated_at DESC, run.id DESC LIMIT 1
		), '');
		UPDATE evaluation_decisions AS decision
		SET agent_run_key = COALESCE((
		  SELECT run.idempotency_key FROM agent_runs AS run
		  WHERE run.id = decision.agent_run_id
		), '')
		WHERE agent_run_key = '';
	`,
	67: schemaV67,
	68: schemaV68,
	69: `
		ALTER TABLE context_manifests ADD COLUMN usage_cost_usd REAL NOT NULL DEFAULT 0;
		ALTER TABLE context_manifests ADD COLUMN usage_costed_turns INTEGER NOT NULL DEFAULT 0;
	`,
	// Input artifact bodies, keyed by the digest the manifest reference
	// records. Until now the dashboard could prove a pull-request snapshot
	// was handed to the model and could not show a byte of it.
	70: `
		CREATE TABLE context_artifacts (
		  digest TEXT PRIMARY KEY,
		  name TEXT NOT NULL,
		  media_type TEXT NOT NULL,
		  body BLOB NOT NULL,
		  created_at TEXT NOT NULL
		);
	`,
	// What the model actually did inside a turn, as Coop narrated it. Until
	// now a turn's interior was a stopwatch: the dashboard could say a model
	// worked for forty seconds and could not name one thing it did in them.
	//
	// Keyed by the Coop event sequence so an at-least-once poll — and the
	// cursor repair that rewinds to zero — replays into the same rows instead
	// of duplicating the story.
	71: `
		CREATE TABLE agent_activity (
		  id TEXT PRIMARY KEY,
		  episode_id TEXT NOT NULL DEFAULT '',
		  agent_run_id TEXT NOT NULL,
		  session_id TEXT NOT NULL,
		  turn_id TEXT NOT NULL DEFAULT '',
		  sequence INTEGER NOT NULL,
		  kind TEXT NOT NULL,
		  tool_call_id TEXT NOT NULL DEFAULT '',
		  title TEXT NOT NULL DEFAULT '',
		  tool_kind TEXT NOT NULL DEFAULT '',
		  status TEXT NOT NULL DEFAULT '',
		  -- Nullable on purpose: most moments carry no detail beyond the
		  -- columns beside them, and an empty blob would claim otherwise.
		  detail BLOB,
		  occurred_at TEXT NOT NULL,
		  created_at TEXT NOT NULL,
		  UNIQUE(agent_run_id, sequence),
		  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
		);

		CREATE INDEX agent_activity_episode_idx
		  ON agent_activity(episode_id, sequence);
	`,
	// When the turn last narrated anything, as against last_progress_at, which
	// is when the model last wrote prose about itself. A real 57-minute turn
	// made 119 tool calls and reported "Still working" twice, byte for byte,
	// so the two columns disagree exactly when it matters: the watchdog that
	// reads only the prose accuses a run that never stopped working.
	//
	// Nullable rather than defaulted: an episode that has narrated nothing has
	// no last activity, and a zero timestamp would claim 1970.
	72: `ALTER TABLE work_episodes ADD COLUMN last_activity_at TEXT;`,
	// Which diff message is open, and what it says the change amounts to.
	//
	// View diff posted a new message every press and there was no way to put
	// one away, so a task the operator checked four times left four diffs of
	// the same fork stacked in the thread, the oldest of them wrong. The button
	// can only become a toggle if the card knows whether a diff is already
	// open, and the ts is the only durable handle on it — Slack has no "is this
	// message still there" that is cheaper than trying to delete it.
	//
	// The stat rides along because it answers the question the diff is opened
	// to answer — how big is this change — without opening it, and it is
	// computed from the same patch fetch. Empty is a real value for both: no
	// diff open, and no honest stat available. A stat is never computed from a
	// page, because "3 files" from the first 7 KB of a 60 KB patch is a lie
	// that reads exactly like the truth.
	73: `
		ALTER TABLE incidents ADD COLUMN changes_message_ts TEXT NOT NULL DEFAULT '';
		ALTER TABLE incidents ADD COLUMN changes_stat TEXT NOT NULL DEFAULT '';
	`,
	// How many turns have gone by since anything was written to this channel's
	// memory, which is the one fact rotation needs and could not ask for.
	//
	// turn_count answers "how long has this session run" and updated_at moves on
	// every decision whether or not memory changed, so neither can tell a
	// session that summarized itself on the way out from one that spent forty
	// turns and wrote nothing. Rotation deletes the transcript either way, and
	// only the second case loses anything — so without this column the host
	// either hands every rotation a model turn it usually does not need, or
	// hands none of them the one it does.
	//
	// It starts at zero for every existing row, which claims the memory on disk
	// is current. That is the safe direction: the first turn after this
	// migration sets it truthfully, and the cost of being wrong once is a
	// handoff not taken rather than a model turn spent for nothing.
	74: `ALTER TABLE channel_memories ADD COLUMN turns_since_memory INTEGER NOT NULL DEFAULT 0;`,
	// What a finished episode amounts to, so the next incident can be told
	// about it. The DDL and its reasoning live in migrationddl.V75.
	75: migrationddl.V75,
	// What changed recently, so an incident can be asked the first question
	// anybody asks it. The DDL and its reasoning live in migrationddl.V76.
	76: migrationddl.V76,
	// Which exact Emisar action an operator has confirmed Responder may offer
	// for which exact alert, until when. The DDL and its reasoning live in
	// migrationddl.V77.
	77: migrationddl.V77,
	// A standing assignment records what it would have done, without doing it.
	// The DDL and its reasoning live in migrationddl.V78.
	78: migrationddl.V78,
}
