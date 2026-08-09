package webui

import (
	"context"
	"database/sql"
	"time"
)

// Room is an incident: the container a whole conversation of work happens in,
// as opposed to an episode, which is one turn of it. Four exist and none was
// reachable, so the three pull requests Responder has opened were visible only
// in GitHub.
type Room struct {
	ID, Title, Status, Workflow string
	Repository, Channel, Kind   string
	Signals, Episodes           int
	PRNumber                    int
	PRState, Checks             string
	Created, Updated            time.Time
}

func (r *Reader) Rooms(ctx context.Context) ([]Room, error) {
	return collect(ctx, r, `
	  SELECT i.id, i.title, i.status, i.workflow, i.repository, i.channel_id, i.work_kind,
	         i.signal_count, COALESCE(p.pr_number,0), COALESCE(f.pr_state,''),
	         COALESCE(f.checks_state,''), i.created_at, i.updated_at,
	         (SELECT COUNT(DISTINCT episode_id) FROM agent_runs WHERE incident_id = i.id)
	  FROM incidents AS i
	  LEFT JOIN publications AS p ON p.incident_id = i.id
	  LEFT JOIN publication_followups AS f ON f.incident_id = i.id
	  ORDER BY i.updated_at DESC LIMIT 50`,
		func(rows *sql.Rows) (Room, error) {
			var item Room
			var channel, created, updated string
			err := rows.Scan(&item.ID, &item.Title, &item.Status, &item.Workflow,
				&item.Repository, &channel, &item.Kind, &item.Signals, &item.PRNumber,
				&item.PRState, &item.Checks, &created, &updated, &item.Episodes)
			item.Channel = r.channelName(ctx, channel)
			item.Created, item.Updated = parseStamp(created), parseStamp(updated)
			return item, err
		})
}

func (r *Reader) Room(ctx context.Context, id string) (Room, error) {
	rooms, err := r.Rooms(ctx)
	if err != nil {
		return Room{}, err
	}
	for _, room := range rooms {
		if room.ID == id {
			return room, nil
		}
	}
	return Room{}, nil
}

// Signal is what opened a room: the alert or the request, in the words it
// arrived in. The room's title is a summary of this; the ask itself is often
// several paragraphs of constraints that the summary drops.
type Signal struct {
	Route, Title, Summary, Status string
	Severity, URL                 string
	Received                      time.Time
}

func (r *Reader) Signals(ctx context.Context, incidentID string) ([]Signal, error) {
	return collect(ctx, r, `
	  SELECT route, title, COALESCE(summary,''), status, COALESCE(severity,''),
	         COALESCE(source_url,''), received_at
	  FROM signals WHERE incident_id = ? ORDER BY received_at LIMIT 40`,
		func(rows *sql.Rows) (Signal, error) {
			var item Signal
			var received string
			err := rows.Scan(&item.Route, &item.Title, &item.Summary, &item.Status,
				&item.Severity, &item.URL, &received)
			item.Received = parseStamp(received)
			return item, err
		}, incidentID)
}

// Moment is one entry of the narrative the room showed people in Slack, which
// is a different record from the episode event stream: it is what was said,
// not what the machine did.
type Moment struct {
	Kind, Actor, Whom, Title, Detail string
	At                               time.Time
}

func (r *Reader) Moments(ctx context.Context, incidentID string) ([]Moment, error) {
	return collect(ctx, r, `
	  SELECT kind, COALESCE(actor_id,''), title, COALESCE(detail,''), created_at
	  FROM timeline_events WHERE incident_id = ? ORDER BY created_at LIMIT 100`,
		func(rows *sql.Rows) (Moment, error) {
			var item Moment
			var at string
			err := rows.Scan(&item.Kind, &item.Actor, &item.Title, &item.Detail, &at)
			item.At, item.Whom = parseStamp(at), whom(item.Actor)
			item.Detail = r.resolveChannels(ctx, item.Detail)
			return item, err
		}, incidentID)
}

// Publication is the change that left the machine: branch, commit, pull
// request, and whether it merged and applied. Its lifecycle events are the
// only record of a PR whose checks failed before they passed.
type Publication struct {
	Repository, Base, Head string
	Commit, State, Error   string
	PRNumber               int
	URL                    string
	PRState, Checks        string
	MergeSHA               string
	Published, Merged      time.Time
	Events                 []Moment
}

func (r *Reader) Publication(ctx context.Context, incidentID string) (Publication, error) {
	var item Publication
	if !r.live() {
		return item, nil
	}
	var published, merged string
	err := r.db.QueryRowContext(ctx, `
	  SELECT p.repository, p.base_branch, p.head_branch, COALESCE(p.commit_sha,''),
	         p.state, COALESCE(p.last_error,''), p.pr_number, COALESCE(p.pr_url,''),
	         COALESCE(f.pr_state,''), COALESCE(f.checks_state,''), COALESCE(f.merge_sha,''),
	         COALESCE(p.published_at,''), COALESCE(f.merged_at,'')
	  FROM publications AS p
	  LEFT JOIN publication_followups AS f ON f.incident_id = p.incident_id
	  WHERE p.incident_id = ?`, incidentID).
		Scan(&item.Repository, &item.Base, &item.Head, &item.Commit, &item.State,
			&item.Error, &item.PRNumber, &item.URL, &item.PRState, &item.Checks,
			&item.MergeSHA, &published, &merged)
	if err != nil {
		// Most rooms never publish anything, so a missing row is the ordinary
		// case and not a fault worth reporting on the page.
		return Publication{}, nil
	}
	item.Commit, item.MergeSHA = truncate(item.Commit, 8), truncate(item.MergeSHA, 8)
	item.Published, item.Merged = parseStamp(published), parseStamp(merged)
	item.Events, err = collect(ctx, r, `
	  SELECT kind, state, summary, created_at
	  FROM publication_lifecycle_events WHERE incident_id = ?
	  ORDER BY created_at LIMIT 60`,
		func(rows *sql.Rows) (Moment, error) {
			var event Moment
			var at string
			err := rows.Scan(&event.Kind, &event.Title, &event.Detail, &at)
			event.At = parseStamp(at)
			return event, err
		}, incidentID)
	return item, err
}

func (r *Reader) EpisodesForIncident(ctx context.Context, incidentID string) ([]Item, error) {
	return r.scanItems(ctx, episodeSelect+`
	  WHERE r.incident_id = ? ORDER BY e.created_at DESC LIMIT 40`, incidentID)
}

// Lane separates the scheduler's permanent poll loops from actual work.
//
// A recurring drain record normally spends almost all of its life pending for
// its next poll. Counting that as queued work made an idle, healthy Responder
// look as though dozens of tasks were stuck. Pollers remain visible as liveness
// evidence, while the work columns contain only finite items.
type Lane struct {
	Name, Status                               string
	Pollers, Ready, Running, Scheduled, Failed int
	Retrying, RetryAttempts                    int
	Error                                      string
	Next                                       time.Time
	HasNext                                    bool
}

func (r *Reader) Lanes(ctx context.Context) ([]Lane, error) {
	return collect(ctx, r, `
	  SELECT lane,
	         SUM(subject_id = 'drain' OR subject_id GLOB 'drain-[0-9]*'),
	         SUM(NOT (subject_id = 'drain' OR subject_id GLOB 'drain-[0-9]*') AND state = 'pending'
	             AND julianday(available_at) <= julianday('now')),
	         SUM(NOT (subject_id = 'drain' OR subject_id GLOB 'drain-[0-9]*') AND state = 'running'),
	         SUM(NOT (subject_id = 'drain' OR subject_id GLOB 'drain-[0-9]*') AND state = 'pending'
	             AND julianday(available_at) > julianday('now')),
	         SUM(NOT (subject_id = 'drain' OR subject_id GLOB 'drain-[0-9]*') AND state = 'failed'),
	         SUM(failure_count > 0), SUM(failure_count),
	         COALESCE(MAX(NULLIF(last_error,'')),''),
	         MIN(CASE WHEN NOT (subject_id = 'drain' OR subject_id GLOB 'drain-[0-9]*') AND state = 'pending'
	             THEN available_at END)
	  FROM work_items GROUP BY lane ORDER BY lane`,
		func(rows *sql.Rows) (Lane, error) {
			var item Lane
			var next sql.NullString
			err := rows.Scan(
				&item.Name, &item.Pollers, &item.Ready, &item.Running,
				&item.Scheduled, &item.Failed, &item.Retrying,
				&item.RetryAttempts, &item.Error, &next,
			)
			if next.Valid {
				item.Next = parseStamp(next.String)
				item.HasNext = !item.Next.IsZero()
			}
			switch {
			case item.Failed > 0:
				item.Status = "failed"
			case item.Retrying > 0:
				item.Status = "retrying"
			case item.Ready > 0 || item.Running > 0:
				item.Status = "working"
			default:
				item.Status = "healthy"
			}
			return item, err
		})
}
