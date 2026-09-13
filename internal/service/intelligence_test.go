package service

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/sessioncreate"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestWatchedStructuredReportPersistsEvidenceCoverageAndMemory(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		  "action":"reply",
		  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		  "reason":"The operator asked Ryker for a health assessment.",
	  "operations":[
	    {"id":"declared-capacity","type":"record_evidence","evidence":{
	      "claim_id":"scheduler.desired_state",
	      "claim":"Expected production capacity is two instances",
	      "observation":"infra/main.tf sets target_size to 2",
	      "source_type":"repository",
	      "source_name":"infra/main.tf",
	      "source_url":"https://example.test/repo/blob/main/infra/main.tf?token=secret",
	      "target":"production-mig",
	      "confidence":"high"
	    }},
	    {"id":"cov-scheduler","type":"record_coverage","coverage":{
	      "layer":"scheduler",
	      "status":"unknown",
	      "detail":"No authorized Nomad observation was available"
	    }},
	    {"id":"mem","type":"update_memory","memory":{
	      "goal":"Assess production health",
	      "topology":["Two declared production instances"],
	      "unresolved_questions":["Nomad allocation state"]
	    }},
	    {"id":"complete","type":"complete_episode","completion":{
	      "message":"**Current assessment:** declared capacity is two instances; scheduler state remains unknown."
	    }}
	  ]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-structured", EnvelopeID: "env-structured",
		EventID: "event-structured", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.900", UserID: "U123ABC",
		Text: "How healthy is production?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		strings.Contains(slackClient.posts[0].message.Markdown, "## Evidence") ||
		strings.Contains(slackClient.posts[0].message.Markdown, "## Coverage") ||
		len(slackClient.posts[0].message.Context) != 1 ||
		slackClient.posts[0].message.Context[0] !=
			"Details saved: 1 evidence record, 1 system area, and 2 memory changes." {
		t.Fatalf("structured response = %+v", slackClient.posts)
	}
	evidence, err := st.Intelligence.ListEvidence(ctx, "", input.ChannelID, 10)
	if err != nil || len(evidence) != 1 ||
		evidence[0].SourceURL != "https://example.test/repo/blob/main/infra/main.tf" {
		t.Fatalf("evidence = %+v, %v", evidence, err)
	}
	coverage, err := st.Intelligence.ListCoverage(ctx, "", input.ChannelID, 10)
	if err != nil || len(coverage) != 1 || coverage[0].Status != "unknown" {
		t.Fatalf("coverage = %+v, %v", coverage, err)
	}
	// The channel's memory keeps what describes the channel and drops the
	// goal, which belongs to the thread that pursues it rather than to the
	// room the thread is in.
	memory, err := st.Intelligence.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || memory.TurnCount != 1 ||
		memory.State.Goal != "" ||
		len(memory.State.Topology) != 1 {
		t.Fatalf("memory = %+v, %v", memory, err)
	}
}

func TestWatchedShadowModeRecordsWithoutPosting(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.ShadowChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "reason":"A direct operational question was asked.",
	  "operations":[
	    {"id":"api-workload","type":"record_evidence","evidence":{
	      "claim_id":"application.functional_behavior",
	      "claim":"One workload is unhealthy",
	      "observation":"The live status is failed",
	      "source_type":"emisar",
	      "source_name":"status",
	      "target":"job/api"
	    }},
	    {"id":"cov-change","type":"record_coverage","coverage":{"layer":"change","status":"unknown","detail":"No deployment source was available"}},
	    {"id":"cov-host","type":"record_coverage","coverage":{"layer":"host","status":"unknown","detail":"No host source was available"}},
	    {"id":"cov-runtime","type":"record_coverage","coverage":{"layer":"runtime","status":"unknown","detail":"No runtime source was available"}},
	    {"id":"cov-workload","type":"record_coverage","coverage":{"layer":"workload","status":"unhealthy","source":"status","detail":"The API workload is failed"}},
	    {"id":"cov-dependency","type":"record_coverage","coverage":{"layer":"dependency","status":"unknown","detail":"No dependency source was available"}},
	    {"id":"cov-application","type":"record_coverage","coverage":{"layer":"application","status":"degraded","source":"status","detail":"The API workload cannot serve normally"}},
	    {"id":"cov-slo","type":"record_coverage","coverage":{"layer":"slo","status":"unknown","detail":"No SLO source was available"}},
	    {"id":"complete","type":"complete_episode","completion":{
	      "message":"Production is degraded.",
	      "completion":{"status":"blocked","summary":"Production is degraded but impact is not fully bounded.","material_gaps":["host, dependency, and SLO evidence"],"blocker_kind":"source_unavailable","attempts":["The configured live status source exposed the workload failure but no host, dependency, or SLO telemetry"],"next_action":"Connect an authoritative host and SLO telemetry source, then rerun the assessment"}
	    }}
	  ]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-shadow", EnvelopeID: "env-shadow", EventID: "event-shadow",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.901", UserID: "U123ABC", Text: "Is production healthy?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 0 {
		t.Fatalf("shadow mode posted: %+v", slackClient.posts)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" {
		t.Fatalf("shadow input = %+v, %v", stored, err)
	}
	evidence, err := st.Intelligence.ListEvidence(ctx, "", input.ChannelID, 10)
	if err != nil || len(evidence) != 1 {
		t.Fatalf("shadow evidence = %+v, %v", evidence, err)
	}
}

// A production replay of an alert finished its model turn and then waited
// forever: --publish had inherited the channel's observe-only setting, so no
// delivery could ever satisfy the replay command's publish contract.
func TestExplicitPublicReplayPublishesFromAShadowChannel(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.ShadowChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":1,"ownership":3,"contribution":"decision","material":true},
	  "reason":"The explicit production replay requested a published answer.",
	  "operations":[
	    {"id":"declared-capacity","type":"record_evidence","evidence":{
	      "claim_id":"scheduler.desired_state",
	      "claim":"Expected production capacity is two instances",
	      "observation":"infra/main.tf sets target_size to 2",
	      "source_type":"repository",
	      "source_name":"infra/main.tf",
	      "target":"production-mig",
	      "confidence":"high"
	    }},
	    {"id":"cov-scheduler","type":"record_coverage","coverage":{
	      "layer":"scheduler",
	      "status":"unknown",
	      "detail":"No authorized scheduler observation was available"
	    }},
	    {"id":"complete","type":"complete_episode","completion":{
	      "message":"Declared capacity is two instances; scheduler state remains unknown."
	    }}
	  ]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-public-replay", EnvelopeID: "replay-public:slack-public-replay",
		EventID: "replay-public:slack-public-replay", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", ThreadTS: "1700.910",
		MessageTS: "1700.911", UserID: "U123ABC", Text: "<@U999BOT> verify production.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	decision, err := st.Intelligence.GetEvaluationDecision(ctx, input.ID, "live")
	if err != nil || decision.Action != "reply" {
		t.Fatalf("public replay decision = %+v, %v", decision, err)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("explicit public replay posts = %+v", slackClient.posts)
	}
	if slackClient.posts[0].thread != input.ThreadTS {
		t.Fatalf("public replay thread = %q, want %q", slackClient.posts[0].thread, input.ThreadTS)
	}
}

// A published replay of a Grafana alert failed before any model turn on
// 2026-08-20. The alert thread already owned an engineering task, so the bot
// replay was mistaken for a task collaborator and Slack rejected the bot ID
// with user_not_found instead of rerunning the investigation.
func TestExplicitBotReplayInvestigatesEvenWhenItsThreadOwnsATask(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, created, createErr := st.CreateEngineeringTask(
		ctx, "repo", "source-task", "Fix the earlier alert", "", "UOPERATOR",
		"CWATCH", "1700.921", 10,
	); createErr != nil || !created {
		t.Fatalf("create task = %t, %v", created, createErr)
	}
	slackClient := &fakeSlack{deniedUsers: map[string]bool{"BGRAFANA": true}}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "attention":{"addressee":"channel","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"new_evidence","material":true},
	  "reason":"The explicit bot replay requested a fresh investigation.",
	  "operations":[
	    {"id":"runtime","type":"record_evidence","evidence":{
	      "claim_id":"workload.desired_state",
	      "claim":"The current workload state is known",
	      "observation":"The workload is running now",
	      "source_type":"monitoring",
	      "source_name":"runtime status",
	      "target":"production workload",
	      "confidence":"high"
	    }},
	    {"id":"coverage","type":"record_coverage","coverage":{
	      "layer":"workload",
	      "status":"healthy",
	      "detail":"The current workload was checked"
	    }},
	    {"id":"complete","type":"complete_episode","completion":{
	      "message":"The current workload is running."
	    }}
	  ]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-public-bot-replay", EnvelopeID: "replay-public:slack-public-bot-replay",
		EventID: "replay-public:slack-public-bot-replay", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", MessageTS: "1700.921",
		UserID: "BGRAFANA", Text: "External application status needs verification.",
	}
	if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
		t.Fatalf("admit = %v, %v", created, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("explicit bot replay posts = %+v", slackClient.posts)
	}
	if slackClient.posts[0].thread != input.MessageTS {
		t.Fatalf("bot replay thread = %q, want %q", slackClient.posts[0].thread, input.MessageTS)
	}
}

func TestWatchSessionRotatesAndCarriesDurableMemory(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.WatchSessionTurns = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.openAfterCreateKey = "ryker:watch-session:CWATCH:2"
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, session, err := svc.ensureWatchSession(ctx, "CWATCH")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AdvanceChannelMemory(ctx, "CWATCH", session.Revision+1, core.AgentMemory{
		Goal: "Track production health",
		Topology: []string{
			"Two declared instances",
		},
	}); err != nil {
		t.Fatal(err)
	}
	coopClient.session.State = "open"
	rotated, _, err := svc.ensureWatchSession(ctx, "CWATCH")
	if err != nil {
		t.Fatal(err)
	}
	if memory.Generation != 1 || rotated.Generation != 2 ||
		rotated.State.Goal != "Track production health" ||
		len(coopClient.createKeys) != 2 ||
		coopClient.createKeys[0] != "ryker:watch-session:CWATCH" ||
		coopClient.createKeys[1] != "ryker:watch-session:CWATCH:2" {
		t.Fatalf(
			"rotation = before=%+v after=%+v keys=%v",
			memory, rotated, coopClient.createKeys,
		)
	}
	cleanup, err := st.NextCleanup(ctx, time.Now().UTC())
	if err != nil || cleanup.SessionID != session.ID {
		t.Fatalf("rotated session was not immediately eligible for cleanup: %+v, %v", cleanup, err)
	}
}

// Five later alerts replayed the same terminal Coop create operations and one
// run spent all 20 attempts without starting. A failed generation therefore
// belongs to channel memory, not only to the run that happened to discover it.
// Covers: TestFailedWatchSessionGenerationSurvivesTheRunThatDiscoveredIt
func TestFailedWatchSessionCreateAdvancesDurableGeneration(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.createErrors = []error{&coop.APIError{
		Status: 500, Code: "internal_error", Detail: "workspace creation failed",
	}}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if _, _, err := svc.ensureWatchSessionAtGeneration(
		ctx, "CWATCH", 1,
	); err == nil {
		t.Fatal("first watch session creation unexpectedly succeeded")
	}
	failed, err := st.Intelligence.GetChannelMemory(ctx, "CWATCH")
	if err != nil {
		t.Fatal(err)
	}
	if failed.SessionID != "" || failed.Generation != 2 {
		t.Fatalf("failed watch generation was not durable: %+v", failed)
	}
	// A separate caller supplies only the normal minimum. It must recover the
	// advanced generation from shared channel memory rather than being told 2.
	if _, _, err := svc.ensureWatchSessionAtGeneration(ctx, "CWATCH", 1); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"ryker:watch-session:CWATCH",
		"ryker:watch-session:CWATCH:2",
	}
	if !slices.Equal(coopClient.createKeys, want) {
		t.Fatalf("watch session create keys = %v, want %v", coopClient.createKeys, want)
	}
}

// A Grafana alert was accepted, then every one of its twenty preparation
// attempts met Coop's retryable internal_error before a model turn existed.
// Ambient bot traffic deliberately has no terminal-failure post, so spending
// the ordinary attempt budget here silently discarded the whole stream.
// Covers: TestRetryableCoopPreparationExhaustionStaysQueued
func TestAcceptedWatchRunSurvivesExhaustedCoopSessionCreationOutage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 20
	cfg.Slack.WatchChannels = []string{"CALERTS"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	coopClient := newFakeCoop()
	for range cfg.Limits.MaxAgentRunAttempts {
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 500, Code: "internal_error",
			Detail: "operation op_secret failed while refreshing /Users/private/blitz-core",
		})
	}
	coopClient.completeOnSubmit = `{"action":"ignore"}`
	slack := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B_GRAFANA",
	}
	clock := useTestClock(svc, st)
	input := core.SlackInput{
		ID: "slack-grafana-create-outage", EnvelopeID: "env-grafana-create-outage",
		EventID: "EvGrafanaCreateOutage", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CALERTS", MessageTS: "1700.950", UserID: "B_GRAFANA",
		Text: "FIRING: scrape target nats-metrics is down",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit alert = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	for range cfg.Limits.MaxAgentRunAttempts {
		if err := svc.processAgentRun(ctx); err != nil {
			t.Fatal(err)
		}
		clock.Advance(time.Hour)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.TerminalState != "" || run.State != core.AgentRunPending || run.Failures != 0 {
		t.Fatalf(
			"accepted alert was abandoned during Coop outage: state=%q terminal=%q failures=%d error=%q",
			run.State, run.TerminalState, run.Failures, run.LastError,
		)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].channel != input.ChannelID ||
		slack.posts[0].thread != input.MessageTS {
		t.Fatalf("retryable preparation notice = %+v", slack.posts)
	}
	rendered := renderedSlackMessage(slack.posts[0].message)
	for _, want := range []string{
		"Investigation queued", "keep retrying this investigation automatically",
	} {
		if !strings.Contains(rendered, want) {
			t.Fatalf("preparation notice lacks %q: %q", want, rendered)
		}
	}
	for _, secret := range []string{"op_secret", "/Users/private", "internal operation"} {
		if strings.Contains(rendered, secret) {
			t.Fatalf("preparation notice leaked %q: %q", secret, rendered)
		}
	}

	// Coop is healthy again. The exact accepted run, not a replacement Slack
	// event, now gets its first model turn and reaches a normal completion.
	finishQueuedAgentRun(t, ctx, svc)
	run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted ||
		run.TerminalState != string(core.AgentRunCompleted) {
		t.Fatalf("preserved alert did not recover = %+v, %v", run, err)
	}
}

// A bounded human conversation uses a different session table from an alert,
// but session creation is still preparation. Twenty retryable Coop failures
// previously spent all twenty model attempts before any turn existed.
func TestAcceptedConversationRunSurvivesExhaustedCoopSessionCreationOutage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 20
	cfg.Slack.WatchChannels = []string{"CCONVERSATION"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	for range cfg.Limits.MaxAgentRunAttempts {
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 500, Code: "internal_error", Detail: "conversation workspace unavailable",
		})
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	clock := useTestClock(svc, st)
	input := core.SlackInput{
		ID: "slack-conversation-create-outage", EnvelopeID: "env-conversation-outage",
		EventID: "EvConversationOutage", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CCONVERSATION", MessageTS: "1700.951", UserID: "U123ABC",
		Text: "Can you keep looking into this here?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit conversation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetAgentRunContext(ctx, run.ID, []byte(`{"conversation_followup":true}`)); err != nil {
		t.Fatal(err)
	}
	for range cfg.Limits.MaxAgentRunAttempts {
		if err := svc.processAgentRun(ctx); err != nil {
			t.Fatal(err)
		}
		clock.Advance(time.Hour)
	}
	run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunPending || run.TerminalState != "" ||
		run.Failures != 0 || len(coopClient.submitSessions) != 0 {
		t.Fatalf("conversation preparation spent accepted work: run=%+v submits=%v err=%v", run, coopClient.submitSessions, err)
	}
}

func TestFailedSessionGenerationOnlyAdvancesForTerminalCoopCreate(t *testing.T) {
	if !sessioncreate.TerminalFailure(&coop.APIError{
		Status: 500, Code: "internal_error",
	}) {
		t.Fatal("terminal Coop create failure did not advance generation")
	}
	if sessioncreate.TerminalFailure(errors.New("connection reset")) ||
		sessioncreate.TerminalFailure(&coop.APIError{
			Status: 409, Code: "operation_uncertain",
		}) {
		t.Fatal("uncertain create failure advanced generation")
	}
}

func TestWatchSessionRecoversLegacyGenerationOneIdempotencyRequest(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_legacy_watch"
	coopClient.createErrors = []error{
		&coop.APIError{
			Status: 409,
			Code:   "idempotency_conflict",
			Detail: "idempotency key is bound to another request",
		},
		nil,
	}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, session, err := svc.ensureWatchSession(ctx, "CWATCH")
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_legacy_watch" ||
		memory.SessionID != session.ID ||
		memory.Generation != 1 ||
		len(coopClient.createKeys) != 2 ||
		coopClient.createKeys[0] != "ryker:watch-session:CWATCH" ||
		coopClient.createKeys[1] != "ryker:watch-session:CWATCH" ||
		coopClient.createTasks[0] != "Slack operations channel CWATCH generation 1" ||
		coopClient.createTasks[1] != "Slack alert triage channel CWATCH" {
		t.Fatalf(
			"legacy recovery = memory=%+v session=%+v keys=%v tasks=%v",
			memory, session, coopClient.createKeys, coopClient.createTasks,
		)
	}
}

func TestWatchSessionSearchesPastHistoricalCollisionWindow(t *testing.T) {
	coopClient := newFakeCoop()
	for range 20 {
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 409,
			Code:   "idempotency_conflict",
			Detail: "idempotency key is bound to a historical request",
		})
	}
	svc := &Service{cfg: serviceConfig(t), coop: coopClient}
	session, generation, err := svc.createWatchSession(
		context.Background(), "CHISTORY", "observe", 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID == "" || generation != 22 || len(coopClient.createKeys) != 21 {
		t.Fatalf(
			"historical collision recovery = session=%+v generation=%d keys=%d",
			session, generation, len(coopClient.createKeys),
		)
	}
	if got := coopClient.createKeys[len(coopClient.createKeys)-1]; got != "ryker:watch-session:CHISTORY:22" {
		t.Fatalf("last create key = %q", got)
	}
}

func TestConversationSessionSearchesPastHistoricalCollisionWindow(t *testing.T) {
	coopClient := newFakeCoop()
	for range 20 {
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 409,
			Code:   "idempotency_conflict",
			Detail: "idempotency key is bound to a historical request",
		})
	}
	svc := &Service{cfg: serviceConfig(t), coop: coopClient}
	session, generation, err := svc.createConversationSession(
		context.Background(), "CHISTORY", "conversation", 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID == "" || generation != 22 || len(coopClient.createKeys) != 21 {
		t.Fatalf(
			"historical collision recovery = session=%+v generation=%d keys=%d",
			session, generation, len(coopClient.createKeys),
		)
	}
}

// A production @mention started at generation 12 while generations 12 through
// 19 named discarded read-only sessions. They were historical create keys, but
// the four-candidate authority guard treated them as live writable sessions and
// delayed the accepted investigation for an hour before any model turn began.
func TestConversationSessionSearchesPastHistoricalTerminalSessions(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.State = "discarded"
	coopClient.operations = map[string]coop.Operation{}
	for generation := 12; generation <= 19; generation++ {
		key := sessioncreate.Key(
			"ryker:conversation-session:CHISTORYTERMINAL", generation,
		)
		coopClient.operations[key] = coop.Operation{
			ID: "op_historical_terminal", Method: "CreateRemoteSession",
			State: "succeeded", ResourceType: "session", ResourceID: "ses_1",
			UpdatedAt: time.Now().UTC().Add(-time.Hour),
		}
	}
	coopClient.openAfterCreateKey = sessioncreate.Key(
		"ryker:conversation-session:CHISTORYTERMINAL", 20,
	)
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	session, generation, err := svc.createConversationSession(
		ctx, "CHISTORYTERMINAL", "conversation", 12,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_2" || session.State != "open" ||
		generation != 20 || len(coopClient.createKeys) != 9 {
		t.Fatalf(
			"historical terminal recovery = session=%+v generation=%d keys=%v",
			session, generation, coopClient.createKeys,
		)
	}
}

// Twenty-one session keys in production still named durable CreateSession
// operations that had failed under the old 30-second repository refresh
// deadline. Retrying one of those keys can only replay its failed outcome; it
// must not spend one accepted Slack run attempt per historical operation.
func TestWatchSessionSearchesPastHistoricalFailedCreateOperations(t *testing.T) {
	now := time.Now().UTC()
	coopClient := newFakeCoop()
	coopClient.operations = map[string]coop.Operation{}
	for generation := 2; generation <= 21; generation++ {
		key := sessioncreate.Key("ryker:watch-session:CHISTORYFAILED", generation)
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 500, Code: "internal_error", OperationID: "op_failed",
		})
		coopClient.operations[key] = coop.Operation{
			ID: "op_failed", Method: "CreateSession", State: "failed",
			UpdatedAt: now.Add(-time.Hour),
		}
	}
	svc := &Service{cfg: serviceConfig(t), coop: coopClient, clock: func() time.Time { return now }}
	session, generation, err := svc.createWatchSession(
		context.Background(), "CHISTORYFAILED", "observe", 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID == "" || generation != 22 || len(coopClient.createKeys) != 21 {
		t.Fatalf("historical failed-create recovery = session=%+v generation=%d keys=%d",
			session, generation, len(coopClient.createKeys))
	}
}

func TestWatchSessionBoundsHistoricalCreateKeySearch(t *testing.T) {
	coopClient := newFakeCoop()
	for range sessioncreate.MaxHistoricalCreateKeys + 1 {
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 409, Code: "idempotency_conflict",
		})
	}
	svc := &Service{cfg: serviceConfig(t), coop: coopClient}
	_, _, err := svc.createWatchSession(context.Background(), "CBOUND", "observe", 2)
	if !errors.Is(err, sessioncreate.ErrHistoricalCreateKeys) {
		t.Fatalf("historical key window returned %v", err)
	}
	if len(coopClient.createKeys) != sessioncreate.MaxHistoricalCreateKeys {
		t.Fatalf("historical key probes = %d", len(coopClient.createKeys))
	}
}

// Covers: TestSuccessfulWritableSessionCreationIsBoundedAndVisible
// Successful but over-authorized session creation once made both read-only
// lanes create managed forks forever. Bound the authority rejection so the
// Slack work can become visibly blocked instead of leaking silently.
func TestSuccessfulWritableSessionCreationIsBoundedAndVisible(t *testing.T) {
	ctx := context.Background()
	for _, testCase := range []struct {
		name   string
		create func(*Service) error
	}{
		{
			name: "watch",
			create: func(svc *Service) error {
				_, _, err := svc.createWatchSession(ctx, "CAUTH", "watch-policy", 1)
				return err
			},
		},
		{
			name: "conversation",
			create: func(svc *Service) error {
				_, _, err := svc.createConversationSession(
					ctx, "CAUTH", "conversation-policy", 1,
				)
				return err
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { st.Close() })
			coopClient := newFakeCoop()
			coopClient.session.RepositoryReadOnly = false
			coopClient.session.ActiveTurnID = "turn_rejected_candidate"
			coopClient.listTurns = []coop.Turn{{
				ID: "turn_rejected_candidate", SessionID: coopClient.session.ID,
				Ordinal: 1, State: "running",
			}}
			coopClient.createErrors = []error{
				nil, nil, nil, nil, errors.New("unbounded create sentinel"),
			}
			svc := New(
				cfg, st, coopClient, &fakeSlack{}, nil,
				slackui.NewSanitizer(12000), nil,
			)

			err = testCase.create(svc)
			if err == nil || !strings.Contains(
				err.Error(), "without read-only repository authority",
			) {
				t.Fatalf("successful writable creates returned %v, want visible authority error", err)
			}
			if len(coopClient.createKeys) != sessioncreate.MaxReadOnlyCandidates {
				t.Fatalf(
					"created %d writable sessions, want bound %d",
					len(coopClient.createKeys), sessioncreate.MaxReadOnlyCandidates,
				)
			}
			if !slices.Equal(coopClient.cancelTurns, []string{"turn_rejected_candidate"}) ||
				coopClient.session.State != "closed" {
				t.Fatalf("rejected candidate retained authority: cancelled=%v session=%+v", coopClient.cancelTurns, coopClient.session)
			}
			cleanup, cleanupErr := st.GetCoopCleanup(ctx, coopClient.session.ID)
			if cleanupErr != nil || cleanup.State != "pending" {
				t.Fatalf("rejected writable session cleanup = %+v, %v", cleanup, cleanupErr)
			}
		})
	}
}

// Four rejected authority candidates are one preparation failure, not four
// invisible model attempts. The first accepted Slack card must receive a
// durable bound-thread status and the run must park on the circuit breaker.
func TestReadOnlyAuthorityFailurePostsOneVisibleStatusAndParksTheRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CAUTHCARD"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B_GRAFANA"}
	clock := useTestClock(svc, st)
	input := core.SlackInput{
		ID: "slack-authority-card", EnvelopeID: "env-authority-card", EventID: "EvAuthorityCard",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CAUTHCARD",
		MessageTS: "1700.960", UserID: "B_GRAFANA", Text: "FIRING: scrape target is down",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.State != core.AgentRunPending || run.TerminalState != "" ||
		run.NextAttemptAt.Before(clock.Now().Add(29*time.Minute)) {
		t.Fatalf("authority-blocked run was not parked: %+v", run)
	}
	if len(coopClient.submitSessions) != 0 {
		t.Fatalf("authority-blocked run submitted model turns: %v", coopClient.submitSessions)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 1 || slackClient.posts[0].channel != input.ChannelID ||
		slackClient.posts[0].thread != input.MessageTS {
		t.Fatalf("authority blocker posts = %+v", slackClient.posts)
	}
	rendered := renderedSlackMessage(slackClient.posts[0].message)
	for _, want := range []string{"Investigation queued", "read-only workspace", "No model turn has started"} {
		if !strings.Contains(rendered, want) {
			t.Fatalf("authority blocker lacks %q: %q", want, rendered)
		}
	}
}

// Opening an agent surface is acknowledged and costs nothing else.
//
// The prompts above the Messages tab are declared statically in
// deploy/slack-app-manifest.yaml under features.agent_view.suggested_prompts.
// Ryker used to answer the same event by calling
// assistant.threads.setSuggestedPrompts with a near-identical list, which Slack
// refused with internal_error on every attempt either deployment ever made.
// Queueing work for these events is therefore not a smaller failure than
// failing at it — it is the whole defect, so the assertion is that no input is
// admitted at all.
func TestOpeningAnAgentSurfaceQueuesNoWorkAndTheHomeStillPublishes(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, socket,
		slackui.NewSanitizer(12000), nil,
	)

	for _, event := range []struct {
		name     string
		envelope string
		data     slackevents.EventsAPIInnerEvent
	}{
		{
			name:     "assistant thread",
			envelope: "env-assistant",
			data: slackevents.EventsAPIInnerEvent{Data: &slackevents.AssistantThreadStartedEvent{
				AssistantThread: slackevents.AssistantThread{
					UserID: "U123ABC", ChannelID: "D123ABC", ThreadTimeStamp: "1700.902",
				},
			}},
		},
		{
			name:     "agent messages tab",
			envelope: "env-messages",
			data: slackevents.EventsAPIInnerEvent{Data: &slackevents.AppHomeOpenedEvent{
				User: "U123ABC", Channel: "D123ABC", Tab: "messages",
			}},
		},
	} {
		payload, _ := json.Marshal(map[string]any{"event_id": event.envelope})
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID: cfg.Slack.TeamID, InnerEvent: event.data,
			},
			Request: &socketmode.Request{EnvelopeID: event.envelope, Payload: payload},
		})
		// Acknowledged so Slack stops redelivering, and nothing queued: the
		// lane finds an empty queue rather than a surface repaint to attempt.
		if err := svc.processSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("%s queued a Slack input: %v", event.name, err)
		}
	}
	if socket.acks != 2 {
		t.Fatalf("acks = %d, want both surface opens acknowledged", socket.acks)
	}

	// The Home tab is the surface that does have host-owned content, and it is
	// unaffected.
	payload, _ := json.Marshal(map[string]any{"event_id": "EvHome"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.AppHomeOpenedEvent{User: "U123ABC", Tab: "home"},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-home", Payload: payload},
	})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	// The header is the answer, not the product name: an empty workspace opens
	// the tab and reads that nothing is waiting on them.
	if len(slackClient.homes) != 1 ||
		slackClient.homes[0].thread != "U123ABC" ||
		slackClient.homes[0].message.Header != "Nothing needs you" {
		t.Fatalf("operations home = %+v", slackClient.homes)
	}
}

func TestSlackShortcutAndDirectMessageBecomeExplicitReadOnlyRequests(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	svc.admitInteraction(ctx, socketmode.Event{
		Type: socketmode.EventTypeInteractive,
		Data: slack.InteractionCallback{
			Type: slack.InteractionTypeMessageAction,
			Team: slack.Team{ID: cfg.Slack.TeamID},
			Channel: slack.Channel{
				GroupConversation: slack.GroupConversation{
					Conversation: slack.Conversation{ID: "CWATCH"},
				},
			},
			User:       slack.User{ID: "U123ABC"},
			CallbackID: "responder_investigate_message",
			Message: slack.Message{Msg: slack.Msg{
				User: "U456DEF", Text: "The API alert is firing.",
				Timestamp: "1700.903",
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-shortcut"},
	})
	shortcut, err := st.LeaseSlackInput(ctx)
	if err != nil || shortcut.Kind != "shortcut" ||
		shortcut.UserID != "U123ABC" || shortcut.ActionValue != "U456DEF" ||
		shortcut.ThreadTS != shortcut.MessageTS {
		t.Fatalf("shortcut = %+v, %v", shortcut, err)
	}
	contextMessage := WatchPromptMessage(shortcut, "U999BOT", true)
	if contextMessage.SenderID != "U456DEF" ||
		contextMessage.RequestedBy != "U123ABC" ||
		contextMessage.SenderType != "selected_message" {
		t.Fatalf("shortcut context = %+v", contextMessage)
	}
	if err := st.FinishSlackInput(ctx, shortcut.ID); err != nil {
		t.Fatal(err)
	}

	payload, _ := json.Marshal(map[string]any{"event_id": "EvDirect"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.MessageEvent{
					Channel: "D123ABC", User: "U123ABC",
					Text: "Assess production health.", TimeStamp: "1700.904",
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-direct", Payload: payload},
	})
	direct, err := st.LeaseSlackInput(ctx)
	if err != nil || direct.Kind != "direct" || direct.ChannelID != "D123ABC" {
		t.Fatalf("direct message = %+v, %v", direct, err)
	}
}
