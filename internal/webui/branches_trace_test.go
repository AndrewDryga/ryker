package webui

import (
	"context"
	"strings"
	"testing"
)

// A fan-out is invisible on the lead's page without this row. The branches are
// child episodes with their own traces, their own prompts and their own
// evidence, and the question that follows "this ran in parallel" is always
// "what did that one find" — which nobody can answer from a list of ids they
// cannot open.
//
// Two things are checked because both have failed elsewhere in this package:
// the row has to name the goal an operator can recognize, and the link has to
// sit in the one cell the table template actually renders as a link.
func TestTheLeadPageListsItsBranchesWithOpenableLinks(t *testing.T) {
	reader := branchFixture(t)
	defer reader.Close()

	branches, err := reader.Branches(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(branches) != 2 {
		t.Fatalf("branches = %+v, want the two fanned-out children", branches)
	}
	goals := map[string]string{}
	for _, branch := range branches {
		goals[branch.GoalID] = branch.State
	}
	if goals["goal-host"] != "completed" || goals["goal-dependency"] != "working" {
		t.Fatalf("branch goals and states = %+v, want goal-host completed and "+
			"goal-dependency working", goals)
	}

	step := branchesStep(branches)
	if !strings.Contains(step.Summary, "2 branches") {
		t.Fatalf("branches row summary = %q, want the branch count", step.Summary)
	}
	var stillRunning string
	for _, stat := range step.Stats {
		if stat.Label == "Still running" {
			stillRunning = stat.Value
		}
	}
	if stillRunning != "1 branch" {
		t.Fatalf("still-running stat = %q; an operator reading a fan-out needs "+
			"to know whether the lead is still waiting", stillRunning)
	}
	table := step.Details[0].Table
	if table == nil || len(table.Rows) != 2 {
		t.Fatalf("branch table = %+v, want one row per branch", table)
	}
	for _, row := range table.Rows {
		if row.Href == "" {
			t.Fatalf("branch row %v has no link; a branch nobody can open is a "+
				"coordinate they have to go paste somewhere else", row.Cells)
		}
		if !strings.HasSuffix(string(row.Href), row.Cells[1]) {
			t.Fatalf("branch row links %q but names %q in the linked cell; the "+
				"template only renders cell 1 as a link", row.Href, row.Cells[1])
		}
	}
}

// The other kind of child. Watch correlation makes a follow-up message a child
// of the episode it continues — the same investigation carrying on, not a
// parallel one — and rendering those here would report every busy thread as a
// fan-out.
func TestACorrelatedFollowUpIsNotListedAsABranch(t *testing.T) {
	reader := branchFixture(t)
	defer reader.Close()

	branches, err := reader.Branches(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	for _, branch := range branches {
		if branch.EpisodeID == "episode-followup" {
			t.Fatal("a correlated follow-up episode was rendered as a parallel " +
				"branch; it is the same investigation continuing")
		}
	}
}

func branchFixture(t *testing.T) *Reader {
	t.Helper()
	fixture := newEpisodeProjectionFixture(t)
	children := []struct{ episode, run, key, state, objective string }{
		{"episode-host", "run-host", "incident:inc_1#branch:goal-host",
			"completed", "Branch goal-host: settle web-1"},
		{"episode-dependency", "run-dependency", "incident:inc_1#branch:goal-dependency",
			"working", "Branch goal-dependency: settle payments"},
		// Not a branch: a correlated follow-up shares the parent column.
		{"episode-followup", "run-followup", "C1:1786000000.000001",
			"working", "Continue the rollout check"},
	}
	for index, child := range children {
		fixture.exec(`INSERT INTO agent_runs
		  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
		   user_id, repository, idempotency_key, result_json, terminal_state, state,
		   next_attempt_at, created_at, updated_at, episode_id, attempt_id, attempt_number)
		  VALUES (?,'incident','C1','1786000000.000001',?,'fanout',?,'U1','emisar',?,
		          '','','pending',?,?,?,?,?,1)`,
			child.run, child.key, "src-"+child.run, "idem-"+child.run,
			fixture.stamp, fixture.stamp, fixture.stamp, child.episode,
			"attempt-"+child.run)
		fixture.exec(`INSERT INTO work_episodes
		  (id, agent_run_id, effort, authority, objective, phase, status, next_action,
		   created_at, updated_at, lifecycle_state, channel_id, thread_ts, anchor_ts,
		   latest_attempt_id, parent_episode_id)
		  VALUES (?,?,'incident_investigation','read_only',?,'working','Working',
		          'Investigate',?,?,?,'C1','1786000000.000001','',?, 'episode-1')`,
			child.episode, child.run, child.objective,
			// Ordered so the fan-out renders in the order it was opened.
			fixture.stamp[:len(fixture.stamp)-2]+string(rune('0'+index))+"Z",
			fixture.stamp, child.state, "attempt-"+child.run)
	}
	return fixture.reader()
}
