package service

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	attentionpkg "github.com/AndrewDryga/responder/internal/attention"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestAlertToSlackAndCompletedCoopTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	signal := core.Signal{
		Route: "grafana", SourceID: "alert-1", EventID: "signal-event-1",
		Repository: "repo", CorrelationKey: "prod-api", Status: core.SignalFiring,
		Title: "API is unavailable", Severity: "critical", ReceivedAt: time.Now().UTC(),
	}
	if _, _, err := st.AdmitWebhook(ctx, "grafana", "delivery-1", "digest", []core.Signal{signal}); err != nil {
		t.Fatal(err)
	}
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || incidents[0].RootTS == "" {
		t.Fatalf("root incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	incident, _ = st.GetIncident(ctx, incident.ID)
	if incident.CoopSessionID == "" || incident.ActiveTurnID == "" {
		t.Fatalf("Coop binding = %+v", incident)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "is investigating..." ||
		slack.statuses[0].thread != incident.RootTS {
		t.Fatalf("active turn status = %+v", slack.statuses)
	}

	coopClient.complete(`{
	  "message":"Verified the alert. The API process is healthy; the load balancer target is stale.",
	  "coverage":[
	    {"layer":"change","status":"healthy","source":"repository","detail":"The declared backend topology was checked"},
	    {"layer":"host","status":"healthy","source":"Emisar","detail":"The API host is responsive"},
	    {"layer":"runtime","status":"healthy","source":"Emisar","detail":"The API runtime is responsive"},
	    {"layer":"workload","status":"healthy","source":"Emisar","detail":"The API process is running"},
	    {"layer":"dependency","status":"unhealthy","source":"Emisar","detail":"The load balancer target is stale"},
	    {"layer":"application","status":"healthy","source":"Emisar","detail":"The API process responds locally"},
	    {"layer":"slo","status":"degraded","source":"Grafana","detail":"The availability alert is firing"}
	  ],
	  "completion":{"status":"decision_ready","summary":"The stale load balancer target is the bounded failure and should be corrected."}
	}`)
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	svc.channelWrites.Reset()
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 2 {
		t.Fatalf("Slack posts = %+v", slack.posts)
	}
	if slack.posts[0].thread != "" || slack.posts[1].thread != incident.RootTS {
		t.Fatalf("thread mapping = %+v", slack.posts)
	}
	incident, _ = st.GetIncident(ctx, incident.ID)
	if incident.ActiveTurnID != "" || incident.Workflow != core.WorkflowParked {
		t.Fatalf("terminal workflow = %+v", incident)
	}
	if len(slack.statuses) != 2 || slack.statuses[1].channel != incident.ChannelID ||
		slack.statuses[1].thread != incident.RootTS || slack.statuses[1].text != "" {
		t.Fatalf("terminal turn did not clear its native status: %+v", slack.statuses)
	}
}

func TestTriageFinalizationExhaustionUsesFrozenSlackDestination(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CWATCH", ThreadTS: "1700.900",
		ConversationKey: "thread:CWATCH:1700.900",
		SourceKind:      "watch", SourceID: "missing-watch-input",
		Repository: "repo", Prompt: "investigate", SessionID: "ses_watch",
	})
	if err != nil || !created {
		t.Fatalf("queue triage run = %+v, %v, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx,
		leased.ID,
		"coop_turn_missing_source",
		2,
		0,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx,
		leased.ID,
		"completed",
		[]byte(`{"action":"ignore"}`),
		"",
		0,
	); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("terminal triage run = %+v, %v", stored, err)
	}
	drainSlackDeliveries(t, ctx, svc)
	// Nothing is posted. A failure Responder cannot explain is not something a
	// channel can act on, so the message is paused and the work stays queued.
	if len(slack.posts) != 0 {
		t.Fatalf("a terminal triage failure posted to Slack: %+v", slack.posts)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "" ||
		slack.statuses[0].channel != run.ChannelID ||
		slack.statuses[0].thread != run.ThreadTS {
		t.Fatalf("fallback triage status clear = %+v", slack.statuses)
	}
}

func TestWatchedAppAlertBurstEvaluatesEveryEventInOrder(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CWATCH", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	coopClient.completeQueue = []string{
		fmt.Sprintf(`{"action":"reply","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3},"message":"Cassandra throughput is below 4k. Reduce nonessential load while restoring capacity, then verify RPS stays above 4k and errors stop.","alert_assessment":{"verdict":"confirmed_issue","impact":"Current Cassandra throughput is below its operating threshold.","cause_status":"bounded","cause":"The Cassandra service is reachable, but aggregate request throughput remains below 4k.","immediate_action":"Reduce nonessential Cassandra load while restoring service capacity.","verification":"Confirm fresh total RPS stays above 4k and request errors stop.","long_term_solution":"Add capacity and traffic controls that keep Cassandra above its operating threshold."},"evidence":[{"claim_id":"change.recent","claim":"the deployed Cassandra topology is current","observation":"the repository declares the current Cassandra service and operating threshold","relation":"supports","health_effect":"none","source_type":"repository","source_name":"cassandra topology","dimensions":{"repository":"repo","environment":"production","revision":"current"}},{"claim_id":"application.functional_behavior","claim":"Cassandra serves requests above its operating threshold","observation":"fresh monitoring reports total RPS below 4k","relation":"contradicts","health_effect":"unhealthy","source_type":"monitoring","source_name":"Cassandra throughput","observed_at":%q,"dimensions":{"service":"cassandra","endpoint":"requests","environment":"production","window":"current"}}],"coverage":[{"layer":"change","claim_ids":["change.recent"],"status":"healthy","detail":"The current Cassandra topology was reconciled."},{"layer":"application","claim_ids":["application.functional_behavior"],"status":"unhealthy","detail":"Current throughput is below 4k."},{"layer":"slo","claim_ids":["impact.current"],"status":"unknown","detail":"No separate user-impact measure is available."},{"layer":"dependency","claim_ids":["dependency.current_health"],"status":"unknown","detail":"Dependency health does not change the confirmed throughput failure."}],"completion":{"status":"decision_ready","verdict":"unhealthy","summary":"Cassandra throughput is currently below its operating threshold."}}`, observedAt),
		fmt.Sprintf(`{"action":"reply","attention":{"addressee":"channel","urgency":2,"confidence":3,"novelty":3,"ownership":3},"message":"Cassandra recovered. Fresh throughput is above 4k and the current request check is passing.","alert_assessment":{"verdict":"not_issue","impact":"The earlier throughput drop is no longer active."},"evidence":[{"claim_id":"change.recent","claim":"the deployed Cassandra topology is current","observation":"the repository declares the current Cassandra service and operating threshold","relation":"supports","health_effect":"none","source_type":"repository","source_name":"cassandra topology","dimensions":{"repository":"repo","environment":"production","revision":"current"}},{"claim_id":"application.functional_behavior","claim":"Cassandra serves requests above its operating threshold","observation":"fresh monitoring reports total RPS above 4k and the request check is passing","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"Cassandra throughput","observed_at":%q,"dimensions":{"service":"cassandra","endpoint":"requests","environment":"production","window":"current"}},{"claim_id":"impact.current","claim":"the Cassandra throughput drop has recovered","observation":"the current service indicator is above threshold","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"Cassandra throughput","observed_at":%q,"dimensions":{"service":"cassandra","indicator":"total_rps","environment":"production","window":"current"}},{"claim_id":"dependency.current_health","claim":"the Cassandra dependency is available","observation":"the current Cassandra request check succeeds","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"Cassandra request check","observed_at":%q,"dimensions":{"dependency":"cassandra","service":"cassandra","environment":"production"}}],"coverage":[{"layer":"change","claim_ids":["change.recent"],"status":"healthy","detail":"The current Cassandra topology was reconciled."},{"layer":"application","claim_ids":["application.functional_behavior"],"status":"healthy","detail":"Current throughput and request checks pass."},{"layer":"slo","claim_ids":["impact.current"],"status":"healthy","detail":"The current throughput indicator is above threshold."},{"layer":"dependency","claim_ids":["dependency.current_health"],"status":"healthy","detail":"The Cassandra request check succeeds."}],"completion":{"status":"decision_ready","verdict":"healthy","summary":"Cassandra throughput and request checks have recovered."}}`, observedAt, observedAt, observedAt),
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	inputs := []core.SlackInput{
		{
			ID: "slack-app-firing", EnvelopeID: "env-app-firing",
			EventID: "EvAppFiring", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
			ChannelID: "CWATCH", MessageTS: "1700.500", UserID: "BBETTERSTACK",
			Text: "FIRING: Cassandra total RPS is below 4k.",
		},
		{
			ID: "slack-app-recovered", EnvelopeID: "env-app-recovered",
			EventID: "EvAppRecovered", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
			ChannelID: "CWATCH", MessageTS: "1700.501", UserID: "BGRAFANA",
			Text: "RESOLVED: Cassandra total RPS recovered.",
		},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatal(err)
		}
	}
	for range inputs {
		finishQueuedAgentRun(t, ctx, svc)
	}
	for _, input := range inputs {
		run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
		if err != nil || run.State != core.AgentRunCompleted {
			t.Fatalf("agent run for %s = %+v, %v", input.ID, run, err)
		}
	}
	if len(slackClient.posts) != 2 ||
		!strings.Contains(slackClient.posts[0].message.Text, "below 4k") ||
		!strings.Contains(slackClient.posts[1].message.Text, "recovered") {
		t.Fatalf("ordered app alert replies = %+v", slackClient.posts)
	}
}

func TestExplicitMentionLoadsAmbientSlackHistoryWhenProactiveTriageIsOff(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CWATCH"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	target := core.SlackInput{
		ID: "slack-mentioned", EnvelopeID: "env-mentioned", EventID: "EvMentioned",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000003", UserID: "U123ABC",
		Text: "<@U999BOT> should we roll this back?",
	}
	if created, err := st.AdmitSlackInput(ctx, target); err != nil || !created {
		t.Fatalf("admit mention = %v, %v", created, err)
	}
	slack := &fakeSlack{history: []slackui.HistoryMessage{
		{
			Timestamp: "1700000000.000001", UserID: "U111",
			Text: "The deploy raised the API error rate.",
		},
		{
			Timestamp: "1700000000.000002", UserID: "U222",
			Text: "I paused the next rollout step.",
		},
		{
			Timestamp: target.MessageTS, UserID: target.UserID, Text: target.Text,
		},
	}}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"ignore"}`
	svc := New(
		cfg, st, coopClient, slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted prompts = %d", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	start := strings.Index(prompt, "<untrusted-slack-context>\n")
	end := strings.Index(prompt, "\n</untrusted-slack-context>")
	if start < 0 || end <= start {
		t.Fatalf("prompt has no bounded context: %s", prompt)
	}
	var evidence struct {
		RecentMessages []decisionpkg.WatchContextMessage `json:"recent_channel_messages"`
	}
	start += len("<untrusted-slack-context>\n")
	if err := json.Unmarshal([]byte(prompt[start:end]), &evidence); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"The deploy raised the API error rate.",
		"I paused the next rollout step.",
		"should we roll this back?",
	}
	if len(evidence.RecentMessages) != len(want) {
		t.Fatalf("recent Slack history = %+v", evidence.RecentMessages)
	}
	for i := range want {
		if evidence.RecentMessages[i].Text != want[i] {
			t.Fatalf(
				"recent Slack history %d = %q, want %q",
				i,
				evidence.RecentMessages[i].Text,
				want[i],
			)
		}
	}
}

func TestAttentionPolicyKeepsTypedAppAlertRecovery(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 RESOLVED:1] WARNING | Cassandra repair overdue",
	}
	decision := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "The scheduled repair completed.",
		Attention: decisionpkg.AttentionAssessment{
			Addressee: "channel", Urgency: 0, Confidence: 3, Novelty: 1, Ownership: 2,
		},
		AlertAssessment: &decisionpkg.AlertAssessment{
			Verdict: "not_issue",
			Impact:  "The overdue condition cleared.",
		},
	}
	filtered := attentionpkg.Enforce(
		input,
		decisionpkg.WatchTurnState{AlertPolicy: "reply_here"},
		decision,
		7,
		4,
	)
	if filtered.Action != "reply" || filtered.Message == "" {
		t.Fatalf("typed recovery was suppressed: %+v", filtered)
	}
}
