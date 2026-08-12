// Package replaycancelstore owns durable Coop interruption obligations created
// when a verification replay times out.
package replaycancelstore

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

type Record struct {
	ReplayID, RunID, RunKey, SessionID, TurnID string
	Failures                                   int
	CreatedAt                                  time.Time
}

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

func (r *Repository) Next(ctx context.Context) (Record, error) {
	var item Record
	var createdAt string
	err := r.db.QueryRowContext(ctx, `
		SELECT replay_id, run_id, run_key, session_id, turn_id, failure_count, created_at
		FROM replay_cancellations
		WHERE state = 'pending' AND next_attempt_at <= ?
		ORDER BY next_attempt_at, created_at LIMIT 1`,
		r.clock().UTC().Format(core.TimestampFormat),
	).Scan(&item.ReplayID, &item.RunID, &item.RunKey, &item.SessionID, &item.TurnID, &item.Failures, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Record{}, core.ErrNotFound
	}
	if err != nil {
		return Record{}, err
	}
	item.CreatedAt, err = time.Parse(core.TimestampParseFormat, createdAt)
	return item, err
}

func (r *Repository) Complete(ctx context.Context, runKey string) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE replay_cancellations SET state = 'completed', last_error = '', updated_at = ?
		WHERE run_key = ? AND state = 'pending'`,
		r.clock().UTC().Format(core.TimestampFormat), runKey,
	)
	return r.absorbCompletion(ctx, runKey, result, err)
}

func (r *Repository) Retry(ctx context.Context, runKey, detail string, next time.Time) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE replay_cancellations
		SET failure_count = failure_count + 1, last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE run_key = ? AND state = 'pending'`,
		sqlutil.BoundedError(detail), next.UTC().Format(core.TimestampFormat),
		r.clock().UTC().Format(core.TimestampFormat), runKey,
	)
	return r.absorbCompletion(ctx, runKey, result, err)
}

func (r *Repository) absorbCompletion(ctx context.Context, runKey string, result sql.Result, err error) error {
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows == 1 {
		return err
	}
	var state string
	if err := r.db.QueryRowContext(ctx,
		`SELECT state FROM replay_cancellations WHERE run_key = ?`, runKey,
	).Scan(&state); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return core.ErrNotFound
		}
		return err
	}
	if state == "completed" {
		return nil
	}
	return core.ErrConflict
}
