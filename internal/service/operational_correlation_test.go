package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
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

// An answer that is written and queued is delivered. A newer card on the same
// stream is not evidence that the answer is stale — on 2026-08-16 that reading
// threw away four of them, one of which an investigation had spent fifteen
// minutes producing.
//
// Staleness has an observable criterion: a NEWER reply already went out in this
// thread. Nothing else supersedes a written answer.
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
	return fmt.Sprintf(`{"action":"reply","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},"reason":"fresh repository and live evidence confirm the alert","operations":[{"id":"checkout-topology","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"checkout topology has two backends","observation":"the production manifest declares two checkout backends behind the load balancer","source_type":"repository","source_name":"infra/checkout.tf","dimensions":{"repository":"repo","environment":"production","revision":"current"}}},{"id":"checkout-live","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"checkout requests complete successfully","observation":"the live checkout error rate is 20.5 percent and one backend is unhealthy","relation":"contradicts","health_effect":"unhealthy","source_type":"emisar","source_name":"Emisar checkout health","observed_at":%q,"dimensions":{"service":"checkout","endpoint":"requests","environment":"production","window":"current"}}},{"id":"checkout-impact","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"checkout user impact is within its error budget","observation":"the current error rate is 20.5 percent","relation":"contradicts","health_effect":"degraded","source_type":"emisar","source_name":"Emisar checkout health","observed_at":%q,"dimensions":{"service":"checkout","indicator":"error_rate","environment":"production","window":"current"}}},{"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","source":"infra/checkout.tf","detail":"the declared two-backend topology was reconciled"}},{"id":"cov-2","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"unhealthy","source":"Emisar checkout health","detail":"current requests are failing"}},{"id":"cov-3","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"degraded","source":"Emisar checkout health","detail":"error rate exceeds the alert threshold"}},{"id":"finding-1","type":"record_finding","finding":{"what":"Checkout requests fail for more than 20 percent of users","scope":"checkout, production","status":"explained","cause_evidence":["checkout-live"],"alternatives":[{"hypothesis":"A client-side release is producing the errors","discriminated_by":"checkout-live"}]}},{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue","impact":"More than 20 percent of current checkout requests fail.","cause_status":"identified","cause":"One load balancer backend is unhealthy after the current deployment.","cause_claim_ids":["application.functional_behavior"],"evidence_refs":["checkout-live"],"immediate_action":"Remove the unhealthy backend from service.","verification":"Confirm checkout errors return below the alert threshold after the backend is removed.","long_term_solution":"Correct the deployment regression and add a checkout-error rollout guard."}},{"id":"mem","type":"update_memory","memory":{"situation_summary":"A critical checkout error-rate alert was confirmed from repository and live evidence.","decisions":["Continue the alert investigation in its source thread."]}},{"id":"complete","type":"complete_episode","completion":{"message":"**Checkout errors are affecting current requests:** more than 20 percent are failing.\n\nRemove the unhealthy backend from service and verify the error rate falls. The durable fix is to correct the deployment regression and add a rollout guard for checkout errors.","completion":{"status":"decision_ready","verdict":"unhealthy","summary":"The checkout alert is a confirmed current issue with a bounded immediate remediation."}}}]}`, observedAt, observedAt)
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
		if strings.Contains(post.message.Text, "Checkout errors") {
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
		if strings.Contains(post.message.Text, "Checkout errors") {
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

// recoveredAlertReplyResult is the same shape as confirmedAlertReplyResult for
// a stream that came back: a not_issue assessment, healthy coverage, and a
// healthy decision_ready completion. Nothing here reports a failure, so no
// finding is required and no host wait is owed.
func recoveredAlertReplyResult(observedAt string) string {
	return fmt.Sprintf(`{"action":"reply","attention":{"addressee":"channel","urgency":1,"confidence":3,"novelty":1,"ownership":3,"contribution":"decision","material":true},"reason":"live evidence agrees the alert recovered","operations":[{"id":"checkout-topology","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"checkout topology has two backends","observation":"the production manifest declares two checkout backends behind the load balancer","source_type":"repository","source_name":"infra/checkout.tf","dimensions":{"repository":"repo","environment":"production","revision":"current"}}},{"id":"checkout-live","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"checkout requests complete successfully","observation":"the live checkout error rate is 0.2 percent and both backends are healthy","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar checkout health","observed_at":%q,"dimensions":{"service":"checkout","endpoint":"requests","environment":"production","window":"current"}}},{"id":"checkout-impact","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"checkout user impact is within its error budget","observation":"the current error rate is 0.2 percent","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar checkout health","observed_at":%q,"dimensions":{"service":"checkout","indicator":"error_rate","environment":"production","window":"current"}}},{"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","source":"infra/checkout.tf","detail":"the declared two-backend topology was reconciled"}},{"id":"cov-2","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"healthy","source":"Emisar checkout health","detail":"current requests are completing"}},{"id":"cov-3","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"healthy","source":"Emisar checkout health","detail":"the error rate is back under the alert threshold"}},{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"not_issue","impact":"No checkout requests are failing now; the error rate is back to baseline.","evidence_refs":["checkout-live"]}},{"id":"mem","type":"update_memory","memory":{"situation_summary":"The checkout error-rate alert recovered and live evidence agrees.","decisions":["Close the checkout alert stream in its source thread."]}},{"id":"complete","type":"complete_episode","completion":{"message":"**Checkout errors recovered:** the current error rate is back to baseline and both backends are healthy.","completion":{"status":"decision_ready","verdict":"healthy","summary":"The checkout alert recovered and live evidence is back to baseline."}}}]}`, observedAt, observedAt)
}
