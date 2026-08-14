package selfreportstore_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/selfreport"
	"github.com/AndrewDryga/responder/internal/store/selfreportstore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

// The reported window is the week ending Monday 2026-08-10 09:00 UTC.
var (
	windowEnd   = time.Date(2026, 8, 10, 9, 0, 0, 0, time.UTC)
	windowStart = windowEnd.AddDate(0, 0, -7)
)

func stamp(t *testing.T, month time.Month, day, hour int) string {
	t.Helper()
	return time.Date(2026, month, day, hour, 0, 0, 0, time.UTC).Format(core.TimestampFormat)
}

// seedWeek writes one of everything the digest counts, plus a neighbour of each
// kind that it must not count: last week's corrections, a withdrawn reaction, a
// proposed knowledge statement, a finding somebody already acted on.
//
// Raw SQL rather than the service paths that normally write these rows. A
// digest assembled from the code that produced its own rows would agree with
// itself no matter what either of them did.
func seedWeek(t *testing.T, db *sql.DB) {
	t.Helper()
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := db.ExecContext(context.Background(), query, args...); err != nil {
			t.Fatalf("seed: %v\n%s", err, query)
		}
	}
	run := func(id string, month time.Month, day int) {
		t.Helper()
		at := stamp(t, month, day, 12)
		exec(`INSERT INTO agent_runs (
		        id, mode, conversation_key, source_kind, source_id, idempotency_key,
		        state, terminal_state, next_attempt_at, created_at, updated_at)
		      VALUES (?, 'triage', ?, 'slack', ?, ?, 'completed', 'completed', ?, ?, ?)`,
			id, id, id, id, at, at, at)
	}
	correction := func(id string, month time.Month, day int, detail string) {
		t.Helper()
		exec(`INSERT INTO audit_events (id, kind, actor_id, object_id, outcome, detail, created_at)
		      VALUES (?, 'result.correction', 'responder', '', 'shape', ?, ?)`,
			id, detail, stamp(t, month, day, 13))
	}
	// Four finished turns this week with two corrections; four the week before
	// with three. The rate fell, which is the one number the digest leads with.
	for index, day := range []int{4, 5, 6, 7} {
		run("run_this_"+string(rune('a'+index)), time.August, day)
	}
	for index, day := range []int{28, 29, 30, 31} {
		run("run_last_"+string(rune('a'+index)), time.July, day)
	}
	repeated := "the reply runs 180 words against a message of 4 words"
	correction("aud_this_a", time.August, 5, repeated)
	correction("aud_this_b", time.August, 6, repeated)
	correction("aud_last_a", time.July, 29, "an older correction")
	correction("aud_last_b", time.July, 30, "an older correction")
	correction("aud_last_c", time.July, 31, "an older correction")

	feedback := []struct{ id, source, sentiment, status string }{
		{"fb_1", "positive_reaction", "positive", "noted"},
		{"fb_2", "positive_reaction", "positive", "noted"},
		{"fb_3", "model_sentiment", "negative", "open"},
		{"fb_4", "positive_reaction", "positive", "withdrawn"},
	}
	for _, item := range feedback {
		exec(`INSERT INTO feedback_items (
		        id, workspace_id, channel_id, user_id, source, category, sentiment,
		        summary, context_json, status, created_at, updated_at)
		      VALUES (?, 'T1', 'C0CHAN', 'U1', ?, 'other', ?, 'seeded', '[]', ?, ?, ?)`,
			item.id, item.source, item.sentiment, item.status,
			stamp(t, time.August, 6, 14), stamp(t, time.August, 6, 14))
	}

	memory := func(channelID string, at string, state core.AgentMemory) {
		t.Helper()
		encoded, err := json.Marshal(state)
		if err != nil {
			t.Fatal(err)
		}
		exec(`INSERT INTO conversation_memories (channel_id, thread_ts, repository, state_json, updated_at)
		      VALUES (?, '', 'repo', ?, ?)`, channelID, string(encoded), at)
	}
	// Two rooms learned one thing each, a day apart, so "newest" has a meaning
	// the ordering has to get right.
	memory("C0LEARN", stamp(t, time.August, 6, 15), core.AgentMemory{
		Knowledge: []core.KnowledgeItem{
			{Subject: "alerts", Statement: "Checkout alerts route to payments.", Status: "accepted"},
			{Subject: "guess", Statement: "The cache may be cold.", Status: "proposed"},
		},
	})
	memory("C0LEARN2", stamp(t, time.August, 7, 15), core.AgentMemory{
		Knowledge: []core.KnowledgeItem{
			{Subject: "symbols", Statement: "Symbols upload through WIF.", Status: "accepted"},
		},
	})
	// Nine days untouched at the end of the window, so its loop is forgotten
	// work rather than work in progress.
	memory("C0LOOPS", stamp(t, time.August, 1, 9), core.AgentMemory{
		OpenLoops: []string{"confirm the migration ran"},
	})

	finding := func(id, disposition, severity, summary string, day int) {
		t.Helper()
		exec(`INSERT INTO quality_findings (
		        id, run_id, episode_ids, channel_id, verdict, disposition, severity,
		        summary, created_at)
		      VALUES (?, '', '[]', 'C0BAD', 'confirmed', ?, ?, ?, ?)`,
			id, disposition, severity, summary, stamp(t, time.August, day, 16))
	}
	finding("qw_low", "recorded", "low", "Used a stale channel name.", 5)
	finding("qw_high", "recorded", "high",
		"Reported the deploy as verified without checking the rollout.", 7)
	finding("qw_done", "integrated", "critical", "Already fixed and deployed.", 7)
}

// Every number the digest states is a row count, so every number has to be
// reproducible from seeded rows. This is the test that makes that checkable —
// and it is the whole reason the digest is composed host-side: a model
// summarising the same tables would produce a paragraph nobody can verify.
func TestTheDigestCountsEverySectionFromWhatTheTablesHold(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	seedWeek(t, db)
	week, err := selfreportstore.New(db).Gather(ctx, windowStart, windowEnd)
	if err != nil {
		t.Fatal(err)
	}
	if week.This != (selfreport.Corrections{Turns: 4, Total: 2}) {
		t.Errorf("this week = %+v, want 4 turns and 2 corrections", week.This)
	}
	if week.Previous != (selfreport.Corrections{Turns: 4, Total: 3}) {
		t.Errorf("last week = %+v, want 4 turns and 3 corrections", week.Previous)
	}
	if week.TopCorrectionCount != 2 ||
		!strings.Contains(week.TopCorrection, "180 words") {
		t.Errorf("top correction = %q x%d", week.TopCorrection, week.TopCorrectionCount)
	}
	// The withdrawn reaction is a retraction, not praise.
	if week.Feedback != (selfreport.Feedback{Positive: 2, Negative: 1, Reactions: 2}) {
		t.Errorf("feedback = %+v", week.Feedback)
	}
	// A proposed statement is not something learned.
	if week.Knowledge.Count != 2 ||
		week.Knowledge.Newest[0] != "Symbols upload through WIF." {
		t.Errorf("knowledge = %+v", week.Knowledge)
	}
	if len(week.OpenLoops) != 1 || week.OpenLoops[0].ChannelID != "C0LOOPS" ||
		week.OpenLoops[0].IdleDays != 9 ||
		week.OpenLoops[0].Loops[0] != "confirm the migration ran" {
		t.Errorf("open loops = %+v", week.OpenLoops)
	}
	// Severity picks the worst; an integrated finding is somebody's decision
	// already and reporting it asks the team to decide it twice.
	if week.Worst == nil || week.Worst.ID != "qw_high" {
		t.Errorf("worst answer = %+v", week.Worst)
	}

	body := selfreport.Render(week)
	for _, want := range []string{
		"50%", "down from 75%", "2 of 4 finished turns",
		"the reply runs 180 words", "2 times",
		"2 positive, 1 negative", "2 of them reactions",
		"Learned 2 things", "Symbols upload through WIF.",
		"<#C0LOOPS>", "9 days", "confirm the migration ran",
		"high severity", "Reported the deploy as verified", "qw_high",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("digest is missing %q:\n%s", want, body)
		}
	}
	for _, unwanted := range []string{
		"an older correction", "The cache may be cold",
		"Already fixed", "Used a stale channel",
	} {
		if strings.Contains(body, unwanted) {
			t.Errorf("digest reported %q, which is outside the week it claims:\n%s", unwanted, body)
		}
	}
}

// A section that vanishes when it is empty reads as a good week.
func TestAnEmptyWeekStillRendersEverySection(t *testing.T) {
	week, err := selfreportstore.New(storetest.DB(t)).
		Gather(context.Background(), windowStart, windowEnd)
	if err != nil {
		t.Fatal(err)
	}
	body := selfreport.Render(week)
	for _, want := range []string{
		"nothing can be concluded", "Feedback: none",
		"Learned: nothing", "Open loops: none", "Worst answer: no confirmed",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("an empty week dropped %q:\n%s", want, body)
		}
	}
}

// The send is recorded as the occurrence it satisfied rather than the wall
// clock it was posted at, so a sweep a minute later compares against the same
// boundary the scheduler does.
func TestTheRecordedSendIsTheOccurrenceItSatisfied(t *testing.T) {
	ctx := context.Background()
	repository := selfreportstore.New(storetest.DB(t))
	sent, err := repository.LastSent(ctx)
	if err != nil || !sent.IsZero() {
		t.Fatalf("a database that never sent reported %s, %v", sent, err)
	}
	if err := repository.MarkSent(ctx, windowEnd); err != nil {
		t.Fatal(err)
	}
	sent, err = repository.LastSent(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !sent.Equal(windowEnd) {
		t.Fatalf("recorded send = %s, want %s", sent, windowEnd)
	}
	if err := repository.MarkSent(ctx, windowEnd.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if sent, _ = repository.LastSent(ctx); !sent.Equal(windowEnd.AddDate(0, 0, 7)) {
		t.Fatalf("a second send did not replace the first: %s", sent)
	}
}
