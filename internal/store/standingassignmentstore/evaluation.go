package standingassignmentstore

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// maxEvaluationReason bounds the recorded reason. The gate's reasons are host
// strings from a fixed set, so this only ever trims a caller that assembled one
// from something wider.
const maxEvaluationReason = 500

// maxEvaluationSignal bounds the recorded signal text. Enough to recognize
// which alert this was, short of storing a channel's worth of prose per row.
const maxEvaluationSignal = 300

// RecordEvaluation writes one gate decision about one signal.
//
// Written for the declines too, and that is the whole point: a shadow period
// whose ledger held only the signals that passed could not answer the question
// it exists to answer. It also cannot be reconstructed afterwards — the gate
// reads a completion assessment and an evidence list that belong to a turn
// which has already finished by the time anyone asks.
func (r *Repository) RecordEvaluation(
	ctx context.Context,
	evaluation core.StandingAssignmentEvaluation,
) (core.StandingAssignmentEvaluation, error) {
	if strings.TrimSpace(evaluation.AssignmentID) == "" {
		return evaluation, errors.New("an evaluation names the assignment that made it")
	}
	if !slices.Contains(core.StandingAssignmentEvaluationVerdicts, evaluation.Verdict) {
		return evaluation, errors.New(
			"verdict must be one of: " +
				strings.Join(core.StandingAssignmentEvaluationVerdicts, ", "),
		)
	}
	if strings.TrimSpace(evaluation.ID) == "" {
		id, err := core.NewID("assigneval")
		if err != nil {
			return evaluation, err
		}
		evaluation.ID = id
	}
	if evaluation.CreatedAt.IsZero() {
		evaluation.CreatedAt = r.now()
	}
	evaluation.Signal = core.BoundedText(evaluation.Signal, maxEvaluationSignal)
	evaluation.Reason = core.BoundedText(evaluation.Reason, maxEvaluationReason)
	shadow := 0
	if evaluation.Shadow {
		shadow = 1
	}
	if _, err := r.db.ExecContext(ctx, `
		INSERT INTO standing_assignment_evaluations (
		  id, assignment_id, input_id, episode_id, signal, shadow, verdict, reason, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		evaluation.ID, evaluation.AssignmentID, evaluation.InputID, evaluation.EpisodeID,
		evaluation.Signal, shadow, evaluation.Verdict, evaluation.Reason,
		sqlutil.TimeText(evaluation.CreatedAt),
	); err != nil {
		return evaluation, err
	}
	return evaluation, nil
}

// Tally is what the shadow period amounts to for one assignment.
//
// One pass over the rows rather than a stored counter. The standing_rules
// tallies are columns because standing_rule_runs expires on the episode-history
// horizon and the count had to outlive its evidence; these rows are deleted
// only with the assignment they belong to, so a counter beside them would be a
// second opinion about facts that are still on disk.
func (r *Repository) Tally(
	ctx context.Context,
	assignmentID string,
) (core.StandingAssignmentTally, error) {
	tally := core.StandingAssignmentTally{AssignmentID: assignmentID}
	var lastEvaluated, lastEligible sql.NullString
	err := r.db.QueryRowContext(ctx, `
		SELECT
		  COUNT(*),
		  COALESCE(SUM(verdict = 'eligible'), 0),
		  COALESCE(SUM(verdict = 'declined'), 0),
		  MAX(created_at),
		  MAX(CASE WHEN verdict = 'eligible' THEN created_at END)
		FROM standing_assignment_evaluations WHERE assignment_id = ?`,
		assignmentID,
	).Scan(
		&tally.Evaluated, &tally.Eligible, &tally.Declined, &lastEvaluated, &lastEligible,
	)
	if err != nil {
		return tally, err
	}
	tally.LastEvaluated = sqlutil.ScanTime(lastEvaluated)
	tally.LastEligible = sqlutil.ScanTime(lastEligible)
	if tally.Declined == 0 {
		return tally, nil
	}
	// The most-repeated refusal, because the count alone cannot tell a
	// misconfigured scope from traffic that simply did not deserve a pull
	// request, and those two call for opposite responses. Ranking recorded
	// refusals by repeats is how the same question got answered for model
	// corrections; the worst one there was telling the model to pick from an
	// empty list of verdicts, which nobody would have found by counting.
	err = r.db.QueryRowContext(ctx, `
		SELECT reason, COUNT(*) AS repeats
		FROM standing_assignment_evaluations
		WHERE assignment_id = ? AND verdict = 'declined'
		GROUP BY reason ORDER BY repeats DESC, reason LIMIT 1`,
		assignmentID,
	).Scan(&tally.TopDecline, &tally.TopDeclineCount)
	if errors.Is(err, sql.ErrNoRows) {
		return tally, nil
	}
	return tally, err
}

// ListEvaluations returns the newest decisions an assignment made.
func (r *Repository) ListEvaluations(
	ctx context.Context,
	assignmentID string,
	limit int,
) ([]core.StandingAssignmentEvaluation, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, assignment_id, input_id, episode_id, signal, shadow, verdict, reason, created_at
		FROM standing_assignment_evaluations
		WHERE assignment_id = ?
		ORDER BY created_at DESC LIMIT ?`, assignmentID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.StandingAssignmentEvaluation, 0)
	for rows.Next() {
		var evaluation core.StandingAssignmentEvaluation
		var shadow int
		var created string
		if err := rows.Scan(
			&evaluation.ID, &evaluation.AssignmentID, &evaluation.InputID,
			&evaluation.EpisodeID, &evaluation.Signal, &shadow, &evaluation.Verdict,
			&evaluation.Reason, &created,
		); err != nil {
			return nil, err
		}
		evaluation.Shadow = shadow == 1
		evaluation.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, evaluation)
	}
	return result, rows.Err()
}
