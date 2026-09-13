package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	episodepkg "github.com/AndrewDryga/ryker/internal/episode"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
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

// The Host OOM model session contained earlier website OOM turns when a new
// VictoriaLogs OOM arrived. Bounded worker concurrency does not require shared
// model context: each operational stream owns a session, while the scheduler
// still limits how many turns can run at once.
func TestUnrelatedOperationalStreamsNeverShareModelContext(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.BackgroundWorkers = 3
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	firing := core.SlackInput{
		Kind: "bot_message", ChannelID: "CWATCH", UserID: "BGRAFANA",
		Text: "[VA1 FIRING:1] WARNING | shared lifecycle\nService: api",
	}
	resolved := firing
	resolved.Text = "[VA1 RESOLVED:1] WARNING | shared lifecycle\nService: api"
	firingShard := operationalWatchSessionChannelID(
		firing, watchConversationKey(firing), cfg.Limits.BackgroundWorkers,
	)
	resolvedShard := operationalWatchSessionChannelID(
		resolved, watchConversationKey(resolved), cfg.Limits.BackgroundWorkers,
	)
	if firingShard == "" || resolvedShard != firingShard {
		t.Fatalf("one alert lifecycle changed session shard: firing=%q resolved=%q", firingShard, resolvedShard)
	}

	sessions := map[string]bool{}
	for index := 0; index < 30; index++ {
		input := core.SlackInput{
			ID:         fmt.Sprintf("pooled-alert-%02d", index),
			EnvelopeID: fmt.Sprintf("env-pooled-alert-%02d", index),
			EventID:    fmt.Sprintf("event-pooled-alert-%02d", index),
			Kind:       "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: fmt.Sprintf("1700.%03d", index), UserID: "BGRAFANA",
			ReceivedAt: time.Now().UTC().Add(time.Duration(index) * time.Second),
			Text:       fmt.Sprintf("[VA1 FIRING:1] WARNING | component-%02d unavailable\nService: component-%02d", index, index),
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit alert %d = %t, %v", index, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue alert %d: %v", index, err)
		}
		run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
		if err != nil {
			t.Fatal(err)
		}
		state, err := decodeWatchRunContext(run)
		if err != nil {
			t.Fatal(err)
		}
		sessions[state.SessionChannelID] = true
	}
	if len(sessions) != 30 {
		t.Fatalf("operational sessions = %v, want one per stream", sessions)
	}
}

// Runs accepted before session sharding already have an empty
// session_channel_id in their frozen context. The production backlog must move
// onto the pool after deployment instead of remaining pinned to the busy
// legacy channel session.
func TestQueuedOperationalRunAdoptsTheWatchSessionPoolBeforeSubmission(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.BackgroundWorkers = 3
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "legacy-pooled-alert", EnvelopeID: "env-legacy-pooled-alert",
		EventID: "event-legacy-pooled-alert", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", MessageTS: "1700.100",
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 FIRING:1] WARNING | legacy queued alert\nService: api",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetAgentRunContext(ctx, run.ID, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	run, err = st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(state.SessionChannelID, "watch-shard:CWATCH:") {
		t.Fatalf("legacy queued run session channel = %q", state.SessionChannelID)
	}
	if len(coopClient.createKeys) != 1 ||
		!strings.HasPrefix(coopClient.createKeys[0], "ryker:watch-session:watch-shard:CWATCH:") {
		t.Fatalf("legacy queued run create keys = %v", coopClient.createKeys)
	}
}

// Covers: TestBetterStackRefireSupersedesEarlierResolutionResult
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
Run notification for SME-Blitz/blitz-infra
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

// A wait is durable as soon as result operations are recorded. The superseded
// check therefore has to run during staging, before recordResultOperationEvents,
// not only when Slack delivery is finalized.
// Covers finding: 20260811T001118Z-run_63d34b6821f777c7555d54c19eff016c
func TestSupersededTerraformTurnCannotLeaveAStaleWakeup(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CTERRAFORM"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, _, err := st.Behavior.UpsertStandingRule(ctx, core.StandingRule{
		ChannelID: "CTERRAFORM", Repository: "repo", Trigger: "terraform_lifecycle",
		Action: "monitor_terraform_lifecycle", SourceKind: "app", Enabled: true,
		SourceRef: "test", ActorID: cfg.Slack.Operators[0],
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}, cfg.Limits.MaxStandingRules, cfg.Limits.MaxRulesPerChannel); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CTERRAFORM", Participation: "proactive", Repository: "repo",
		AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}

	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}
	now := time.Now().UTC()
	older := core.SlackInput{
		ID: "terraform-planning", EnvelopeID: "env-terraform-planning",
		EventID: "event-terraform-planning", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CTERRAFORM", MessageTS: "1700.100", UserID: "BTERRAFORM",
		ReceivedAt: now,
		Text: "Run notification for acme/infra\nRun run-abc\n" +
			"<https://app.terraform.io/app/acme/infra/runs/run-abc|Open run>\nRun Planning",
	}
	if created, err := st.AdmitSlackInput(ctx, older); err != nil || !created {
		t.Fatalf("admit planning card = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", older.ID)
	if err != nil || run.State != core.AgentRunRunning {
		t.Fatalf("planning run = %+v, %v", run, err)
	}

	newer := older
	newer.ID, newer.EnvelopeID, newer.EventID = "terraform-applied", "env-terraform-applied", "event-terraform-applied"
	newer.MessageTS, newer.ReceivedAt = "1700.200", now.Add(time.Minute)
	newer.Text = strings.Replace(older.Text, "Run Planning", "Run Applied", 1)
	if created, err := st.AdmitSlackInput(ctx, newer); err != nil || !created {
		t.Fatalf("admit applied card = %t, %v", created, err)
	}

	pollAfter := now.Add(10 * time.Minute).Format(time.RFC3339)
	deadline := now.Add(time.Hour).Format(time.RFC3339)
	coopClient.complete(fmt.Sprintf(`{"action":"ignore","reason":"the exact run is still planning","operations":[{"id":"wait-run","type":"wait_external","external_wait":{"id":"wakeup-run","kind":"terraform_run","verification":"Read the exact run until it is terminal.","event_matcher":{"provider":"hcp_terraform","run_id":"run-abc"},"poll_after":%q,"deadline":%q}},{"id":"complete","type":"complete_episode","completion":{"message":"Still planning.","completion":{"status":"decision_ready","verdict":"in_progress","summary":"The exact run is still planning."}}}]}`, pollAfter, deadline))
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	run, err = st.GetAgentRun(ctx, run.ID)
	if err != nil || run.State != core.AgentRunSuperseded {
		t.Fatalf("older Terraform turn = %+v, %v", run, err)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, run.EpisodeID)
	if err != nil || len(wakeups) != 0 {
		t.Fatalf("superseded Terraform turn left wakeups = %+v, %v", wakeups, err)
	}
}

// An answer that is written and queued is delivered. A newer card on the same
// stream is not evidence that the answer is stale — on 2026-08-16 that reading
// threw away four of them, one of which an investigation had spent fifteen
// minutes producing.
//
// Staleness has an observable criterion: a NEWER reply already went out in this
// thread. Nothing else supersedes a written answer.
// Covers finding: 20260810T204844Z-run_d7a57ffc976c9cccd0abd99562b685e5
// Covers: TestCompletedMaterialResultSurvivesANewerAttemptThatPublishesNothing
func TestStagedAlertReplyIsDeliveredDespiteANewerCard(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	older, newer := stagedAlertStreamInputs(cfg.Slack.TeamID)
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
	if err := stageAlertStreamReply(ctx, st, older, run, "The alert is still firing."); err != nil {
		t.Fatal(err)
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
	if err != nil || delivery.State != "sent" || len(slack.posts) != 1 {
		t.Fatalf(
			"a written alert answer was discarded for a newer card: delivery=%+v posts=%+v err=%v",
			delivery, slack.posts, err,
		)
	}
}

// The other half of the same invariant: once a newer reply for this stream has
// actually been posted in the thread, the older one is genuinely stale and must
// not arrive under it as a contradicting second answer.
func TestStagedAlertReplyIsSupersededOnlyByANewerSentReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	older, newer := stagedAlertStreamInputs(cfg.Slack.TeamID)
	for _, input := range []core.SlackInput{older, newer} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: older.ChannelID,
		ConversationKey: watchConversationKey(older), SourceKind: "watch", SourceID: older.ID,
		UserID: older.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := stageAlertStreamReply(ctx, st, older, run, "The alert is still firing."); err != nil {
		t.Fatal(err)
	}
	newerRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: newer.ChannelID,
		ConversationKey: watchConversationKey(newer), SourceKind: "watch", SourceID: newer.ID,
		UserID: newer.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := stageAlertStreamReply(ctx, st, newer, newerRun, "The alert recovered."); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, "watch_reply_"+newer.ID, "1700.900", "pending"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.GetSlackDelivery(ctx, "watch_reply_"+older.ID)
	if err != nil || delivery.State != "superseded" || len(slack.posts) != 0 {
		t.Fatalf(
			"an alert answer overtaken by a sent reply was still posted: delivery=%+v posts=%+v err=%v",
			delivery, slack.posts, err,
		)
	}
}

func stagedAlertStreamInputs(teamID string) (core.SlackInput, core.SlackInput) {
	older := core.SlackInput{
		ID: "staged-alert", EnvelopeID: "env-staged-alert", EventID: "event-staged-alert",
		Kind: "bot_message", TeamID: teamID, ChannelID: "CWATCH",
		MessageTS: "1700.100", UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 FIRING:1] WARNING | High disk I/O latency\nService: cluster\nComponent: cassandra",
	}
	newer := older
	newer.ID, newer.EnvelopeID, newer.EventID =
		"staged-alert-resolved", "env-staged-alert-resolved", "event-staged-alert-resolved"
	newer.MessageTS, newer.ReceivedAt = "1700.200", older.ReceivedAt.Add(time.Second)
	newer.Text = "[VA1 RESOLVED:1] WARNING | High disk I/O latency\nService: cluster\nComponent: cassandra"
	return older, newer
}

// stageAlertStreamReply writes the reply an investigation produced into the
// outbox, in the same shape finalization does: a response-root post threaded
// under the first card of the stream.
func stageAlertStreamReply(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
	run core.AgentRun,
	text string,
) error {
	body, err := slackui.Encode(
		slackui.ConversationResponse(text, slackui.NewSanitizer(12000)),
	)
	if err != nil {
		return err
	}
	created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + input.ID, Operation: "post", Kind: "notice",
		ChannelID: input.ChannelID, ThreadTS: "1700.100", Body: body,
		ResponseRoot: true, SourceInputID: input.ID,
		AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey,
	})
	if err != nil {
		return err
	}
	if !created {
		return errors.New("staged alert reply was not enqueued")
	}
	return nil
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

// Two Vector recoveries on 2026-08-23 reused the active alert episode but
// supplied the newer RESOLVED card as the response thread. The delivery layer
// accepted that route and moved the durable destination, so later rechecks
// followed the recovery card instead of the FIRING investigation. A bound
// episode is the authority: a later model context cannot relocate it.
func TestABoundAlertEpisodeCannotMoveToTheResolvedCard(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	const firingThread = "1787527443.511159"
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CWATCH", ThreadTS: firingThread,
		ConversationKey: "operation:grafana:vector-errors", SourceKind: "watch",
		SourceID: "vector-firing", UserID: "BGRAFANA", Repository: "repo",
	})
	if err != nil || !created {
		t.Fatalf("queue firing episode = %+v, %t, %v", run, created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.postInputMessageAtEpisodeResponse(
		ctx, "vector-resolved-reply", run.EpisodeID, "vector-resolved",
		"CWATCH", "1787528043.399299",
		slackui.ConversationResponse("Vector recovered.", slackui.NewSanitizer(12000)), true,
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != firingThread {
		t.Fatalf("resolved answer moved away from the firing thread: %+v", slack.posts)
	}
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil || episode.Destination.ThreadTS != firingThread {
		t.Fatalf("resolved card replaced the durable destination: %+v, %v", episode.Destination, err)
	}
	events, err := st.ListEpisodeEvents(ctx, run.EpisodeID, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range events {
		if event.Kind == episodepkg.EventDestinationChanged {
			t.Fatalf("automatic recovery emitted a destination change: %+v", event)
		}
	}
}

// Better Stack's Tolgee recovery on 2026-08-18 reused the firing episode but
// moved the final Slack answer under the RESOLVED card. Grafana keys already
// took the original-thread path; lifecycle-link keys must make the same
// promise all the way through the durable Slack delivery.
func TestBetterStackRecoveryIsDeliveredInTheOriginalIncidentThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	opened := core.SlackInput{
		ID: "better-stack-opened", EnvelopeID: "env-better-stack-opened",
		EventID: "event-better-stack-opened", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", MessageTS: "1700.501",
		UserID: "BBETTERSTACK", ReceivedAt: time.Now().UTC(),
		Text: "New incident for Tolgee: health check\n" +
			"<https://uptime.betterstack.com/team/t22201/incidents/1003304830|View incident>",
	}
	resolved := opened
	resolved.ID, resolved.EnvelopeID, resolved.EventID =
		"better-stack-resolved", "env-better-stack-resolved", "event-better-stack-resolved"
	resolved.MessageTS = "1700.502"
	resolved.ReceivedAt = opened.ReceivedAt.Add(5 * time.Minute)
	resolved.Text = "Automatically resolved Tolgee: health check incident\n" +
		"<https://uptime.betterstack.com/team/t22201/incidents/1003304830|View incident>"

	for _, input := range []core.SlackInput{opened, resolved} {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}
	openedRun, err := st.GetAgentRunBySource(ctx, "watch", opened.ID)
	if err != nil {
		t.Fatal(err)
	}
	resolvedRun, err := st.GetAgentRunBySource(ctx, "watch", resolved.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(resolvedRun)
	if err != nil {
		t.Fatal(err)
	}
	responseThread := watchDecisionResponseThread(
		resolvedRun.ConversationKey, resolved, state, resolvedRun.EpisodeID,
	)
	if err := svc.postInputMessageAtEpisodeResponse(
		ctx, "better-stack-recovery-reply", resolvedRun.EpisodeID, resolved.ID,
		resolved.ChannelID, responseThread, slackui.ConversationResponse(
			"The exact Tolgee alert condition recovered.", slackui.NewSanitizer(12000),
		), true,
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != opened.MessageTS {
		t.Fatalf("recovery Slack destination = %+v, want thread %s", slack.posts, opened.MessageTS)
	}
	episode, err := st.GetWorkEpisode(ctx, openedRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if resolvedRun.EpisodeID != openedRun.EpisodeID ||
		episode.Destination.ThreadTS != opened.MessageTS {
		t.Fatalf("recovery moved episode destination: run=%q episode=%q",
			resolvedRun.EpisodeID, episode.Destination.ThreadTS)
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

// confirmedAlertReplyResult is a harvested decision_ready alert reply: a
// confirmed_issue assessment, a typed finding, evidence bound to every required
// claim, and exactly one complete_episode. It passes the whole watch validation
// pipeline unaltered, which is expensive to reproduce and cheap to share, so
// TestAnsweredAlertCardShowsCheckMark and the alert-stream tests below all use
// this one string.
func confirmedAlertReplyResult(observedAt string) string {
	return fmt.Sprintf(`{"action":"reply","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},"reason":"fresh repository and live evidence confirm the alert","operations":[{"id":"checkout-topology","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"checkout topology has two backends","observation":"the production manifest declares two checkout backends behind the load balancer","source_type":"repository","source_name":"infra/checkout.tf","dimensions":{"repository":"repo","environment":"production","revision":"current"}}},{"id":"checkout-live","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"checkout requests complete successfully","observation":"the live checkout error rate is 20.5 percent and one backend is unhealthy","relation":"contradicts","health_effect":"unhealthy","source_type":"emisar","source_name":"Emisar checkout health","target":"checkout","observed_at":%q,"dimensions":{"service":"checkout","endpoint":"requests","environment":"production","window":"current"}}},{"id":"checkout-impact","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"checkout user impact is within its error budget","observation":"the current error rate is 20.5 percent","relation":"contradicts","health_effect":"degraded","source_type":"emisar","source_name":"Emisar checkout health","target":"checkout","observed_at":%q,"dimensions":{"service":"checkout","indicator":"error_rate","environment":"production","window":"current"}}},{"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","source":"infra/checkout.tf","detail":"the declared two-backend topology was reconciled"}},{"id":"cov-2","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"unhealthy","source":"Emisar checkout health","detail":"current requests are failing"}},{"id":"cov-3","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"degraded","source":"Emisar checkout health","detail":"error rate exceeds the alert threshold"}},{"id":"finding-1","type":"record_finding","finding":{"key":"checkout-error-rate","what":"Checkout requests fail for more than 20 percent of users","scope":"checkout, production","status":"explained","cause_evidence":["checkout-live"],"alternatives":[{"hypothesis":"A client-side release is producing the errors","claim_id":"application.functional_behavior","discriminated_by":"checkout-live"}]}},{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue","impact":"More than 20 percent of current checkout requests fail.","cause_status":"identified","cause":"One load balancer backend is unhealthy after the current deployment.","cause_claim_ids":["application.functional_behavior"],"evidence_refs":["checkout-live"],"immediate_action_kind":"mitigation","immediate_action":"Remove the unhealthy backend from service.","verification":"Confirm checkout errors return below the alert threshold after the backend is removed.","long_term_solution":"Correct the deployment regression and add a checkout-error rollout guard.","scope":{"status":"bounded","checked_targets":["checkout"],"unverified_targets":["routes outside checkout"],"evidence_refs":["checkout-live"]}}},{"id":"mem","type":"update_memory","memory":{"situation_summary":"A critical checkout error-rate alert was confirmed from repository and live evidence.","decisions":["Continue the alert investigation in its source thread."]}},{"id":"complete","type":"complete_episode","completion":{"message":"This arbitrary model prose must not become the Slack scope claim.","completion":{"status":"decision_ready","verdict":"unhealthy","summary":"The checkout alert is a confirmed current issue with a bounded immediate remediation."}}}]}`, observedAt, observedAt)
}

// alertStreamChannel prepares a watch channel that answers operational alerts
// on the channel's behalf: a standing triage rule so the card is acknowledged,
// and a reply alert policy so the answer is posted rather than offered.
func alertStreamChannel(t *testing.T, ctx context.Context, st *store.Store, cfg config.Config, channelID string) {
	t.Helper()
	if _, _, err := st.Behavior.UpsertStandingRule(ctx, core.StandingRule{
		ChannelID: channelID, Repository: "repo",
		Trigger: "operational_alert", Action: "triage_alert",
		SourceKind: "app", Enabled: true, SourceRef: "test", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}, cfg.Limits.MaxStandingRules, cfg.Limits.MaxRulesPerChannel); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: channelID, Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "UOPERATOR",
	}); err != nil {
		t.Fatal(err)
	}
}

// Two investigations on 2026-08-16 (15 and 7 minutes, 50 tool calls, 5
// correction rounds) were dropped mid-flight for the next Grafana card and
// restarted from zero. Grafana posted seven cards for one Traefik memory alert
// in ninety minutes; each one superseded whatever was running, so a stream that
// was investigated for an hour never once finished an investigation.
//
// An unstarted run still coalesces, and must: nothing was produced, so nothing
// is lost. A run that has submitted its turn has produced work, and the newer
// card is one more update to that same investigation rather than a reason to
// throw it away. The guard already existed for human messages and was never
// applied to bot messages.
func TestAttemptedAlertRunSurvivesANewerNotificationOnTheSameStream(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CSTREAM"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	alertStreamChannel(t, ctx, st, cfg, "CSTREAM")
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	base := core.SlackInput{
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CSTREAM",
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "CRITICAL alert: checkout error rate is firing above 20 percent.",
	}
	first := base
	first.ID, first.EnvelopeID = "stream-card-1", "env-stream-card-1"
	first.EventID, first.MessageTS = "event-stream-card-1", "1703.100"
	second := base
	second.ID, second.EnvelopeID = "stream-card-2", "env-stream-card-2"
	second.EventID, second.MessageTS = "event-stream-card-2", "1703.200"
	second.ReceivedAt = base.ReceivedAt.Add(4 * time.Minute)
	second.Text = "[VA1 FIRING:2] " + base.Text

	if created, admitErr := st.AdmitSlackInput(ctx, first); admitErr != nil || !created {
		t.Fatalf("admit first card = %v, %v", created, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	firstRun, err := st.GetAgentRunBySource(ctx, "watch", first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 1 || firstRun.StartedAt.IsZero() {
		t.Fatalf(
			"the first card's investigation did not start: prompts=%d run=%+v",
			len(coopClient.submitPrompts), firstRun,
		)
	}

	if created, admitErr := st.AdmitSlackInput(ctx, second); admitErr != nil || !created {
		t.Fatalf("admit second card = %v, %v", created, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	// A correction round or a transport retry puts a started run back into
	// pending, and its next lease asks this question again. It must answer the
	// same way it did the first time.
	state, err := decodeWatchRunContext(firstRun)
	if err != nil {
		t.Fatal(err)
	}
	if decided, admitErr := svc.admitTriageRun(ctx, firstRun, first, &state); admitErr != nil || decided {
		t.Fatalf(
			"a started investigation was coalesced into the newer card: decided=%t, %v",
			decided, admitErr,
		)
	}

	coopClient.complete(confirmedAlertReplyResult(time.Now().UTC().Format(time.RFC3339)))
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	firstRun, err = st.GetAgentRun(ctx, firstRun.ID)
	if err != nil {
		t.Fatal(err)
	}
	if firstRun.State != core.AgentRunCompleted {
		t.Fatalf(
			"the finished investigation ended %q (%q) instead of completing",
			firstRun.State, firstRun.LastError,
		)
	}
	replied := false
	for _, post := range slackClient.posts {
		if strings.Contains(post.message.Text, "the live checkout error rate is 20.5 percent") {
			replied = true
		}
	}
	if !replied {
		t.Fatalf("the finished investigation never reached Slack: %+v", slackClient.posts)
	}

	secondRun, err := st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil {
		t.Fatal(err)
	}
	if secondRun.State != core.AgentRunPending {
		t.Fatalf("the newer card's run = %q, want it still waiting its turn", secondRun.State)
	}
	if secondRun.EpisodeID != firstRun.EpisodeID || secondRun.AttemptNumber != 2 {
		t.Fatalf(
			"the newer card opened separate work: episode=%q attempt=%d, want %q attempt 2",
			secondRun.EpisodeID, secondRun.AttemptNumber, firstRun.EpisodeID,
		)
	}
}

// Five episodes and $15 for one alert on 2026-08-16; the stream is one unit of
// work until it recovers.
//
// Grafana posted seven cards for one Traefik memory alert in ninety minutes.
// Every episode completed the moment its reply posted, so the next card found a
// terminal predecessor, opened a new episode, and paid for a fresh briefing to
// re-learn what the last one had just established. An alert that is still
// active is not finished work: the reply goes out, and the episode stays open
// on a bounded host wait until the stream recovers or the window expires.
func TestActiveAlertReplyKeepsTheStreamEpisodeOpen(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CSTREAMOPEN"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	alertStreamChannel(t, ctx, st, cfg, "CSTREAMOPEN")
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = confirmedAlertReplyResult(
		time.Now().UTC().Format(time.RFC3339),
	)
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	base := core.SlackInput{
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CSTREAMOPEN",
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "CRITICAL alert: checkout error rate is firing above 20 percent.",
	}
	first := base
	first.ID, first.EnvelopeID = "open-card-1", "env-open-card-1"
	first.EventID, first.MessageTS = "event-open-card-1", "1704.100"
	if created, err := st.AdmitSlackInput(ctx, first); err != nil || !created {
		t.Fatalf("admit first card = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	firstRun, err := st.GetAgentRunBySource(ctx, "watch", first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(firstRun.ConversationKey, "operation:") {
		t.Fatalf("the alert card is not on an operational stream: %q", firstRun.ConversationKey)
	}
	answered := false
	for _, post := range slackClient.posts {
		if strings.Contains(post.message.Text, "the live checkout error rate is 20.5 percent") {
			answered = true
		}
	}
	if !answered {
		t.Fatalf("the alert was never answered: run=%q %q posts=%+v",
			firstRun.State, firstRun.LastError, slackClient.posts)
	}
	episode, err := st.GetWorkEpisode(ctx, firstRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal {
		t.Fatalf(
			"an answered but still-firing alert closed its episode as %q",
			episode.State,
		)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, firstRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	streamWaits := 0
	for _, wakeup := range wakeups {
		if wakeup.Kind == alertStreamWaitKind {
			streamWaits++
		}
	}
	if streamWaits != 1 {
		t.Fatalf("alert stream wakeups = %d, want exactly one: %+v", streamWaits, wakeups)
	}
	// The card was answered. A host wait that keeps the ledger open is not the
	// model waiting on something, so it must not take the ✅ off the card.
	checked := false
	for _, added := range slackClient.reactions {
		if added.name == "white_check_mark" && added.timestamp == first.MessageTS {
			checked = true
		}
	}
	if !checked {
		t.Fatalf("the answered card lost its check mark: %+v", slackClient.reactions)
	}

	second := base
	second.ID, second.EnvelopeID = "open-card-2", "env-open-card-2"
	second.EventID, second.MessageTS = "event-open-card-2", "1704.200"
	second.ReceivedAt = base.ReceivedAt.Add(12 * time.Minute)
	second.Text = "[VA1 FIRING:2] " + base.Text
	if created, err := st.AdmitSlackInput(ctx, second); err != nil || !created {
		t.Fatalf("admit second card = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	secondRun, err := st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil {
		t.Fatal(err)
	}
	// Answering the next card keeps the stream open on the SAME wait. One timer
	// per stream, not one per card, or seven cards in ninety minutes become
	// seven re-checks six hours later.
	finishQueuedAgentRun(t, ctx, svc)
	wakeups, err = st.ListEpisodeWakeups(ctx, firstRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	streamWaits = 0
	for _, wakeup := range wakeups {
		if wakeup.Kind == alertStreamWaitKind {
			streamWaits++
		}
	}
	if streamWaits != 1 {
		t.Fatalf(
			"each card left its own stream re-check behind: %d waits, %+v",
			streamWaits, wakeups,
		)
	}
	if secondRun.EpisodeID != firstRun.EpisodeID || secondRun.AttemptNumber != 2 {
		t.Fatalf(
			"the next card on the stream opened new work: episode=%q attempt=%d, want %q attempt 2",
			secondRun.EpisodeID, secondRun.AttemptNumber, firstRun.EpisodeID,
		)
	}
}

// One live replay on 2026-08-18 correctly told operators that a FIRING alert
// was lifecycle-unverified, then completed the episode anyway. The matching
// RESOLVED card had to open a child episode instead of continuing the stream's
// evidence ledger. An unverified firing is still firing: its bounded answer is
// delivered, and the host keeps the stream open until lifecycle evidence
// arrives or the ordinary alert window expires.
// Covers: TestUnverifiedFiringAlertKeepsItsStreamOpen
func TestUnverifiedFiringAlertKeepsItsStreamOpen(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, slackClient, svc, base := streamFixture(
		t, "CUNVERIFIEDFIRING", harvestedUnverifiedFiringResult(t, observedAt),
	)
	card := base
	card.ID, card.EnvelopeID = "unverified-firing-card", "env-unverified-firing-card"
	card.EventID, card.MessageTS = "event-unverified-firing-card", "1704.300"
	card.Text = "[VA1 FIRING:1] WARNING | Ingress 5xx ratio high"

	run := answerStreamCard(t, svc, st, card)
	if len(slackClient.posts) != 1 {
		t.Fatalf("the bounded unverified answer was not delivered once: %d posts", len(slackClient.posts))
	}
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal {
		t.Fatalf(
			"a lifecycle-unverified FIRING card closed its stream as %q",
			episode.State,
		)
	}
	if waits := streamWaitCount(t, ctx, st, run.EpisodeID); waits != 1 {
		t.Fatalf("unverified firing stream wakeups = %d, want exactly one", waits)
	}
}

func TestUnverifiedResolvedCardDoesNotOpenANewStream(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, _, svc, base := streamFixture(
		t, "CUNVERIFIEDRESOLVED", harvestedUnverifiedFiringResult(t, observedAt),
	)
	card := base
	card.ID, card.EnvelopeID = "unverified-resolved-card", "env-unverified-resolved-card"
	card.EventID, card.MessageTS = "event-unverified-resolved-card", "1704.400"
	card.Text = "[VA1 RESOLVED:1] WARNING | Ingress 5xx ratio high"

	run := answerStreamCard(t, svc, st, card)
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeCompleted {
		t.Fatalf("a first-seen RESOLVED card opened a stream as %q", episode.State)
	}
	if waits := streamWaitCount(t, ctx, st, run.EpisodeID); waits != 0 {
		t.Fatalf("first-seen resolved stream wakeups = %d, want none", waits)
	}
}

// harvestedUnverifiedFiringResult is run_8b71dcdf7099068ee9c01c5ba09970bd,
// the exact result that exposed the lifecycle defect. Only observation times
// move so the production evidence remains fresh when this regression runs.
func harvestedUnverifiedFiringResult(t *testing.T, observedAt string) string {
	t.Helper()
	raw, err := os.ReadFile("testdata/unverified_firing_result.json")
	if err != nil {
		t.Fatal(err)
	}
	return strings.NewReplacer(
		"2026-08-18T20:38:03Z", observedAt,
		"2026-08-18T20:37:47Z", observedAt,
		"2026-08-18T20:37:53Z", observedAt,
		"2026-08-18T20:37:58Z", observedAt,
	).Replace(string(raw))
}

// The stream stays open only while the alert does. A recovery closes the
// episode on the spot, or a stream that fires once a week never finishes and
// every recheck timer it ever scheduled stays live.
func TestRecoveredAlertReplyCompletesTheStreamEpisode(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CSTREAMDONE"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	alertStreamChannel(t, ctx, st, cfg, "CSTREAMDONE")
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = recoveredAlertReplyResult(
		time.Now().UTC().Format(time.RFC3339),
	)
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	recovered := core.SlackInput{
		ID: "done-card-1", EnvelopeID: "env-done-card-1", EventID: "event-done-card-1",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CSTREAMDONE",
		MessageTS: "1705.100", UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "[VA1 RESOLVED:1] CRITICAL alert: checkout error rate is back under 20 percent.",
	}
	if created, err := st.AdmitSlackInput(ctx, recovered); err != nil || !created {
		t.Fatalf("admit recovery card = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	run, err := st.GetAgentRunBySource(ctx, "watch", recovered.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(run.ConversationKey, "operation:") {
		t.Fatalf("the recovery card is not on an operational stream: %q", run.ConversationKey)
	}
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeCompleted {
		t.Fatalf(
			"a recovered alert left its episode open as %q (run %q %q)",
			episode.State, run.State, run.LastError,
		)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	for _, wakeup := range wakeups {
		if wakeup.Kind == alertStreamWaitKind {
			t.Fatalf("a recovered alert still scheduled a stream re-check: %+v", wakeup)
		}
	}
}

// The first live Traefik reply after 2026-08-16's deploy planned and closed
// three goals in one turn and lost its stream wait; the next card opened a new
// episode.
//
// The host skipped its own wait whenever the turn "continued this episode", and
// that question counts any plan_goal in the result — including goals the same
// turn closed. run_0c2e0f1f2ea28371cac5ef8a1aa603c4 answered the 19:01Z
// va1-nomad-oom-risk card with three planned goals, three update_goal closures,
// a confirmed_issue verdict and a decision_ready completion. Nothing was left
// running, no wait was appended, the episode completed, and the 19:11Z card
// opened episode_run_72b49371 with a fresh briefing. Only a wait or a recheck
// actually outlives the turn, so only those may stand in for the host's own.
func TestAnActiveAlertReplyWithClosedGoalsStillKeepsTheStreamOpen(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "CGOALCLOSED")
	svc.coop.(*fakeCoop).completeQueue = []string{
		withPlannedAndClosedGoal(t, confirmedAlertReplyResult(observedAt)),
	}

	card := base
	card.ID, card.EnvelopeID = "goal-card-1", "env-goal-card-1"
	card.EventID, card.MessageTS = "event-goal-card-1", "1709.100"
	run := answerStreamCard(t, svc, st, card)
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 1 {
		t.Fatalf("the card was not answered exactly once: %d posts", len(posted))
	}
	// The reproduction depends on the goal operations actually being applied: a
	// fixture whose plan_goal never reached the ledger would pass this test
	// without ever posing the question it exists to ask.
	if states := streamColumn(t, cfg, `
		SELECT state FROM episode_goals WHERE episode_id = ? ORDER BY id`,
		run.EpisodeID,
	); len(states) != 1 || states[0] != string(core.GoalCompleted) {
		t.Fatalf("the reply's planned-and-closed goal is not on the ledger: %v", states)
	}
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal {
		t.Fatalf(
			"a reply that planned and closed a goal completed its still-firing stream as %q",
			episode.State,
		)
	}
	if waits := streamWaitCount(t, ctx, st, run.EpisodeID); waits != 1 {
		t.Fatalf("alert stream wakeups = %d, want exactly one", waits)
	}
}

// Attempt 2 of the live stream completed the episode at 19:29Z because the
// guard skipped the wait instead of reusing it.
//
// One wait per stream was enforced by returning before the wait operation was
// appended, so the second answered card on va1-nomad-oom-risk (the 19:24Z card,
// audited alert_update_changed) staged a decision with nothing pending in it.
// The phase that reads those operations saw a finished turn, completed the
// episode a second time, and the 20:09Z card opened a third one. The operation
// and the timer are different things: the operation says this turn is not the
// end of the episode and belongs on every answer, and only the wakeup row
// behind it has to be a single one.
//
// This test holds two doors shut. Appending the operation was not enough on
// its own: with the wait in the result the episode still completed, because the
// phase event that parks it was keyed on the transition alone and attempt 2's
// park was identical to attempt 1's, so it deduplicated into silence and
// FinishAgentRun closed an episode that was still in an execution state. Either
// defect alone loses the stream.
func TestASecondActiveReplyKeepsTheStreamOpen(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, slackClient, svc, base := streamFixture(t, "CSECONDREPLY")
	svc.coop.(*fakeCoop).completeQueue = []string{
		confirmedAlertReplyResult(observedAt),
		degradedConfirmedAlertReply(t, observedAt),
	}

	first := base
	first.ID, first.EnvelopeID = "second-card-1", "env-second-card-1"
	first.EventID, first.MessageTS = "event-second-card-1", "1710.100"
	firstRun := answerStreamCard(t, svc, st, first)
	episode, err := st.GetWorkEpisode(ctx, firstRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal {
		t.Fatalf("the first answered card closed its stream as %q", episode.State)
	}
	if waits := streamWaitCount(t, ctx, st, firstRun.EpisodeID); waits != 1 {
		t.Fatalf("alert stream wakeups after the first card = %d, want one", waits)
	}

	second := base
	second.ID, second.EnvelopeID = "second-card-2", "env-second-card-2"
	second.EventID, second.MessageTS = "event-second-card-2", "1710.200"
	second.ReceivedAt = base.ReceivedAt.Add(13 * time.Minute)
	second.Text = "[VA1 FIRING:2] " + base.Text
	secondRun := answerStreamCard(t, svc, st, second)
	if secondRun.EpisodeID != firstRun.EpisodeID || secondRun.AttemptNumber != 2 {
		t.Fatalf(
			"the second card did not continue the stream: episode=%q attempt=%d, want %q attempt 2",
			secondRun.EpisodeID, secondRun.AttemptNumber, firstRun.EpisodeID,
		)
	}
	// A changed decision, so this is the answered path the live stream took and
	// not a suppressed repeat that never reached the channel.
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 2 {
		t.Fatalf("the second card was not answered: %d posts", len(posted))
	}
	episode, err = st.GetWorkEpisode(ctx, firstRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal {
		t.Fatalf(
			"the second answer on a still-firing stream closed the episode as %q",
			episode.State,
		)
	}
	// And still one row: the wait belongs on every answer, the timer belongs to
	// the stream, or seven cards in ninety minutes become seven re-checks.
	if waits := streamWaitCount(t, ctx, st, firstRun.EpisodeID); waits != 1 {
		t.Fatalf("alert stream wakeups after the second card = %d, want one", waits)
	}
}

// streamWaitCount counts the host's stream re-check timers on an episode.
func streamWaitCount(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	episodeID string,
) int {
	t.Helper()
	wakeups, err := st.ListEpisodeWakeups(ctx, episodeID)
	if err != nil {
		t.Fatal(err)
	}
	waits := 0
	for _, wakeup := range wakeups {
		if wakeup.Kind == alertStreamWaitKind {
			waits++
		}
	}
	return waits
}

// rewriteFixture edits a harvested result by exact substring, failing when the
// substring is not there.
//
// A fixture that quietly stopped being rewritten is a test that quietly stopped
// testing: the "changed" cases below would compare a reply with itself and pass
// for the wrong reason. Every variant here differs from confirmedAlertReplyResult
// in exactly the fields it names and in nothing else, which is the whole point
// of comparing decisions rather than sentences.
func rewriteFixture(t *testing.T, body string, pairs ...string) string {
	t.Helper()
	for index := 0; index+1 < len(pairs); index += 2 {
		if !strings.Contains(body, pairs[index]) {
			t.Fatalf("the alert fixture no longer contains %q to rewrite", pairs[index])
		}
		body = strings.ReplaceAll(body, pairs[index], pairs[index+1])
	}
	return body
}

// rewordedConfirmedAlertReply says the same thing in different words: the same
// verdict, the same cause status, the same coverage on the same layers, the
// same explained finding, the same absence of an offer, and not one sentence in
// common. It is the 2026-08-16 flap in one fixture.
func rewordedConfirmedAlertReply(t *testing.T, observedAt string) string {
	t.Helper()
	return rewriteFixture(t, confirmedAlertReplyResult(observedAt),
		"fresh repository and live evidence confirm the alert",
		"the live signal still disagrees with the declared topology",
		"More than 20 percent of current checkout requests fail.",
		"Checkout is still shedding better than a fifth of what it is asked to serve.",
		"Remove the unhealthy backend from service.",
		"Take the failing backend out of rotation.",
		"The checkout alert is a confirmed current issue with a bounded immediate remediation.",
		"The alert is still a live problem and its immediate remediation is already known.",
	)
}

// degradedConfirmedAlertReply is the same verdict over different coverage: the
// application layer moved from unhealthy to degraded, and the evidence under it
// moved with it. Nothing else changes, so a host that posts this one and
// suppresses the reworded one is comparing the decision rather than the prose.
func degradedConfirmedAlertReply(t *testing.T, observedAt string) string {
	t.Helper()
	return rewriteFixture(t, confirmedAlertReplyResult(observedAt),
		`"health_effect":"unhealthy"`, `"health_effect":"degraded"`,
		`"status":"unhealthy","source":"Emisar checkout health","detail":"current requests are failing"`,
		`"status":"degraded","source":"Emisar checkout health","detail":"current requests are failing less often"`,
	)
}

// supersedingRecoveredAlertReply is the closure a stream owes when its firing
// investigation is still the same episode.
//
// A2 keeps one episode across every card, so the evidence the firing turn
// recorded is still on the ledger when the recovery turn writes the opposite of
// it. Retiring the earlier records by id is how the model is required to say
// "this replaces that" — which is exactly what a recovery is.
func supersedingRecoveredAlertReply(t *testing.T, recoveredAt string) string {
	t.Helper()
	return rewriteFixture(t, recoveredAlertReplyResult(recoveredAt),
		`{"id":"checkout-live","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"checkout requests complete successfully","observation":"the live checkout error rate is 0.2 percent and both backends are healthy","relation":"supports"`,
		`{"id":"checkout-live-recovered","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"checkout requests complete successfully","observation":"the live checkout error rate is 0.2 percent and both backends are healthy","supersedes":["checkout-live"],"relation":"supports"`,
		`{"id":"checkout-impact","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"checkout user impact is within its error budget","observation":"the current error rate is 0.2 percent","relation":"supports"`,
		`{"id":"checkout-impact-recovered","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"checkout user impact is within its error budget","observation":"the current error rate is 0.2 percent","supersedes":["checkout-impact"],"relation":"supports"`,
		`"evidence_refs":["checkout-live"]`, `"evidence_refs":["checkout-live-recovered"]`,
	)
}

// withPlannedAndClosedGoal adds the shape the 19:01Z live reply had: a goal
// planned and closed inside the same turn, leaving nothing running behind it.
func withPlannedAndClosedGoal(t *testing.T, body string) string {
	t.Helper()
	return rewriteFixture(t, body,
		`{"id":"complete","type":"complete_episode"`,
		`{"id":"goal-plan-1","type":"plan_goal","goal":{"id":"goal-1","kind":"check",`+
			`"requested_outcome":"Read the load balancer's live backend health",`+
			`"completion_contract":"each backend's health is reported from live evidence",`+
			`"required":false,"authority":"read_only"}},`+
			`{"id":"goal-done-1","type":"update_goal","goal_state":{"goal_id":"goal-1",`+
			`"state":"completed","detail":"the live health read named the unhealthy backend"}},`+
			`{"id":"complete","type":"complete_episode"`,
	)
}

// withCheckoutTaskOffer adds the engineering offer the 2026-08-16 replies all
// carried: the same title, in the same repository, on every card.
func withCheckoutTaskOffer(t *testing.T, body string) string {
	t.Helper()
	return rewriteFixture(t, body,
		`{"id":"complete","type":"complete_episode"`,
		`{"id":"offer-fix","type":"offer_task","task":{"kind":"engineering","title":`+
			`"Remove the unhealthy checkout backend from the load balancer",`+
			`"repository":"repo"}},{"id":"complete","type":"complete_episode"`,
	)
}

// alertReplyPosts counts the answers that reached the channel. A status update
// or an ephemeral is not an answer, so the count is over posts whose body
// actually names the alert.
func alertReplyPosts(posts []slackPost) []slackPost {
	var replies []slackPost
	for _, post := range posts {
		body := post.message.Text + " " + strings.Join(post.message.Sections, " ")
		if strings.Contains(body, "Checkout") || strings.Contains(body, "checkout") {
			replies = append(replies, post)
		}
	}
	return replies
}

// watchAuditOutcomes reads the slack.watch outcomes recorded against one Slack
// input, the way the trace page does. The outcome is how an operator learns the
// host suppressed a post rather than failing to produce one.
func watchAuditOutcomes(t *testing.T, cfg config.Config, objectID string) []string {
	t.Helper()
	return streamColumn(t, cfg, `
		SELECT outcome FROM audit_events
		WHERE kind = 'slack.watch' AND object_id = ?
		ORDER BY created_at, id`, objectID)
}

// standingRuleRunActions reads what the channel's rule ledger says was done
// with a card.
func standingRuleRunActions(t *testing.T, cfg config.Config, sourceInput string) []string {
	t.Helper()
	return streamColumn(t, cfg, `
		SELECT outcome FROM standing_rule_runs
		WHERE source_input = ? ORDER BY created_at, rule_id`, sourceInput)
}

func streamColumn(t *testing.T, cfg config.Config, query string, args ...any) []string {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.QueryContext(context.Background(), query, args...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var values []string
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			t.Fatal(err)
		}
		values = append(values, value)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return values
}

// streamFixture is the two-card alert stream every test below runs: a watch
// channel with a triage rule and a reply alert policy, and a fake Coop that
// answers each card from a queue.
func streamFixture(
	t *testing.T,
	channelID string,
	results ...string,
) (config.Config, *store.Store, *fakeSlack, *Service, core.SlackInput) {
	t.Helper()
	return streamFixtureOn(t, serviceConfig(t), channelID, results...)
}

// streamFixtureOn is the same fixture over a configuration the caller has
// already shaped — a second repository, say, so an offer can name one the
// channel did not.
func streamFixtureOn(
	t *testing.T,
	cfg config.Config,
	channelID string,
	results ...string,
) (config.Config, *store.Store, *fakeSlack, *Service, core.SlackInput) {
	t.Helper()
	ctx := context.Background()
	cfg.Slack.WatchChannels = []string{channelID}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	alertStreamChannel(t, ctx, st, cfg, channelID)
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeQueue = results
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	base := core.SlackInput{
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: channelID,
		UserID: "BGRAFANA", ReceivedAt: time.Now().UTC(),
		Text: "CRITICAL alert: checkout error rate is firing above 20 percent.",
	}
	return cfg, st, slackClient, svc, base
}

// answerStreamCard admits one card and drives it all the way to a delivered
// answer, which is what an operator watching the channel sees happen.
func answerStreamCard(
	t *testing.T,
	svc *Service,
	st *store.Store,
	card core.SlackInput,
) core.AgentRun {
	t.Helper()
	ctx := context.Background()
	if created, err := st.AdmitSlackInput(ctx, card); err != nil || !created {
		t.Fatalf("admit card %s = %t, %v", card.ID, created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	run, err := st.GetAgentRunBySource(ctx, "watch", card.ID)
	if err != nil {
		t.Fatalf("card %s produced no run: %v", card.ID, err)
	}
	if run.LastError != "" {
		t.Fatalf("card %s failed: %q %q", card.ID, run.State, run.LastError)
	}
	return run
}

// Five posts for one unchanged decision on 2026-08-16.
//
// One Grafana stream, Traefik memory oscillating around 95 percent, seven cards
// in ninety minutes, and five replies in the stream's thread — 8:51, 8:57,
// 9:23, 9:55 and 10:04 — each restating that all five allocations sat near the
// 4 GiB cap and each ending with the same offer. Two said only that a node had
// crossed back over the line. Nothing anywhere compared a new assessment with
// the one already posted, so "say nothing unless something changed" was a rule
// with no one holding it.
//
// The comparison is over what the reply DECIDES — verdict, cause status,
// completion, which coverage layers are unwell, how many findings are still
// unexplained, which repository is being offered — because those five replies
// differed in every sentence and in nothing that mattered.
func TestUnchangedFlapDoesNotPostAgain(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "CFLAP")
	svc.coop.(*fakeCoop).completeQueue = []string{
		confirmedAlertReplyResult(observedAt),
		rewordedConfirmedAlertReply(t, observedAt),
	}

	first := base
	first.ID, first.EnvelopeID = "flap-card-1", "env-flap-card-1"
	first.EventID, first.MessageTS = "event-flap-card-1", "1706.100"
	// Both cards say two allocations are over the line. The count is part of the
	// comparison since TestAHigherFiringCountPostsAgain, so a repeat that also
	// moved it would post for that reason and prove nothing about the prose.
	first.Text = "[VA1 FIRING:2] " + base.Text
	firstRun := answerStreamCard(t, svc, st, first)
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 1 {
		t.Fatalf("the first card was not answered exactly once: %d posts", len(posted))
	}

	second := base
	second.ID, second.EnvelopeID = "flap-card-2", "env-flap-card-2"
	second.EventID, second.MessageTS = "event-flap-card-2", "1706.200"
	second.ReceivedAt = base.ReceivedAt.Add(6 * time.Minute)
	second.Text = "[VA1 FIRING:2] " + base.Text
	secondRun := answerStreamCard(t, svc, st, second)
	if secondRun.EpisodeID != firstRun.EpisodeID {
		t.Fatalf(
			"the repeat card left the stream episode: %q, want %q",
			secondRun.EpisodeID, firstRun.EpisodeID,
		)
	}
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 1 {
		t.Fatalf(
			"an unchanged assessment was posted again: %d answers, last %q",
			len(posted), posted[len(posted)-1].message.Text,
		)
	}
	// The card was handled, and the channel has to be able to see that. A
	// suppressed reply that also drops the check mark is indistinguishable from
	// an alert nobody looked at.
	checked := false
	for _, added := range slackClient.reactions {
		if added.name == "white_check_mark" && added.timestamp == second.MessageTS {
			checked = true
		}
	}
	if !checked {
		t.Fatalf("the suppressed card lost its check mark: %+v", slackClient.reactions)
	}
	outcomes := watchAuditOutcomes(t, cfg, second.ID)
	if !slices.Contains(outcomes, "alert_update_unchanged") {
		t.Fatalf(
			"the suppression is not on the trace: slack.watch outcomes %v",
			outcomes,
		)
	}
	// The channel's rule ledger has to agree with the channel. A rule run
	// recorded as "reply" for a card nothing was posted for is what an operator
	// reads when asking why the rule is so noisy.
	for _, action := range standingRuleRunActions(t, cfg, second.ID) {
		if action != "ignore" {
			t.Fatalf("the suppressed card recorded its rule run as %q", action)
		}
	}
}

// A synthetic timer is another attempt in the same alert stream. It must use
// the same decision signature as app cards so an unchanged assessment stays
// quiet instead of posting once per scheduled recheck.
func TestUnchangedOperationalAlertRecheckDoesNotPostAgain(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, _, svc, base := streamFixture(t, "CRECHECK-REPEAT")
	svc.coop.(*fakeCoop).completeQueue = []string{confirmedAlertReplyResult(observedAt)}
	base.ID, base.EnvelopeID, base.EventID = "recheck-base", "env-recheck-base", "event-recheck-base"
	base.MessageTS = "1706.250"
	run := answerStreamCard(t, svc, st, base)
	decision, err := decisionpkg.ParseWatchDecision(confirmedAlertReplyResult(observedAt), svc.now())
	if err != nil {
		t.Fatal(err)
	}
	recheck := base
	recheck.Kind, recheck.ID = "recheck", "synthetic-recheck"
	repeated, _, err := svc.alertReplyRepeats(context.Background(), recheck, run, decision)
	if err != nil || !repeated {
		t.Fatalf("unchanged recheck repeated=%t, err=%v", repeated, err)
	}
}

// The other half: a decision that actually changed still reaches the channel.
// A stream that recovered says something the last reply did not, and this is
// also the case that proves the suppression above is about the decision rather
// than about the second card being a second card.
func TestChangedVerdictPostsAgain(t *testing.T) {
	ctx := context.Background()
	// Both observations are in the past and inside the freshness window, and
	// the recovery is the later of the two: superseding evidence has to carry an
	// observed_at after the record it retires.
	observedAt := time.Now().UTC().Add(-6 * time.Minute).Format(time.RFC3339)
	recoveredAt := time.Now().UTC().Add(-1 * time.Minute).Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "CVERDICT")
	svc.coop.(*fakeCoop).completeQueue = []string{
		confirmedAlertReplyResult(observedAt),
		supersedingRecoveredAlertReply(t, recoveredAt),
	}

	first := base
	first.ID, first.EnvelopeID = "verdict-card-1", "env-verdict-card-1"
	first.EventID, first.MessageTS = "event-verdict-card-1", "1707.100"
	firstRun := answerStreamCard(t, svc, st, first)

	second := base
	second.ID, second.EnvelopeID = "verdict-card-2", "env-verdict-card-2"
	second.EventID, second.MessageTS = "event-verdict-card-2", "1707.200"
	second.ReceivedAt = base.ReceivedAt.Add(20 * time.Minute)
	// The same alert, with a resolved status in front of it: the correlation key
	// is built from the alert's title, so a recovery worded as a different alert
	// would open a different stream and prove nothing about this one.
	second.Text = "[VA1 RESOLVED:2] " + base.Text
	answerStreamCard(t, svc, st, second)
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 2 {
		t.Fatalf("the recovery was suppressed as a repeat: %d answers", len(posted))
	}
	if outcomes := watchAuditOutcomes(t, cfg, second.ID); !slices.Contains(
		outcomes, "alert_update_changed",
	) {
		t.Fatalf("what changed is not on the trace: slack.watch outcomes %v", outcomes)
	}
	// A recovery on a stream that was live holds the episode open for one more
	// window rather than closing it, so the next firing continues this work
	// instead of starting over. What must not change is that the recovery is a
	// posted answer: suppressing a reply must never be the thing that keeps an
	// episode open, and holding one open must never be the thing that silences
	// a reply.
	episode, err := st.GetWorkEpisode(ctx, firstRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal {
		t.Fatalf("the recovered stream did not stay open for its window: %q", episode.State)
	}
}

// Coverage is part of the decision even when the verdict is not. The same
// confirmed issue over a different set of unwell layers is a different answer,
// and an operator watching a service move between unhealthy and degraded is
// watching the only thing the reply is for.
func TestChangedCoveragePostsAgain(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "CCOVER")
	svc.coop.(*fakeCoop).completeQueue = []string{
		confirmedAlertReplyResult(observedAt),
		degradedConfirmedAlertReply(t, observedAt),
	}

	first := base
	first.ID, first.EnvelopeID = "cover-card-1", "env-cover-card-1"
	first.EventID, first.MessageTS = "event-cover-card-1", "1708.100"
	answerStreamCard(t, svc, st, first)

	second := base
	second.ID, second.EnvelopeID = "cover-card-2", "env-cover-card-2"
	second.EventID, second.MessageTS = "event-cover-card-2", "1708.200"
	second.ReceivedAt = base.ReceivedAt.Add(9 * time.Minute)
	second.Text = "[VA1 FIRING:2] " + base.Text
	answerStreamCard(t, svc, st, second)
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 2 {
		t.Fatalf("a moved coverage layer was suppressed as a repeat: %d answers", len(posted))
	}
	// And the comparator says which part of the decision moved. A suppression
	// nobody can debug becomes a suppression nobody trusts, and the first
	// question about a missing reply is always "compared with what".
	outcomes := watchAuditOutcomes(t, cfg, second.ID)
	if !slices.Contains(outcomes, "alert_update_changed") {
		t.Fatalf("what changed is not on the trace: slack.watch outcomes %v", outcomes)
	}
}

// The alert's own count is part of the answer, by operator decision.
//
// A Grafana card says how many of the group are over the line — "[VA1 FIRING:3,
// RESOLVED:1] WARNING | Alloc resident memory near limit" — and the comparator
// shipped on 2026-08-16 read only what the reply DECIDED, so a stream going from
// two allocations over the cap to three, with an identical assessment, said
// nothing. The operator decided the number over the line is the fact they are
// watching. The price is about three of that day's five replies coming back,
// which was argued and chosen rather than overlooked.
func TestAHigherFiringCountPostsAgain(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "CFIRING")
	// The same decision twice, in different words: nothing but the card's count
	// separates the second answer from the first.
	svc.coop.(*fakeCoop).completeQueue = []string{
		confirmedAlertReplyResult(observedAt),
		rewordedConfirmedAlertReply(t, observedAt),
	}

	first := base
	first.ID, first.EnvelopeID = "firing-card-1", "env-firing-card-1"
	first.EventID, first.MessageTS = "event-firing-card-1", "1711.100"
	first.Text = "[VA1 FIRING:2] " + base.Text
	answerStreamCard(t, svc, st, first)

	second := base
	second.ID, second.EnvelopeID = "firing-card-2", "env-firing-card-2"
	second.EventID, second.MessageTS = "event-firing-card-2", "1711.200"
	second.ReceivedAt = base.ReceivedAt.Add(7 * time.Minute)
	second.Text = "[VA1 FIRING:3, RESOLVED:1] " + base.Text
	answerStreamCard(t, svc, st, second)
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 2 {
		t.Fatalf("a third allocation over the line was suppressed as a repeat: %d answers", len(posted))
	}
	// And the trace says the count is what moved, because a post an operator did
	// not expect is asked about the same way a missing one is.
	outcomes := watchAuditOutcomes(t, cfg, second.ID)
	if !slices.Contains(outcomes, "alert_update_changed") {
		t.Fatalf("what changed is not on the trace: slack.watch outcomes %v", outcomes)
	}
}

// The model is told what it already said, so "nothing has changed" is a
// decision it can make.
//
// The prompt has always asked for silence unless something changed, and never
// said what "unchanged" would be measured against. A repeat card looked exactly
// like a first one, so the only honest answer available was to restate the
// assessment — which is what happened five times on 2026-08-16.
func TestAnsweredStreamPromptTellsTheModelWhatWasPosted(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, _, svc, base := streamFixture(t, "CTOLD")
	coopClient := svc.coop.(*fakeCoop)
	coopClient.completeQueue = []string{
		confirmedAlertReplyResult(observedAt),
		rewordedConfirmedAlertReply(t, observedAt),
	}

	first := base
	first.ID, first.EnvelopeID = "told-card-1", "env-told-card-1"
	first.EventID, first.MessageTS = "event-told-card-1", "1709.100"
	answerStreamCard(t, svc, st, first)
	answered := len(coopClient.submitPrompts)

	second := base
	second.ID, second.EnvelopeID = "told-card-2", "env-told-card-2"
	second.EventID, second.MessageTS = "event-told-card-2", "1709.200"
	second.ReceivedAt = base.ReceivedAt.Add(6 * time.Minute)
	second.Text = "[VA1 FIRING:2] " + base.Text
	answerStreamCard(t, svc, st, second)
	if len(coopClient.submitPrompts) <= answered {
		t.Fatalf("the repeat card submitted no turn: %d prompts", len(coopClient.submitPrompts))
	}
	repeat := coopClient.submitPrompts[answered]
	if !strings.Contains(repeat, "<host-stream-answered>") {
		t.Fatalf("the repeat card was briefed as if the stream had never been answered:\n%s", repeat)
	}
	// The verdict, because a section that says only "you already replied" leaves
	// the model comparing against nothing.
	if !strings.Contains(repeat, "confirmed_issue") {
		t.Fatalf("the answered-stream section names no verdict:\n%s", repeat)
	}
	if !strings.Contains(repeat, "Remove the unhealthy backend from service.") {
		t.Fatalf("the answered-stream section names no recommended action:\n%s", repeat)
	}
	// The first card had nothing to be told, and must not be told anything: a
	// stream's opening card is exactly when silence is not allowed.
	if strings.Contains(coopClient.submitPrompts[0], "<host-stream-answered>") {
		t.Fatalf("the first card of a stream was told it had already been answered")
	}
}

// Six identical offers on 2026-08-16, none accepted, each reply re-deriving the
// same task.
//
// Five came from the alert stream and one from a scheduled review in another
// thread, all of them "open an engineering task in blitz-infra to raise the
// memory cap". A second button for work already on offer is not a second
// choice; it is the same choice, rendered again, next to a button that still
// works.
func TestRepeatAlertReplyPointsAtTheOpenOffer(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "COFFER")
	svc.coop.(*fakeCoop).completeQueue = []string{
		withCheckoutTaskOffer(t, confirmedAlertReplyResult(observedAt)),
		withCheckoutTaskOffer(t, degradedConfirmedAlertReply(t, observedAt)),
	}

	first := base
	first.ID, first.EnvelopeID = "offer-card-1", "env-offer-card-1"
	first.EventID, first.MessageTS = "event-offer-card-1", "1710.100"
	answerStreamCard(t, svc, st, first)
	posted := alertReplyPosts(slackClient.posts)
	if len(posted) != 1 {
		t.Fatalf("the first card was not answered exactly once: %d answers", len(posted))
	}
	if !messageOffersEngineeringTask(posted[0].message) {
		t.Fatalf("the first offer rendered no button: %+v", posted[0].message.Actions)
	}

	second := base
	second.ID, second.EnvelopeID = "offer-card-2", "env-offer-card-2"
	second.EventID, second.MessageTS = "event-offer-card-2", "1710.200"
	second.ReceivedAt = base.ReceivedAt.Add(11 * time.Minute)
	second.Text = "[VA1 FIRING:2] " + base.Text
	answerStreamCard(t, svc, st, second)
	posted = alertReplyPosts(slackClient.posts)
	if len(posted) != 2 {
		t.Fatalf("the changed assessment was suppressed: %d answers", len(posted))
	}
	repeat := posted[1].message
	if messageOffersEngineeringTask(repeat) {
		t.Fatalf("the same task was offered twice: %+v", repeat.Actions)
	}
	pointer := strings.Join(repeat.Context, " ")
	if !strings.Contains(pointer, "Already offered") {
		t.Fatalf("the repeat reply does not point at the open offer: %q", pointer)
	}
	if !strings.Contains(pointer, "Remove the unhealthy checkout backend") {
		t.Fatalf("the pointer does not name the task already on offer: %q", pointer)
	}
	if outcomes := watchAuditOutcomes(t, cfg, second.ID); !slices.Contains(
		outcomes, "engineering_task_offer_repeated",
	) {
		t.Fatalf("the repeated offer is not on the trace: %v", outcomes)
	}
}

func messageOffersEngineeringTask(message slackui.Message) bool {
	for _, action := range message.Actions {
		if action.ID == slackui.ActionStartTask {
			return true
		}
	}
	return false
}

// recoveredAlertReplyResult is the same shape as confirmedAlertReplyResult for
// a stream that came back: a not_issue assessment, healthy coverage, and a
// healthy decision_ready completion. Nothing here reports a failure, so no
// finding is required and no host wait is owed.
func recoveredAlertReplyResult(observedAt string) string {
	return fmt.Sprintf(`{"action":"reply","attention":{"addressee":"channel","urgency":1,"confidence":3,"novelty":1,"ownership":3,"contribution":"decision","material":true},"reason":"live evidence agrees the alert recovered","operations":[{"id":"checkout-topology","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"checkout topology has two backends","observation":"the production manifest declares two checkout backends behind the load balancer","source_type":"repository","source_name":"infra/checkout.tf","dimensions":{"repository":"repo","environment":"production","revision":"current"}}},{"id":"checkout-live","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"checkout requests complete successfully","observation":"the live checkout error rate is 0.2 percent and both backends are healthy","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar checkout health","target":"checkout","observed_at":%q,"dimensions":{"service":"checkout","endpoint":"requests","environment":"production","window":"current"}}},{"id":"checkout-impact","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"checkout user impact is within its error budget","observation":"the current error rate is 0.2 percent","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar checkout health","target":"checkout","observed_at":%q,"dimensions":{"service":"checkout","indicator":"error_rate","environment":"production","window":"current"}}},{"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","source":"infra/checkout.tf","detail":"the declared two-backend topology was reconciled"}},{"id":"cov-2","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"healthy","source":"Emisar checkout health","detail":"current requests are completing"}},{"id":"cov-3","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"healthy","source":"Emisar checkout health","detail":"the error rate is back under the alert threshold"}},{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"not_issue","impact":"No checkout requests are failing now; the error rate is back to baseline.","evidence_refs":["checkout-live"],"immediate_action_kind":"monitor","scope":{"status":"bounded","checked_targets":["checkout"],"unverified_targets":["routes outside checkout"],"evidence_refs":["checkout-live"]}}},{"id":"mem","type":"update_memory","memory":{"situation_summary":"The checkout error-rate alert recovered and live evidence agrees.","decisions":["Close the checkout alert stream in its source thread."]}},{"id":"complete","type":"complete_episode","completion":{"message":"**Checkout errors recovered:** the current error rate is back to baseline and both backends are healthy.","completion":{"status":"decision_ready","verdict":"healthy","summary":"The checkout alert recovered and live evidence is back to baseline."}}}]}`, observedAt, observedAt)
}

// A recovery is the end of a firing, not the end of the conversation.
//
// The stream episode stayed open only while the alert was active, so the moment
// a reply said the condition had cleared the episode completed — and a re-fire
// minutes later opened a NEW one, with a fresh briefing, an empty ledger and no
// sight of the offer the earlier episode had already made. That is the shape
// the whole alert-stream change exists to remove, arriving one card later than
// the version it removed: on 2026-08-16 the va1-nomad-oom-risk stream cleared
// at 19:11Z and fired again at 19:24Z, thirteen minutes apart, and the second
// firing knew nothing about the first.
//
// So a stream that WAS live holds its episode open for one more window after it
// recovers, and only the window's own deadline closes it.
func TestARecoveredStreamStaysOpenForItsWindow(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Add(-6 * time.Minute).Format(time.RFC3339)
	recoveredAt := time.Now().UTC().Add(-1 * time.Minute).Format(time.RFC3339)
	cfg, st, _, svc, base := streamFixture(
		t, "CSTREAMHOLD",
		confirmedAlertReplyResult(observedAt),
		supersedingRecoveredAlertReply(t, recoveredAt),
	)
	_ = cfg

	firing := base
	firing.ID, firing.EnvelopeID = "hold-card-1", "env-hold-card-1"
	firing.EventID, firing.MessageTS = "event-hold-card-1", "1712.100"
	first := answerStreamCard(t, svc, st, firing)

	recovered := base
	recovered.ID, recovered.EnvelopeID = "hold-card-2", "env-hold-card-2"
	recovered.EventID, recovered.MessageTS = "event-hold-card-2", "1712.200"
	recovered.ReceivedAt = base.ReceivedAt.Add(2 * time.Minute)
	// The same alert, said the other way round. A differently worded recovery
	// correlates to a stream of its own, which would make this test pass for a
	// reason that has nothing to do with the hold.
	recovered.Text = "[VA1 RESOLVED:1] " + base.Text
	second := answerStreamCard(t, svc, st, recovered)

	if second.EpisodeID != first.EpisodeID {
		t.Fatalf(
			"the recovery opened its own episode %q instead of continuing %q",
			second.EpisodeID, first.EpisodeID,
		)
	}
	episode, err := st.GetWorkEpisode(ctx, second.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal {
		t.Fatalf(
			"a stream that had been live closed on its recovery as %q, so the next firing starts over",
			episode.State,
		)
	}
	if waits := streamWaitCount(t, ctx, st, second.EpisodeID); waits < 1 {
		t.Fatal("the recovered stream is open with nothing scheduled to close it")
	}
}

// The hold is for streams that were live, not for every recovery card.
//
// A RESOLVED notice for something Ryker never investigated is the end of a
// conversation it was not having. Holding an episode open for it would keep a
// wakeup, a session and an episode alive for six hours over a card that said
// nothing was wrong.
func TestARecoveryOnAStreamThatWasNeverActiveStillCompletes(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, _, svc, base := streamFixture(
		t, "CSTREAMQUIET", recoveredAlertReplyResult(observedAt),
	)

	recovered := base
	recovered.ID, recovered.EnvelopeID = "quiet-card-1", "env-quiet-card-1"
	recovered.EventID, recovered.MessageTS = "event-quiet-card-1", "1713.100"
	recovered.Text = "[VA1 RESOLVED:1] CRITICAL alert: checkout error rate is back under 20 percent."
	run := answerStreamCard(t, svc, st, recovered)

	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeCompleted {
		t.Fatalf(
			"a recovery on a stream that was never live held its episode open as %q",
			episode.State,
		)
	}
	if waits := streamWaitCount(t, ctx, st, run.EpisodeID); waits != 0 {
		t.Fatalf("a stream that was never live scheduled %d re-checks", waits)
	}
}

// And the point of the hold: the next firing is the same unit of work.
//
// Same episode means the same ledger, the same thread and the same open offer,
// which is what makes the second firing able to say "the fix is already
// offered above" instead of deriving it again.
func TestARefireAfterARecoveryContinuesTheSameEpisode(t *testing.T) {
	observedAt := time.Now().UTC().Add(-6 * time.Minute).Format(time.RFC3339)
	recoveredAt := time.Now().UTC().Add(-3 * time.Minute).Format(time.RFC3339)
	refiredAt := time.Now().UTC().Format(time.RFC3339)
	_, st, _, svc, base := streamFixture(
		t, "CSTREAMREFIRE",
		confirmedAlertReplyResult(observedAt),
		supersedingRecoveredAlertReply(t, recoveredAt),
		degradedConfirmedAlertReply(t, refiredAt),
	)

	firing := base
	firing.ID, firing.EnvelopeID = "refire-card-1", "env-refire-card-1"
	firing.EventID, firing.MessageTS = "event-refire-card-1", "1714.100"
	first := answerStreamCard(t, svc, st, firing)

	recovered := base
	recovered.ID, recovered.EnvelopeID = "refire-card-2", "env-refire-card-2"
	recovered.EventID, recovered.MessageTS = "event-refire-card-2", "1714.200"
	recovered.ReceivedAt = base.ReceivedAt.Add(2 * time.Minute)
	recovered.Text = "[VA1 RESOLVED:1] " + base.Text
	answerStreamCard(t, svc, st, recovered)

	again := base
	again.ID, again.EnvelopeID = "refire-card-3", "env-refire-card-3"
	again.EventID, again.MessageTS = "event-refire-card-3", "1714.300"
	again.ReceivedAt = base.ReceivedAt.Add(4 * time.Minute)
	third := answerStreamCard(t, svc, st, again)

	if third.EpisodeID != first.EpisodeID {
		t.Fatalf(
			"the re-fire started episode %q instead of continuing %q",
			third.EpisodeID, first.EpisodeID,
		)
	}
	if third.AttemptNumber < 3 {
		t.Fatalf(
			"the re-fire is attempt %d of its episode, so it did not resume the stream's work",
			third.AttemptNumber,
		)
	}
}

// A recovered stream is remembered after its hold expires, but it no longer
// owns where a new alert speaks.
//
// The Vector alert stream copied the destination from its first-ever episode
// into every terminal successor. A current FIRING card was therefore answered
// under a four-day-old Slack message: useful history survived, but so did an
// audience choice whose lifetime should have ended with the recovered hold.
func TestARefireAfterTheRecoveredHoldStartsAtTheNewCard(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Add(-6 * time.Minute).Format(time.RFC3339)
	recoveredAt := time.Now().UTC().Add(-3 * time.Minute).Format(time.RFC3339)
	cfg, st, _, svc, base := streamFixture(
		t, "CSTREAMNEWCYCLE",
		confirmedAlertReplyResult(observedAt),
		supersedingRecoveredAlertReply(t, recoveredAt),
	)

	firing := base
	firing.ID, firing.EnvelopeID = "new-cycle-card-1", "env-new-cycle-card-1"
	firing.EventID, firing.MessageTS = "event-new-cycle-card-1", "1715.100"
	first := answerStreamCard(t, svc, st, firing)

	recovered := base
	recovered.ID, recovered.EnvelopeID = "new-cycle-card-2", "env-new-cycle-card-2"
	recovered.EventID, recovered.MessageTS = "event-new-cycle-card-2", "1715.200"
	recovered.ReceivedAt = base.ReceivedAt.Add(2 * time.Minute)
	recovered.Text = "[VA1 RESOLVED:1] " + base.Text
	second := answerStreamCard(t, svc, st, recovered)

	if err := st.SetWorkEpisodePhase(
		ctx, second.ID, core.EpisodeCompleted, "completed", "Recovered hold expired", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	expiredAt := time.Now().UTC().Add(-cfg.Slack.AlertStreamOpenWindow.Duration - time.Minute)
	if _, err := raw.ExecContext(
		ctx, `UPDATE work_episodes SET completed_at = ? WHERE id = ?`,
		expiredAt.Format(core.TimestampFormat), first.EpisodeID,
	); err != nil {
		raw.Close()
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	again := base
	again.ID, again.EnvelopeID = "new-cycle-card-3", "env-new-cycle-card-3"
	again.EventID, again.MessageTS = "event-new-cycle-card-3", "1715.300"
	again.ReceivedAt = time.Now().UTC()
	if created, err := st.AdmitSlackInput(ctx, again); err != nil || !created {
		t.Fatalf("admit new cycle = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	third, err := st.GetAgentRunBySource(ctx, "watch", again.ID)
	if err != nil {
		t.Fatal(err)
	}
	if third.EpisodeID == first.EpisodeID {
		t.Fatalf("the expired recovered stream kept the new firing in episode %q", third.EpisodeID)
	}
	if third.ThreadTS != again.MessageTS {
		t.Fatalf("the new firing answers in %q, not its current card %q", third.ThreadTS, again.MessageTS)
	}
	thirdEpisode, err := st.GetWorkEpisode(ctx, third.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if thirdEpisode.ParentEpisodeID != first.EpisodeID {
		t.Fatalf("the new cycle lost its historical parent: %+v", thirdEpisode)
	}
	if thirdEpisode.Destination.ThreadTS != again.MessageTS {
		t.Fatalf("the new cycle inherited the historical destination %q", thirdEpisode.Destination.ThreadTS)
	}
}

// The Host OOM stream stayed non-terminal while provider and correction
// failures accumulated. Three recovered cycles then re-fired hours later, but
// each new OOM was admitted into the day-old episode and inherited evidence
// from a different killed process. Recovery plus an expired hold ends the
// cycle even when the old investigation failed to terminalize itself.
func TestARefireAfterAnExpiredRecoveryStartsANewEpisodeWhenTheOldOneIsStillOpen(t *testing.T) {
	ctx := context.Background()
	firstAt := time.Now().UTC()
	recoveredAt := firstAt.Add(10 * time.Minute)
	cfg, st, _, svc, base := streamFixture(
		t, "CSTREAMSTUCKCYCLE",
		confirmedAlertReplyResult(firstAt.Format(time.RFC3339)),
		supersedingRecoveredAlertReply(t, recoveredAt.Format(time.RFC3339)),
	)
	base.Text = "[VA1 FIRING:1] WARNING | checkout errors\n" + base.Text
	clock := firstAt
	svc.clock = func() time.Time { return clock }

	firing := base
	firing.ID, firing.EnvelopeID = "stuck-cycle-card-1", "env-stuck-cycle-card-1"
	firing.EventID, firing.MessageTS = "event-stuck-cycle-card-1", "1715.410"
	firing.ReceivedAt = firstAt
	first := answerStreamCard(t, svc, st, firing)

	clock = recoveredAt
	recovered := base
	recovered.ID, recovered.EnvelopeID = "stuck-cycle-card-2", "env-stuck-cycle-card-2"
	recovered.EventID, recovered.MessageTS = "event-stuck-cycle-card-2", "1715.420"
	recovered.ReceivedAt = recoveredAt
	recovered.Text = "[VA1 RESOLVED:1] " + base.Text
	answerStreamCard(t, svc, st, recovered)

	old, err := st.GetWorkEpisode(ctx, first.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if old.State == core.EpisodeCompleted {
		t.Fatalf("fixture unexpectedly terminalized the recovered hold: %+v", old)
	}

	again := base
	again.ID, again.EnvelopeID = "stuck-cycle-card-3", "env-stuck-cycle-card-3"
	again.EventID, again.MessageTS = "event-stuck-cycle-card-3", "1715.430"
	again.ReceivedAt = recoveredAt.Add(cfg.Slack.AlertStreamOpenWindow.Duration + time.Minute)
	clock = again.ReceivedAt
	if created, err := st.AdmitSlackInput(ctx, again); err != nil || !created {
		t.Fatalf("admit new cycle = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	third, err := st.GetAgentRunBySource(ctx, "watch", again.ID)
	if err != nil {
		t.Fatal(err)
	}
	if third.EpisodeID == first.EpisodeID {
		t.Fatalf("expired recovered cycle reused old episode %q", third.EpisodeID)
	}
	if third.ThreadTS != again.MessageTS {
		t.Fatalf("new cycle destination = %q, want current card %q", third.ThreadTS, again.MessageTS)
	}
	thirdEpisode, err := st.GetWorkEpisode(ctx, third.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if thirdEpisode.ParentEpisodeID != first.EpisodeID {
		t.Fatalf("new cycle lost historical parent: %+v", thirdEpisode)
	}
}

// Signing Server and Internal Utils fired twenty seconds apart. The second
// lifecycle was linked to the first for useful operational history, but the
// host also copied the first card's Slack destination. Even with shadow mode
// fixed, the Internal Utils decision would have appeared under another alert.
// A parent is evidence continuity, never reply routing.
func TestANewOperationalLifecycleKeepsHistoryWithoutBorrowingItsThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CUTILS", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "UOPERATOR",
	}); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	now := time.Now().UTC()
	first := core.SlackInput{
		ID: "signing-firing", EnvelopeID: "env-signing-firing", EventID: "event-signing-firing",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CUTILS",
		MessageTS: "1700.100", UserID: "BBETTERSTACK", ReceivedAt: now,
		Text: "New incident for Signing Server\nCause: Status 502\n" +
			"Incident: <https://uptime.betterstack.com/team/t57321/incidents/1003449400|Incident>",
	}
	second := first
	second.ID, second.EnvelopeID, second.EventID = "utils-firing", "env-utils-firing", "event-utils-firing"
	second.MessageTS, second.ReceivedAt = "1700.200", now.Add(20*time.Second)
	second.Text = "New incident for Internal Utils\nCause: Status 502\n" +
		"Incident: <https://uptime.betterstack.com/team/t57321/incidents/1003449411|Incident>"
	for _, input := range []core.SlackInput{first, second} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("queue %s: %v", input.ID, err)
		}
	}
	firstRun, err := st.GetAgentRunBySource(ctx, "watch", first.ID)
	if err != nil {
		t.Fatal(err)
	}
	secondRun, err := st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil {
		t.Fatal(err)
	}
	secondEpisode, err := st.GetWorkEpisode(ctx, secondRun.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if secondEpisode.ParentEpisodeID != firstRun.EpisodeID {
		t.Fatalf("new lifecycle history parent = %q, want %q",
			secondEpisode.ParentEpisodeID, firstRun.EpisodeID)
	}
	if secondRun.ThreadTS != second.MessageTS ||
		secondEpisode.Destination.ThreadTS != second.MessageTS {
		t.Fatalf("new lifecycle destination = run %q episode %q, want %q",
			secondRun.ThreadTS, secondEpisode.Destination.ThreadTS, second.MessageTS)
	}
}

// A card that repeats what the stream just answered costs no model turn.
//
// A1 stopped a newer card from destroying the investigation in flight, and A3
// stopped its answer being posted twice — but the turn was still spent: the
// second card was leased, briefed, submitted, answered and only then compared
// and suppressed. On 2026-08-16 the va1-nomad-oom-risk stream produced seven
// cards in ninety minutes, so that is six investigations of a condition the
// first one had already established.
//
// The host can see for itself when a card says nothing new: the bracketed
// marker carries how many alerts are firing and how many have resolved, and a
// card whose counts match the answered one, arriving while that answer was
// being written, is the same news. It is answered without asking a model, and
// it carries the ✅ that says so.
func TestACardThatSaysNothingNewIsAnsweredWithoutAModelTurn(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, slackClient, svc, base := streamFixture(
		t, "CFOLD", confirmedAlertReplyResult(observedAt),
	)
	coopClient := svc.coop.(*fakeCoop)
	base.Text = "[VA1 FIRING:2] " + base.Text

	first := base
	first.ID, first.EnvelopeID = "fold-card-1", "env-fold-card-1"
	first.EventID, first.MessageTS = "event-fold-card-1", "1716.100"
	answerStreamCard(t, svc, st, first)
	if turns := len(coopClient.submitPrompts); turns != 1 {
		t.Fatalf("the first card took %d model turns, want 1", turns)
	}

	// It arrived while the first card was being investigated, which is the
	// whole case: the answer that followed was written knowing everything this
	// card says. A card that arrives AFTER the answer is a fresh statement of
	// the current state and still earns its own turn.
	repeat := base
	repeat.ID, repeat.EnvelopeID = "fold-card-2", "env-fold-card-2"
	repeat.EventID, repeat.MessageTS = "event-fold-card-2", "1716.200"
	// Driven by hand rather than through answerStreamCard, which reads a
	// superseded run as a failed card — and a folded card is answered, not
	// failed. Its run ending superseded with that reason IS the behaviour.
	ctx := context.Background()
	if created, err := st.AdmitSlackInput(ctx, repeat); err != nil || !created {
		t.Fatalf("admit repeat = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	folded, err := st.GetAgentRunBySource(ctx, "watch", repeat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if folded.State != core.AgentRunSuperseded ||
		!strings.Contains(folded.LastError, "answered by this stream") {
		t.Fatalf("the repeat was not folded into the answered stream: %+v", folded)
	}

	if turns := len(coopClient.submitPrompts); turns != 1 {
		t.Fatalf(
			"a card repeating the answered counts spent %d model turns, want the first one only",
			turns,
		)
	}
	if posted := alertReplyPosts(slackClient.posts); len(posted) != 1 {
		t.Fatalf("the repeat was answered again in the channel: %d answers", len(posted))
	}
	answered := false
	for _, reaction := range slackClient.reactions {
		if reaction.name == "white_check_mark" && reaction.timestamp == repeat.MessageTS {
			answered = true
		}
	}
	if !answered {
		t.Fatalf(
			"the folded card carries no answered mark, so it reads as unseen: %+v",
			slackClient.reactions,
		)
	}
}

// And a card that says something new still gets its own investigation.
//
// This is the door the fold-in must not close. A third allocation crossing the
// line is the fact an operator is watching, and deciding it host-side from the
// counts alone would be the flap suppression eating the escalation it exists to
// make visible.
func TestACardWithANewCountStillGetsItsOwnTurn(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, _, svc, base := streamFixture(
		t, "CFOLDNEW",
		confirmedAlertReplyResult(observedAt),
		degradedConfirmedAlertReply(t, observedAt),
	)
	coopClient := svc.coop.(*fakeCoop)

	first := base
	first.ID, first.EnvelopeID = "foldnew-card-1", "env-foldnew-card-1"
	first.EventID, first.MessageTS = "event-foldnew-card-1", "1717.100"
	first.Text = "[VA1 FIRING:2] " + base.Text
	answerStreamCard(t, svc, st, first)

	escalated := base
	escalated.ID, escalated.EnvelopeID = "foldnew-card-2", "env-foldnew-card-2"
	escalated.EventID, escalated.MessageTS = "event-foldnew-card-2", "1717.200"
	escalated.ReceivedAt = base.ReceivedAt.Add(90 * time.Second)
	escalated.Text = "[VA1 FIRING:3] " + base.Text
	answerStreamCard(t, svc, st, escalated)

	if turns := len(coopClient.submitPrompts); turns != 2 {
		t.Fatalf(
			"a third allocation over the line was folded away after %d model turns; it is news",
			turns,
		)
	}
}

// A stream with no bracketed marker is left exactly as it was.
//
// Terraform run notifications, Better Stack alerts and every other app card
// report 0 and 0, so comparing counts would make "Run Applied" and "Run
// Errored" the same news. Only a card that states its own counts may be folded.
func TestAnAppCardWithNoCountsIsNeverFolded(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, _, svc, base := streamFixture(
		t, "CFOLDPLAIN",
		confirmedAlertReplyResult(observedAt),
		degradedConfirmedAlertReply(t, observedAt),
	)
	coopClient := svc.coop.(*fakeCoop)

	first := base
	first.ID, first.EnvelopeID = "foldplain-card-1", "env-foldplain-card-1"
	first.EventID, first.MessageTS = "event-foldplain-card-1", "1718.100"
	answerStreamCard(t, svc, st, first)

	repeat := base
	repeat.ID, repeat.EnvelopeID = "foldplain-card-2", "env-foldplain-card-2"
	repeat.EventID, repeat.MessageTS = "event-foldplain-card-2", "1718.200"
	repeat.ReceivedAt = base.ReceivedAt.Add(90 * time.Second)
	answerStreamCard(t, svc, st, repeat)

	if turns := len(coopClient.submitPrompts); turns != 2 {
		t.Fatalf("a markerless app card was folded on counts it never carried: %d turns", turns)
	}
}
