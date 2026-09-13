// Package activitystore owns what the model did inside a turn, as Coop
// narrated it.
//
// Ryker's trace could always say a turn ran and what it concluded. It
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
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store/sqlutil"
)

const (
	maxTitleBytes  = 300
	maxDetailBytes = 8 << 10
	maxListRows    = 500
	// The card keeps three lines. Reading more than a handful would be paying
	// for rows the renderer is about to drop.
	maxTailRows = 8
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
	occurredText := occurredAt.UTC().Format(core.TimestampFormat)
	// The row and the episode's freshness stamp move together. They are two
	// statements answering one question — "has this turn done anything lately"
	// — and a crash between them would leave the overdue watchdog reading a
	// stamp that the stored narration contradicts.
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
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
		occurredText,
		r.now().UTC().Format(core.TimestampFormat),
	)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	// Never backwards. Polling is at-least-once and the cursor rewinds to
	// zero, so a moment from the start of the turn can arrive after one from
	// its end; letting the older stamp win would make a working turn look
	// stalled to the watchdog that reads this column. String comparison is
	// chronological because every stamp is written in one fixed-width UTC
	// format.
	if _, err := tx.ExecContext(ctx, `
		UPDATE work_episodes SET last_activity_at = ?
		WHERE id = ? AND (last_activity_at IS NULL OR last_activity_at < ?)`,
		occurredText, activity.EpisodeID, occurredText,
	); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return affected > 0, nil
}

// tailQuery answers everything the running card asks of a turn's interior in
// one read: the newest displayable moments, how many tool calls the turn has
// made, how many moments of any kind it recorded, and when the last of them
// happened. %[1]s selects the episode — directly, or through the work the
// operator is actually looking at.
//
// Displayable is tool.started and model.thought and nothing else. A completion
// repeats the line its start already put on the card, and a plan revision, a
// permission decision and an elision notice are all about the run rather than
// about the work. They still count toward freshness — a turn that spent four
// minutes waiting on a permission was not idle — so the kind filter narrows
// what is shown and never what is counted.
//
// The counts come from a separate branch of the same statement rather than
// from the returned lines, because the lines are a window of three and the
// counters are the whole turn: 119 calls behind a strip showing the last two
// is the fact the card exists to state.
//
// LEFT JOIN so the totals survive a turn that has recorded only
// non-displayable moments. "Thinking, nothing to show yet" is a different card
// from "nothing has happened", and an inner join renders them alike.
//
// Newest first is by occurrence, not by run.
//
// ListForEpisode orders by `agent_run_id, sequence` because it is building a
// whole narrative and the sequence is the only total order Coop guarantees
// inside a run. Reversing that here would have been wrong: a run id is
// thirty-two characters of crypto/rand with no time in it, so `agent_run_id
// DESC` names the newest attempt only by luck. On the deployed blitz database
// eight episodes carry narration from more than one run and for four of them
// it names the older one — a retried task would have shown the operator the
// attempt that gave up while the retry was working.
//
// occurred_at is what the question actually asks: the last things that
// happened. Sequence breaks ties, which is right inside a run and is the only
// place ties occur — a retry starts after the attempt it replaces ended, and
// Coop stamps these on the same host that reads them. Joining agent_runs to
// order by the run's own created_at would express the grouping more directly
// and would cost a join that retention can outlive: nothing deletes activity
// when a run row is pruned, and an inner join would silently drop exactly the
// oldest windows.
const tailQuery = `
	WITH totals AS (
	  SELECT COUNT(*) AS recorded,
	         SUM(CASE WHEN kind = 'tool.started' THEN 1 ELSE 0 END) AS tool_calls,
	         MAX(occurred_at) AS last_activity
	  FROM agent_activity WHERE episode_id = %[1]s
	), recent AS (
	  SELECT kind, title, tool_kind, status, detail, occurred_at, sequence,
	         episode_id, tool_call_id,
	         ROW_NUMBER() OVER (ORDER BY occurred_at DESC, sequence DESC) AS position
	  FROM agent_activity
	  WHERE episode_id = %[1]s AND kind IN ('tool.started', 'model.thought')
	)
	SELECT totals.recorded, COALESCE(totals.tool_calls, 0),
	       COALESCE(totals.last_activity, ''),
	       COALESCE(recent.kind, ''), COALESCE(recent.title, ''),
	       COALESCE(recent.tool_kind, ''), COALESCE(recent.status, ''),
	       COALESCE(recent.detail, CAST('' AS BLOB)),
	       COALESCE(recent.occurred_at, ''), COALESCE(recent.sequence, 0),
	       COALESCE((
	         SELECT settled.title FROM agent_activity settled
	         WHERE settled.episode_id = recent.episode_id
	           AND settled.tool_call_id = recent.tool_call_id
	           AND recent.tool_call_id <> ''
	           AND settled.sequence > recent.sequence
	           AND settled.title <> ''
	           AND settled.title <> recent.title
	         ORDER BY settled.sequence LIMIT 1
	       ), '')
	FROM totals LEFT JOIN recent ON recent.position <= ?
	ORDER BY recent.position`

// latestEpisodeOfIncident is the episode selector for a card. An incident that
// was retried holds several episodes; the card is a window onto the one that
// is running, or onto the one that just stopped.
const latestEpisodeOfIncident = `(
	  SELECT episode_id FROM agent_runs
	  WHERE incident_id = %[1]s AND episode_id != ''
	  ORDER BY created_at DESC, id DESC LIMIT 1
	)`

// TailForEpisode reads a turn's interior for a known episode.
func (r *Repository) TailForEpisode(
	ctx context.Context,
	episodeID string,
	limit int,
) (core.AgentActivityTail, error) {
	return r.tail(ctx, fmt.Sprintf(tailQuery, "?"), episodeID, limit)
}

// TailForIncident reads the interior of the newest turn behind a card.
//
// Addressed by incident rather than by episode because that is what the card
// worker holds, and resolving the episode first would be a second round trip
// on a card that rewrites itself every fifteen seconds. The subquery does it
// inside the same statement.
func (r *Repository) TailForIncident(
	ctx context.Context,
	incidentID string,
	limit int,
) (core.AgentActivityTail, error) {
	selector := fmt.Sprintf(latestEpisodeOfIncident, "?")
	return r.tail(ctx, fmt.Sprintf(tailQuery, selector), incidentID, limit)
}

// TailForWork keeps cumulative task totals across feedback/review episodes.
// Operational incident cards deliberately use TailForIncident and retain their
// newest-episode window; an engineering task is a single delivery record whose
// tool count must not reset every time a teammate replies.
func (r *Repository) TailForWork(
	ctx context.Context,
	incidentID string,
	limit int,
) (core.AgentActivityTail, error) {
	selector := `(SELECT DISTINCT episode_id FROM agent_runs
		WHERE incident_id = ? AND episode_id != '')`
	query := strings.ReplaceAll(
		tailQuery,
		"episode_id = %[1]s",
		"episode_id IN %[1]s",
	)
	return r.tail(ctx, fmt.Sprintf(query, selector), incidentID, limit)
}

// CountsForTurn totals what one turn did.
//
// The tails above answer a card's question and span the whole episode on
// purpose. A receipt asks about one turn, and the rows carry the turn id Coop
// stamped on them, so the answer is a count rather than an episode total worn
// as one — an episode's hundred tool calls quoted under a turn that made three
// is not a rounding error, it is a different fact.
//
// The scan is bounded by the episode as well as the turn because that is the
// index the table has; a turn id alone would be a full scan of every episode's
// narration to find rows one episode already isolates.
func (r *Repository) CountsForTurn(
	ctx context.Context,
	episodeID string,
	turnID string,
) (core.AgentTurnActivity, error) {
	var counts core.AgentTurnActivity
	if strings.TrimSpace(episodeID) == "" || strings.TrimSpace(turnID) == "" {
		return counts, nil
	}
	var first, last string
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(*),
		       COALESCE(SUM(CASE WHEN kind = 'tool.started' THEN 1 ELSE 0 END), 0),
		       COALESCE(SUM(CASE WHEN kind = 'tool.started'
		                          AND LOWER(TRIM(tool_kind)) IN (`+editToolKindList+`)
		                         THEN 1 ELSE 0 END), 0),
		       COALESCE(MIN(occurred_at), ''), COALESCE(MAX(occurred_at), '')
		FROM agent_activity
		WHERE episode_id = ? AND turn_id = ?`, episodeID, turnID,
	).Scan(&counts.Moments, &counts.ToolCalls, &counts.Files, &first, &last)
	if err != nil {
		return core.AgentTurnActivity{}, err
	}
	counts.First = sqlutil.ParseTime(first)
	counts.Last = sqlutil.ParseTime(last)
	return counts, nil
}

// editToolKindList is core.EditToolKinds as a SQL literal list, built from the
// slice rather than typed out again so the ledger and the live card cannot come
// to disagree about which tool kinds changed a file.
var editToolKindList = editToolKindLiterals()

func editToolKindLiterals() string {
	quoted := make([]string, 0, len(core.EditToolKinds))
	for _, kind := range core.EditToolKinds {
		// The vocabulary is a package-level constant list, not input; quoting
		// it is belt and braces against a future entry with an apostrophe in
		// it becoming a syntax error at runtime instead of here.
		quoted = append(quoted, "'"+strings.ReplaceAll(kind, "'", "''")+"'")
	}
	return strings.Join(quoted, ", ")
}

func (r *Repository) tail(
	ctx context.Context,
	query string,
	subject string,
	limit int,
) (core.AgentActivityTail, error) {
	var tail core.AgentActivityTail
	if strings.TrimSpace(subject) == "" {
		return tail, nil
	}
	if limit < 1 || limit > maxTailRows {
		limit = maxTailRows
	}
	rows, err := r.db.QueryContext(ctx, query, subject, subject, limit)
	if err != nil {
		return tail, err
	}
	defer rows.Close()
	for rows.Next() {
		var line core.AgentActivity
		var detail []byte
		var lastActivity, occurredAt string
		if err := rows.Scan(
			&tail.Recorded, &tail.ToolCalls, &lastActivity,
			&line.Kind, &line.Title, &line.ToolKind, &line.Status, &detail,
			&occurredAt, &line.Sequence, &line.SettledTitle,
		); err != nil {
			return core.AgentActivityTail{}, err
		}
		tail.LastActivity = sqlutil.ParseTime(lastActivity)
		if line.Kind == "" {
			continue
		}
		if len(detail) > 0 {
			line.Detail = detail
		}
		line.OccurredAt = sqlutil.ParseTime(occurredAt)
		tail.Lines = append(tail.Lines, line)
	}
	return tail, rows.Err()
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
