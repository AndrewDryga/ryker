package webui

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// AssignmentDetail is one standing assignment with everything needed to decide
// whether it should ever be granted: what it covers, whether it is withheld,
// and what its gate has actually decided.
//
// It sits beside the standing rules for the same reason they gained
// fired/acted/quiet counters on 2026-08-09: a grant that has never been argued
// with is a grant nobody can judge, and the counters are the argument. This one
// is a larger grant, so the page says plainly that it is opening nothing.
type AssignmentDetail struct {
	ID, Channel, Signal, Repository, ChangeClass, Paths, Actor string
	Enabled, Shadow                                            bool
	DailyBudget                                                int
	Evaluated, Eligible, Declined, TopDeclineCount             int
	TopDecline                                                 string
	LastEvaluated, LastEligible, Expires, Created              time.Time
}

// State is what this assignment can do right now, shadow first, because that is
// the difference between a grant and a rehearsal.
func (d AssignmentDetail) State() string {
	switch {
	case !d.Enabled:
		return "paused"
	case !d.Expires.IsZero() && d.Expires.Before(time.Now().UTC()):
		return "expired"
	case d.Shadow:
		return "shadow"
	default:
		return "live"
	}
}

// Covers is the grant in one line, in the words an operator would use.
func (d AssignmentDetail) Covers() string {
	scope := "the whole repository"
	if d.Paths != "" {
		scope = d.Paths
	}
	return fmt.Sprintf(
		"When %s recurs in %s, open a %s pull request in %s, within %s, up to %d a day",
		d.Signal, d.Channel, strings.ReplaceAll(d.ChangeClass, "_", " "),
		d.Repository, scope, d.DailyBudget,
	)
}

// Worth is the same sentence Slack shows, from the same function, so the two
// surfaces cannot come to different conclusions about the same rows.
func (d AssignmentDetail) Worth() string {
	return slackui.AssignmentWorth(core.StandingAssignmentTally{
		Evaluated: d.Evaluated, Eligible: d.Eligible, Declined: d.Declined,
		TopDecline: d.TopDecline, TopDeclineCount: d.TopDeclineCount,
		LastEvaluated: d.LastEvaluated, LastEligible: d.LastEligible,
	})
}

// Idle reports an assignment that has looked at signals and never once reached
// the bar. It is the standing-rule "firing but never acting" in the shape this
// grant takes, and it is the answer to "should this be switched on": no.
func (d AssignmentDetail) Idle() bool { return d.Evaluated > 0 && d.Eligible == 0 }

// StandingAssignments is every assignment with the tally its gate produced.
//
// The counts are aggregated from the evaluation rows rather than read from
// columns on the assignment. Those rows are deleted only with the assignment
// they belong to and an assignment stops producing them at its own expiry, so
// the evidence outlives the question — a stored counter beside them would be a
// second opinion about facts that are still on disk.
func (r *Reader) StandingAssignments(ctx context.Context) ([]AssignmentDetail, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT a.id, a.channel_id, a.signal_pattern, a.repository, a.change_class,
	         a.path_globs_json, a.actor_id, a.enabled, a.shadow, a.daily_budget,
	         COUNT(e.id),
	         COALESCE(SUM(e.verdict = 'eligible'), 0),
	         COALESCE(SUM(e.verdict = 'declined'), 0),
	         COALESCE(MAX(e.created_at), ''),
	         COALESCE(MAX(CASE WHEN e.verdict = 'eligible' THEN e.created_at END), ''),
	         a.expires_at, a.created_at
	  FROM standing_assignments AS a
	  LEFT JOIN standing_assignment_evaluations AS e ON e.assignment_id = a.id
	  GROUP BY a.id ORDER BY a.created_at DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []AssignmentDetail{}
	for rows.Next() {
		var item AssignmentDetail
		var channel, globs, evaluated, eligible, expires, created string
		if err := rows.Scan(&item.ID, &channel, &item.Signal, &item.Repository,
			&item.ChangeClass, &globs, &item.Actor, &item.Enabled, &item.Shadow,
			&item.DailyBudget, &item.Evaluated, &item.Eligible, &item.Declined,
			&evaluated, &eligible, &expires, &created); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, channel)
		item.Paths = strings.Trim(strings.NewReplacer(
			`["`, "", `"]`, "", `","`, ", ",
		).Replace(globs), "[]")
		item.Actor = r.userName(item.Actor)
		item.LastEvaluated, item.LastEligible = parseStamp(evaluated), parseStamp(eligible)
		item.Expires, item.Created = parseStamp(expires), parseStamp(created)
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return r.attachTopDeclines(ctx, items)
}

// attachTopDeclines names the refusal each assignment gave most often.
//
// A refusal count says an assignment is quiet; the reason says whether it is
// misconfigured or whether the traffic simply did not deserve a pull request,
// and those two call for opposite responses. Ranking recorded refusals by
// repeats is how the same question was answered for model corrections — the
// worst one there was telling the model to pick from an empty list of verdicts,
// which nobody would have found by counting.
func (r *Reader) attachTopDeclines(
	ctx context.Context,
	items []AssignmentDetail,
) ([]AssignmentDetail, error) {
	if len(items) == 0 {
		return items, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT assignment_id, reason, COUNT(*) AS repeats
	  FROM standing_assignment_evaluations WHERE verdict = 'declined'
	  GROUP BY assignment_id, reason ORDER BY assignment_id, repeats DESC, reason`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	top := map[string]AssignmentDetail{}
	for rows.Next() {
		var id, reason string
		var repeats int
		if err := rows.Scan(&id, &reason, &repeats); err != nil {
			return nil, err
		}
		if _, seen := top[id]; !seen {
			top[id] = AssignmentDetail{TopDecline: reason, TopDeclineCount: repeats}
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for index := range items {
		if best, ok := top[items[index].ID]; ok {
			items[index].TopDecline = best.TopDecline
			items[index].TopDeclineCount = best.TopDeclineCount
		}
	}
	return items, nil
}

// assignments lists scoped authority to open a pull request without a click.
//
// Read-only, and deliberately so. There is no control here that grants,
// revokes, pauses or deletes one: this dashboard authenticates by being on
// loopback, and a button that hands autonomous pull-request authority to
// whoever is at the keyboard is the wrong shape for the one grant in the
// product that acts with nobody watching. Slack's operator-only slash family
// owns those verbs.
func (h *Handler) assignments(w http.ResponseWriter, r *http.Request) {
	var failed problems
	items, err := h.reader.StandingAssignments(r.Context())
	failed.note("standing assignments", err)
	h.detail(w, r, "configuration", "assignments", "Standing assignments", struct {
		Assignments []AssignmentDetail
		Errs        problems
	}{items, failed})
}
