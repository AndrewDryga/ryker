package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/provider"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestEmisarApprovalMonitorUpdatesCardAndQueuesOneContinuation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_approval_monitor", EnvelopeID: "env_approval_monitor",
		EventID: "EvApprovalMonitor", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "Enable the exact governed setting.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	approval, created, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_monitor", ChannelID: input.ChannelID,
		SourceInput: input.ID, RequestedBy: input.UserID,
		RunID: "run_monitor", OperationID: "op_monitor",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_monitor",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil || !created {
		t.Fatalf("record approval = %+v, %t, %v", approval, created, err)
	}
	body, err := slackui.Encode(slackui.WithEmisarApproval(
		slackui.ConversationResponse("Ready for approval.", slackui.NewSanitizer(12000)),
		approval,
	))
	if err != nil {
		t.Fatal(err)
	}
	deliveryID := "watch_reply_" + input.ID
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: deliveryID, Operation: "post", Kind: "notice",
		ChannelID: input.ChannelID, ThreadTS: input.MessageTS, Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BindEmisarApprovalDelivery(ctx, approval.RequestID, deliveryID); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	emisarClient := &fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: approval.OperationID,
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: "success",
		RunURL: "https://emisar.dev/app/acme/runs/run_monitor",
	}}
	svc.SetEmisar(emisarClient)
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetEmisarApproval(ctx, approval.RequestID)
	if err != nil || stored.Status != "success" || !stored.ContinuationQueued ||
		stored.MessageTS == "" || stored.RunURL == "" {
		t.Fatalf("monitored approval = %+v, %v", stored, err)
	}
	run, err := st.GetAgentRunBySource(
		ctx,
		"emisar_approval:"+approval.RequestID,
		input.ID,
	)
	if err != nil || run.Prompt == "" || run.Mode != core.AgentRunTriage {
		t.Fatalf("approval continuation = %+v, %v", run, err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil || !state.ApprovalContinuation ||
		state.ReplyDeliveryID != "emisar_approval_reply_"+approval.RequestID {
		t.Fatalf("approval continuation state = %+v, %v", state, err)
	}
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	if emisarClient.calls != 1 {
		t.Fatalf("terminal approval was polled again: %d calls", emisarClient.calls)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.updates) != 1 ||
		slackClient.updates[0].message.Header != "Emisar action completed" {
		t.Fatalf("approval Slack update = %+v", slackClient.updates)
	}
}

func TestEmisarApprovalMonitorFailsClosedOnIdentityMismatch(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	approval, _, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_mismatch", ChannelID: "CWATCH",
		SourceInput: "slack_mismatch", RequestedBy: "U123ABC",
		RunID: "run_mismatch", OperationID: "op_expected",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_mismatch",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.SetEmisar(&fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: "op_other",
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: "success",
	}})
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err == nil ||
		!strings.Contains(err.Error(), "immutable identity") {
		t.Fatalf("identity mismatch error = %v", err)
	}
	stored, err := st.GetEmisarApproval(ctx, approval.RequestID)
	if err != nil || stored.Status != "pending_approval" || stored.ContinuationQueued {
		t.Fatalf("mismatched approval was advanced = %+v, %v", stored, err)
	}
}

func TestEmisarApprovalMonitorPersistsProgressWithoutQueueingContinuation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	approval, _, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_running", ChannelID: "CWATCH",
		SourceInput: "slack_running", RequestedBy: "U123ABC",
		RunID: "run_running", OperationID: "op_running",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_running",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	emisarClient := &fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: approval.OperationID,
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: "running",
		RunURL: "https://emisar.dev/app/acme/runs/run_running",
	}}
	svc.SetEmisar(emisarClient)
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetEmisarApproval(ctx, approval.RequestID)
	if err != nil || stored.Status != "running" || stored.ContinuationQueued ||
		stored.RunURL == "" || !stored.NextCheckAt.After(stored.UpdatedAt) {
		t.Fatalf("running approval = %+v, %v", stored, err)
	}
	if _, err := st.GetAgentRunBySource(
		ctx,
		"emisar_approval:"+approval.RequestID,
		approval.SourceInput,
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("nonterminal approval queued a model continuation: %v", err)
	}
}

func TestEmisarApprovalSchedulerRecoversPersistedTerminalRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	approval, _, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_restart", ChannelID: "CWATCH",
		SourceInput: "slack_restart", RequestedBy: "U123ABC",
		RunID: "run_restart", OperationID: "op_restart",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_restart",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	approval, _, err = st.AdvanceEmisarApproval(
		ctx,
		approval.RequestID,
		"success",
		"https://emisar.dev/app/acme/runs/run_restart",
		"",
		time.Now().UTC(),
	)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.seedEmisarApprovalWork(ctx); err != nil {
		t.Fatal(err)
	}
	work, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if work.Kind != workEmisarApproval || work.SubjectID != approval.RequestID {
		t.Fatalf("recovered approval work = %+v", work)
	}
}

func TestAgentRunInterruptedByResponderShutdownIsReplayed(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-restart", 1,
	); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg,
		st,
		coopClient,
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	run, created, err := svc.queueIncidentAgentRun(
		ctx,
		incident,
		"initial",
		incident.ID,
		"",
		"Investigate the alert.",
	)
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	running, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || running.State != core.AgentRunRunning ||
		running.CoopTurnID != "coop_turn_1" ||
		running.SessionID != coopClient.session.ID {
		t.Fatalf("first submission = %+v, %v", running, err)
	}
	firstKey := running.IdempotencyKey
	coopClient.turn.State = "failed"
	coopClient.turn.ErrorCode = "acp_cancelled"
	coopClient.turn.ErrorDetail = "turn cancelled"
	coopClient.session.ActiveTurnID = ""
	coopClient.session.State = "open"
	coopClient.session.Activity = "parked"
	coopClient.session.Revision++
	coopClient.events = append(coopClient.events, coop.Event{
		ID: "evt_restart", SessionID: coopClient.session.ID, Sequence: 1,
		TurnID: "coop_turn_1", Type: "turn.failed",
	})
	svc.pollAgentRuns(ctx)
	requeued, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || requeued.State != core.AgentRunPending ||
		requeued.Failures != 1 || requeued.CoopTurnID != "" ||
		requeued.ExpectedRevision != 0 ||
		requeued.CoopEventSequence != 1 ||
		requeued.IdempotencyKey == firstKey {
		t.Fatalf("requeued run = %+v, %v", requeued, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ActiveTurnID != "" ||
		incident.Workflow != core.WorkflowParked ||
		incident.CoopEventSequence != 1 {
		t.Fatalf("released incident = %+v, %v", incident, err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	replayed, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || replayed.State != core.AgentRunRunning ||
		replayed.CoopTurnID != "coop_turn_2" ||
		replayed.IdempotencyKey != requeued.IdempotencyKey {
		t.Fatalf("replayed run = %+v, %v", replayed, err)
	}
	if len(coopClient.submitKeys) != 2 ||
		coopClient.submitKeys[0] == coopClient.submitKeys[1] {
		t.Fatalf("submission keys = %v", coopClient.submitKeys)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ActiveTurnID != replayed.CoopTurnID ||
		incident.Workflow != core.WorkflowInvestigating {
		t.Fatalf("replayed incident = %+v, %v", incident, err)
	}
}

func TestExplicitAgentRunCancellationIsTerminal(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CWATCH", ThreadTS: "1700.100",
		ConversationKey: "thread:CWATCH:1700.100",
		SourceKind:      "watch", SourceID: "explicit-cancel",
		SessionID: "ses_1", Context: []byte("{}"),
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx, leased.ID, "coop_turn_1", 2, 0,
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.turn = coop.Turn{
		ID: "coop_turn_1", SessionID: "ses_1", State: "cancelled",
		ErrorCode: "acp_cancelled", ErrorDetail: "turn cancelled",
	}
	coopClient.events = []coop.Event{{
		ID: "evt_cancel", SessionID: "ses_1", Sequence: 1,
		TurnID: "coop_turn_1", Type: "turn.cancelled",
	}}
	svc := New(
		cfg,
		st,
		coopClient,
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.pollAgentRuns(ctx)
	staged, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || staged.State != core.AgentRunApplying ||
		staged.TerminalState != "cancelled" || staged.Failures != 0 {
		t.Fatalf("explicit cancellation = %+v, %v", staged, err)
	}
}

// An exhausted target ladder is the providers saying "not now", not the run
// failing. Coop has already tried every rung by the time it surfaces this, so
// it must wait rather than be replayed like a transport blip — replaying spends
// attempts against a window that has not moved, and once they are spent the
// operator gets an error for work that was never wrong. The wait itself is
// [provider.LadderRetryDelay]; this pins that it never reaches the paths that
// would count it.
func TestExhaustedTargetLadderWaitsInsteadOfBurningAttempts(t *testing.T) {
	limited := coop.Turn{
		ErrorCode:   "rate_limited",
		ErrorDetail: "every target in the policy ladder is rate limited until 2026-08-07T18:30:00Z",
	}
	if !provider.LadderExhausted(limited.ErrorCode) {
		t.Fatal("an exhausted ladder was not recognised as a provider refusal")
	}
	if terminalACPEnvironmentFailure(limited) {
		t.Fatal("an exhausted ladder was treated as a terminal environment failure")
	}
	if replayAgentRunInFreshSession(limited) {
		t.Fatal("an exhausted ladder discarded the session; the session is fine, the rungs are cooling")
	}
	// It must not reach the ordinary replay path, which counts the attempt.
	if reason, replay := replayAgentRunFailure(
		core.AgentRun{Failures: 0}, "turn.failed", limited, 20,
	); replay || reason != "" {
		t.Fatalf("an exhausted ladder was replayed as a failure = %q, %t", reason, replay)
	}

}

func TestAgentRunProtocolReplayIsExactAndBounded(t *testing.T) {
	run := core.AgentRun{Failures: 0}
	oversized := coop.Turn{
		ErrorCode:   "acp_protocol_error",
		ErrorDetail: "ACP frame exceeded its bound",
	}
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", oversized, 20,
	); !replay || !strings.Contains(reason, "oversized ACP frame") {
		t.Fatalf("oversized frame replay = %q, %t", reason, replay)
	}
	run.Failures = 1
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", oversized, 20,
	); replay || reason != "" {
		t.Fatalf("oversized frame replay was not bounded = %q, %t", reason, replay)
	}
	transcript := coop.Turn{
		ErrorCode:   "acp_protocol_error",
		ErrorDetail: "ACP transcript exceeded its bound",
	}
	run.Mode = core.AgentRunTriage
	for _, failures := range []int{0, 3, 18} {
		run.Failures = failures
		if reason, replay := replayAgentRunFailure(
			run, "turn.failed", transcript, 20,
		); !replay || !strings.Contains(reason, "fresh read-only session") {
			t.Fatalf(
				"transcript overflow %d replay = %q, %t",
				failures,
				reason,
				replay,
			)
		}
	}
	run.Failures = 19
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", transcript, 20,
	); replay || reason != "" {
		t.Fatalf("transcript overflow ignored configured poison budget = %q, %t", reason, replay)
	}
	run.Mode = core.AgentRunIncident
	run.Failures = 0
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", transcript, 20,
	); replay || reason != "" {
		t.Fatalf("writable transcript overflow replayed = %q, %t", reason, replay)
	}
	cleanupFailure := coop.Turn{
		ErrorCode:   "acp_protocol_error",
		ErrorDetail: "turn cleanup failed",
	}
	for failures := 0; failures < 2; failures++ {
		run.Failures = failures
		if reason, replay := replayAgentRunFailure(
			run, "turn.failed", cleanupFailure, 20,
		); !replay || !strings.Contains(reason, "retrying") {
			t.Fatalf(
				"cleanup failure %d replay = %q, %t",
				failures,
				reason,
				replay,
			)
		}
	}
	run.Failures = 2
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", cleanupFailure, 20,
	); replay || reason != "" {
		t.Fatalf("cleanup failure replay was not bounded = %q, %t", reason, replay)
	}
	childClosed := coop.Turn{
		ErrorCode:   "acp_process_error",
		ErrorDetail: "ACP child closed before its response",
	}
	run.Mode = core.AgentRunTriage
	for failures := 0; failures < 19; failures++ {
		run.Failures = failures
		if reason, replay := replayAgentRunFailure(
			run, "turn.failed", childClosed, 20,
		); !replay || !strings.Contains(reason, "fresh read-only session") {
			t.Fatalf(
				"ACP process failure %d replay = %q, %t",
				failures,
				reason,
				replay,
			)
		}
	}
	run.Failures = 19
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", childClosed, 20,
	); replay || reason != "" {
		t.Fatalf("ACP process failure replay was not bounded = %q, %t", reason, replay)
	}
	for _, detail := range []string{
		"ACP child closed before its response: Coop box image is not built; run 'coop build'",
		"ACP child closed before its response: Coop runtime storage is full",
		"ACP child closed before its response: Coop cannot reach the Docker runtime",
		"ACP child closed before its response: the configured Coop account is not authenticated; run 'coop login'",
		"ACP child closed before its response: credential is not portable through the turn deadline",
		"provider credential needs sign-in or renewal",
	} {
		environmentFailure := coop.Turn{
			ErrorCode:   "acp_process_error",
			ErrorDetail: detail,
		}
		run.Failures = 0
		if reason, replay := replayAgentRunFailure(
			run, "turn.failed", environmentFailure, 20,
		); replay || reason != "" || replayAgentRunInFreshSession(environmentFailure) {
			t.Fatalf("environment failure replayed = %q, %t, %q", reason, replay, detail)
		}
	}
	run.Mode = core.AgentRunIncident
	run.Failures = 0
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", childClosed, 20,
	); replay || reason != "" {
		t.Fatalf("writable ACP process failure replayed = %q, %t", reason, replay)
	}
	if !replayAgentRunInFreshSession(childClosed) ||
		!replayAgentRunInFreshSession(transcript) ||
		!replayAgentRunInFreshSession(coop.Turn{
			ErrorCode: "acp_cancelled", ErrorDetail: "turn cancelled",
		}) || replayAgentRunInFreshSession(coop.Turn{
		ErrorCode: "acp_cancelled", ErrorDetail: "operator cancelled",
	}) {
		t.Fatal("fresh-session recovery classification is not exact")
	}
	run.Failures = 0
	for _, candidate := range []struct {
		event string
		turn  coop.Turn
	}{
		{event: "turn.cancelled", turn: oversized},
		{
			event: "turn.failed",
			turn: coop.Turn{
				ErrorCode: "acp_protocol_error", ErrorDetail: "invalid ACP response",
			},
		},
		{
			event: "turn.failed",
			turn: coop.Turn{
				ErrorCode: "acp_cancelled", ErrorDetail: "operator cancelled",
			},
		},
	} {
		if reason, replay := replayAgentRunFailure(
			run, candidate.event, candidate.turn, 20,
		); replay || reason != "" {
			t.Fatalf(
				"unrelated failure replayed: event=%s turn=%+v reason=%q",
				candidate.event,
				candidate.turn,
				reason,
			)
		}
	}
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", oversized, 1,
	); replay || reason != "" {
		t.Fatalf("configured terminal attempt replayed = %q, %t", reason, replay)
	}
}

func TestAgentRunACPProcessFailureRotatesSlackInvestigationSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CPROCESS"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-process-recovery", EnvelopeID: "env-process-recovery",
		EventID: "event-process-recovery", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CPROCESS", MessageTS: "1700.710", UserID: "U123ABC",
		Text: "<@U999BOT> graph the last seven days of Cassandra CPU load",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_process_error",
			ErrorDetail: "ACP child closed before its response",
		},
		{
			State: "completed",
			AssistantMessage: `{
				"action":"reply",
				"message":"The seven-day Cassandra CPU graph is ready."
			}`,
		},
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending || requeued.Failures != 1 {
		t.Fatalf("requeued process failure = %+v, %v", requeued, err)
	}
	firstSession := requeued.SessionID
	coopClient.openAfterCreateKey = "responder:watch-session:CPROCESS:2"
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted ||
		completed.SessionID == firstSession || completed.SessionGeneration != 2 {
		t.Fatalf("recovered Slack run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[1], "<host-transport-recovery>") ||
		!strings.Contains(coopClient.submitPrompts[1], "Long task duration is not a reason to stop") {
		t.Fatalf("process recovery prompts = %+v", coopClient.submitPrompts)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "graph is ready") ||
		strings.Contains(slackClient.posts[0].message.Text, "could not complete") {
		t.Fatalf("process recovery result = %+v", slackClient.posts)
	}
}

func TestAgentRunMissingCoopImageRepairsAndRetriesWithoutSlackFailure(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CIMAGE"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-image-recovery", EnvelopeID: "env-image-recovery",
		EventID: "event-image-recovery", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CIMAGE", MessageTS: "1700.711", UserID: "U123ABC",
		Text: "<@U999BOT> what is two plus two?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_process_error",
			ErrorDetail: "ACP child closed before its response: Coop box image is not built; run 'coop build'",
		},
		{
			State: "completed",
			AssistantMessage: `{
				"action":"reply",
				"message":"Four."
			}`,
		},
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	repairs := 0
	svc.SetCoopRuntimeRepairer(func(context.Context) error {
		repairs++
		return nil
	})
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending || requeued.Failures != 0 ||
		!strings.Contains(requeued.LastError, "execution image rebuilt") {
		t.Fatalf("requeued missing image = %+v, %v", requeued, err)
	}
	firstSession := requeued.SessionID
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted ||
		completed.SessionID != firstSession || repairs != 1 {
		t.Fatalf("recovered missing image = %+v, repairs=%d, err=%v", completed, repairs, err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "Four") ||
		strings.Contains(slackClient.posts[0].message.Text, "could not complete") {
		t.Fatalf("missing-image recovery result = %+v", slackClient.posts)
	}
}

func TestAgentRunMissingCoopImageBuildFailureStaysQueuedWithoutSlackFailure(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CIMAGEWAIT"}
	cfg.Slack.WatchChannels = nil
	cfg.Slack.NativeStatus = true
	cfg.Limits.MaxAgentRunAttempts = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-image-wait", EnvelopeID: "env-image-wait",
		EventID: "event-image-wait", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CIMAGEWAIT", MessageTS: "1700.712", UserID: "U123ABC",
		Text: "<@U999BOT> check production health",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{{
		State:       "failed",
		ErrorCode:   "acp_process_error",
		ErrorDetail: "ACP child closed before its response: Coop box image is not built; run 'coop build'",
	}}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	repairs := 0
	svc.SetCoopRuntimeRepairer(func(context.Context) error {
		repairs++
		return errors.New("Docker daemon unavailable")
	})
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	drainSlackDeliveries(t, ctx, svc)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending || requeued.Failures != 0 ||
		!strings.Contains(requeued.LastError, "waiting for the managed Coop execution image") ||
		time.Until(requeued.NextAttemptAt) < 25*time.Second {
		t.Fatalf("queued missing image = %+v, %v", requeued, err)
	}
	if repairs != 1 {
		t.Fatalf("repair attempts = %d, want 1", repairs)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("missing image failure reached Slack = %+v", slackClient.posts)
	}
	if len(slackClient.statuses) != 2 ||
		slackClient.statuses[0].text != watchPendingStatus ||
		slackClient.statuses[1].text != "" {
		t.Fatalf("dependency-blocked status lifecycle = %+v", slackClient.statuses)
	}
	state, err := decodeWatchRunContext(requeued)
	if err != nil || state.PendingStatusSet || state.PendingStatusAt != 0 {
		t.Fatalf("parked watch state = %+v, %v", state, err)
	}
}

func TestAgentRunTranscriptOverflowRotatesSlackSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"COVERFLOW"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-transcript-overflow", EnvelopeID: "env-transcript-overflow",
		EventID: "event-transcript-overflow", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COVERFLOW", MessageTS: "1700.700", UserID: "U123ABC",
		Text: "<@U999BOT> please check all pull zones again and make sure we do not have any unresolved traffic spikes from the last two weeks",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "ACP transcript exceeded its bound",
		},
		{
			State: "completed",
			AssistantMessage: `{
				"action":"reply",
				"message":"All pull zones were checked with bounded current and historical queries."
			}`,
		},
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending || requeued.Failures != 1 {
		t.Fatalf("requeued Slack run = %+v, %v", requeued, err)
	}
	firstSession := requeued.SessionID
	coopClient.openAfterCreateKey = "responder:watch-session:COVERFLOW:2"
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted ||
		completed.SessionID == firstSession || completed.SessionGeneration != 2 {
		t.Fatalf("completed Slack run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[0], "<host-tool-transport>") ||
		!strings.Contains(coopClient.submitPrompts[1], "<host-transport-recovery>") ||
		!strings.Contains(coopClient.submitPrompts[1], "tightly filtered queries") ||
		!strings.Contains(coopClient.submitPrompts[1], "check all pull zones again") {
		t.Fatalf("Slack recovery prompts = %+v", coopClient.submitPrompts)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "All pull zones were checked") ||
		strings.Contains(slackClient.posts[0].message.Text, "could not complete") {
		t.Fatalf("Slack continuation result = %+v", slackClient.posts)
	}
}

func TestEvaluationTurnCleanupRetryIsBoundedAndRecovers(t *testing.T) {
	client := newFakeCoop()
	client.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "turn cleanup failed",
		},
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "turn cleanup failed",
		},
		{
			State:            "completed",
			AssistantMessage: `{"action":"ignore"}`,
		},
	}
	response, turnID, calls, err := runEvaluationTurnWithRetry(
		context.Background(),
		client,
		client.session.ID,
		"responder:test-eval-turn",
		"evaluate",
		time.Millisecond,
	)
	if err != nil {
		t.Fatal(err)
	}
	if response != `{"action":"ignore"}` || turnID == "" || calls != 3 {
		t.Fatalf(
			"retry result = response %q, turn %q, calls %d",
			response,
			turnID,
			calls,
		)
	}
	if want := []string{
		"responder:test-eval-turn",
		"responder:test-eval-turn:cleanup-retry:1",
		"responder:test-eval-turn:cleanup-retry:2",
	}; !slices.Equal(client.submitKeys, want) {
		t.Fatalf("retry keys = %v, want %v", client.submitKeys, want)
	}
}

func TestOperatorRequestedEmisarApprovalReachesIncidentThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-api", 1,
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	input := core.SlackInput{
		ID: "slack-operational-action", EnvelopeID: "env-operational-action",
		EventID: "event-operational-action", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS, MessageTS: "1700.002",
		UserID: cfg.Slack.Operators[0], Text: "Restart the failed allocation on prod-1.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit operator request = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	expires := time.Now().UTC().Add(time.Hour).Truncate(time.Second)
	coopClient.complete(fmt.Sprintf(`{
	  "message":"Emisar paused the requested restart before execution.",
	  "evidence":[],
	  "coverage":[],
	  "memory":{},
	  "pending_approval":{
	    "request_id":"apr_123",
	    "run_id":"run_123",
	    "operation_id":"op_123",
	    "action_id":"nomad.alloc_restart",
	    "pack_ref":"nomad@1.2.3#sha256:abc",
	    "runner_ref":"prod-1~abc123",
	    "status":"pending_approval",
	    "approval_url":"https://emisar.dev/app/acme/approvals/apr_123",
	    "expires_at":%q
	  },
	  "proposals":[]
	}`, expires.Format(time.RFC3339)))
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("approval posts = %+v", slackClient.posts)
	}
	post := slackClient.posts[0]
	if post.thread != incident.RootTS ||
		post.message.Header != "Approval required in Emisar" ||
		len(post.message.Actions) != 1 ||
		post.message.Actions[0].ID != slackui.ActionOpenApproval ||
		post.message.Actions[0].URL != "https://emisar.dev/app/acme/approvals/apr_123" {
		t.Fatalf("approval thread card = %+v", post)
	}
	stored, err := st.GetEmisarApproval(ctx, "apr_123")
	if err != nil || stored.RunID != "run_123" {
		t.Fatalf("stored approval = %+v, %v", stored, err)
	}
}

func TestEngineeringTaskDeliveryRequiresChangesFromCurrentTurn(t *testing.T) {
	before := coop.Changes{
		BaseCommit: "base", ForkHead: "existing",
		Committed:   []coop.Change{{Path: "infra.tf", Status: "M"}},
		PatchDigest: "existing-diff", PatchBytes: 100,
	}
	if engineeringTaskTurnCreatedChanges(coopChangesFingerprint(before), before) {
		t.Fatal("unchanged task work was attributed to the current turn")
	}
	after := before
	after.ForkHead = "new-head"
	after.Committed = append(
		after.Committed,
		coop.Change{Path: "followup.tf", Status: "M"},
	)
	after.PatchDigest = "new-diff"
	if !engineeringTaskTurnCreatedChanges(coopChangesFingerprint(before), after) {
		t.Fatal("new task work was not attributed to the current turn")
	}
	if engineeringTaskTurnCreatedChanges("unavailable", after) {
		t.Fatal("unknown initial state exposed stale task controls")
	}
}

func TestAgentRunFinalizationFailureUsesDurableBackoff(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := stageAgentRunWithMissingConversationSource(t, ctx, st)
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	before := time.Now().UTC()
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunApplying || stored.Failures != 1 ||
		!stored.NextAttemptAt.After(before) ||
		!strings.Contains(stored.LastError, "not found") {
		t.Fatalf("deferred finalization = %+v", stored)
	}
	if err := svc.processAgentRunFinalization(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("finalization ignored durable due time: %v", err)
	}
}

func TestAgentRunFinalizationExhaustionPostsFailureAndClearsStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := stageAgentRunWithMissingConversationSource(t, ctx, st)
	slack := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed ||
		!strings.Contains(stored.LastError, "configured retry limit") {
		t.Fatalf("terminal finalization = %+v, %v", stored, err)
	}
	incident, err := st.GetIncident(ctx, run.IncidentID)
	if err != nil || incident.ActiveTurnID != "" ||
		incident.Workflow != core.WorkflowParked {
		t.Fatalf("terminal incident = %+v, %v", incident, err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "could not finalize") {
		t.Fatalf("terminal finalization notice = %+v", slack.posts)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "" ||
		slack.statuses[0].thread != incident.RootTS {
		t.Fatalf("terminal finalization status clear = %+v", slack.statuses)
	}
}

func TestSlashTurnLimitOverrides(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if _, err := svc.turnLimitStatus(ctx, "COTHER"); err != nil {
		t.Fatalf("initial turn-limit status: %v", err)
	}
	run := func(id, channel, text string) slackui.Message {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: channel,
			UserID: "U123ABC", Text: text, ActionID: "/responder",
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		if len(slackClient.ephemerals) == 0 {
			stored, storedErr := st.GetSlackInput(ctx, id)
			t.Fatalf("process %s produced no response: input=%+v, error=%v", id, stored, storedErr)
		}
		return slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	}

	status := run("turn-status-default", "COTHER", "turn-limit")
	if !strings.Contains(status.Text, "up to 1000 agent requests") ||
		!strings.Contains(strings.Join(status.Sections, "\n"), "Operators do not choose") {
		t.Fatalf("default turn-limit status = %+v", status)
	}
	run("turn-global", "CCONTROL", "turn-limit global 2000")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 2000 {
		t.Fatalf("workspace turn limit = %d, %v", got, err)
	}
	run("turn-channel", "COTHER", "turn-limit 1500")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 1500 {
		t.Fatalf("channel turn limit = %d, %v", got, err)
	}
	run("turn-channel-inherit", "COTHER", "turn-limit inherit")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 2000 {
		t.Fatalf("inherited turn limit = %d, %v", got, err)
	}
	invalid := run("turn-invalid", "COTHER", "turn-limit 99")
	if !strings.Contains(invalid.Text, "between `100` and `10000`") {
		t.Fatalf("invalid turn-limit guidance = %+v", invalid)
	}
}

func TestRaisingTurnLimitResumesPreservedIncidentWork(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.TurnLimit = 100
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 3); err != nil {
		t.Fatal(err)
	}
	if err := st.SetIncidentError(
		ctx, incident.ID, core.WorkflowBlocked, turnLimitReachedMessage(100),
	); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "raise-preserved-work", EnvelopeID: "env-raise-preserved-work",
		EventID: "event-raise-preserved-work", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, UserID: "U123ABC", Text: "turn-limit 200",
		ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.Workflow != core.WorkflowParked || incident.LastError != "" {
		t.Fatalf("resumed incident = %+v, %v", incident, err)
	}
}

func TestAgentRunContinuationPromptCarriesStructuredCorrection(t *testing.T) {
	prompt := agentRunContinuationPrompt(core.AgentRun{
		LastError: "the structured agent report is invalid: completion capability gap 1: requires evidence_refs from pack discovery",
	})
	for _, required := range []string{
		"<host-structured-correction>",
		"requires evidence_refs from pack discovery",
		"Do not repeat the investigation",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("continuation prompt lacks %q: %s", required, prompt)
		}
	}
}

func TestIncidentTurnCapacityExtendsAutomatically(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 7); err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "control", SourceID: "automatic-capacity",
		UserID: "U123ABC", Repository: incident.Repository,
		Prompt: "Inspect current evidence.",
	}); err != nil || !created {
		t.Fatalf("queue turn = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.Revision = 7
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if coopClient.session.MaxTurns != 125 || len(coopClient.submitKeys) != 1 {
		t.Fatalf("automatic capacity session = %+v, submissions = %v",
			coopClient.session, coopClient.submitKeys)
	}
	submission, err := st.GetAgentRunBySource(ctx, "control", "automatic-capacity")
	if err != nil || submission.State != core.AgentRunRunning ||
		submission.SessionID != "ses_1" {
		t.Fatalf("automatic-capacity submission = %+v, %v", submission, err)
	}
}

func TestAutomaticTurnCapacityHonorsConfiguredCeiling(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.TurnLimit = 100
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	_, err = svc.ensureTurnCapacity(ctx, "CWATCH", "", coopClient.session)
	var limitErr *automaticTurnLimitError
	if !errors.As(err, &limitErr) || limitErr.Limit != 100 {
		t.Fatalf("configured ceiling error = %T %v", err, err)
	}
	if coopClient.session.MaxTurns != 100 {
		t.Fatalf("capacity changed beyond ceiling: %+v", coopClient.session)
	}
}

func TestCleanupTreatsMissingCoopSessionAsAlreadyDone(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.getSessionErr = &coop.APIError{Status: 404, Code: "session_not_found"}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "expired session", false, time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.CleanupPending != 0 || metrics.CleanupBlocked != 0 {
		t.Fatalf("missing cleanup was retained: %+v", metrics)
	}
}

func TestCleanupStopsRetryingPersistentCoopFailures(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.getSessionErr = &coop.APIError{Status: 500, Code: "internal_error"}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "expired session", false, time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	for attempt := 1; attempt < cleanupRetryLimit; attempt++ {
		if err := st.SetCleanupState(
			ctx, coopClient.session.ID, "retry", "", "internal error", time.Now().Add(-time.Second),
		); err != nil {
			t.Fatal(err)
		}
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.CleanupPending != 0 || metrics.CleanupBlocked != 1 {
		t.Fatalf("persistent cleanup was not blocked: %+v", metrics)
	}
}
