package webui

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/store"
)

// everyFilterTerm exercises every episode-list predicate at once, so a column
// renamed under one of them cannot hide behind the others that still parse.
var everyFilterTerm = EpisodeFilter{
	Channel: "C1", Repository: "tenant-platform", Mode: "triage",
	Provider: "anthropic", Model: "claude-opus-4-5",
	Query: "checkout 100%", State: "failed", Offset: 10,
}

// everyAuditTerm does the same for the audit drill-down's predicates.
var everyAuditTerm = AuditFilter{
	Kind: "slack.watch", Actor: "U1", Since: time.Now().UTC(), Offset: 100,
}

// Every read runs against the real schema, not against a nil database.
//
// The episode page selected evidence `WHERE episode_id = ?` from a table that
// has never had that column. It errored on every episode in production, the
// handler discarded the error, and the page reported "No evidence was recorded"
// above nineteen recorded observations. Every test in this package pointed a
// Reader at no database at all, so every query short-circuited before SQLite
// ever saw it and the whole class was invisible. This opens a migrated database
// and makes SQLite parse each one.
func TestEveryQueryRunsAgainstTheMigratedSchema(t *testing.T) {
	reader := migratedReader(t)
	ctx := context.Background()
	window := chosenWindow(UsageWindows("30d", time.Now().UTC()))
	checks := map[string]func() error{
		"Blocked":             func() error { _, err := reader.Blocked(ctx, 5); return err },
		"Channel":             func() error { _, _, err := reader.Channel(ctx, "C1"); return err },
		"KnownChannels":       func() error { _, err := reader.KnownChannels(ctx); return err },
		"Schedules":           func() error { _, err := reader.Schedules(ctx); return err },
		"Preferences":         func() error { _, err := reader.Preferences(ctx); return err },
		"StandingRules":       func() error { _, err := reader.StandingRules(ctx); return err },
		"Episodes":            func() error { _, err := reader.Episodes(ctx, 5); return err },
		"Episode":             func() error { _, err := reader.Episode(ctx, "ep"); return err },
		"EpisodesForChannel":  func() error { _, err := reader.EpisodesForChannel(ctx, "C1", 5); return err },
		"EpisodesForIncident": func() error { _, err := reader.EpisodesForIncident(ctx, "inc"); return err },
		"Events":              func() error { _, err := reader.Events(ctx, "ep"); return err },
		"Turn":                func() error { _, err := reader.Turn(ctx, "ep"); return err },
		"Claims":              func() error { _, err := reader.Claims(ctx, "ep"); return err },
		"Evidence":            func() error { _, err := reader.Evidence(ctx, "ep"); return err },
		"Coverage":            func() error { _, err := reader.Coverage(ctx, "ep"); return err },
		"Manifest":            func() error { _, err := reader.Manifest(ctx, "ep"); return err },
		"Attempts":            func() error { _, err := reader.Attempts(ctx, "ep"); return err },
		"Deliveries":          func() error { _, err := reader.Deliveries(ctx, "ep"); return err },
		"Failures":            func() error { _, err := reader.Failures(ctx); return err },
		"FailureRuns":         func() error { _, err := reader.FailureRuns(ctx, "boom"); return err },
		"RetainedWorkspaces":  func() error { _, _, err := reader.RetainedWorkspaces(ctx); return err },
		"EpisodeStates":       func() error { _, err := reader.EpisodeStates(ctx); return err },
		"AuditOfKindFiltered": func() error {
			_, err := reader.AuditOfKindFiltered(ctx, everyAuditTerm)
			return err
		},
		"CountAuditOfKind": func() error {
			_, err := reader.CountAuditOfKind(ctx, everyAuditTerm)
			return err
		},
		"Corrections":       func() error { _, err := reader.Corrections(ctx); return err },
		"Feedback":          func() error { _, err := reader.Feedback(ctx); return err },
		"ChannelMemory":     func() error { _, err := reader.ChannelMemory(ctx); return err },
		"Channels":          func() error { _, err := reader.Channels(ctx); return err },
		"MemoryEntries":     func() error { _, err := reader.MemoryEntries(ctx); return err },
		"Rollups":           func() error { _, err := reader.Rollups(ctx); return err },
		"Conversations":     func() error { _, err := reader.Conversations(ctx); return err },
		"MemoryReview":      func() error { _, err := reader.MemoryReview(ctx); return err },
		"Conversation":      func() error { _, err := reader.Conversation(ctx, "C1", "channel"); return err },
		"Rooms":             func() error { _, err := reader.Rooms(ctx); return err },
		"Signals":           func() error { _, err := reader.Signals(ctx, "inc"); return err },
		"Moments":           func() error { _, err := reader.Moments(ctx, "inc"); return err },
		"Publication":       func() error { _, err := reader.Publication(ctx, "inc"); return err },
		"Lanes":             func() error { _, err := reader.Lanes(ctx); return err },
		"AuditKinds":        func() error { _, err := reader.AuditKinds(ctx); return err },
		"AuditRecent":       func() error { _, err := reader.AuditRecent(ctx, 10); return err },
		"AuditOfKind":       func() error { _, err := reader.AuditOfKind(ctx, "slack.watch"); return err },
		"AuditForEpisode":   func() error { _, err := reader.AuditForEpisode(ctx, "ep"); return err },
		"AuditForIncident":  func() error { _, err := reader.AuditForIncident(ctx, "inc"); return err },
		"UsageTotals":       func() error { _, err := reader.UsageTotals(ctx, window); return err },
		"UsageTrend":        func() error { _, err := reader.UsageTrend(ctx, window); return err },
		"UsageByModel":      func() error { _, err := reader.UsageByModel(ctx, window); return err },
		"UsageByChannel":    func() error { _, err := reader.UsageByChannel(ctx, window); return err },
		"UsageByRepository": func() error { _, err := reader.UsageByRepository(ctx, window); return err },
		"UsageByKind":       func() error { _, err := reader.UsageByKind(ctx, window); return err },
		"EpisodeTokens":     func() error { _, err := reader.EpisodeTokens(ctx, "ep"); return err },
		"EpisodesMatching": func() error {
			_, err := reader.EpisodesMatching(ctx, everyFilterTerm, 5)
			return err
		},
		"CountMatching": func() error { _, err := reader.CountMatching(ctx, everyFilterTerm); return err },
	}
	for name, run := range checks {
		// A missing row is the ordinary answer for an empty database; a missing
		// column is the defect this test exists for.
		if err := run(); err != nil && !errors.Is(err, sql.ErrNoRows) {
			t.Errorf("%s does not run against the real schema: %v", name, err)
		}
	}
}

// A counter cannot report a failure: Count returns zero when the query breaks,
// and zero on this dashboard means "none". "Failed work: 0" over a broken query
// is the same lie as "No failed work" over ninety-eight of them, and quieter.
func TestEveryCounterRunsAgainstTheMigratedSchema(t *testing.T) {
	reader := migratedReader(t)
	for _, counted := range []struct {
		query string
		args  []any
	}{
		{countNeedsDecision, nil}, {countFailedRuns, nil}, {countInFlight, nil},
		{countRetained, nil}, {countCleanupDone, nil}, {countEpisodes, nil},
		{countTerminalRuns, nil}, {countCorrections, []any{"unreadable"}},
		{countAudited, nil}, {countAuditKind, []any{"slack.watch"}},
	} {
		var count int
		err := reader.db.QueryRowContext(context.Background(), counted.query, counted.args...).Scan(&count)
		if err != nil {
			t.Errorf("counter does not run: %v\n%s", err, counted.query)
		}
	}
}

// Every page renders against the real schema, templates included. A template
// that names a field the handler stopped passing fails at execute time, which
// no compile catches.
func TestEveryPageRendersAgainstTheMigratedSchema(t *testing.T) {
	reader := migratedReader(t)
	handler, err := NewHandler(reader, "test", "47", "responder-abc", nil, nil, config.Pricing{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	for _, path := range []string{
		"/", "/episodes", "/failures", "/workspaces", "/decisions", "/audit", "/memory",
		"/configuration", "/usage",
	} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusOK {
			t.Errorf("GET %s = %d: %s", path, recorder.Code, recorder.Body.String())
			continue
		}
		if strings.Contains(recorder.Body.String(), "Could not load") {
			t.Errorf("GET %s reports a failed query against an empty but valid database", path)
		}
	}
}

// Recurring scheduler drains are infrastructure, not a backlog. They normally
// wait in the pending state between polls, so presenting them as pending tasks
// made an idle Responder look stuck. Finite work remains visible separately.
func TestLanesSeparatePollersFromActualWork(t *testing.T) {
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "responder.db")
	writable, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	insert := func(kind, subject, state string, failures int, available time.Time, detail string) {
		t.Helper()
		_, err := writable.Exec(`INSERT INTO work_items
		  (kind, subject_id, lane, conversation_key, priority, state, failure_count,
		   available_at, lease_token, last_error, created_at, updated_at)
		  VALUES (?, ?, 'background', '', 50, ?, ?, ?, '', ?, ?, ?)`,
			kind, subject, state, failures, available.Format(time.RFC3339Nano), detail,
			now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano))
		if err != nil {
			t.Fatal(err)
		}
	}
	insert("agent_run", "drain", "pending", 0, now.Add(time.Second), "")
	insert("agent_run", "drain-2", "pending", 0, now.Add(time.Second), "")
	insert("episode_recheck", "ready-work", "pending", 0, now.Add(-time.Minute), "")
	insert("emisar_approval", "scheduled-work", "pending", 2, now.Add(time.Hour), "temporary failure")
	insert("episode_recheck", "running-work", "running", 0, now, "")
	insert("episode_recheck", "failed-work", "failed", 3, now, "permanent failure")
	if err := writable.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	lanes, err := reader.Lanes(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(lanes) != 1 {
		t.Fatalf("got %d lanes, want 1", len(lanes))
	}
	lane := lanes[0]
	if lane.Pollers != 2 || lane.Ready != 1 || lane.Running != 1 ||
		lane.Scheduled != 1 || lane.Failed != 1 {
		t.Errorf("lane counts = %+v", lane)
	}
	if lane.Retrying != 2 || lane.RetryAttempts != 5 {
		t.Errorf("retry counts = %d items / %d attempts, want 2 / 5", lane.Retrying, lane.RetryAttempts)
	}
	if lane.Status != "failed" || lane.Error != "temporary failure" && lane.Error != "permanent failure" {
		t.Errorf("lane status = %q, error = %q", lane.Status, lane.Error)
	}

	handler, err := NewHandler(reader, "test", "47", "responder-abc", nil, nil, config.Pricing{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("overview = %d: %s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	if !strings.Contains(body, "not queued tasks") || strings.Contains(body, ">Pending<") {
		t.Errorf("overview still presents pollers as pending tasks: %s", body)
	}
	if strings.Contains(body, ">never<") {
		t.Errorf("an empty next-work cell is presented as an event that never happens: %s", body)
	}
}

func TestOverviewShowsScheduledTasksAsUpcomingWork(t *testing.T) {
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	stamp := func(value time.Time) string { return value.Format(time.RFC3339Nano) }
	_, err = db.Exec(`INSERT INTO scheduled_tasks (
	  id, team_id, channel_id, thread_ts, delivery_channel_id, repository, title, prompt,
	  recurrence, start_at, interval_seconds, weekdays_json, day_of_month, local_time,
	  timezone, catch_up, enabled, actor_id, source_ref, next_run_at, last_run_at,
	  last_outcome, expires_at, created_at, updated_at
	) VALUES ('schedule-1','T1','C1','','C1','tenant-infra','Daily platform health review',
	  'Check production health','daily',?,0,'[]',0,'09:00','America/Mexico_City',
	  'latest',1,'U1','slack:C1:1',?,?,'completed',?,?,?)`,
		stamp(now), stamp(now.Add(20*time.Hour)), stamp(now.Add(-4*time.Hour)),
		stamp(now.Add(90*24*time.Hour)), stamp(now), stamp(now))
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	handler, err := NewHandler(reader, "test", "47", "responder-abc", nil, nil, config.Pricing{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	body := recorder.Body.String()
	for _, expected := range []string{
		"Scheduled tasks", "Daily platform health review", "daily at 09:00 America/Mexico_City",
		"Next in 19h", "Last completed 4h ago", "/responder schedules",
	} {
		if !strings.Contains(body, expected) {
			t.Errorf("overview is missing %q: %s", expected, body)
		}
	}
	if strings.Contains(body, "Next just now") {
		t.Errorf("future schedule is presented as current: %s", body)
	}
}

// migratedReader opens the dashboard against a database the store itself
// created, so the columns are the ones production has rather than the ones a
// fixture guessed at.
func migratedReader(t *testing.T) *Reader {
	t.Helper()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	return reader
}

// A channel id embedded in stored free text is resolved too, not just the ones
// in their own column.
//
// An audit detail reading "channel=C0TENANTX01 participation=proactive" says
// which setting changed and not which channel it changed for, and a publication
// note citing "Slack message C0TENANTOPS/1785885550.501459" is a coordinate
// nobody can read. An id with no known name is left alone: rewriting it as
// "#C0TENANTX01" would dress a failed lookup as a resolved one.
func TestChannelIDsInFreeTextResolveToNames(t *testing.T) {
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "responder.db")
	writable, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = writable.Exec(`INSERT INTO slack_channel_memberships
	  (channel_id, channel_name, observed_at) VALUES ('C0TENANTOPS','backend-ops','now')`)
	if err != nil {
		t.Fatal(err)
	}
	if err := writable.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	ctx := context.Background()
	detail := "Correlated from Slack message C0TENANTOPS/1785885550.501459 and C0TENANTX01"
	got := reader.resolveChannels(ctx, detail)
	if !strings.Contains(got, "#backend-ops/1785885550.501459") {
		t.Errorf("a known channel id was not resolved: %q", got)
	}
	if !strings.Contains(got, "C0TENANTX01") || strings.Contains(got, "#C0TENANTX01") {
		t.Errorf("an unknown id was dressed up as resolved: %q", got)
	}
	// Second call comes from the cache the earlier code only claimed to have.
	if again := reader.resolveChannels(ctx, detail); again != got {
		t.Errorf("cached lookup disagreed with the first: %q then %q", got, again)
	}
}
