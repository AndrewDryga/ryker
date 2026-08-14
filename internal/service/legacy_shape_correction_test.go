package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const legacyWatchReply = `{
  "action":"reply",
  "attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":2,"contribution":"decision","material":true},
  "reason":"a direct question with an answer in hand",
  "message":"The checkout API is healthy; the alert cleared at 09:12 UTC.",
  "memory":{"situation_summary":"checkout alert cleared on its own"}
}`

const typedWatchReply = `{
  "action":"reply",
  "attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":2,"contribution":"decision","material":true},
  "reason":"a direct question with an answer in hand",
  "operations":[
    {"id":"mem","type":"update_memory","memory":{"situation_summary":"checkout alert cleared on its own"}},
    {"id":"complete","type":"complete_episode","completion":{"message":"The checkout API is healthy; the alert cleared at 09:12 UTC.","completion":{"status":"decision_ready","summary":"alert cleared, no action needed"}}}
  ]
}`

// legacyCorrectionService is the arrangement all four cases share: one watched
// channel, one mention, and a scripted Coop.
func legacyCorrectionService(
	t *testing.T,
	ctx context.Context,
	queue []string,
) (*Service, *fakeCoop, *fakeSlack, *store.Store, core.SlackInput) {
	t.Helper()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeQueue = queue
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-legacy-shape", EnvelopeID: "env-legacy-shape",
		EventID: "EvLegacyShape", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.900", UserID: "U123ABC",
		Text: "<@U999BOT> is the checkout API healthy?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	return svc, coopClient, slackClient, st, input
}

func legacyShapeOutcomes(t *testing.T, svc *Service, runID string) []string {
	t.Helper()
	return auditOutcomes(t, svc.cfg, "result.legacy_shape", runID)
}

// A legacy result is read, acted on, and asked once to come back typed.
//
// The whole squeeze is in this test: the answer was never in question, so the
// correction must say so and must ask for the same decision rather than a fresh
// one — and when the typed version arrives, that is what reaches Slack.
func TestLegacyWatchResultIsCorrectedOnceAndTheTypedRetryIsUsed(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := legacyCorrectionService(
		t, ctx, []string{legacyWatchReply, typedWatchReply},
	)

	finishQueuedAgentRun(t, ctx, svc)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending {
		t.Fatalf("legacy result did not draw a correction: %+v, %v", requeued, err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("the legacy answer posted before its one correction: %+v", slackClient.posts)
	}

	finishQueuedAgentRun(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("corrected run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 {
		t.Fatalf("submitted turns = %d, want exactly one correction: %d prompts",
			len(coopClient.submitPrompts), len(coopClient.submitPrompts))
	}
	correction := coopClient.submitPrompts[1]
	for _, required := range []string{
		"<host-result-shape-correction>",
		"typed operations array",
		"complete_episode",
		"update_memory",
		"Do not re-evaluate the target message",
	} {
		if !strings.Contains(correction, required) {
			t.Fatalf("correction prompt does not mention %q:\n%s", required, correction)
		}
	}
	// The framing the rejection path uses would tell the model to re-decide,
	// which is the one thing this correction must not ask for.
	if strings.Contains(correction, "was rejected by Responder's deterministic") {
		t.Fatalf("an accepted result was told it was rejected:\n%s", correction)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "alert cleared at 09:12 UTC") {
		t.Fatalf("corrected answer did not reach Slack: %+v", slackClient.posts)
	}
	outcomes := legacyShapeOutcomes(t, svc, completed.ID)
	if len(outcomes) != 2 ||
		!strings.HasPrefix(outcomes[0], "legacy_only") ||
		!strings.HasPrefix(outcomes[1], "legacy_corrected") {
		t.Fatalf("audit trail = %v, want the legacy answer then its correction", outcomes)
	}
}

// One attempt, and then the answer ships in whatever shape it is in.
//
// A correction of a correction is the loop that would turn a tolerated format
// into an unbounded retry, so the second legacy result is accepted exactly as
// the tolerance accepts it today. The tolerance is not a gate.
func TestLegacyWatchResultThatStaysLegacyIsAcceptedAfterOneCorrection(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := legacyCorrectionService(
		t, ctx, []string{legacyWatchReply, legacyWatchReply, legacyWatchReply},
	)

	finishQueuedAgentRun(t, ctx, svc)
	finishQueuedAgentRun(t, ctx, svc)

	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("run after one correction = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 {
		t.Fatalf("submitted turns = %d, want exactly one correction and no correction "+
			"of a correction", len(coopClient.submitPrompts))
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "alert cleared at 09:12 UTC") {
		t.Fatalf("the still-legacy answer was not delivered: %+v", slackClient.posts)
	}
	outcomes := legacyShapeOutcomes(t, svc, completed.ID)
	if len(outcomes) != 1 || !strings.HasPrefix(outcomes[0], "legacy_only") {
		t.Fatalf("audit trail = %v, want one legacy_only row; a run counted twice "+
			"inflates the number the deletion decision rests on", outcomes)
	}
}

// A turn whose correction budget is already spent still answers.
//
// This is the pressure/gate boundary. Everything above this correction in the
// ladder has a better claim on the shared budget, and when it is gone the
// legacy answer must ship unchanged rather than be replaced by "I couldn't
// finish this check safely yet" — a rule that eats a correct answer over the
// shape of its JSON is not a rule worth having.
func TestLegacyWatchResultShipsWhenTheCorrectionBudgetIsSpent(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Limits.MaxAgentRunAttempts = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = legacyWatchReply
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-legacy-budget", EnvelopeID: "env-legacy-budget",
		EventID: "EvLegacyBudget", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.901", UserID: "U123ABC",
		Text: "<@U999BOT> is the checkout API healthy?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("run with no correction budget = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted turns = %d, want no correction when the budget is gone",
			len(coopClient.submitPrompts))
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "alert cleared at 09:12 UTC") ||
		strings.Contains(slackClient.posts[0].message.Text, "couldn't finish this check") {
		t.Fatalf("the answer was eaten by its own shape rule: %+v", slackClient.posts)
	}
	outcomes := legacyShapeOutcomes(t, svc, completed.ID)
	if len(outcomes) != 1 || !strings.HasPrefix(outcomes[0], "legacy_only") {
		t.Fatalf("audit trail = %v, want one legacy_only row", outcomes)
	}
}

// A typed result costs nothing. This is the counter-assertion that keeps the
// correction from becoming a tax on every watch turn.
func TestTypedWatchResultDrawsNoCorrection(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := legacyCorrectionService(
		t, ctx, []string{typedWatchReply},
	)

	finishQueuedAgentRun(t, ctx, svc)

	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("typed run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted turns = %d, want one: a typed result must not be corrected",
			len(coopClient.submitPrompts))
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("typed answer did not reach Slack: %+v", slackClient.posts)
	}
	if outcomes := legacyShapeOutcomes(t, svc, completed.ID); len(outcomes) != 0 {
		t.Fatalf("a typed result was audited as legacy: %v", outcomes)
	}
}

// The most common watch answer there is must not cost a model turn.
//
// A bare ignore has an empty operation stream, which is what LegacyShape
// measures — and it is also exactly what the contract asks ignore to return.
// Correcting it would spend a round trip per ignored Slack message.
func TestBareIgnoreDrawsNoCorrection(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, _, st, input := legacyCorrectionService(t, ctx, []string{
		`{"action":"ignore","attention":{"addressee":"human","urgency":0,"confidence":2,"novelty":0,"ownership":0},"reason":"two teammates talking to each other"}`,
	})

	finishQueuedAgentRun(t, ctx, svc)

	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("ignore run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted turns = %d; a bare ignore bought a correction turn",
			len(coopClient.submitPrompts))
	}
}

// The biggest genuine legacy population on the live instances is not a reply.
//
// Twenty-one of the recorded legacy results are an ignore that learned
// something and put it in the envelope's memory field instead of an
// update_memory operation — the exact case the prompt calls out ("if the only
// useful result is learning, return action=ignore with exactly one
// update_memory operation"). Nobody is waiting on an ignore, so this is the
// cheapest pressure there is, and it has to reach the silent path intact.
func TestLegacyIgnoreThatLearnedSomethingIsCorrectedToUpdateMemory(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := legacyCorrectionService(t, ctx, []string{
		`{"action":"ignore","attention":{"addressee":"channel","urgency":0,"confidence":3,"novelty":2,"ownership":1},"reason":"a decision worth remembering","memory":{"situation_summary":"symbols move to GCS"}}`,
		`{"action":"ignore","attention":{"addressee":"channel","urgency":0,"confidence":3,"novelty":2,"ownership":1},"reason":"a decision worth remembering","operations":[{"id":"mem","type":"update_memory","memory":{"situation_summary":"symbols move to GCS"}}]}`,
	})

	finishQueuedAgentRun(t, ctx, svc)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending {
		t.Fatalf("a legacy ignore that learned something drew no correction: %+v, %v",
			requeued, err)
	}

	finishQueuedAgentRun(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("corrected ignore = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 {
		t.Fatalf("submitted turns = %d, want exactly one correction",
			len(coopClient.submitPrompts))
	}
	if !strings.Contains(coopClient.submitPrompts[1], "update_memory") {
		t.Fatalf("correction did not name the operation that carries memory:\n%s",
			coopClient.submitPrompts[1])
	}
	// An ignore stays silent through all of it. A correction that made
	// Responder speak would be worse than the shape it was correcting.
	if len(slackClient.posts) != 0 {
		t.Fatalf("correcting an ignore made Responder speak: %+v", slackClient.posts)
	}
	outcomes := legacyShapeOutcomes(t, svc, completed.ID)
	if len(outcomes) != 2 || !strings.HasPrefix(outcomes[1], "legacy_corrected") {
		t.Fatalf("audit trail = %v, want the legacy ignore then its correction", outcomes)
	}
}
