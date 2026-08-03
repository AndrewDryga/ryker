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
	if first.EventID != second.EventID || first.EnvelopeID != second.EnvelopeID {
		t.Fatalf("reconciled event IDs differ: %q != %q", first.EventID, second.EventID)
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
