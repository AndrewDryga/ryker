package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestExternalLifecycleReconciliationAdmitsAttachmentOnlyTerminalEdit(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC()
	source := core.SlackInput{
		ID: "slack-plan", EnvelopeID: "env-plan", EventID: "event-plan",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CPLAN",
		MessageTS: "1700.700", UserID: "BTERRAFORM",
		Text:       "Run notification for acme/infra\nRun run-abc\nRun Planning",
		ReceivedAt: now,
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit planning input = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackInput(ctx, leased.ID); err != nil {
		t.Fatal(err)
	}

	slackClient := &fakeSlack{history: []slackui.HistoryMessage{{
		Timestamp: source.MessageTS, BotID: source.UserID,
		Text: "Run notification for acme/infra\nRun run-abc\nRun Errored",
	}}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.reconcileExternalMessage(ctx, store.WorkItem{
		SubjectID: source.ID, DeadlineAt: now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}

	updated, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Kind != "bot_message" || updated.MessageTS != source.MessageTS ||
		!strings.Contains(updated.Text, "Run Errored") ||
		!strings.HasPrefix(updated.EventID, "reconcile:") {
		t.Fatalf("reconciled terminal input = %+v", updated)
	}
	if shouldReconcileExternalMessage(updated.Text) {
		t.Fatal("terminal lifecycle message remained eligible for polling")
	}
}

func TestExternalLifecycleReconciliationFindsMissedTerminalSibling(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC()
	source := core.SlackInput{
		ID: "slack-plan", EnvelopeID: "env-plan", EventID: "event-plan",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CPLAN",
		MessageTS: "1700.700000", UserID: "BTERRAFORM",
		Text: "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\n" +
			"<https://app.terraform.io/app/acme/infra/runs/run-abc|Run run-abc>\nRun Planning",
		ReceivedAt: now,
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit planning input = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackInput(ctx, leased.ID); err != nil {
		t.Fatal(err)
	}

	slackClient := &fakeSlack{history: []slackui.HistoryMessage{
		{
			Timestamp: "1700.760000", BotID: source.UserID,
			Text: "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\n" +
				"<https://app.terraform.io/app/acme/infra/runs/run-other|Run run-other>\nRun Applied",
		},
		{
			Timestamp: "1700.750000", BotID: source.UserID,
			Text: "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\n" +
				"<https://app.terraform.io/app/acme/infra/runs/run-abc|Run run-abc>\nRun Errored",
		},
		{
			Timestamp: "1700.710000", BotID: source.UserID,
			Text: "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\n" +
				"<https://app.terraform.io/app/acme/infra/runs/run-abc|Run run-abc>\nRun Applying",
		},
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.reconcileExternalMessage(ctx, store.WorkItem{
		SubjectID: source.ID, DeadlineAt: now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}

	updated, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if updated.MessageTS != "1700.750000" || !strings.Contains(updated.Text, "Run Errored") {
		t.Fatalf("reconciled sibling input = %+v", updated)
	}
	if strings.Contains(updated.Text, "run-other") {
		t.Fatalf("unrelated lifecycle sibling was selected: %+v", updated)
	}
}

func TestReconciledExternalLifecycleIDDoesNotDependOnPollingSource(t *testing.T) {
	message := slackui.HistoryMessage{
		Timestamp: "1700.750000", BotID: "BTERRAFORM", Text: "Run run-abc\nRun Errored",
	}
	first := reconciledExternalMessageInput("TTEST", core.SlackInput{
		ID: "slack-plan", ChannelID: "CPLAN", UserID: "BTERRAFORM",
	}, message)
	second := reconciledExternalMessageInput("TTEST", core.SlackInput{
		ID: "slack-applying", ChannelID: "CPLAN", UserID: "BTERRAFORM",
	}, message)
	if first.EventID != second.EventID || first.EnvelopeID != second.EnvelopeID ||
		first.ID != second.ID || first.ID == "" {
		t.Fatalf("reconciled event IDs differ: %q != %q", first.EventID, second.EventID)
	}
}

func TestSlackMessageVersionIdentityMatchesSocketAndReconciliation(t *testing.T) {
	socket := core.SlackInput{
		EnvelopeID: "socket-envelope", EventID: "socket-event",
		Kind: "bot_message", TeamID: "TTEST", ChannelID: "CPLAN",
		MessageTS: "1700.750000", UserID: "BTERRAFORM",
		Text: "Run run-abc\nRun Errored",
	}
	bindCanonicalSlackMessageInputID(&socket)
	reconciled := reconciledExternalMessageInput(
		"TTEST",
		core.SlackInput{ChannelID: "CPLAN", UserID: "BTERRAFORM"},
		slackui.HistoryMessage{
			Timestamp: "1700.750000", BotID: "BTERRAFORM",
			Text: "Run run-abc\nRun Errored",
		},
	)
	if socket.ID == "" || socket.ID != reconciled.ID {
		t.Fatalf("message version IDs differ: socket=%q reconcile=%q", socket.ID, reconciled.ID)
	}
	mention := socket
	mention.ID = ""
	mention.Kind = "mention"
	bindCanonicalSlackMessageInputID(&mention)
	if mention.ID != socket.ID {
		t.Fatalf("event subscription changed message identity: socket=%q mention=%q", socket.ID, mention.ID)
	}

	edited := socket
	edited.ID = ""
	edited.Text = "Run run-abc\nRun Applied"
	bindCanonicalSlackMessageInputID(&edited)
	if edited.ID == socket.ID {
		t.Fatalf("edited lifecycle reused message version ID %q", edited.ID)
	}
}

func TestExternalLifecycleFastPathSkipsCoopAndCompletesPrivateReplay(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)

	input := core.SlackInput{
		ID: "slack-applying", EnvelopeID: "replay-private:slack-applying",
		EventID: "replay-private:slack-applying", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CPLAN", MessageTS: "1700.800",
		UserID: "BTERRAFORM",
		Text:   "Run notification for acme/infra\nRun run-abc\nRun Applying",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit applying replay = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.createKeys) != 0 || len(coopClient.submitKeys) != 0 {
		t.Fatalf(
			"applying lifecycle used Coop: creates=%+v submits=%+v",
			coopClient.createKeys, coopClient.submitKeys,
		)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted {
		t.Fatalf("deterministic replay run = %+v, %v", run, err)
	}
	decision, err := parseWatchDecision(string(run.Result))
	if err != nil || decision.Action != "ignore" {
		t.Fatalf("deterministic replay result = %+v, %v", decision, err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" {
		t.Fatalf("deterministic replay input = %+v, %v", stored, err)
	}
}

func TestStartupBackfillsRecentInProgressExternalMessages(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC()
	for _, input := range []core.SlackInput{
		{
			ID: "slack-recent-plan", EnvelopeID: "env-recent-plan", EventID: "event-recent-plan",
			Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CPLAN",
			MessageTS: "1700.800", UserID: "BTERRAFORM", Text: "Run Planning", ReceivedAt: now,
		},
		{
			ID: "slack-terminal", EnvelopeID: "env-terminal", EventID: "event-terminal",
			Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CPLAN",
			MessageTS: "1700.900", UserID: "BTERRAFORM", Text: "Run Applied", ReceivedAt: now,
		},
	} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
	}

	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.seedExternalMessageReconciliations(ctx); err != nil {
		t.Fatal(err)
	}
	item, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if item.Kind != workExternalMessageReconcile || item.SubjectID != "slack-recent-plan" {
		t.Fatalf("startup reconciliation work = %+v", item)
	}
}

func TestExternalLifecycleReconciliationIsProviderNeutralAndBounded(t *testing.T) {
	for _, text := range []string{
		"Run Created",
		"Run Planning",
		"Deployment in progress",
		"Workflow queued",
		"Status: waiting",
	} {
		if !shouldReconcileExternalMessage(text) {
			t.Errorf("did not recognize in-progress lifecycle %q", text)
		}
	}
	for _, text := range []string{
		"Run Errored",
		"Deployment succeeded",
		"FIRING: high memory",
		"A teammate mentioned that a job is running",
	} {
		if shouldReconcileExternalMessage(text) {
			t.Errorf("unexpected lifecycle reconciliation for %q", text)
		}
	}
	for input, expected := range map[string]string{
		"Run run-abc\nRun Planning":                   "run:run-abc",
		"Deployment prod-api\nDeployment in progress": "deployment:prod-api",
		"Run notification for <https://example.com/workspaces/acme|acme>\n" +
			"<https://example.com/workspaces/acme/runs/run-abc|Run run-abc>": "link:https://example.com/workspaces/acme/runs/run-abc",
	} {
		if actual := externalLifecycleCorrelationKey(input); actual != expected {
			t.Errorf("correlation key for %q = %q, want %q", input, actual, expected)
		}
	}
}

func TestExternalLifecycleCommunicationSuppressesOnlyNonActionablePhases(t *testing.T) {
	updates := []publicationUpdate{{
		IncidentID: "task-1", Kind: "terraform", State: "pending",
		Reference: "0123456", Summary: "Terraform is applying.",
	}}
	base := watchDecision{
		Action: "reply", Message: "Terraform is still running.",
		PublicationUpdates: updates,
	}
	for _, test := range []struct {
		name             string
		status           string
		wantAction       string
		wantPublications int
	}{
		{name: "created", status: "Run Created", wantAction: "ignore"},
		{name: "planning", status: "Run Planning", wantAction: "ignore"},
		{name: "applying", status: "Run Applying", wantAction: "ignore", wantPublications: 1},
		{name: "failed", status: "Run Errored", wantAction: "reply", wantPublications: 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			decision := enforceExternalLifecycleCommunication(core.SlackInput{
				Kind: "bot_message", Text: "Run run-abc\n" + test.status,
			}, base)
			if decision.Action != test.wantAction ||
				len(decision.PublicationUpdates) != test.wantPublications {
				t.Fatalf("decision = %+v", decision)
			}
		})
	}

	inProgress := base
	inProgress.Completion = &completionAssessment{
		Status: "decision_ready", Verdict: "in_progress", Summary: "The run is applying.",
	}
	if decision := enforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "bot_message", Text: "Run run-abc\nRun Planned - Needs Confirmation",
	}, inProgress); decision.Action != "ignore" {
		t.Fatalf("nonterminal plan narration was not suppressed: %+v", decision)
	}
	materialReview := base
	materialReview.Message = "The plan replaces a production database. Hold it for review."
	materialReview.Completion = &completionAssessment{
		Status: "decision_ready", Verdict: "needs_review", Summary: "Replacement needs review.",
	}
	if decision := enforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "bot_message", Text: "Run run-abc\nRun Planned - Needs Confirmation",
	}, materialReview); decision.Action != "reply" {
		t.Fatalf("material plan review was suppressed: %+v", decision)
	}
}

func TestExternalLifecyclePhaseDoesNotClassifyConversationProse(t *testing.T) {
	for _, text := range []string{
		"A teammate said the job is running slowly.",
		"Can you explain why the apply failed?",
		"The deployment plan needs review.",
	} {
		if phase := externalMessageLifecyclePhase(text); phase != externalLifecycleUnknown {
			t.Errorf("phase for %q = %q", text, phase)
		}
	}
}
