package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const emisarApprovalColumns = `
	request_id, COALESCE(incident_id, ''), channel_id, source_input,
	requested_by, delivery_id, message_ts, run_id, operation_id, action_id,
	pack_ref, runner_ref, status, approval_url, run_url, last_error,
	failure_count, continuation_queued, next_check_at, expires_at,
	terminal_at, created_at, updated_at`

func (s *Store) RecordEmisarApproval(
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
	now := s.now().UTC()
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
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO emisar_approvals (
		  request_id, incident_id, channel_id, source_input, requested_by,
		  delivery_id, message_ts, run_id, operation_id, action_id, pack_ref,
		  runner_ref, status, approval_url, run_url, last_error, failure_count,
		  continuation_queued, next_check_at, expires_at, terminal_at,
		  created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		item.RequestID, incidentID, item.ChannelID, item.SourceInput,
		item.RequestedBy, item.DeliveryID, item.MessageTS, item.RunID,
		item.OperationID, item.ActionID, item.PackRef, item.RunnerRef,
		item.Status, item.ApprovalURL, item.RunURL, item.LastError,
		item.FailureCount, boolInt(item.ContinuationQueued),
		item.NextCheckAt.UTC().Format(timestampFormat),
		item.ExpiresAt.UTC().Format(timestampFormat), nullableTime(item.TerminalAt),
		item.CreatedAt.UTC().Format(timestampFormat), item.UpdatedAt.Format(timestampFormat),
	)
	if err != nil {
		return core.EmisarApproval{}, false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return core.EmisarApproval{}, false, err
	}
	stored, err := s.GetEmisarApproval(ctx, item.RequestID)
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

func (s *Store) BindEmisarApprovalDelivery(
	ctx context.Context,
	requestID string,
	deliveryID string,
) (core.EmisarApproval, error) {
	if requestID == "" || deliveryID == "" {
		return core.EmisarApproval{}, errors.New("Emisar approval delivery binding is incomplete")
	}
	tx, err := s.db.BeginTx(ctx, nil)
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
			return core.EmisarApproval{}, ErrNotFound
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
		s.nowText(),
		requestID,
	); err != nil {
		return core.EmisarApproval{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.EmisarApproval{}, err
	}
	return s.GetEmisarApproval(ctx, requestID)
}

func (s *Store) GetEmisarApproval(
	ctx context.Context,
	requestID string,
) (core.EmisarApproval, error) {
	return scanEmisarApproval(s.db.QueryRowContext(ctx, `
		SELECT `+emisarApprovalColumns+`
		FROM emisar_approvals WHERE request_id = ?`, requestID))
}

func (s *Store) ListEmisarApprovalsForIncident(
	ctx context.Context,
	incidentID string,
) ([]core.EmisarApproval, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+emisarApprovalColumns+`
		FROM emisar_approvals WHERE incident_id = ?
		ORDER BY created_at, request_id`, incidentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]core.EmisarApproval, 0)
	for rows.Next() {
		item, err := scanEmisarApproval(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func scanEmisarApproval(
	row interface{ Scan(...any) error },
) (core.EmisarApproval, error) {
	var item core.EmisarApproval
	var continuation int
	var next, expires, created, updated string
	var terminal sql.NullString
	err := row.Scan(
		&item.RequestID, &item.IncidentID, &item.ChannelID, &item.SourceInput,
		&item.RequestedBy, &item.DeliveryID, &item.MessageTS, &item.RunID,
		&item.OperationID, &item.ActionID, &item.PackRef, &item.RunnerRef,
		&item.Status, &item.ApprovalURL, &item.RunURL, &item.LastError,
		&item.FailureCount, &continuation, &next, &expires, &terminal,
		&created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EmisarApproval{}, ErrNotFound
	}
	if err != nil {
		return core.EmisarApproval{}, err
	}
	item.ContinuationQueued = continuation != 0
	item.NextCheckAt = parseTime(next)
	item.ExpiresAt = parseTime(expires)
	item.TerminalAt = scanTime(terminal)
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	return item, nil
}

func (s *Store) ListMonitorableEmisarApprovals(
	ctx context.Context,
	limit int,
) ([]core.EmisarApproval, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+emisarApprovalColumns+`
		FROM emisar_approvals
		WHERE continuation_queued = 0
		ORDER BY next_check_at, created_at, request_id
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]core.EmisarApproval, 0)
	for rows.Next() {
		item, err := scanEmisarApproval(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (s *Store) AdvanceEmisarApproval(
	ctx context.Context,
	requestID string,
	status string,
	runURL string,
	detail string,
	nextCheckAt time.Time,
) (core.EmisarApproval, bool, error) {
	if requestID == "" || !validEmisarRunStatus(status) || nextCheckAt.IsZero() {
		return core.EmisarApproval{}, false, errors.New("Emisar approval update is invalid")
	}
	stored, err := s.GetEmisarApproval(ctx, requestID)
	if err != nil {
		return core.EmisarApproval{}, false, err
	}
	if emisarRunTerminal(stored.Status) && stored.Status != status {
		return core.EmisarApproval{}, false, fmt.Errorf(
			"terminal Emisar run status %q cannot transition to %q",
			stored.Status,
			status,
		)
	}
	now := s.now().UTC()
	var terminal any
	if emisarRunTerminal(status) {
		if stored.TerminalAt.IsZero() {
			terminal = now.Format(timestampFormat)
		} else {
			terminal = stored.TerminalAt.Format(timestampFormat)
		}
	}
	changed := stored.Status != status || stored.RunURL != runURL ||
		stored.LastError != detail
	result, err := s.db.ExecContext(ctx, `
		UPDATE emisar_approvals
		SET status = ?, run_url = ?, last_error = ?, failure_count = 0,
		    next_check_at = ?, terminal_at = COALESCE(terminal_at, ?), updated_at = ?
		WHERE request_id = ?`,
		status,
		runURL,
		boundedError(detail),
		nextCheckAt.UTC().Format(timestampFormat),
		terminal,
		now.Format(timestampFormat),
		requestID,
	)
	if err := expectOne(result, err, "advance Emisar approval"); err != nil {
		return core.EmisarApproval{}, false, err
	}
	updated, err := s.GetEmisarApproval(ctx, requestID)
	return updated, changed, err
}

func (s *Store) RetryEmisarApproval(
	ctx context.Context,
	requestID string,
	detail string,
	nextCheckAt time.Time,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE emisar_approvals
		SET failure_count = failure_count + 1, last_error = ?, next_check_at = ?,
		    updated_at = ?
		WHERE request_id = ? AND continuation_queued = 0`,
		boundedError(detail),
		nextCheckAt.UTC().Format(timestampFormat),
		s.nowText(),
		requestID,
	)
	return expectOne(result, err, "retry Emisar approval")
}

func (s *Store) MarkEmisarApprovalContinuationQueued(
	ctx context.Context,
	requestID string,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE emisar_approvals
		SET continuation_queued = 1, updated_at = ?
		WHERE request_id = ? AND terminal_at IS NOT NULL`,
		s.nowText(),
		requestID,
	)
	return expectOne(result, err, "mark Emisar approval continuation queued")
}

func validEmisarRunStatus(status string) bool {
	switch status {
	case "pending", "pending_approval", "sent", "running", "cancelling",
		"success", "failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "refused", "denied":
		return true
	default:
		return false
	}
}

func emisarRunTerminal(status string) bool {
	switch status {
	case "success", "failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "refused", "denied":
		return true
	default:
		return false
	}
}
