// Package activitystore owns what the model did inside a turn, as Coop
// narrated it.
//
// Responder's trace could always say a turn ran and what it concluded. It
// could not say anything about the minutes in between: the Emisar operations
// an episode cited were visible only because the model happened to quote their
// IDs in its evidence, and everything it read, searched, or tried and abandoned
// left no mark at all.
//
// Rows are keyed by the Coop event sequence rather than by arrival. Polling is
// at-least-once and the cursor is rewound to zero whenever it outruns the
// session, so the same narration is delivered more than once by design; the
// unique key is what makes a replay idempotent instead of a duplicate story.
package activitystore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const (
	maxTitleBytes  = 300
	maxDetailBytes = 8 << 10
	maxListRows    = 500
)

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

func (r *Repository) now() time.Time {
	if r.clock != nil {
		return r.clock()
	}
	return time.Now()
}

// Record stores one narrated moment. It is idempotent on the run's event
// sequence, and reports whether the row was new.
func (r *Repository) Record(ctx context.Context, activity core.AgentActivity) (bool, error) {
	if strings.TrimSpace(activity.EpisodeID) == "" ||
		strings.TrimSpace(activity.AgentRunID) == "" ||
		strings.TrimSpace(activity.Kind) == "" {
		return false, errors.New("agent activity requires an episode, a run, and a kind")
	}
	if activity.Sequence <= 0 {
		return false, errors.New("agent activity requires the Coop event sequence")
	}
	id, err := core.NewID("activity")
	if err != nil {
		return false, err
	}
	// Detail is bounded JSON or nothing. Anything else must not reach a page
	// that will try to parse it.
	detail := activity.Detail
	if len(detail) > maxDetailBytes || !json.Valid(detail) {
		detail = nil
	}
	occurredAt := activity.OccurredAt
	if occurredAt.IsZero() {
		occurredAt = r.now()
	}
	result, err := r.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO agent_activity (
		  id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
		  tool_call_id, title, tool_kind, status, detail, occurred_at, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, activity.EpisodeID, activity.AgentRunID, activity.SessionID,
		activity.TurnID, activity.Sequence, activity.Kind, activity.ToolCallID,
		core.TruncateUTF8WithSuffix(activity.Title, maxTitleBytes, "…"),
		core.TruncateUTF8(activity.ToolKind, 64),
		core.TruncateUTF8(activity.Status, 64),
		detail,
		occurredAt.UTC().Format(core.TimestampFormat),
		r.now().UTC().Format(core.TimestampFormat),
	)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected > 0, err
}

// ListForEpisode returns an episode's narration in the order Coop produced it.
// Ordering is by run and sequence rather than by timestamp: several events
// share a millisecond, and the sequence is the only total order Coop actually
// guarantees.
func (r *Repository) ListForEpisode(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]core.AgentActivity, error) {
	if strings.TrimSpace(episodeID) == "" {
		return nil, nil
	}
	if limit < 1 || limit > maxListRows {
		limit = maxListRows
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
		       tool_call_id, title, tool_kind, status,
		       COALESCE(detail, CAST('' AS BLOB)), occurred_at
		FROM agent_activity
		WHERE episode_id = ?
		ORDER BY agent_run_id, sequence
		LIMIT ?`, episodeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []core.AgentActivity{}
	for rows.Next() {
		var item core.AgentActivity
		var detail []byte
		var occurredAt string
		if err := rows.Scan(
			&item.ID, &item.EpisodeID, &item.AgentRunID, &item.SessionID,
			&item.TurnID, &item.Sequence, &item.Kind, &item.ToolCallID,
			&item.Title, &item.ToolKind, &item.Status, &detail, &occurredAt,
		); err != nil {
			return nil, err
		}
		if len(detail) > 0 {
			item.Detail = detail
		}
		item.OccurredAt = sqlutil.ParseTime(occurredAt)
		items = append(items, item)
	}
	return items, rows.Err()
}
