package webui

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

// AuditRow is one thing that was done, by whom, and what came of it.
//
// 976 of these are on record and none had a surface. They are the only place
// that keeps an approval, a saved configuration, a remembered preference and a
// rejected model answer in one sequence, which is what an operator needs when
// the question is "who changed this" rather than "what is broken".
type AuditRow struct {
	Kind, Outcome, Actor, Whom string
	Object, Detail             string
	EpisodeID, IncidentID      string
	At                         time.Time
	Repeats                    int
	Span                       string
	Occurrences                []time.Time
}

// AuditGroup counts one kind of action, because 976 rows are not 976 different
// things: 204 are watch replies and 147 are the same class of correction.
type AuditGroup struct {
	Kind     string
	Count    int
	Outcomes string
	Latest   time.Time
}

const auditSelect = `
  SELECT a.kind, a.outcome, a.actor_id, COALESCE(a.object_id,''), COALESCE(a.detail,''),
         COALESCE(byrun.episode_id, bysource.episode_id, ''), COALESCE(a.incident_id,''),
         a.created_at
  FROM audit_events AS a
  LEFT JOIN agent_runs AS byrun ON byrun.id = a.object_id
  LEFT JOIN agent_runs AS bysource ON bysource.source_id = a.object_id`

func (r *Reader) scanAudit(ctx context.Context, query string, args ...any) ([]AuditRow, error) {
	items, err := collect(ctx, r, query, func(rows *sql.Rows) (AuditRow, error) {
		var item AuditRow
		var at string
		err := rows.Scan(&item.Kind, &item.Outcome, &item.Actor, &item.Object,
			&item.Detail, &item.EpisodeID, &item.IncidentID, &at)
		item.At, item.Whom = parseStamp(at), whom(item.Actor)
		item.Occurrences = []time.Time{item.At}
		item.Detail = r.resolveChannels(ctx, item.Detail)
		return item, err
	}, args...)
	return foldAudit(items), err
}

// foldAudit collapses a run of identical actions into one row with a count.
//
// A slash command that failed on a dead channel eleven times in twenty minutes
// took eleven of the forty rows on the audit page and pushed everything else
// that happened that hour off it. Eleven identical failures are one fact, and
// the same folding the episode timeline already does applies here for the same
// reason. Only consecutive rows fold, so nothing that happened in between is
// hidden.
func foldAudit(rows []AuditRow) []AuditRow {
	folded := make([]AuditRow, 0, len(rows))
	for _, row := range rows {
		last := len(folded) - 1
		if last >= 0 && folded[last].Kind == row.Kind && folded[last].Outcome == row.Outcome &&
			folded[last].Actor == row.Actor && folded[last].Detail == row.Detail {
			folded[last].Repeats++
			folded[last].Occurrences = append(folded[last].Occurrences, row.Occurrences...)
			// Absolute, because these lists are read newest-first on the audit
			// pages and oldest-first on an episode, and a span is a duration
			// either way.
			if span := row.At.Sub(folded[last].At).Abs(); span >= time.Second {
				folded[last].Span = span.Round(time.Second).String()
			}
			continue
		}
		folded = append(folded, row)
	}
	return folded
}

// whom says what kind of thing acted, because there is no directory to turn
// "U089UCBNT38" into a name and inventing one would be worse than the id. The
// distinction that matters when reading the log back is person versus app
// versus the host acting on its own, and the id alone does not carry it.
func whom(actor string) string {
	switch {
	case actor == "":
		return "unattributed"
	case actor == "responder":
		return "ryker"
	case actor == dashboardActor:
		return "this dashboard"
	case strings.HasPrefix(actor, "U"):
		return "person"
	case strings.HasPrefix(actor, "B"):
		return "app"
	default:
		return "host"
	}
}

func (r *Reader) AuditKinds(ctx context.Context) ([]AuditGroup, error) {
	return collect(ctx, r, `
	  SELECT kind, COUNT(*), GROUP_CONCAT(DISTINCT outcome), MAX(created_at)
	  FROM audit_events GROUP BY kind ORDER BY COUNT(*) DESC LIMIT 60`,
		func(rows *sql.Rows) (AuditGroup, error) {
			var item AuditGroup
			var outcomes sql.NullString
			var latest string
			err := rows.Scan(&item.Kind, &item.Count, &outcomes, &latest)
			item.Latest = parseStamp(latest)
			item.Outcomes = strings.ReplaceAll(outcomes.String, ",", ", ")
			return item, err
		})
}

func (r *Reader) AuditRecent(ctx context.Context, limit int) ([]AuditRow, error) {
	return r.scanAudit(ctx, auditSelect+` ORDER BY a.created_at DESC LIMIT ?`, limit)
}

func (r *Reader) AuditOfKind(ctx context.Context, kind string) ([]AuditRow, error) {
	return r.scanAudit(ctx,
		auditSelect+` WHERE a.kind = ? ORDER BY a.created_at DESC LIMIT 200`, kind)
}

// AuditFilter narrows one kind's events to an actor and a window, with an
// offset. It exists because slack.watch holds hundreds of rows and a page
// that shows the newest two hundred of them answers "what happened last
// week" with silence.
type AuditFilter struct {
	Kind, Actor string
	Since       time.Time
	SinceKey    string
	Offset      int
}

func (f AuditFilter) Active() bool { return f.Actor != "" || !f.Since.IsZero() }

// where builds the predicate the list and its count share, so "N match" can
// never disagree with the rows below it.
func (f AuditFilter) where() (string, []any) {
	clauses, args := []string{"a.kind = ?"}, []any{f.Kind}
	if f.Actor != "" {
		clauses = append(clauses, "a.actor_id = ?")
		args = append(args, f.Actor)
	}
	if !f.Since.IsZero() {
		// core.TimestampFormat, not RFC3339Nano: stored stamps are TEXT and
		// SQLite compares them as text, and RFC3339Nano's trailing-zero
		// stripping makes its Z sort after every digit — a threshold written
		// that way excludes rows that happen to carry a fraction.
		clauses = append(clauses, "a.created_at >= ?")
		args = append(args, f.Since.UTC().Format(core.TimestampFormat))
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

// auditPageSize is raw rows per page, before identical neighbours fold.
const auditPageSize = 100

func (r *Reader) AuditOfKindFiltered(ctx context.Context, filter AuditFilter) ([]AuditRow, error) {
	where, args := filter.where()
	return r.scanAudit(ctx, auditSelect+where+
		` ORDER BY a.created_at DESC LIMIT ? OFFSET ?`,
		append(args, auditPageSize, filter.Offset)...)
}

// CountAuditOfKind reports its failure, for the same reason CountMatching
// does: a zero from a broken query would read as "nothing matched".
func (r *Reader) CountAuditOfKind(ctx context.Context, filter AuditFilter) (int, error) {
	if !r.live() {
		return 0, nil
	}
	where, args := filter.where()
	var count int
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM audit_events AS a`+where, args...).Scan(&count)
	return count, err
}

// AuditForEpisode is the link the other way: from work back to the record of
// what was decided about it. An audit page nobody can enter from an episode is
// a log, not a trail.
func (r *Reader) AuditForEpisode(ctx context.Context, episodeID string) ([]AuditRow, error) {
	return r.scanAudit(ctx, auditSelect+`
	  WHERE a.object_id IN (`+episodeSources+`)
	  ORDER BY a.created_at`, episodeID, episodeID)
}

func (r *Reader) AuditForIncident(ctx context.Context, incidentID string) ([]AuditRow, error) {
	return r.scanAudit(ctx,
		auditSelect+` WHERE a.incident_id = ? ORDER BY a.created_at LIMIT 60`, incidentID)
}

// KnownAuditKind guards the drill-down. Rendering an empty page for a kind
// nobody ever recorded reads as "this never happens" when the truth is that
// the URL was wrong.
func (r *Reader) KnownAuditKind(ctx context.Context, kind string) bool {
	return r.Count(ctx, countAuditKind, kind) > 0
}
