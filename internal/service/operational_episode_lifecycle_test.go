package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestOperationalUpdateAfterTerminalEpisodeStartsLinkedRunnableEpisode(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}

	firing := core.SlackInput{
		ID: "terminal-alert-firing", EnvelopeID: "env-terminal-alert-firing",
		EventID: "event-terminal-alert-firing", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", MessageTS: "1700.401",
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "<https://grafana.example.com/alerting/grafana/oom/view?orgId=1|" +
			"[VA1 FIRING:1] WARNING | Host OOM kills>",
	}
	if created, err := st.AdmitSlackInput(ctx, firing); err != nil || !created {
		t.Fatalf("admit firing = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	firingRun, err := st.GetAgentRunBySource(ctx, "watch", firing.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetEpisodePhase(
		ctx, firingRun.EpisodeID, core.EpisodeCompleted, "finished", "Completed", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}

	resolved := firing
	resolved.ID, resolved.EnvelopeID, resolved.EventID =
		"terminal-alert-resolved", "env-terminal-alert-resolved", "event-terminal-alert-resolved"
	resolved.MessageTS = "1700.402"
	resolved.ReceivedAt = firing.ReceivedAt.Add(15 * time.Minute)
	resolved.Text = "<https://grafana.example.com/alerting/grafana/oom/view?orgId=1|" +
		"[VA1 RESOLVED:1] WARNING | Host OOM kills>"
	if created, err := st.AdmitSlackInput(ctx, resolved); err != nil || !created {
		t.Fatalf("admit resolved = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	resolvedRun, err := st.GetAgentRunBySource(ctx, "watch", resolved.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resolvedRun.EpisodeID == firingRun.EpisodeID {
		t.Fatal("terminal operational episode was reused")
	}
	resolvedEpisode, err := st.GetWorkEpisode(ctx, resolvedRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if resolvedEpisode.ParentEpisodeID != firingRun.EpisodeID ||
		resolvedEpisode.Conversation.ThreadTS != resolved.MessageTS ||
		resolvedEpisode.Destination.ThreadTS != firing.MessageTS ||
		resolvedRun.ThreadTS != firing.MessageTS {
		t.Fatalf("linked recovery episode = run %+v episode %+v", resolvedRun, resolvedEpisode)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != resolvedRun.ID {
		t.Fatalf("leased run = %s, want new lifecycle run %s", leased.ID, resolvedRun.ID)
	}
}

func TestTerminalEpisodeCancellationClearsPendingSlackStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}
	input := core.SlackInput{
		ID: "stale-terminal-status", EnvelopeID: "env-stale-terminal-status",
		EventID: "event-stale-terminal-status", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.900", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> check this",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	state := decisionpkg.WatchTurnState{
		PendingStatusSet: true, PendingStatusAt: time.Now().Unix(),
	}
	contextJSON, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:" + input.ChannelID, SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: contextJSON,
		Episode: &core.WorkEpisode{Effort: core.EffortFocusedCheck, Authority: core.AuthorityReadOnly},
	})
	if err != nil || !created {
		t.Fatalf("queue stale run = %t, %v", created, err)
	}
	if err := st.SetEpisodePhase(
		ctx, run.EpisodeID, core.EpisodeCompleted, "finished", "Completed", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.enqueueNativeStatus(
		ctx, "", run.EpisodeID, input.ChannelID, input.MessageTS,
		watchPendingStatus, slackui.WatchProgressSteps(),
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.statuses) != 1 || slackClient.statuses[0].text == "" {
		t.Fatalf("initial status = %+v", slackClient.statuses)
	}

	if err := svc.processAgentRun(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("process cancelled terminal run = %v", err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.statuses) != 2 || slackClient.statuses[1].text != "" {
		t.Fatalf("terminal status cleanup = %+v", slackClient.statuses)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	storedState, err := decodeWatchRunContext(stored)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunCancelled || storedState.PendingStatusSet {
		t.Fatalf("cancelled run = %+v state = %+v", stored, storedState)
	}
}
