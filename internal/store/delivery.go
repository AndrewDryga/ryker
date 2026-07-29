package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const slackDeliveryColumns = `
	id, COALESCE(incident_id, ''), operation, kind, channel_id, thread_ts,
	message_ts, body_json, status_text, steps_json, coalesce_key, card_version,
	state, failure_count, next_attempt_at, last_error, created_at`

func (s *Store) EnqueueSlackDelivery(
	ctx context.Context,
	delivery core.SlackDelivery,
) (bool, error) {
	if delivery.Operation == "" {
		delivery.Operation = "post"
	}
	if delivery.Operation != "post" && delivery.Operation != "update" &&
		delivery.Operation != "status" {
		return false, fmt.Errorf(
			"unsupported Slack delivery operation %q",
			delivery.Operation,
		)
	}
	if delivery.ChannelID == "" {
		return false, errors.New("Slack delivery channel is required")
	}
	if delivery.Operation == "post" && len(delivery.Body) == 0 {
		return false, errors.New("Slack post delivery body is required")
	}
	if delivery.Operation == "update" &&
		(delivery.MessageTS == "" || len(delivery.Body) == 0) {
		return false, errors.New("Slack update delivery target and body are required")
	}
	if delivery.Operation == "status" && delivery.ThreadTS == "" {
		return false, errors.New("Slack status delivery thread is required")
	}
	if delivery.Body == nil {
		delivery.Body = []byte{}
	}
	if delivery.ID == "" {
		var err error
		delivery.ID, err = core.NewID("delivery")
		if err != nil {
			return false, err
		}
	}
	steps, err := json.Marshal(delivery.Steps)
	if err != nil {
		return false, fmt.Errorf("encode Slack delivery steps: %w", err)
	}
	if string(steps) == "null" || len(steps) == 0 {
		steps = []byte("[]")
	}
	var incidentID any
	if delivery.IncidentID != "" {
		incidentID = delivery.IncidentID
	}
	now := nowText()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO slack_deliveries (
		  id, incident_id, operation, kind, channel_id, thread_ts, message_ts,
		  body_json, status_text, steps_json, coalesce_key, card_version,
		  state, next_attempt_at, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		delivery.ID, incidentID, delivery.Operation, delivery.Kind,
		delivery.ChannelID, delivery.ThreadTS, delivery.MessageTS, delivery.Body,
		delivery.Status, steps, delivery.CoalesceKey, delivery.CardVersion,
		now, now, now)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if rows == 1 && delivery.CoalesceKey != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE slack_deliveries
			SET state = 'superseded', updated_at = ?
			WHERE coalesce_key = ? AND id != ?
			  AND state IN ('pending', 'retry')`,
			now, delivery.CoalesceKey, delivery.ID); err != nil {
			return false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return rows == 1, nil
}

func scanSlackDelivery(
	row interface{ Scan(...any) error },
) (core.SlackDelivery, error) {
	var delivery core.SlackDelivery
	var steps []byte
	var next, created string
	err := row.Scan(
		&delivery.ID, &delivery.IncidentID, &delivery.Operation, &delivery.Kind,
		&delivery.ChannelID, &delivery.ThreadTS, &delivery.MessageTS,
		&delivery.Body, &delivery.Status, &steps, &delivery.CoalesceKey,
		&delivery.CardVersion, &delivery.State, &delivery.Attempts, &next,
		&delivery.LastError, &created,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.SlackDelivery{}, ErrNotFound
	}
	if err != nil {
		return core.SlackDelivery{}, err
	}
	if len(steps) > 0 {
		if err := json.Unmarshal(steps, &delivery.Steps); err != nil {
			return core.SlackDelivery{}, fmt.Errorf(
				"decode Slack delivery steps: %w",
				err,
			)
		}
	}
	delivery.NextAttemptAt = parseTime(next)
	delivery.CreatedAt = parseTime(created)
	return delivery, nil
}

func (s *Store) LeaseSlackDelivery(
	ctx context.Context,
) (core.SlackDelivery, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.SlackDelivery{}, err
	}
	defer tx.Rollback()
	now := nowText()
	delivery, err := scanSlackDelivery(tx.QueryRowContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE state IN ('pending', 'retry')
		  AND julianday(next_attempt_at) <= julianday(?)
		ORDER BY
		  CASE operation WHEN 'status' THEN 0 WHEN 'update' THEN 1 ELSE 2 END,
		  created_at,
		  id
		LIMIT 1`, now))
	if err != nil {
		return core.SlackDelivery{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'sending', failure_count = failure_count + 1, updated_at = ?
		WHERE id = ? AND state IN ('pending', 'retry')`,
		now, delivery.ID)
	if err := expectOne(result, err, "lease Slack delivery"); err != nil {
		return core.SlackDelivery{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.SlackDelivery{}, err
	}
	delivery.State = "sending"
	delivery.Attempts++
	return delivery, nil
}

func (s *Store) FinishSlackDelivery(
	ctx context.Context,
	id string,
	messageTS string,
	fromState string,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var incidentID sql.NullString
	var kind string
	var cardVersion int64
	if err := tx.QueryRowContext(ctx, `
		SELECT incident_id, kind, card_version
		FROM slack_deliveries
		WHERE id = ? AND state = ?`,
		id, fromState).Scan(&incidentID, &kind, &cardVersion); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("finish Slack delivery: %w", ErrConflict)
		}
		return err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'sent', message_ts = CASE WHEN ? = '' THEN message_ts ELSE ? END,
		    last_error = '', updated_at = ?
		WHERE id = ? AND state = ?`,
		messageTS, messageTS, nowText(), id, fromState)
	if err := expectOne(result, err, "finish Slack delivery"); err != nil {
		return err
	}
	if incidentID.Valid && kind == "root" {
		result, err = tx.ExecContext(ctx, `
			UPDATE incidents
			SET root_ts = ?, workflow = 'provisioning_session',
			    updated_at = ?, card_version = card_version + 1, last_error = ''
			WHERE id = ? AND channel_id != '' AND root_ts = ''`,
			messageTS, nowText(), incidentID.String)
		if err := expectOne(result, err, "bind incident root"); err != nil {
			return err
		}
	}
	if incidentID.Valid && kind == "card" && cardVersion > 0 {
		if _, err := tx.ExecContext(ctx, `
			UPDATE incidents
			SET card_rendered_version = MAX(card_rendered_version, ?), updated_at = ?
			WHERE id = ?`,
			cardVersion, nowText(), incidentID.String); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RetrySlackDelivery(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
	uncertain bool,
	terminal bool,
) error {
	state := "retry"
	if uncertain {
		state = "uncertain"
	} else if terminal {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = ?, last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'sending'`,
		state, boundedError(detail), next.UTC().Format(timestampFormat),
		nowText(), id)
	return expectOne(result, err, "retry Slack delivery")
}

func (s *Store) ListUncertainSlackDeliveries(
	ctx context.Context,
	limit int,
) ([]core.SlackDelivery, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE state = 'uncertain' AND operation = 'post'
		  AND julianday(next_attempt_at) <= julianday(?)
		ORDER BY created_at, id
		LIMIT ?`, nowText(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.SlackDelivery, 0)
	for rows.Next() {
		delivery, err := scanSlackDelivery(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, delivery)
	}
	return result, rows.Err()
}

func (s *Store) RetryUncertainSlackDelivery(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
	terminal bool,
) error {
	state := "retry"
	if terminal {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = ?, last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'uncertain'`,
		state, boundedError(detail), next.UTC().Format(timestampFormat),
		nowText(), id)
	return expectOne(result, err, "retry uncertain Slack delivery")
}
