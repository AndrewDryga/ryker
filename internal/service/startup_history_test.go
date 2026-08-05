package service

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestStartupHistoryRecoversOnlyMissingExternalAppMessagesOnce(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.StartupHistoryWindow.Duration = 15 * time.Minute
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.ReconcileSlackChannelMemberships(ctx, []store.SlackChannelMembershipObservation{{
		ChannelID: "CALERTS", ChannelName: "alerts", Present: true,
	}}, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CALERTS", Participation: "proactive", Repository: "repo",
		AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC()
	existingTS := fmt.Sprintf("%d.100000", now.Unix()-30)
	missedTS := fmt.Sprintf("%d.200000", now.Unix()-20)
	existing := core.SlackInput{
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CALERTS",
		MessageTS: existingTS, UserID: "BGRAFANA", Text: "FIRING existing alert",
		ReceivedAt: now.Add(-30 * time.Second),
	}
	bindCanonicalSlackMessageInputID(&existing)
	if created, admitErr := st.AdmitSlackInput(ctx, existing); admitErr != nil || !created {
		t.Fatalf("admit existing input = %t, %v", created, admitErr)
	}

	slackClient := &fakeSlack{history: []slackui.HistoryMessage{
		{Timestamp: missedTS, BotID: "BGRAFANA", Text: "FIRING missed alert"},
		{Timestamp: existingTS, BotID: "BGRAFANA", Text: existing.Text},
		{Timestamp: fmt.Sprintf("%d.300000", now.Unix()-10), UserID: "UOTHER", Text: "human message"},
		{Timestamp: fmt.Sprintf("%d.400000", now.Unix()-5), BotID: "BSELF", Text: "own reply"},
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "BSELF",
	}
	if err := svc.catchUpSlackAppMessages(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.catchUpSlackAppMessages(ctx); err != nil {
		t.Fatal(err)
	}

	inputs, err := st.ListLatestSlackInputsByKind(
		ctx, "bot_message", now.Add(-time.Hour), 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(inputs) != 2 {
		t.Fatalf("recovered inputs = %+v", inputs)
	}
	var recovered core.SlackInput
	for _, input := range inputs {
		if input.MessageTS == missedTS {
			recovered = input
		}
	}
	if recovered.Text != "FIRING missed alert" || recovered.UserID != "BGRAFANA" ||
		recovered.EventID != "history:CALERTS:"+missedTS {
		t.Fatalf("recovered input = %+v", recovered)
	}
	if len(slackClient.historyRequests) != 2 ||
		slackClient.historyRequests[0].channel != "CALERTS" ||
		slackClient.historyRequests[0].since == "" {
		t.Fatalf("history requests = %+v", slackClient.historyRequests)
	}
}

func TestStartupHistorySkipsUnwatchedChannels(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.ReconcileSlackChannelMemberships(ctx, []store.SlackChannelMembershipObservation{{
		ChannelID: "CCHAT", ChannelName: "chat", Present: true,
	}}, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{history: []slackui.HistoryMessage{{
		Timestamp: fmt.Sprintf("%d.100000", time.Now().Unix()),
		BotID:     "BAPP", Text: "routine app message",
	}}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{BotUserID: "U999BOT", BotID: "BSELF"}
	if err := svc.catchUpSlackAppMessages(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.historyRequests) != 0 {
		t.Fatalf("unwatched history requests = %+v", slackClient.historyRequests)
	}
}
