package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

func activityFixture(t *testing.T) *Store {
	t.Helper()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_1", "working",
		map[string][2]string{"run_1": {"running", "2026-08-07T12:00:00.000000000Z"}})
	return st
}

func recordActivity(t *testing.T, st *Store, activity core.AgentActivity) bool {
	t.Helper()
	if activity.EpisodeID == "" {
		activity.EpisodeID = "ep_1"
	}
	if activity.AgentRunID == "" {
		activity.AgentRunID = "run_1"
	}
	if activity.OccurredAt.IsZero() {
		activity.OccurredAt = time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	}
	stored, err := st.Activity.Record(context.Background(), activity)
	if err != nil {
		t.Fatalf("record %s: %v", activity.Kind, err)
	}
	return stored
}

// The Coop event sequence is the identity of a moment, not just its order.
// Polling is at-least-once and the cursor is rewound to zero whenever it
// outruns the session, so the same narration arrives more than once by design.
func TestRecordAgentActivityIsIdempotentOnTheCoopSequence(t *testing.T) {
	st := activityFixture(t)
	first := recordActivity(t, st, core.AgentActivity{
		Sequence: 7, Kind: "tool.started", ToolCallID: "t1", Title: "Read job", ToolKind: "read",
	})
	if !first {
		t.Fatal("the first delivery was not stored")
	}
	if recordActivity(t, st, core.AgentActivity{
		Sequence: 7, Kind: "tool.started", ToolCallID: "t1", Title: "Read job", ToolKind: "read",
	}) {
		t.Fatal("a replayed event was stored a second time")
	}
	items, err := st.Activity.ListForEpisode(context.Background(), "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("a replay told the story twice: %d rows", len(items))
	}
}

func TestListEpisodeActivityOrdersBySequenceNotTimestamp(t *testing.T) {
	st := activityFixture(t)
	// Same instant, which is ordinary: several frames land inside one
	// millisecond and the timestamp cannot order them.
	same := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	for _, sequence := range []int64{3, 1, 2} {
		recordActivity(t, st, core.AgentActivity{
			Sequence: sequence, Kind: "tool.started",
			Title: "call", OccurredAt: same,
		})
	}
	items, err := st.Activity.ListForEpisode(context.Background(), "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 3 {
		t.Fatalf("want 3 rows, got %d", len(items))
	}
	for index, want := range []int64{1, 2, 3} {
		if items[index].Sequence != want {
			t.Fatalf("row %d has sequence %d, want %d", index, items[index].Sequence, want)
		}
	}
}

func TestRecordAgentActivityRejectsAnUnanchoredMoment(t *testing.T) {
	st := activityFixture(t)
	ctx := context.Background()
	for name, activity := range map[string]core.AgentActivity{
		"no episode":  {AgentRunID: "run_1", Sequence: 1, Kind: "tool.started"},
		"no run":      {EpisodeID: "ep_1", Sequence: 1, Kind: "tool.started"},
		"no kind":     {EpisodeID: "ep_1", AgentRunID: "run_1", Sequence: 1},
		"no sequence": {EpisodeID: "ep_1", AgentRunID: "run_1", Kind: "tool.started"},
	} {
		if _, err := st.Activity.Record(ctx, activity); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}

// Detail is bounded JSON or nothing. A payload that is neither must not reach
// a page that will try to parse it.
func TestRecordAgentActivityDropsUnusableDetail(t *testing.T) {
	st := activityFixture(t)
	recordActivity(t, st, core.AgentActivity{
		Sequence: 1, Kind: "tool.started", Title: "call",
		Detail: []byte("this is not json"),
	})
	items, err := st.Activity.ListForEpisode(context.Background(), "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("want the row without its detail, got %d rows", len(items))
	}
	if len(items[0].Detail) != 0 {
		t.Fatalf("unparseable detail was stored: %q", items[0].Detail)
	}
}

// The card shows the newest lines at the top, the way anyone scans a feed, and
// newest is by sequence rather than by arrival: the cursor rewinds, so the
// start of a turn can be delivered after its middle.
//
// Displayable is tool.started and model.thought and nothing else. A completion
// repeats the line its start already put on the card, and a plan revision, a
// permission decision and an elision notice are all about the run rather than
// about the work the operator asked for.
func TestEpisodeActivityTailShowsTheNewestDisplayableMomentsFirst(t *testing.T) {
	st := activityFixture(t)
	for _, moment := range []core.AgentActivity{
		{Sequence: 1, Kind: "model.thought", Title: "the alert names the checkout pod"},
		{Sequence: 2, Kind: "tool.started", Title: "Read runbook", ToolKind: "read"},
		{Sequence: 3, Kind: "tool.completed", Title: "Read runbook", Status: "ok"},
		{Sequence: 4, Kind: "model.plan", Title: "check the deploy first"},
		{Sequence: 5, Kind: "model.thought", Title: "the 11:58 deploy looks related"},
		{Sequence: 6, Kind: "permission.decided", Title: "bash", Status: "allowed"},
		{Sequence: 7, Kind: "tool.started", Title: "Grep deploy log", ToolKind: "search"},
		{Sequence: 8, Kind: "activity.elided", Title: "12 moments elided"},
	} {
		recordActivity(t, st, moment)
	}
	tail, err := st.Activity.TailForEpisode(context.Background(), "ep_1", 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail.Lines) != 3 {
		t.Fatalf("the card asked for 3 lines and got %d", len(tail.Lines))
	}
	for index, want := range []int64{7, 5, 2} {
		if tail.Lines[index].Sequence != want {
			t.Fatalf("line %d has sequence %d, want %d: the tail is not newest first",
				index, tail.Lines[index].Sequence, want)
		}
	}
	for _, line := range tail.Lines {
		if line.Kind != "tool.started" && line.Kind != "model.thought" {
			t.Fatalf("a %s reached the card as %q", line.Kind, line.Title)
		}
	}
}

// A retried episode holds several runs, and the card has to show the attempt
// that is working rather than the one that gave up. The tail groups by run
// before sequence for exactly that reason — but it orders the groups by
// agent_run_id, and a run id is thirty-two characters of crypto/rand with no
// time in them, so "the greatest id" is a coin flip rather than "the newest
// run".
//
// On the deployed blitz database eight episodes have narration from more than
// one run, and for four of them agent_run_id DESC names the older run: for
// episode_run_2b25a096… it picks run_2b25a096… over the later run_26d38089…
// because 'b' sorts above '6'. The names here are chosen to make that same
// comparison deterministic instead of leaving it to the random half.
func TestEpisodeActivityTailShowsTheRunningAttemptNotTheAbandonedOne(t *testing.T) {
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_1", "working", map[string][2]string{
		"run_b_abandoned": {"failed", "2026-08-07T12:00:00.000000000Z"},
		"run_a_retry":     {"running", "2026-08-07T12:30:00.000000000Z"},
	})
	base := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	for _, moment := range []core.AgentActivity{
		{AgentRunID: "run_b_abandoned", Sequence: 1, Kind: "tool.started",
			Title: "Read the stale runbook", OccurredAt: base},
		{AgentRunID: "run_b_abandoned", Sequence: 2, Kind: "model.thought",
			Title: "this is going nowhere", OccurredAt: base.Add(time.Minute)},
		{AgentRunID: "run_a_retry", Sequence: 10, Kind: "model.thought",
			Title: "starting again from the deploy log", OccurredAt: base.Add(30 * time.Minute)},
		{AgentRunID: "run_a_retry", Sequence: 11, Kind: "tool.started",
			Title: "Read deploy log", OccurredAt: base.Add(31 * time.Minute)},
	} {
		recordActivity(t, st, moment)
	}
	tail, err := st.Activity.TailForEpisode(context.Background(), "ep_1", 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail.Lines) != 2 {
		t.Fatalf("the card asked for 2 lines and got %d", len(tail.Lines))
	}
	if tail.Lines[0].Title != "Read deploy log" {
		t.Fatalf("newest line = %q, want %q: the card is showing the attempt that "+
			"gave up while the retry is working", tail.Lines[0].Title, "Read deploy log")
	}
}

// The lines are a window and the counters are the whole turn. "119 tool calls"
// behind a strip showing the last two is the fact the card exists to state, so
// the counts are read from the table rather than from the rows that survived
// the limit.
func TestEpisodeActivityTailCountsTheWholeTurnBehindItsThreeLines(t *testing.T) {
	st := activityFixture(t)
	sequence := int64(0)
	record := func(kind, title string) {
		sequence++
		recordActivity(t, st, core.AgentActivity{
			Sequence: sequence, Kind: kind, Title: title,
		})
	}
	for _, call := range []string{
		"Read runbook", "Grep deploy log", "Read pod events",
		"Curl health endpoint", "Read the 11:58 diff",
	} {
		record("tool.started", call)
	}
	record("model.thought", "the checkout pod restarted twice")
	record("model.thought", "the deploy is the likeliest cause")
	record("tool.completed", "Read the 11:58 diff")
	record("permission.decided", "bash")

	tail, err := st.Activity.TailForEpisode(context.Background(), "ep_1", 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail.Lines) != 3 {
		t.Fatalf("the card asked for 3 lines and got %d", len(tail.Lines))
	}
	if tail.ToolCalls != 5 {
		t.Fatalf("tool calls = %d, want 5: the counter described the window, not the turn",
			tail.ToolCalls)
	}
	if tail.Recorded != 9 {
		t.Fatalf("recorded = %d, want 9 moments of every kind", tail.Recorded)
	}
}

// Freshness is the newest moment of any kind, including the kinds the card
// refuses to show. A turn that has spent four minutes waiting on a permission
// decision is not an idle turn, and a stamp that counted only displayable
// moments would report a run that never stopped working as stalled.
func TestEpisodeActivityTailFreshnessCountsMomentsItNeverShows(t *testing.T) {
	st := activityFixture(t)
	base := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	shown := base.Add(time.Minute)
	waited := base.Add(4 * time.Minute)
	for _, moment := range []core.AgentActivity{
		{Sequence: 1, Kind: "tool.started", Title: "Read runbook", OccurredAt: base},
		{Sequence: 2, Kind: "model.thought", Title: "the pod restarted twice",
			OccurredAt: base.Add(30 * time.Second)},
		{Sequence: 3, Kind: "tool.started", Title: "Bash kubectl rollout", OccurredAt: shown},
		{Sequence: 4, Kind: "permission.decided", Title: "bash", Status: "allowed",
			OccurredAt: waited},
	} {
		recordActivity(t, st, moment)
	}
	tail, err := st.Activity.TailForEpisode(context.Background(), "ep_1", 3)
	if err != nil {
		t.Fatal(err)
	}
	if !tail.LastActivity.Equal(waited) {
		t.Fatalf("freshness = %s, want %s: the permission the turn waited on did not count",
			tail.LastActivity, waited)
	}
	// The moment that set it is deliberately not on the card, which is the
	// whole reason the two answers are read separately.
	if len(tail.Lines) == 0 || !tail.Lines[0].OccurredAt.Equal(shown) {
		t.Fatalf("newest shown line = %+v, want the tool call at %s", tail.Lines, shown)
	}
}

// "Thinking, nothing to show yet" is a different card from "nothing has
// happened", and a turn whose whole narration so far is a plan and a permission
// has to render as the first. The read joins the counts to the lines from the
// outside for this case alone: an inner join would drop the counters along with
// the lines and make a working turn look like one that never started.
func TestEpisodeActivityTailReportsATurnWithNothingDisplayableYet(t *testing.T) {
	st := activityFixture(t)
	base := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	newest := base.Add(45 * time.Second)
	for _, moment := range []core.AgentActivity{
		{Sequence: 1, Kind: "model.plan", Title: "read the runbook first", OccurredAt: base},
		{Sequence: 2, Kind: "permission.decided", Title: "bash", Status: "allowed",
			OccurredAt: base.Add(15 * time.Second)},
		{Sequence: 3, Kind: "tool.completed", Title: "Read runbook", Status: "ok",
			OccurredAt: base.Add(30 * time.Second)},
		{Sequence: 4, Kind: "activity.elided", Title: "12 moments elided", OccurredAt: newest},
	} {
		recordActivity(t, st, moment)
	}
	tail, err := st.Activity.TailForEpisode(context.Background(), "ep_1", 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail.Lines) != 0 {
		t.Fatalf("a non-displayable moment reached the card: %+v", tail.Lines)
	}
	if tail.Recorded != 4 || tail.ToolCalls != 0 {
		t.Fatalf("counts = %d recorded / %d tool calls, want 4 / 0: the totals were lost "+
			"with the lines", tail.Recorded, tail.ToolCalls)
	}
	if !tail.LastActivity.Equal(newest) {
		t.Fatalf("freshness = %s, want %s: a turn narrating only its own bookkeeping "+
			"still reports when it last did so", tail.LastActivity, newest)
	}
}

// An incident that was retried holds several episodes, and the card is a window
// onto the turn that is running rather than onto everything the incident has
// ever done. The card worker holds an incident and asks again every fifteen
// seconds, so the read resolves the newest episode itself instead of charging
// the caller a round trip to find it.
func TestIncidentActivityTailReadsTheNewestEpisodeBehindTheIncident(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_early", "completed",
		map[string][2]string{"run_early": {"completed", "2026-08-07T11:00:00.000000000Z"}})
	seedEpisodeWithRun(t, st, "ep_late", "working",
		map[string][2]string{"run_late": {"running", "2026-08-07T13:00:00.000000000Z"}})
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO incidents (id, route, repository, correlation_key, title, status,
		  workflow, created_at, updated_at)
		VALUES ('inc_1','manual','repo','k','Checkout latency','active','idle',
		  '2026-08-07T11:00:00.000000000Z','2026-08-07T11:00:00.000000000Z')`,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET incident_id = 'inc_1' WHERE id IN ('run_early','run_late')`,
	); err != nil {
		t.Fatal(err)
	}
	// The first attempt did plenty and is over.
	for _, sequence := range []int64{1, 2, 3} {
		recordActivity(t, st, core.AgentActivity{
			EpisodeID: "ep_early", AgentRunID: "run_early", Sequence: sequence,
			Kind: "tool.started", Title: "first attempt",
		})
	}
	recordActivity(t, st, core.AgentActivity{
		EpisodeID: "ep_late", AgentRunID: "run_late", Sequence: 1,
		Kind: "model.thought", Title: "retrying against the deploy log",
	})
	recordActivity(t, st, core.AgentActivity{
		EpisodeID: "ep_late", AgentRunID: "run_late", Sequence: 2,
		Kind: "tool.started", Title: "Read deploy log",
	})

	tail, err := st.Activity.TailForIncident(ctx, "inc_1", 3)
	if err != nil {
		t.Fatal(err)
	}
	if tail.Recorded != 2 || tail.ToolCalls != 1 {
		t.Fatalf("counts = %d recorded / %d tool calls, want 2 / 1: the abandoned attempt "+
			"was counted into the running one", tail.Recorded, tail.ToolCalls)
	}
	if len(tail.Lines) != 2 {
		t.Fatalf("want the running episode's 2 lines, got %d", len(tail.Lines))
	}
	for _, line := range tail.Lines {
		if line.Title == "first attempt" {
			t.Fatalf("a line from the earlier episode reached the card: %+v", line)
		}
	}
	if tail.Lines[0].Sequence != 2 {
		t.Fatalf("newest line has sequence %d, want 2", tail.Lines[0].Sequence)
	}
}

// Engineering work often returns from review feedback in a new episode. The
// work card is a task receipt, so its totals span those episodes while its
// visible window still shows the latest activity.
func TestEngineeringTaskActivityTailKeepsCumulativeTotalsAcrossFeedbackEpisodes(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_first", "completed",
		map[string][2]string{"run_first": {"completed", "2026-08-07T11:00:00.000000000Z"}})
	seedEpisodeWithRun(t, st, "ep_feedback", "working",
		map[string][2]string{"run_feedback": {"running", "2026-08-07T13:00:00.000000000Z"}})
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO incidents (id, route, repository, correlation_key, title, status,
		  workflow, work_kind, created_at, updated_at)
		VALUES ('task_1','manual','repo','k','Sampling','active','investigating',
		  'engineering_task','2026-08-07T11:00:00.000000000Z','2026-08-07T11:00:00.000000000Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET incident_id = 'task_1' WHERE id IN ('run_first','run_feedback')`); err != nil {
		t.Fatal(err)
	}
	for sequence := int64(1); sequence <= 3; sequence++ {
		recordActivity(t, st, core.AgentActivity{
			EpisodeID: "ep_first", AgentRunID: "run_first", Sequence: sequence,
			Kind: "tool.started", Title: "initial implementation",
			OccurredAt: time.Date(2026, 8, 7, 11, int(sequence), 0, 0, time.UTC),
		})
	}
	recordActivity(t, st, core.AgentActivity{
		EpisodeID: "ep_feedback", AgentRunID: "run_feedback", Sequence: 1,
		Kind: "tool.started", Title: "apply review feedback",
		OccurredAt: time.Date(2026, 8, 7, 13, 1, 0, 0, time.UTC),
	})

	tail, err := st.Activity.TailForWork(ctx, "task_1", 3)
	if err != nil {
		t.Fatal(err)
	}
	if tail.Recorded != 4 || tail.ToolCalls != 4 {
		t.Fatalf("task totals reset on feedback: %+v", tail)
	}
	if len(tail.Lines) != 3 || tail.Lines[0].Title != "apply review feedback" {
		t.Fatalf("task window is not the newest activity: %+v", tail.Lines)
	}
}

func TestEngineeringTaskMilestonesUseDurableHostTimestamps(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_milestones", "completed",
		map[string][2]string{"run_milestones": {"completed", "2026-08-07T11:00:00.000000000Z"}})
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO incidents (id, route, repository, correlation_key, title, status,
		  workflow, work_kind, created_at, updated_at)
		VALUES ('task_milestones','manual','repo','km','Milestones','active','parked',
		  'engineering_task','2026-08-07T10:58:00.000000000Z','2026-08-07T11:06:00.000000000Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `
		UPDATE agent_runs SET incident_id = 'task_milestones', mode = 'engineering_task'
		WHERE id = 'run_milestones'`); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO publications (
		  incident_id, repository, base_branch, head_branch, parent_head,
		  candidate_tree, state, created_at, updated_at
		) VALUES (
		  'task_milestones','repo','main','ryker/task','parent','candidate',
		  'reviewing','2026-08-07T11:05:00.000000000Z','2026-08-07T11:05:00.000000000Z'
		)`); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO timeline_events (id, incident_id, kind, title, created_at)
		VALUES ('tl_workspace','task_milestones','coop.session.created','Workspace ready',
		  '2026-08-07T10:59:00.000000000Z')`); err != nil {
		t.Fatal(err)
	}
	recordActivity(t, st, core.AgentActivity{
		EpisodeID: "ep_milestones", AgentRunID: "run_milestones", Sequence: 1,
		Kind: "model.plan", Title: "Plan", OccurredAt: time.Date(2026, 8, 7, 11, 1, 0, 0, time.UTC),
	})

	milestones, err := st.TaskCards.Milestones(ctx, "task_milestones")
	if err != nil {
		t.Fatal(err)
	}
	if got := milestones.WorkspaceReadyAt.Format(time.RFC3339); got != "2026-08-07T10:59:00Z" {
		t.Fatalf("workspace ready = %s", got)
	}
	if got := milestones.PlanningStartedAt.Format(time.RFC3339); got != "2026-08-07T11:00:00Z" {
		t.Fatalf("planning started = %s", got)
	}
	if got := milestones.PlanningFinishedAt.Format(time.RFC3339); got != "2026-08-07T11:01:00Z" {
		t.Fatalf("planning finished = %s", got)
	}
	if got := milestones.ImplementationFinishedAt.Format(time.RFC3339); got != "2026-08-07T11:05:00Z" {
		t.Fatalf("implementation finished = %s", got)
	}
}

// The episode carries its own freshness stamp so the watchdog can read one row
// instead of aggregating the narration under it, and the two are written in one
// transaction so a crash cannot leave a stamp the stored rows contradict.
//
// It only ever moves forward. Polling is at-least-once and the cursor rewinds
// to zero, so a moment from the start of a turn arrives after one from its end;
// letting the older stamp win would report a working run as stalled.
func TestRecordAgentActivityStampsEpisodeFreshnessAndNeverMovesItBack(t *testing.T) {
	ctx := context.Background()
	st := activityFixture(t)
	base := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	latest := base.Add(10 * time.Second)
	recordActivity(t, st, core.AgentActivity{
		Sequence: 5, Kind: "tool.started", Title: "Grep deploy log", OccurredAt: latest,
	})
	episode, err := st.GetWorkEpisode(ctx, "ep_1")
	if err != nil {
		t.Fatal(err)
	}
	if !episode.LastActivityAt.Equal(latest) {
		t.Fatalf("episode freshness = %s, want %s", episode.LastActivityAt, latest)
	}
	// The rewound cursor replays the opening of the turn after its latest
	// moment has already been stored.
	recordActivity(t, st, core.AgentActivity{
		Sequence: 2, Kind: "model.thought", Title: "read the alert", OccurredAt: base,
	})
	episode, err = st.GetWorkEpisode(ctx, "ep_1")
	if err != nil {
		t.Fatal(err)
	}
	if !episode.LastActivityAt.Equal(latest) {
		t.Fatalf("a replayed earlier moment dragged freshness back to %s, want %s",
			episode.LastActivityAt, latest)
	}
}

// The rows belong to the episode's story and go when it does.
func TestEpisodeActivityIsDeletedWithItsEpisode(t *testing.T) {
	st := activityFixture(t)
	ctx := context.Background()
	recordActivity(t, st, core.AgentActivity{Sequence: 1, Kind: "tool.started", Title: "call"})
	if _, err := st.db.ExecContext(ctx, `DELETE FROM work_episodes WHERE id = 'ep_1'`); err != nil {
		t.Fatal(err)
	}
	items, err := st.Activity.ListForEpisode(ctx, "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("activity outlived its episode: %d rows", len(items))
	}
}

// The card said "Terminal" three times while the command sat two rows away.
//
// A Claude runtime opens a shell call as title "Terminal" with an input of {}
// and names the command only when the call settles, under the same tool call
// id. The tail window selects tool.started rows, so it read the one moment of
// the three that does not know what ran: on the deployed blitz instance 1,249
// of 1,251 "Terminal" rows had a recoverable command already on disk.
func TestActivityTailRecoversTheCommandASettledMomentSupplied(t *testing.T) {
	st := activityFixture(t)
	const command = `git stash -q && cargo clippy --locked --all-targets`
	for _, moment := range []core.AgentActivity{
		{
			Sequence: 1, Kind: "tool.started", ToolKind: "execute",
			ToolCallID: "toolu_a", Title: "Terminal",
			Detail: json.RawMessage(`{"input":{}}`),
		},
		{
			Sequence: 2, Kind: "permission.decided",
			ToolCallID: "toolu_a", Title: command, Status: "allowed",
		},
		{
			Sequence: 3, Kind: "tool.completed", ToolKind: "execute",
			ToolCallID: "toolu_a", Title: command, Status: "completed",
		},
	} {
		recordActivity(t, st, moment)
	}

	tail, err := st.Activity.TailForEpisode(context.Background(), "ep_1", 3)
	if err != nil {
		t.Fatal(err)
	}

	if len(tail.Lines) != 1 {
		t.Fatalf("the settled moments became rows of their own: %d lines", len(tail.Lines))
	}
	if got := tail.Lines[0].SettledTitle; got != command {
		t.Fatalf("settled title = %q, want the command the later moment carried %q", got, command)
	}
}

// The floor beside the test above: a call still in flight has no later moment,
// and inventing one would be worse than the placeholder.
func TestActivityTailLeavesAnUnsettledCallWithoutASettledTitle(t *testing.T) {
	st := activityFixture(t)
	recordActivity(t, st, core.AgentActivity{
		Sequence: 1, Kind: "tool.started", ToolKind: "execute",
		ToolCallID: "toolu_b", Title: "Terminal",
		Detail: json.RawMessage(`{"input":{}}`),
	})

	tail, err := st.Activity.TailForEpisode(context.Background(), "ep_1", 3)
	if err != nil {
		t.Fatal(err)
	}

	if len(tail.Lines) != 1 {
		t.Fatalf("want the running call as one line, got %d", len(tail.Lines))
	}
	if got := tail.Lines[0].SettledTitle; got != "" {
		t.Fatalf("settled title = %q, want empty for a call that has not settled", got)
	}
}

// The screenshot that started this was an engineering task card, and a task
// reads TailForWork rather than TailForIncident — a different query, built by
// rewriting the episode predicate to span every episode behind the task. The
// recovery has to survive that rewrite, or the one card shape that showed the
// defect is the one shape still showing it.
func TestEngineeringTaskActivityTailAlsoRecoversTheSettledCommand(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_task", "working",
		map[string][2]string{"run_task": {"running", "2026-08-07T13:00:00.000000000Z"}})
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO incidents (id, route, repository, correlation_key, title, status,
		  workflow, work_kind, created_at, updated_at)
		VALUES ('task_1','manual','repo','k','Realtime Gateway','active','investigating',
		  'engineering_task','2026-08-07T11:00:00.000000000Z','2026-08-07T11:00:00.000000000Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET incident_id = 'task_1' WHERE id = 'run_task'`); err != nil {
		t.Fatal(err)
	}
	const command = `cargo clippy --locked --all-targets -- -D warnings`
	recordActivity(t, st, core.AgentActivity{
		EpisodeID: "ep_task", AgentRunID: "run_task", Sequence: 1,
		Kind: "tool.started", ToolKind: "execute", ToolCallID: "toolu_c",
		Title: "Terminal", Detail: json.RawMessage(`{"input":{}}`),
		OccurredAt: time.Date(2026, 8, 7, 13, 1, 0, 0, time.UTC),
	})
	recordActivity(t, st, core.AgentActivity{
		EpisodeID: "ep_task", AgentRunID: "run_task", Sequence: 2,
		Kind: "tool.completed", ToolKind: "execute", ToolCallID: "toolu_c",
		Title: command, Status: "completed",
		OccurredAt: time.Date(2026, 8, 7, 13, 2, 0, 0, time.UTC),
	})

	tail, err := st.Activity.TailForWork(ctx, "task_1", 3)
	if err != nil {
		t.Fatal(err)
	}

	if len(tail.Lines) != 1 {
		t.Fatalf("want the one shell call as one line, got %d", len(tail.Lines))
	}
	if got := tail.Lines[0].SettledTitle; got != command {
		t.Fatalf("settled title = %q, want %q", got, command)
	}
}
