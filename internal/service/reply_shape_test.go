package service

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The word "hi" drew 245 words and four paragraphs from a build whose prompt
// already said a one-line question gets one to three sentences. This is that
// turn, end to end: the host refuses the first answer with a specific
// correction, and posts the second whatever shape it arrives in, because an
// operator waiting on an answer has to get one.
func TestOverlongReplyIsCorrectedOnceAndThenPosted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	overlong := strings.TrimSpace(
		strings.Repeat("the scheduler reported a healthy allocation again ", 35),
	)
	reply := func(message string) string {
		encoded, marshalErr := json.Marshal(map[string]any{
			"action": "reply",
			"attention": map[string]any{
				"addressee": "responder", "confidence": 3, "novelty": 2, "ownership": 3,
				"contribution": "decision", "material": true,
			},
			"reason": "answering the greeting",
			"operations": []any{map[string]any{
				"id":         "complete",
				"type":       "complete_episode",
				"completion": map[string]any{"message": message},
			}},
		})
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		return string(encoded)
	}
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{reply(overlong), reply(overlong)}
	slack := &fakeSlack{}
	logs := &bytes.Buffer{}
	svc := New(
		cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000),
		slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelWarn})),
	)

	input := core.SlackInput{
		ID: "greeting", EnvelopeID: "greeting-env", EventID: "greeting-event",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.300", UserID: "U123ABC", Text: "hi",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit greeting = %t, %v", created, err)
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
	// Failures stays 0: a correction round is not a failed attempt. The shape
	// correction on the row is what proves the answer went back.
	if run.State != core.AgentRunPending || run.Failures != 0 ||
		!strings.Contains(run.LastError, "over the 60-word bound") {
		t.Fatalf("a 245-word answer to \"hi\" was accepted as written: %+v", run)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("the rejected reply reached Slack: %+v", slack.posts)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[1], "word bound for a message that size") {
		t.Fatalf("the correction did not reach the model: %+v", coopClient.submitPrompts)
	}

	// The second attempt is just as long. It ships anyway.
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "healthy allocation") {
		t.Fatalf("the second answer was eaten instead of posted: %+v", slack.posts)
	}
	if !strings.Contains(logs.String(), "still fails its shape rule") {
		t.Fatalf("posting an uncorrected reply left no record: %s", logs.String())
	}
	counts, _, err := st.CorrectionRate(ctx, time.Now().UTC().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if counts["shape"] != 1 {
		t.Fatalf("shape corrections are not countable: %+v", counts)
	}
}

// The budget is one retry, not one per rule. Two shape failures in a row must
// not cost two extra turns.
func TestReplyShapeSpendsAtMostOneCorrectionPerTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	overlong := strings.Repeat("word ", 400)
	if correction, spent := svc.replyShapeCorrection(
		ctx, core.AgentRun{ID: "run"}, "hi", "conversation", "reply", overlong, 0,
	); correction == "" || !spent {
		t.Fatalf("first shape failure = %q, %t", correction, spent)
	}
	if correction, spent := svc.replyShapeCorrection(
		ctx, core.AgentRun{ID: "run"}, "hi", "conversation", "reply", overlong, 1,
	); correction != "" || spent {
		t.Fatalf("second shape failure = %q, %t", correction, spent)
	}
}

func TestRuntimeReplyShapeDoesNotBranchOnGeneratedPhrases(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	message := "The rollout is stable. Customer impact is low. No further action is needed."
	if correction, spent := svc.replyShapeCorrection(
		ctx, core.AgentRun{ID: "run"}, "did it recover?", "conversation", "reply", message, 0,
	); correction != "" || spent {
		t.Fatalf("runtime interpreted arbitrary generated prose: correction=%q spent=%t", correction, spent)
	}
}

// The counter has to survive the trip through the run context, or the second
// attempt looks like the first and the loop never ends.
func TestReplyShapeCountSurvivesTheContextRoundTrip(t *testing.T) {
	state := decisionpkg.WatchTurnState{SessionID: "ses", ReplyShapeCorrections: 1}
	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	var decoded decisionpkg.WatchTurnState
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ReplyShapeCorrections != 1 {
		t.Fatalf("watch state lost the shape count: %+v", decoded)
	}
	assembled := assembledAgentContext{ReplyShapeCorrections: 1, CapturedAt: time.Now().UTC()}
	encoded, err = json.Marshal(assembled)
	if err != nil {
		t.Fatal(err)
	}
	roundTripped, ok := decodeAssembledAgentContext(encoded)
	if !ok || roundTripped.ReplyShapeCorrections != 1 {
		t.Fatalf("incident context lost the shape count: %+v, %t", roundTripped, ok)
	}
}
