package webui

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"

	_ "modernc.org/sqlite"
	"os"
	"strings"
)

// Search reaches both places an operator remembers work by — the commitment
// title and the episode's own status line — and the count and the list run
// the same predicate, so "N match" can never disagree with the rows under it.
// The LIKE input is escaped: someone searching for "100%" is looking for a
// percent sign, not for every row containing "100".
func TestEpisodeSearchMatchesTitlesAndStatusAndPaginates(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	queue := func(source, title string) core.WorkEpisode {
		t.Helper()
		run, created, err := live.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: "COPS",
			ConversationKey: "thread:COPS:" + source, SourceKind: "watch",
			SourceID: source, Prompt: "Investigate " + source, CommitmentTitle: title,
		})
		if err != nil || !created {
			t.Fatalf("queue %s: created=%t err=%v", source, created, err)
		}
		episode, err := live.GetWorkEpisodeByRun(ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		return episode
	}
	queue("m1", "Checkout errors are spiking")
	second := queue("m2", "Cassandra repair overdue")
	queue("m3", "Refund is 100% complete")
	queue("m4", "Refund is 100x slower")
	// The second episode mentions checkout only in its status line.
	if err := live.SetEpisodePhase(ctx, second.ID, core.EpisodeFailed, "finished",
		"The checkout dependency broke the repair", "Review", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	matches := func(filter EpisodeFilter) ([]Item, int) {
		t.Helper()
		items, err := reader.EpisodesMatching(ctx, filter, 50)
		if err != nil {
			t.Fatal(err)
		}
		count, err := reader.CountMatching(ctx, filter)
		if err != nil {
			t.Fatal(err)
		}
		return items, count
	}

	items, count := matches(EpisodeFilter{Query: "checkout"})
	if len(items) != 2 || count != 2 {
		t.Fatalf("checkout matched %d rows, count %d, want 2 and 2", len(items), count)
	}
	items, count = matches(EpisodeFilter{Query: "checkout", State: "failed"})
	if len(items) != 1 || count != 1 || items[0].ID != second.ID {
		t.Fatalf("state filter over search = %d rows, count %d", len(items), count)
	}
	// "100%" is a literal, not a wildcard: only the row with a percent sign.
	items, count = matches(EpisodeFilter{Query: "100%"})
	if len(items) != 1 || count != 1 {
		t.Fatalf("literal %%: %d rows, count %d, want exactly the percent row", len(items), count)
	}

	// Offset pages through the same predicate rather than restarting it.
	first, err := reader.EpisodesMatching(ctx, EpisodeFilter{}, 3)
	if err != nil || len(first) != 3 {
		t.Fatalf("page one: %d rows, %v", len(first), err)
	}
	rest, err := reader.EpisodesMatching(ctx, EpisodeFilter{Offset: 3}, 3)
	if err != nil || len(rest) != 1 {
		t.Fatalf("page two: %d rows, %v", len(rest), err)
	}
	for _, earlier := range first {
		if earlier.ID == rest[0].ID {
			t.Fatal("pagination repeated a row across pages")
		}
	}
}

// The channel roll-up is the answer to "where is work happening", which the
// flat episode list could only answer by reading six hundred channel columns.
// Its outcome bar has to tile exactly: a segment that rounds away leaves a gap
// that reads as work nobody accounted for.
func TestChannelRollsGroupWorkAndTileTheirOutcomeBar(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	queue := func(channel, source string) core.WorkEpisode {
		t.Helper()
		run, created, err := live.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: channel,
			ConversationKey: "thread:" + channel + ":" + source, SourceKind: "watch",
			SourceID: source, Prompt: "Investigate " + source, CommitmentTitle: "Work in " + channel,
		})
		if err != nil || !created {
			t.Fatalf("queue %s: created=%t err=%v", source, created, err)
		}
		episode, err := live.GetWorkEpisodeByRun(ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		return episode
	}
	finish := func(episode core.WorkEpisode, state core.WorkEpisodeState) {
		t.Helper()
		if err := live.SetEpisodePhase(ctx, episode.ID, state, "finished",
			"done", "", time.Time{}); err != nil {
			t.Fatal(err)
		}
	}
	finish(queue("COPS", "a"), core.EpisodeCompleted)
	finish(queue("COPS", "b"), core.EpisodeCompleted)
	finish(queue("COPS", "c"), core.EpisodeFailed)
	queue("COPS", "d") // still accepted: in flight, neither done nor failed
	finish(queue("CQUIET", "e"), core.EpisodeCompleted)
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	rolls, err := reader.ChannelRolls(ctx)
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]ChannelRoll{}
	for _, roll := range rolls {
		byID[roll.ID] = roll
	}
	if len(rolls) != 2 {
		t.Fatalf("rolls = %d, want one per channel that has work", len(rolls))
	}
	ops := byID["COPS"]
	if ops.Total != 4 || ops.Done != 2 || ops.Failed != 1 || ops.Other != 1 {
		t.Fatalf("COPS = %+v, want 4 total split 2 done, 1 failed, 1 other", ops)
	}
	if ops.InFlight != 1 {
		t.Fatalf("COPS in flight = %d, want the unfinished episode counted", ops.InFlight)
	}
	for _, roll := range rolls {
		if width := roll.DoneW + roll.FailedW + roll.OtherW; width != 100 {
			t.Fatalf("%s bar spans %d units, want the segments to tile exactly", roll.ID, width)
		}
		if roll.FailedX != roll.DoneW || roll.OtherX != roll.DoneW+roll.FailedW {
			t.Fatalf("%s segments overlap or leave a gap: %+v", roll.ID, roll)
		}
	}
}

// A count that is real must not round away to nothing, and the bar must still
// add up: one failure among a thousand successes is the row an operator is
// looking for.
func TestOutcomeWidthsKeepSmallSharesVisible(t *testing.T) {
	done, failed, other := outcomeWidths(999, 1, 0)
	if failed == 0 {
		t.Fatal("a real failure rounded away to nothing")
	}
	if done+failed+other != 100 {
		t.Fatalf("widths = %d+%d+%d, want 100", done, failed, other)
	}
	if done, failed, other = outcomeWidths(0, 0, 0); done+failed+other != 0 {
		t.Fatalf("empty channel drew %d+%d+%d units", done, failed, other)
	}
}

// A schedule's own page exists to answer "did it actually run", so the
// executions have to reach it and each one has to lead back to the episode it
// produced. The list deliberately hides expired schedules while the detail
// page still opens them: an execution from last week is a real record, and
// following it to a page claiming the schedule never existed would be a lie
// about history.
func TestSchedulePagesListRunsAndOpenExpiredSchedules(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	migrated, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := migrated.Close(); err != nil {
		t.Fatal(err)
	}
	// Seeded through raw SQL against the real migrated schema: schedules are
	// created by the Slack confirmation flow, and reaching that from a reader
	// test would exercise everything except what is under test here.
	live, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	insert := func(id, title, expires string) {
		t.Helper()
		if _, err := live.ExecContext(ctx, `
			INSERT INTO scheduled_tasks (
			  id, team_id, channel_id, repository, title, prompt, recurrence,
			  start_at, local_time, timezone, enabled, actor_id, source_ref,
			  next_run_at, expires_at, created_at, updated_at
			) VALUES (?, 'T1', 'COPS', 'repo', ?, 'check the thing', 'daily',
			  '2026-01-01T09:00:00.000000000Z', '09:00', 'UTC', 1, 'U1', 'ref-'||?,
			  '2027-01-01T09:00:00.000000000Z', ?,
			  '2026-01-01T00:00:00.000000000Z', '2026-01-01T00:00:00.000000000Z')`,
			id, title, id, expires); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	insert("sched-live", "Daily health review", "2099-01-01T00:00:00.000000000Z")
	insert("sched-gone", "Retired review", "2020-01-01T00:00:00.000000000Z")
	if _, err := live.ExecContext(ctx, `
		INSERT INTO scheduled_task_runs (
		  task_id, scheduled_for, outcome, episode_id, started_at, completed_at,
		  created_at, updated_at
		) VALUES
		  ('sched-live', '2026-06-01T09:00:00.000000000Z', 'completed', 'episode_x',
		   '2026-06-01T09:00:00.000000000Z', '2026-06-01T09:04:00.000000000Z',
		   '2026-06-01T09:00:00.000000000Z', '2026-06-01T09:04:00.000000000Z'),
		  ('sched-live', '2026-06-02T09:00:00.000000000Z', 'skipped_overlap', '',
		   NULL, NULL,
		   '2026-06-02T09:00:00.000000000Z', '2026-06-02T09:00:00.000000000Z')`,
	); err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	listed, err := reader.Schedules(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].ID != "sched-live" {
		t.Fatalf("list = %+v, want only the schedule that can still fire", listed)
	}
	if listed[0].Cadence != "daily at 09:00 UTC" || listed[0].Runs != 2 {
		t.Fatalf("list row = %+v, want the human cadence and its run count", listed[0])
	}
	// The expired one is absent from the list and still has a page.
	gone, found, err := reader.Schedule(ctx, "sched-gone")
	if err != nil || !found || gone.Title != "Retired review" {
		t.Fatalf("expired schedule = %+v found=%t err=%v", gone, found, err)
	}
	if _, found, err := reader.Schedule(ctx, "sched-missing"); err != nil || found {
		t.Fatalf("unknown id reported found=%t err=%v", found, err)
	}

	runs, err := reader.ScheduleRuns(ctx, "sched-live", 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 2 {
		t.Fatalf("runs = %d, want both firings", len(runs))
	}
	// Newest first, so the page opens on what happened last.
	if runs[0].Outcome != "skipped_overlap" || runs[1].Outcome != "completed" {
		t.Fatalf("runs are not newest first: %+v", runs)
	}
	if runs[1].EpisodeID != "episode_x" || runs[1].Took() != "4m 00s" {
		t.Fatalf("completed run = %+v, want its episode and duration", runs[1])
	}
	// A skipped firing never started, so it has no duration to report rather
	// than a zero one, and it says why in words.
	if runs[0].Took() != "" {
		t.Fatalf("skipped run reported a duration of %q", runs[0].Took())
	}
	if runs[0].Reads() != "skipped, still running" {
		t.Fatalf("outcome reads %q, want the stored token in words", runs[0].Reads())
	}
}

// The correction queue is grouped by the complaint, because seventy-one
// candidates were thirty-seven complaints and the commonest was eight copies
// of one habit. A reviewer who ruled on one copy used to meet the same words
// again four rows later with no sign they had already decided.
func TestCorrectionsGroupByComplaintAndFlagHostFaults(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	migrated, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := migrated.Close(); err != nil {
		t.Fatal(err)
	}
	live, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	add := func(id, episode, text, class, created string) {
		t.Helper()
		if _, err := live.ExecContext(ctx, `
			INSERT INTO fixture_candidates (
			  id, episode_id, run_id, capability, correction_class, correction,
			  status, reviewed_by, created_at, expires_at, updated_at
			) VALUES (?, ?, 'run_1', '', ?, ?, 'pending', '', ?, ?, ?)`,
			id, episode, class, text, created, created, created); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	repeated := "the alert reply has no alert_assessment; continue the read-only investigation"
	add("c1", "ep_1", repeated, "incomplete", "2026-08-10T09:00:00.000000000Z")
	add("c2", "ep_2", repeated, "incomplete", "2026-08-11T09:00:00.000000000Z")
	add("c3", "ep_3", repeated, "incomplete", "2026-08-12T09:00:00.000000000Z")
	add("c4", "ep_4", `the structured Slack response is invalid: unknown evidence field "source_ref"`,
		"unreadable", "2026-08-11T10:00:00.000000000Z")
	add("c5", "ep_5", "required claims still contain unresolved contradictions: change.recent",
		"incomplete", "2026-08-12T10:00:00.000000000Z")
	add("c6", "ep_6", "rewrite this recovered-alert update as a compact closure",
		"incomplete", "2026-08-12T11:00:00.000000000Z")
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	groups, err := reader.Corrections(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 4 {
		t.Fatalf("groups = %d, want six candidates collapsed to four complaints", len(groups))
	}
	// Commonest first: a complaint earned three times is one habit worth one
	// test, and it should be the first thing a reviewer sees.
	if groups[0].Count != 3 || len(groups[0].IDs) != 3 {
		t.Fatalf("first group = %+v, want the three-copy complaint", groups[0])
	}
	if groups[0].IDList() != "c3,c2,c1" {
		t.Fatalf("group ids = %q, want every copy so one decision settles them all", groups[0].IDList())
	}
	if len(groups[0].Episodes) != 3 {
		t.Fatalf("group kept %d episodes, want each copy reachable", len(groups[0].Episodes))
	}
	// The span says whether a habit is old news or still happening.
	if groups[0].First.After(groups[0].Last) {
		t.Fatalf("group span is inverted: %+v", groups[0])
	}
	byText := map[string]CorrectionGroup{}
	for _, group := range groups {
		byText[group.Text] = group
	}
	// An unreadable answer is a fact; a prose critique is an argument. The
	// difference decides whether a test is cheap or brittle.
	if kind := byText[`the structured Slack response is invalid: unknown evidence field "source_ref"`].Kind; kind != "unreadable input" {
		t.Fatalf("invented field name classified as %q", kind)
	}
	if kind := byText["rewrite this recovered-alert update as a compact closure"].Kind; kind != "judgment" {
		t.Fatalf("prose critique classified as %q", kind)
	}
	if kind := byText[repeated].Kind; kind != "contract rule" {
		t.Fatalf("contract precondition classified as %q", kind)
	}
	// The one that must never be promoted silently.
	contradiction := byText["required claims still contain unresolved contradictions: change.recent"]
	if contradiction.Caution == "" {
		t.Fatal("a correction from the contradiction gate carried no warning")
	}
	if byText[repeated].Caution != "" {
		t.Fatalf("an ordinary complaint was flagged as a host fault: %q", byText[repeated].Caution)
	}
}

// The workspaces page exists to say what the checkouts cost, so the two
// numbers it is built on have to be right: what a size reads as, and which
// directories no live session owns.
func TestWorkspaceDiskNamesSizesAndOrphans(t *testing.T) {
	for _, testCase := range []struct {
		bytes int64
		want  string
	}{
		{0, "0 B"}, {512, "1 KB"}, {5 << 20, "5 MB"}, {2 << 30, "2.0 GB"},
	} {
		if got := HumanBytes(testCase.bytes); got != testCase.want {
			t.Fatalf("HumanBytes(%d) = %q, want %q", testCase.bytes, got, testCase.want)
		}
	}

	root := t.TempDir()
	for name, size := range map[string]int{"live_1": 2048, "gone_1": 4096} {
		if err := os.MkdirAll(filepath.Join(root, name), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(
			filepath.Join(root, name, "blob"), make([]byte, size), 0o600,
		); err != nil {
			t.Fatal(err)
		}
	}
	reader := &Reader{}
	// A checkout is an orphan when no live session claims it, which is why the
	// live list has to be measured against the disk rather than assumed equal
	// to it: an open session may hold no directory at all, because Coop builds
	// one on first use.
	disk := reader.Disk(context.Background(), root, []Workspace{{ID: "live_1"}})
	if !disk.Available {
		t.Fatal("a readable directory reported no measurement")
	}
	if len(disk.Orphans) != 1 || disk.Orphans[0].SessionID != "gone_1" {
		t.Fatalf("orphans = %+v, want only the checkout with no live session", disk.Orphans)
	}
	if disk.Total < 6144 {
		t.Fatalf("total = %d, want every checkout counted including the orphan", disk.Total)
	}
	// A deployment with no Coop directory says so rather than reporting zero,
	// because "nothing held" and "could not look" are different answers.
	if absent := reader.Disk(context.Background(), filepath.Join(root, "nope"), nil); absent.Available {
		t.Fatal("a missing directory reported a measurement")
	}
}

// The turn budget section replaced a table fed by a slice nobody passed, so
// what matters is that it reads the measurement and says what it means — a
// section that renders is not the same as a section that is right.
func TestTurnBudgetReadsWhatWasCutAndWhy(t *testing.T) {
	// Under half the ceiling and still dropping layers. This is the state the
	// cap alone calls healthy and is not: the assembler is budgeting against
	// its own share of the prompt, so the transport's headroom is unreachable.
	thinned := TurnBudget{
		Cap: 256 << 10, Turns: 144, Thinned: 92,
		Largest: 113718, Typical: 65231,
	}
	if thinned.Healthy() {
		t.Fatal("a budget dropping context on most turns reported healthy")
	}
	if got := thinned.Fullest(); got != 43 {
		t.Fatalf("fullest = %d%%, want 43%%", got)
	}
	if !strings.Contains(thinned.Verdict(), "the cap is not what cut it") {
		t.Fatalf("verdict does not name the real cause: %q", thinned.Verdict())
	}

	roomy := TurnBudget{Cap: 256 << 10, Turns: 10, Largest: 1000, Typical: 900}
	if !roomy.Healthy() || !strings.Contains(roomy.Verdict(), "room to spare") {
		t.Fatalf("a budget that cut nothing did not read as healthy: %q", roomy.Verdict())
	}
	if empty := (TurnBudget{Cap: 1}); empty.Measured() || !strings.Contains(
		empty.Verdict(), "nothing to measure",
	) {
		t.Fatalf("an unmeasured budget claimed a measurement: %q", empty.Verdict())
	}

	// The transport's elision notes name the exact byte counts of the prompt
	// they cut, so counting them verbatim yields one row per turn and a list
	// that says nothing. They collapse to the one fact they share.
	reasons := decodeOmissions(`["the transport elided 4085 bytes from the middle of this 69621-byte prompt to fit","the transport elided 546 bytes from the middle of this 66082-byte prompt to fit","older channel messages were omitted to fit the turn"]`)
	if len(reasons) != 3 || reasons[0] != reasons[1] {
		t.Fatalf("transport elisions did not collapse to one reason: %q", reasons)
	}
	if decodeOmissions("[]") != nil || decodeOmissions("not json") != nil {
		t.Fatal("an empty or unreadable omission list produced reasons")
	}
}
