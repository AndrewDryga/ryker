// Package selfreportstore counts the week the weekly digest reports.
//
// Every number the digest states is a row count from this file. Nothing here
// interprets: the queries return what is in the tables and internal/selfreport
// decides how to say it, so a wrong digest is either a wrong query or wrong
// wording and never a plausible sentence with no source.
//
// It is a repository rather than methods on Store for the reason the other
// extractions here exist: a delegating method still counts against the store's
// method budget, so an extraction only reduces the surface if callers reach it
// through the field.
package selfreportstore

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/selfreport"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// sentStateKey records when the digest last went out, in the same key-value
// table the memory-consolidation pass uses to remember its last run.
const sentStateKey = "weekly_self_report_sent_at"

const (
	maxStatements  = 3
	maxLoopRows    = 200
	maxLoopsPerRow = 3
)

type Repository struct {
	db *sql.DB
}

func New(db *sql.DB) *Repository { return &Repository{db: db} }

// LastSent reports when the digest was last posted, or the zero time when it
// never has been.
func (r *Repository) LastSent(ctx context.Context) (time.Time, error) {
	var value string
	err := r.db.QueryRowContext(
		ctx, `SELECT value FROM responder_state WHERE key = ?`, sentStateKey,
	).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, nil
	}
	if err != nil {
		return time.Time{}, err
	}
	return sqlutil.ParseTime(value), nil
}

// MarkSent records that the digest for a window went out.
//
// The recorded value is the scheduled send the digest satisfied, not the wall
// clock it was posted at. A restart inside the window then reads a send that is
// already at or past this week's occurrence and does nothing, which is what
// stops a flapping process posting the same digest repeatedly.
func (r *Repository) MarkSent(ctx context.Context, occurrence time.Time) error {
	value := occurrence.UTC().Format(core.TimestampFormat)
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO responder_state (key, value, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		sentStateKey, value, value,
	)
	return err
}

// Gather counts one week, half-open on [start, end), plus the week before it
// for the comparison.
//
// start and end keep the location they arrive in. The digest names the week an
// operator would recognise, and that is their local week rather than a UTC one
// they have to shift in their head.
func (r *Repository) Gather(
	ctx context.Context,
	start, end time.Time,
) (selfreport.Week, error) {
	week := selfreport.Week{Start: start, End: end}
	var err error
	if week.This, err = r.corrections(ctx, start, end); err != nil {
		return selfreport.Week{}, err
	}
	if week.Previous, err = r.corrections(ctx, start.AddDate(0, 0, -7), start); err != nil {
		return selfreport.Week{}, err
	}
	if week.TopCorrection, week.TopCorrectionCount, err =
		r.topCorrection(ctx, start, end); err != nil {
		return selfreport.Week{}, err
	}
	if week.Feedback, err = r.feedback(ctx, start, end); err != nil {
		return selfreport.Week{}, err
	}
	if week.Knowledge, err = r.knowledge(ctx, start, end); err != nil {
		return selfreport.Week{}, err
	}
	if week.OpenLoops, err = r.openLoops(ctx, start, end); err != nil {
		return selfreport.Week{}, err
	}
	if week.Worst, err = r.worstAnswer(ctx, start, end); err != nil {
		return selfreport.Week{}, err
	}
	return week, nil
}

// corrections counts one window of the same instrument the correction-rate CLI
// reports.
//
// The CLI's Store.CorrectionRate answers a cumulative question from a single
// `since`, which cannot express two adjacent windows, so the bound is repeated
// here rather than the query. Same table, same kind, same definition of a
// finished turn: when the windows line up the two agree by construction.
func (r *Repository) corrections(
	ctx context.Context,
	start, end time.Time,
) (selfreport.Corrections, error) {
	var counts selfreport.Corrections
	if err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM audit_events
		WHERE kind = 'result.correction' AND created_at >= ? AND created_at < ?`,
		sqlutil.TimeText(start), sqlutil.TimeText(end),
	).Scan(&counts.Total); err != nil {
		return selfreport.Corrections{}, err
	}
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM agent_runs
		WHERE terminal_state != '' AND created_at >= ? AND created_at < ?`,
		sqlutil.TimeText(start), sqlutil.TimeText(end),
	).Scan(&counts.Turns)
	return counts, err
}

// topCorrection returns the correction text the host sent back most often.
//
// The text rather than the class: "shape, 22" says a fifth of the week's
// corrections were about how replies read, and "the reply runs 180 words
// against a message of 4 words, 9 times" says what to change.
func (r *Repository) topCorrection(
	ctx context.Context,
	start, end time.Time,
) (string, int, error) {
	var text string
	var count int
	err := r.db.QueryRowContext(ctx, `
		SELECT detail, COUNT(*) AS repeats FROM audit_events
		WHERE kind = 'result.correction' AND detail != ''
		  AND created_at >= ? AND created_at < ?
		GROUP BY detail
		ORDER BY repeats DESC, detail
		LIMIT 1`,
		sqlutil.TimeText(start), sqlutil.TimeText(end),
	).Scan(&text, &count)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, nil
	}
	return text, count, err
}

// feedback tallies what the team said about the answers.
//
// Withdrawn rows are excluded because a removed reaction is a retraction: the
// operator took the judgement back, and counting it would report praise nobody
// is offering.
func (r *Repository) feedback(
	ctx context.Context,
	start, end time.Time,
) (selfreport.Feedback, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT sentiment, source, COUNT(*) FROM feedback_items
		WHERE status != 'withdrawn' AND created_at >= ? AND created_at < ?
		GROUP BY sentiment, source`,
		sqlutil.TimeText(start), sqlutil.TimeText(end),
	)
	if err != nil {
		return selfreport.Feedback{}, err
	}
	defer rows.Close()
	var tally selfreport.Feedback
	for rows.Next() {
		var sentiment, source string
		var count int
		if err := rows.Scan(&sentiment, &source, &count); err != nil {
			return selfreport.Feedback{}, err
		}
		switch sentiment {
		case "positive":
			tally.Positive += count
		case "negative":
			tally.Negative += count
		default:
			continue
		}
		if source == "positive_reaction" || source == "negative_reaction" {
			tally.Reactions += count
		}
	}
	return tally, rows.Err()
}

// knowledge counts the accepted statements structured memory gained.
//
// A knowledge item carries no timestamp of its own, so the window is the
// conversation memory's updated_at: the turn that wrote the item is what moved
// the row. Statements are counted distinctly because the same fact restated in
// two threads is one thing learned.
func (r *Repository) knowledge(
	ctx context.Context,
	start, end time.Time,
) (selfreport.Knowledge, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT statement, MAX(updated_at) AS learned FROM (
		  SELECT json_extract(item.value, '$.statement') AS statement,
		         memory.updated_at AS updated_at
		  FROM conversation_memories AS memory,
		       json_each(memory.state_json, '$.knowledge') AS item
		  WHERE json_valid(memory.state_json)
		    AND memory.updated_at >= ? AND memory.updated_at < ?
		    AND json_extract(item.value, '$.status') = 'accepted'
		)
		WHERE statement IS NOT NULL AND statement != ''
		GROUP BY statement
		ORDER BY learned DESC, statement`,
		sqlutil.TimeText(start), sqlutil.TimeText(end),
	)
	if err != nil {
		return selfreport.Knowledge{}, err
	}
	defer rows.Close()
	var learned selfreport.Knowledge
	for rows.Next() {
		var statement, at string
		if err := rows.Scan(&statement, &at); err != nil {
			return selfreport.Knowledge{}, err
		}
		learned.Count++
		if len(learned.Newest) < maxStatements {
			learned.Newest = append(learned.Newest, statement)
		}
	}
	return learned, rows.Err()
}

// openLoops lists what each channel's memory still calls unfinished, for the
// channels nothing has touched in a week.
//
// Idle is the point. A loop opened yesterday is work in progress; a loop in a
// channel that has been silent for nine days is something the team forgot, and
// the digest exists to say so.
func (r *Repository) openLoops(
	ctx context.Context,
	staleBefore, now time.Time,
) ([]selfreport.ChannelLoops, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT memory.channel_id, memory.updated_at, item.value
		FROM conversation_memories AS memory,
		     json_each(memory.state_json, '$.open_loops') AS item
		WHERE json_valid(memory.state_json) AND memory.updated_at < ?
		ORDER BY memory.updated_at ASC, memory.channel_id, item.key
		LIMIT ?`,
		sqlutil.TimeText(staleBefore), maxLoopRows,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var channels []selfreport.ChannelLoops
	index := map[string]int{}
	for rows.Next() {
		var channelID, at, loop string
		if err := rows.Scan(&channelID, &at, &loop); err != nil {
			return nil, err
		}
		if loop == "" {
			continue
		}
		position, seen := index[channelID]
		if !seen {
			channels = append(channels, selfreport.ChannelLoops{
				ChannelID: channelID,
				IdleDays:  int(now.Sub(sqlutil.ParseTime(at)).Hours() / 24),
			})
			position = len(channels) - 1
			index[channelID] = position
		}
		if len(channels[position].Loops) < maxLoopsPerRow {
			channels[position].Loops = append(channels[position].Loops, loop)
		}
	}
	return channels, rows.Err()
}

// worstAnswer returns the week's most severe confirmed finding that nobody has
// acted on, or nil.
//
// Unactioned means the disposition is still the one the watcher writes on
// recording. Anything else — declined, quarantined, integrated — is a finding
// somebody already decided about, and repeating it in a digest asks the team to
// decide it again.
func (r *Repository) worstAnswer(
	ctx context.Context,
	start, end time.Time,
) (*selfreport.Finding, error) {
	var finding selfreport.Finding
	err := r.db.QueryRowContext(ctx, `
		SELECT id, severity, summary, channel_id FROM quality_findings
		WHERE verdict = 'confirmed' AND disposition IN ('', 'recorded')
		  AND created_at >= ? AND created_at < ?
		ORDER BY CASE severity
		    WHEN 'critical' THEN 4 WHEN 'high' THEN 3
		    WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0
		  END DESC, created_at DESC, id
		LIMIT 1`,
		sqlutil.TimeText(start), sqlutil.TimeText(end),
	).Scan(&finding.ID, &finding.Severity, &finding.Summary, &finding.ChannelID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &finding, nil
}
