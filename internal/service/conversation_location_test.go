package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestConversationLocationDetection(t *testing.T) {
	threadInput := core.SlackInput{
		MessageTS: "1700.1",
		Text:      "Let's switch to a thread not to pollute the channel.",
	}
	if !locationOnlyRequest(threadInput.Text) ||
		conversationalResponseThread(threadInput) != threadInput.MessageTS {
		t.Fatalf("thread location request was not recognized: %+v", threadInput)
	}
	channelInput := core.SlackInput{
		ThreadTS:  "1700.1",
		MessageTS: "1700.2",
		Text:      "Please continue in the channel.",
	}
	if !locationOnlyRequest(channelInput.Text) ||
		conversationalResponseThread(channelInput) != "" {
		t.Fatalf("channel location request was not recognized: %+v", channelInput)
	}
	combined := core.SlackInput{
		MessageTS: "1700.3",
		Text:      "Take this to a thread and check production health.",
	}
	if locationOnlyRequest(combined.Text) ||
		conversationalResponseThread(combined) != combined.MessageTS {
		t.Fatalf("combined work and location request = %+v", combined)
	}
}

func TestConversationalLocationSwitchAcknowledgesWhereOperatorMoves(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{
		channel: slackui.Channel{ID: "CWATCH", Name: "infra", Member: true},
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	toThread := core.SlackInput{
		ID: "move-thread", EnvelopeID: "move-thread-env", EventID: "move-thread-event",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.1", UserID: "U123ABC",
		Text: "<@U999BOT> let's switch to a thread not to pollute the channel",
	}
	if _, err := st.AdmitSlackInput(ctx, toThread); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != toThread.MessageTS ||
		!strings.Contains(slack.posts[0].message.Text, "Continuing in this thread") {
		t.Fatalf("thread switch response = %+v", slack.posts)
	}

	toChannel := core.SlackInput{
		ID: "move-channel", EnvelopeID: "move-channel-env", EventID: "move-channel-event",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		ThreadTS: toThread.MessageTS, MessageTS: "1700.2", UserID: "U123ABC",
		Text: "<@U999BOT> back to the channel",
	}
	if _, err := st.AdmitSlackInput(ctx, toChannel); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 2 || slack.posts[1].thread != "" ||
		!strings.Contains(slack.posts[1].message.Text, "Continuing in the channel") {
		t.Fatalf("channel switch response = %+v", slack.posts)
	}
}
