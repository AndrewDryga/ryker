package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func (s *Store) RecordEmisarApproval(
	ctx context.Context,
	item core.EmisarApproval,
) (core.EmisarApproval, bool, error) {
	if item.RequestID == "" || item.ChannelID == "" ||
		item.SourceInput == "" || item.RunID == "" || item.OperationID == "" ||
		item.ActionID == "" || item.PackRef == "" || item.RunnerRef == "" ||
		item.Status != "pending_approval" || item.ApprovalURL == "" ||
		item.ExpiresAt.IsZero() {
		return core.EmisarApproval{}, false, errors.New("Emisar approval is incomplete")
	}
	now := time.Now().UTC()
	if item.CreatedAt.IsZero() {
		item.CreatedAt = now
	}
	item.UpdatedAt = now
	var incidentID any
	if item.IncidentID != "" {
		incidentID = item.IncidentID
	}
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO emisar_approvals (
		  request_id, incident_id, channel_id, source_input, run_id, operation_id,
		  action_id, pack_ref, runner_ref, status, approval_url, expires_at,
		  created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		item.RequestID, incidentID, item.ChannelID, item.SourceInput,
		item.RunID, item.OperationID, item.ActionID, item.PackRef, item.RunnerRef,
		item.Status, item.ApprovalURL, item.ExpiresAt.UTC().Format(timestampFormat),
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

func (s *Store) GetEmisarApproval(
	ctx context.Context,
	requestID string,
) (core.EmisarApproval, error) {
	var item core.EmisarApproval
	var expires, created, updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT request_id, COALESCE(incident_id, ''), channel_id, source_input, run_id,
		  operation_id, action_id, pack_ref, runner_ref, status, approval_url,
		  expires_at, created_at, updated_at
		FROM emisar_approvals WHERE request_id = ?`, requestID).Scan(
		&item.RequestID, &item.IncidentID, &item.ChannelID, &item.SourceInput,
		&item.RunID, &item.OperationID, &item.ActionID, &item.PackRef,
		&item.RunnerRef, &item.Status, &item.ApprovalURL, &expires, &created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EmisarApproval{}, ErrNotFound
	}
	if err != nil {
		return core.EmisarApproval{}, err
	}
	item.ExpiresAt = parseTime(expires)
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	return item, nil
}
