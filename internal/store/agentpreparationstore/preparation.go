// Package agentpreparationstore owns durable pre-submission agent-run leases.
package agentpreparationstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const timestampFormat = core.TimestampFormat

type Deferral struct {
	EpisodeState core.WorkEpisodeState
	Phase        string
	Status       string
	NextAction   string
	ProgressDue  time.Time
	EventSuffix  string
}

type ProjectDeferral func(context.Context, *sql.Tx, string, Deferral) error

func Defer(
	ctx context.Context,
	db *sql.DB,
	now func() time.Time,
	id string,
	contextJSON []byte,
	detail string,
	next time.Time,
	preparingWorkspace bool,
	project ProjectDeferral,
) error {
	if contextJSON != nil &&
		(len(contextJSON) == 0 || len(contextJSON) > 256<<10 || !json.Valid(contextJSON)) {
		return errors.New("triage run context must be valid JSON between 1 byte and 256 KiB")
	}
	projection := Deferral{
		EpisodeState: core.EpisodeAcknowledged,
		Phase:        "queued",
		Status:       detail,
		NextAction:   "Resume when the dependency is ready",
		EventSuffix:  "deferred",
	}
	if preparingWorkspace {
		projection.EpisodeState = core.EpisodeRetrying
		projection.Phase = "preparing_workspace"
		projection.NextAction = "Responder will retry this investigation branch automatically"
		projection.ProgressDue = next
		projection.EventSuffix = "deferred:preparing_workspace"
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var storedContext any
	if contextJSON != nil {
		storedContext = contextJSON
	}
	stamp := now().UTC().Format(timestampFormat)
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending',
		    context_json = CASE WHEN ? IS NULL THEN context_json ELSE ? END,
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		storedContext, storedContext, sqlutil.BoundedError(detail),
		next.UTC().Format(timestampFormat), stamp, id,
	)
	if err := sqlutil.ExpectOne(result, err, "defer agent run"); err != nil {
		return err
	}
	if err := project(ctx, tx, id, projection); err != nil {
		return err
	}
	return tx.Commit()
}

func Recover(
	ctx context.Context,
	db *sql.DB,
	now func() time.Time,
	staleBefore time.Time,
) (int64, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `
		SELECT run.id
		FROM agent_runs AS run
		WHERE run.state = 'preparing'
		  AND run.coop_turn_id = ''
		  AND julianday(run.updated_at) <= julianday(?)
		ORDER BY run.updated_at, run.id`,
		staleBefore.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	var candidates []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		candidates = append(candidates, id)
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	stamp := now().UTC()
	detail := "Workspace preparation was interrupted; retrying"
	var recovered int64
	for _, id := range candidates {
		result, err := tx.ExecContext(ctx, `
			UPDATE agent_runs
			SET state = 'pending', next_attempt_at = ?,
			    last_error = CASE WHEN last_error = '' THEN ? ELSE last_error END,
			    updated_at = ?
			WHERE id = ? AND state = 'preparing' AND coop_turn_id = ''
			  AND julianday(updated_at) <= julianday(?)`,
			stamp.Format(timestampFormat), detail, stamp.Format(timestampFormat), id,
			staleBefore.UTC().Format(timestampFormat),
		)
		if err != nil {
			return 0, err
		}
		changed, err := result.RowsAffected()
		if err != nil {
			return 0, err
		}
		if changed == 0 {
			continue
		}
		result, err = tx.ExecContext(ctx, `
			UPDATE episode_attempts
			SET state = 'pending', failure_class = ?, lease_owner = '',
			    lease_expires_at = NULL, completed_at = NULL, updated_at = ?
			WHERE agent_run_id = ?`,
			sqlutil.BoundedError(detail), stamp.Format(timestampFormat), id,
		)
		if err := sqlutil.ExpectOne(result, err, "recover agent-run episode attempt"); err != nil {
			return 0, err
		}
		recovered += changed
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return recovered, nil
}
