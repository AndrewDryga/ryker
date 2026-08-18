// Package deliveryretrystore owns Slack outbox retry transitions. They are one
// transaction because a newer coalesced intent can make a failed write obsolete
// while that write is in flight.
package deliveryretrystore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/preparationstore"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

type UncertainDisposition string

const (
	UncertainAgain        UncertainDisposition = "uncertain"
	UncertainRetry        UncertainDisposition = "retry"
	UncertainTerminal     UncertainDisposition = "terminal"
	ConfirmedAbsentRetry  UncertainDisposition = "absent_retry"
	ConfirmedAbsentFailed UncertainDisposition = "absent_failed"
)

func ConfirmedAbsent(terminal bool) UncertainDisposition {
	if terminal {
		return ConfirmedAbsentFailed
	}
	return ConfirmedAbsentRetry
}

func Retry(
	ctx context.Context,
	db *sql.DB,
	now string,
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
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var operation, kind, coalesceKey, created string
	var rowID int64
	if err := tx.QueryRowContext(ctx, `
		SELECT operation, kind, coalesce_key, created_at, rowid
		FROM slack_deliveries WHERE id = ? AND state = 'sending'`, id,
	).Scan(&operation, &kind, &coalesceKey, &created, &rowID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("retry Slack delivery: %w", core.ErrConflict)
		}
		return err
	}
	if operation == "reaction" && coalesceKey != "" {
		var newer bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS (
			SELECT 1 FROM slack_deliveries
			WHERE coalesce_key = ? AND operation = 'reaction' AND id != ?
			  AND (created_at > ? OR (created_at = ? AND rowid > ?))
		)`, coalesceKey, id, created, created, rowID).Scan(&newer); err != nil {
			return err
		}
		if newer {
			state, detail = "superseded", "newer reaction intent"
		}
	}
	if operation != "delete" && kind == "notice" && !uncertain {
		newer, err := preparationstore.NewerRetirement(ctx, tx, coalesceKey, rowID)
		if err != nil {
			return err
		}
		if newer {
			state, detail = "superseded", "preparation recovered while delivery was in flight"
		}
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = ?, failure_count = failure_count + 1,
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'sending'`,
		state, sqlutil.BoundedError(detail), next.UTC().Format(core.TimestampFormat),
		now, id)
	if err := sqlutil.ExpectOne(result, err, "retry Slack delivery"); err != nil {
		return err
	}
	return tx.Commit()
}

func SupersedeLeased(
	ctx context.Context, db *sql.DB, now, id, detail string,
) error {
	result, err := db.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'superseded', last_error = ?, updated_at = ?
		WHERE id = ? AND state = 'sending'`, sqlutil.BoundedError(detail), now, id)
	return sqlutil.ExpectOne(result, err, "supersede leased Slack delivery")
}

func RetryUncertain(
	ctx context.Context,
	db *sql.DB,
	now string,
	id string,
	detail string,
	next time.Time,
	disposition UncertainDisposition,
) error {
	state := "uncertain"
	confirmedAbsent := false
	switch disposition {
	case UncertainRetry:
		state = "retry"
	case UncertainTerminal:
		state = "failed"
	case ConfirmedAbsentRetry:
		state, confirmedAbsent = "retry", true
	case ConfirmedAbsentFailed:
		state, confirmedAbsent = "failed", true
	case UncertainAgain:
	default:
		return fmt.Errorf("unsupported uncertain Slack disposition %q", disposition)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var kind, coalesceKey string
	var rowID int64
	if err := tx.QueryRowContext(ctx, `
		SELECT kind, coalesce_key, rowid FROM slack_deliveries
		WHERE id = ? AND state = 'uncertain'`, id,
	).Scan(&kind, &coalesceKey, &rowID); err != nil {
		return err
	}
	if kind == "notice" && confirmedAbsent {
		newer, newerErr := preparationstore.NewerRetirement(ctx, tx, coalesceKey, rowID)
		if newerErr != nil {
			return newerErr
		}
		if newer {
			state, detail = "superseded", "preparation recovered while delivery was uncertain"
		}
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = ?, failure_count = failure_count + 1,
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'uncertain'`,
		state, sqlutil.BoundedError(detail), next.UTC().Format(core.TimestampFormat),
		now, id)
	if err := sqlutil.ExpectOne(result, err, "retry uncertain Slack delivery"); err != nil {
		return err
	}
	return tx.Commit()
}
