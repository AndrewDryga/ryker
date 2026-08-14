package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// A turn that answers and remembers nothing. The Coop transcript is the only
// place its thirty minutes of reasoning exists, and rotation deletes it.
const handoffReplyWithoutMemory = `{
	"action":"reply",
	"operations":[{"id":"complete","type":"complete_episode","completion":{
		"message":"Checkout latency is back inside its budget.",
		"completion":{"status":"decision_ready","summary":"answered"}}}]
}`

// The same turn, having written memory on its way out. Rotation costs nothing
// here, so a handoff turn would be a model turn spent on nothing.
const handoffReplyWithMemory = `{
	"action":"reply",
	"operations":[
		{"id":"mem","type":"update_memory","memory":{
			"situation_summary":"Checkout latency recovered after the cache rollout.",
			"open_loops":["Confirm the rollout guard landed."]}},
		{"id":"complete","type":"complete_episode","completion":{
			"message":"Checkout latency is back inside its budget.",
			"completion":{"status":"decision_ready","summary":"answered"}}}]
}`

// The handoff turn's own answer: a silent ignore carrying exactly one
// update_memory, which is the only shape the watch dialect allows for it.
const handoffMemoryResult = `{
	"action":"ignore",
	"reason":"carrying this session's context into the next one",
	"operations":[{"id":"handoff","type":"update_memory","memory":{
		"situation_summary":"Checkout latency was traced to cache warmup after the rollout.",
		"open_loops":["Confirm the rollout guard landed."],
		"decisions":["Keep watching checkout p99 for the next deploy."]}}]
}`

// Covers: a rotated session's transcript is the richest continuity Responder
// has, and it evaporates at the rotation boundary. A model that spent thirty
// turns investigating and never emitted update_memory used to hand its
// successor a stale or empty summary, so the first post-rotation turn re-derived
// what the transcript already knew — while the prompt overhauled on 2026-08-14
// told it "Continue; do not restart" against memory nothing had refreshed.
//
// The three claims are separate on purpose. The handoff must run in the
// OUTGOING session (the new one has no transcript to summarize, so a handoff
// asked there is a model turn spent on nothing), its memory must land under the
// channel every later turn reads, and the user's own turn must not wait for
// either.
func TestARotatedSessionHandsItsMemoryForward(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CHANDOFF"}
	cfg.Slack.WatchChannels = nil
	cfg.Coop.WatchSessionTurns = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		handoffReplyWithoutMemory, handoffReplyWithoutMemory, handoffMemoryResult,
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	runWatchedMention(t, ctx, svc, st, "handoff-1", "1700.801", "CHANDOFF",
		"<@U999BOT> is checkout latency still bad?")
	firstSession := coopClient.session.ID

	// The next request rotates: one turn was taken and the cap is one.
	coopClient.openAfterCreateKey = "responder:watch-session:CHANDOFF:2"
	admitWatchedMention(t, ctx, st, cfg.Slack.TeamID, "handoff-2", "1700.802",
		"CHANDOFF", "<@U999BOT> and now?")
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	user, err := st.GetAgentRunBySource(ctx, "watch", "handoff-2")
	if err != nil {
		t.Fatal(err)
	}
	if user.SessionID == firstSession || user.SessionGeneration != 2 {
		t.Fatalf(
			"the triggering turn did not run on the new session: %s generation %d (old %s)",
			user.SessionID, user.SessionGeneration, firstSession,
		)
	}
	handoff, err := st.GetAgentRunBySource(ctx, "handoff", "handoff:"+firstSession)
	if err != nil {
		t.Fatalf("no handoff run was queued for the retiring session %s: %v", firstSession, err)
	}
	if handoff.State != core.AgentRunPending {
		t.Fatalf(
			"the triggering turn waited on the handoff: handoff state %q, want pending",
			handoff.State,
		)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if user, err = st.GetAgentRun(ctx, user.ID); err != nil ||
		user.State != core.AgentRunCompleted {
		t.Fatalf("the triggering turn did not finish on the new session: %+v, %v", user, err)
	}

	// Only now does the handoff turn run, in the session rotation left behind.
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitSessions) != 3 {
		t.Fatalf("submitted turns = %v, want three", coopClient.submitSessions)
	}
	if coopClient.submitSessions[2] != firstSession {
		t.Fatalf(
			"the handoff turn ran in %q, not the retiring session %q",
			coopClient.submitSessions[2], firstSession,
		)
	}
	memory, err := st.Intelligence.GetChannelMemory(ctx, "CHANDOFF")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(memory.State.SituationSummary, "cache warmup") ||
		len(memory.State.OpenLoops) != 1 || len(memory.State.Decisions) != 1 {
		t.Fatalf("the handoff memory did not reach the channel: %+v", memory.State)
	}
	if len(slackClient.posts) != 2 {
		t.Fatalf("the handoff turn was not silent: %+v", slackClient.posts)
	}
	// The session rotation left open for the handoff is retired once it is done,
	// exactly as an ordinary rotation retires it immediately.
	cleanup, err := st.NextCleanup(ctx, svc.now().UTC())
	if err != nil || cleanup.SessionID != firstSession {
		t.Fatalf("the handed-off session was not retired: %+v, %v", cleanup, err)
	}
}

// Covers: the freshness half of the same rule. The handoff costs a real model
// turn, so a session whose last turn already wrote memory must not spend one —
// otherwise every rotation on a well-behaved channel buys a summary of a
// summary.
func TestAFreshlyRememberedSessionRotatesWithoutAHandoffTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CFRESH"}
	cfg.Slack.WatchChannels = nil
	cfg.Coop.WatchSessionTurns = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{handoffReplyWithMemory, handoffReplyWithoutMemory}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	runWatchedMention(t, ctx, svc, st, "fresh-1", "1700.811", "CFRESH",
		"<@U999BOT> is checkout latency still bad?")
	firstSession := coopClient.session.ID
	coopClient.openAfterCreateKey = "responder:watch-session:CFRESH:2"
	runWatchedMention(t, ctx, svc, st, "fresh-2", "1700.812", "CFRESH",
		"<@U999BOT> and now?")

	if _, err := st.GetAgentRunBySource(ctx, "handoff", "handoff:"+firstSession); !errors.Is(
		err, store.ErrNotFound,
	) {
		t.Fatalf("a handoff turn was spent on memory that was already fresh: %v", err)
	}
	if len(coopClient.submitSessions) != 2 {
		t.Fatalf("submitted turns = %v, want exactly the two user turns", coopClient.submitSessions)
	}
	// Rotation behaves exactly as it did before: the outgoing session is closed
	// and queued for cleanup on the spot.
	cleanup, err := st.NextCleanup(ctx, svc.now().UTC())
	if err != nil || cleanup.SessionID != firstSession {
		t.Fatalf("the rotated session was not retired immediately: %+v, %v", cleanup, err)
	}
}

func admitWatchedMention(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	teamID string,
	id string,
	messageTS string,
	channelID string,
	text string,
) {
	t.Helper()
	created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id, Kind: "mention",
		TeamID: teamID, ChannelID: channelID, MessageTS: messageTS,
		UserID: "U123ABC", Text: text,
	})
	if err != nil || !created {
		t.Fatalf("admit %s = %v, %v", id, created, err)
	}
}

func runWatchedMention(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	st *store.Store,
	id string,
	messageTS string,
	channelID string,
	text string,
) {
	t.Helper()
	admitWatchedMention(t, ctx, st, svc.cfg.Slack.TeamID, id, messageTS, channelID, text)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
}
