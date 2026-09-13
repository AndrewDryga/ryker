package service

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/resultrecovery"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
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
	decision, err := decisionpkg.ParseWatchDecision(string(run.Result), testDecodeClock)
	if err != nil || decision.Action != "ignore" {
		t.Fatalf("deterministic replay result = %+v, %v", decision, err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" {
		t.Fatalf("deterministic replay input = %+v, %v", stored, err)
	}
}

// The Terraform Run Created and Run Applying cards at 19:30 on 2026-08-18
// were consumed by the deterministic lifecycle fast path but looked completely
// untouched in Slack. Host-owned handling is still handling, so it must leave
// the same terminal mark as a successful model-owned turn.
func TestHostHandledLifecycleUpdateShowsCheckWithoutStandingRule(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CPLAN"}
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
	input := core.SlackInput{
		ID: "slack-applying-live", EnvelopeID: "env-applying-live",
		EventID: "event-applying-live", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CPLAN", MessageTS: "1700.802",
		UserID: "BTERRAFORM", ReceivedAt: time.Now().UTC(),
		Text: "Run notification for acme/infra\nRun run-abc\nRun Applying",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit applying input = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.reactions) != 1 ||
		slackClient.reactions[0].name != "white_check_mark" ||
		slackClient.reactions[0].timestamp != input.MessageTS {
		t.Fatalf("handled lifecycle reactions = %+v", slackClient.reactions)
	}
}

// Better Stack edited one firing card while its investigation was still
// running. The edit was a coordination-only acknowledgement, and the fast
// path added a terminal check beside the working eyes four minutes before the
// outage decision existed. A card has one owner: lifecycle decoration cannot
// declare it handled while the exact alert episode is active.
func TestCoordinationEditCannotMarkAnActiveAlertHandled(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "COUTAGE", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "UOPERATOR",
	}); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	now := time.Now().UTC()
	const incident = "https://uptime.betterstack.com/team/t57321/incidents/1003449411"
	firing := core.SlackInput{
		ID: "slack-outage-firing", EnvelopeID: "env-outage-firing", EventID: "event-outage-firing",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "COUTAGE",
		MessageTS: "1700.812", UserID: "BBETTERSTACK", ReceivedAt: now,
		Text: "New incident for Internal Utils\nCause: Status 502\nIncident: <" + incident + "|Incident>",
	}
	if created, err := st.AdmitSlackInput(ctx, firing); err != nil || !created {
		t.Fatalf("admit firing card = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	coordination := firing
	coordination.ID = "slack-outage-acknowledged"
	coordination.EnvelopeID = "env-outage-acknowledged"
	coordination.EventID = "event-outage-acknowledged"
	coordination.ReceivedAt = now.Add(4 * time.Minute)
	coordination.Text = "<@UOPERATOR> acknowledged Internal Utils incident\nIncident: <" + incident + "|Incident>"
	if created, err := st.AdmitSlackInput(ctx, coordination); err != nil || !created {
		t.Fatalf("admit coordination edit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	for _, reaction := range slackClient.reactions {
		if reaction.name == "white_check_mark" && reaction.timestamp == firing.MessageTS {
			t.Fatalf("active alert card was marked handled: %+v", slackClient.reactions)
		}
	}
}

// Shadow means observe without writing. The deterministic lifecycle fast path
// bypassed the decision gate and left a public check mark even though replies
// from the same channel were correctly suppressed.
func TestShadowedLifecycleUpdateLeavesNoReaction(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CSHADOW", Participation: "shadow",
		Repository: "repo", AlertPolicy: "reply", ActorID: "UOPERATOR",
	}); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "slack-shadow-applying", EnvelopeID: "env-shadow-applying",
		EventID: "event-shadow-applying", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CSHADOW", MessageTS: "1700.900",
		UserID: "BTERRAFORM", ReceivedAt: time.Now().UTC(),
		Text: "Run notification for acme/infra\nRun run-abc\nRun Applying",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit shadow lifecycle = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.reactions) != 0 || len(slackClient.removedReactions) != 0 {
		t.Fatalf("shadow lifecycle changed Slack reactions: added=%+v removed=%+v",
			slackClient.reactions, slackClient.removedReactions)
	}
}

func TestExternalLifecyclePlanningRuleStartsQuietDurableExactRunWatch(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, _, err := st.Behavior.UpsertStandingRule(ctx, core.StandingRule{
		ChannelID: "CPLAN", Repository: "repo",
		Trigger: "terraform_lifecycle", Action: "monitor_terraform_lifecycle",
		SourceKind: "app", Enabled: true, SourceRef: "test", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}, cfg.Limits.MaxStandingRules, cfg.Limits.MaxRulesPerChannel); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)

	now := time.Now().UTC().Truncate(time.Second)
	coopClient.completeOnSubmit = fmt.Sprintf(`Here is the structured result:
	{
	  "action":"ignore",
	  "operations":[
	    {"id":"wait-run-abc","type":"wait_external","external_wait":{
	      "id":"wakeup-run-abc","kind":"terraform_run",
	      "event_matcher":{"provider":"hcp_terraform","run_id":"run-abc","desired_state":"reviewable_or_terminal"},
	      "poll_after":%q,"deadline":%q
	    }}
	  ]
	}`, now.Add(time.Minute).Format(time.RFC3339), now.Add(24*time.Hour).Format(time.RFC3339))
	input := core.SlackInput{
		ID: "slack-planning", EnvelopeID: "env-planning", EventID: "event-planning",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CPLAN",
		MessageTS: "1700.801", UserID: "BTERRAFORM", ReceivedAt: now,
		Text: "Run notification for <https://app.terraform.io/app/acme/workspaces/infra|acme/infra>\n" +
			"Run run-abc\nRun Planning",
	}
	if phase := externalMessageLifecyclePhase(input.Text); phase != externalLifecyclePlanning {
		t.Fatalf("planning lifecycle phase = %q", phase)
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit planning input = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(coopClient.createKeys) != 1 || len(coopClient.submitKeys) != 1 {
		t.Fatalf("planning lifecycle did not establish a durable model-owned watch: creates=%+v submits=%+v",
			coopClient.createKeys, coopClient.submitKeys)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("planning lifecycle posted narration: %+v", slackClient.posts)
	}
	if len(slackClient.reactions) != 1 || slackClient.reactions[0].name != "eyes" ||
		slackClient.reactions[0].timestamp != input.MessageTS {
		t.Fatalf("planning lifecycle reactions = %+v", slackClient.reactions)
	}
	if len(slackClient.removedReactions) != 0 {
		t.Fatalf("planning lifecycle acknowledgement was cleared: %+v", slackClient.removedReactions)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(run.Result), "Here is the structured result") {
		t.Fatalf("planning lifecycle persisted provider prose: %s", run.Result)
	}
	decision, err := decisionpkg.ParseWatchDecision(string(run.Result), testDecodeClock)
	if err != nil || decision.Action != "ignore" || decision.Completion != nil ||
		len(decision.Operations) != 1 || decision.Operations[0].Type != "wait_external" {
		t.Fatalf("canonical planning lifecycle result = %+v, %v; raw=%s", decision, err, run.Result)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal || !episode.CompletedAt.IsZero() {
		t.Fatalf("planning lifecycle episode = %+v", episode)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(wakeups) != 1 || wakeups[0].Kind != "terraform_run" ||
		wakeups[0].State != core.WakeupPending ||
		!strings.Contains(string(wakeups[0].EventMatcher), `"run_id":"run-abc"`) {
		t.Fatalf("planning lifecycle wakeups = %+v", wakeups)
	}
	metrics, err := st.WorkMetrics(ctx, store.WorkLaneBackground)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.Pending != 1 {
		t.Fatalf("planning lifecycle scheduler metrics = %+v", metrics)
	}
}

func TestIncidentAcknowledgementFastPathSkipsCoopAndSlackOutput(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)

	input := core.SlackInput{
		ID: "slack-incident-ack", EnvelopeID: "replay-private:slack-incident-ack",
		EventID: "replay-private:slack-incident-ack", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CALERTS", MessageTS: "1700.810",
		UserID: "BBETTERSTACK",
		Text:   "<@UOPERATOR> acknowledged Grafana: VA1: Typesense node unhealthy incident",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit acknowledgement replay = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.createKeys) != 0 || len(coopClient.submitKeys) != 0 {
		t.Fatalf(
			"acknowledgement used Coop: creates=%+v submits=%+v",
			coopClient.createKeys, coopClient.submitKeys,
		)
	}
	if len(slackClient.posts) != 0 || len(slackClient.reactions) != 0 ||
		len(slackClient.statuses) != 0 {
		t.Fatalf(
			"acknowledgement produced Slack output: posts=%+v reactions=%+v statuses=%+v",
			slackClient.posts, slackClient.reactions, slackClient.statuses,
		)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted {
		t.Fatalf("deterministic acknowledgement run = %+v, %v", run, err)
	}
	decision, err := decisionpkg.ParseWatchDecision(string(run.Result), testDecodeClock)
	if err != nil || decision.Action != "ignore" {
		t.Fatalf("deterministic acknowledgement result = %+v, %v", decision, err)
	}
}

func TestExternalCoordinationOnlyEvent(t *testing.T) {
	for _, text := range []string{
		"<@U123> acknowledged Grafana: VA1: Typesense node unhealthy incident",
		"New incident for Typesense\nIncident acknowledged",
		"The incident was acknowledged by Andrew.",
	} {
		if !decisionpkg.ExternalCoordinationOnlyEvent(text) {
			t.Errorf("did not recognize coordination-only event %q", text)
		}
	}
	for _, text := range []string{
		"New incident for Typesense. Please acknowledge the incident.",
		"Typesense alert is firing.",
		"The service recovered after the deployment.",
	} {
		if decisionpkg.ExternalCoordinationOnlyEvent(text) {
			t.Errorf("misclassified operational event as coordination-only %q", text)
		}
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
			"<https://example.com/workspaces/acme/runs/run-abc|Run run-abc>": "run:run-abc",
	} {
		if actual := externalLifecycleCorrelationKey(input); actual != expected {
			t.Errorf("correlation key for %q = %q, want %q", input, actual, expected)
		}
	}
}

// Covers: TestExternalLifecycleCommunicationKeepsMaterialRiskReviewAfterRunAdvanced
// Covers: TestMaterialPlanReviewSurvivesApplyInProgress
// Covers: TestAppliedTerraformCapabilityBlockerReachesTheChannel
// Covers: TestSuppressedLifecycleBlockKeepsItsBoundedRecheck
// Covers finding: 20260810T210012Z-run_ce6ee4d605b6463e4849082b5338f3ec
// Covers finding: 20260814T085412Z-run_22ab784b1e170054788bb97f906f149d
func TestExternalLifecycleCommunicationSuppressesOnlyNonActionablePhases(t *testing.T) {
	updates := []decisionpkg.PublicationUpdate{{
		IncidentID: "task-1", Kind: "terraform", State: "pending",
		Reference: "0123456", Summary: "Terraform is applying.",
	}}
	base := decisionpkg.WatchDecision{
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
		{name: "succeeded", status: "Run Applied", wantAction: "ignore", wantPublications: 1},
		{name: "failed", status: "Run Errored", wantAction: "reply", wantPublications: 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			decision := EnforceExternalLifecycleCommunication(core.SlackInput{
				Kind: "bot_message", Text: "Run run-abc\n" + test.status,
			}, base)
			if decision.Action != test.wantAction ||
				len(decision.PublicationUpdates) != test.wantPublications {
				t.Fatalf("decision = %+v", decision)
			}
		})
	}

	inProgress := base
	inProgress.Completion = &CompletionAssessment{
		Status: "decision_ready", Verdict: "in_progress", Summary: "The run is applying.",
	}
	if decision := EnforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "bot_message", Text: "Run run-abc\nRun Planned - Needs Confirmation",
	}, inProgress); decision.Action != "ignore" {
		t.Fatalf("nonterminal plan narration was not suppressed: %+v", decision)
	}
	materialReview := base
	materialReview.Message = "The plan replaces a production database. Hold it for review."
	materialReview.Completion = &CompletionAssessment{
		Status: "decision_ready", Verdict: "needs_review", Summary: "Replacement needs review.",
	}
	reviewInput := core.SlackInput{
		Kind: "bot_message",
		Text: "Run <https://app.terraform.io/app/acme/infra/runs/run-abc|run-abc>\n" +
			"Run Planned - Needs Confirmation",
	}
	if decision := EnforceExternalLifecycleCommunication(reviewInput, materialReview); decision.Action != "reply" {
		t.Fatalf("material plan review was suppressed: %+v", decision)
	} else if decision = EnrichExternalLifecycleReply(reviewInput, decision); !strings.Contains(decision.Message, "https://app.terraform.io/app/acme/infra/runs/run-abc") {
		t.Fatalf("host did not add the source-owned provider URL: %q", decision.Message)
	}
	if decision := EnforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "bot_message", Text: "Run run-abc\nRun Planning",
	}, materialReview); decision.Action != "reply" {
		t.Fatalf("provider-backed review discovered during planning was suppressed: %+v", decision)
	}
	blockedReview := base
	blockedReview.Message = "The saved plan is ready, but the provider omitted part of its drift list."
	blockedReview.Completion = &CompletionAssessment{
		Status: "blocked", Summary: "The material plan review is incomplete.",
		MaterialGaps: []string{"The complete drift list is unavailable."},
		BlockerKind:  "source_unavailable",
		Attempts:     []string{"Read the exact saved plan."},
		NextAction:   "Expose the complete drift list.",
	}
	if decision := EnforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "bot_message", Text: "Run run-abc\nRun Planning",
	}, blockedReview); decision.Action != "reply" {
		t.Fatalf("provider blocker discovered during planning was suppressed: %+v", decision)
	}
	quietWait := base
	quietWait.AppliedOperations = []investigation.ResultOperation{{
		ID: "wait-run", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: "wake-run", Kind: "terraform_run",
		},
	}}
	quietWait.Completion = &CompletionAssessment{
		Status: "decision_ready", Verdict: "in_progress", Summary: "Still planning.",
	}
	if decision := EnforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "recheck",
	}, quietWait); decision.Action != "ignore" ||
		!waitsForExternalKind(decision, "terraform_run") {
		t.Fatalf("quiet recheck lost its durable wait: %+v", decision)
	}

	now := time.Now().UTC()
	verifiedRollout := base
	verifiedRollout.Message = "The new revision is serving successfully on both instances."
	verifiedRollout.Evidence = []core.Evidence{{
		Claim: "the rollout is healthy", Observation: "both instances serve the new revision",
		SourceType: "emisar", SourceName: "rollout health", ObservedAt: now,
	}}
	verifiedRollout.Coverage = []core.Coverage{{
		Layer: "workload", Status: "healthy", Source: "rollout health",
		Detail: "both instances serve the new revision", ObservedAt: now,
	}}
	if decision := EnforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "bot_message", Text: "Run run-abc\nRun Applied",
	}, verifiedRollout); decision.Action != "reply" {
		t.Fatalf("fresh rollout verification was suppressed: %+v", decision)
	}
}

// GitHub Actions formats its field label with Slack mrkdwn. The lifecycle
// source still says success; the punctuation must not turn it into an unknown
// event and allow Ryker to narrate the green card without runtime proof.
// Covers: TestGitHubActionsSuccessWithoutFreshRuntimeEvidenceStaysSilent
func TestGitHubActionsSuccessWithoutFreshRuntimeEvidenceStaysSilent(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "*Workflow:* deploy\n*Status:* :large_green_circle: Success\n*Branch:* main",
	}
	decision := decisionpkg.WatchDecision{
		Action: "reply", Message: "The workflow succeeded.",
		Completion: &CompletionAssessment{
			Status: "decision_ready", Verdict: "healthy", Summary: "CI passed.",
		},
	}
	if got := EnforceExternalLifecycleCommunication(input, decision); got.Action != "ignore" {
		t.Fatalf("source-only GitHub Actions success reached Slack: %+v", got)
	}
}

// A correction recheck stays quiet until its bounded last attempt, then turns
// into one visible blocker. Earlier retries must retain the recheck directive.
// Covers: TestStructuredCorrectionRecheckContinuesSilentlyUntilFinalAttempt
func TestStructuredCorrectionRecheckContinuesSilentlyUntilFinalAttempt(t *testing.T) {
	run := core.AgentRun{ID: "run_rejected"}
	input := core.SlackInput{Kind: "bot_message"}
	for _, test := range []struct {
		attempt     int
		wantAction  string
		wantRecheck bool
	}{
		{attempt: 1, wantAction: "ignore", wantRecheck: true},
		{attempt: 2, wantAction: "reply", wantRecheck: false},
	} {
		state := decisionpkg.WatchTurnState{RecheckAttempt: test.attempt}
		decision := resultrecovery.BlockedWatch(run, input, state, "invalid result", nil)
		if decision.Action != test.wantAction {
			t.Fatalf("attempt %d action = %q", test.attempt, decision.Action)
		}
		gotRecheck := decision.Completion != nil && decision.Completion.Recheck != nil
		if gotRecheck != test.wantRecheck {
			t.Fatalf("attempt %d recheck = %t", test.attempt, gotRecheck)
		}
	}
}

func TestTerraformLifecycleContinuationRequiresExactDurableWait(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "Run notification for acme/infra\n" +
			"Run run-abc\n<https://app.terraform.io/app/acme/infra/runs/run-abc|Open run>\nRun Planning",
	}
	state := decisionpkg.WatchTurnState{MatchedRules: []core.StandingRule{{
		Trigger: "terraform_lifecycle", Action: "monitor_terraform_lifecycle",
	}}}
	unfinished := decisionpkg.WatchDecision{
		Action: "reply",
		Completion: &CompletionAssessment{
			Status: "decision_ready", Verdict: "in_progress", Summary: "Still planning.",
		},
	}
	if correction := TerraformLifecycleContinuationCorrection(input, state, unfinished); correction == "" {
		t.Fatal("accepted a nonterminal Terraform result without durable continuation")
	}
	waiting := unfinished
	waiting.AppliedOperations = []investigation.ResultOperation{{
		ID: "wait-run-abc", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: "wakeup-run-abc", Kind: "terraform_run",
			EventMatcher: []byte(`{"provider":"hcp_terraform","run_id":"run-abc"}`),
			PollAfter:    now.Add(time.Minute).Format(time.RFC3339),
			Deadline:     now.Add(24 * time.Hour).Format(time.RFC3339),
		},
	}}
	if correction := TerraformLifecycleContinuationCorrection(input, state, waiting); correction != "" {
		t.Fatalf("rejected exact durable Terraform wait: %s", correction)
	}
	wrongRun := unfinished
	wrongRun.AppliedOperations = []investigation.ResultOperation{{
		ID: "wait-run-other", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: "wakeup-run-other", Kind: "terraform_run",
			EventMatcher: []byte(`{"run_id":"run-other"}`),
			PollAfter:    now.Add(time.Minute).Format(time.RFC3339),
			Deadline:     now.Add(24 * time.Hour).Format(time.RFC3339),
		},
	}}
	if correction := TerraformLifecycleContinuationCorrection(input, state, wrongRun); correction == "" {
		t.Fatal("accepted a Terraform wait for a different run")
	}
	review := waiting
	review.Message = "The saved plan needs approval."
	review.Completion = &CompletionAssessment{
		Status: "decision_ready", Verdict: "needs_review", Summary: "The saved plan needs approval.",
	}
	if correction := TerraformLifecycleContinuationCorrection(input, state, review); !strings.Contains(correction, "fresh affected-scope") {
		t.Fatalf("approval review without pre-change health correction = %q", correction)
	}
	review.Evidence = []core.Evidence{{
		Claim: "the current workload is healthy", Observation: "both replicas are ready",
		SourceType: "emisar", SourceName: "workload health", ObservedAt: now,
	}}
	review.Coverage = []core.Coverage{{
		Layer: "workload", Status: "healthy", Source: "workload health",
		Detail: "both replicas are ready", ObservedAt: now,
	}}
	if correction := TerraformLifecycleContinuationCorrection(input, state, review); correction != "" {
		t.Fatalf("rejected approval-ready review with URL, health, and terminal wait: %s", correction)
	}
	delivered := EnrichExternalLifecycleReply(
		input, EnforceExternalLifecycleCommunication(input, review),
	)
	if !strings.Contains(delivered.Message, "https://app.terraform.io/app/acme/infra/runs/run-abc") {
		t.Fatalf("approval review did not receive the canonical source URL: %q", delivered.Message)
	}
	recheckInput := input
	recheckInput.Kind = "recheck"
	delivered = EnrichExternalLifecycleReply(recheckInput, review)
	if !strings.Contains(delivered.Message, "https://app.terraform.io/app/acme/infra/runs/run-abc") {
		t.Fatalf("approval-ready wakeup did not receive the canonical source URL: %q", delivered.Message)
	}
	terminal := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "The rollout is healthy after the apply.",
		Evidence: []core.Evidence{{
			Claim: "the rollout is healthy", Observation: "both replicas serve the new revision",
			SourceType: "emisar", SourceName: "rollout health", ObservedAt: now,
		}},
		Coverage: []core.Coverage{{
			Layer: "workload", Status: "healthy", Source: "rollout health",
			Detail: "both replicas serve the new revision", ObservedAt: now,
		}},
		Completion: &CompletionAssessment{
			Status: "decision_ready", Verdict: "succeeded", Summary: "Applied and verified.",
		},
	}
	if correction := TerraformLifecycleContinuationCorrection(input, state, terminal); correction != "" {
		t.Fatalf("required a wakeup after terminal completion: %s", correction)
	}
	terminalWithoutHealth := terminal
	terminalWithoutHealth.Evidence = nil
	terminalWithoutHealth.Coverage = nil
	if correction := TerraformLifecycleContinuationCorrection(input, state, terminalWithoutHealth); !strings.Contains(correction, "post") && !strings.Contains(correction, "applied") {
		t.Fatalf("applied result without post-change health correction = %q", correction)
	}
}

// A card processed hours after it arrived is still verifiable. The freshness
// clock for a Terraform apply was the card's own arrival time, so evidence the
// model gathered when it finally ran read as "observed in the future" and was
// discarded: run_15d4bde1 (Run Applied, received 00:49Z, retried 05:15Z after
// a credential outage) recorded ten /healthz samples at 05:18Z and was told
// twice, verbatim, to record fresh evidence — a correction nothing it could
// send would satisfy. Freshness is measured against when the turn ran.
func TestALateProcessedApplyIsVerifiedByEvidenceGatheredWhenItRan(t *testing.T) {
	arrived := time.Now().UTC().Add(-4 * time.Hour).Truncate(time.Second)
	gathered := time.Now().UTC().Truncate(time.Second)
	input := core.SlackInput{
		Kind:       "bot_message",
		Text:       "Run notification for acme/infra\nRun run-late\nRun Applied",
		ReceivedAt: arrived,
	}
	state := decisionpkg.WatchTurnState{MatchedRules: []core.StandingRule{{
		Trigger: "terraform_lifecycle", Action: "monitor_terraform_lifecycle",
	}}}
	verified := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "Portal is on the applied revision and serving normally.",
		Evidence: []core.Evidence{{
			Claim: "the rollout is healthy", Observation: "ten /healthz samples report the applied revision",
			SourceType: "monitoring", SourceName: "emisar.dev health", ObservedAt: gathered,
		}},
		Coverage: []core.Coverage{{
			Layer: "workload", Status: "healthy", Source: "emisar.dev health",
			Detail: "ten /healthz samples report the applied revision", ObservedAt: gathered,
		}},
		Completion: &CompletionAssessment{
			Status: "decision_ready", Verdict: "succeeded", Summary: "Applied and verified.",
		},
	}
	if correction := TerraformLifecycleContinuationCorrection(input, state, verified); correction != "" {
		t.Fatalf("evidence gathered when the late turn ran was rejected as not fresh: %s", correction)
	}
}

func TestSuccessfulLifecycleDoesNotParaphraseVisibleStatusOrOldPlanContext(t *testing.T) {
	now := time.Now().UTC()
	decision := EnforceExternalLifecycleCommunication(core.SlackInput{
		Kind: "bot_message",
		Text: "Run notification for SME-Blitz/blitz-infra\n" +
			"Run run-RvK3U9VVwhcujW6D\nRun Applied",
	}, decisionpkg.WatchDecision{
		Action: "reply",
		Message: "run-RvK3U9VVwhcujW6D is applied. This terminal notification closes " +
			"the Terraform lifecycle check. Runtime verification remains.",
		Evidence: []core.Evidence{{
			Claim: "the apply completed", Observation: "HCP Terraform reports Run Applied",
			SourceType: "monitoring", SourceName: "HCP Terraform", ObservedAt: now,
		}},
		Coverage: []core.Coverage{{
			Layer: "change", Status: "healthy", Source: "HCP Terraform",
			Detail: "the apply completed", ObservedAt: now,
		}},
		Completion: &CompletionAssessment{
			Status: "decision_ready", Verdict: "healthy", Summary: "The apply completed.",
		},
	})
	if decision.Action != "ignore" || decision.Message != "" {
		t.Fatalf("redundant success narration reached Slack: %+v", decision)
	}
}

func TestStaleLifecycleReplyKeepsOnlyChangeHealthAndIndependentCaveat(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "Run run-UBwFpsiiVMtXwtbi\nRun Planned - Needs Confirmation",
	}
	verbose := decisionpkg.WatchDecision{
		Action: "reply",
		Message: "Terraform run run-UBwFpsiiVMtXwtbi has already applied successfully; the Needs " +
			"Confirmation notification is stale. The plan replaced the Emisar GCP runner VM and " +
			"updated Tolgee Cloud SQL. Post-apply, the runner is connected with no reported issues " +
			"and the database is RUNNABLE. The review caveat is 61 drifted resources: the summary " +
			"exposed three Better Uptime monitors but omitted the other 58 entries. No further apply " +
			"action is needed; review the complete drift list before the next run and verify it " +
			"contains only expected external changes.",
		Completion: &CompletionAssessment{Status: "decision_ready", Verdict: "healthy"},
	}
	if correction := ExternalLifecycleReplyLanguageCorrection(input, verbose); correction == "" {
		t.Fatal("accepted bureaucratic stale lifecycle narration")
	}
	concise := decisionpkg.WatchDecision{
		Action: "reply",
		Message: "**This plan already applied, so the confirmation card is stale.** It replaced " +
			"the Emisar runner VM and updated Tolgee Cloud SQL; the runner is connected and the " +
			"database is healthy.\n\nThe 61 drifted resources are separate follow-up work.",
		Completion: &CompletionAssessment{Status: "decision_ready", Verdict: "healthy"},
	}
	if correction := ExternalLifecycleReplyLanguageCorrection(input, concise); correction != "" {
		t.Fatalf("rejected concise stale lifecycle update: %s", correction)
	}
	missingStale := concise
	missingStale.Message = "The run applied successfully. It replaced the Emisar runner VM and " +
		"updated Tolgee Cloud SQL; the runner is connected and the database is healthy."
	missingStale.Completion.Verdict = "succeeded"
	if correction := ExternalLifecycleReplyLanguageCorrection(input, missingStale); correction == "" {
		t.Fatal("accepted a stale source card without calling it stale")
	}
}

func TestTerminalLifecycleEvidenceIsHostBoundBeforeCompletionValidation(t *testing.T) {
	observedAt := time.Date(2026, 8, 4, 23, 31, 0, 0, time.UTC)
	episode := core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Objective: "Review the exact Terraform run",
		RequiredCoverage: []string{"change"},
	}
	decision, adjusted := EnforceExternalLifecycleEvidence(core.SlackInput{
		ID: "slack-run-failed", EventID: "EvRunFailed", Kind: "bot_message",
		ReceivedAt: observedAt,
		Text: "Run notification for <https://example.com/acme/infra|acme/infra>\n" +
			"<https://example.com/acme/infra/runs/run-abc|Run run-abc>\nRun Errored",
	}, episode, decisionpkg.WatchDecision{
		Action: "reply",
		Coverage: []core.Coverage{{
			Layer: "change", Status: "unknown", Detail: "Partial effects are unknown.",
		}},
	})
	if !adjusted || len(decision.Evidence) != 1 ||
		decision.Evidence[0].ClaimID != "change.recent" ||
		decision.Evidence[0].Relation != "contradicts" ||
		decision.Evidence[0].HealthEffect != "unhealthy" {
		t.Fatalf("terminal evidence = %+v, adjusted=%t", decision.Evidence, adjusted)
	}
	if len(decision.Coverage) != 1 || decision.Coverage[0].Status != "unhealthy" ||
		!containsString(decision.Coverage[0].ClaimIDs, "change.recent") ||
		!decision.Coverage[0].ObservedAt.Equal(observedAt) {
		t.Fatalf("terminal coverage = %+v", decision.Coverage)
	}
}

func TestTerminalLifecycleEvidencePreservesTypedOperationsTransport(t *testing.T) {
	observedAt := time.Date(2026, 8, 4, 23, 31, 0, 0, time.UTC)
	input := core.SlackInput{
		ID: "slack-run-failed", EventID: "EvRunFailed", Kind: "bot_message",
		ReceivedAt: observedAt,
		Text: "Run notification for <https://example.com/acme/infra|acme/infra>\n" +
			"<https://example.com/acme/infra/runs/run-abc|Run run-abc>\nRun Errored",
	}
	message := `{"action":"reply","operations":[` +
		`{"id":"coverage-change","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"unknown","detail":"Partial effects are unknown."}},` +
		`{"id":"complete","type":"complete_episode","completion":{"message":"The apply failed; inspect the exact diagnostic before retrying.","completion":{"status":"decision_ready","verdict":"failed","summary":"The apply failed."}}}` +
		`]}`
	decision, err := decisionpkg.ParseWatchDecision(message, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	decision, adjusted := EnforceExternalLifecycleEvidence(input, core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Objective: "Review the exact Terraform run",
		RequiredCoverage: []string{"change"},
	}, decision)
	if !adjusted {
		t.Fatal("terminal lifecycle evidence was not adjusted")
	}
	encoded, err := decisionpkg.MarshalWatchDecisionResult(decision)
	if err != nil {
		t.Fatal(err)
	}
	reparsed, err := decisionpkg.ParseWatchDecision(string(encoded), testDecodeClock)
	if err != nil {
		t.Fatalf("reparse typed transport: %v\n%s", err, encoded)
	}
	if len(reparsed.Evidence) != 1 || reparsed.Evidence[0].ClaimID != "change.recent" ||
		reparsed.Evidence[0].HealthEffect != "unhealthy" {
		t.Fatalf("reparsed evidence = %+v", reparsed.Evidence)
	}
	if len(reparsed.Coverage) != 1 || reparsed.Coverage[0].Status != "unhealthy" {
		t.Fatalf("reparsed coverage = %+v", reparsed.Coverage)
	}
	if got := reparsed.Operations[len(reparsed.Operations)-1].Type; got != "complete_episode" {
		t.Fatalf("last operation = %q", got)
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

// Host suppression has to survive the database. Policy converted a redundant
// Terraform-success notice to ignore and left the operation stream intact,
// because those operations carry evidence worth keeping — but the operation
// stream is also what a reply is rebuilt from, so finalization read it back and
// posted the exact message policy had just decided not to send. Seventeen
// separate quality findings are this one round trip.
// Covers: TestSuccessfulLifecycleSuppressionSurvivesTypedOperationsRoundTrip
// Covers: TestSuppressedTypedLifecycleReplyStaysSilentAcrossPersistence
// Covers: TestSuppressedTypedWatchDecisionRemainsIgnoredAfterPersistenceRoundTrip
// Covers: TestSuppressedTypedLifecycleDecisionSurvivesResultRoundTrip
// Covers: TestSuppressedTypedLifecycleDecisionStaysIgnoredAfterRoundTrip
// Covers: TestSuppressedLifecycleResultWithMemorySurvivesPersistence
// Covers: TestSuppressedLifecycleReplyWithMemorySurvivesPersistence
// Covers: TestSuppressedLifecycleReplyWithMemoryStaysSuppressedAfterPersistence
// Covers finding: 20260810T192406Z-run_89281c05e23669a4d67c84432a174b28
// Covers finding: 20260810T211848Z-run_a195db0a00fe4148317f0a0ef672e38f
// Covers finding: 20260810T231750Z-run_8d88406b670383df3aee6f50692a887f
// Covers finding: 20260811T172159Z-run_3f946d903c7596bda2f5eb213a22ce58
// Covers finding: 20260811T201852Z-run_d04e2c56d1efc4905478e2de3ef3b28f
// Covers finding: 20260812T144840Z-run_bb6a463310db34f3b6933bf6a9289db8
// Covers finding: 20260812T154716Z-run_a7f9bd0bdff77d2b41b236d07036cc79
// Covers finding: 20260812T172232Z-run_7c97056964b4781bff28319da752dfec
// Covers finding: 20260812T173311Z-run_800fb7b1925a7feb803e4ea975f84745
// Covers finding: 20260812T182339Z-run_7f1f8bba54763e43ae047001560eb2c4
// Covers finding: 20260813T205845Z-run_f87173737dd525259b51c1682812b863
// Covers finding: 20260813T214950Z-run_970d12c802d3638357f92994c87626fd
// Covers finding: 20260813T221030Z-run_1bce224533f703e67cc34fe06132a2fd
// Covers finding: 20260813T222052Z-run_38c1180e80e87577eec7fbd9844636d5
// Covers finding: 20260814T163231Z-run_6b2d6ab9ea58dcc59bb543d7afd5ca8a
func TestSuppressedLifecycleReplyStaysSuppressedAfterPersistence(t *testing.T) {
	input := core.SlackInput{
		ID: "slack-run-succeeded", EventID: "EvRunOK", Kind: "bot_message",
		ReceivedAt: time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC),
		Text: "Run notification for <https://example.com/acme/infra|acme/infra>\n" +
			"<https://example.com/acme/infra/runs/run-ok|Run run-ok>\nRun Applied",
	}
	message := `{"action":"reply","operations":[` +
		`{"id":"evidence-change","type":"record_evidence","evidence":{"claim_id":"change.recent",` +
		`"observation":"The apply completed cleanly.","source_type":"terraform","source_name":"acme/infra",` +
		`"relation":"supports","health_effect":"none"}},` +
		`{"id":"memory","type":"update_memory","memory":{"situation_summary":"The apply completed cleanly."}},` +
		`{"id":"complete","type":"complete_episode","completion":{"message":"The Terraform apply succeeded.",` +
		`"completion":{"status":"decision_ready","verdict":"healthy","summary":"Apply succeeded."}}}` +
		`]}`
	decision, err := decisionpkg.ParseWatchDecision(message, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	decision = EnforceExternalLifecycleCommunication(input, decision)
	if decision.Action != "ignore" {
		t.Fatalf("host did not suppress the successful lifecycle reply: action %q", decision.Action)
	}

	encoded, err := decisionpkg.MarshalWatchDecisionResult(decision)
	if err != nil {
		t.Fatal(err)
	}
	reparsed, err := decisionpkg.ParseWatchDecision(string(encoded), testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	if reparsed.Action != "ignore" {
		t.Fatalf("suppressed decision became %q after the round trip: %s", reparsed.Action, encoded)
	}
	if strings.TrimSpace(reparsed.Message) != "" {
		t.Fatalf("suppressed decision recovered a reply body: %q", reparsed.Message)
	}
	if reparsed.Completion != nil || len(reparsed.FollowupMessages) != 0 || len(reparsed.Visuals) != 0 {
		t.Fatal("suppressed decision recovered reply content beside the empty message")
	}
	// The suppression was about the message, never about what the turn found.
	// Dropping the evidence would trade a redundant Slack notice for a hole in
	// the record, which is the wrong repair.
	if len(reparsed.Evidence) != 1 || reparsed.Evidence[0].ClaimID != "change.recent" {
		t.Fatalf("suppression discarded the evidence it should keep: %+v", reparsed.Evidence)
	}
	if reparsed.Memory.SituationSummary != "The apply completed cleanly." {
		t.Fatalf("suppression discarded durable memory: %+v", reparsed.Memory)
	}
}

// Suppression decides what Slack hears. It does not decide whether the model's
// own result was coherent — but completion validation skips anything that is
// not a reply, and suppression makes every result an ignore. So a succeeded
// change review over change coverage the same turn had marked unknown was
// finalized silently, because policy removed the evidence of its own
// invalidity before anything looked at it.
// Covers: TestLifecycleSuppressionDoesNotBypassCompletionValidation
// Covers finding: 20260813T172916Z-run_1d689933cac8c443eb2dffc2f23feef6
func TestSuppressedLifecycleResultIsStillValidatedAgainstItsContract(t *testing.T) {
	input := core.SlackInput{
		ID: "slack-run-invalid", EventID: "EvRunInvalid", Kind: "bot_message",
		ReceivedAt: time.Date(2026, 8, 13, 10, 0, 0, 0, time.UTC),
		Text: "Run notification for <https://example.com/acme/infra|acme/infra>\n" +
			"<https://example.com/acme/infra/runs/run-ok|Run run-ok>\nRun Applied",
	}
	episode := core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Objective: "Review the exact Terraform run",
		RequiredCoverage: []string{"change"},
	}
	// A terminal verdict over coverage the same turn could not establish.
	message := `{"action":"reply","operations":[` +
		`{"id":"coverage-change","type":"record_coverage","coverage":{"layer":"change",` +
		`"claim_ids":["change.recent"],"status":"unknown","detail":"Effects are unknown."}},` +
		`{"id":"complete","type":"complete_episode","completion":{"message":"The apply succeeded.",` +
		`"completion":{"status":"decision_ready","verdict":"healthy","summary":"Apply succeeded."}}}` +
		`]}`
	decision, err := decisionpkg.ParseWatchDecision(message, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	beforeAction, beforeCompletion := decision.Action, decision.Completion

	suppressed := EnforceExternalLifecycleCommunication(input, decision)
	if suppressed.Action != "ignore" || suppressed.Completion != nil {
		t.Fatalf("the host did not suppress this successful lifecycle reply: %+v", suppressed)
	}

	// Validated after suppression it says nothing, which is the defect: the
	// verdict reaches the episode either way.
	coverage := decisionpkg.SanitizeCoverage(suppressed.Coverage, "", "", "", testDecodeClock)
	if after := investigation.CompletionCorrection(
		episode, suppressed.Action, coverage, suppressed.Completion,
	); after != "" {
		t.Fatalf("suppressed decision was already validated, so this test proves nothing: %q", after)
	}
	if before := investigation.CompletionCorrection(
		episode, beforeAction, coverage, beforeCompletion,
	); before == "" {
		t.Fatal("a healthy verdict over unknown change coverage was accepted as valid")
	}
}

// A verified rollout is not a status paraphrase, and suppression could not tell
// them apart.
//
// The rule required a coverage layer other than change to carry a real status,
// so a reply whose whole point was that the change landed and the service
// answers — fresh probe evidence bound to change.recent, change coverage
// healthy — was suppressed as redundant narration.
// Covers: TestAppliedTerraformSuccessWithUnobservableRuntimeStaysSilent
// Covers finding: 20260813T184608Z-run_bdabfcc0665da45a3f939e0dc7ccc13b
// Covers finding: 20260813T193840Z-run_013c9bade228ec7b3f84235ebf44dcc1
// Covers finding: 20260814T162201Z-run_7679d23d37147598601f9188ad0e90ed
func TestAppliedTerraformReplyWithContractShapedFreshRuntimeEvidenceIsNotSuppressed(t *testing.T) {
	observed := time.Now().UTC()
	input := core.SlackInput{
		ID: "slack-run-applied", EventID: "EvApplied", Kind: "bot_message",
		ReceivedAt: observed,
		Text: "Run notification for <https://example.com/acme/infra|acme/infra>\n" +
			"<https://example.com/acme/infra/runs/run-ok|Run run-ok>\nRun Applied",
	}
	verified := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "The apply landed and the service answers on the new revision.",
		Evidence: []core.Evidence{{
			ID: "evidence-probe", ClaimID: "change.recent",
			Observation: "The HTTP probe returns 200 on the new revision.",
			SourceType:  "emisar", SourceName: "http-probe", Relation: "supports",
			HealthEffect: "none", ObservedAt: observed.Add(-time.Minute),
		}},
		Coverage: []core.Coverage{{
			Layer: "change", Status: "healthy", ClaimIDs: []string{"change.recent"},
			Detail: "The requested revision is the running one.", ObservedAt: observed,
		}},
	}
	if got := EnforceExternalLifecycleCommunication(input, verified); got.Action != "reply" {
		t.Fatalf("a verified rollout with fresh runtime evidence was suppressed: action %q", got.Action)
	}

	// Still suppressed: coverage the model asserted from the notification it was
	// reading rather than from anything it recorded.
	asserted := verified
	asserted.Coverage = []core.Coverage{{
		Layer: "change", Status: "healthy", Source: "HCP Terraform",
		Detail: "the apply completed", ObservedAt: observed,
	}}
	if got := EnforceExternalLifecycleCommunication(input, asserted); got.Action != "ignore" {
		t.Fatalf("unbound change coverage reached the channel: action %q", got.Action)
	}
}
