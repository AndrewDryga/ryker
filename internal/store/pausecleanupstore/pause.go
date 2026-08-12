// Package pausecleanupstore finds pre-upgrade Slack messages whose terminal
// work still carries Responder's old pause reaction.
package pausecleanupstore

import (
	"context"
	"database/sql"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/slackinputstore"
)

type Repository struct{ db *sql.DB }

func New(db *sql.DB) *Repository { return &Repository{db: db} }

// Queued reports whether an older build durably recorded a pause that still
// needs removing. Modern inputs never receive this audit, so callers must not
// manufacture a cleanup receipt merely because an ordinary reply completed.
func (r *Repository) Queued(ctx context.Context, inputID string) (bool, error) {
	var queued bool
	err := r.db.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1 FROM audit_events AS paused
		  WHERE paused.kind = 'slack.paused' AND paused.object_id = ?
		    AND paused.outcome = 'queued'
		) AND NOT EXISTS (
		  SELECT 1 FROM audit_events AS cleared
		  WHERE cleared.kind = 'slack.paused' AND cleared.object_id = ?
		    AND cleared.outcome = 'cleared'
		)`, inputID, inputID).Scan(&queued)
	return queued, err
}

// MarkCleared records an idempotent receipt only for a real legacy pause.
func (r *Repository) MarkCleared(ctx context.Context, inputID string, now time.Time) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO audit_events
		  (id, kind, actor_id, object_id, outcome, detail, created_at)
		SELECT 'slack_pause_cleared_' || ?, 'slack.paused', 'responder', ?,
		       'cleared', 'removed legacy pause after terminal work', ?
		WHERE EXISTS (
		  SELECT 1 FROM audit_events AS paused
		  WHERE paused.kind = 'slack.paused' AND paused.object_id = ?
		    AND paused.outcome = 'queued'
		)
		ON CONFLICT(id) DO NOTHING`, inputID, inputID, now.UTC().Format(time.RFC3339Nano), inputID)
	return err
}

// Next returns one terminal input with a durable paused audit and no durable
// cleanup receipt. The scheduler owns retries, so a transient Slack failure
// leaves this row eligible across process restarts.
func (r *Repository) Next(ctx context.Context) (core.SlackInput, error) {
	return slackinputstore.Scan(r.db.QueryRowContext(ctx, `
		SELECT input.id, input.envelope_id, input.event_id, input.kind, input.team_id,
		  input.channel_id, input.thread_ts, input.message_ts, input.user_id, input.text,
		  input.action_id, input.action_value, input.attachments_json, input.frozen_json,
		  input.state, input.attempts, input.failure_count, input.received_at
		FROM slack_inputs AS input
		WHERE input.channel_id != '' AND input.message_ts != ''
		  AND EXISTS (
		    SELECT 1 FROM audit_events AS paused
		    WHERE paused.kind = 'slack.paused' AND paused.object_id = input.id
		      AND paused.outcome = 'queued'
		  )
		  AND EXISTS (
		    SELECT 1 FROM agent_runs AS run
		    WHERE run.source_id = input.id
		      AND run.state IN ('completed', 'failed', 'cancelled', 'superseded')
		  )
		  AND NOT EXISTS (
		    SELECT 1 FROM audit_events AS cleared
		    WHERE cleared.kind = 'slack.paused' AND cleared.object_id = input.id
		      AND cleared.outcome = 'cleared'
		  )
		ORDER BY input.received_at, input.id
		LIMIT 1`))
}
