package taskcardstore

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// Repository owns the durable Slack card used to present an engineering task.
type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

func (r *Repository) nowText() string {
	return r.clock().UTC().Format(core.TimestampFormat)
}

// AdoptOffer makes the existing offer message the task's durable status card.
func (r *Repository) AdoptOffer(ctx context.Context, id, messageTS string) error {
	if strings.TrimSpace(messageTS) == "" {
		return errors.New("adopt task card requires a Slack message timestamp")
	}
	now := r.nowText()
	result, err := r.db.ExecContext(ctx, `
		UPDATE incidents SET channel_id = origin_channel_id, root_ts = ?,
		  workflow = 'provisioning_session', channel_state = 'active',
		  channel_state_changed_at = ?, channel_checked_at = ?, updated_at = ?,
		  card_version = card_version + 1, last_error = ''
		WHERE id = ? AND work_scope = 'thread' AND channel_id = '' AND root_ts = ''
		  AND origin_channel_id != '' AND origin_thread_ts != ''`,
		messageTS, now, now, now, id)
	return sqlutil.ExpectOne(result, err, "adopt task card")
}

// SetUpdate replaces the human-readable progress section on the task card.
func (r *Repository) SetUpdate(ctx context.Context, id, runID, update string) error {
	update = core.BoundedText(strings.TrimSpace(update), 6000)
	now := r.nowText()
	result, err := r.db.ExecContext(ctx, `
		UPDATE incidents SET latest_update = ?, latest_update_run_id = ?,
		  latest_update_run_key = run_key.value, updated_at = ?,
		  card_version = card_version + CASE
		    WHEN latest_update != ? OR latest_update_run_id != ?
		      OR latest_update_run_key != run_key.value THEN 1 ELSE 0 END,
		  last_error = ''
		FROM (SELECT COALESCE((
		  SELECT idempotency_key FROM agent_runs WHERE id = ?
		), '') AS value) AS run_key
		WHERE incidents.id = ? AND work_kind = 'engineering_task'`,
		update, runID, now, update, runID, runID, id)
	return sqlutil.ExpectOne(result, err, "update task card")
}
