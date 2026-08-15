package migrationddl

// V78 makes a standing assignment shadow its own authority before it uses it.
//
// The consumption half of standing assignments has been complete and carefully
// gated since migration 43 — a signal must match the granted scope, have
// recurred three times in fourteen days, have reached a decision-ready
// completion with no material gaps, and carry evidence from something that
// observed the system. What has never existed is a way to create one, so
// ListLiveStandingAssignments has always returned empty and the gate has never
// run against real traffic. Both deployments hold zero rows.
//
// Adding the creation path alone would grant Responder authority to open pull
// requests unattended, gated on completion.status — the contract that was the
// largest single source of defects on 2026-08-09, and whose corpus only reached
// 9/9 that evening. The nearest comparable feature, the quality-watch fixer,
// writes code unattended and landed zero net fixes in seven days across 59
// attempts before it was switched off. So the creation path lands with the
// authority withheld: the assignment is evaluated by the real gate and the
// verdict is recorded, and only the acting is skipped.
//
// shadow defaults to 1 rather than 0 because the safe state must be the one a
// forgotten argument produces. A Go bool zero-values to false, so a caller that
// simply neglects the field would otherwise be minting live authority; with the
// default here and a refusal in the repository, silence means shadow.
//
// standing_assignment_evaluations is a separate table from
// standing_assignment_actions on purpose. That table's UNIQUE(assignment_id,
// correlation_key) is the deduplication that makes "one pull request per issue"
// structural, and counting its rows is the daily budget. Recording shadow
// verdicts there would spend a budget nothing spent and suppress the second
// evaluation of a recurring signal — which is precisely the row worth having,
// because a decline that repeats is the evidence this whole exercise is for.
//
// The tally is a GROUP BY over these rows rather than counters on the
// assignment, which is where the standing_rules tallies had to go: those
// counters exist because standing_rule_runs expires on the episode-history
// horizon and the count had to outlive its evidence. These rows do not expire
// on a horizon — they are Cascade, deleted with the assignment they belong to —
// and an assignment stops producing them at its own expiry, so the evidence
// outlives the question and a second opinion about the same verdict would only
// be something to disagree with.
const V78 = `
ALTER TABLE standing_assignments ADD COLUMN shadow INTEGER NOT NULL DEFAULT 1;

CREATE TABLE standing_assignment_evaluations (
  id TEXT PRIMARY KEY,
  assignment_id TEXT NOT NULL,
  input_id TEXT NOT NULL,
  episode_id TEXT NOT NULL DEFAULT '',
  signal TEXT NOT NULL DEFAULT '',
  shadow INTEGER NOT NULL DEFAULT 1 CHECK (shadow IN (0, 1)),
  verdict TEXT NOT NULL CHECK (verdict IN ('eligible', 'declined')),
  reason TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  FOREIGN KEY(assignment_id) REFERENCES standing_assignments(id) ON DELETE CASCADE
);

CREATE INDEX standing_assignment_evaluations_assignment_idx
  ON standing_assignment_evaluations(assignment_id, created_at DESC);

CREATE INDEX standing_assignment_evaluations_episode_idx
  ON standing_assignment_evaluations(episode_id);
`
