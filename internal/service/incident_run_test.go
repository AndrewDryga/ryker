package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/slackfile"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestPrivateSlackReplayRunsWithoutPublicSideEffects(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CREPLAY"}
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_replay_private", EnvelopeID: "replay-private:slack_replay_private",
		EventID: "replay-private:slack_replay_private", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "CREPLAY", ThreadTS: "1700.100",
		MessageTS: "1700.200", UserID: "U123ABC",
		Text: "<@U999BOT> inspect this and reply",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit private replay = %t, %v", created, err)
	}
	coopClient := newFakeCoop()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.statuses) != 0 || len(slackClient.reactions) != 0 {
		t.Fatalf("private replay acknowledged publicly: statuses=%+v reactions=%+v", slackClient.statuses, slackClient.reactions)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	coopClient.complete(`{
		"action":"reply",
		"operations":[
			{"id":"mem","type":"update_memory","memory":{
				"knowledge":[{
					"subject":"Symbolicator storage",
					"kind":"decision",
					"statement":"Use GCS with GitHub Actions WIF for symbol uploads.",
					"status":"accepted",
					"confidence":3,
					"source_ref":"https://example.slack.com/archives/CREPLAY/p1700200",
					"source_message_ts":"1700.200"
				}]
			}},
			{"id":"complete","type":"complete_episode","completion":{
				"message":"Verified privately.",
				"completion":{"status":"decision_ready","summary":"Verified privately."}
			}}
		]
	}`)
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 || len(slackClient.updates) != 0 ||
		len(slackClient.statuses) != 0 || len(slackClient.reactions) != 0 {
		t.Fatalf("private replay produced public Slack side effects: %+v", slackClient)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted {
		t.Fatalf("private replay run = %+v, %v", run, err)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 0 {
		t.Fatalf("private replay created incidents = %+v, %v", incidents, err)
	}
	memory, err := st.Intelligence.GetConversationMemory(ctx, input.ChannelID, input.ThreadTS)
	if err != nil || len(memory.State.Knowledge) != 1 ||
		memory.State.Knowledge[0].Subject != "Symbolicator storage" {
		t.Fatalf("private replay conversation memory = %+v, %v", memory, err)
	}
	channelMemory, err := st.Intelligence.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || len(channelMemory.State.Knowledge) != 0 {
		t.Fatalf("private replay changed channel-wide memory = %+v, %v", channelMemory, err)
	}
}

func TestPrivateSlackReplayTerminalFailureHasNoPublicSideEffects(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_replay_private_failure", EnvelopeID: "replay-private:slack_replay_private_failure",
		EventID: "replay-private:slack_replay_private_failure", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "CREPLAY", MessageTS: "1700.300",
		UserID: "U123ABC", Text: "verify privately",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit private replay = %t, %v", created, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ConversationKey: "channel:" + input.ChannelID, SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil || !created {
		t.Fatalf("queue private replay = %+v, %t, %v", run, created, err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.finishTriageRunFailure(
		ctx, run, input, decisionpkg.WatchTurnState{}, "internal operation failure",
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 || len(slackClient.updates) != 0 ||
		len(slackClient.statuses) != 0 || len(slackClient.reactions) != 0 ||
		len(slackClient.removedReactions) != 0 {
		t.Fatalf("failed private replay produced public Slack side effects: %+v", slackClient)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("private replay failure = %+v, %v", stored, err)
	}
}

// Covers finding: 20260812T024151Z-run_8b5d9357162e2d7350a7c8dbb5290bc9
func TestPrivateSlackReplayBypassesStaleMessageCoalescing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID:         "slack_replay_old_message",
		EnvelopeID: "replay-private:slack_replay_old_message",
		EventID:    "replay-private:slack_replay_old_message",
		Kind:       "message", TeamID: cfg.Slack.TeamID, ChannelID: "CREPLAY",
		MessageTS: "1700.100", UserID: "U123ABC", Text: "could you please help?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit private replay = %t, %v", created, err)
	}
	newer := core.SlackInput{
		ID: "slack_newer_message", EnvelopeID: "env_newer_message",
		EventID: "event_newer_message", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: input.ChannelID,
		MessageTS: "1700.200", UserID: "U456DEF", Text: "newer channel message",
	}
	if created, err := st.AdmitSlackInput(ctx, newer); err != nil || !created {
		t.Fatalf("admit newer message = %t, %v", created, err)
	}
	if err := st.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ObjectID: newer.ID, Outcome: "ignored",
	}); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	run := core.AgentRun{ID: "run_private_replay", SourceID: input.ID}
	decided, err := svc.admitTriageRun(
		ctx, run, input, &decisionpkg.WatchTurnState{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if decided {
		t.Fatal("private replay was superseded by newer channel activity")
	}
}

func TestChangesCursorAndNavigationBindPagesToIncidentAndDigest(t *testing.T) {
	digest := strings.Repeat("a", 64)
	value := slackui.EncodeChangesCursor(slackui.ChangesCursor{
		IncidentID: "incident_123",
		Offset:     slackui.ChangesPatchPageBytes,
		Digest:     digest,
	})
	cursor, ok := slackui.DecodeChangesCursor(value)
	if !ok || cursor.IncidentID != "incident_123" ||
		cursor.Offset != slackui.ChangesPatchPageBytes || cursor.Digest != digest {
		t.Fatalf("cursor = %+v, %t", cursor, ok)
	}
	if _, ok := slackui.DecodeChangesCursor(value + "!"); ok {
		t.Fatal("malformed diff cursor was accepted")
	}
	navigation := slackui.NewChangesNavigation("incident_123", coop.Changes{
		PatchOffset: 7000, PatchNextOffset: 14000,
		PatchBytes: 15000, PatchHasMore: true, PatchDigest: digest,
	})
	if navigation.Page != 2 || navigation.Pages != 3 ||
		navigation.PreviousValue == "" || navigation.NextValue == "" ||
		navigation.RefreshValue == "" {
		t.Fatalf("navigation = %+v", navigation)
	}
	for _, action := range []struct {
		id    string
		value string
	}{
		{slackui.ActionChangesPrevious, navigation.PreviousValue},
		{slackui.ActionChangesNext, navigation.NextValue},
		{slackui.ActionChangesRefresh, navigation.RefreshValue},
	} {
		incidentID, ok := slackui.ActionIncidentID(action.id, action.value)
		if !ok || incidentID != "incident_123" {
			t.Fatalf("action %s incident = %q, %t", action.id, incidentID, ok)
		}
	}
}

func TestMixedCapacityBatchDispatchesAcceptedIncidentUpdate(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxOpenIncidents = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	existing := core.Signal{
		Route: "grafana", SourceID: "alert-1", EventID: "event-1",
		Repository: "repo", CorrelationKey: "existing", Status: core.SignalFiring,
		Title: "Existing incident", ReceivedAt: time.Now().UTC(),
	}
	incidents, err := st.ApplySignals(
		ctx, core.WebhookEvent{Signals: []core.Signal{existing}}, time.Hour, 0, 1,
	)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("existing incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "inc-existing"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	resolved := existing
	resolved.EventID = "event-resolved"
	resolved.Status = core.SignalResolved
	deferred := existing
	deferred.SourceID = "alert-2"
	deferred.EventID = "event-new"
	deferred.CorrelationKey = "new"
	if _, _, err := st.AdmitWebhook(
		ctx, "grafana", "delivery-mixed", "digest-mixed", []core.Signal{resolved, deferred},
	); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 1 || dirty[0].ID != incidents[0].ID {
		t.Fatalf("accepted incident card was not refreshed: %+v, %v", dirty, err)
	}
	updated, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil || updated.Status != core.IncidentMonitoring || updated.FiringCount != 0 {
		t.Fatalf("accepted incident was not updated: %+v, %v", updated, err)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil || metrics.WebhooksPending != 1 {
		t.Fatalf("deferred webhook was not retained: %+v, %v", metrics, err)
	}
}

func TestExplicitMentionRepliesOutsideConfiguredChannelsWithoutCreatingIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"COTHER"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-summon-question", EnvelopeID: "envelope-summon-question",
		EventID: "event-summon-question", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CUNCONFIGURED", MessageTS: "1700.000", UserID: "U123ABC",
		Text: "<@U999BOT> how is the health of our infrastructure?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	coopClient.completeOnSubmit = fmt.Sprintf(`{
	  "action":"reply",
	  "operations":[
	    {"id":"ev-change","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"the deployed revision matches the declared revision","observation":"The deployed revision matches the declared revision","relation":"supports","health_effect":"none","source_type":"repository","source_name":"infrastructure manifests","observed_at":%[1]q,"dimensions":{"repository":"repo","environment":"production","revision":"current"}}},
	    {"id":"ev-host","type":"record_evidence","evidence":{"claim_id":"host.current_state","claim":"the declared hosts are present and responsive","observation":"All declared hosts are connected","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar host inventory","observed_at":%[1]q,"dimensions":{"host":"all declared hosts","environment":"production"}}},
	    {"id":"ev-runtime","type":"record_evidence","evidence":{"claim_id":"runtime.current_state","claim":"the host runtimes are healthy","observation":"The host runtimes are responsive","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar runtime status","observed_at":%[1]q,"dimensions":{"runtime":"container runtime","host":"all declared hosts"}}},
	    {"id":"ev-workload","type":"record_evidence","evidence":{"claim_id":"workload.desired_state","claim":"the declared workloads run at desired capacity","observation":"All declared workloads are running","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar workload status","observed_at":%[1]q,"dimensions":{"service":"all declared services","workload":"all declared workloads","environment":"production"}}},
	    {"id":"ev-dependency","type":"record_evidence","evidence":{"claim_id":"dependency.current_health","claim":"the declared dependencies are available","observation":"Declared dependencies passed their checks","relation":"supports","health_effect":"none","source_type":"emisar","source_name":"Emisar dependency checks","observed_at":%[1]q,"dimensions":{"dependency":"declared dependencies","service":"all declared services","environment":"production"}}},
	    {"id":"ev-application","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"representative user paths work","observation":"Application probes are passing","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"application probes","observed_at":%[1]q,"dimensions":{"service":"all declared services","endpoint":"probe endpoints","environment":"production","measurement_kind":"functional_probe"}}},
	    {"id":"ev-broad-errors","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"broad error trend is healthy","observation":"No broad error increase is present","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"request metrics","observed_at":%[1]q,"dimensions":{"measurement_kind":"error_rate","measurement_scope":"broad","window":"10m","comparison_window":"previous 10m","population":"all requests","denominator":"all requests"}}},
	    {"id":"ev-broad-timeouts","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"broad timeout trend is healthy","observation":"No broad timeout increase is present","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"request metrics","observed_at":%[1]q,"dimensions":{"measurement_kind":"timeout_rate","measurement_scope":"broad","window":"10m","comparison_window":"previous 10m","population":"all requests","denominator":"all requests"}}},
	    {"id":"ev-service-errors","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"service error trend is healthy","observation":"No service error increase is present","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"service metrics","observed_at":%[1]q,"dimensions":{"measurement_kind":"error_rate","measurement_scope":"service","window":"10m","comparison_window":"previous 10m","population":"service requests","denominator":"service requests"}}},
	    {"id":"ev-service-timeouts","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"service timeout trend is healthy","observation":"No service timeout increase is present","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"service metrics","observed_at":%[1]q,"dimensions":{"measurement_kind":"timeout_rate","measurement_scope":"service","window":"10m","comparison_window":"previous 10m","population":"service requests","denominator":"service requests"}}},
	    {"id":"ev-impact","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"no active alert reports user impact","observation":"No SLO alerts are active","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"alert monitoring","observed_at":%[1]q,"dimensions":{"service":"all declared services","indicator":"active alerts","environment":"production","window":"current"}}},
	    {"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","source":"repository","detail":"The deployed revision matches the declared revision"}},
	    {"id":"cov-2","type":"record_coverage","coverage":{"layer":"host","claim_ids":["host.current_state"],"status":"healthy","source":"Emisar","detail":"All declared hosts are connected"}},
	    {"id":"cov-3","type":"record_coverage","coverage":{"layer":"runtime","claim_ids":["runtime.current_state"],"status":"healthy","source":"Emisar","detail":"The host runtimes are responsive"}},
	    {"id":"cov-4","type":"record_coverage","coverage":{"layer":"workload","claim_ids":["workload.desired_state"],"status":"healthy","source":"Emisar","detail":"All declared workloads are running"}},
	    {"id":"cov-5","type":"record_coverage","coverage":{"layer":"dependency","claim_ids":["dependency.current_health"],"status":"healthy","source":"Emisar","detail":"Declared dependencies passed their checks"}},
	    {"id":"cov-6","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"healthy","source":"monitoring","detail":"Application probes are passing"}},
	    {"id":"cov-7","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"healthy","source":"monitoring","detail":"No SLO alerts are active"}},
	    {"id":"complete","type":"complete_episode","completion":{
	      "message":"I checked current infrastructure state and found no active alerts.",
	      "completion":{"status":"decision_ready","verdict":"healthy","summary":"The checked production scope is healthy."}
	    }}
	  ]
	}`, observedAt)
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "no active alerts") {
		t.Fatalf("summon reply = %+v", slackClient.posts)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("summon question created incident = %+v, %v", incidents, err)
	}
	if len(coopClient.submitPrompts) != 1 ||
		!strings.Contains(coopClient.submitPrompts[0], `"mentions_responder":true`) {
		t.Fatalf("explicit mention did not use watched triage: %+v", coopClient.submitPrompts)
	}

	for name, threadTS := range map[string]string{
		"top-level continuation":    "",
		"thread started from reply": "1700.001",
	} {
		t.Run(name, func(t *testing.T) {
			admit, err := svc.shouldAdmitChannelMessage(ctx, core.SlackInput{
				Kind: "message", ChannelID: input.ChannelID,
				ThreadTS: threadTS, MessageTS: "1700.010", UserID: input.UserID,
				Text: "How were you able to verify that?",
			})
			if err != nil || !admit {
				t.Fatalf("continuation admission = %t, %v", admit, err)
			}
		})
	}
	if active, err := st.HasRecentWatchReply(
		ctx,
		input.ChannelID,
		"",
		"1700.010",
		time.Now().UTC().Add(time.Minute),
	); err != nil || active {
		t.Fatalf("expired continuation = %t, %v", active, err)
	}
	if active, err := st.HasRecentWatchReply(
		ctx,
		input.ChannelID,
		"",
		"1700.0005",
		time.Now().UTC().Add(-time.Minute),
	); err != nil || active {
		t.Fatalf("message preceding reply continuation = %t, %v", active, err)
	}

	followup := core.SlackInput{
		ID: "slack-summon-followup", EnvelopeID: "envelope-summon-followup",
		EventID: "event-summon-followup", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: input.ChannelID, MessageTS: "1700.010", UserID: input.UserID,
		Text: "How were you able to verify that?",
	}
	if created, err := st.AdmitSlackInput(ctx, followup); err != nil || !created {
		t.Fatalf("admit continuation = %v, %v", created, err)
	}
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"operations":[
			{"id":"complete","type":"complete_episode","completion":{
				"message":"I used the configured GitHub credentials and checked the current workflow run.",
				"completion":{"status":"decision_ready","summary":"Named the source used to verify the answer."}
			}}
		]
	}`
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 2 ||
		!strings.Contains(slackClient.posts[1].message.Text, "configured GitHub credentials") {
		t.Fatalf("continuation reply = %+v", slackClient.posts)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(
			coopClient.submitPrompts[1],
			`"conversation_continuation":true`,
		) {
		t.Fatalf("continuation prompt = %+v", coopClient.submitPrompts)
	}
}

func TestDurableSelfInviteRequestDoesNotCreateIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-invite-policy", EnvelopeID: "envelope-invite-policy",
		EventID: "event-invite-policy", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CSUMMON", MessageTS: "1700.000", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> when you create an incident channel always invite me into it",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	// Nothing was saved and nothing was created, so the room hears nothing. The
	// one operator who asked hears that they are already covered.
	if len(slackClient.posts) != 0 {
		t.Fatalf("a no-op answer was posted to the room = %+v", slackClient.posts)
	}
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "already included") ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "No incident was created") {
		t.Fatalf("self-invite response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("self-invite request created incident = %+v, %v", incidents, err)
	}
	if slackClient.createChannelCalls != 0 {
		t.Fatalf("self-invite request created %d Slack channels", slackClient.createChannelCalls)
	}
	if len(coopClient.submitPrompts) != 0 {
		t.Fatalf("self-invite request reached model: %+v", coopClient.submitPrompts)
	}
}

func TestManualSummonCompletesHandoffToIncidentRoom(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-manual-ready", EnvelopeID: "envelope-ready", EventID: "event-manual-ready",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CSUMMON",
		MessageTS: "1700.001", UserID: "U123ABC",
		Text: "<@U999BOT> open an incident for checkout",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	for count := 0; count < 4; count++ {
		err := svc.processSlackDelivery(ctx, nil)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	var handoff *slackPost
	for index := range slack.posts {
		if slack.posts[index].message.Header == "Incident room ready" {
			handoff = &slack.posts[index]
		}
	}
	if handoff == nil || handoff.channel != "CSUMMON" || handoff.thread != input.MessageTS ||
		!strings.Contains(handoff.message.Text, "<#CINCIDENT>") {
		t.Fatalf("manual handoff = %+v", slack.posts)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("manual incident = %+v, %v", incidents, err)
	}
	if err := svc.enqueueManualHandoff(ctx, incidents[0]); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("manual handoff was not idempotent: %v", err)
	}
}

func TestManualHandoffWaitsForUsableIncidentRoom(t *testing.T) {
	tests := []struct {
		name       string
		rootErr    error
		inviteErr  error
		wantRootTS bool
	}{
		{name: "root delivery uncertain", rootErr: errors.New("Slack timeout")},
		{name: "ryker invite fails", inviteErr: errors.New("invite denied"), wantRootTS: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			incident, created, err := st.CreateManualIncident(
				ctx, "repo", "manual-source", "Investigate checkout", "Investigate checkout", "U123ABC",
				"CSUMMON", "1700.001", cfg.Limits.MaxOpenIncidents,
			)
			if err != nil || !created {
				t.Fatalf("manual incident = %+v, %v, %v", incident, created, err)
			}
			slack := &fakeSlack{postErr: test.rootErr, inviteErr: test.inviteErr}
			svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
			if err := svc.processChannel(ctx); err != nil {
				t.Fatal(err)
			}
			if err := svc.processSlackDelivery(ctx, nil); err != nil {
				t.Fatal(err)
			}
			sessionErr := svc.processSession(ctx)
			if test.inviteErr != nil {
				if sessionErr == nil || !strings.Contains(sessionErr.Error(), test.inviteErr.Error()) {
					t.Fatalf("session preparation error = %v, want %v", sessionErr, test.inviteErr)
				}
			} else if sessionErr != nil && !errors.Is(sessionErr, store.ErrNotFound) {
				t.Fatal(sessionErr)
			}
			for _, post := range slack.posts {
				if post.message.Header == "Incident room ready" {
					t.Fatalf("handoff announced unusable room: %+v", slack.posts)
				}
			}
			incident, err = st.GetIncident(ctx, incident.ID)
			if err != nil || (incident.RootTS != "") != test.wantRootTS {
				t.Fatalf("root binding = %+v, %v", incident, err)
			}
			if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("handoff was queued before room preparation: %v", err)
			}
		})
	}
}

func TestIncidentScopedSchedulerFailureDoesNotBlockAnotherIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	createBound := func(sourceID, channelID, rootTS string) core.Incident {
		t.Helper()
		incident, created, err := st.CreateManualIncident(
			ctx,
			"repo",
			sourceID,
			"Investigate "+sourceID,
			"Investigate "+sourceID,
			"U123ABC",
			"CSOURCE",
			"1700.001",
			cfg.Limits.MaxOpenIncidents,
		)
		if err != nil || !created {
			t.Fatalf("create %s = %+v, %v, %v", sourceID, incident, created, err)
		}
		if err := st.SetChannel(ctx, incident.ID, channelID, "room-"+sourceID); err != nil {
			t.Fatal(err)
		}
		if err := st.SetRoot(ctx, incident.ID, rootTS); err != nil {
			t.Fatal(err)
		}
		incident, err = st.GetIncident(ctx, incident.ID)
		if err != nil {
			t.Fatal(err)
		}
		return incident
	}
	blocked := createBound("blocked", "CBLOCKED", "1700.101")
	healthy := createBound("healthy", "CHEALTHY", "1700.102")
	slack := &fakeSlack{inviteByChannel: map[string]error{
		blocked.ChannelID: errors.New("invite temporarily unavailable"),
	}}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	for priority, incident := range []core.Incident{blocked, healthy} {
		if err := st.EnsureWork(ctx, store.WorkItem{
			Kind: workIncidentSession, SubjectID: incident.ID,
			Lane:            store.WorkLaneBackground,
			ConversationKey: "incident:" + incident.ID,
			Priority:        10 + priority,
		}); err != nil {
			t.Fatal(err)
		}
	}
	first, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil || first.SubjectID != blocked.ID {
		t.Fatalf("first scheduled incident = %+v, %v", first, err)
	}
	svc.handleScheduledWork(ctx, first)
	second, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil || second.SubjectID != healthy.ID {
		t.Fatalf("second scheduled incident = %+v, %v", second, err)
	}
	svc.handleScheduledWork(ctx, second)
	blocked, err = st.GetIncident(ctx, blocked.ID)
	if err != nil || blocked.CoopSessionID != "" ||
		blocked.Workflow != core.WorkflowHolding {
		t.Fatalf("blocked incident = %+v, %v", blocked, err)
	}
	healthy, err = st.GetIncident(ctx, healthy.ID)
	if err != nil || healthy.CoopSessionID == "" {
		t.Fatalf("unrelated incident did not progress = %+v, %v", healthy, err)
	}
	metrics, err := st.WorkMetrics(ctx, store.WorkLaneBackground)
	if err != nil || metrics.Pending != 1 || metrics.Running != 0 {
		t.Fatalf("per-incident retry queue = %+v, %v", metrics, err)
	}
}

func TestIncidentSubthreadKeepsProgressOnTheSourceConversation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-subthread-reply", EnvelopeID: "envelope-subthread-reply",
		EventID: "event-subthread-reply", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, ThreadTS: "1700.777", MessageTS: "1700.778",
		UserID: "U123ABC", Text: "<@U999BOT> Check this follow-up in depth.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack subthread reply = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slack,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.identity = slackui.Identity{
		TeamID:    cfg.Slack.TeamID,
		BotUserID: "U999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 1 || slack.statuses[0].thread != input.ThreadTS ||
		slack.statuses[0].text != "is investigating..." {
		t.Fatalf("accepted subthread status = %+v", slack.statuses)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 1 || slack.statuses[0].thread != input.ThreadTS ||
		slack.statuses[0].text != "is investigating..." {
		t.Fatalf("running subthread replaced the pending status: %+v", slack.statuses)
	}
}

func TestIncidentConversationAcceptsMessagesWithoutMentions(t *testing.T) {
	tests := []struct {
		name       string
		kind       string
		threadTS   string
		text       string
		wantPolicy string
		wantText   string
	}{
		{
			name: "pinned card reply", kind: "message", threadTS: "1700.001",
			text: "What should we do next?", wantPolicy: "directly addresses",
			wantText: "What should we do next?",
		},
		{
			name: "top level without mention", kind: "message",
			text: "The deploy finished; anything else?", wantPolicy: "ambient room conversation",
			wantText: "The deploy finished; anything else?",
		},
		{
			name: "top level mention", kind: "mention",
			text: "<@U999BOT> Are you following this?", wantPolicy: "directly addresses",
			wantText: "Are you following this?",
		},
		{
			name: "another conversation thread", kind: "message", threadTS: "1700.900",
			text: "I think the database is healthy.", wantPolicy: "ambient room conversation",
			wantText: "I think the database is healthy.",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			incident := createBoundIncident(t, ctx, st)
			if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
				t.Fatal(err)
			}
			input := core.SlackInput{
				ID: "slack-conversation", EnvelopeID: "envelope-conversation",
				EventID: "event-conversation", Kind: test.kind, TeamID: cfg.Slack.TeamID,
				ChannelID: incident.ChannelID, ThreadTS: test.threadTS, MessageTS: "1700.901",
				UserID: "U123ABC", Text: test.text,
			}
			if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
				t.Fatalf("admit conversation = %v, %v", created, err)
			}
			svc := New(
				cfg, st, newFakeCoop(), &fakeSlack{}, nil,
				slackui.NewSanitizer(12000), nil,
			)
			svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			submission, err := st.GetAgentRunBySource(ctx, "slack", input.ID)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(submission.Prompt, test.wantPolicy) ||
				!strings.Contains(submission.Prompt, test.wantText) ||
				strings.Contains(submission.Prompt, "<@U999BOT>") {
				t.Fatalf("conversation prompt = %q", submission.Prompt)
			}
		})
	}
}

func TestConversationReplyReturnsToOriginWithoutIncidentChrome(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-top-level", EnvelopeID: "envelope-top-level", EventID: "event-top-level",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		MessageTS: "1700.500", UserID: "U123ABC", Text: "What's next?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit top-level message = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	coopClient.complete("The inspection is complete. Close the incident unless another gate should run.")
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != incident.RootTS ||
		slack.posts[0].message.Header != "" || len(slack.posts[0].message.Context) != 0 ||
		!strings.Contains(slack.posts[0].message.Text, "inspection is complete") {
		t.Fatalf("conversation reply = %+v", slack.posts)
	}
}

func TestDeletedChannelEventBlocksIncidentAndSuppressesSlackDelivery(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetSlackSetting(
		ctx,
		"channel",
		incident.ChannelID,
		"proactive",
		"on",
		"U123ABC",
	); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, socket,
		slackui.NewSanitizer(12000), nil,
	)
	payload, _ := json.Marshal(map[string]any{"event_id": "EvDeleted"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.ChannelDeletedEvent{
					Type: "channel_deleted", Channel: incident.ChannelID,
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-deleted", Payload: payload},
	})
	if socket.acks != 1 {
		t.Fatalf("deletion event acknowledgements = %d", socket.acks)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelDeleted ||
		incident.Workflow != core.WorkflowBlocked ||
		!strings.Contains(incident.LastError, "room was deleted") {
		t.Fatalf("deleted incident = %+v", incident)
	}
	if _, err := st.GetSlackSetting(
		ctx,
		"channel",
		incident.ChannelID,
		"proactive",
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("deleted channel retained its Slack override: %v", err)
	}
	if err := svc.enqueue(
		ctx, "out-after-delete", incident, "notice", incident.RootTS,
		slackui.Notice("This must not be posted."),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("deleted room received posts: %+v", slackClient.posts)
	}
	failures, err := st.ListFailedWork(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	var suppressed bool
	for _, failure := range failures {
		if failure.ID == "out-after-delete" &&
			strings.Contains(failure.LastError, "delivery suppressed") {
			suppressed = true
		}
	}
	if !suppressed {
		t.Fatalf("suppressed delivery was not retained as failed work: %+v", failures)
	}
}

func TestIncidentChannelReconciliationDistinguishesArchiveAndUnreachable(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{
		channel: slackui.Channel{ID: incident.ChannelID, Name: incident.ChannelName, Archived: true},
	}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelArchived {
		t.Fatalf("archived reconciliation = %+v, %v", incident, err)
	}
	slackClient.channel.Archived = false
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelActive {
		t.Fatalf("active reconciliation = %+v, %v", incident, err)
	}
	slackClient.channel = slackui.Channel{}
	slackClient.channelErr = slackui.ErrNotFound
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelUnreachable ||
		incident.ChannelState == core.ChannelDeleted {
		t.Fatalf("unreachable reconciliation = %+v, %v", incident, err)
	}
}

func TestThePostmortemButtonReadsTheLatestClosedIncidentRecord(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incidents, err := st.ApplySignals(ctx, core.WebhookEvent{
		Route: "grafana", DedupeKey: "postmortem-delivery", BodyDigest: "digest",
		Signals: []core.Signal{{
			Route: "grafana", SourceID: "alert-postmortem", EventID: "alert-event",
			Repository: "emisar", CorrelationKey: "api", Status: core.SignalFiring,
			Title: "API errors", Severity: "high", ReceivedAt: time.Now().UTC(),
		}},
	}, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CPOSTMORTEM", "ems-api"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: incident.ID, ChannelID: "CPOSTMORTEM", SourceInput: "run_1",
		Claim: "API recovered", Observation: "Probe returned HTTP 200",
		SourceType: "emisar", SourceName: "http probe", Target: "api",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}

	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "record-postmortem", EnvelopeID: "env-record-postmortem",
		EventID: "event-record-postmortem", Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: "CPOSTMORTEM", UserID: "U123ABC",
		ActionID: slackui.ActionRecordPostmortem, ActionValue: incident.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit command = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("postmortem responses = %+v", slackClient.ephemerals)
	}
	// A short record belongs in the private reply itself. Canvas is reserved for
	// records that cannot fit, so this one must expose the evidence immediately.
	if len(slackClient.canvases) != 0 {
		t.Fatalf("short postmortem was needlessly moved to Canvas: %+v", slackClient.canvases)
	}
	message := slackClient.ephemerals[0].message
	rendered := renderedSlackMessage(message)
	if !strings.Contains(rendered, "API recovered") ||
		!strings.Contains(rendered, "Confirm root cause from cited evidence") ||
		strings.Contains(rendered, "Root cause:") || strings.Contains(rendered, "Still open") {
		t.Fatalf("postmortem card = %+v", message)
	}
}

func TestSlashStatusExplainsIncidentRoomBehavior(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slash-incident-status", EnvelopeID: "env-incident-status",
		EventID: "event-incident-status", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, UserID: "U123ABC", Text: "status",
		ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("ephemeral status count = %d", len(slackClient.ephemerals))
	}
	message := slackClient.ephemerals[0].message
	sections := strings.Join(message.Sections, "\n")
	for _, required := range []string{
		"Incident collaboration remains active regardless of proactive triage",
		"without an `@mention`",
		"Attached incident `" + slackui.ShortID(incident.ID) + "`",
		"Reply normally anywhere in this incident channel",
	} {
		if !strings.Contains(sections, required) {
			t.Fatalf("incident status lacks %q: %+v", required, message)
		}
	}
	for _, internal := range []string{"parked", "provisioning_channel", "ryker.yaml"} {
		if strings.Contains(message.Text+"\n"+sections, internal) {
			t.Fatalf("incident status exposes internal label %q: %+v", internal, message)
		}
	}
}
func TestClosedIncidentControlsResolveByIDAndHideWithoutChanges(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-read-only", 1,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processCard(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.updates) != 1 ||
		len(slackClient.updates[0].message.Actions) != 0 {
		t.Fatalf("unchanged closed card controls = %+v", slackClient.updates)
	}
	runAction := func(id, actionID string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
			MessageTS: incident.RootTS, UserID: "U123ABC",
			ActionID: actionID, ActionValue: incident.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		drainSlackDeliveries(t, ctx, svc)
	}
	runAction("closed-changes", slackui.ActionChanges)
	if got := slackClient.posts[len(slackClient.posts)-1].message; !strings.Contains(
		got.Text+"\n"+strings.Join(got.Sections, "\n"),
		"no changes",
	) {
		t.Fatalf("closed changes response = %+v", got)
	}
	// "There is nothing to review" answers the operator who pressed Review. The
	// room is not told that a button did nothing.
	posted := len(slackClient.posts)
	runAction("closed-review", slackui.ActionReview)
	if len(slackClient.posts) != posted {
		t.Fatalf("a review refusal was posted to the room = %+v", slackClient.posts[posted:])
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("closed review response = %+v", slackClient.ephemerals)
	}
	if got := slackClient.ephemerals[0].message; !strings.Contains(
		renderedSlackMessage(got), "no proposed code change",
	) {
		t.Fatalf("closed review response = %+v", got)
	}
}

func TestIncidentControlMatchesDeliveredResultMessage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	message := slackui.Message{
		Text: "The requested change is ready.",
		Actions: []slackui.Action{{
			ID: slackui.ActionChanges, Label: "View diff", Value: incident.ID,
		}},
	}
	body, err := slackui.Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_result_with_controls", IncidentID: incident.ID,
		Kind: "assistant", ChannelID: incident.ChannelID,
		ThreadTS: incident.ConversationThreadTS(), Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(
		ctx,
		delivery.ID,
		"1700.900",
		"sending",
	); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		Kind: "action", ChannelID: incident.ChannelID,
		ThreadTS: incident.ConversationThreadTS(), MessageTS: "1700.900",
		ActionID: slackui.ActionChanges, ActionValue: incident.ID,
	}
	matches, err := svc.incidentControlMatchesMessage(ctx, input, incident)
	if err != nil || !matches {
		t.Fatalf("delivered result control = %t, %v", matches, err)
	}
	input.ActionID = slackui.ActionPublishPR
	matches, err = svc.incidentControlMatchesMessage(ctx, input, incident)
	if err != nil || matches {
		t.Fatalf("undelivered result control = %t, %v", matches, err)
	}
	input.ActionID = slackui.ActionChanges
	input.MessageTS = "1700.999"
	matches, err = svc.incidentControlMatchesMessage(ctx, input, incident)
	if err != nil || matches {
		t.Fatalf("wrong result message control = %t, %v", matches, err)
	}
}

func TestIncidentControlMatchesMessageEmbeddedInDeliveredVisual(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	message := slackui.Message{Text: "The requested change and chart are ready.", Actions: []slackui.Action{{
		ID: slackui.ActionChanges, Label: "View diff", Value: incident.ID,
	}}}
	data := []byte("\x89PNG\r\n\x1a\nchart")
	digest := sha256.Sum256(data)
	body, err := json.Marshal(slackfile.Delivery{
		Filename: "result.png", Title: "Result", AltText: "Result chart",
		MediaType: "image/png", SHA256: hex.EncodeToString(digest[:]), Data: data, Message: &message,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_visual_result_with_controls", IncidentID: incident.ID,
		Operation: "file", Kind: "generated_visual", ChannelID: incident.ChannelID,
		ThreadTS: incident.ConversationThreadTS(), Body: body, ResponseRoot: true,
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, delivery.ID, "1700.950", "sending"); err != nil {
		t.Fatal(err)
	}
	matches, err := svc.incidentControlMatchesMessage(ctx, core.SlackInput{
		Kind: "action", ChannelID: incident.ChannelID,
		ThreadTS: incident.ConversationThreadTS(), MessageTS: "1700.950",
		ActionID: slackui.ActionChanges, ActionValue: incident.ID,
	}, incident)
	if err != nil || !matches {
		t.Fatalf("visual result control = %t, %v", matches, err)
	}
}

func TestErroredAppRunIsInvestigatedInPlaceWithoutPolicyBoilerplate(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CWATCH", Participation: "proactive", Repository: "repo",
		AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}

	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"incident","title":"Terraform apply run-R1FRs9QFdGmTbBUx errored after destructive changes began","reason":"A credible terminal apply failure may have left partial changes."}`,
		`{"action":"reply","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},"operations":[` +
			`{"id":"ev-1","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"the apply failed after partial changes","observation":"HCP Terraform reports the run errored after five bucket deletions while the runner replacement remained incomplete","relation":"contradicts","health_effect":"unhealthy","source_type":"monitoring","source_name":"HCP Terraform run run-R1FRs9QFdGmTbBUx"}},` +
			`{"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"unhealthy","source":"HCP Terraform","detail":"the apply reached a terminal error after partial destructive changes"}},` +
			`{"id":"finding-apply-failed","type":"record_finding","finding":{"key":"terraform-apply-partial-failure","what":"The Terraform apply failed after partial destructive changes","scope":"SME-Blitz/blitz-infra production apply","status":"explained","cause_evidence":["ev-1"],"alternatives":[{"hypothesis":"The apply is still progressing toward success","claim_id":"change.recent","discriminated_by":"ev-1"}]}},` +
			`{"id":"complete","type":"complete_episode","completion":{"message":"**Apply failed after changes had started.** Five storage buckets and their IAM bindings were deleted before Terraform stopped; the runner replacement did not finish. Check the terminal Terraform error, restore any unintended deletions, then run a fresh plan and verify the runner before applying again.","completion":{"status":"decision_ready","verdict":"failed","summary":"The apply failed after partial destructive changes and needs reconciliation before retrying."}}}` +
			`]}`,
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-terraform-errored", EnvelopeID: "env-terraform-errored",
		EventID: "EvTerraformErrored", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1785762915.000", UserID: "BTERRAFORM",
		Text: "Run notification for SME-Blitz/blitz-infra\nRun run-R1FRs9QFdGmTbBUx\n" +
			"Triggered via CLI\nRun Errored",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	finishQueuedAgentRun(t, ctx, svc)
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	// Failures stays 0: a correction round is not a failed attempt.
	if err != nil || run.State != core.AgentRunPending || run.Failures != 0 ||
		!strings.Contains(run.LastError, "evidence-backed in-place alert assessment") {
		t.Fatalf("incident-only result was not corrected = %+v, %v", run, err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("premature alert result reached Slack: %+v", slackClient.posts)
	}

	finishQueuedAgentRun(t, ctx, svc)
	run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted {
		t.Fatalf("completed alert investigation = %+v, %v", run, err)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("Slack posts = %+v", slackClient.posts)
	}
	text := strings.ToLower(slackClient.posts[0].message.Text)
	for _, required := range []string{"apply failed", "five storage buckets", "fresh plan"} {
		if !strings.Contains(text, required) {
			t.Fatalf("useful alert result missing %q: %+v", required, slackClient.posts[0])
		}
	}
	for _, boilerplate := range []string{
		"no incident", "channel is configured", "without offering", "opening one creates",
	} {
		if strings.Contains(text, boilerplate) {
			t.Fatalf("alert result leaked policy boilerplate %q: %+v", boilerplate, slackClient.posts[0])
		}
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 0 {
		t.Fatalf("in-place alert created incidents = %+v, %v", incidents, err)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[0], "Do not explain or disclose this setting") ||
		!strings.Contains(coopClient.submitPrompts[1], "evidence-backed in-place alert assessment") {
		t.Fatalf("alert correction prompts = %v", coopClient.submitPrompts)
	}
}

func TestIncidentCompoundReportPostsOrderedMessagesBeforeFinalEvidenceCard(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_compound_incident", "incident-compound", 1,
	); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "signal", SourceID: "signal-compound",
		Repository: incident.Repository, Prompt: "check host, workload, and dependency",
	})
	if err != nil || !created {
		t.Fatalf("queue incident run = %+v, %t, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx, leased.ID, "ses_compound_incident", 0, incident.Repository, 0, leased.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leased.ID, "turn_compound", 2, 0); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx,
		leased.ID,
		"completed",
		[]byte(`{
			"message":"**Host:** both nodes are responsive.",
			"followup_messages":[
				"**Workload:** all expected allocations are running.",
				"**Dependency:** database latency remains unverified."
			],
			"evidence":[{"claim":"hosts respond","observation":"two host checks passed","source_type":"emisar","source_name":"host check"}],
			"coverage":[{"layer":"host","status":"healthy","source":"host check","detail":"both nodes responded"}],
			"memory":{}
		}`),
		"",
		0,
	); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{dedupePosts: true}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 3 {
		t.Fatalf("compound incident posts = %+v", slackClient.posts)
	}
	for index, expected := range []string{"Host", "Workload", "Dependency"} {
		post := slackClient.posts[index]
		if post.channel != incident.ChannelID || post.thread != incident.RootTS ||
			!strings.Contains(post.message.Text, expected) {
			t.Fatalf("compound incident delivery = %+v", slackClient.posts)
		}
	}
	if !strings.Contains(
		strings.Join(slackClient.posts[2].message.Context, "\n"),
		"Details saved",
	) {
		t.Fatalf("final compound incident evidence = %+v", slackClient.posts[2])
	}
}

func TestExplicitIncidentRequestRecognition(t *testing.T) {
	for _, input := range []string{
		"Open an incident for this failure",
		"please create incident for checkout",
		"Declare the incident now",
		"turn this into an incident",
	} {
		if !explicitIncidentRequest(input) {
			t.Fatalf("explicit request was not recognized: %q", input)
		}
	}
	for _, input := range []string{
		"How healthy is production?",
		"This looks like an incident",
		"Should we open one?",
		"Investigate the disconnected runners",
		"When you create an incident channel always invite me into it",
		"Always create an incident for critical alerts",
	} {
		if explicitIncidentRequest(input) {
			t.Fatalf("ordinary conversation was treated as explicit: %q", input)
		}
	}
}
