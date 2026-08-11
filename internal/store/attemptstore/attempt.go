// Package attemptstore owns persistence for attempts within a work episode.
package attemptstore

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Ensure links an agent run to its durable episode attempt, creating the
// attempt when the transport run is first attached to the episode.
func Ensure(ctx context.Context, tx *sql.Tx, episodeID string, run core.AgentRun, now string) error {
	var existingID string
	err := tx.QueryRowContext(ctx,
		`SELECT id FROM episode_attempts WHERE agent_run_id = ?`, run.ID,
	).Scan(&existingID)
	if err == nil {
		_, err = tx.ExecContext(ctx, `
			UPDATE agent_runs
			SET episode_id = ?, attempt_id = ?, attempt_number = (
			  SELECT attempt_number FROM episode_attempts WHERE id = ?
			), updated_at = ?
			WHERE id = ?`, episodeID, existingID, existingID, now, run.ID)
		return err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	var number int
	if err := tx.QueryRowContext(ctx, `
		SELECT COALESCE(MAX(attempt_number), 0) + 1
		FROM episode_attempts WHERE episode_id = ?`, episodeID).Scan(&number); err != nil {
		return err
	}
	attemptID := strings.TrimSpace(run.AttemptID)
	if attemptID == "" {
		attemptID = "attempt_" + run.ID
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO episode_attempts (
		  id, episode_id, agent_run_id, attempt_number, state,
		  failure_generation, started_at, completed_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		attemptID, episodeID, run.ID, number, fromAgentState(run.State),
		run.Failures, nullableTime(run.StartedAt), nullableTime(run.CompletedAt),
		run.CreatedAt.UTC().Format(time.RFC3339Nano), now,
	); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET episode_id = ?, attempt_id = ?, attempt_number = ?, updated_at = ?
		WHERE id = ?`, episodeID, attemptID, number, now, run.ID); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE work_episodes
		SET latest_attempt_id = ?, updated_at = ? WHERE id = ?`, attemptID, now, episodeID)
	return err
}

func fromAgentState(state core.AgentRunState) core.EpisodeAttemptState {
	switch state {
	case core.AgentRunPending:
		return core.AttemptPending
	case core.AgentRunPreparing:
		return core.AttemptLeased
	case core.AgentRunRunning, core.AgentRunApplying, core.AgentRunFinalizing:
		return core.AttemptRunning
	case core.AgentRunCompleted:
		return core.AttemptSucceeded
	case core.AgentRunCancelled, core.AgentRunSuperseded:
		return core.AttemptCancelled
	default:
		return core.AttemptFailed
	}
}

func nullableTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value.UTC().Format(time.RFC3339Nano)
}
