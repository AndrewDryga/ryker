package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestOperationalCorrelationKeyTracksAlertLifecycle(t *testing.T) {
	firing := core.SlackInput{
		Kind: "bot_message", UserID: "BGRAFANA",
		Text: "[VA1 FIRING:1] WARNING | High disk I/O latency\n" +
			"FIRING - 1 alert\nDisk latency is high\nService: cluster\nComponent: cassandra",
	}
	resolved := firing
	resolved.Text = "[VA1 RESOLVED:2] WARNING | High disk I/O latency\n" +
		"RESOLVED - 2 alerts\nDisk latency is normal\nService: cluster\nComponent: cassandra"
	if got, want := OperationalCorrelationKey(resolved), OperationalCorrelationKey(firing); got != want {
		t.Fatalf("resolved correlation = %q, want %q", got, want)
	}
	other := firing
	other.Text = strings.ReplaceAll(other.Text, "cassandra", "typesense")
	if OperationalCorrelationKey(other) == OperationalCorrelationKey(firing) {
		t.Fatal("unrelated components shared an alert stream")
	}
}

func TestOperationalCorrelationKeyPrefersStableAlertLinkOverDashboardRange(t *testing.T) {
	first := core.SlackInput{
		Kind: "bot_message", UserID: "BGRAFANA",
		Text: "<https://grafana.example.com/alerting/grafana/alert-123/view?orgId=1|FIRING>\n" +
			"<https://grafana.example.com/d/dashboard?from=100&amp;to=200|Dashboard>",
	}
	second := first
	second.Text = "<https://grafana.example.com/alerting/grafana/alert-123/view?orgId=1|FIRING>\n" +
		"<https://grafana.example.com/d/dashboard?from=300&amp;to=400|Dashboard>"
	if got, want := OperationalCorrelationKey(second), OperationalCorrelationKey(first); got != want {
		t.Fatalf("repeated alert correlation = %q, want %q", got, want)
	}
	if got := OperationalCorrelationKey(first); !strings.Contains(got, "/alerting/grafana/alert-123/view") {
		t.Fatalf("alert correlation did not retain stable alert identity: %q", got)
	}
	other := first
	other.Text = strings.ReplaceAll(other.Text, "alert-123", "alert-456")
	if OperationalCorrelationKey(other) == OperationalCorrelationKey(first) {
		t.Fatal("distinct stable alert links shared an operational stream")
	}
}

func TestResolvedOperationalUpdateCannotDiscardCorrelatedFiringInvestigation(t *testing.T) {
	firingText := "[VA1 FIRING:1] WARNING | High disk I/O latency\n" +
		"FIRING - 1 alert\nService: cluster\nComponent: cassandra"
	resolved := core.SlackInput{
		Kind: "bot_message", UserID: "BGRAFANA",
		Text: "[VA1 RESOLVED:1] WARNING | High disk I/O latency\n" +
			"RESOLVED - 1 alert\nService: cluster\nComponent: cassandra",
	}
	state := decisionpkg.WatchTurnState{RecentMessages: []decisionpkg.WatchContextMessage{
		{
			MessageTS: "1700.001", SenderID: "BGRAFANA",
			SenderType: "external_app", Text: firingText,
		},
		{
			MessageTS: "1700.002", SenderID: "BGRAFANA",
			SenderType: "external_app", Text: resolved.Text, Target: true,
		},
	}}
	correction := decisionpkg.WatchDecisionCorrectionAt(
		resolved, state, decisionpkg.WatchDecision{Action: "ignore"}, time.Now().UTC(), OperationalCorrelationKey,
	)
	if !strings.Contains(correction, "investigation was already admitted") {
		t.Fatalf("resolved alert correction = %q", correction)
	}

	unrelated := resolved
	unrelated.Text = strings.ReplaceAll(unrelated.Text, "cassandra", "typesense")
	if correction := decisionpkg.WatchDecisionCorrectionAt(
		unrelated, state, decisionpkg.WatchDecision{Action: "ignore"}, time.Now().UTC(), OperationalCorrelationKey,
	); correction != "" {
		t.Fatalf("unrelated resolved alert correction = %q", correction)
	}
}

func TestOperationalAlertResolvedEventRecognizesProviderLifecycleWording(t *testing.T) {
	for _, text := range []string{
		"[VA1 RESOLVED:2] WARNING | High disk I/O latency",
		"logging/user/emisar/recurrent_job_failures returned to normal with a value of 0.000.",
		"Alert closed No severity",
	} {
		if !decisionpkg.OperationalAlertResolvedEvent(text) {
			t.Fatalf("resolved alert wording not recognized: %q", text)
		}
	}
	if decisionpkg.OperationalAlertResolvedEvent("Alert open No severity") {
		t.Fatal("open alert was classified as resolved")
	}
}

func TestOperationalCorrelationKeyTracksTerraformRunLifecycle(t *testing.T) {
	planned := core.SlackInput{Kind: "bot_message", UserID: "BTFC", Text: `
Run notification for SME-Tenant/tenant-infra
Run run-6d2hQfNJrTeyAP4T
Run Planned - Needs Confirmation`}
	errored := planned
	errored.Text = `Run run-6d2hQfNJrTeyAP4T is applying
Run Errored`
	if got, want := OperationalCorrelationKey(errored), OperationalCorrelationKey(planned); got != want {
		t.Fatalf("Terraform lifecycle correlation = %q, want %q", got, want)
	}
	other := planned
	other.Text = strings.ReplaceAll(other.Text, "run-6d2hQfNJrTeyAP4T", "run-R1FRs9QFdGmTbBUx")
	if OperationalCorrelationKey(other) == OperationalCorrelationKey(planned) {
		t.Fatal("different Terraform runs shared a lifecycle stream")
	}
}

func TestOperationalBurstCoalescesBeforeCoopAndLinksEpisodes(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}

	base := core.SlackInput{
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		EnvelopeID: "env-finalizing-alert",
		UserID:     "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 FIRING:1] WARNING | High disk I/O latency\n" +
			"FIRING - 1 alert\nService: cluster\nComponent: cassandra",
	}
	first := base
	first.ID, first.EnvelopeID, first.EventID, first.MessageTS = "storm-1", "env-storm-1", "event-storm-1", "1700.001"
	second := base
	second.ID, second.EnvelopeID, second.EventID, second.MessageTS = "storm-2", "env-storm-2", "event-storm-2", "1700.002"
	second.Text = strings.Replace(second.Text, "FIRING:1", "FIRING:2", 1)
	for _, input := range []core.SlackInput{first, second} {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}

	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	oldRun, err := st.GetAgentRunBySource(ctx, "watch", first.ID)
	if err != nil || oldRun.State != core.AgentRunSuperseded {
		t.Fatalf("older correlated run = %+v, %v", oldRun, err)
	}
	if len(coopClient.submitPrompts) != 0 {
		t.Fatalf("superseded update reached Coop: %d prompts", len(coopClient.submitPrompts))
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	newRun, err := st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("newest update prompts = %d, want 1", len(coopClient.submitPrompts))
	}
	newEpisode, err := st.GetWorkEpisode(ctx, newRun.EpisodeID)
	if err != nil || newRun.EpisodeID != oldRun.EpisodeID || newEpisode.ParentEpisodeID != "" {
		t.Fatalf("correlated lifecycle episode = run=%+v episode=%+v err=%v", newRun, newEpisode, err)
	}
}

// Two Grafana cards on 2026-08-16 kept 👀 for hours after their runs were
// coalesced into a newer card; the answered cards had theirs removed, so the
// abandoned ones looked like the only work in progress.
func TestCoalescedAlertRunRemovesItsAcknowledgement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, _, err := st.Behavior.UpsertStandingRule(ctx, core.StandingRule{
		ChannelID: "CWATCH", Repository: "repo",
		Trigger: "operational_alert", Action: "triage_alert",
		SourceKind: "app", Enabled: true, SourceRef: "test", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}, cfg.Limits.MaxStandingRules, cfg.Limits.MaxRulesPerChannel); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CWATCH", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "UOPERATOR",
	}); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}

	base := core.SlackInput{
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 FIRING:1] WARNING | High disk I/O latency\n" +
			"FIRING - 1 alert\nService: cluster\nComponent: cassandra",
	}
	first := base
	first.ID, first.EnvelopeID = "ack-storm-1", "env-ack-storm-1"
	first.EventID, first.MessageTS = "event-ack-storm-1", "1700.001"
	second := base
	second.ID, second.EnvelopeID = "ack-storm-2", "env-ack-storm-2"
	second.EventID, second.MessageTS = "event-ack-storm-2", "1700.002"
	second.Text = strings.Replace(second.Text, "FIRING:1", "FIRING:2", 1)
	for _, input := range []core.SlackInput{first, second} {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}
	drainSlackDeliveries(t, ctx, svc)
	marked := func(entries []slackReaction, name string, timestamp string) bool {
		for _, entry := range entries {
			if entry.name == name && entry.timestamp == timestamp {
				return true
			}
		}
		return false
	}
	if !marked(slackClient.reactions, "eyes", first.MessageTS) ||
		!marked(slackClient.reactions, "eyes", second.MessageTS) {
		t.Fatalf("standing rule acknowledgements = %+v", slackClient.reactions)
	}

	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	oldRun, err := st.GetAgentRunBySource(ctx, "watch", first.ID)
	if err != nil || oldRun.State != core.AgentRunSuperseded {
		t.Fatalf("older correlated run = %+v, %v", oldRun, err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if !marked(slackClient.removedReactions, "eyes", first.MessageTS) {
		t.Fatalf(
			"the coalesced card still tells the channel somebody is looking at it: %+v",
			slackClient.removedReactions,
		)
	}
	if marked(slackClient.removedReactions, "eyes", second.MessageTS) {
		t.Fatalf(
			"the run that will answer lost its acknowledgement: %+v",
			slackClient.removedReactions,
		)
	}
	cleared, found := "", false
	for _, status := range slackClient.statuses {
		if status.thread == first.MessageTS {
			cleared, found = status.text, true
		}
	}
	if !found || cleared != "" {
		t.Fatalf(
			"the coalesced card's thread status = %q (set=%t): %+v",
			cleared, found, slackClient.statuses,
		)
	}
}

func TestNewOperationalInputAdmittedDuringFinalizationSuppressesOldResult(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	base := core.SlackInput{
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 FIRING:1] WARNING | High disk I/O latency\nService: cluster\nComponent: cassandra",
	}
	older := base
	older.ID, older.EventID, older.MessageTS = "finalizing-alert", "event-finalizing-alert", "1700.100"
	newer := base
	newer.EnvelopeID = "env-terminal-alert"
	newer.ID, newer.EventID, newer.MessageTS, newer.ReceivedAt = "terminal-alert", "event-terminal-alert", "1900.200", base.ReceivedAt.Add(4*time.Minute)
	newer.Text = "[VA1 RESOLVED:1] WARNING | High disk I/O latency\nService: cluster\nComponent: cassandra"
	if created, err := st.AdmitSlackInput(ctx, older); err != nil || !created {
		t.Fatalf("admit older = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: older.ChannelID,
		ConversationKey: watchConversationKey(older), SourceKind: "watch", SourceID: older.ID,
		UserID: older.UserID, State: core.AgentRunRunning, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, run.ID, "completed", []byte(`{"action":"ignore"}`), "", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	for index := 0; index < 101; index++ {
		unrelated := base
		unrelated.ID = fmt.Sprintf("unrelated-bot-%03d", index)
		unrelated.EnvelopeID = fmt.Sprintf("env-unrelated-bot-%03d", index)
		unrelated.EventID = fmt.Sprintf("event-unrelated-bot-%03d", index)
		unrelated.MessageTS = fmt.Sprintf("1800.%03d", index)
		unrelated.ReceivedAt = base.ReceivedAt.Add(2*time.Minute + time.Duration(index)*time.Millisecond)
		unrelated.Text = fmt.Sprintf("unrelated application notification %d", index)
		if created, err := st.AdmitSlackInput(ctx, unrelated); err != nil || !created {
			t.Fatalf("admit unrelated update %d = %t, %v", index, created, err)
		}
	}
	if created, err := st.AdmitSlackInput(ctx, newer); err != nil || !created {
		t.Fatalf("admit terminal update = %t, %v", created, err)
	}
	staged, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if newerFound, err := svc.hasNewerOperationalInput(ctx, staged, older); err != nil || !newerFound {
		t.Fatalf("newer operational input = %t, %v", newerFound, err)
	}
	if err := svc.finalizeTriageAgentRun(ctx, staged); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunSuperseded {
		t.Fatalf("older operational result = %+v, %v", stored, err)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("older operational result reached Slack: %v", err)
	}
}

func TestNewOperationalInputSupersedesAlreadyStagedOlderDelivery(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	older := core.SlackInput{
		ID: "staged-alert", EnvelopeID: "env-staged-alert", EventID: "event-staged-alert",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.100", UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 FIRING:1] WARNING | High disk I/O latency\nService: cluster\nComponent: cassandra",
	}
	newer := older
	newer.ID, newer.EnvelopeID, newer.EventID = "staged-alert-resolved", "env-staged-alert-resolved", "event-staged-alert-resolved"
	newer.MessageTS, newer.ReceivedAt = "1700.200", older.ReceivedAt.Add(time.Second)
	newer.Text = "[VA1 RESOLVED:1] WARNING | High disk I/O latency\nService: cluster\nComponent: cassandra"
	if created, err := st.AdmitSlackInput(ctx, older); err != nil || !created {
		t.Fatalf("admit older = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: older.ChannelID,
		ConversationKey: watchConversationKey(older), SourceKind: "watch", SourceID: older.ID,
		UserID: older.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	body, err := slackui.Encode(slackui.ConversationResponse("The alert is still firing.", slackui.NewSanitizer(12000)))
	if err != nil {
		t.Fatal(err)
	}
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + older.ID, Operation: "post", Kind: "notice",
		ChannelID: older.ChannelID, ThreadTS: older.MessageTS, Body: body,
		ResponseRoot: true, SourceInputID: older.ID, AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey,
	}); err != nil || !created {
		t.Fatalf("stage older delivery = %t, %v", created, err)
	}
	if created, err := st.AdmitSlackInput(ctx, newer); err != nil || !created {
		t.Fatalf("admit terminal update = %t, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.GetSlackDelivery(ctx, "watch_reply_"+older.ID)
	if err != nil || delivery.State != "superseded" || len(slack.posts) != 0 {
		t.Fatalf("staged operational delivery = %+v, posts=%+v, err=%v", delivery, slack.posts, err)
	}
}

func TestOperationalRecoveryKeepsTheOriginalAlertThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}

	firing := core.SlackInput{
		ID: "alert-firing", EnvelopeID: "env-alert-firing", EventID: "event-alert-firing",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.401", UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 FIRING:1] WARNING | High disk I/O latency\n" +
			"FIRING - 1 alert\nService: cluster\nComponent: node-exporter",
	}
	resolved := firing
	resolved.ID, resolved.EnvelopeID, resolved.EventID =
		"alert-resolved", "env-alert-resolved", "event-alert-resolved"
	resolved.MessageTS = "1700.402"
	resolved.ReceivedAt = firing.ReceivedAt.Add(5 * time.Minute)
	resolved.Text = "[VA1 RESOLVED:1] WARNING | High disk I/O latency\n" +
		"RESOLVED - 1 alert\nService: cluster\nComponent: node-exporter"

	for _, input := range []core.SlackInput{firing, resolved} {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}

	firingRun, err := st.GetAgentRunBySource(ctx, "watch", firing.ID)
	if err != nil {
		t.Fatal(err)
	}
	if firingRun.ThreadTS != firing.MessageTS {
		t.Fatalf("firing thread = %q, want %q", firingRun.ThreadTS, firing.MessageTS)
	}
	episode, err := st.GetWorkEpisode(ctx, firingRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.Destination.ThreadTS != firing.MessageTS {
		t.Fatalf("initial episode destination = %q, want %q", episode.Destination.ThreadTS, firing.MessageTS)
	}

	resolvedRun, err := st.GetAgentRunBySource(ctx, "watch", resolved.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(resolvedRun)
	if err != nil {
		t.Fatal(err)
	}
	if resolvedRun.EpisodeID != firingRun.EpisodeID {
		t.Fatalf("recovery episode = %q, want %q", resolvedRun.EpisodeID, firingRun.EpisodeID)
	}
	if got := watchDecisionResponseThread(
		resolvedRun.ConversationKey, resolved, state, resolvedRun.EpisodeID,
	); got != firing.MessageTS {
		t.Fatalf("recovery response thread = %q, want original alert %q", got, firing.MessageTS)
	}
}

func TestDifferentAlertFamiliesInOneBurstUseOnlyNewestModelRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}

	now := time.Now().UTC()
	inputs := []core.SlackInput{
		{
			ID: "burst-oom", EnvelopeID: "env-burst-oom", EventID: "event-burst-oom",
			Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700.201", UserID: "BGRAFANA", ReceivedAt: now,
			Text: "[VA1 FIRING:1] CRITICAL | Container OOM\nService: api\nComponent: nomad-agent",
		},
		{
			ID: "burst-scrape", EnvelopeID: "env-burst-scrape", EventID: "event-burst-scrape",
			Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700.202", UserID: "BGRAFANA", ReceivedAt: now.Add(10 * time.Second),
			Text: "[VA1 FIRING:1] CRITICAL | Scrape target down\nService: api\nComponent: prometheus",
		},
	}
	for _, input := range inputs {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	first, err := st.GetAgentRunBySource(ctx, "watch", inputs[0].ID)
	if err != nil || first.State != core.AgentRunSuperseded {
		t.Fatalf("older burst run = %+v, %v", first, err)
	}
	if len(coopClient.submitPrompts) != 0 {
		t.Fatalf("older burst reached Coop: %d prompts", len(coopClient.submitPrompts))
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("newest burst prompts = %d, want 1", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	for _, required := range []string{
		"<operational-burst>", "Container OOM", "Scrape target down",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("coalesced prompt omitted %q:\n%s", required, prompt)
		}
	}
}

func TestDifferentExternalLifecycleRunsDoNotCoalesce(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}

	now := time.Now().UTC()
	inputs := []core.SlackInput{
		{
			ID: "terraform-applied", EnvelopeID: "env-terraform-applied",
			EventID: "event-terraform-applied", Kind: "bot_message",
			TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", MessageTS: "1700.301",
			UserID: "BTERRAFORM", ReceivedAt: now,
			Text: "Run notification for acme/infra\nRun run-first\nRun Applied",
		},
		{
			ID: "terraform-errored", EnvelopeID: "env-terraform-errored",
			EventID: "event-terraform-errored", Kind: "bot_message",
			TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", MessageTS: "1700.302",
			UserID: "BTERRAFORM", ReceivedAt: now.Add(time.Second),
			Text: "Run notification for acme/infra\nRun run-second\nRun Errored",
		},
	}
	for _, input := range inputs {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	first, err := st.GetAgentRunBySource(ctx, "watch", inputs[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if first.State == core.AgentRunSuperseded {
		t.Fatalf("exact lifecycle run was coalesced by another run: %+v", first)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("first exact lifecycle run prompts = %d, want 1", len(coopClient.submitPrompts))
	}
}

func TestRelatedAlertFamiliesShareRecentOperationalAncestry(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}

	inputs := []core.SlackInput{
		{
			ID: "related-oom", EnvelopeID: "env-related-oom", EventID: "event-related-oom",
			Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700.101", UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
			Text: "[VA1 FIRING:1] CRITICAL | Container OOM\nService: api\nComponent: nomad-agent",
		},
		{
			ID: "related-scrape", EnvelopeID: "env-related-scrape", EventID: "event-related-scrape",
			Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700.102", UserID: "BGRAFANA", ReceivedAt: time.Now().UTC().Add(time.Minute),
			Text: "[VA1 FIRING:2] CRITICAL | Scrape target down\nService: api\nComponent: prometheus",
		},
	}
	for _, input := range inputs {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}
	first, err := st.GetAgentRunBySource(ctx, "watch", inputs[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	second, err := st.GetAgentRunBySource(ctx, "watch", inputs[1].ID)
	if err != nil {
		t.Fatal(err)
	}
	if first.ConversationKey == second.ConversationKey {
		t.Fatal("different alert families were incorrectly deduplicated")
	}
	secondEpisode, err := st.GetWorkEpisode(ctx, second.EpisodeID)
	if err != nil || secondEpisode.ParentEpisodeID != first.EpisodeID {
		t.Fatalf("related operational ancestry = %+v, %v", secondEpisode, err)
	}
}

func TestObviousHumanDialogueIsSuppressedBeforeCoop(t *testing.T) {
	svc := &Service{identity: slackui.Identity{BotUserID: "UBOT"}}
	input := core.SlackInput{Kind: "message", Text: "<@UALICE> can you check the failed build?"}
	if !svc.obviousHumanDialogue(input, decisionpkg.WatchTurnState{}) {
		t.Fatal("obvious human addressee was not suppressed")
	}
	input.Text = "<@UBOT> can you check the failed build?"
	if svc.obviousHumanDialogue(input, decisionpkg.WatchTurnState{}) {
		t.Fatal("direct bot mention was suppressed")
	}
}
