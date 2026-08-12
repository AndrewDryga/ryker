package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestConversationLocationDetection(t *testing.T) {
	threadInput := core.SlackInput{
		MessageTS: "1700.1",
		Text:      "Let's switch to a thread not to pollute the channel.",
	}
	if !decisionpkg.LocationOnlyRequest(threadInput.Text) ||
		conversationalResponseThread(threadInput) != threadInput.MessageTS {
		t.Fatalf("thread location request was not recognized: %+v", threadInput)
	}
	channelInput := core.SlackInput{
		ThreadTS:  "1700.1",
		MessageTS: "1700.2",
		Text:      "Please continue in the channel.",
	}
	if !decisionpkg.LocationOnlyRequest(channelInput.Text) ||
		conversationalResponseThread(channelInput) != "" {
		t.Fatalf("channel location request was not recognized: %+v", channelInput)
	}
	combined := core.SlackInput{
		MessageTS: "1700.3",
		Text:      "Take this to a thread and check production health.",
	}
	if decisionpkg.LocationOnlyRequest(combined.Text) ||
		conversationalResponseThread(combined) != combined.MessageTS {
		t.Fatalf("combined work and location request = %+v", combined)
	}
	if !decisionpkg.WatchInputTargeted(combined, decisionpkg.WatchTurnState{}) ||
		!watchInputWantsPendingStatus(combined, decisionpkg.WatchTurnState{}) {
		t.Fatalf("location work should be targeted and request status: %+v", combined)
	}
	terraformRule := core.SlackInput{
		MessageTS: "1700.4",
		Text: "Look at the Terraform events in this channel and comment in a thread " +
			"with the plan changes and red flags.",
	}
	if decisionpkg.LocationOnlyRequest(terraformRule.Text) ||
		conversationalResponseThread(terraformRule) != terraformRule.MessageTS {
		t.Fatalf("Terraform rule thread request was not recognized: %+v", terraformRule)
	}
}

func TestLocationWorkAndOldThreadContinuationSetPendingStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slack,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)

	locationWork := core.SlackInput{
		ID: "location-work", EnvelopeID: "location-work-env",
		EventID: "location-work-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "Let's continue in a thread, 3+5?",
	}
	if created, err := st.AdmitSlackInput(ctx, locationWork); err != nil || !created {
		t.Fatalf("admit location work = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 1 ||
		slack.statuses[0].thread != locationWork.MessageTS ||
		slack.statuses[0].text != watchPendingStatus {
		t.Fatalf("location work pending status = %+v", slack.statuses)
	}

	replySource := core.SlackInput{
		ID: "old-thread-source", EnvelopeID: "old-thread-source-env",
		EventID: "old-thread-source-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "COLD", ThreadTS: "1600.100", MessageTS: "1600.101",
		UserID: "U123ABC", Text: "What is the result?",
	}
	if created, err := st.AdmitSlackInput(ctx, replySource); err != nil || !created {
		t.Fatalf("admit old thread source = %t, %v", created, err)
	}
	leasedReplySource, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leasedReplySource.ID != replySource.ID {
		t.Fatalf("leased old thread source = %q", leasedReplySource.ID)
	}
	if err := st.FinishSlackInput(ctx, replySource.ID); err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: replySource.ChannelID,
		ThreadTS:        replySource.ThreadTS,
		ConversationKey: "channel:" + replySource.ChannelID,
		SourceKind:      "watch", SourceID: replySource.ID,
		Repository: "repo", IdempotencyKey: "old-thread-turn",
	}); err != nil || !created {
		t.Fatalf("queue old thread source = %t, %v", created, err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + replySource.ID, Operation: "post", Kind: "notice",
		ChannelID: replySource.ChannelID, ThreadTS: replySource.ThreadTS,
		Body: []byte(`{"text":"The result is 8."}`),
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(
		ctx,
		delivery.ID,
		"1600.102",
		"sending",
	); err != nil {
		t.Fatal(err)
	}
	if recent, err := st.HasRecentWatchReply(
		ctx,
		replySource.ChannelID,
		replySource.ThreadTS,
		"1600.103",
		time.Now().UTC().Add(time.Hour),
	); err != nil || recent {
		t.Fatalf("future cutoff should exclude reply = %t, %v", recent, err)
	}
	oldThreadFollowup := core.SlackInput{
		ID: "old-thread-followup", EnvelopeID: "old-thread-followup-env",
		EventID: "old-thread-followup-event", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: replySource.ChannelID,
		ThreadTS: replySource.ThreadTS, MessageTS: "1600.103",
		UserID: "U123ABC", Text: "No, let's get back to channel, 9-1.",
	}
	if continuing, err := svc.isRecentWatchConversation(
		ctx,
		oldThreadFollowup,
	); err != nil || !continuing {
		t.Fatalf("old exact thread continuation = %t, %v", continuing, err)
	}
	if created, err := st.AdmitSlackInput(
		ctx,
		oldThreadFollowup,
	); err != nil || !created {
		t.Fatalf("admit old thread followup = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 2 ||
		slack.statuses[1].thread != oldThreadFollowup.ThreadTS ||
		slack.statuses[1].text != watchPendingStatus {
		t.Fatalf("old thread pending status = %+v", slack.statuses)
	}
}

func TestLocationWorkIgnoreIsRetriedAndAnswered(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"ignore","attention":{"addressee":"responder","confidence":3,"ownership":1},"reason":"duplicate"}`,
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"reason":"current arithmetic request","message":"8"}`,
	}
	svc := New(
		cfg,
		st,
		coopClient,
		slack,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	input := core.SlackInput{
		ID: "location-retry", EnvelopeID: "location-retry-env",
		EventID: "location-retry-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", ThreadTS: "1700.100", MessageTS: "1700.200",
		UserID: "U123ABC", Text: "No, let's get back to channel, 9-1.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit location retry = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.State != core.AgentRunPending || run.Failures != 1 {
		t.Fatalf("rejected decision run = %+v", run)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(
			coopClient.submitPrompts[1],
			"Your previous decision was rejected",
		) {
		t.Fatalf("correction prompts = %+v", coopClient.submitPrompts)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 ||
		slack.posts[0].thread != "" ||
		slack.posts[0].broadcast ||
		!strings.Contains(slack.posts[0].message.Text, "8") {
		t.Fatalf("corrected channel reply = %+v", slack.posts)
	}
	if len(slack.statuses) != 2 ||
		slack.statuses[0].thread != input.ThreadTS ||
		slack.statuses[0].text != watchPendingStatus ||
		slack.statuses[1].text != "" {
		t.Fatalf("pending status lifecycle = %+v", slack.statuses)
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
	if len(slack.posts) != 2 ||
		slack.posts[1].thread != "" ||
		slack.posts[1].broadcast ||
		!strings.Contains(slack.posts[1].message.Text, "Continuing in the channel") {
		t.Fatalf("channel switch response = %+v", slack.posts)
	}
}
