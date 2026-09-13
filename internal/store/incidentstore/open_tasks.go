package incidentstore

import (
	"context"
	"errors"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

// ListOpenEngineeringTasksForChannel names the engineering work this channel
// has already opened and not yet closed.
//
// It answers a question nothing could ask before: "is the fix for what I am
// looking at already written". On 2026-08-13 an investigation in #blitz-alerts
// produced an approved engineering task that a session completed and committed
// as f804b18c in a fork, and then parked without publishing. Nothing carried
// that fact forward, so when the same alert fired on 2026-08-16 five separate
// investigations proposed writing the change again.
//
// Anchored on the channel by either binding. A room-scoped incident owns
// channel_id; a thread-scoped engineering task — which is what every task
// opened from a conversation is — owns origin_channel_id and only gains
// channel_id once its conversation is bound. Matching one of the two would
// silently miss whichever half of the work happened to be in the other state.
//
// Bounded twice, by age and by count, because this layer costs the prompt
// budget that live evidence needs: a task nobody has touched in a month is
// history the operator can look up, not context worth displacing an alert
// query for.
func (r *Repository) ListOpenEngineeringTasksForChannel(
	ctx context.Context,
	channelID string,
	since time.Time,
	limit int,
) ([]core.Incident, error) {
	if channelID == "" {
		return nil, nil
	}
	if limit < 1 || limit > 50 {
		return nil, errors.New("open engineering tasks require a limit from 1 to 50")
	}
	rows, err := r.db.QueryContext(ctx, `SELECT `+Columns+`
		FROM incidents
		WHERE work_kind = 'engineering_task'
		  AND status != 'closed'
		  AND (channel_id = ? OR origin_channel_id = ?)
		  AND updated_at >= ?
		ORDER BY updated_at DESC, id LIMIT ?`,
		channelID, channelID, since.UTC().Format(core.TimestampFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	tasks := make([]core.Incident, 0, limit)
	for rows.Next() {
		task, err := Scan(rows)
		if err != nil {
			return nil, err
		}
		tasks = append(tasks, task)
	}
	return tasks, rows.Err()
}
