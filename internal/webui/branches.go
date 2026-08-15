package webui

import (
	"context"
	"database/sql"
	"html/template"
	"net/url"
	"strconv"
	"strings"
)

// branchMarker is internal/fanout's separator between an episode's conversation
// and the goal a branch runs. Spelled out rather than imported for the reason
// similarEpisodeRefKind is: the dashboard reads the database and never the
// packages that wrote it, so a rename on that side has to reach this string
// through the conversation keys already on disk, which keep the old one.
const branchMarker = "#branch:"

// BranchRow is one child episode a parallel investigation fanned out into.
//
// It exists as a row of its own rather than as one more side effect because a
// fan-out is the one shape where the children are the work. An operator asking
// why an incident took four turns instead of one, or which branch found the
// thing, is asking about this list — and finding it scattered through the
// timeline as three unrelated "work episode" steps is finding it by accident.
type BranchRow struct {
	EpisodeID string
	GoalID    string
	State     string
	Objective string
}

// Branches lists the branch children of an episode.
//
// The branch-marker filter is what tells a branch from the other kind of child
// this column carries: watch correlation makes a follow-up message a child of
// the episode it continues, and those are the same investigation carrying on
// rather than a parallel one. Rendering them here would report a busy thread as
// a fan-out.
func (r *Reader) Branches(ctx context.Context, episodeID string) ([]BranchRow, error) {
	if !r.live() {
		return nil, nil
	}
	return collect(ctx, r, `
	  SELECT episode.id, episode.lifecycle_state, episode.objective,
	         run.conversation_key
	    FROM work_episodes AS episode
	    JOIN agent_runs AS run ON run.id = episode.agent_run_id
	   WHERE episode.parent_episode_id = ?
	     AND instr(run.conversation_key, ?) > 0
	   ORDER BY episode.created_at, episode.id`,
		func(rows *sql.Rows) (BranchRow, error) {
			var item BranchRow
			var conversationKey string
			err := rows.Scan(&item.EpisodeID, &item.State, &item.Objective, &conversationKey)
			if marker := strings.Index(conversationKey, branchMarker); marker >= 0 {
				item.GoalID = conversationKey[marker+len(branchMarker):]
			}
			return item, err
		}, episodeID, branchMarker)
}

// branchesStep renders the fan-out as one row with a link per branch.
//
// The link is the point. A branch is a whole episode with its own trace, its
// own prompt and its own evidence, and the question that follows "this ran in
// parallel" is always "what did that one find" — which is unanswerable from a
// list of ids nobody can open.
func branchesStep(branches []BranchRow) TraceStep {
	rows := make([]TraceTableRow, 0, len(branches))
	running := 0
	for _, branch := range branches {
		if !terminalBranchState(branch.State) {
			running++
		}
		rows = append(rows, TraceTableRow{
			// The episode id sits in cell 1 because that is the only cell the
			// table template links.
			Cells: []string{
				fallback(branch.GoalID, "unnamed goal"),
				truncate(branch.EpisodeID, 24),
				branch.State,
				cleanTitle(branch.Objective),
			},
			Href: template.URL("/episodes/" + url.PathEscape(branch.EpisodeID)),
		})
	}
	state := "complete"
	if running > 0 {
		state = "running"
	}
	return TraceStep{
		ID: "branches", Stage: "Investigation", Actor: "Responder", State: state,
		Icon:  "split",
		Title: "Fanned out into parallel branches",
		Summary: countedBranches(len(branches)) +
			", each read-only on one independent pocket of the claims ledger.",
		Why: "The host measured two or more independent pockets of unresolved " +
			"ambiguity and the lead proposed a goal for each. Branches write " +
			"into this incident's shared ledger and cannot complete it; only " +
			"this episode synthesizes and finishes the work.",
		Stats: []TraceStat{
			{"Branches", countedBranches(len(branches))},
			{"Still running", countedBranches(running)},
		},
		Details: []TraceDetail{{
			Label: "Branch episodes", Kind: "context", Status: "Parallel",
			Tone: "operational", ShowCount: true, Count: len(branches),
			Group: "Parallel investigation", GroupCount: len(branches),
			GroupDetail: "Each branch is a child episode of this one, sharing " +
				"this incident and therefore one claims ledger.",
			Table: &TraceTable{
				Headers:  []string{"Goal", "Episode", "State", "Objective"},
				Rows:     rows,
				IDPrefix: "branch",
			},
		}},
	}
}

func terminalBranchState(state string) bool {
	switch state {
	case "completed", "failed", "refused", "cancelled", "superseded", "blocked":
		return true
	default:
		return false
	}
}

// countedBranches keeps the row readable. It is the first thing an operator
// reads about a fan-out, and "1 branches" is a sentence that makes the host
// look like it is guessing.
func countedBranches(count int) string {
	if count == 1 {
		return "1 branch"
	}
	return strconv.Itoa(count) + " branches"
}
