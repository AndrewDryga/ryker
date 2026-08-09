package httpapi

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
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
	if err := actions.ConvertFeedback(ctx, item.ID, "control-plane@localhost"); err == nil {
		t.Error("a resolved item converted twice")
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

// guidanceEntryID finds the one guidance entry the conversion wrote.
func guidanceEntryID(t *testing.T, st *store.Store) string {
	t.Helper()
	entries, err := st.Memory.ListMemoryForHome(context.Background(), "T1", "U1", 50)
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
