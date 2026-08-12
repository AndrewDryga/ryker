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
