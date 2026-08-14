package taskcardstore

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// Repository owns the durable Slack card used to present a unit of work, and
// the version number that tells the card worker the card is out of date.
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

// BumpActiveTurn marks the pinned card stale because the running turn narrated
// something new, and reports whether it did.
//
// Every other bump in this package names a state change. This one names the
// absence of one: the facts on the card moved — another tool call, another
// minute since the last — while nothing in the incident row did.
//
// The guards are the whole method. A turn that has ended has no window to
// refresh and its ledger has already absorbed the totals, so active_turn_id is
// checked in the statement rather than by the caller: read-then-write across a
// turn that finishes in between would pin a live window to a card with nothing
// running behind it. The other two conditions are the ones ListDirtyCards
// applies, so this can never dirty a card the worker would then refuse to
// render.
func (r *Repository) BumpActiveTurn(ctx context.Context, id string) (bool, error) {
	result, err := r.db.ExecContext(ctx, `
		UPDATE incidents SET card_version = card_version + 1, updated_at = ?
		WHERE id = ? AND active_turn_id != '' AND root_ts != ''
		  AND channel_state = 'active'`,
		r.nowText(), id,
	)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected > 0, err
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
