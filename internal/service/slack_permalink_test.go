package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/slackref"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"time"
)

func TestParseSlackPermalinkExtractsThreadAndMessage(t *testing.T) {
	reference, ok := slackref.Parse(
		`<https://theblitzapp.slack.com/archives/C01KJP8SQSZ/p1786480327091169?thread_ts=1786478872.467239&amp;cid=C01KJP8SQSZ|thread>`,
	)
	if !ok || reference.ChannelID != "C01KJP8SQSZ" ||
		reference.ThreadTS != "1786478872.467239" ||
		reference.MessageTS != "1786480327.091169" {
		t.Fatalf("reference = %+v, %t", reference, ok)
	}

	for _, malformed := range []string{
		"https://example.com/archives/C01KJP8SQSZ/p1786480327091169",
		"https://theblitzapp.slack.com/archives/C01KJP8SQSZ/not-a-message",
		"https://theblitzapp.slack.com/archives/C01KJP8SQSZ/p1786480327091169?cid=COTHER",
		"https://theblitzapp.slack.com/archives/D01KJP8SQSZ/p1786480327091169",
	} {
		if got, accepted := slackref.Parse(malformed); accepted {
			t.Fatalf("malformed permalink %q accepted as %+v", malformed, got)
		}
	}
}

// Covers: TestWatchedSlackPermalinkHydratesCrossChannelReferencedThread
// Covers finding: 20260812T005823Z-run_ea41eecf88b56f45ac2c776c1c20dd1e
func TestSlackPermalinkHydratesConfiguredCrossChannelThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "C01KJP8SQSZ", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.ReconcileSlackChannelMemberships(ctx, []store.SlackChannelMembershipObservation{
		{ChannelID: "C01KJP8SQSZ", ChannelName: "frontend-ops", Present: true},
	}, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{history: []slackui.HistoryMessage{
		{Timestamp: "1786478872.467239", UserID: "U123ABC", Text: "Add support for the blitzapp.gg repository."},
		{Timestamp: "1786480327.091169", ThreadTS: "1786478872.467239", UserID: "U123ABC", Text: "Check if you have access to that repo now."},
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{WorkspaceURL: "https://theblitzapp.slack.com/"}
	input := core.SlackInput{
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "C0BMDQK46RJ",
		MessageTS: "1786496033.633489", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> do you have access now? " +
			"<https://theblitzapp.slack.com/archives/C01KJP8SQSZ/p1786480327091169?" +
			"thread_ts=1786478872.467239&amp;cid=C01KJP8SQSZ|thread>",
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
	if request.channel != "C01KJP8SQSZ" || request.thread != "1786478872.467239" ||
		request.target != "1786480327.091169" {
		t.Fatalf("linked history request = %+v", request)
	}
	// Fetching the transcript is half the job. The model is told two paragraphs
	// later to treat the current thread as the referent of "that", so a
	// transcript from another room with nothing marking it as such reads as
	// more of this room — and the link to the thread holding the answer reads
	// as unresolved.
	if !assembled.ReferencedThread.Elsewhere {
		t.Fatal("a transcript from another channel was not marked as coming from one")
	}
	if assembled.ReferencedThread.ChannelID != "C01KJP8SQSZ" {
		t.Fatalf("referenced channel = %q, want the linked one",
			assembled.ReferencedThread.ChannelID)
	}
	if assembled.ReferencedThread.ChannelName != "frontend-ops" {
		t.Fatalf("referenced channel name = %q, want the roster name",
			assembled.ReferencedThread.ChannelName)
	}

	// A link into the channel the conversation is already in is not a
	// cross-channel reference, and saying so would send the model chasing a
	// room it is standing in.
	local := input
	local.ChannelID = "C01KJP8SQSZ"
	here, err := svc.assembleAgentContext(ctx, agentContextRequest{
		ChannelID: local.ChannelID, Repository: "repo", RepositoryPinned: true,
		OperatorID: local.UserID, TargetInput: &local,
		ReferencedChannelID: state.ReferencedChannelID,
		ReferencedThreadTS:  state.ReferencedThreadTS,
		ReferencedMessageTS: state.ReferencedMessageTS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if here.ReferencedThread == nil || here.ReferencedThread.Elsewhere {
		t.Fatalf("a same-channel reference was marked as elsewhere: %+v", here.ReferencedThread)
	}
}

func TestWatchedInputCapturesSlackPermalinkBeforeQueueing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"C0BMDQK46RJ"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "C01KJP8SQSZ", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, WorkspaceURL: "https://theblitzapp.slack.com/",
		BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "permalink-watch", EnvelopeID: "env-permalink-watch", EventID: "event-permalink-watch",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "C0BMDQK46RJ",
		MessageTS: "1786496033.633489", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> do you have access now? " +
			"https://theblitzapp.slack.com/archives/C01KJP8SQSZ/p1786480327091169?" +
			"thread_ts=1786478872.467239&cid=C01KJP8SQSZ",
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
	if !state.ReferenceCaptured || state.ReferencedChannelID != "C01KJP8SQSZ" ||
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
	svc.identity = slackui.Identity{WorkspaceURL: "https://theblitzapp.slack.com/"}
	input := core.SlackInput{
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "C0BMDQK46RJ",
		UserID: cfg.Slack.Operators[0],
		Text: "https://theblitzapp.slack.com/archives/C01KJP8SQSZ/p1786480327091169?" +
			"thread_ts=1786478872.467239&cid=C01KJP8SQSZ",
	}
	var state decisionpkg.WatchTurnState
	if err := svc.captureSlackPermalinkReference(ctx, input, &state); err != nil {
		t.Fatal(err)
	}
	if state.ReferencedThreadTS != "" || len(slackClient.historyRequests) != 0 {
		t.Fatalf("unconfigured reference was hydrated: %+v", state)
	}

	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "C01KJP8SQSZ", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	lookalike := input
	lookalike.Text = strings.Replace(input.Text, "theblitzapp.slack.com", "another-workspace.slack.com", 1)
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
	if err == nil || !strings.Contains(err.Error(), "read linked Slack thread C01KJP8SQSZ/1786478872.467239: not_in_channel") {
		t.Fatalf("unreadable reference error = %v", err)
	}
}
