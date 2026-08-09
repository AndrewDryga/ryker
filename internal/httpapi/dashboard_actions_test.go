package httpapi

import (
	"context"
	"strings"
	"testing"
	"time"

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
