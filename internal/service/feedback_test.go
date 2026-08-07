package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestNegativeReactionFeedbackIsRecordedAndRemovalWithdrawsIt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{history: []slackui.HistoryMessage{
		{Timestamp: "99.000", UserID: "U123ABC", Text: "Why did that fail?"},
		{Timestamp: "100.000", UserID: "U999BOT", Text: "It failed."},
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "feedback-reply", Kind: "reply", ChannelID: "C123ABC",
		ThreadTS: "100.000", Body: []byte(`{"text":"It failed."}`),
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, delivery.ID, "100.000", delivery.State); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "reaction-1", Kind: "reaction_added", TeamID: cfg.Slack.TeamID,
		ChannelID: "C123ABC", ThreadTS: "100.000", MessageTS: "101.000",
		UserID: "U123ABC", ActionID: "thumbsdown", ActionValue: "100.000",
	}
	if err := svc.recordReactionFeedback(ctx, input); err != nil {
		t.Fatal(err)
	}
	items, err := st.ListOpenFeedback(ctx, cfg.Slack.TeamID, 20)
	if err != nil || len(items) != 1 || items[0].Source != "negative_reaction" ||
		len(items[0].Context) != 3 || !strings.Contains(items[0].SourceRef, "100.000") {
		t.Fatalf("items = %#v, err = %v", items, err)
	}
	input.Kind = "reaction_removed"
	if err := svc.recordReactionFeedback(ctx, input); err != nil {
		t.Fatal(err)
	}
	items, err = st.ListOpenFeedback(ctx, cfg.Slack.TeamID, 20)
	if err != nil || len(items) != 0 {
		t.Fatalf("items after removal = %#v, err = %v", items, err)
	}
}

func TestNegativeReactionToSomeoneElsesMessageIsNotFeedback(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "reaction-1", Kind: "reaction_added", TeamID: cfg.Slack.TeamID,
		ChannelID: "C123ABC", UserID: "U123ABC",
		ActionID: "thumbsdown", ActionValue: "100.000",
	}
	if err := svc.recordReactionFeedback(ctx, input); err != nil {
		t.Fatal(err)
	}
	items, err := st.ListOpenFeedback(ctx, cfg.Slack.TeamID, 20)
	if err != nil || len(items) != 0 {
		t.Fatalf("items = %#v, err = %v", items, err)
	}
}

func TestFeedbackOperationPersistsBoundedConversationContext(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	run := core.AgentRun{ID: "run-1", EpisodeID: "episode-1"}
	input := core.SlackInput{
		ID: "message-1", TeamID: cfg.Slack.TeamID, ChannelID: "C123ABC",
		ThreadTS: "100.000", MessageTS: "101.000", UserID: "U123ABC",
		Text: "That answer was too vague.",
	}
	state := watchTurnState{RecentMessages: []watchContextMessage{
		{MessageTS: "100.000", SenderID: "U999BOT", SenderType: "responder", Text: "Everything looks fine."},
		{MessageTS: "101.000", SenderID: "U123ABC", SenderType: "human", Text: input.Text},
	}}
	operations := []investigation.ResultOperation{{
		ID: "feedback-1", Type: "record_feedback",
		Feedback: &investigation.FeedbackOperation{
			Category: "correctness", Sentiment: "negative",
			Summary: "The answer was too vague to act on.",
		},
	}}
	if err := svc.recordFeedbackOperations(ctx, run, input, state, operations); err != nil {
		t.Fatal(err)
	}
	items, err := st.ListOpenFeedback(ctx, cfg.Slack.TeamID, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].AgentRunID != run.ID || len(items[0].Context) != 2 {
		t.Fatalf("items = %#v", items)
	}
}

func TestWatchPromptSeparatesResponderFeedbackFromOperationalFrustration(t *testing.T) {
	prompt := (&Service{}).unboundedWatchPrompt(
		core.SlackInput{TeamID: "T123ABC", ChannelID: "C123ABC", UserID: "U123ABC", Text: "This answer is not useful"},
		"U999BOT", false, nil, core.AgentMemory{}, nil, nil,
		operationalMemoryContext{}, "", nil,
		nil,
	)
	for _, required := range []string{
		"Product feedback is distinct from operational frustration",
		"include one record_feedback operation",
		"Do not record anger or concern directed at an outage",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("prompt missing %q", required)
		}
	}
}

func TestFeedbackFollowupIsIncludedOnce(t *testing.T) {
	question := "What did you expect to see instead?"
	decision := decisionpkg.WatchDecision{Operations: []investigation.ResultOperation{
		{
			ID: "feedback-1", Type: "record_feedback",
			Feedback: &investigation.FeedbackOperation{
				Category: "ux", Sentiment: "negative", Summary: "The response was not useful.",
				NeedsFollowup: true, FollowupQuestion: question,
			},
		},
		{
			ID: "complete-1", Type: "complete_episode",
			Completion: &investigation.CompleteEpisode{Message: "I saved that feedback."},
		},
	}}
	if err := decisionpkg.ApplyWatchResultOperations(&decision); err != nil {
		t.Fatal(err)
	}
	if strings.Count(decision.Message, question) != 1 {
		t.Fatalf("message = %q", decision.Message)
	}
}

func TestSlashArgumentPreservesFeedbackText(t *testing.T) {
	if got := slashArgument("feedback   Keep progress visible while working"); got != "Keep progress visible while working" {
		t.Fatalf("argument = %q", got)
	}
}

func TestOrdinaryWorkspaceMemberCanSubmitButNotBrowseFeedback(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	submit := core.SlackInput{
		ID: "feedback-submit", EnvelopeID: "feedback-submit-envelope",
		EventID: "feedback-submit-event", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: "C123ABC", UserID: "U456MEMBER",
		Text: "feedback Keep the progress status visible",
	}
	if created, err := st.AdmitSlackInput(ctx, submit); err != nil || !created {
		t.Fatalf("admit feedback = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	items, err := st.ListOpenFeedback(ctx, cfg.Slack.TeamID, 20)
	if err != nil || len(items) != 1 || items[0].UserID != submit.UserID {
		t.Fatalf("items = %#v, err = %v", items, err)
	}

	browse := core.SlackInput{
		ID: "feedback-browse", EnvelopeID: "feedback-browse-envelope",
		EventID: "feedback-browse-event", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: "C123ABC", UserID: "U456MEMBER", Text: "feedback",
	}
	if created, err := st.AdmitSlackInput(ctx, browse); err != nil || !created {
		t.Fatalf("admit browse = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 2 ||
		!strings.Contains(slackClient.ephemerals[1].message.Text, "cannot run Responder commands") {
		t.Fatalf("ephemeral responses = %#v", slackClient.ephemerals)
	}
}

// Feedback that is captured and never acted on is worse than feedback that was
// never captured: the person sees their input accepted and nothing change.
// These cover the two ways an item can leave the queue.
func TestFeedbackConvertsToGuidanceAndDismisses(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	operator := cfg.Slack.Operators[0]

	record := func(id, summary string) {
		t.Helper()
		if _, err := st.RecordFeedback(ctx, store.FeedbackItem{
			ID: id, WorkspaceID: cfg.Slack.TeamID, ChannelID: "C123ABC",
			UserID: operator, Source: "model_sentiment", Category: "tone",
			Sentiment: "suggestion", Summary: summary,
			SourceRef: "https://slack.com/archives/C123ABC/p1700001",
		}); err != nil {
			t.Fatal(err)
		}
	}
	record("fb_convert", "answer with the decision first, then the detail")
	record("fb_dismiss", "the emoji were too much in the incident channel")

	// Converting produces durable guidance the agent will actually recall.
	if err := svc.handleConvertFeedback(ctx, admittedAction(
		t, ctx, st, cfg, "slack_convert", slackui.ActionConvertFeedback, "fb_convert", operator,
	)); err != nil {
		t.Fatal(err)
	}
	entries, err := st.ListMemoryForContext(
		ctx, cfg.Slack.TeamID, "C123ABC", cfg.Slack.DefaultRepository, operator, 50,
	)
	if err != nil {
		t.Fatal(err)
	}
	var guidance *core.MemoryEntry
	for index := range entries {
		if entries[index].SourceRef == "feedback:fb_convert" {
			guidance = &entries[index]
		}
	}
	if guidance == nil {
		t.Fatalf("converting feedback produced no guidance entry: %+v", entries)
	}
	if guidance.Predicate != "guidance" ||
		guidance.Value != "answer with the decision first, then the detail" {
		t.Fatalf("guidance entry = %+v", guidance)
	}

	if err := svc.handleDismissFeedback(ctx, admittedAction(
		t, ctx, st, cfg, "slack_dismiss", slackui.ActionDismissFeedback, "fb_dismiss", operator,
	)); err != nil {
		t.Fatal(err)
	}

	// Both items have left the open queue, so the digest is empty.
	open, err := svc.openFeedbackSummaries(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(open) != 0 {
		t.Fatalf("resolved feedback is still open: %+v", open)
	}

	// Resolving twice is a real race when two operators are looking at the
	// same App Home, and must not error.
	if err := svc.handleDismissFeedback(ctx, admittedAction(
		t, ctx, st, cfg, "slack_dismiss_again", slackui.ActionDismissFeedback, "fb_dismiss", operator,
	)); err != nil {
		t.Fatalf("resolving an already-resolved item errored: %v", err)
	}
}

// Only a configured operator may turn feedback into behaviour.
func TestFeedbackResolutionRequiresAnOperator(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if _, err := st.RecordFeedback(ctx, store.FeedbackItem{
		ID: "fb_guarded", WorkspaceID: cfg.Slack.TeamID, ChannelID: "C123ABC",
		UserID: "UOTHER1", Source: "model_sentiment", Category: "ux",
		Sentiment: "suggestion", Summary: "please be quieter",
	}); err != nil {
		t.Fatal(err)
	}
	if err := svc.handleConvertFeedback(ctx, admittedAction(
		t, ctx, st, cfg, "slack_guarded", slackui.ActionConvertFeedback, "fb_guarded", "UOTHER1",
	)); err != nil {
		t.Fatal(err)
	}
	open, err := svc.openFeedbackSummaries(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(open) != 1 {
		t.Fatalf("a non-operator resolved feedback: %+v", open)
	}
}

// admittedAction builds an interactive Slack action the way production does:
// admitted and leased, so the handler's completion path behaves as it would in
// the control lane rather than erroring on an input that was never persisted.
func admittedAction(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	cfg config.Config,
	id, actionID, actionValue, userID string,
) core.SlackInput {
	t.Helper()
	created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: id, EnvelopeID: "env_" + id, EventID: "Ev" + id,
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: "",
		UserID: userID, ActionID: actionID, ActionValue: actionValue,
	})
	if err != nil || !created {
		t.Fatalf("admit %s = %t, %v", id, created, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return leased
}
