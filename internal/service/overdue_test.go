package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// Accepting a request is a promise. The behaviour that makes this feel like a
// teammate rather than a bot is what happens when the promise cannot be kept:
// it says so, once, and then changes state rather than repeating itself.
func TestOverdueCommitmentIsSurfacedOnceThenBlocked(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)

	grace := cfg.Limits.EpisodeOverdueAfter.Duration
	// Not yet overdue: nothing should be said.
	clock.Advance(grace / 2)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 0 {
		t.Fatalf("surfaced before the grace window elapsed: %+v", slack.posts)
	}

	// Past the window: exactly one notice, naming the state and what to do.
	clock.Advance(grace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("expected exactly one overdue notice, got %d: %+v", len(slack.posts), slack.posts)
	}
	notice := slack.posts[0].message
	if !strings.Contains(notice.Text, "not made progress") {
		t.Fatalf("notice does not state the problem: %+v", notice)
	}

	// Running maintenance again inside the same generation must not repeat it.
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("overdue notice repeated within one generation: %+v", slack.posts)
	}

	// Still nothing a full interval later: state changes instead of nagging.
	clock.Advance(2 * grace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("a stalled episode kept posting instead of blocking: %+v", slack.posts)
	}
	stalled, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stalled.State != core.EpisodeBlocked {
		t.Fatalf("stalled episode state = %q, want blocked", stalled.State)
	}
}

// A restart must not turn one commitment into two notices.
func TestOverdueSurfacingSurvivesRestart(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)

	clock.Advance(cfg.Limits.EpisodeOverdueAfter.Duration * 2)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	// A fresh service over the same durable state, as after a restart.
	restarted := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	restarted.SetClock(clock.Now)
	restarted.identity = svc.identity
	restarted.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, restarted)

	if len(slack.posts) != 1 {
		t.Fatalf("restart produced a duplicate overdue notice: %+v", slack.posts)
	}
}

func acceptedEpisodeAwaitingProgress(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	st *store.Store,
	clock *testClock,
) core.WorkEpisode {
	t.Helper()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_overdue", Mode: core.AgentRunTriage, ChannelID: "C123ABC",
		ThreadTS: "1700.001", ConversationKey: "channel:C123ABC",
		SourceKind: "watch", SourceID: "slack_overdue", UserID: "U123ABC",
		State: core.AgentRunRunning,
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "working", "Working",
		"Investigating", clock.Now().Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	refreshed, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	return refreshed
}
