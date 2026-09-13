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

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store"
)

// everyFilterTerm exercises every episode-list predicate at once, so a column
// renamed under one of them cannot hide behind the others that still parse.
var everyFilterTerm = EpisodeFilter{
	Channel: "C1", Repository: "blitz-platform", Mode: "triage",
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
		"Findings":            func() error { _, err := reader.Findings(ctx, 0); return err },
		"Channel":             func() error { _, _, err := reader.Channel(ctx, "C1"); return err },
		"KnownChannels":       func() error { _, err := reader.KnownChannels(ctx); return err },
		"Schedules":           func() error { _, err := reader.Schedules(ctx); return err },
		"Preferences":         func() error { _, err := reader.Preferences(ctx); return err },
		"StandingRules":       func() error { _, err := reader.StandingRules(ctx); return err },
		"StandingAssignments": func() error { _, err := reader.StandingAssignments(ctx); return err },
		"Episodes":            func() error { _, err := reader.Episodes(ctx, 5); return err },
		"Episode":             func() error { _, err := reader.Episode(ctx, "ep"); return err },
		"EpisodesForChannel":  func() error { _, err := reader.EpisodesForChannel(ctx, "C1", 5); return err },
		"EpisodesForIncident": func() error { _, err := reader.EpisodesForIncident(ctx, "inc"); return err },
		"Events":              func() error { _, err := reader.Events(ctx, "ep"); return err },
		"Turn":                func() error { _, err := reader.Turn(ctx, "ep"); return err },
		"Claims":              func() error { _, err := reader.Claims(ctx, "ep"); return err },
		"Evidence":            func() error { _, err := reader.Evidence(ctx, "ep"); return err },
		"Coverage":            func() error { _, err := reader.Coverage(ctx, "ep"); return err },
		"ContextArtifact":     func() error { _, _, err := reader.ContextArtifact(ctx, "digest"); return err },
		"StoredArtifacts":     func() error { _, err := reader.StoredArtifactDigests(ctx, []string{"digest"}); return err },
		"Manifest":            func() error { _, err := reader.Manifest(ctx, "ep"); return err },
		"Attempts":            func() error { _, err := reader.Attempts(ctx, "ep"); return err },
		"Deliveries":          func() error { _, err := reader.Deliveries(ctx, "ep"); return err },
		"SideEffects":         func() error { _, err := reader.SideEffects(ctx, "ep"); return err },
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
		"AuditionLanes": func() error {
			_, err := reader.AuditionLanes(ctx, time.Now().UTC().AddDate(0, 0, -7))
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
		{countNeedsDecision, nil}, {countFailedRuns, nil}, {countFailedToday, nil}, {countInFlight, nil},
		{countRetained, nil}, {countCleanupDone, nil}, {countEpisodes, nil},
		{countTerminalRuns, nil}, {countCorrections, []any{"unreadable"}},
		{countAudited, nil}, {countAuditKind, []any{"slack.watch"}},
		{countFeedbackSentiment, []any{"positive"}},
		{countFindings, nil}, {countConfirmedFindings, nil},
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
	handler, err := NewHandler(reader, "test", "47", "ryker-abc", nil, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	for _, path := range []string{
		"/", "/episodes", "/failures", "/workspaces", "/decisions", "/findings",
		"/audit", "/memory", "/configuration", "/usage",
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
// made an idle Ryker look stuck. Finite work remains visible separately.
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

	handler, err := NewHandler(reader, "test", "47", "ryker-abc", nil, config.Pricing{}, nil, nil)
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
	if !strings.Contains(body, "not queued jobs") || strings.Contains(body, ">Pending<") {
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
	) VALUES ('schedule-1','T1','C1','','C1','blitz-infra','Daily platform health review',
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
	handler, err := NewHandler(reader, "test", "47", "ryker-abc", nil, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	body := recorder.Body.String()
	// The section is "Coming up" and each row leads with when it next runs,
	// so a schedule reads as an appointment rather than as a settings entry.
	// It hands off to the Schedules section rather than explaining how to make
	// one: the overview says what is coming, and the page it links to is where
	// a schedule's own history lives.
	// The dashboard row says "daily at 09:00" — the timezone is reference
	// material for the schedule's own page, not the glance.
	for _, expected := range []string{
		"Coming up", "Daily platform health review", "daily at 09:00",
		"in 19h", "last completed 4h ago", `href="/schedules/schedule-1"`, "every schedule →",
	} {
		if !strings.Contains(body, expected) {
			t.Errorf("overview is missing %q: %s", expected, body)
		}
	}
	if strings.Contains(body, "Next just now") {
		t.Errorf("future schedule is presented as current: %s", body)
	}
}

// The two pages that read what nothing read before.
//
// Configuration listed a standing rule's fire count and nothing else, which is
// the number that cannot answer "should I keep this": emisar's Terraform rule
// shows 64 fires and every outcome anyone kept was 'ignore'. Decisions listed
// praise in among the complaints under a heading about being told Ryker got
// something wrong, so the one signal saying an answer was worth copying was
// invisible in the list that contained it.
func TestConfigurationAndDecisionsReadWhatTheRuleAndThePraiseProduced(t *testing.T) {
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
	now := time.Now().UTC().Format(time.RFC3339Nano)
	later := time.Now().UTC().Add(30 * 24 * time.Hour).Format(time.RFC3339Nano)
	if _, err := db.Exec(`
		INSERT INTO standing_rules (
		  id, channel_id, repository, trigger_name, action_name, source_kind,
		  enabled, source_ref, actor_id, trigger_count, acted_count, quiet_count,
		  last_triggered_at, expires_at, created_at, updated_at
		) VALUES ('rule_idle', 'C1', 'repo', 'terraform_plan',
		  'review_terraform_plan', 'app', 1, 'slack_rule', 'U1', 64, 0, 12,
		  ?, ?, ?, ?);
		INSERT INTO feedback_items
		  (id, workspace_id, channel_id, user_id, source, category, sentiment,
		   summary, context_json, episode_id, status, created_at, updated_at)
		VALUES
		  ('fb_good', 'T1', 'C1', 'U1', 'positive_reaction', 'other', 'positive',
		   'User reacted positively to a Ryker message', ?, 'ep_praised',
		   'noted', ?, ?),
		  ('fb_bad', 'T1', 'C1', 'U1', 'model_sentiment', 'correctness', 'negative',
		   'that was the wrong repository', ?, '', 'open', ?, ?);
		INSERT INTO audit_events
		  (id, kind, actor_id, object_id, outcome, detail, created_at)
		VALUES
		  ('fixpromo_fixcand_2', 'fixture.promotion', 'ryker', 'fixcand_2',
		   'promoted', 'ep_2: assess the checkout rollout', ?),
		  ('fixpromo_fixcand_3', 'fixture.promotion', 'ryker', 'fixcand_3',
		   'quarantined',
		   'ep_3: another case in the corpus already answers to this name', ?);`,
		now, later, now, now, []byte("{}"), now, now, []byte("{}"), now, now,
		now, now,
	); err != nil {
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
	handler, err := NewHandler(reader, "test", "53", "ryker-abc", nil, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	render := func(path string) string {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		return recorder.Body.String()
	}

	// Configuration is the index. It carries the count and the one fact that
	// says whether the rules need attention; the rules themselves are a page.
	configuration := render("/configuration")
	for _, expected := range []string{"Standing rules", "1 firing but never acting"} {
		if !strings.Contains(configuration, expected) {
			t.Errorf("configuration does not show %q: %s", expected, configuration)
		}
	}

	rules := render("/rules")
	for _, expected := range []string{
		// The rule reads as a sentence, because that is how an operator holds
		// it in mind — not as two enum columns they have to translate.
		"When a Terraform plan is posted in C1 posted by an app, review the plan before it is applied.",
		"fired 64", "acted 0", "stayed quiet 12", "never acted",
		// A rule with fires and no actions is the row worth acting on, so it
		// is marked as such rather than sharing the state that says "enabled"
		// and stops there.
		`data-state="idle"`,
	} {
		if !strings.Contains(rules, expected) {
			t.Errorf("rules page does not show %q: %s", expected, rules)
		}
	}

	// The detail page exists for the question the counts cannot answer: what it
	// decided each time it fired.
	rule := render("/rules/rule_idle")
	for _, expected := range []string{"Firings", "has not matched anything on record"} {
		if !strings.Contains(rule, expected) {
			t.Errorf("rule page does not show %q: %s", expected, rule)
		}
	}

	decisions := render("/decisions")
	for _, expected := range []string{
		"What Ryker got right",
		"1 of 2 graded reactions were praise (50%)",
		"the answer they liked",
		"/episodes/ep_praised",
		// And the complaint stays in the complaints list.
		"that was the wrong repository",
		// A fixture the drain held back is on the page rather than only in a
		// log line. Automating promotion moves the human from admitting a
		// lesson to noticing one that did not make it, and this row is the
		// entire notification.
		"Kept corrections that promoted themselves",
		"held back",
		"already answers to this name",
		"/episodes/ep_3",
	} {
		if !strings.Contains(decisions, expected) {
			t.Errorf("decisions does not show %q: %s", expected, decisions)
		}
	}
	if strings.Contains(decisions, "Nobody has reacted positively") {
		t.Errorf("recorded praise is still reported as absent: %s", decisions)
	}
}

// A reader is only proven by a row, because an empty table never scans.
//
// TestEveryQueryRunsAgainstTheMigratedSchema makes SQLite parse each query, so
// it catches a column that does not exist. It cannot catch a SELECT and a Scan
// that disagree about how many columns there are: rows.Next() is false on an
// empty table, so the Scan never runs. The corrections queue shipped that way —
// five columns selected, six destinations passed — and the review surface the
// whole correction loop depends on returned an error on its first row, which
// the handler discarded, leaving an empty list beside a badge counting the rows
// it had failed to read.
//
// These two are seeded because they are the pair that page reads. The rest of
// the readers still need the same treatment; a generic seeder is the real fix.
func TestReadersScanTheColumnsTheySelect(t *testing.T) {
	reader := seededReader(t)
	ctx := context.Background()

	corrections, err := reader.Corrections(ctx)
	if err != nil {
		t.Fatalf("Corrections: %v", err)
	}
	// One group, because the queue is grouped by the complaint now, and it has
	// to carry the episode the complaint came from — a correction whose
	// episode is unreachable cannot be judged, only guessed at.
	if len(corrections) != 1 {
		t.Fatalf("Corrections returned %d groups, want 1", len(corrections))
	}
	if len(corrections[0].Episodes) != 1 || corrections[0].Episodes[0] != "ep_1" {
		t.Errorf("correction lost its episode: %+v", corrections[0])
	}
	if corrections[0].Count != 1 || len(corrections[0].IDs) != 1 {
		t.Errorf("a single correction did not group as one: %+v", corrections[0])
	}

	feedback, err := reader.Feedback(ctx)
	if err != nil {
		t.Fatalf("Feedback: %v", err)
	}
	if len(feedback) != 1 {
		t.Fatalf("Feedback returned %d rows, want 1", len(feedback))
	}

	// Held back first, and with the episode split out of the receipt: a
	// promotion nobody has to act on must not push the one that needs a person
	// off the top of the list.
	promotions, err := reader.Promotions(ctx)
	if err != nil {
		t.Fatalf("Promotions: %v", err)
	}
	if len(promotions) != 2 {
		t.Fatalf("Promotions returned %d rows, want 2", len(promotions))
	}
	if !promotions[0].Quarantined || promotions[0].Episode != "ep_3" ||
		!strings.HasPrefix(promotions[0].Detail, "another case") {
		t.Errorf("the held-back promotion did not read back: %+v", promotions[0])
	}
	if promotions[1].Quarantined || promotions[1].Candidate != "fixcand_2" {
		t.Errorf("the completed promotion did not read back: %+v", promotions[1])
	}

	entries, err := reader.MemoryEntries(ctx)
	if err != nil {
		t.Fatalf("MemoryEntries: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("MemoryEntries returned %d rows, want 1", len(entries))
	}
	if entries[0].Rewrites != 1 || entries[0].LastRewrite != "operator replacement" {
		t.Errorf("memory history was not read back: %+v", entries[0])
	}

	findings, err := reader.Findings(ctx, 0)
	if err != nil {
		t.Fatalf("Findings: %v", err)
	}
	if len(findings) != 1 {
		t.Fatalf("Findings returned %d rows, want 1", len(findings))
	}
	// The JSON columns are the part a Scan cannot prove on its own: they arrive
	// as text and are only a list once something decodes them, so a finding
	// whose evidence silently became empty would still scan cleanly.
	if !findings[0].Confirmed() || findings[0].Severity != "high" {
		t.Errorf("the challenger's verdict was not read back: %+v", findings[0])
	}
	if len(findings[0].Code) != 1 || len(findings[0].EpisodeIDs) != 1 {
		t.Errorf("the finding lost the evidence that makes it actionable: %+v", findings[0])
	}
}

// seededReader is migratedReader with one row in the tables the decisions page
// reads, written through raw SQL against the migrated schema so the columns are
// production's own.
func seededReader(t *testing.T) *Reader {
	t.Helper()
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
	now := time.Now().UTC().Format(time.RFC3339Nano)
	later := time.Now().UTC().Add(14 * 24 * time.Hour).Format(time.RFC3339Nano)
	for _, statement := range []struct {
		query string
		args  []any
	}{
		{`INSERT INTO fixture_candidates
		    (id, episode_id, run_id, correction_class, correction, status,
		     created_at, expires_at, updated_at)
		  VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
			[]any{"fixcand_1", "ep_1", "run_1", "unreadable",
				"the structured Slack response is invalid", now, later, now}},
		// One promotion the drain performed and one it held back. The held-back
		// row is the reason this page grew the section: the drain never retries
		// a quarantined candidate, so a lesson stopping there is invisible
		// everywhere else.
		{`INSERT INTO audit_events
		    (id, kind, actor_id, object_id, outcome, detail, created_at)
		  VALUES (?, 'fixture.promotion', 'ryker', 'fixcand_2', 'promoted', ?, ?)`,
			[]any{"fixpromo_fixcand_2", "ep_2: assess the checkout rollout", now}},
		{`INSERT INTO audit_events
		    (id, kind, actor_id, object_id, outcome, detail, created_at)
		  VALUES (?, 'fixture.promotion', 'ryker', 'fixcand_3', 'quarantined', ?, ?)`,
			[]any{"fixpromo_fixcand_3",
				"ep_3: another case in the corpus already answers to this name", now}},
		{`INSERT INTO feedback_items
		    (id, workspace_id, channel_id, user_id, source, category, sentiment,
		     summary, context_json, status, created_at, updated_at)
		  VALUES (?, 'T1', 'C1', 'U1', 'model_sentiment', 'correctness', 'negative',
		          'answer in thread, and make it durable', ?, 'open', ?, ?)`,
			[]any{"fb_1", []byte("{}"), now, now}},
		{`INSERT INTO memory_entries
		    (id, scope_kind, scope_key, subject_key, predicate, value_json,
		     value_hash, source_ref, actor_id, visibility_kind, visibility_id,
		     expires_at, created_at, updated_at)
		  VALUES (?, 'channel', 'C1', 'debug_symbols', 'guidance',
		          'GCS with WIF is the accepted direction.', 'hash1',
		          'feedback:fb_1', 'U1', 'channel', 'C1', ?, ?, ?)`,
			[]any{"mem_1", later, now, now}},
		{`INSERT INTO memory_supersessions
		    (id, entry_id, previous_value_hash, replacement_value_hash, reason, created_at)
		  VALUES (?, 'mem_1', 'hash0', 'hash1', 'operator replacement', ?)`,
			[]any{"memsup_1", now}},
		// Seventeen columns, written the way the quality watcher writes them:
		// arrays as JSON text, because that is what a shell script producing
		// them with jq can store and what the page renders whole.
		{`INSERT INTO quality_findings
		    (id, run_id, episode_ids, channel_id, verdict, disposition, severity,
		     summary, expected_behavior, evidence, code_evidence,
		     suspected_components, regression_test, challenger_summary,
		     challenger_evidence, artifacts, created_at)
		  VALUES (?, 'run_1', '["run_1"]', 'C1', 'confirmed', 'recorded', 'high',
		          'the watch reply claimed a deploy it never verified',
		          'it should say what it checked', '["reply_body said verified"]',
		          '["internal/service/watch.go: replyFromRun"]',
		          '["internal/service"]', 'a watch turn with no evidence must not claim one',
		          'the delivered body does assert it', '["internal/service/watch.go:220"]',
		          '/state/quality-watch/reviews/batch_1', ?)`,
			[]any{"batch_1", now}},
	} {
		if _, err := db.Exec(statement.query, statement.args...); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	return reader
}

// migratedReader opens the dashboard against a database the store itself
// created, so the columns are the ones production has rather than the ones a
// fixture guessed at.
// A retained artifact body serves as inert text with sniffing disabled, and a
// digest with no body answers with the styled miss rather than a bare 404.
func TestArtifactRouteServesRetainedBodiesAsInertText(t *testing.T) {
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Artifacts.Save(context.Background(), []core.ContextArtifact{{
		Digest: "digest-1", Name: "github-pr-529.md", MediaType: "text/markdown",
		Body: []byte("# PR 529\n\n<script>alert(1)</script>"),
	}}); err != nil {
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
	handler, err := NewHandler(reader, "test", "70", "ryker-abc",
		func() (bool, string) { return true, "" }, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)

	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/artifacts/digest-1", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("artifact = %d: %s", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Content-Type"); got != "text/plain; charset=utf-8" {
		t.Fatalf("content type = %q, want inert text", got)
	}
	if got := recorder.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("nosniff header = %q", got)
	}
	if !strings.Contains(recorder.Body.String(), "# PR 529") {
		t.Fatalf("artifact body missing: %s", recorder.Body.String())
	}

	missing := httptest.NewRecorder()
	mux.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/artifacts/unknown", nil))
	if missing.Code != http.StatusNotFound ||
		!strings.Contains(missing.Body.String(), "No such artifact") {
		t.Fatalf("missing artifact = %d: %s", missing.Code, missing.Body.String())
	}
}

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
// An audit detail reading "channel=C0BMDQK46RJ participation=proactive" says
// which setting changed and not which channel it changed for, and a publication
// note citing "Slack message C08MMETA3U3/1785885550.501459" is a coordinate
// nobody can read. An id with no known name is left alone: rewriting it as
// "#C0BMDQK46RJ" would dress a failed lookup as a resolved one.
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
	  (channel_id, channel_name, observed_at) VALUES ('C08MMETA3U3','backend-ops','now')`)
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
	detail := "Correlated from Slack message C08MMETA3U3/1785885550.501459 and C0BMDQK46RJ"
	got := reader.resolveChannels(ctx, detail)
	if !strings.Contains(got, "#backend-ops/1785885550.501459") {
		t.Errorf("a known channel id was not resolved: %q", got)
	}
	if !strings.Contains(got, "C0BMDQK46RJ") || strings.Contains(got, "#C0BMDQK46RJ") {
		t.Errorf("an unknown id was dressed up as resolved: %q", got)
	}
	// Second call comes from the cache the earlier code only claimed to have.
	if again := reader.resolveChannels(ctx, detail); again != got {
		t.Errorf("cached lookup disagreed with the first: %q then %q", got, again)
	}
}

// An operator watched alerts arrive and nothing happen. The machine knew
// exactly why — its Docker daemon was down, so Coop could not build the box
// image and every turn died before it started — and the page said "not ready"
// in three-point type, which is indistinguishable from a Ryker that had
// decided to stay quiet.
func TestNotReadyStatesTheReasonItAlreadyKnows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "responder.db")
	db, err := store.Open(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(filepath.Dir(path), "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	stopped, err := NewHandler(reader, "test", "70", "ryker-abc",
		func() (bool, string) { return false, "Coop unavailable" },
		config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	stopped.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/configuration", nil))
	if body := recorder.Body.String(); !strings.Contains(body, "Coop unavailable") {
		t.Fatalf("a stopped deployment does not say what stopped it: %s", body)
	}

	// A reason nobody supplied still reads as a state rather than as a blank.
	bare, err := NewHandler(reader, "test", "70", "ryker-abc",
		func() (bool, string) { return false, "" }, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	bareMux := http.NewServeMux()
	bare.Register(bareMux)
	bareRecorder := httptest.NewRecorder()
	bareMux.ServeHTTP(bareRecorder, httptest.NewRequest(http.MethodGet, "/configuration", nil))
	if body := bareRecorder.Body.String(); !strings.Contains(body, "not ready") {
		t.Fatalf("an unexplained stop lost its state entirely: %s", body)
	}
}
