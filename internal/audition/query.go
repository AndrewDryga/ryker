package audition

import (
	"context"
	"database/sql"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// LanesQuery is the live half of the report, and every clause in it is load
// bearing.
//
// agent_runs joins on attempt_id, NEVER on episode_id. An episode has many
// manifests and many runs, so the episode join multiplies rows against each
// other — on a production database it turned 351 manifests into 953 rows, each
// one counted as an attempt. The join is LEFT and guarded on a non-empty
// attempt_id for the reason the Usage page states: a run pruned out from under
// its attempt must still leave the attempt in the denominator, or the coverage
// figure improves every time retention runs.
//
// The corrections join is a grouped subquery rather than a second LEFT JOIN
// against audit_events, because audit_events has no unique key on object_id: a
// run corrected three times would otherwise triple its own attempt row and
// inflate every token and cost figure on the lane with it.
//
// Both COALESCE and SUM are mandatory together. SQLite sums no rows to NULL and
// the driver refuses to scan that into an int.
const LanesQuery = `
  SELECT COALESCE(a.mode,''), COALESCE(p.source_ref,''),
         COALESCE(m.provider,''), COALESCE(m.model,''), COALESCE(m.reasoning_effort,''),
         COUNT(*),
         COALESCE(SUM(m.usage_input_tokens > 0 OR m.usage_cached_input_tokens > 0
             OR m.usage_output_tokens > 0 OR m.usage_reasoning_tokens > 0),0),
         COALESCE(SUM(m.usage_input_tokens),0), COALESCE(SUM(m.usage_cached_input_tokens),0),
         COALESCE(SUM(m.usage_output_tokens),0), COALESCE(SUM(m.usage_reasoning_tokens),0),
         COALESCE(SUM(m.usage_costed_turns),0), COALESCE(SUM(m.usage_cost_usd),0),
         COALESCE(SUM(c.corrections),0), COALESCE(SUM(c.corrections > 0),0)
  FROM context_manifests AS m
  LEFT JOIN agent_runs AS a ON a.attempt_id = m.attempt_id AND m.attempt_id <> ''
  LEFT JOIN context_manifest_refs AS p
    ON p.manifest_id = m.id AND p.kind = 'execution_profile'
  LEFT JOIN (
    SELECT object_id, COUNT(*) AS corrections FROM audit_events
    WHERE kind = 'result.correction' GROUP BY object_id
  ) AS c ON c.object_id = a.id
  WHERE m.created_at >= ?
  GROUP BY 1, 2, 3, 4, 5`

// Lanes reads the live half. It takes a database rather than a store so the
// command and the control plane run the same query against the same columns —
// two spellings of "which model deserves which lane" that disagreed by a join
// would be worse than one that only existed in one place.
func Lanes(ctx context.Context, db *sql.DB, since time.Time) ([]Lane, error) {
	if db == nil {
		return nil, nil
	}
	rows, err := db.QueryContext(ctx, LanesQuery, since.UTC().Format(core.TimestampFormat))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var lanes []Lane
	for rows.Next() {
		var lane Lane
		if err := rows.Scan(
			&lane.Class, &lane.Profile, &lane.Provider, &lane.Model, &lane.Effort,
			&lane.Attempts, &lane.Measured,
			&lane.Tokens.InputTokens, &lane.Tokens.CachedInputTokens,
			&lane.Tokens.OutputTokens, &lane.Tokens.ReasoningTokens,
			&lane.CostedTurns, &lane.ReportedUSD,
			&lane.Corrections, &lane.CorrectedAttempts,
		); err != nil {
			return nil, err
		}
		lane.Tokens.CostedTurns = lane.CostedTurns
		lanes = append(lanes, trimProfile(lane))
	}
	return lanes, rows.Err()
}

// trimProfile drops the "profile:" prefix the manifest reference carries, which
// is a source-ref namespace rather than part of the name.
func trimProfile(lane Lane) Lane {
	const prefix = "profile:"
	if len(lane.Profile) > len(prefix) && lane.Profile[:len(prefix)] == prefix {
		lane.Profile = lane.Profile[len(prefix):]
	}
	return lane
}
