package httpapi

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
	_ "modernc.org/sqlite"
)

// Resolving a blocked episode as overtaken writes the kernel's cancel event
// and the audit row in the same act, and refuses anything that is not parked
// on a person — running or completed work has its own exits, and a dashboard
// must not become the door without the rule.
func TestResolveEpisodeOvertakenClosesBlockedWorkAndAuditsIt(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: "thread:COPS:1",
		SourceKind: "watch", SourceID: "message-1", Prompt: "Investigate",
	})
	if err != nil || !created {
		t.Fatalf("queue run: created=%t err=%v", created, err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	actions := &dashboardActions{store: st}

	// Working states refuse: only parked work qualifies.
	err = actions.ResolveEpisodeOvertaken(ctx, episode.ID, "control-plane@localhost")
	if err == nil || !strings.Contains(err.Error(), "only blocked or waiting work") {
		t.Fatalf("a non-waiting episode was resolved: %v", err)
	}

	if err := st.SetEpisodePhase(ctx, episode.ID, core.EpisodeBlocked, "blocked",
		"Waiting for an operator decision", "Decide", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := actions.ResolveEpisodeOvertaken(ctx, episode.ID, "control-plane@localhost"); err != nil {
		t.Fatal(err)
	}
	resolved, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.State != core.EpisodeCancelled {
		t.Fatalf("episode state = %s, want cancelled", resolved.State)
	}
	if resolved.Status != "Resolved by the operator: overtaken by events" {
		t.Fatalf("status = %q; the record must say who ended it and why", resolved.Status)
	}
	events, err := st.ListEpisodeEvents(ctx, episode.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	cancelled := false
	for _, event := range events {
		if event.Kind == "episode_cancelled" && event.Actor == "control-plane@localhost" {
			cancelled = true
		}
	}
	if !cancelled {
		t.Error("no episode_cancelled event attributed to the control plane was written")
	}

	// A second resolve refuses: the episode is terminal now, and a silent
	// success over a no-op would report an action that did nothing.
	err = actions.ResolveEpisodeOvertaken(ctx, episode.ID, "control-plane@localhost")
	if err == nil {
		t.Error("a terminal episode accepted a second resolve")
	}
}

// Marking an ending reviewed writes the ledger row AND the audit row in one
// act. The dashboard once shipped an action that changed state with no audit
// trail and sixteen unattributed reviews came of it, which is why this is a
// rule rather than a preference — and it matters more here than most, because
// the ledger's whole effect is to stop a trace being read again, and "who
// decided nobody needs to look at this" is the question that gets asked when
// something was missed.
func TestMarkingAnEndingReviewedLeavesBothTheLedgerAndTheAuditRow(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	st, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: "thread:COPS:1",
		SourceKind: "watch", SourceID: "message-1", Prompt: "Investigate",
	})
	if err != nil || !created {
		t.Fatalf("queue run: created=%t err=%v", created, err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	actions := &dashboardActions{store: st}

	// Running work refuses, and the refusal reaches the operator verbatim.
	err = actions.ReviewEpisode(ctx, episode.ID, "read it", "control-plane@localhost")
	if err == nil || !strings.Contains(err.Error(), "has not ended") {
		t.Fatalf("an episode still working accepted a review: %v", err)
	}

	if err := st.SetEpisodePhase(ctx, episode.ID, core.EpisodeCompleted, "complete",
		"Completed", "None", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := actions.ReviewEpisode(ctx, episode.ID,
		"the verdict matched the evidence", "control-plane@localhost"); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var reviewer, note string
	if err := db.QueryRowContext(ctx,
		`SELECT reviewer, note FROM episode_reviews WHERE episode_id = ?`, episode.ID,
	).Scan(&reviewer, &note); err != nil {
		t.Fatalf("the review was not recorded: %v", err)
	}
	if reviewer != "control-plane@localhost" || note != "the verdict matched the evidence" {
		t.Fatalf("ledger row = (%q, %q); it must say who judged the ending and what they saw", reviewer, note)
	}
	var kind, actor, object, outcome, detail string
	if err := db.QueryRowContext(ctx, `
		SELECT kind, actor_id, object_id, outcome, detail
		FROM audit_events WHERE kind = 'episode.review'`,
	).Scan(&kind, &actor, &object, &outcome, &detail); err != nil {
		t.Fatalf("no audit row was written for the review: %v", err)
	}
	if actor != "control-plane@localhost" || object != episode.ID || outcome != "reviewed" {
		t.Fatalf("audit row = (%s, %s, %s, %s); the log must name who, what and the result",
			kind, actor, object, outcome)
	}
	if !strings.Contains(detail, "the verdict matched the evidence") {
		t.Fatalf("audit detail = %q; the note is the judgement and belongs in the log", detail)
	}
}

// Converting feedback mirrors the Slack handler field for field: the summary
// becomes workspace guidance sourced to the item, the item resolves as
// converted, and a second conversion refuses because the queue must not
// silently no-op. Dismissal is the other real outcome.
func TestFeedbackActionsMirrorTheSlackHandlers(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	item, err := st.RecordFeedback(ctx, store.FeedbackItem{
		ID: "fb_tone_1", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
		Source: "reaction", Category: "tone", Sentiment: "negative",
		Summary: "Answers are too long",
	})
	if err != nil {
		t.Fatal(err)
	}
	actions := &dashboardActions{store: st, cfg: config.Config{
		Slack:  config.SlackConfig{TeamID: "T1"},
		Limits: config.Limits{MaxMemoryEntries: 100, MaxMemoryEntriesPerScope: 50},
	}}
	if err := actions.ConvertFeedback(ctx, item.ID, "control-plane@localhost"); err != nil {
		t.Fatal(err)
	}
	resolved, err := st.GetFeedback(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Status != "converted" {
		t.Fatalf("feedback status = %q, want converted", resolved.Status)
	}
	saved, err := st.Memory.GetMemoryEntry(ctx, guidanceEntryID(t, st))
	if err != nil {
		t.Fatal(err)
	}
	if saved.Predicate != "guidance" || saved.SourceRef != "feedback:"+item.ID {
		t.Fatalf("converted entry = %+v; guidance must trace back to its feedback", saved)
	}
	if _, err := st.Memory.DeleteMemoryEntry(ctx, saved.ID); err != nil {
		t.Fatal(err)
	}
	if err := actions.ConvertFeedback(ctx, item.ID, "control-plane@localhost"); err != nil {
		t.Fatalf("a converted item could not repair its missing guidance: %v", err)
	}
	restored, err := st.Memory.GetMemoryEntry(ctx, guidanceEntryID(t, st))
	if err != nil || restored.SourceRef != "feedback:"+item.ID {
		t.Fatalf("converted feedback did not restore its guidance: %+v, %v", restored, err)
	}

	second, err := st.RecordFeedback(ctx, store.FeedbackItem{
		ID: "fb_accuracy_1", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
		Source: "reaction", Category: "accuracy", Sentiment: "negative",
		Summary: "Wrong dashboard link",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := actions.DismissFeedback(ctx, second.ID, "control-plane@localhost"); err != nil {
		t.Fatal(err)
	}
	if err := actions.DismissFeedback(ctx, second.ID, "control-plane@localhost"); err == nil {
		t.Error("a resolved item dismissed twice")
	}
}

// Two correctness complaints were converted together during the 2026-08-18
// self-improvement pass. The dashboard keyed both as correctness/guidance,
// marked both feedback rows converted, and silently superseded the first rule.
// Conversion must preserve every distinct instruction exactly as Slack does.
func TestConvertingTwoFeedbackItemsInTheSameCategoryPreservesBothGuidanceRules(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	items := []store.FeedbackItem{
		{
			ID: "fb_temporal", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
			Source: "reaction", Category: "correctness", Sentiment: "negative",
			Summary: "Do not attribute a new incident to longstanding configuration without temporal evidence.",
		},
		{
			ID: "fb_errors", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
			Source: "reaction", Category: "correctness", Sentiment: "negative",
			Summary: "Treat the errors as genuine when alert counts are difficult to reconcile.",
		},
	}
	actions := &dashboardActions{store: st, cfg: config.Config{
		Slack:  config.SlackConfig{TeamID: "T1"},
		Limits: config.Limits{MaxMemoryEntries: 100, MaxMemoryEntriesPerScope: 50},
	}}
	for _, item := range items {
		if _, err := st.RecordFeedback(ctx, item); err != nil {
			t.Fatal(err)
		}
		if err := actions.ConvertFeedback(ctx, item.ID, "control-plane@localhost"); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := st.Memory.ListMemoryForContext(ctx, "T1", "C1", "", "U1", 50)
	if err != nil {
		t.Fatal(err)
	}
	converted := make(map[string]core.MemoryEntry)
	for _, entry := range entries {
		if strings.HasPrefix(entry.SourceRef, "feedback:") {
			converted[entry.SourceRef] = entry
		}
	}
	if len(converted) != 2 {
		t.Fatalf("two converted rules became %d memory entries: %+v", len(converted), converted)
	}
	for _, item := range items {
		entry := converted["feedback:"+item.ID]
		if entry.ScopeKind != "channel" || entry.ScopeKey != "C1" {
			t.Fatalf("feedback %s widened beyond its channel: %+v", item.ID, entry)
		}
		if !entry.ExpiresAt.Equal(core.PermanentExpiry) {
			t.Fatalf("feedback %s expires at %s, want permanent", item.ID, entry.ExpiresAt)
		}
	}
}

// guidanceEntryID finds the one guidance entry the conversion wrote.
func guidanceEntryID(t *testing.T, st *store.Store) string {
	t.Helper()
	entries, err := st.Memory.ListMemoryForContext(
		context.Background(), "T1", "C1", "", "U1", 50,
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.Predicate == "guidance" {
			return entry.ID
		}
	}
	t.Fatal("no guidance entry was written")
	return ""
}

// Forgetting an entry from the dashboard is the same delete and the same
// audit shape as the Slack forget button.
func TestForgetMemoryDeletesAndRefusesTwice(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	entry, _, err := st.Memory.UpsertMemoryEntry(ctx, core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "T1", SubjectKey: "service:api",
		Predicate: "guidance", Value: "Prefer the staging dashboard",
		VisibilityKind: "workspace", VisibilityID: "T1", SourceRef: "test:manual",
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour), ActorID: "U1",
	}, 100, 50)
	if err != nil {
		t.Fatal(err)
	}
	actions := &dashboardActions{store: st}
	if err := actions.ForgetMemory(ctx, entry.ID, "control-plane@localhost"); err != nil {
		t.Fatal(err)
	}
	if err := actions.ForgetMemory(ctx, entry.ID, "control-plane@localhost"); err == nil {
		t.Error("a deleted entry was forgotten twice without complaint")
	}
}
