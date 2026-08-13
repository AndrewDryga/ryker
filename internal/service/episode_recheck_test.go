package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestCompletionRecheckIsTypedAndBounded(t *testing.T) {
	valid := &CompletionAssessment{
		Status: "blocked", Summary: "Pack is not advertised yet.",
		MaterialGaps: []string{"live action catalog"},
		BlockerKind:  "source_unavailable",
		Attempts:     []string{"Refreshed the runner inventory and action catalog."},
		NextAction:   "Wait for runner catalog propagation.",
		Recheck: &investigation.RecheckDirective{
			Key: "emisar:pack:gcp-billing", Reason: "Runner reload is in progress.",
			AfterSeconds: 60, AdditionalAttempts: 2,
		},
	}
	if err := investigation.ValidateCompletion(valid); err != nil {
		t.Fatalf("valid recheck rejected: %v", err)
	}
	valid.Recheck.AfterSeconds = 5
	if err := investigation.ValidateCompletion(valid); err == nil {
		t.Fatal("unsafe recheck delay accepted")
	}
	valid.Recheck.AfterSeconds = 60
	valid.BlockerKind = "access_denied"
	if err := investigation.ValidateCompletion(valid); err == nil {
		t.Fatal("access denial accepted as an automatic recheck")
	}
}

func TestEpisodeRechecksAreChainedAfterEachCompletedAttempt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	input := core.SlackInput{
		ID: "slack_chain", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "100.2", UserID: cfg.Slack.Operators[0],
	}
	if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
		t.Fatalf("admit input = %t, %v", created, admitErr)
	}
	result := []byte(`{
  "action":"reply",
  "message":"Waiting for propagation.",
  "completion":{
    "status":"blocked",
    "summary":"Catalog propagation is pending.",
    "material_gaps":["live catalog"],
    "blocker_kind":"source_unavailable",
    "attempts":["Refreshed the catalog."],
    "next_action":"Recheck after propagation.",
    "recheck":{"key":"catalog","reason":"Propagation is pending.","after_seconds":30,"additional_attempts":3}
  }
}`)
	origin, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_chain", Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ConversationKey: "channel:" + input.ChannelID,
		SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
		Result: result, State: core.AgentRunRunning,
	})
	if err != nil || !created {
		t.Fatalf("queue origin = %+v, %t, %v", origin, created, err)
	}
	svc := &Service{cfg: cfg, store: st}
	completion := &CompletionAssessment{Recheck: &investigation.RecheckDirective{
		Key: "catalog", AfterSeconds: 30, AdditionalAttempts: 3,
	}}
	if err := svc.scheduleEpisodeRechecks(
		ctx, origin, input, decisionpkg.WatchTurnState{}, "reply", completion,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.EnqueueWork(ctx, store.WorkItem{
		Kind: workEpisodeRecheck, SubjectID: episodeRecheckSubject(origin.ID, 1),
		Lane: store.WorkLaneBackground, AvailableAt: time.Now().Add(-time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	first, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil || first.SubjectID != episodeRecheckSubject(origin.ID, 1) {
		t.Fatalf("first work = %+v, %v", first, err)
	}
	if err := st.CompleteWork(ctx, first); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("later attempts were queued eagerly: %v", err)
	}

	state := decisionpkg.WatchTurnState{RecheckOriginRunID: origin.ID, RecheckAttempt: 1}
	if err := svc.scheduleEpisodeRechecks(
		ctx, core.AgentRun{ID: "run_chain_recheck_1"}, input, state, "ignore", nil,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.EnqueueWork(ctx, store.WorkItem{
		Kind: workEpisodeRecheck, SubjectID: episodeRecheckSubject(origin.ID, 2),
		Lane: store.WorkLaneBackground, AvailableAt: time.Now().Add(-time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	second, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil || second.SubjectID != episodeRecheckSubject(origin.ID, 2) {
		t.Fatalf("second work = %+v, %v", second, err)
	}
	if err := st.CompleteWork(ctx, second); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("third attempt was queued before second completed: %v", err)
	}
}

func TestLegacyEpisodeRecheckQuietlyDefersUntilPriorAttemptCompletes(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_legacy", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "100.2", UserID: cfg.Slack.Operators[0],
	}
	if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
		t.Fatalf("admit input = %t, %v", created, admitErr)
	}
	result := []byte(`{
  "action":"reply","message":"Waiting.",
  "completion":{"status":"blocked","summary":"Waiting.","material_gaps":["catalog"],
  "blocker_kind":"source_unavailable","attempts":["Checked."],"next_action":"Wait.",
  "recheck":{"key":"catalog","reason":"Waiting.","after_seconds":60,"additional_attempts":3}}
}`)
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_legacy", Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ConversationKey: "channel:" + input.ChannelID,
		SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
		Result: result, State: core.AgentRunRunning,
	})
	if err != nil || !created {
		t.Fatalf("queue origin = %+v, %t, %v", run, created, err)
	}
	err = (&Service{cfg: cfg, store: st}).processEpisodeRecheck(ctx, store.WorkItem{
		Kind: workEpisodeRecheck, SubjectID: episodeRecheckSubject(run.ID, 2),
	})
	var deferral scheduledWorkDeferral
	if !errors.As(err, &deferral) || !deferral.at.After(time.Now()) {
		t.Fatalf("legacy later attempt was not quietly deferred: %#v", err)
	}
}

func TestEpisodeRecheckIsSilentWhileBackgroundWorkRunsOrFails(t *testing.T) {
	input := core.SlackInput{
		ID: "slack_recheck", Kind: "recheck", ChannelID: "COPS",
		ThreadTS: "100.1", MessageTS: "100.2",
	}
	state := decisionpkg.WatchTurnState{
		ConversationFollowup: true,
		RecheckOriginRunID:   "run_origin",
		RecheckKey:           "emisar:pack:gcp-billing",
	}
	if watchInputWantsPendingStatus(input, state) {
		t.Fatal("background recheck requested a visible pending status")
	}
}

func TestEpisodeRecheckCreatesOneSilentSyntheticInput(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	origin := core.SlackInput{
		ID: "slack_origin", EnvelopeID: "env_origin", EventID: "event_origin",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		ThreadTS: "100.1", MessageTS: "100.2", UserID: cfg.Slack.Operators[0],
		Text: "There is a billing pack installed, so query it.",
	}
	if created, err := st.AdmitSlackInput(ctx, origin); err != nil || !created {
		t.Fatalf("admit origin = %t, %v", created, err)
	}
	stateJSON, err := json.Marshal(decisionpkg.WatchTurnState{
		SessionID: "session_origin", SessionChannelID: "COPS",
		Repository: "repo", RouteCaptured: true, ResponseThreadTS: "100.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	result := []byte(`{
  "action":"reply",
  "message":"The pack has not reached the runner yet.",
  "completion":{
    "status":"blocked",
    "summary":"The billing action is not advertised yet.",
    "material_gaps":["live billing action"],
    "blocker_kind":"source_unavailable",
    "attempts":["Refreshed runner inventory and action discovery."],
    "next_action":"Wait for runner catalog propagation.",
    "recheck":{"key":"emisar:pack:gcp-billing","reason":"A runner reload is in progress.","after_seconds":60,"additional_attempts":2}
  }
}`)
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_origin", Mode: core.AgentRunTriage,
		ChannelID: origin.ChannelID, ConversationKey: "channel:" + origin.ChannelID,
		SourceKind: "watch", SourceID: origin.ID, UserID: origin.UserID,
		Context: stateJSON, Result: result, State: core.AgentRunRunning,
	})
	if err != nil || !created {
		t.Fatalf("queue origin run = %+v, %t, %v", run, created, err)
	}
	svc := &Service{cfg: cfg, store: st}
	if err := svc.processEpisodeRecheck(ctx, store.WorkItem{
		Kind: workEpisodeRecheck, SubjectID: episodeRecheckSubject(run.ID, 1),
	}); err != nil {
		t.Fatal(err)
	}

	recheck, err := st.GetSlackInput(ctx, episodeRecheckInputID(run.ID, 1))
	if err != nil {
		t.Fatal(err)
	}
	if recheck.Kind != "recheck" || recheck.Text != origin.Text ||
		recheck.ThreadTS != origin.ThreadTS || recheck.MessageTS != origin.MessageTS {
		t.Fatalf("recheck input = %+v", recheck)
	}
	var recheckState decisionpkg.WatchTurnState
	if err := json.Unmarshal(recheck.Frozen, &recheckState); err != nil {
		t.Fatal(err)
	}
	if recheckState.RecheckOriginRunID != run.ID ||
		recheckState.RecheckKey != "emisar:pack:gcp-billing" ||
		recheckState.RecheckAttempt != 1 || !recheckState.ConversationFollowup {
		t.Fatalf("recheck state = %+v", recheckState)
	}

	if err := svc.processEpisodeRecheck(ctx, store.WorkItem{
		Kind: workEpisodeRecheck, SubjectID: episodeRecheckSubject(run.ID, 1),
	}); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, episodeRecheckInputID(run.ID, 1))
	if err != nil || stored.ID != recheck.ID {
		t.Fatalf("idempotent recheck = %+v, %v", stored, err)
	}
}

func TestSyntheticRecheckBypassesHumanSlackMembershipValidation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	origin := core.SlackInput{
		ID: "slack_external_app", EnvelopeID: "env:external-app",
		EventID: "event:external-app", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.100", UserID: "BGRAFANA",
		Text: "Disk latency is high.", ReceivedAt: time.Now().UTC().Add(-time.Second),
	}
	if created, admitErr := st.AdmitSlackInput(ctx, origin); admitErr != nil || !created {
		t.Fatalf("admit source alert = %t, %v", created, admitErr)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != origin.ID {
		t.Fatalf("lease source alert = %+v, %v", leased, err)
	}
	if err := st.FinishSlackInput(ctx, leased.ID); err != nil {
		t.Fatal(err)
	}
	frozen, err := json.Marshal(decisionpkg.WatchTurnState{
		RouteCaptured: true, ResponseThreadTS: "1700.100", RulesCaptured: true,
		ConversationFollowup: true, RecheckOriginRunID: "run_origin", RecheckAttempt: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack_recheck_external_app", EnvelopeID: "recheck:external-app",
		EventID: "recheck:external-app", Kind: "recheck", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "1700.100", MessageTS: "1700.100",
		UserID: "BGRAFANA", Text: "Disk latency is high.", Frozen: frozen,
		ReceivedAt: time.Now().UTC().Add(-time.Second),
	}
	created, err := st.AdmitSyntheticSlackInput(ctx, input)
	if err != nil || !created {
		t.Fatalf("admit synthetic recheck = %t, %v", created, err)
	}
	if err := st.RetrySlackInput(
		ctx, input.ID, "interrupted before queueing", time.Now().Add(-time.Second), false,
	); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" {
		t.Fatalf("synthetic recheck input = %+v, %v", stored, err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.UserID != input.UserID || run.Mode != core.AgentRunTriage {
		t.Fatalf("synthetic recheck run = %+v", run)
	}
}
