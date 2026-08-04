package service

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestEpisodeWakeupQueuesFreshAttemptOnSameEpisode(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1.0",
		ConversationKey: "thread:COPS:1.0", SourceKind: "watch", SourceID: "source-1",
		UserID: "U123ABC", Repository: "repo", Prompt: "Check the rollout",
		Episode: &core.WorkEpisode{WorkspaceID: cfg.Slack.TeamID, Mode: core.EpisodeCheck},
	})
	if err != nil || !created {
		t.Fatalf("queue original attempt = %+v, %t, %v", run, created, err)
	}
	wakeup, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
		EpisodeID: run.EpisodeID, Kind: "external_event",
		DueAt: time.Now().UTC().Add(-time.Second), Deadline: time.Now().UTC().Add(time.Hour),
		EventMatcher: []byte(`{"provider":"github","state":"terminal"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processEpisodeWakeup(ctx); err != nil {
		t.Fatal(err)
	}
	resumed, err := st.GetAgentRunBySource(ctx, "watch", "episode_wakeup_"+wakeup.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resumed.EpisodeID != run.EpisodeID || resumed.AttemptID == run.AttemptID ||
		resumed.AttemptNumber != 2 {
		t.Fatalf("resumed attempt = %+v; original = %+v", resumed, run)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, run.EpisodeID)
	if err != nil || len(wakeups) != 1 || wakeups[0].State != core.WakeupResolved {
		t.Fatalf("wakeups = %+v, %v", wakeups, err)
	}
}
