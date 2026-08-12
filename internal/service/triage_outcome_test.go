package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestTerminalHumanTriageFailurePostsOneSanitizedNotice(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "human-terminal-failure", EnvelopeID: "env-human-terminal-failure",
		EventID: "event-human-terminal-failure", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@UBOT> check production health",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	const raw = "Coop API 500: secret internal transport detail"
	if err := svc.failPreparingTriageRun(
		ctx, run, input, decisionpkg.WatchTurnState{}, raw,
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != input.MessageTS {
		t.Fatalf("terminal failure notice = %+v", slack.posts)
	}
	content := slack.posts[0].message.Text + strings.Join(slack.posts[0].message.Sections, " ")
	if strings.Contains(content, raw) || !strings.Contains(content, "couldn't finish this request") {
		t.Fatalf("terminal notice leaked or omitted the useful summary: %q", content)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("terminal run = %+v, %v", stored, err)
	}
	followup := core.SlackInput{
		ID: "failure-thread-followup", Kind: "message", TeamID: input.TeamID,
		ChannelID: input.ChannelID, ThreadTS: input.MessageTS, MessageTS: "1700.200",
		UserID: input.UserID, Text: "try it again now",
	}
	admitted, err := svc.shouldAdmitChannelMessage(ctx, followup)
	if err != nil || !admitted {
		t.Fatalf("plain reply to terminal failure was not admitted = %t, %v", admitted, err)
	}
}

func TestApprovalContinuationFailurePostsVerificationOnlyNotice(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "approval-continuation-failure", EnvelopeID: "env-approval-continuation-failure",
		EventID: "event-approval-continuation-failure", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "1700.100", MessageTS: "1700.200", UserID: "U123ABC",
		Text: "approval result",
	}
	if created, err := st.AdmitSyntheticSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit continuation = %t, %v", created, err)
	}
	if err := st.Intelligence.BindChannelSession(
		ctx, input.ChannelID, "repo", "ses_approval", 3, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.ThreadTS,
		ConversationKey: "channel:COPS", SourceKind: "emisar_approval:apr_1", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(ctx, run.ID, "ses_approval", 3, "repo", 0, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	run, err = st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	state := decisionpkg.WatchTurnState{
		ConversationFollowup: true, ApprovalContinuation: true,
		SessionID: "ses_approval", SessionChannelID: input.ChannelID,
		Generation: 1,
	}
	if err := svc.finishTriageRunFailure(ctx, run, input, state, "secret verifier transport detail"); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != input.ThreadTS {
		t.Fatalf("approval verification notice = %+v", slack.posts)
	}
	content := slack.posts[0].message.Text + strings.Join(slack.posts[0].message.Sections, " ")
	for _, required := range []string{"couldn't verify or report", "before repeating any action"} {
		if !strings.Contains(content, required) {
			t.Fatalf("approval verification notice lacks %q: %q", required, content)
		}
	}
	if strings.Contains(content, "secret verifier") || strings.Contains(content, "action finished") {
		t.Fatalf("approval verification notice overclaimed or leaked diagnostics: %q", content)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("approval continuation run = %+v, %v", stored, err)
	}
	memory, err := st.Intelligence.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || memory.SessionID != "ses_approval" || memory.Generation != 1 {
		t.Fatalf("approval continuation retired shared session = %+v, %v", memory, err)
	}
}

func TestNewerHumanTurnSuppressesOlderCompletedReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	olderInput := core.SlackInput{
		ID: "human-old", EnvelopeID: "env-human-old", EventID: "event-human-old",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.100", UserID: "U123ABC", Text: "<@UBOT> use the old target",
		ReceivedAt: time.Now().UTC(),
	}
	newerInput := core.SlackInput{
		ID: "human-new", EnvelopeID: "env-human-new", EventID: "event-human-new",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		ThreadTS: "1700.100", MessageTS: "1700.200", UserID: "U123ABC",
		Text: "Correction: use the new target.", ReceivedAt: olderInput.ReceivedAt.Add(time.Second),
	}
	unrelatedInput := core.SlackInput{
		ID: "human-unrelated", EnvelopeID: "env-human-unrelated", EventID: "event-human-unrelated",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1800.100", UserID: "UOTHER", Text: "<@UBOT> separate question",
		ReceivedAt: olderInput.ReceivedAt.Add(500 * time.Millisecond),
	}
	for _, input := range []core.SlackInput{olderInput, unrelatedInput} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.100",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: olderInput.ID,
		UserID: olderInput.UserID, State: core.AgentRunRunning, StartedAt: olderInput.ReceivedAt,
		CreatedAt: olderInput.ReceivedAt, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, older.ID, "completed",
		[]byte(`{"action":"reply","attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"message":"Use the old target."}`),
		"", 1,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, older.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1800.100",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: unrelatedInput.ID,
		UserID: unrelatedInput.UserID, CreatedAt: unrelatedInput.ReceivedAt, Context: []byte(`{}`),
	}); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	staged, err := st.GetAgentRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stale, err := svc.supersedeStaleHumanTriageResult(
		ctx, staged, olderInput, decisionpkg.WatchTurnState{},
	); err != nil || stale {
		t.Fatalf("unrelated channel turn suppressed the answer: stale=%t err=%v", stale, err)
	}
	if created, err := st.AdmitSlackInput(ctx, newerInput); err != nil || !created {
		t.Fatalf("admit correction = %t, %v", created, err)
	}
	staged, err = st.GetAgentRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.finalizeTriageAgentRun(ctx, staged); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); err == nil {
		t.Fatal("stale human reply was queued")
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, older.ID)
	if err != nil || episode.State != core.EpisodeSuperseded {
		t.Fatalf("stale episode = %+v, %v", episode, err)
	}
}

func TestOlderFailedAttemptCannotRetireNewerAttemptsSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "older-failed-input", EnvelopeID: "older-failed-envelope",
		EventID: "older-failed-event", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.300", UserID: "U123ABC",
		Text: "<@UBOT> investigate this",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit older input = %t, %v", created, err)
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: older.ConversationKey, SourceKind: "watch", SourceID: "new-owner",
		UserID: input.UserID, Context: []byte(`{}`),
	}); err != nil || !created {
		t.Fatalf("queue newer owner = %t, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "shared-session"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	older.Context = []byte(`{"session_id":"shared-session"}`)
	if err := svc.stageTerminalFinalizationFailure(
		ctx, older, errors.New("stale failure"),
	); err != nil {
		t.Fatal(err)
	}
	if coopClient.session.State != "open" {
		t.Fatalf("older attempt retired shared session: %+v", coopClient.session)
	}
	stored, err := st.GetAgentRun(ctx, older.ID)
	if err != nil || stored.State != core.AgentRunPreparing {
		t.Fatalf("older attempt state = %+v, %v", stored, err)
	}
	if _, err := st.GetSlackDelivery(ctx, "watch_failure_"+input.ID); err == nil {
		t.Fatal("older attempt queued a failure notice")
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("older attempt queued fallback status clear: %v", err)
	}
}

func TestOlderEngineeringFinalizerCannotClearNewerAttemptStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "stale-finalizer-task", "Fix it", "summary", "U123ABC",
		"COPS", "1700.400", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.401"); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: task.ChannelID, ThreadTS: task.RootTS,
		ConversationKey: "incident:" + task.ID,
		SourceKind:      "slack", SourceID: "older-task-turn", UserID: "U123ABC",
		State: core.AgentRunRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, older.ID, "completed", []byte(`{}`), "", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, older.ID); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: task.ChannelID, ThreadTS: task.RootTS,
		ConversationKey: older.ConversationKey,
		SourceKind:      "slack", SourceID: "newer-task-turn", UserID: "U123ABC",
	}); !errors.Is(err, store.ErrConflict) || created {
		t.Fatalf("queue while task result finalizes = %t, %v", created, err)
	}
}
