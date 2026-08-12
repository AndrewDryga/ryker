// Package publicationrecoverystore restores interrupted publication attempts
// before the generic Slack-input recovery can replay their side effects.
package publicationrecoverystore

import (
	"context"
	"database/sql"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

func (r *Repository) RecoverInterrupted(ctx context.Context) error {
	now := r.clock().UTC().Format(core.TimestampFormat)
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		UPDATE incidents SET workflow = 'parked', updated_at = ?,
		  card_version = card_version + 1
		WHERE status != 'closed' AND workflow = 'closing'`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE publications SET state = 'published', failure_code = '', last_error = '',
		  updated_at = ?
		WHERE pr_number > 0 AND published_at IS NOT NULL AND EXISTS (
		  SELECT 1 FROM publication_followups
		  WHERE incident_id = publications.incident_id
		    AND pr_state IN ('merged', 'closed')
		)`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = ?, card_version = card_version + 1
		WHERE id IN (
		  SELECT incident_id FROM publications
		  WHERE state IN ('reviewing', 'publishing')
		)`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE publications AS publication SET
		  state = CASE WHEN EXISTS (
		    SELECT 1 FROM slack_inputs AS input
		    WHERE input.state = 'processing'
		      AND input.id = publication.attempt_input_id
		      AND input.action_id = 'responder_publish_pr'
		      AND input.action_value = publication.incident_id
		  ) THEN 'retrying' ELSE 'failed' END,
		  last_error = CASE WHEN EXISTS (
		    SELECT 1 FROM slack_inputs AS input
		    WHERE input.state = 'processing'
		      AND input.id = publication.attempt_input_id
		      AND input.action_id = 'responder_publish_pr'
		      AND input.action_value = publication.incident_id
		  ) THEN 'Responder restarted during draft PR work; retry is scheduled'
		  ELSE 'Responder stopped during draft PR work; retry it from the task card' END,
		  updated_at = ?
		WHERE state IN ('reviewing', 'publishing')
		  AND NOT EXISTS (
		    SELECT 1 FROM publication_followups
		    WHERE incident_id = publication.incident_id
		      AND pr_state IN ('merged', 'closed')
		  )`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_inputs SET state = 'retry', next_attempt_at = ?, updated_at = ?
		WHERE state = 'processing' AND action_id = 'responder_publish_pr'
		  AND EXISTS (
		    SELECT 1 FROM publications
		    WHERE publications.incident_id = slack_inputs.action_value
		      AND publications.attempt_input_id = slack_inputs.id
		      AND publications.state = 'retrying'
		  )`, now, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_inputs SET state = 'done', updated_at = ?
		WHERE state = 'processing' AND action_id = 'responder_publish_pr'
		  AND EXISTS (
		    SELECT 1 FROM publications
		    WHERE publications.incident_id = slack_inputs.action_value
		      AND publications.attempt_input_id = slack_inputs.id
		      AND publications.state IN ('failed', 'published', 'stale')
		  )`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO publication_followups (
		  incident_id, next_check_at, created_at, updated_at
		)
		SELECT publication.incident_id, ?, ?, ?
		FROM publications AS publication
		WHERE publication.state IN ('published', 'stale') AND EXISTS (
		  SELECT 1 FROM slack_inputs AS input
		  WHERE input.action_id = 'responder_publish_pr'
		    AND input.id = publication.attempt_input_id
		    AND input.action_value = publication.incident_id
		    AND input.state = 'done' AND input.updated_at = ?
		)`, now, now, now, now); err != nil {
		return err
	}
	return tx.Commit()
}
