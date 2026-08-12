package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackref"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestParseSlackPermalinkExtractsThreadAndMessage(t *testing.T) {
	reference, ok := slackref.Parse(
		`<https://tenantcorp.slack.com/archives/C0TENANTENG/p1786480327091169?thread_ts=1786478872.467239&amp;cid=C0TENANTENG|thread>`,
	)
	if !ok || reference.ChannelID != "C0TENANTENG" ||
		reference.ThreadTS != "1786478872.467239" ||
		reference.MessageTS != "1786480327.091169" {
		t.Fatalf("reference = %+v, %t", reference, ok)
	}

	for _, malformed := range []string{
		"https://example.com/archives/C0TENANTENG/p1786480327091169",
		"https://tenantcorp.slack.com/archives/C0TENANTENG/not-a-message",
		"https://tenantcorp.slack.com/archives/C0TENANTENG/p1786480327091169?cid=COTHER",
		"https://tenantcorp.slack.com/archives/D0TENANTENG/p1786480327091169",
	} {
		if got, accepted := slackref.Parse(malformed); accepted {
			t.Fatalf("malformed permalink %q accepted as %+v", malformed, got)
		}
	}
}

func TestSlackPermalinkHydratesConfiguredCrossChannelThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "C0TENANTENG", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{history: []slackui.HistoryMessage{
		{Timestamp: "1786478872.467239", UserID: "U123ABC", Text: "Add support for the tenantcorp.gg repository."},
		{Timestamp: "1786480327.091169", ThreadTS: "1786478872.467239", UserID: "U123ABC", Text: "Check if you have access to that repo now."},
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{WorkspaceURL: "https://tenantcorp.slack.com/"}
	input := core.SlackInput{
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "C0TENANTX01",
		MessageTS: "1786496033.633489", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> do you have access now? " +
			"<https://tenantcorp.slack.com/archives/C0TENANTENG/p1786480327091169?" +
			"thread_ts=1786478872.467239&amp;cid=C0TENANTENG|thread>",
	}
	var state decisionpkg.WatchTurnState
	if err := svc.captureSlackPermalinkReference(ctx, input, &state); err != nil {
		t.Fatal(err)
	}
	assembled, err := svc.assembleAgentContext(ctx, agentContextRequest{
		ChannelID: input.ChannelID, Repository: "repo", RepositoryPinned: true,
		OperatorID: input.UserID, TargetInput: &input,
		ReferencedChannelID: state.ReferencedChannelID,
		ReferencedThreadTS:  state.ReferencedThreadTS,
		ReferencedMessageTS: state.ReferencedMessageTS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if assembled.ReferencedThread == nil ||
		len(assembled.ReferencedThread.RecentMessages) != 2 ||
		!strings.Contains(assembled.ReferencedThread.RecentMessages[1].Text, "access to that repo") {
		t.Fatalf("referenced thread = %+v", assembled.ReferencedThread)
	}
	if len(slackClient.historyRequests) != 1 {
		t.Fatalf("history requests = %+v", slackClient.historyRequests)
	}
	request := slackClient.historyRequests[0]
	if request.channel != "C0TENANTENG" || request.thread != "1786478872.467239" ||
		request.target != "1786480327.091169" {
		t.Fatalf("linked history request = %+v", request)
	}
}

func TestWatchedInputCapturesSlackPermalinkBeforeQueueing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"C0TENANTX01"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "C0TENANTENG", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, WorkspaceURL: "https://tenantcorp.slack.com/",
		BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "permalink-watch", EnvelopeID: "env-permalink-watch", EventID: "event-permalink-watch",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "C0TENANTX01",
		MessageTS: "1786496033.633489", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> do you have access now? " +
			"https://tenantcorp.slack.com/archives/C0TENANTENG/p1786480327091169?" +
			"thread_ts=1786478872.467239&cid=C0TENANTENG",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		t.Fatal(err)
	}
	if !state.ReferenceCaptured || state.ReferencedChannelID != "C0TENANTENG" ||
		state.ReferencedThreadTS != "1786478872.467239" ||
		state.ReferencedMessageTS != "1786480327.091169" {
		t.Fatalf("queued permalink state = %+v", state)
	}
}

func TestSlackPermalinkRejectsUnconfiguredOrUnreadableCrossChannelThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{historyErr: errors.New("not_in_channel")}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{WorkspaceURL: "https://tenantcorp.slack.com/"}
	input := core.SlackInput{
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "C0TENANTX01",
		UserID: cfg.Slack.Operators[0],
		Text: "https://tenantcorp.slack.com/archives/C0TENANTENG/p1786480327091169?" +
			"thread_ts=1786478872.467239&cid=C0TENANTENG",
	}
	var state decisionpkg.WatchTurnState
	if err := svc.captureSlackPermalinkReference(ctx, input, &state); err != nil {
		t.Fatal(err)
	}
	if state.ReferencedThreadTS != "" || len(slackClient.historyRequests) != 0 {
		t.Fatalf("unconfigured reference was hydrated: %+v", state)
	}

	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "C0TENANTENG", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	lookalike := input
	lookalike.Text = strings.Replace(input.Text, "tenantcorp.slack.com", "another-workspace.slack.com", 1)
	state = decisionpkg.WatchTurnState{}
	if err := svc.captureSlackPermalinkReference(ctx, lookalike, &state); err != nil {
		t.Fatal(err)
	}
	if state.ReferencedThreadTS != "" {
		t.Fatalf("cross-workspace permalink was hydrated: %+v", state)
	}
	if err := svc.captureSlackPermalinkReference(ctx, input, &state); err != nil {
		t.Fatal(err)
	}
	_, err = svc.assembleAgentContext(ctx, agentContextRequest{
		ChannelID: input.ChannelID, Repository: "repo", RepositoryPinned: true,
		OperatorID: input.UserID, TargetInput: &input,
		ReferencedChannelID: state.ReferencedChannelID,
		ReferencedThreadTS:  state.ReferencedThreadTS,
		ReferencedMessageTS: state.ReferencedMessageTS,
	})
	if err == nil || !strings.Contains(err.Error(), "read linked Slack thread C0TENANTENG/1786478872.467239: not_in_channel") {
		t.Fatalf("unreadable reference error = %v", err)
	}
}
