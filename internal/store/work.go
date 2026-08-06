package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"
)

const (
	WorkLaneControl     = "control"
	WorkLaneBackground  = "background"
	WorkLaneMaintenance = "maintenance"
)

type WorkItem struct {
	Kind            string
	SubjectID       string
	Lane            string
	ConversationKey string
	Priority        int
	State           string
	Failures        int
	AvailableAt     time.Time
	LeaseExpiresAt  time.Time
	LeaseToken      string
	DeadlineAt      time.Time
	LastError       string
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

type WorkQueueMetrics struct {
	Pending       int
	Running       int
	Failed        int
	OldestDueAge  time.Duration
	OldestRunning time.Duration
}

func validWorkLane(lane string) bool {
	return lane == WorkLaneControl ||
		lane == WorkLaneBackground ||
		lane == WorkLaneMaintenance
}

func enqueueWorkTx(
	ctx context.Context,
	tx interface {
		ExecContext(context.Context, string, ...any) (sql.Result, error)
	},
	item WorkItem,
	now string,
) error {
	if item.Kind == "" || item.SubjectID == "" {
		return errors.New("scheduled work kind and subject are required")
	}
	if !validWorkLane(item.Lane) {
		return fmt.Errorf("unsupported scheduled work lane %q", item.Lane)
	}
	if item.AvailableAt.IsZero() {
		item.AvailableAt = time.Now().UTC()
	}
	var deadline any
	if !item.DeadlineAt.IsZero() {
		deadline = item.DeadlineAt.UTC().Format(timestampFormat)
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO work_items (
		  kind, subject_id, lane, conversation_key, priority, state,
		  available_at, deadline_at, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
		ON CONFLICT(kind, subject_id) DO UPDATE SET
		  lane = excluded.lane,
		  conversation_key = excluded.conversation_key,
		  priority = MIN(work_items.priority, excluded.priority),
		  state = CASE
		    WHEN work_items.state = 'running' THEN work_items.state
		    ELSE 'pending'
		  END,
		  available_at = CASE
		    WHEN work_items.state = 'running' THEN work_items.available_at
		    WHEN julianday(work_items.available_at) <= julianday(excluded.available_at)
		      THEN work_items.available_at
		    ELSE excluded.available_at
		  END,
		  rerun_at = CASE
		    WHEN work_items.state != 'running' THEN work_items.rerun_at
		    WHEN work_items.rerun_at IS NULL THEN excluded.available_at
		    WHEN julianday(work_items.rerun_at) <= julianday(excluded.available_at)
		      THEN work_items.rerun_at
		    ELSE excluded.available_at
		  END,
		  deadline_at = COALESCE(excluded.deadline_at, work_items.deadline_at),
		  last_error = CASE
		    WHEN work_items.state = 'failed' THEN ''
		    ELSE work_items.last_error
		  END,
		  updated_at = excluded.updated_at`,
		item.Kind,
		item.SubjectID,
		item.Lane,
		item.ConversationKey,
		item.Priority,
		item.AvailableAt.UTC().Format(timestampFormat),
		deadline,
		now,
		now,
	)
	return err
}

func (s *Store) EnqueueWork(ctx context.Context, item WorkItem) error {
	return enqueueWorkTx(ctx, s.db, item, s.nowText())
}

// EnsureWork creates a scheduler record without changing an existing record's
// lease, retry schedule, or terminal state.
func (s *Store) EnsureWork(ctx context.Context, item WorkItem) error {
	if item.Kind == "" || item.SubjectID == "" {
		return errors.New("scheduled work kind and subject are required")
	}
	if !validWorkLane(item.Lane) {
		return fmt.Errorf("unsupported scheduled work lane %q", item.Lane)
	}
	now := s.nowText()
	if item.AvailableAt.IsZero() {
		item.AvailableAt = s.now().UTC()
	}
	var deadline any
	if !item.DeadlineAt.IsZero() {
		deadline = item.DeadlineAt.UTC().Format(timestampFormat)
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO work_items (
		  kind, subject_id, lane, conversation_key, priority, state,
		  available_at, deadline_at, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
		ON CONFLICT(kind, subject_id) DO NOTHING`,
		item.Kind,
		item.SubjectID,
		item.Lane,
		item.ConversationKey,
		item.Priority,
		item.AvailableAt.UTC().Format(timestampFormat),
		deadline,
		now,
		now,
	)
	return err
}

func scanWorkItem(row interface{ Scan(...any) error }) (WorkItem, error) {
	var item WorkItem
	var available, created, updated string
	var lease, deadline sql.NullString
	err := row.Scan(
		&item.Kind,
		&item.SubjectID,
		&item.Lane,
		&item.ConversationKey,
		&item.Priority,
		&item.State,
		&item.Failures,
		&available,
		&lease,
		&item.LeaseToken,
		&deadline,
		&item.LastError,
		&created,
		&updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return WorkItem{}, ErrNotFound
	}
	if err != nil {
		return WorkItem{}, err
	}
	item.AvailableAt = parseTime(available)
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	if lease.Valid {
		item.LeaseExpiresAt = parseTime(lease.String)
	}
	if deadline.Valid {
		item.DeadlineAt = parseTime(deadline.String)
	}
	return item, nil
}

func newWorkLeaseToken() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("generate scheduled work lease token: %w", err)
	}
	return hex.EncodeToString(value[:]), nil
}

func (s *Store) LeaseWork(
	ctx context.Context,
	lane string,
	leaseDuration time.Duration,
) (WorkItem, error) {
	if !validWorkLane(lane) {
		return WorkItem{}, fmt.Errorf("unsupported scheduled work lane %q", lane)
	}
	if leaseDuration <= 0 {
		return WorkItem{}, errors.New("scheduled work lease duration must be positive")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return WorkItem{}, err
	}
	defer tx.Rollback()
	now := s.now().UTC()
	if _, err := tx.ExecContext(ctx, `
		UPDATE work_items
		SET state = 'pending',
		    available_at = CASE
		      WHEN rerun_at IS NULL THEN updated_at
		      WHEN julianday(rerun_at) < julianday(updated_at) THEN rerun_at
		      ELSE updated_at
		    END,
		    lease_expires_at = NULL,
		    lease_token = '',
		    rerun_at = NULL,
		    last_error = CASE
		      WHEN last_error = '' THEN 'scheduled work lease expired'
		      ELSE last_error
		    END,
		    updated_at = ?
		WHERE state = 'running'
		  AND julianday(lease_expires_at) <= julianday(?)`,
		now.Format(timestampFormat),
		now.Format(timestampFormat),
	); err != nil {
		return WorkItem{}, err
	}
	item, err := scanWorkItem(tx.QueryRowContext(ctx, `
		SELECT kind, subject_id, lane, conversation_key, priority, state,
		  failure_count, available_at, lease_expires_at, lease_token, deadline_at,
		  last_error, created_at, updated_at
		FROM work_items AS candidate
		WHERE candidate.lane = ?
		  AND candidate.state = 'pending'
		  AND julianday(candidate.available_at) <= julianday(?)
		  AND (
		    candidate.conversation_key = '' OR NOT EXISTS (
		      SELECT 1 FROM work_items AS active
		      WHERE active.conversation_key = candidate.conversation_key
		        AND active.state = 'running'
		        AND julianday(active.lease_expires_at) > julianday(?)
		    )
		  )
		ORDER BY candidate.priority, candidate.available_at,
		  candidate.created_at, candidate.kind, candidate.subject_id
		LIMIT 1`,
		lane,
		now.Format(timestampFormat),
		now.Format(timestampFormat),
	))
	if err != nil {
		return WorkItem{}, err
	}
	leaseUntil := now.Add(leaseDuration)
	leaseToken, err := newWorkLeaseToken()
	if err != nil {
		return WorkItem{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE work_items
		SET state = 'running', lease_expires_at = ?, lease_token = ?, updated_at = ?
		WHERE kind = ? AND subject_id = ? AND state = 'pending'`,
		leaseUntil.Format(timestampFormat),
		leaseToken,
		now.Format(timestampFormat),
		item.Kind,
		item.SubjectID,
	)
	if err := expectOne(result, err, "lease scheduled work"); err != nil {
		return WorkItem{}, err
	}
	if err := tx.Commit(); err != nil {
		return WorkItem{}, err
	}
	item.State = "running"
	item.LeaseExpiresAt = leaseUntil
	item.LeaseToken = leaseToken
	item.UpdatedAt = now
	return item, nil
}

func (s *Store) CompleteWork(ctx context.Context, item WorkItem) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var rerun sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT rerun_at FROM work_items
		WHERE kind = ? AND subject_id = ? AND state = 'running'
		  AND lease_token = ?`,
		item.Kind,
		item.SubjectID,
		item.LeaseToken,
	).Scan(&rerun); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("complete scheduled work: %w", ErrConflict)
		}
		return err
	}
	if rerun.Valid {
		result, err := tx.ExecContext(ctx, `
			UPDATE work_items
			SET state = 'pending', available_at = ?, lease_expires_at = NULL,
			    lease_token = '', rerun_at = NULL, last_error = '', updated_at = ?
			WHERE kind = ? AND subject_id = ? AND state = 'running'
			  AND lease_token = ?`,
			rerun.String,
			s.nowText(),
			item.Kind,
			item.SubjectID,
			item.LeaseToken,
		)
		if err := expectOne(result, err, "rerun scheduled work"); err != nil {
			return err
		}
	} else {
		result, err := tx.ExecContext(ctx, `
			DELETE FROM work_items
			WHERE kind = ? AND subject_id = ? AND state = 'running'
			  AND lease_token = ?`,
			item.Kind,
			item.SubjectID,
			item.LeaseToken,
		)
		if err := expectOne(result, err, "complete scheduled work"); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RetryWork(
	ctx context.Context,
	item WorkItem,
	detail string,
	next time.Time,
	terminal bool,
) error {
	state := "pending"
	if terminal ||
		(!item.DeadlineAt.IsZero() && !next.Before(item.DeadlineAt)) {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE work_items
		SET state = ?, failure_count = failure_count + 1,
		    available_at = ?, lease_expires_at = NULL,
		    lease_token = '', last_error = ?, updated_at = ?
		WHERE kind = ? AND subject_id = ? AND state = 'running'
		  AND lease_token = ?`,
		state,
		next.UTC().Format(timestampFormat),
		boundedError(detail),
		s.nowText(),
		item.Kind,
		item.SubjectID,
		item.LeaseToken,
	)
	return expectOne(result, err, "retry scheduled work")
}

func (s *Store) DeferWork(
	ctx context.Context,
	item WorkItem,
	next time.Time,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE work_items
		SET state = 'pending', failure_count = 0, available_at = ?,
		    lease_expires_at = NULL, lease_token = '', last_error = '', updated_at = ?
		WHERE kind = ? AND subject_id = ? AND state = 'running'
		  AND lease_token = ?`,
		next.UTC().Format(timestampFormat),
		s.nowText(),
		item.Kind,
		item.SubjectID,
		item.LeaseToken,
	)
	return expectOne(result, err, "defer scheduled work")
}

func (s *Store) RecoverWorkLeases(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE work_items
		SET state = 'pending',
		    available_at = CASE
		      WHEN rerun_at IS NULL THEN updated_at
		      WHEN julianday(rerun_at) < julianday(updated_at) THEN rerun_at
		      ELSE updated_at
		    END,
		    lease_expires_at = NULL,
		    lease_token = '',
		    rerun_at = NULL,
		    last_error = CASE
		      WHEN last_error = '' THEN 'Responder stopped during scheduled work'
		      ELSE last_error
		    END,
		    updated_at = ?
		WHERE state = 'running'`,
		now.UTC().Format(timestampFormat),
	)
	return err
}

func (s *Store) WorkMetrics(
	ctx context.Context,
	lane string,
) (WorkQueueMetrics, error) {
	if !validWorkLane(lane) {
		return WorkQueueMetrics{}, fmt.Errorf("unsupported scheduled work lane %q", lane)
	}
	var result WorkQueueMetrics
	var oldestDue, oldestRunning sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT
		  COALESCE(SUM(CASE WHEN state = 'pending' THEN 1 ELSE 0 END), 0),
		  COALESCE(SUM(CASE WHEN state = 'running' THEN 1 ELSE 0 END), 0),
		  COALESCE(SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END), 0),
		  MIN(CASE WHEN state = 'pending' AND julianday(available_at) <= julianday(?)
		    THEN available_at END),
		  MIN(CASE WHEN state = 'running' THEN updated_at END)
		FROM work_items WHERE lane = ?`,
		s.nowText(),
		lane,
	).Scan(
		&result.Pending,
		&result.Running,
		&result.Failed,
		&oldestDue,
		&oldestRunning,
	)
	if err != nil {
		return WorkQueueMetrics{}, err
	}
	now := s.now().UTC()
	if oldestDue.Valid {
		result.OldestDueAge = max(now.Sub(parseTime(oldestDue.String)), 0)
	}
	if oldestRunning.Valid {
		result.OldestRunning = max(now.Sub(parseTime(oldestRunning.String)), 0)
	}
	return result, nil
}
