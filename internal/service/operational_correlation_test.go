package service

import (
	"context"
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
	if got, want := operationalCorrelationKey(resolved), operationalCorrelationKey(firing); got != want {
		t.Fatalf("resolved correlation = %q, want %q", got, want)
	}
	other := firing
	other.Text = strings.ReplaceAll(other.Text, "cassandra", "typesense")
	if operationalCorrelationKey(other) == operationalCorrelationKey(firing) {
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
	if got, want := operationalCorrelationKey(second), operationalCorrelationKey(first); got != want {
		t.Fatalf("repeated alert correlation = %q, want %q", got, want)
	}
	if got := operationalCorrelationKey(first); !strings.Contains(got, "/alerting/grafana/alert-123/view") {
		t.Fatalf("alert correlation did not retain stable alert identity: %q", got)
	}
	other := first
	other.Text = strings.ReplaceAll(other.Text, "alert-123", "alert-456")
	if operationalCorrelationKey(other) == operationalCorrelationKey(first) {
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
		resolved, state, decisionpkg.WatchDecision{Action: "ignore"}, time.Now().UTC(), operationalCorrelationKey,
	)
	if !strings.Contains(correction, "investigation was already admitted") {
		t.Fatalf("resolved alert correction = %q", correction)
	}

	unrelated := resolved
	unrelated.Text = strings.ReplaceAll(unrelated.Text, "cassandra", "typesense")
	if correction := decisionpkg.WatchDecisionCorrectionAt(
		unrelated, state, decisionpkg.WatchDecision{Action: "ignore"}, time.Now().UTC(), operationalCorrelationKey,
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
	if got, want := operationalCorrelationKey(errored), operationalCorrelationKey(planned); got != want {
		t.Fatalf("Terraform lifecycle correlation = %q, want %q", got, want)
	}
	other := planned
	other.Text = strings.ReplaceAll(other.Text, "run-6d2hQfNJrTeyAP4T", "run-R1FRs9QFdGmTbBUx")
	if operationalCorrelationKey(other) == operationalCorrelationKey(planned) {
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
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
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
