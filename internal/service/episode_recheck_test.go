package service

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestCompletionRecheckIsTypedAndBounded(t *testing.T) {
	valid := &completionAssessment{
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
	if err := validateCompletionAssessment(valid); err != nil {
		t.Fatalf("valid recheck rejected: %v", err)
	}
	valid.Recheck.AfterSeconds = 5
	if err := validateCompletionAssessment(valid); err == nil {
		t.Fatal("unsafe recheck delay accepted")
	}
	valid.Recheck.AfterSeconds = 60
	valid.BlockerKind = "access_denied"
	if err := validateCompletionAssessment(valid); err == nil {
		t.Fatal("access denial accepted as an automatic recheck")
	}
}

func TestEpisodeRecheckIsSilentWhileBackgroundWorkRunsOrFails(t *testing.T) {
	input := core.SlackInput{
		ID: "slack_recheck", Kind: "recheck", ChannelID: "COPS",
		ThreadTS: "100.1", MessageTS: "100.2",
	}
	state := watchTurnState{
		ConversationFollowup: true,
		RecheckOriginRunID:   "run_origin",
		RecheckKey:           "emisar:pack:gcp-billing",
	}
	if watchInputWantsPendingStatus(input, state) {
		t.Fatal("background recheck requested a visible pending status")
	}
	if publishTriageFailure(input, state) {
		t.Fatal("background recheck failure was publishable")
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
	stateJSON, err := json.Marshal(watchTurnState{
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
	var recheckState watchTurnState
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
