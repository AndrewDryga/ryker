package webui

import (
	"context"
	"database/sql"
	"strings"
	"time"
)

// RetainedWorkspace is one Coop session whose fork is still on disk.
//
// Thirty of these sat in coop_cleanup on a production database with no surface
// at all: the App Home shows the count, the count cannot be opened, and the
// only way to learn why a workspace was held — dirty tree, unpublished
// commits, a Coop conflict — was sqlite. The blocked ones are the operator's
// queue: the janitor has already refused them for a stated reason and will
// never look again without a person acting.
type RetainedWorkspace struct {
	SessionID, IncidentID, Reason, State string
	// Refusal is the janitor's own last error, verbatim. It is the answer to
	// "what is held and why", so it is never summarized into a category.
	Refusal                                 string
	IncidentTitle, IncidentStatus, WorkKind string
	Channel                                 string
	Attempts                                int
	AllowUnmerged                           bool
	Created, Eligible, NextAttempt          time.Time
}

// CanDiscard mirrors the gate on the Slack "Discard retained work" button:
// only a closed engineering task, so no agent turn can race the deletion.
// Offering it wider here would make this page the one door without the rule.
func (w RetainedWorkspace) CanDiscard() bool {
	return w.IncidentStatus == "closed" && w.WorkKind == "engineering_task"
}

// CanReclaim offers the record-less discard: a fork with no work record behind
// it, which the incident-shaped controls cannot reach at all. Dirty trees are
// excluded here as everywhere — the service refuses them too, and a page must
// not offer what the service will refuse.
func (w RetainedWorkspace) CanReclaim() bool {
	return w.IncidentID == "" &&
		!strings.HasPrefix(w.Refusal, "workspace has uncommitted changes")
}

// CanPublish mirrors the Slack admission gate, which refuses publish once the
// work is closed. In practice a cleanup row usually exists because the work
// closed, so this is rare here — but a page must not offer what the service
// will refuse.
func (w RetainedWorkspace) CanPublish() bool {
	return w.IncidentID != "" && w.WorkKind == "engineering_task" &&
		w.IncidentStatus != "closed"
}

// CanRerun offers another pass through the janitor's own checks — the same
// SetCleanupState path the service uses — but only where a second pass could
// end differently. A dirty tree and unpublished commits are policy refusals
// the janitor re-makes deterministically, and a retry that always re-blocks
// is a live-looking control that does nothing.
func (w RetainedWorkspace) CanRerun() bool {
	return w.State == "blocked" &&
		!strings.HasPrefix(w.Refusal, "workspace has uncommitted changes") &&
		!strings.HasPrefix(w.Refusal, "workspace has unpublished committed changes")
}

// Explain says why a held row offers no action, in that row's own terms.
// Empty when an action is offered. A row with neither a button nor a reason
// reads as a rendering fault, and a button that the service would refuse is
// worse.
func (w RetainedWorkspace) Explain() string {
	if w.CanPublish() || w.CanDiscard() || w.CanRerun() || w.CanReclaim() {
		return ""
	}
	if strings.HasPrefix(w.Refusal, "workspace has uncommitted changes") {
		return "Nothing may delete uncommitted work — not the janitor, not Slack, not this page. " +
			"Inspect the fork directly and decide what to preserve; cleanup takes it once the tree is clean."
	}

	return "No Slack-equivalent action applies in this state; the refusal above says what the janitor needs."
}

// RetainedWorkspaces splits the cleanup ledger into the rows waiting on a
// person and the rows the janitor still owns. Done rows are excluded — they
// are reclaimed disk, not a workspace — and counted separately by the page.
func (r *Reader) RetainedWorkspaces(ctx context.Context) (held, queued []RetainedWorkspace, err error) {
	rows, err := collect(ctx, r, `
	  SELECT c.session_id, COALESCE(c.incident_id,''), c.reason, c.state,
	         COALESCE(NULLIF(c.last_error,''),''), c.attempts, c.allow_unmerged,
	         c.created_at, c.eligible_at, c.next_attempt_at,
	         COALESCE(i.title,''), COALESCE(i.status,''), COALESCE(i.work_kind,''),
	         COALESCE((SELECT channel_id FROM channel_memories
	                   WHERE session_id = c.session_id LIMIT 1),
	                  (SELECT channel_id FROM conversation_sessions
	                   WHERE session_id = c.session_id LIMIT 1), '')
	  FROM coop_cleanup AS c
	  LEFT JOIN incidents AS i ON i.id = c.incident_id
	  WHERE c.state != 'done'
	  ORDER BY c.updated_at DESC LIMIT 200`,
		func(rows *sql.Rows) (RetainedWorkspace, error) {
			var item RetainedWorkspace
			var allow int
			var created, eligible, next, channel string
			err := rows.Scan(&item.SessionID, &item.IncidentID, &item.Reason, &item.State,
				&item.Refusal, &item.Attempts, &allow, &created, &eligible, &next,
				&item.IncidentTitle, &item.IncidentStatus, &item.WorkKind, &channel)
			item.AllowUnmerged = allow != 0
			item.Created = parseStamp(created)
			item.Eligible = parseStamp(eligible)
			item.NextAttempt = parseStamp(next)
			item.Channel = r.channelName(ctx, channel)
			// Only rows with a work record get the title treatment: cleanTitle
			// turns an empty string into "Untitled work", which for a session
			// with no incident would invent a work record that does not exist.
			if item.IncidentID != "" {
				item.IncidentTitle = cleanTitle(item.IncidentTitle)
			}
			return item, err
		})
	if err != nil {
		return nil, nil, err
	}
	for _, row := range rows {
		if row.State == "blocked" {
			held = append(held, row)
		} else {
			queued = append(queued, row)
		}
	}
	return held, queued, nil
}
