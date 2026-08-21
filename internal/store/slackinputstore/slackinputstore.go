package slackinputstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

type Repository struct{ db *sql.DB }

func New(db *sql.DB) *Repository { return &Repository{db: db} }

type execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func Admit(
	ctx context.Context,
	db execer,
	input core.SlackInput,
	state string,
	attempts int,
	now string,
	deduplicate bool,
) (bool, error) {
	if input.ID == "" {
		var err error
		input.ID, err = core.NewID("slack")
		if err != nil {
			return false, err
		}
	}
	attachments, err := json.Marshal(input.Attachments)
	if err != nil {
		return false, fmt.Errorf("encode Slack input attachments: %w", err)
	}
	received := input.ReceivedAt
	if received.IsZero() {
		received = sqlutil.ParseTime(now)
	}
	result, err := db.ExecContext(ctx, `
		INSERT OR IGNORE INTO slack_inputs
		  (id, envelope_id, event_id, kind, team_id, channel_id, thread_ts, message_ts,
		   user_id, text, action_id, action_value, attachments_json, frozen_json, state, attempts, next_attempt_at,
		   received_at, updated_at)
		SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
		WHERE ? = 0 OR NOT EXISTS (
		  SELECT 1 FROM slack_inputs AS existing
		  WHERE existing.team_id = ? AND existing.channel_id = ?
		    AND existing.message_ts = ? AND existing.user_id = ?
		    AND existing.text = ? AND existing.attachments_json = ?
		)`,
		input.ID, input.EnvelopeID, input.EventID, input.Kind, input.TeamID, input.ChannelID,
		input.ThreadTS, input.MessageTS, input.UserID, input.Text, input.ActionID,
		input.ActionValue, attachments, input.Frozen, state, attempts, now,
		received.UTC().Format(core.TimestampFormat), now,
		boolInt(deduplicate), input.TeamID, input.ChannelID, input.MessageTS,
		input.UserID, input.Text, attachments)
	if err != nil {
		return false, fmt.Errorf("admit Slack input: %w", err)
	}
	rows, err := result.RowsAffected()
	return rows == 1, err
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

// SupersedeDeliveriesAfterAuthorizedInput applies Slack input authority at the
// outbox boundary. Persistence happens before capability enforcement, so a
// later denial must keep the refused input from suppressing an operator result.
func SupersedeDeliveriesAfterAuthorizedInput(
	ctx context.Context,
	db execer,
	now string,
) error {
	_, err := db.ExecContext(ctx, `
		UPDATE slack_deliveries AS delivery
		SET state = 'superseded', last_error = 'newer human turn admitted', updated_at = ?
		WHERE delivery.state IN ('pending', 'retry')
		  AND delivery.source_input_id != ''
		  AND EXISTS (
		    SELECT 1
		    FROM slack_inputs AS source
		    JOIN slack_inputs AS newer
		      ON newer.id != source.id
		     AND newer.channel_id = source.channel_id
		     AND COALESCE(NULLIF(newer.thread_ts, ''), newer.message_ts) =
		         COALESCE(NULLIF(source.thread_ts, ''), source.message_ts)
		     AND newer.kind IN ('message', 'mention', 'direct')
		     AND (
		       (source.message_ts != '' AND (
		         CAST(newer.message_ts AS REAL) > CAST(source.message_ts AS REAL) OR
		         (newer.message_ts = source.message_ts AND newer.rowid > source.rowid)
		       )) OR
		       (source.message_ts = '' AND (
		         newer.received_at > source.received_at OR
		         (newer.received_at = source.received_at AND newer.rowid > source.rowid)
		       ))
		     )
		    WHERE source.id = delivery.source_input_id
		      AND source.envelope_id NOT LIKE 'replay-public:%'
		      AND NOT EXISTS (
		        SELECT 1 FROM audit_events AS refusal
		        WHERE refusal.object_id = newer.id
		          AND refusal.kind = 'slack.input'
		          AND refusal.outcome = 'denied'
		      )
		  )`, now)
	return err
}

func (r *Repository) GetByEventID(ctx context.Context, eventID string) (core.SlackInput, error) {
	if strings.TrimSpace(eventID) == "" {
		return core.SlackInput{}, core.ErrNotFound
	}
	return Scan(r.db.QueryRowContext(ctx, `
		SELECT id, envelope_id, event_id, kind, team_id, channel_id, thread_ts,
		  message_ts, user_id, text, action_id, action_value, attachments_json,
		  frozen_json, state, attempts, failure_count, received_at
		FROM slack_inputs WHERE event_id = ?`, eventID))
}

// NewerBotMessages returns app notifications admitted after source in Slack
// order. Admission is the authority boundary: callers must not wait for the
// control lane to create a run before suppressing an older result.
func (r *Repository) NewerBotMessages(
	ctx context.Context,
	sourceID string,
) ([]core.SlackInput, error) {
	if sourceID == "" {
		return nil, core.ErrNotFound
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT newer.id, newer.envelope_id, newer.event_id, newer.kind, newer.team_id,
		  newer.channel_id, newer.thread_ts, newer.message_ts, newer.user_id, newer.text,
		  newer.action_id, newer.action_value, newer.attachments_json, newer.frozen_json,
		  newer.state, newer.attempts, newer.failure_count, newer.received_at
		FROM slack_inputs AS source
		JOIN slack_inputs AS newer
		  ON newer.id != source.id
		 AND newer.channel_id = source.channel_id
		 AND newer.user_id = source.user_id
		 AND newer.kind = 'bot_message'
		 AND (
		   CAST(newer.message_ts AS REAL) > CAST(source.message_ts AS REAL) OR
		   (newer.message_ts = source.message_ts AND newer.rowid > source.rowid)
		 )
		WHERE source.id = ?
		ORDER BY CAST(newer.message_ts AS REAL), newer.rowid`, sourceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var inputs []core.SlackInput
	for rows.Next() {
		input, scanErr := Scan(rows)
		if scanErr != nil {
			return nil, scanErr
		}
		inputs = append(inputs, input)
	}
	return inputs, rows.Err()
}

func Scan(row interface{ Scan(...any) error }) (core.SlackInput, error) {
	var input core.SlackInput
	var received string
	var attachments []byte
	err := row.Scan(
		&input.ID, &input.EnvelopeID, &input.EventID, &input.Kind, &input.TeamID,
		&input.ChannelID, &input.ThreadTS, &input.MessageTS, &input.UserID, &input.Text,
		&input.ActionID, &input.ActionValue, &attachments, &input.Frozen, &input.State,
		&input.Attempts, &input.Failures, &received,
	)
	if err == sql.ErrNoRows {
		return core.SlackInput{}, core.ErrNotFound
	}
	if err != nil {
		return core.SlackInput{}, err
	}
	if len(attachments) > 0 {
		if err := json.Unmarshal(attachments, &input.Attachments); err != nil {
			return core.SlackInput{}, fmt.Errorf("decode Slack input attachments: %w", err)
		}
	}
	input.ReceivedAt = sqlutil.ParseTime(received)
	return input, nil
}
