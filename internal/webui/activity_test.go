package webui

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
)

// Coop narrates a tool call as two events — it started, it finished — because
// the trace has to be readable while the turn is still running. By the time
// anyone opens the page those two are one row with a duration.
func TestReaderFoldsToolStartAndFinishIntoOneMoment(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	seed := func(sequence int, kind, callID, title, toolKind, status string, detail any, offset time.Duration) {
		fixture.exec(`INSERT INTO agent_activity
		  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
		   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
		  VALUES (?,'episode-1','run-1','sess-1','turn-1',?,?,?,?,?,?,?,?,?)`,
			"act-"+title+"-"+status, sequence, kind, callID, title, toolKind, status, detail,
			at.Add(offset).Format(time.RFC3339Nano), fixture.stamp)
	}
	seed(1, "tool.started", "t1", "Emisar nomad.job_status", "execute", "",
		`{"input":{"job":"website"}}`, 0)
	seed(2, "tool.completed", "t1", "Emisar nomad.job_status", "execute", "completed",
		nil, 2500*time.Millisecond)
	// A start whose completion never arrived: the turn ended while it ran.
	seed(3, "tool.started", "t2", "Read apps_cms.tf", "read", "", nil, 3*time.Second)

	reader := fixture.reader()
	defer reader.Close()
	moments, err := reader.Activity(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 2 {
		t.Fatalf("want two calls, got %d: %+v", len(moments), moments)
	}
	finished := moments[0]
	if finished.Status != "completed" || finished.Duration != "2.5s" {
		t.Fatalf("the pair did not fold into one row: %+v", finished)
	}
	if finished.Title != "Emisar nomad.job_status" || finished.ToolKind != "execute" {
		t.Fatalf("folding lost the call's identity: %+v", finished)
	}
	if finished.Detail != `{"job":"website"}` {
		t.Fatalf("arguments were lost in the fold: %q", finished.Detail)
	}
	// Showing it as running is honest; inventing a completion is not.
	if moments[1].Status != "" || moments[1].Duration != "" {
		t.Fatalf("an unfinished call was given an ending: %+v", moments[1])
	}
}

// Providers number tool calls per session, so an episode that ran twice holds
// two "t1"s. A call the first run left open must not swallow the second run's
// completion and report a duration spanning both.
func TestReaderDoesNotPairToolCallsAcrossRuns(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	fixture.exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, state, next_attempt_at, created_at,
	   updated_at, episode_id)
	  VALUES ('run-2','triage','C1','1786000000.000001','C1:1786000000.000001',
	          'watch','input-2','U1','emisar','idem-2','completed',?,?,?,'episode-1')`,
		fixture.stamp, fixture.stamp, fixture.stamp)
	seed := func(id, runID string, sequence int, kind, status string, offset time.Duration) {
		fixture.exec(`INSERT INTO agent_activity
		  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
		   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
		  VALUES (?,'episode-1',?,'sess-1','turn-1',?,?,'t1','Read config','read',?,NULL,?,?)`,
			id, runID, sequence, kind, status,
			at.Add(offset).Format(time.RFC3339Nano), fixture.stamp)
	}
	// The first run opened t1 and never closed it.
	seed("a1", "run-1", 1, "tool.started", "", 0)
	// The second run's own t1, a full hour later, completes normally.
	seed("a2", "run-2", 1, "tool.started", "", time.Hour)
	seed("a3", "run-2", 2, "tool.completed", "completed", time.Hour+time.Second)

	reader := fixture.reader()
	defer reader.Close()
	moments, err := reader.Activity(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 2 {
		t.Fatalf("want one open call and one closed call, got %+v", moments)
	}
	if moments[0].Status != "" || moments[0].Duration != "" {
		t.Fatalf("the first run's open call was closed by another run: %+v", moments[0])
	}
	if moments[1].Status != "completed" || moments[1].Duration != "1.0s" {
		t.Fatalf("the second run's call did not pair with its own start: %+v", moments[1])
	}
}

// A completion whose start was never recorded still happened — the narration
// budget can run out mid-call, and dropping the row would hide a real action.
func TestReaderKeepsACompletionWithoutItsStart(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	fixture.exec(`INSERT INTO agent_activity
	  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
	   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
	  VALUES ('act-1','episode-1','run-1','sess-1','turn-1',9,'tool.completed',
	          'orphan','Emisar http.probe','execute','failed',NULL,?,?)`,
		at.Format(time.RFC3339Nano), fixture.stamp)

	reader := fixture.reader()
	defer reader.Close()
	moments, err := reader.Activity(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 1 {
		t.Fatalf("want the orphaned completion kept, got %+v", moments)
	}
	if moments[0].Status != "failed" || moments[0].Tone != "bad" {
		t.Fatalf("a failed call was not marked: %+v", moments[0])
	}
}

func activityStep(t *testing.T, page episodePage) (TraceStep, bool) {
	t.Helper()
	for _, step := range buildEpisodeTrace(config.Pricing{}, page, nil).Steps {
		if step.ID == "activity" {
			return step, true
		}
	}
	return TraceStep{}, false
}

func detailByLabel(step TraceStep, label string) (TraceDetail, bool) {
	for _, detail := range step.Details {
		if detail.Label == label {
			return detail, true
		}
	}
	return TraceDetail{}, false
}

// An episode that narrated nothing gets no card. A turn from a Coop that
// predates this, or one that used no tools, must not sprout an empty section.
func TestActivityStepIsAbsentWithoutActivity(t *testing.T) {
	if _, ok := activityStep(t, episodePage{}); ok {
		t.Fatal("an episode with no recorded activity got an activity card")
	}
}

// One card, not one per call. A turn runs dozens, and a rail that pushed each
// onto the timeline would bury the decisions an operator came to read.
func TestActivityStepFoldsEveryCallIntoOneCard(t *testing.T) {
	start := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	page := episodePage{Activity: []ActivityMoment{
		{Kind: "tool", Title: "Emisar nomad.job_status", ToolKind: "execute",
			Status: "completed", Duration: "2.0s", At: start, Detail: `{"job":"website"}`},
		{Kind: "tool", Title: "Read apps_cms.tf", ToolKind: "read",
			Status: "completed", Duration: "120ms", At: start.Add(3 * time.Second)},
		{Kind: "tool", Title: "Emisar http.probe", ToolKind: "execute",
			Status: "failed", Tone: "bad", Duration: "5.0s", At: start.Add(6 * time.Second)},
	}}
	step, ok := activityStep(t, page)
	if !ok {
		t.Fatal("recorded activity produced no card")
	}
	if step.At != start {
		t.Fatalf("the card must sit at the first moment, not %v", step.At)
	}
	if step.Duration != "6.0s" {
		t.Fatalf("span = %q, want the first-to-last stretch", step.Duration)
	}
	if !strings.Contains(step.Summary, "3 tool calls") ||
		!strings.Contains(step.Summary, "1 failed call") {
		t.Fatalf("summary does not count the work: %q", step.Summary)
	}
	if step.Tone != "warn" {
		t.Fatalf("a failed call left the card unmarked: tone %q", step.Tone)
	}
	table, ok := detailByLabel(step, "Every call, in order")
	if !ok || table.Table == nil {
		t.Fatalf("the calls are not behind a table: %+v", step.Details)
	}
	// A closed disclosure is why the first person to look for this on a live
	// episode reported not seeing it at all.
	if !table.Open {
		t.Fatal("the call table renders collapsed")
	}
	if len(table.Table.Rows) != 3 {
		t.Fatalf("table rows = %d, want one per call", len(table.Table.Rows))
	}
	// Offsets are relative to the first moment, so a reader sees the shape of
	// the turn rather than three near-identical wall-clock stamps.
	if got := table.Table.Rows[1].Cells[0]; got != "+3.0s" {
		t.Fatalf("second call is at %q, want an offset from the first", got)
	}
	if got := table.Table.Rows[0].Cells[5]; got != `{"job":"website"}` {
		t.Fatalf("arguments were lost: %q", got)
	}
	// Counted by kind, so "it ran nine actions and read two files" is legible
	// without opening anything.
	if len(step.Stats) != 2 || step.Stats[0].Label != "execute" || step.Stats[0].Value != "2" {
		t.Fatalf("kind tally = %+v", step.Stats)
	}
}

// The summary strip above the trace is what a reader scans before opening
// anything, so it has to admit the turn's interior was recorded at all.
func TestTraceSummaryCountsToolCalls(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	trace := buildEpisodeTrace(config.Pricing{}, episodePage{Activity: []ActivityMoment{
		{Kind: "tool", Title: "Emisar run_action", ToolKind: "execute", Status: "completed", At: at},
		{Kind: "tool", Title: "Emisar http.probe", ToolKind: "execute", Status: "completed", At: at},
		// Not a call, and must not be counted as one.
		{Kind: "thought", Detail: "Check the rollout.", At: at},
	}}, nil)
	var found string
	for _, stat := range trace.Stats {
		if stat.Label == "Tool calls" {
			found = stat.Value
		}
	}
	if found != "2" {
		t.Fatalf("tool calls in the summary strip = %q, want \"2\"; stats=%+v", found, trace.Stats)
	}
}

// The card belongs to "The work". Chapters are assigned forward-only, so a
// card that landed in a later band would drag every step after it along.
func TestActivityStepBelongsToTheWorkChapter(t *testing.T) {
	start := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	page := episodePage{
		Item:   Item{Created: start},
		Source: SourceInput{Received: start},
		Activity: []ActivityMoment{{
			Kind: "tool", Title: "Emisar nomad.job_status", ToolKind: "execute",
			Status: "completed", Duration: "2.0s", At: start.Add(time.Second),
		}},
		Delivered: []Delivery{{
			Kind: "post", State: "sent", Channel: "C1",
			At: start.Add(time.Minute),
		}},
	}
	trace := buildEpisodeTrace(config.Pricing{}, page, nil)
	var chapter string
	for _, candidate := range trace.Chapters {
		for _, step := range candidate.Steps {
			if step.ID == "activity" {
				chapter = candidate.Title
			}
		}
	}
	if chapter != "The work" {
		t.Fatalf("the activity card landed in %q, want \"The work\"", chapter)
	}
	// And the delivery after it still reads as an outcome, which is what
	// breaks first if the card is banded too late.
	last := trace.Chapters[len(trace.Chapters)-1]
	if last.Title != "What came of it" {
		t.Fatalf("last chapter = %q; the card pulled the story forward", last.Title)
	}
}

// A call with no terminal update did not succeed. The card says so rather than
// rendering it as finished.
func TestActivityStepNamesCallsThatNeverFinished(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	step, ok := activityStep(t, episodePage{Activity: []ActivityMoment{
		{Kind: "tool", Title: "Emisar run_action", ToolKind: "execute", At: at},
	}})
	if !ok {
		t.Fatal("no card")
	}
	if !strings.Contains(step.Summary, "never reported finishing") {
		t.Fatalf("an unfinished call was not called out: %q", step.Summary)
	}
	table, _ := detailByLabel(step, "Every call, in order")
	if got := table.Table.Rows[0].Cells[3]; got != "still running" {
		t.Fatalf("status cell = %q, want an honest unfinished state", got)
	}
}

func TestActivityStepSeparatesReasoningPlanAndPermissions(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	step, ok := activityStep(t, episodePage{Activity: []ActivityMoment{
		{Kind: "thought", Detail: "Check whether the rollout finished.", At: at},
		{Kind: "plan", At: at.Add(time.Second), Entries: []ActivityPlanStep{
			{Content: "Read the run", Status: "completed"},
			{Content: "Check allocations", Status: "pending"},
		}},
		{Kind: "permission", Title: "Emisar run_action", Detail: "allow_always",
			At: at.Add(2 * time.Second)},
		{Kind: "elided", Detail: "the turn produced more activity than one turn may narrate",
			Dropped: 12, At: at.Add(3 * time.Second)},
	}})
	if !ok {
		t.Fatal("no card")
	}
	if !strings.Contains(step.Summary, "2 plan steps") ||
		!strings.Contains(step.Summary, "1 reasoning pass") {
		t.Fatalf("summary = %q", step.Summary)
	}
	plan, ok := detailByLabel(step, "Plan the model kept")
	if !ok || !strings.Contains(plan.Body, "• Read the run — completed") {
		t.Fatalf("plan detail = %+v", plan)
	}
	reasoning, ok := detailByLabel(step, "Reasoning")
	if !ok || reasoning.Body != "Check whether the rollout finished." {
		t.Fatalf("reasoning detail = %+v", reasoning)
	}
	// Nobody human answered this; the trace owes the reader that fact.
	decided, ok := detailByLabel(step, "Permissions answered without a person")
	if !ok || !strings.Contains(decided.Body, "Emisar run_action — allow_always") {
		t.Fatalf("permission detail = %+v", decided)
	}
	// A silently short list would read as a complete account of the turn.
	elided, ok := detailByLabel(step, "Not recorded")
	if !ok || !strings.Contains(elided.Body, "more activity than one turn may narrate") {
		t.Fatalf("elision detail = %+v", elided)
	}
}
