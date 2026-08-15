// Package approvalstore owns the Emisar approval record: the durable proof that
// a governed mutation was requested, who asked for it, which episode asked, and
// what Emisar finally said about it.
//
// It is a repository rather than methods on Store for the reason every other
// extraction here exists — a delegating method still counts against the store's
// method budget, so an extraction only reduces the surface if callers reach it
// through the field.
//
// It decides nothing about authority. Whether an operator may request an action
// is settled before a row lands here, and whether the run's terminal status
// earns or costs a rung is decided in internal/remediation. What this package
// owns is identity and monotonicity: an approval's immutable fields cannot be
// rewritten by a redelivered result, and a terminal status cannot become a
// different terminal status.
package approvalstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// Repository reads and writes emisar_approvals.
type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

func (r *Repository) now() time.Time { return r.clock().UTC() }

func (r *Repository) nowText() string {
	return r.now().Format(core.TimestampFormat)
}

const columns = `
	request_id, COALESCE(incident_id, ''), channel_id, source_input,
	requested_by, delivery_id, message_ts, run_id, operation_id, action_id,
	pack_ref, runner_ref, status, approval_url, run_url, last_error,
	failure_count, continuation_queued, next_check_at, expires_at,
	terminal_at, created_at, updated_at`

func (r *Repository) Record(
	ctx context.Context,
	item core.EmisarApproval,
) (core.EmisarApproval, bool, error) {
	if item.RequestID == "" || item.ChannelID == "" ||
		item.SourceInput == "" || item.RequestedBy == "" || item.RunID == "" ||
		item.OperationID == "" || item.ActionID == "" || item.PackRef == "" ||
		item.RunnerRef == "" || item.Status != "pending_approval" ||
		item.ApprovalURL == "" || item.ExpiresAt.IsZero() {
		return core.EmisarApproval{}, false, errors.New("Emisar approval is incomplete")
	}
	now := r.now()
	if item.CreatedAt.IsZero() {
		item.CreatedAt = now
	}
	if item.NextCheckAt.IsZero() {
		item.NextCheckAt = now
	}
	item.UpdatedAt = now
	var incidentID any
	if item.IncidentID != "" {
		incidentID = item.IncidentID
	}
	result, err := r.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO emisar_approvals (
		  request_id, incident_id, channel_id, source_input,
		  requested_by, delivery_id, message_ts, run_id, operation_id, action_id,
		  pack_ref, runner_ref, status, approval_url, run_url, last_error,
		  failure_count, continuation_queued, next_check_at, expires_at,
		  terminal_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		item.RequestID, incidentID, item.ChannelID, item.SourceInput,
		item.RequestedBy, item.DeliveryID, item.MessageTS, item.RunID,
		item.OperationID, item.ActionID, item.PackRef, item.RunnerRef,
		item.Status, item.ApprovalURL, item.RunURL, item.LastError,
		item.FailureCount, boolInt(item.ContinuationQueued),
		item.NextCheckAt.UTC().Format(core.TimestampFormat),
		item.ExpiresAt.UTC().Format(core.TimestampFormat), sqlutil.TimeText(item.TerminalAt),
		item.CreatedAt.UTC().Format(core.TimestampFormat),
		item.UpdatedAt.Format(core.TimestampFormat),
	)
	if err != nil {
		return core.EmisarApproval{}, false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return core.EmisarApproval{}, false, err
	}
	stored, err := r.Get(ctx, item.RequestID)
	if err != nil {
		return core.EmisarApproval{}, false, err
	}
	if stored.IncidentID != item.IncidentID || stored.ChannelID != item.ChannelID ||
		stored.SourceInput != item.SourceInput || stored.RequestedBy != item.RequestedBy ||
		stored.RunID != item.RunID || stored.OperationID != item.OperationID ||
		stored.ActionID != item.ActionID || stored.PackRef != item.PackRef ||
		stored.RunnerRef != item.RunnerRef || stored.ApprovalURL != item.ApprovalURL ||
		!stored.ExpiresAt.Equal(item.ExpiresAt) {
		return core.EmisarApproval{}, false, fmt.Errorf(
			"Emisar approval %q conflicts with its stored immutable identity",
			item.RequestID,
		)
	}
	return stored, rows == 1, nil
}

func (r *Repository) BindDelivery(
	ctx context.Context,
	requestID string,
	deliveryID string,
) (core.EmisarApproval, error) {
	if requestID == "" || deliveryID == "" {
		return core.EmisarApproval{}, errors.New("Emisar approval delivery binding is incomplete")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return core.EmisarApproval{}, err
	}
	defer tx.Rollback()
	var existing string
	if err := tx.QueryRowContext(
		ctx,
		`SELECT delivery_id FROM emisar_approvals WHERE request_id = ?`,
		requestID,
	).Scan(&existing); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return core.EmisarApproval{}, core.ErrNotFound
		}
		return core.EmisarApproval{}, err
	}
	if existing != "" && existing != deliveryID {
		return core.EmisarApproval{}, fmt.Errorf(
			"Emisar approval %q is already bound to Slack delivery %q",
			requestID,
			existing,
		)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE emisar_approvals
		SET delivery_id = ?,
		    message_ts = COALESCE((
		      SELECT message_ts FROM slack_deliveries
		      WHERE id = ? AND state = 'sent'
		    ), message_ts),
		    updated_at = ?
		WHERE request_id = ?`,
		deliveryID,
		deliveryID,
		r.nowText(),
		requestID,
	); err != nil {
		return core.EmisarApproval{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.EmisarApproval{}, err
	}
	return r.Get(ctx, requestID)
}

func (r *Repository) Get(
	ctx context.Context,
	requestID string,
) (core.EmisarApproval, error) {
	return scan(r.db.QueryRowContext(ctx, `
		SELECT `+columns+`
		FROM emisar_approvals WHERE request_id = ?`, requestID))
}

func (r *Repository) ListForIncident(
	ctx context.Context,
	incidentID string,
) ([]core.EmisarApproval, error) {
	return r.list(ctx, `
		SELECT `+columns+`
		FROM emisar_approvals WHERE incident_id = ?
		ORDER BY created_at, request_id`, incidentID)
}

func (r *Repository) ListMonitorable(
	ctx context.Context,
	limit int,
) ([]core.EmisarApproval, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	return r.list(ctx, `
		SELECT `+columns+`
		FROM emisar_approvals
		WHERE continuation_queued = 0
		ORDER BY next_check_at, created_at, request_id
		LIMIT ?`, limit)
}

func (r *Repository) list(
	ctx context.Context,
	query string,
	args ...any,
) ([]core.EmisarApproval, error) {
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]core.EmisarApproval, 0)
	for rows.Next() {
		item, err := scan(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func scan(row interface{ Scan(...any) error }) (core.EmisarApproval, error) {
	var item core.EmisarApproval
	var continuation int
	var next, expires, created, updated string
	var terminal sql.NullString
	err := row.Scan(
		&item.RequestID, &item.IncidentID, &item.ChannelID,
		&item.SourceInput, &item.RequestedBy, &item.DeliveryID, &item.MessageTS,
		&item.RunID, &item.OperationID, &item.ActionID, &item.PackRef,
		&item.RunnerRef, &item.Status, &item.ApprovalURL, &item.RunURL,
		&item.LastError, &item.FailureCount, &continuation, &next, &expires,
		&terminal, &created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EmisarApproval{}, core.ErrNotFound
	}
	if err != nil {
		return core.EmisarApproval{}, err
	}
	item.ContinuationQueued = continuation != 0
	item.NextCheckAt = sqlutil.ParseTime(next)
	item.ExpiresAt = sqlutil.ParseTime(expires)
	item.TerminalAt = sqlutil.ScanTime(terminal)
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	return item, nil
}

func (r *Repository) Advance(
	ctx context.Context,
	requestID string,
	status string,
	runURL string,
	detail string,
	nextCheckAt time.Time,
) (core.EmisarApproval, bool, error) {
	if requestID == "" || !ValidRunStatus(status) || nextCheckAt.IsZero() {
		return core.EmisarApproval{}, false, errors.New("Emisar approval update is invalid")
	}
	stored, err := r.Get(ctx, requestID)
	if err != nil {
		return core.EmisarApproval{}, false, err
	}
	if RunTerminal(stored.Status) && stored.Status != status {
		return core.EmisarApproval{}, false, fmt.Errorf(
			"terminal Emisar run status %q cannot transition to %q",
			stored.Status,
			status,
		)
	}
	now := r.now()
	var terminal any
	if RunTerminal(status) {
		if stored.TerminalAt.IsZero() {
			terminal = now.Format(core.TimestampFormat)
		} else {
			terminal = stored.TerminalAt.Format(core.TimestampFormat)
		}
	}
	changed := stored.Status != status || stored.RunURL != runURL ||
		stored.LastError != detail
	result, err := r.db.ExecContext(ctx, `
		UPDATE emisar_approvals
		SET status = ?, run_url = ?, last_error = ?, failure_count = 0,
		    next_check_at = ?, terminal_at = COALESCE(terminal_at, ?), updated_at = ?
		WHERE request_id = ?`,
		status,
		runURL,
		sqlutil.BoundedError(detail),
		nextCheckAt.UTC().Format(core.TimestampFormat),
		terminal,
		now.Format(core.TimestampFormat),
		requestID,
	)
	if err := sqlutil.ExpectOne(result, err, "advance Emisar approval"); err != nil {
		return core.EmisarApproval{}, false, err
	}
	updated, err := r.Get(ctx, requestID)
	return updated, changed, err
}

func (r *Repository) Retry(
	ctx context.Context,
	requestID string,
	detail string,
	nextCheckAt time.Time,
) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE emisar_approvals
		SET failure_count = failure_count + 1, last_error = ?, next_check_at = ?,
		    updated_at = ?
		WHERE request_id = ? AND continuation_queued = 0`,
		sqlutil.BoundedError(detail),
		nextCheckAt.UTC().Format(core.TimestampFormat),
		r.nowText(),
		requestID,
	)
	return sqlutil.ExpectOne(result, err, "retry Emisar approval")
}

func (r *Repository) MarkContinuationQueued(
	ctx context.Context,
	requestID string,
) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE emisar_approvals
		SET continuation_queued = 1, updated_at = ?
		WHERE request_id = ? AND terminal_at IS NOT NULL`,
		r.nowText(),
		requestID,
	)
	return sqlutil.ExpectOne(result, err, "mark Emisar approval continuation queued")
}

// ValidRunStatus and RunTerminal were spelled twice — once in the store and
// once in the service — which is one copy per place that could drift.
func ValidRunStatus(status string) bool {
	switch status {
	case "pending", "pending_approval", "sent", "running", "cancelling",
		"success", "failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "refused", "denied":
		return true
	default:
		return false
	}
}

func RunTerminal(status string) bool {
	switch status {
	case "success", "failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "refused", "denied":
		return true
	default:
		return false
	}
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
