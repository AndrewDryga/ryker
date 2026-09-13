package webui

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
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
	if finished.Detail != "job=website" {
		t.Fatalf("arguments were lost in the fold: %q", finished.Detail)
	}
	// Showing it as running is honest; inventing a completion is not.
	if moments[1].Status != "" || moments[1].Duration != "" {
		t.Fatalf("an unfinished call was given an ending: %+v", moments[1])
	}
}

// An Emisar call arrives as mcp.emisar.run_action wrapping a 250-byte
// envelope, and the fact that matters — which action ran against which target
// — is two levels inside it. Four such rows printed the envelope four times
// and made the reader dig for the only part that differed.
func TestReaderNamesTheOperationInsideAnMCPCall(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 20, 22, 45, 0, time.UTC)
	input := `{"input":{"arguments":{"action_id":"tfc.run_details",` +
		`"args":{"run_id":"run-d3doZz584gYuTKrA"},` +
		`"pack_ref":"hcp-terraform@0.7.0/sha256:3f34cba5aaaaf61b36480ec3c77f55f7dae0da90",` +
		`"reason":"Verify the exact lifecycle of the blitz-infra CI run.",` +
		`"runner_refs":["emisar-gcp-runner~4a20767d"],"wait":"30s"},` +
		`"server":"emisar","tool":"run_action"}}`
	fixture.exec(`INSERT INTO agent_activity
	  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
	   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
	  VALUES ('act-1','episode-1','run-1','sess-1','turn-1',1,'tool.started',
	          't1','mcp.emisar.run_action','execute','',?,?,?)`,
		input, at.Format(time.RFC3339Nano), fixture.stamp)

	reader := fixture.reader()
	defer reader.Close()
	moments, err := reader.Activity(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 1 {
		t.Fatalf("want one call, got %+v", moments)
	}
	call := moments[0]
	if call.Title != "emisar · tfc.run_details" {
		t.Fatalf("the row is still named after the envelope: %q", call.Title)
	}
	// The cell carries the target, not the pack digest and runner ref that are
	// identical on every call from the same pack.
	if call.Detail != "run_id=run-d3doZz584gYuTKrA" {
		t.Fatalf("arguments cell = %q", call.Detail)
	}
	// Nothing is lost — it moves behind the disclosure, reason first.
	if !strings.HasPrefix(call.Arguments, "Why: Verify the exact lifecycle of the blitz-infra CI run.") {
		t.Fatalf("the stated reason is not surfaced: %q", call.Arguments)
	}
	for _, want := range []string{"pack_ref", "runner_refs", "hcp-terraform@0.7.0"} {
		if !strings.Contains(call.Arguments, want) {
			t.Fatalf("normalizing dropped %q from the full record", want)
		}
	}
}

// Adapters populate rawInput only for MCP calls, so an empty object is the
// common case. "{}" in a cell is worse than nothing, and there is nothing to
// open behind it.
func TestReaderTreatsAnEmptyToolInputAsAbsent(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 20, 22, 45, 0, time.UTC)
	fixture.exec(`INSERT INTO agent_activity
	  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
	   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
	  VALUES ('act-1','episode-1','run-1','sess-1','turn-1',1,'tool.started',
	          't1','Terminal','execute','','{"input":{}}',?,?)`,
		at.Format(time.RFC3339Nano), fixture.stamp)

	reader := fixture.reader()
	defer reader.Close()
	moments, err := reader.Activity(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 1 || moments[0].Title != "Terminal" {
		t.Fatalf("want the call kept under its own name: %+v", moments)
	}
	if moments[0].Detail != "" || moments[0].Arguments != "" {
		t.Fatalf("an empty input produced content: %+v", moments[0])
	}
}

// A plain (non-MCP) tool keeps its own name and gets its fields flattened.
func TestReaderFlattensAPlainToolInput(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 20, 22, 45, 0, time.UTC)
	fixture.exec(`INSERT INTO agent_activity
	  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
	   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
	  VALUES ('act-1','episode-1','run-1','sess-1','turn-1',1,'tool.started',
	          't1','Read','read','',
	          '{"input":{"file_path":"/repo/apps_cms.tf","limit":40}}',?,?)`,
		at.Format(time.RFC3339Nano), fixture.stamp)

	reader := fixture.reader()
	defer reader.Close()
	moments, err := reader.Activity(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if moments[0].Title != "Read" {
		t.Fatalf("a plain tool was renamed: %q", moments[0].Title)
	}
	if moments[0].Detail != "file_path=/repo/apps_cms.tf · limit=40" {
		t.Fatalf("arguments cell = %q", moments[0].Detail)
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

func activitySteps(t *testing.T, page episodePage) []TraceStep {
	t.Helper()
	found := []TraceStep{}
	for _, step := range buildEpisodeTrace(config.Pricing{}, page, nil).Steps {
		if strings.HasPrefix(step.ID, "activity-") {
			found = append(found, step)
		}
	}
	return found
}

func detailByLabel(step TraceStep, label string) (TraceDetail, bool) {
	for _, detail := range step.Details {
		if detail.Label == label {
			return detail, true
		}
	}
	return TraceDetail{}, false
}

func toolMoment(name string, at time.Time) ActivityMoment {
	return ActivityMoment{
		Kind: "tool", Title: name, ToolKind: "execute", Status: "completed",
		Duration: "1.0s", At: at, Detail: "run_id=r1", Arguments: "{\n  \"run_id\": \"r1\"\n}",
	}
}

// An episode that narrated nothing gets no cards.
func TestActivityAbsentWithoutActivity(t *testing.T) {
	if steps := activitySteps(t, episodePage{}); len(steps) != 0 {
		t.Fatalf("an episode with no recorded activity got %d cards", len(steps))
	}
}

// The shape that makes both turns work: an unbroken run of calls is one card,
// however long, so a mechanical turn that fires twenty-six Emisar actions back
// to back does not bury the rest of the trace.
func TestConsecutiveToolCallsCollapseIntoOneCard(t *testing.T) {
	start := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	moments := make([]ActivityMoment, 0, 26)
	for index := range 26 {
		moments = append(moments, toolMoment(
			fmt.Sprintf("emisar · tfc.action_%d", index), start.Add(time.Duration(index)*time.Second)))
	}
	steps := activitySteps(t, episodePage{Activity: moments})
	if len(steps) != 1 {
		t.Fatalf("26 back-to-back calls produced %d cards, want 1", len(steps))
	}
	if steps[0].Title != "26 tool calls" {
		t.Fatalf("card title = %q", steps[0].Title)
	}
	table, ok := detailByLabel(steps[0], "Every call, in order")
	if !ok || len(table.Table.Rows) != 26 {
		t.Fatalf("the calls are not all in the card's table: %+v", table.Table)
	}
	if steps[0].Duration != "25.0s" {
		t.Fatalf("card span = %q, want the whole run", steps[0].Duration)
	}
}

// And the shape the single summary card destroyed: reasoning and acting
// alternate, and the page has to keep the order they happened in.
func TestReasoningAndCallsAlternateAsSeparateCards(t *testing.T) {
	start := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	at := func(seconds int) time.Time { return start.Add(time.Duration(seconds) * time.Second) }
	steps := activitySteps(t, episodePage{Activity: []ActivityMoment{
		{Kind: "thought", Detail: "Check whether the rollout finished.", At: at(0)},
		toolMoment("emisar · tfc.run_details", at(1)),
		toolMoment("emisar · tfc.plan_summary", at(2)),
		{Kind: "thought", Detail: "The plan touched one resource.", At: at(3)},
		toolMoment("emisar · nomad.job_status", at(4)),
	}})
	if len(steps) != 4 {
		t.Fatalf("want thought, calls, thought, call — got %d cards", len(steps))
	}
	titles := []string{steps[0].Title, steps[1].Title, steps[2].Title, steps[3].Title}
	want := []string{"Reasoning", "2 tool calls", "Reasoning", "emisar · nomad.job_status"}
	for index := range want {
		if titles[index] != want[index] {
			t.Fatalf("card %d = %q, want %q (all: %v)", index, titles[index], want[index], titles)
		}
	}
	// Neither card carries a summary line. The table sits open directly under
	// it and lists every call, so a header naming the first few would be the
	// same sentence twice.
	for _, step := range steps {
		if step.Summary != "" && step.Title != "Reasoning" {
			t.Fatalf("card %q repeats its own table: %q", step.Title, step.Summary)
		}
	}
	// Order on the rail is the order they happened.
	for index := 1; index < len(steps); index++ {
		if steps[index].At.Before(steps[index-1].At) {
			t.Fatalf("cards are out of order at %d", index)
		}
	}
}

// The cards belong to "The work", and the preparation before them no longer
// claims that name.
func TestActivityCardsOpenTheWorkChapter(t *testing.T) {
	start := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	page := episodePage{
		Item:     Item{Created: start},
		Source:   SourceInput{Received: start},
		Manifest: ManifestRow{Version: 1, Created: start.Add(time.Second)},
		// The turn ends after its work, which is what dates the usage card.
		// Without it that card falls back to the briefing's timestamp, lands
		// before the work it measured, and — chapters being forward-only —
		// drags the work into "The answer".
		Turn:      Turn{RunID: "run-1", State: "completed", Updated: start.Add(10 * time.Second)},
		Activity:  []ActivityMoment{toolMoment("emisar · tfc.run_details", start.Add(2*time.Second))},
		Delivered: []Delivery{{Kind: "post", State: "sent", Channel: "C1", At: start.Add(time.Minute)}},
	}
	trace := buildEpisodeTrace(config.Pricing{}, page, nil)
	chapterOf := map[string]string{}
	titles := []string{}
	for _, chapter := range trace.Chapters {
		titles = append(titles, chapter.Title)
		for _, step := range chapter.Steps {
			chapterOf[step.ID] = chapter.Title
		}
	}
	if chapterOf["activity-1"] != "The work" {
		t.Fatalf("the activity card landed in %q; chapters=%v", chapterOf["activity-1"], titles)
	}
	// The briefing is preparation, and now says so.
	if chapterOf["prompt"] != "Getting ready" {
		t.Fatalf("the briefing landed in %q; chapters=%v", chapterOf["prompt"], titles)
	}
	// Chapters are assigned forward-only, so a card banded too late would drag
	// everything after it along.
	if titles[len(titles)-1] != "What came of it" {
		t.Fatalf("last chapter = %q; the cards pulled the story forward", titles[len(titles)-1])
	}
}

// The summary strip above the trace is what a reader scans before opening
// anything, so it has to admit the turn's interior was recorded at all.
func TestTraceSummaryCountsToolCalls(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	trace := buildEpisodeTrace(config.Pricing{}, episodePage{Activity: []ActivityMoment{
		toolMoment("emisar · run_action", at),
		toolMoment("emisar · http.probe", at.Add(time.Second)),
		// Not a call, and must not be counted as one.
		{Kind: "thought", Detail: "Check the rollout.", At: at.Add(2 * time.Second)},
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

// A call with no terminal update did not succeed, and the card says so rather
// than rendering it as finished.
func TestCallsThatNeverFinishedAreNamed(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	steps := activitySteps(t, episodePage{Activity: []ActivityMoment{
		{Kind: "tool", Title: "emisar · run_action", ToolKind: "execute", At: at},
	}})
	var running string
	for _, stat := range steps[0].Stats {
		if stat.Label == "never finished" {
			running = stat.Value
		}
	}
	if running != "1" {
		t.Fatalf("an unfinished call was not called out: %+v", steps[0].Stats)
	}
	table, _ := detailByLabel(steps[0], "Every call, in order")
	if got := table.Table.Rows[0].Cells[1]; !strings.HasPrefix(got, "still running · ") {
		t.Fatalf("state cell = %q, want an honest unfinished state", got)
	}
}

// Identity columns must not break mid-token, and what a cell summarized away
// has to stay reachable behind it.
func TestCallTableIsTightAndExpandable(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	steps := activitySteps(t, episodePage{Activity: []ActivityMoment{
		toolMoment("emisar · tfc.run_details", at),
	}})
	table, ok := detailByLabel(steps[0], "Every call, in order")
	if !ok || table.Table == nil {
		t.Fatalf("the call has no table: %+v", steps[0].Details)
	}
	if !table.Open {
		t.Fatal("the call table renders collapsed")
	}
	if !table.Table.Tight {
		t.Fatal("the table wraps its identity columns")
	}
	if got, want := table.Table.Headers, []string{"Tool", "State", "At", "Arguments"}; !slices.Equal(got, want) {
		t.Fatalf("call table headers = %q, want the compact scan path %q", got, want)
	}
	row := table.Table.Rows[0]
	if row.ExpandAt != 3 || !strings.Contains(row.Expand, `"run_id": "r1"`) {
		t.Fatalf("the full record is not behind the arguments cell: %+v", row)
	}
	// The toggle controls are namespaced per card. A page carries several of
	// these tables, and a duplicated control id would make one row's click
	// open a different card's record.
	if table.Table.IDPrefix != steps[0].ID {
		t.Fatalf("table id prefix = %q, want the card's own id %q",
			table.Table.IDPrefix, steps[0].ID)
	}
}

// Every cell in an expandable row is a label for that row's toggle, so the
// whole row is the click target rather than one column of it.
func TestEveryCellOfAnExpandableRowIsTheControl(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	for index, action := range []string{"tfc.run_details", "tfc.plan_summary"} {
		fixture.exec(`INSERT INTO agent_activity
		  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
		   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
		  VALUES (?,'episode-1','run-1','sess-1','turn-1',?,'tool.started',?,
		          'mcp.emisar.run_action','execute','',?,?,?)`,
			fmt.Sprintf("act-%d", index), index+1, fmt.Sprintf("t%d", index),
			fmt.Sprintf(`{"input":{"arguments":{"action_id":%q,"args":{"run_id":"r1"}},`+
				`"server":"emisar","tool":"run_action"}}`, action),
			at.Add(time.Duration(index)*time.Second).Format(time.RFC3339Nano), fixture.stamp)
	}
	reader := fixture.reader()
	defer reader.Close()
	body := servePage(t, reader, "/episodes/episode-1")
	rows := regexp.MustCompile(`(?s)<tr class="is-expandable">(.*?)</tr>`).FindAllStringSubmatch(body, -1)
	if len(rows) != 2 {
		t.Fatalf("want two expandable rows, got %d", len(rows))
	}
	for index, row := range rows {
		id := regexp.MustCompile(`id="([^"]+)"`).FindStringSubmatch(row[1])
		if id == nil {
			t.Fatalf("row %d has no toggle", index)
		}
		cells := strings.Count(row[1], "<td>")
		labels := strings.Count(row[1], `<label for="`+id[1]+`"`)
		if labels != cells {
			t.Fatalf("row %d: %d of %d cells are click targets", index, labels, cells)
		}
	}
	// Two rows, two distinct controls.
	if strings.Count(body, `class="trace-row-toggle"`) != 2 {
		t.Fatalf("expected one toggle per row: %d", strings.Count(body, `class="trace-row-toggle"`))
	}
	if strings.Contains(body, "trace-cell-detail") {
		t.Fatal("the old single-column disclosure is still rendered")
	}
}

func TestPlanPermissionAndElisionEachGetACard(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	steps := activitySteps(t, episodePage{Activity: []ActivityMoment{
		{Kind: "plan", At: at, Entries: []ActivityPlanStep{
			{Content: "Read the run", Status: "completed"},
			{Content: "Check allocations", Status: "pending"},
		}},
		{Kind: "permission", Title: "emisar · run_action", Detail: "allow_always",
			At: at.Add(time.Second)},
		{Kind: "elided", Detail: "the turn produced more activity than one turn may narrate",
			Dropped: 12, At: at.Add(2 * time.Second)},
	}})
	if len(steps) != 3 {
		t.Fatalf("want a card each, got %d", len(steps))
	}
	if steps[0].Title != "Plan updated" || steps[0].Summary != "1 of 2 steps done" {
		t.Fatalf("plan card = %+v", steps[0])
	}
	plan, ok := detailByLabel(steps[0], "The plan as it stood")
	if !ok || !strings.Contains(plan.Body, "• Read the run — completed") {
		t.Fatalf("plan detail = %+v", plan)
	}
	// Nobody human answered this; the trace owes the reader that fact, in the
	// words it happened in rather than the wire's enum spelling.
	if steps[1].Title != "Used a tool — policy allowed it" {
		t.Fatalf("permission card = %+v", steps[1])
	}
	if !strings.Contains(steps[1].Summary, "keep allowing this for the rest of the session") {
		t.Fatalf("permission summary = %q", steps[1].Summary)
	}
	// A silently short list would read as a complete account of the turn.
	if steps[2].Tone != "warn" || steps[2].Stats[0].Value != "12" {
		t.Fatalf("elision card = %+v", steps[2])
	}
}

// "Permission decided — allow_always" is the machinery's vocabulary for it.
// What a reader wants is the two facts underneath: what was asked for, and
// whether it went ahead. Every decision Coop can record maps to a sentence,
// including the ones it cannot name — an unrecognised answer rendered as a
// blank is a decision the page hid.
func TestPermissionCardNamesTheActionAndTheDecision(t *testing.T) {
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	for _, want := range []struct {
		name, toolKind, outcome, decision string
		title, summary, raw               string
		tone                              string
	}{{
		name: "a lasting allow on a command", toolKind: "execute",
		outcome: "selected", decision: "allow_always",
		title:   "Ran a command — policy allowed it",
		summary: "Allowed, and policy will keep allowing this for the rest of the session.",
	}, {
		name: "a one-shot allow on a command", toolKind: "execute",
		outcome: "selected", decision: "allow_once",
		title:   "Ran a command — policy allowed it",
		summary: "Allowed this once — the next request like it is decided again.",
	}, {
		name: "the bare allow spelling, on a read", toolKind: "read",
		outcome: "selected", decision: "allow",
		title:   "Read a file — policy allowed it",
		summary: "Allowed this once — the next request like it is decided again.",
	}, {
		name: "a lasting refusal on an edit", toolKind: "edit",
		outcome: "selected", decision: "reject_always",
		title:   "Did not edit a file — policy refused it",
		summary: "Refused, and policy will keep refusing this for the rest of the session.",
		tone:    "warn",
	}, {
		name: "a one-shot refusal on a command", toolKind: "execute",
		outcome: "selected", decision: "reject_once",
		title:   "Did not run a command — policy refused it",
		summary: "Refused this once — the next request like it is decided again.",
		tone:    "warn",
	}, {
		name: "the deny spelling, on a delete", toolKind: "delete",
		outcome: "selected", decision: "deny",
		title:   "Did not delete a file — policy refused it",
		summary: "Refused this once — the next request like it is decided again.",
		tone:    "warn",
	}, {
		// What Coop actually does when a request offers it no allow option.
		name: "a cancelled request", toolKind: "execute",
		outcome: "cancelled", decision: "",
		title:   "Did not run a command — policy refused it",
		summary: "Refused: the request offered no answer Coop is allowed to give, so the call never ran.",
		tone:    "warn",
	}, {
		name: "an answer nobody recorded", toolKind: "execute",
		outcome: "", decision: "",
		title:   "Asked to run a command — policy answered",
		summary: "Coop answered this request, but the record does not say which way.",
	}, {
		// The kinds are the agent's, not Ryker's. One this page has never
		// seen is reported as exactly that, beside the value it was given.
		name: "a decision this page cannot name", toolKind: "execute",
		outcome: "selected", decision: "escalate_to_owner",
		title:   "Asked to run a command — policy answered",
		summary: "Coop recorded an answer this page cannot name. It is printed below, exactly as it was recorded.",
		raw:     "escalate_to_owner",
	}, {
		name: "a tool kind this page has no phrasing for", toolKind: "switch_mode",
		outcome: "selected", decision: "allow_always",
		title:   "Used a tool — policy allowed it",
		summary: "Allowed, and policy will keep allowing this for the rest of the session.",
	}} {
		t.Run(want.name, func(t *testing.T) {
			steps := activitySteps(t, episodePage{Activity: []ActivityMoment{{
				Kind: "permission", Title: "curl -sS https://api.example.com/v1/runs",
				ToolKind: want.toolKind, Status: want.outcome, Detail: want.decision, At: at,
			}}})
			if len(steps) != 1 {
				t.Fatalf("want one card, got %d", len(steps))
			}
			step := steps[0]
			if step.Title != want.title {
				t.Fatalf("title = %q, want %q", step.Title, want.title)
			}
			if step.Summary != want.summary {
				t.Fatalf("summary = %q, want %q", step.Summary, want.summary)
			}
			if step.Tone != want.tone {
				t.Fatalf("tone = %q, want %q", step.Tone, want.tone)
			}
			// The enum spelling is not the card's vocabulary anywhere a reader
			// reads a sentence. Every wire value carries an underscore and no
			// English sentence here does, so one in either line is a leak.
			if strings.ContainsRune(step.Title+step.Summary, '_') {
				t.Fatalf("the wire spelling leaked into the prose: %q / %q",
					step.Title, step.Summary)
			}
			// What was asked for is below the sentence, in a block, never in it.
			asked, ok := detailByLabel(step, "The command")
			if want.toolKind != "execute" {
				if ok {
					t.Fatalf("a %s call was captioned as a command", want.toolKind)
				}
			} else if !ok || asked.Body != "curl -sS https://api.example.com/v1/runs" {
				t.Fatalf("the command is not in its own block: %+v", step.Details)
			}
			if strings.Contains(step.Summary, "curl") {
				t.Fatalf("the command is back in the summary: %q", step.Summary)
			}
			recorded, ok := detailByLabel(step, "The answer Coop recorded")
			if want.raw == "" {
				if ok {
					t.Fatalf("a named decision printed a raw value: %+v", recorded)
				}
			} else if !ok || recorded.Body != want.raw {
				t.Fatalf("an unnamed decision went invisible: %+v", step.Details)
			}
			// The insight the card has always carried, kept to what the record
			// proves: Coop has no path that waits for a person.
			if !strings.Contains(step.Why, "policy") {
				t.Fatalf("why = %q", step.Why)
			}
		})
	}
}

// The bug the operator hit: a permission card put the tool's own arguments
// through the prose renderer, which found the URL inside the command and made
// it a link. Tool input is not prose. It renders in a code block, escaped,
// with nothing looking for markup in it.
func TestPermissionCommandRendersInertInACodeBlock(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	const hostile = "curl -sS https://evil.example.com/x " +
		"-d '<script>alert(1)</script>' && echo `id` **not bold**"
	seed := func(id string, sequence int, kind, title, toolKind, detail string) {
		fixture.exec(`INSERT INTO agent_activity
		  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
		   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
		  VALUES (?,'episode-1','run-1','sess-1','turn-1',?,?,'t1',?,?,'',?,?,?)`,
			id, sequence, kind, title, toolKind, detail,
			at.Add(time.Duration(sequence)*time.Second).Format(time.RFC3339Nano), fixture.stamp)
	}
	// The tool call names its kind; the permission that answered it does not,
	// and reads the kind off the call it names.
	seed("act-1", 1, "tool.started", hostile, "execute", `{"input":{"command":"`+"curl"+`"}}`)
	seed("act-2", 2, "permission.decided", hostile, "",
		`{"outcome":"selected","option_id":"opt-1","option_kind":"allow_always"}`)

	reader := fixture.reader()
	defer reader.Close()
	body := servePage(t, reader, "/episodes/episode-1")

	if strings.Contains(body, "<script>") {
		t.Fatal("a transcript string opened a script tag on the page")
	}
	if strings.Contains(body, "evil.example.com\"") || strings.Contains(body, "href=\"https://evil.example.com") {
		t.Fatal("the URL inside a command became a link")
	}
	if !strings.Contains(body, "&lt;script&gt;alert(1)&lt;/script&gt;") {
		t.Fatal("the command's angle brackets were not escaped")
	}
	// Every block holding the command holds it as text: escaped content has no
	// "<" left in it at all, so one is proof that markup got in.
	blocks := regexp.MustCompile(`(?s)<pre>(.*?)</pre>`).FindAllStringSubmatch(body, -1)
	found := 0
	for _, block := range blocks {
		if !strings.Contains(block[1], "evil.example.com") {
			continue
		}
		found++
		if strings.Contains(block[1], "<") {
			t.Fatalf("markup reached a code block: %q", block[1])
		}
	}
	if found == 0 {
		t.Fatalf("the command was not rendered in a code block at all: %s", body)
	}
	// And the card leads with the sentence, not with the command.
	if !strings.Contains(body, "Ran a command — policy allowed it") {
		t.Fatal("the card does not say what happened")
	}
	if strings.Contains(body, "allow_always") {
		t.Fatal("the card still shows the wire's enum spelling")
	}
}

// The audit behind the fix above, held in place: every other route transcript
// text takes to this page — a tool's name, its recorded arguments, the model's
// own prose — escapes it, and none of them can be talked into emitting a tag.
// The prose renderer does linkify, which is what it is for; what it must never
// do is let the text close its own tag.
func TestTranscriptTextNeverBecomesMarkup(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	at := time.Date(2026, 8, 13, 18, 11, 0, 0, time.UTC)
	const hostile = `<img src=x onerror="alert(1)">`
	// The string has to survive being a JSON value before it can be tested as
	// an HTML one: embedded raw, its quotes end the field and the payload is
	// simply unparseable, which passes every assertion below by rendering
	// nothing at all.
	quoted, err := json.Marshal(hostile)
	if err != nil {
		t.Fatal(err)
	}
	seed := func(id string, sequence int, kind, callID, title, toolKind, detail string) {
		fixture.exec(`INSERT INTO agent_activity
		  (id, episode_id, agent_run_id, session_id, turn_id, sequence, kind,
		   tool_call_id, title, tool_kind, status, detail, occurred_at, created_at)
		  VALUES (?,'episode-1','run-1','sess-1','turn-1',?,?,?,?,?,'',?,?,?)`,
			id, sequence, kind, callID, title, toolKind, detail,
			at.Add(time.Duration(sequence)*time.Second).Format(time.RFC3339Nano), fixture.stamp)
	}
	// A tool name, a tool's recorded arguments, a plan entry, and model prose.
	seed("act-1", 1, "tool.started", "t1", hostile, "execute",
		`{"input":{"command":`+string(quoted)+`}}`)
	seed("act-2", 2, "model.plan", "", "Plan updated", "",
		`{"entries":[{"content":`+string(quoted)+`,"status":"pending"}]}`)
	seed("act-3", 3, "model.thought", "", "Reasoning", "",
		`{"text":`+string(quoted)+`}`)

	reader := fixture.reader()
	defer reader.Close()
	body := servePage(t, reader, "/episodes/episode-1")

	// The escaped rendering contains the letters "onerror" itself, so the tag
	// opening and the attribute quote are what a leak actually looks like.
	if strings.Contains(body, "<img") || strings.Contains(body, `onerror="`) {
		t.Fatal("a transcript string emitted a tag or an event handler")
	}
	// Five sinks, five escapes: the card's own heading, the row's name cell,
	// its flattened arguments cell, the argument disclosure, the plan block,
	// and the reasoning summary — the prose renderer among them.
	if got := strings.Count(body, "&lt;img src=x onerror="); got < 5 {
		t.Fatalf("only %d sinks rendered the string escaped: %s", got, body)
	}
}
