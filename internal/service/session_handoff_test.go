package service

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
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

// Covers: TestATerminalRotatedSessionDoesNotQueueAnImpossibleHandoff
//
// A discarded Coop session cannot accept another turn. Rotation used to ask
// whether memory was stale before it asked whether the session was terminal,
// so a stale discarded session gained a pending handoff that could never run
// and its cleanup was postponed behind impossible work.
func TestATerminalRotatedSessionDoesNotQueueAnImpossibleHandoff(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if err := st.Intelligence.BindChannelSession(
		ctx, "CTERMINAL", "emisar", "ses_1", 1, 1, time.Now().UTC().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.ApplyWatchDecision(ctx, core.EvaluationDecision{
		ChannelID: "CTERMINAL", Repository: "emisar", MessageTS: "1700.901",
		SourceInput: "terminal-turn", Mode: "live", Action: "reply",
	}, "investigation", 2, core.AgentMemory{}); err != nil {
		t.Fatal(err)
	}

	coopClient := newFakeCoop()
	coopClient.session.State = "discarded"
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.retireRotatedSession(
		ctx, "ses_1", "close-terminal", "terminal rotation",
		outgoingSession{
			memoryChannelID: "CTERMINAL", repository: "emisar",
			lane: "watch", turnCount: 1,
		},
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetAgentRunBySource(
		ctx, handoffSourceKind, handoffSourceKind+":ses_1",
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("terminal session received a handoff run: %v", err)
	}
	cleanup, err := st.NextCleanup(ctx, svc.now().UTC())
	if err != nil || cleanup.SessionID != "ses_1" {
		t.Fatalf("terminal session was not queued for cleanup: %+v, %v", cleanup, err)
	}
}

// Revoking writable authority may not spend one last model turn inside the
// rejected workspace. The live legacy sessions were idle, but their stale
// transcripts made them eligible for exactly this handoff during rotation.
func TestAWritableRotatedSessionNeverReceivesAHandoffTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.Intelligence.BindChannelSession(
		ctx, "CWRITABLE", "repo", "ses_1", 1, 1, time.Now().UTC().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.ApplyWatchDecision(ctx, core.EvaluationDecision{
		ChannelID: "CWRITABLE", Repository: "repo", MessageTS: "1700.903",
		SourceInput: "writable-turn", Mode: "live", Action: "reply",
	}, "investigation", 2, core.AgentMemory{}); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.retireRotatedSession(ctx, "ses_1", "close-writable", "authority rotation", outgoingSession{
		memoryChannelID: "CWRITABLE", repository: "repo", lane: "watch", turnCount: 1,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetAgentRunBySource(
		ctx, handoffSourceKind, handoffSourceKind+":ses_1",
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("writable session received a handoff run: %v", err)
	}
	cleanup, err := st.NextCleanup(ctx, svc.now().UTC())
	if err != nil || cleanup.SessionID != "ses_1" {
		t.Fatalf("writable session was not retired directly: %+v, %v", cleanup, err)
	}
}

// A transient Coop read is not evidence that the outgoing workspace vanished.
// Treating it as successful retirement lets the channel bind a replacement
// while the old writable session and its turns remain live and cleanup-unowned.
func TestATransientSessionReadFailureCannotCompleteRetirement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.getSessionErr = &coop.APIError{Status: 503, Code: "internal_error"}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	err = svc.retireRotatedSession(
		ctx, coopClient.session.ID, "close-transient", "rotation",
		outgoingSession{memoryChannelID: "CTRANSIENT", repository: "repo", lane: "watch"},
	)
	if err == nil || !coop.Retryable(err) {
		t.Fatalf("transient retirement read returned %v", err)
	}
	if _, cleanupErr := st.GetCoopCleanup(ctx, coopClient.session.ID); !errors.Is(cleanupErr, store.ErrNotFound) {
		t.Fatalf("unproven retirement entered cleanup: %v", cleanupErr)
	}
}

// Confirmed absence is terminal, but it still needs a durable cleanup receipt
// so the outgoing session identity is not lost between rotation and audit.
func TestAMissingSessionRecordsCleanupOwnershipBeforeRetirementCompletes(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.getSessionErr = &coop.APIError{Status: 404, Code: "session_not_found"}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.retireRotatedSession(
		ctx, coopClient.session.ID, "close-missing", "rotation",
		outgoingSession{memoryChannelID: "CMISSING", repository: "repo", lane: "watch"},
	); err != nil {
		t.Fatal(err)
	}
	cleanup, err := st.GetCoopCleanup(ctx, coopClient.session.ID)
	if err != nil || cleanup.State != "pending" {
		t.Fatalf("missing session cleanup ownership = %+v, %v", cleanup, err)
	}
}

// An active read-only session is still the channel's current owner. Rotation
// must wait for its turn, not report success and strand it after rebinding.
func TestAnActiveReadOnlySessionDefersRotation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.ActiveTurnID = "turn_read_only"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	err = svc.retireRotatedSession(
		ctx, coopClient.session.ID, "close-busy-read-only", "rotation",
		outgoingSession{memoryChannelID: "CBUSY", repository: "repo", lane: "watch"},
	)
	if err == nil || !strings.Contains(err.Error(), "still has active or queued work") {
		t.Fatalf("active read-only retirement returned %v", err)
	}
	if coopClient.session.State != "open" {
		t.Fatalf("active read-only session was closed: %+v", coopClient.session)
	}
	if _, cleanupErr := st.GetCoopCleanup(ctx, coopClient.session.ID); !errors.Is(cleanupErr, store.ErrNotFound) {
		t.Fatalf("active bound session was orphaned into cleanup: %v", cleanupErr)
	}
}

// An active writable turn is authority still in use, not a reason to abandon
// rotation. Leaving it alive after rebinding the channel lets the rejected
// workspace keep writing with no durable owner.
func TestWritableTurnsAreRevokedBeforeSessionRetirement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.ActiveTurnID = "turn_writable"
	coopClient.listTurns = []coop.Turn{{
		ID: "turn_writable", SessionID: coopClient.session.ID, Ordinal: 1, State: "running",
	}}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	if err := svc.retireRotatedSession(
		ctx, coopClient.session.ID, "close-active-writable", "authority rotation",
		outgoingSession{memoryChannelID: "CWRITABLE", repository: "repo", lane: "watch", turnCount: 1},
	); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(coopClient.cancelTurns, []string{"turn_writable"}) {
		t.Fatalf("revoked turns = %v", coopClient.cancelTurns)
	}
	cleanup, err := st.GetCoopCleanup(ctx, coopClient.session.ID)
	if err != nil || cleanup.State != "pending" || coopClient.session.State != "closed" {
		t.Fatalf("retired writable session = %+v cleanup %+v, %v", coopClient.session, cleanup, err)
	}
}

// A session can become terminal after rotation admitted its handoff but before
// that background run is leased. This happened when a provider-limited handoff
// was retried after Coop discarded the outgoing session: no Slack work was
// lost, yet the bookkeeping episode was recorded as an operator-facing failure.
func TestQueuedHandoffWhoseSessionBecomesTerminalFinishesAsABenignFallback(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if err := st.Intelligence.BindChannelSession(
		ctx, "CTERMINALAFTERQUEUE", "emisar", "ses_1", 1, 1,
		time.Now().UTC().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.ApplyWatchDecision(ctx, core.EvaluationDecision{
		ChannelID: "CTERMINALAFTERQUEUE", Repository: "emisar",
		MessageTS: "1700.902", SourceInput: "terminal-after-queue",
		Mode: "live", Action: "reply",
	}, "investigation", 2, core.AgentMemory{}); err != nil {
		t.Fatal(err)
	}

	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if !svc.queueSessionHandoff(ctx, "ses_1", outgoingSession{
		memoryChannelID: "CTERMINALAFTERQUEUE", repository: "emisar",
		lane: "watch", turnCount: 1,
	}) {
		t.Fatal("handoff was not queued while the outgoing session was open")
	}
	coopClient.session.State = "discarded"
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}

	run, err := st.GetAgentRunBySource(
		ctx, handoffSourceKind, handoffSourceKind+":ses_1",
	)
	if err != nil {
		t.Fatal(err)
	}
	if run.State != core.AgentRunSuperseded || run.TerminalState != "" ||
		run.Failures != 0 {
		t.Fatalf("terminal-after-queue handoff = %+v", run)
	}
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil || episode.State != core.EpisodeSuperseded {
		t.Fatalf("benign handoff fallback episode = %+v, %v", episode, err)
	}
	cleanup, err := st.NextCleanup(ctx, svc.now().UTC())
	if err != nil || cleanup.SessionID != "ses_1" {
		t.Fatalf("terminal session cleanup = %+v, %v", cleanup, err)
	}
}

// Retirement is part of completing the handoff, not best-effort work after
// completion. Otherwise a transient Coop read makes the durable run terminal
// while its outgoing workspace is still open and has no cleanup owner.
func TestAHandoffFallbackRemainsRetryableUntilRetirementIsOwned(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, SourceKind: handoffSourceKind,
		SourceID: handoffSourceKind + ":ses_fallback", SessionID: "ses_fallback",
		ChannelID: "CHANDOFF", ConversationKey: "handoff:CHANDOFF",
		Repository: "repo", Prompt: "summarize",
		Episode: &core.WorkEpisode{Mode: core.EpisodeConversation},
	})
	if err != nil || !created {
		t.Fatalf("queue handoff = %+v, %t, %v", run, created, err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_fallback"
	coopClient.getSessionErr = &coop.APIError{Status: 503, Code: "internal_error"}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.abandonSessionHandoff(ctx, run, errors.New("handoff unavailable")); err == nil {
		t.Fatal("transient retirement failure was hidden")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State == core.AgentRunSuperseded || stored.State == core.AgentRunCompleted {
		t.Fatalf("handoff became terminal before retirement: %+v", stored)
	}
	coopClient.getSessionErr = nil
	if err := svc.abandonSessionHandoff(ctx, stored, errors.New("handoff unavailable")); err != nil {
		t.Fatal(err)
	}
	stored, err = st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunSuperseded {
		t.Fatalf("retired fallback handoff = %+v, %v", stored, err)
	}
}

// The successful handoff path has the same ordering invariant. A transient
// close failure must leave finalization leasable until cleanup ownership is on
// disk, rather than completing a run that can never be finalized again.
func TestACompletedHandoffRemainsRetryableUntilRetirementIsOwned(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, SourceKind: handoffSourceKind,
		SourceID: handoffSourceKind + ":ses_complete", SessionID: "ses_complete",
		ChannelID: "CHANDOFF", ConversationKey: "handoff:CHANDOFF",
		Repository: "repo", Prompt: "summarize",
		Episode: &core.WorkEpisode{Mode: core.EpisodeConversation},
	})
	if err != nil || !created {
		t.Fatalf("queue handoff = %+v, %t, %v", run, created, err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, run.ID, "turn_handoff", 1, 0); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, run.ID, "failed", nil, "handoff result unavailable", 0); err != nil {
		t.Fatal(err)
	}
	run, err = st.LeaseAgentRunFinalization(ctx)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_complete"
	coopClient.closeErrors = []error{&coop.APIError{Status: 503, Code: "internal_error"}}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.finalizeSessionHandoffTurn(ctx, run); err == nil {
		t.Fatal("transient close failure was hidden")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State == core.AgentRunCompleted {
		t.Fatalf("handoff completed before cleanup ownership: %+v", stored)
	}
	if err := svc.finalizeSessionHandoffTurn(ctx, stored); err != nil {
		t.Fatal(err)
	}
	stored, err = st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("retired completed handoff = %+v, %v", stored, err)
	}
	if _, err := st.GetCoopCleanup(ctx, "ses_complete"); err != nil {
		t.Fatalf("retired completed handoff has no cleanup owner: %v", err)
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
