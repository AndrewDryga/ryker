// Package incidentsessionstore owns authority-safe incident session rotation.
package incidentsessionstore

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/fanout"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

type Repository struct{ db *sql.DB }

func New(db *sql.DB) *Repository { return &Repository{db: db} }

// CountRetryingBranches reports preparation custody without replacing the
// incident's own workflow: its lead or sibling branches may already be live.
func (r *Repository) CountRetryingBranches(ctx context.Context, incidentID string) (int, error) {
	if incidentID == "" {
		return 0, nil
	}
	var count int
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM work_episodes AS episode
		JOIN agent_runs AS run ON run.id = episode.agent_run_id
		WHERE run.incident_id = ?
		  AND instr(run.conversation_key, ?) > 0
		  AND episode.lifecycle_state = 'retrying'`,
		incidentID, fanout.BranchMarker,
	).Scan(&count)
	return count, err
}

func (r *Repository) AdvanceAgentRunGeneration(
	ctx context.Context,
	runID string,
	generation int,
	now time.Time,
) error {
	if runID == "" || generation < 1 {
		return errors.New("agent run session generation is incomplete")
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET session_id = '', session_generation = ?, updated_at = ?
		WHERE id = ? AND state = 'preparing' AND session_generation < ?`,
		generation, now.UTC().Format(core.TimestampFormat), runID, generation,
	)
	return sqlutil.ExpectOne(result, err, "advance agent run session generation")
}

// RotateReadOnly atomically releases a workspace whose authority no longer
// matches its incident lane, advances its create key, and gives cleanup
// ownership of the old fork. The legacy name is retained for the store port.
func (r *Repository) RotateReadOnly(
	ctx context.Context,
	incidentID, sessionID string,
	expectedGeneration int,
	reason string,
	eligibleAt time.Time,
) (bool, error) {
	if incidentID == "" || sessionID == "" || expectedGeneration < 1 || reason == "" {
		return false, errors.New("incident session rotation identity is incomplete")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	now := eligibleAt.UTC().Format(core.TimestampFormat)
	result, err := tx.ExecContext(ctx, `
		UPDATE incidents
		SET coop_session_id = '', coop_fork_name = '', coop_revision = 0,
		  coop_event_sequence = 0, active_turn_id = '',
		  coop_session_generation = coop_session_generation + 1,
		  workflow = 'provisioning_session', last_error = '',
		  updated_at = ?, card_version = card_version + 1
		WHERE id = ? AND status != 'closed'
		  AND active_turn_id = '' AND coop_session_generation = ?
		  AND (coop_session_id = ? OR coop_session_id = '')`,
		now, incidentID, expectedGeneration, sessionID,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if rows != 1 {
		return false, core.ErrConflict
	}
	when := eligibleAt.UTC().Format(core.TimestampFormat)
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		) VALUES (?, ?, ?, 0, 'pending', ?, ?, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
		  incident_id = CASE WHEN coop_cleanup.incident_id = ''
		    THEN excluded.incident_id ELSE coop_cleanup.incident_id END,
		  eligible_at = MIN(coop_cleanup.eligible_at, excluded.eligible_at),
		  updated_at = excluded.updated_at
		WHERE coop_cleanup.state != 'done'`,
		sessionID, incidentID, reason, when, when, now, now,
	); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}
