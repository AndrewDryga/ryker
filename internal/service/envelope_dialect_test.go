package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// legacyWatchReply is a real answer in the retired dialect: the result sits in
// the envelope's own fields and there is no operation stream at all.
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

// This is the model result that production rejected for the operator's
// ship-fast Terraform guidance. Its only syntax defect is the third `}` before
// the operations array closes at the very end; the reply and memory operation
// themselves are complete and valid.
const watchReplyWithOneSpuriousObjectClose = `{"action":"reply","attention":{"addressee":"responder","urgency":0,"confidence":3,"novelty":1,"ownership":2,"contribution":"decision","material":true},"reason":"The operator set a clear approval policy that can be acknowledged directly.","operations":[{"id":"complete","type":"complete_episode","completion":{"message":"Understood. I’ll recommend holding approval only when there is a concrete risk. Otherwise I’ll default to shipping.","completion":{"status":"decision_ready","summary":"Accepted the ship-fast approval policy."}}},{"id":"learned","type":"update_memory","memory":{"knowledge":[{"subject":"Terraform deployment approval guidance","kind":"decision","statement":"Default to shipping Terraform changes quickly. Recommend holding approval only for a concrete production risk.","status":"accepted","confidence":3,"source_ref":"https://app.slack.com/client/T/C/thread/C-1700.900","source_message_ts":"1700.901"}]}}}]}`

// envelopeDialectService is the arrangement these cases share: one watched
// channel, one mention, and a scripted Coop.
func envelopeDialectService(
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
		EventID: "EvEnvelopeDialect", Kind: "mention", TeamID: cfg.Slack.TeamID,
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

// There is one result dialect, and an answer in the other one does not reach
// Slack.
//
// For six days the host read the retired shape, acted on it, and asked once —
// politely, from a correction class of its own — for the same decision back in
// typed operations. That tolerance is what taught every model serving both
// lanes two dialects for the same channel, and it is now deleted: an envelope
// carrying its result in top-level fields is a result the host cannot read, and
// it draws the ordinary unreadable correction like any other malformed answer.
// Evidence for the deletion: zero result.legacy_shape audit rows on either live
// instance after the honest-metric deploy, and the two legacy_corrected rows
// before it were the last answers in the old dialect.
func TestLegacyEnvelopeReplyIsRejectedAsUnreadable(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := envelopeDialectService(
		t, ctx, []string{legacyWatchReply, typedWatchReply},
	)

	finishQueuedAgentRun(t, ctx, svc)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending {
		t.Fatalf("the retired dialect was accepted instead of rejected: %+v, %v",
			requeued, err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("an unreadable answer reached Slack: %+v", slackClient.posts)
	}
	if outcomes := auditOutcomes(t, svc.cfg, "result.correction", requeued.ID); len(outcomes) != 1 ||
		!strings.HasPrefix(outcomes[0], "unreadable") {
		t.Fatalf("correction classes = %v, want one unreadable; the legacy_shape "+
			"class is deleted and this must not be counted under a class of its own",
			outcomes)
	}

	finishQueuedAgentRun(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("corrected run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 {
		t.Fatalf("submitted turns = %d, want exactly one correction",
			len(coopClient.submitPrompts))
	}
	// The correction has to name the fields that could not be read and the
	// operations that carry them. A rejection that only says "invalid" leaves
	// the model guessing at the dialect it was supposed to use.
	correction := coopClient.submitPrompts[1]
	for _, required := range []string{
		"<host-structured-correction>",
		"structured Slack response is invalid",
		"message, memory",
		"complete_episode",
		"update_memory",
	} {
		if !strings.Contains(correction, required) {
			t.Fatalf("correction prompt does not mention %q:\n%s", required, correction)
		}
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "alert cleared at 09:12 UTC") {
		t.Fatalf("the typed answer did not reach Slack: %+v", slackClient.posts)
	}
	if outcomes := auditOutcomes(t, svc.cfg, "result.legacy_shape", ""); len(outcomes) != 0 {
		t.Fatalf("the retired legacy_shape audit was written: %v", outcomes)
	}
}

// The largest genuine population in the old dialect was never a reply.
//
// Twenty-one of the recorded legacy results are an ignore that learned
// something and put it in the envelope's memory field instead of an
// update_memory operation. Nobody is waiting on an ignore, so this is the
// cheapest place to hold the line — and the rejection has to reach the silent
// path intact, because a rejection that made Responder speak in a conversation
// it had decided to stay out of would be worse than the shape it refused.
func TestLegacyEnvelopeIgnoreThatLearnedSomethingIsRejectedAsUnreadable(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := envelopeDialectService(t, ctx, []string{
		`{"action":"ignore","attention":{"addressee":"channel","urgency":0,"confidence":3,"novelty":2,"ownership":1},"reason":"a decision worth remembering","memory":{"situation_summary":"symbols move to GCS"}}`,
		`{"action":"ignore","attention":{"addressee":"channel","urgency":0,"confidence":3,"novelty":2,"ownership":1},"reason":"a decision worth remembering","operations":[{"id":"mem","type":"update_memory","memory":{"situation_summary":"symbols move to GCS"}}]}`,
	})

	finishQueuedAgentRun(t, ctx, svc)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending {
		t.Fatalf("a legacy ignore that learned something was accepted: %+v, %v",
			requeued, err)
	}
	if outcomes := auditOutcomes(t, svc.cfg, "result.correction", requeued.ID); len(outcomes) != 1 ||
		!strings.HasPrefix(outcomes[0], "unreadable") {
		t.Fatalf("correction classes = %v, want one unreadable", outcomes)
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
	if len(slackClient.posts) != 0 {
		t.Fatalf("rejecting an ignore made Responder speak: %+v", slackClient.posts)
	}
}

// The cost of the deletion, stated where it can be seen.
//
// While the old dialect was tolerated, an answer that ran out of correction
// budget shipped in whatever shape it was in. A rejected result cannot: it is
// unreadable, so the turn blocks like any other unreadable turn. That is the
// price of one dialect, and it is only ever paid by a model still answering in
// a shape the prompt stopped teaching on 2026-08-14.
func TestLegacyEnvelopeWithNoCorrectionBudgetLeftDoesNotShip(t *testing.T) {
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

	if len(slackClient.posts) == 1 &&
		strings.Contains(slackClient.posts[0].message.Text, "alert cleared at 09:12 UTC") {
		t.Fatalf("an unreadable result shipped its envelope answer: %+v", slackClient.posts)
	}
}

// A typed result costs nothing. This is the counter-assertion that keeps the
// envelope rule from becoming a tax on every watch turn.
func TestTypedWatchResultDrawsNoCorrection(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := envelopeDialectService(
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
}

// Three production turns repeated the same one-character closing-delimiter
// mistake. Responder discarded the valid acknowledgment and accepted memory
// each time, then told the operator it could not finish. A syntactically
// impossible extra close must not cost the whole result when deleting that one
// byte produces a result that still passes the complete strict contract.
func TestOneSpuriousObjectCloseDoesNotDiscardReplyAndMemory(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, slackClient, st, input := envelopeDialectService(
		t, ctx, []string{watchReplyWithOneSpuriousObjectClose},
	)

	finishQueuedAgentRun(t, ctx, svc)

	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted {
		t.Fatalf("recovered run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted turns = %d, want one: a harmless extra close must not draw corrections",
			len(coopClient.submitPrompts))
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "default to shipping") {
		t.Fatalf("accepted guidance did not reach Slack: %+v", slackClient.posts)
	}
	memory, err := st.Intelligence.GetConversationMemory(ctx, input.ChannelID, "")
	if err != nil || len(memory.State.Knowledge) != 1 ||
		memory.State.Knowledge[0].Subject != "Terraform deployment approval guidance" {
		t.Fatalf("accepted guidance memory = %+v, %v", memory, err)
	}
}

// The most common watch answer there is must not cost a model turn.
//
// A bare ignore has no operation stream and nothing in the envelope to move,
// and it is exactly what the contract asks ignore to return. Rejecting it would
// spend a round trip per ignored Slack message — 110 of the 147 readable
// envelope-shaped results across both live instances were bare envelopes with
// nothing in them, and that is the population this rule must never touch.
func TestBareIgnoreDrawsNoCorrection(t *testing.T) {
	ctx := context.Background()
	svc, coopClient, _, st, input := envelopeDialectService(t, ctx, []string{
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
