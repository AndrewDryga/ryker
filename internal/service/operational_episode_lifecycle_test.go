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

// Covers: TestTerminalLifecycleUpdateStartsChildEpisodeInsteadOfBeingCancelled
// Covers: TestOperationalRecoveryAfterCompletedInvestigationReopensEpisode
// Covers: TestCompletedTerraformLifecycleEpisodeAdmitsLaterTerminalUpdate
// Covers finding: 20260811T144951Z-run_b2a58fcdb33869de9aeb62cfdb8daf2b
// Covers finding: 20260811T160845Z-run_7b4bec27797c7b4dae12e526b55a8f52
// Covers finding: 20260811T162826Z-run_79dfcfbecc70bf5b2e7ed3465173724d
// Covers finding: 20260811T174802Z-run_7030f033bde4aa4db2c733c3d16610bd
// Covers finding: 20260811T182939Z-run_5174a0deb68c7534943916642d95c036
// Covers finding: 20260811T211140Z-run_26214903f653f84d82516ee23b6fd5e4
// Covers finding: 20260811T213151Z-run_bfe7b078a638e25c6d92b65bca9aa77b
// Covers finding: 20260811T220114Z-run_2012e5904cf262f75daae8352282672f
// Covers finding: 20260811T235807Z-run_2f2154b97e0ba8cd55f623e7608f54a8
// Covers finding: 20260812T011123Z-run_fc64fdcc141eb09d2072d402e469b0ee
// Covers finding: 20260812T013813Z-run_6b03d24a3fe40e68fbe307a29b621492
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

// A published replay of the current Host OOM card inherited the destination of
// a day-old alert episode. Its investigation correctly targeted the selected
// card, but the finished answer was queued under historical Slack context.
// Replay history may link episodes; it never changes the requested destination.
func TestExplicitOperationalReplayUsesTheSelectedCardAsItsDestination(t *testing.T) {
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

	original := core.SlackInput{
		ID: "historical-alert", EnvelopeID: "env-historical-alert",
		EventID: "event-historical-alert", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", MessageTS: "1700.100",
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "<https://grafana.example.com/alerting/grafana/oom/view?orgId=1|" +
			"[VA1 FIRING:1] WARNING | Host OOM kills>",
	}
	if created, err := st.AdmitSlackInput(ctx, original); err != nil || !created {
		t.Fatalf("admit original = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	originalRun, err := st.GetAgentRunBySource(ctx, "watch", original.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetEpisodePhase(
		ctx, originalRun.EpisodeID, core.EpisodeWaitingExternal,
		"waiting_external", "Watching the alert stream", "Wait for the next card",
		original.ReceivedAt.Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}

	replay := original
	replay.ID, replay.EventID = "public-alert-replay", "event-public-alert-replay"
	replay.EnvelopeID = "replay-public:public-alert-replay"
	replay.MessageTS = "1700.900"
	replay.ReceivedAt = original.ReceivedAt.Add(time.Minute)
	if created, err := st.AdmitSlackInput(ctx, replay); err != nil || !created {
		t.Fatalf("admit replay = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	replayRun, err := st.GetAgentRunBySource(ctx, "watch", replay.ID)
	if err != nil {
		t.Fatal(err)
	}
	replayEpisode, err := st.GetWorkEpisode(ctx, replayRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if replayEpisode.ParentEpisodeID != originalRun.EpisodeID {
		t.Fatalf("replay lost historical parent: %+v", replayEpisode)
	}
	if replayRun.ThreadTS != replay.MessageTS ||
		replayEpisode.Destination.ThreadTS != replay.MessageTS {
		t.Fatalf("replay destination = run %q episode %q, want selected card %q",
			replayRun.ThreadTS, replayEpisode.Destination.ThreadTS, replay.MessageTS)
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
