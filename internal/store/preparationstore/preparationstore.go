// Package preparationstore owns the durable lifecycle of the one mutable
// workspace-preparation notice attached to a triage run.
package preparationstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

type DeleteTarget struct {
	ChannelID string
	MessageTS string
}

// PreserveCausalRetirementSQL prevents ordinary coalescing from cancelling a
// delete whose outcome or predecessor is ambiguous. Its sole placeholder is
// the newly inserted delivery ID, which is not a pre-existing recurrence.
const PreserveCausalRetirementSQL = `
	AND NOT (
	  operation = 'delete' AND kind = 'notice_retirement' AND (
	    failure_count > 0 OR EXISTS (
	      SELECT 1 FROM slack_deliveries AS ambiguous
	      WHERE ambiguous.coalesce_key = slack_deliveries.coalesce_key
	        AND ambiguous.rowid < slack_deliveries.rowid
	        AND ambiguous.operation IN ('post', 'update')
	        AND ambiguous.state IN ('sending', 'uncertain')
	    ) OR EXISTS (
	      SELECT 1 FROM slack_deliveries AS recurrence
	      WHERE recurrence.coalesce_key = slack_deliveries.coalesce_key
	        AND recurrence.rowid > slack_deliveries.rowid
	        AND recurrence.id != ?
	        AND recurrence.operation IN ('post', 'update')
	        AND recurrence.state IN ('pending', 'retry', 'sending', 'uncertain', 'sent')
	    )
	  )
	)`

// LeaseBarrierSQL serializes both sides of a blocker/delete boundary. A delete
// waits for an ambiguous post to resolve; a recurring post waits for every
// older causal delete to finish.
const LeaseBarrierSQL = `
	AND (
	  candidate.operation != 'delete' OR candidate.kind != 'notice_retirement' OR NOT EXISTS (
	    SELECT 1 FROM slack_deliveries AS blocker
	    WHERE blocker.coalesce_key = candidate.coalesce_key
	      AND blocker.rowid < candidate.rowid
	      AND (
	        (blocker.operation IN ('post', 'update') AND
	         blocker.state IN ('pending', 'retry', 'sending', 'uncertain')) OR
	        (blocker.operation = 'delete' AND blocker.kind = 'notice_retirement' AND
	         blocker.state IN ('pending', 'retry', 'sending'))
	      )
	  )
	)
	AND (
	  candidate.kind != 'notice' OR candidate.operation NOT IN ('post', 'update') OR NOT EXISTS (
	    SELECT 1 FROM slack_deliveries AS retirement
	    WHERE retirement.coalesce_key = candidate.coalesce_key
	      AND retirement.rowid < candidate.rowid
	      AND retirement.operation = 'delete'
	      AND retirement.kind = 'notice_retirement'
	      AND retirement.state IN ('pending', 'retry', 'sending')
	  )
	)`

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

func (r *Repository) Retire(ctx context.Context, prefix string) (bool, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	created, err := RetireTx(ctx, tx, prefix, r.nowText())
	if err != nil {
		return false, err
	}
	return created, tx.Commit()
}

// RetireTx records recovery even when the blocker has not reached Slack yet.
// The intent supersedes queued blockers immediately and waits behind an
// in-flight or uncertain post until its Slack timestamp becomes durable.
func RetireTx(ctx context.Context, tx *sql.Tx, prefix, now string) (bool, error) {
	if prefix == "" {
		return false, nil
	}
	var episodeID, runID, runKey, sourceID, channelID string
	var blockerRowID int64
	err := tx.QueryRowContext(ctx, `
		SELECT episode_id, agent_run_id, agent_run_key, source_input_id, channel_id, rowid
		FROM slack_deliveries
		WHERE coalesce_key = ? AND operation IN ('post', 'update')
		  AND state IN ('pending', 'retry', 'sending', 'uncertain', 'sent')
		  AND rowid > COALESCE((
		    SELECT MAX(rowid) FROM slack_deliveries
		    WHERE coalesce_key = ? AND operation = 'delete' AND state = 'sent'
		  ), 0)
		ORDER BY rowid DESC LIMIT 1`, prefix,
		prefix,
	).Scan(&episodeID, &runID, &runKey, &sourceID, &channelID, &blockerRowID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var activeDelete int
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS (
		SELECT 1 FROM slack_deliveries
		WHERE coalesce_key = ? AND operation = 'delete'
		  AND state IN ('pending', 'retry', 'sending')
		  AND rowid > ?
	)`, prefix, blockerRowID).Scan(&activeDelete); err != nil {
		return false, err
	}
	if activeDelete == 1 {
		return false, nil
	}
	var generation int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) + 1 FROM slack_deliveries
		WHERE coalesce_key = ? AND operation = 'delete'`, prefix,
	).Scan(&generation); err != nil {
		return false, err
	}
	id := fmt.Sprintf("%sretire_%03d", prefix, generation)
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO slack_deliveries (
		  id, episode_id, agent_run_id, agent_run_key, source_input_id,
		  operation, kind, channel_id, body_json, steps_json, coalesce_key,
		  state, next_attempt_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, 'delete', 'notice_retirement', ?, '', '[]', ?,
		          'pending', ?, ?, ?)`,
		id, episodeID, runID, runKey, sourceID, channelID, prefix, now, now, now,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows == 0 {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'superseded', last_error = 'preparation recovered before delivery', updated_at = ?
		WHERE coalesce_key = ? AND id != ? AND operation IN ('post', 'update')
		  AND state IN ('pending', 'retry')`, now, prefix, id); err != nil {
		return false, err
	}
	return true, nil
}

// ResolveDelete binds a leased retirement intent to the latest blocker that
// actually reached Slack. No target is a successful no-op: recovery won before
// the blocker became visible.
func (r *Repository) ResolveDelete(ctx context.Context, id string) (DeleteTarget, bool, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return DeleteTarget{}, false, err
	}
	defer tx.Rollback()
	var prefix, fallbackChannel string
	var deleteRowID int64
	if err := tx.QueryRowContext(ctx, `
		SELECT coalesce_key, channel_id, rowid FROM slack_deliveries
		WHERE id = ? AND operation = 'delete' AND state = 'sending'`, id,
	).Scan(&prefix, &fallbackChannel, &deleteRowID); err != nil {
		return DeleteTarget{}, false, err
	}
	var target DeleteTarget
	err = tx.QueryRowContext(ctx, `
		SELECT channel_id, message_ts FROM slack_deliveries
		WHERE coalesce_key = ? AND rowid < ? AND operation IN ('post', 'update')
		  AND state = 'sent' AND message_ts != ''
		ORDER BY rowid DESC LIMIT 1`, prefix, deleteRowID,
	).Scan(&target.ChannelID, &target.MessageTS)
	if errors.Is(err, sql.ErrNoRows) {
		return DeleteTarget{ChannelID: fallbackChannel}, false, tx.Commit()
	}
	if err != nil {
		return DeleteTarget{}, false, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries SET channel_id = ?, message_ts = ?, updated_at = ?
		WHERE id = ? AND state = 'sending'`,
		target.ChannelID, target.MessageTS, r.nowText(), id); err != nil {
		return DeleteTarget{}, false, err
	}
	return target, true, tx.Commit()
}

// CloseDeleteEpoch marks only blockers older than this retirement as history.
// A new blocker admitted while Slack deletes the old one belongs to the next
// epoch and remains deliverable.
func CloseDeleteEpoch(ctx context.Context, tx *sql.Tx, id, now string) error {
	var prefix string
	var deleteRowID int64
	if err := tx.QueryRowContext(ctx, `
		SELECT coalesce_key, rowid FROM slack_deliveries
		WHERE id = ? AND operation = 'delete'`, id,
	).Scan(&prefix, &deleteRowID); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'superseded', last_error = 'preparation notice retired', updated_at = ?
		WHERE coalesce_key = ? AND rowid < ? AND operation IN ('post', 'update')
		  AND state IN ('sent', 'failed')`, now, prefix, deleteRowID)
	return err
}

// NewerRetirement reports whether recovery became durable after a blocker was
// leased. Its retry must not resurrect work the recovery intent retired.
func NewerRetirement(
	ctx context.Context, tx *sql.Tx, coalesceKey string, rowID int64,
) (bool, error) {
	if coalesceKey == "" {
		return false, nil
	}
	var newer bool
	err := tx.QueryRowContext(ctx, `SELECT EXISTS (
		SELECT 1 FROM slack_deliveries
		WHERE coalesce_key = ? AND rowid > ? AND operation = 'delete'
		  AND kind = 'notice_retirement'
		  AND state IN ('pending', 'retry', 'sending', 'sent')
	)`, coalesceKey, rowID).Scan(&newer)
	return newer, err
}

func (r *Repository) nowText() string {
	return r.clock().UTC().Format(core.TimestampFormat)
}
