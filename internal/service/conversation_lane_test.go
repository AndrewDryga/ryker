package service

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestReferencedOldThreadContextIsAnchoredAndCached(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Intelligence.BindChannelSession(
		ctx, "COPS", "repo", "ses_watch", 1, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.ApplyWatchDecision(
		ctx,
		core.EvaluationDecision{
			ChannelID: "COPS", ThreadTS: "1600.100", MessageTS: "1600.200",
			Repository: "repo", SourceInput: "old-thread-decision",
			Mode: "live", Action: "reply",
		},
		"investigation",
		2,
		core.AgentMemory{SituationSummary: "The old thread decided to use option B."},
	); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{history: []slackui.HistoryMessage{{
		Timestamp: "1600.200", ThreadTS: "1600.100",
		UserID: "U123ABC", Text: "Use option B.",
	}}}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	target := core.SlackInput{
		ID: "current", ChannelID: "COPS", MessageTS: "1700.100",
		UserID: "U123ABC", Text: "post hi back to that thread",
	}
	request := agentContextRequest{
		ChannelID: "COPS", Repository: "repo", OperatorID: target.UserID,
		SourceInputID: target.ID, TargetInput: &target,
		ReferencedThreadTS: "1600.100", IncludeRecent: true,
	}
	first, err := svc.assembleAgentContext(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := svc.assembleAgentContext(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if first.ReferencedThread == nil ||
		first.ReferencedThread.Summary.SituationSummary !=
			"The old thread decided to use option B." ||
		len(first.ReferencedThread.RecentMessages) != 1 ||
		second.ReferencedThread == nil {
		t.Fatalf("referenced contexts = %+v / %+v", first, second)
	}
	if len(slack.historyRequests) != 3 {
		t.Fatalf("anchored history requests = %+v", slack.historyRequests)
	}
}

func TestConversationRoutePersistsChannelAndReturnsToPreviousThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	exit := core.SlackInput{
		ChannelID: "COPS", ThreadTS: "1700.100", MessageTS: "1700.200",
		UserID: "U123ABC", Text: "no lets get back to channel, 9-1",
	}
	thread, referenced, err := svc.resolveConversationRoute(ctx, exit)
	if err != nil || thread != "" || referenced != "" {
		t.Fatalf("exit route = %q, %q, %v", thread, referenced, err)
	}
	followup := exit
	followup.MessageTS = "1700.300"
	followup.Text = "why did you post it here?"
	thread, referenced, err = svc.resolveConversationRoute(ctx, followup)
	if err != nil || thread != "" || referenced != exit.ThreadTS {
		t.Fatalf("persisted channel route = %q, %q, %v", thread, referenced, err)
	}
	back := core.SlackInput{
		ChannelID: "COPS", MessageTS: "1700.400", UserID: "U123ABC",
		Text: "Can you post hi back to that thread?",
	}
	thread, referenced, err = svc.resolveConversationRoute(ctx, back)
	if err != nil || thread != exit.ThreadTS || referenced != exit.ThreadTS {
		t.Fatalf("previous thread route = %q, %q, %v", thread, referenced, err)
	}
}

func TestConversationRouteAppliesPreferencePrecedenceAndExplicitOverride(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Add(90 * 24 * time.Hour)
	for _, preference := range []core.ResponderPreference{
		{
			ScopeKind: "workspace", ScopeKey: cfg.Slack.TeamID,
			Name: "response_location", Value: "prefer_channel",
			SourceRef: "workspace_pref", ActorID: cfg.Slack.Operators[0], ExpiresAt: now,
		},
		{
			ScopeKind: "operator", ScopeKey: cfg.Slack.Operators[0],
			Name: "response_location", Value: "prefer_thread",
			SourceRef: "operator_pref", ActorID: cfg.Slack.Operators[0], ExpiresAt: now,
		},
	} {
		if _, _, err := st.UpsertPreference(ctx, preference, 20, 10); err != nil {
			t.Fatal(err)
		}
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	operator := core.SlackInput{
		ChannelID: "COPS", MessageTS: "1700.700",
		UserID: cfg.Slack.Operators[0], Text: "Can you check this?",
	}
	thread, _, err := svc.resolveConversationRoute(ctx, operator)
	if err != nil || thread != operator.MessageTS {
		t.Fatalf("operator preference route = %q, %v", thread, err)
	}
	other := core.SlackInput{
		ChannelID: "COPS", ThreadTS: "1700.800", MessageTS: "1700.801",
		UserID: "UOTHER", Text: "Can you check this?",
	}
	thread, referenced, err := svc.resolveConversationRoute(ctx, other)
	if err != nil || thread != "" || referenced != other.ThreadTS {
		t.Fatalf("workspace preference route = %q, %q, %v", thread, referenced, err)
	}
	explicit := core.SlackInput{
		ChannelID: "COPS", ThreadTS: operator.MessageTS, MessageTS: "1700.701",
		UserID: cfg.Slack.Operators[0], Text: "Let's get back to the channel.",
	}
	thread, _, err = svc.resolveConversationRoute(ctx, explicit)
	if err != nil || thread != "" {
		t.Fatalf("explicit channel override = %q, %v", thread, err)
	}
	followup := explicit
	followup.MessageTS = "1700.702"
	followup.Text = "One more question."
	thread, referenced, err = svc.resolveConversationRoute(ctx, followup)
	if err != nil || thread != "" || referenced != operator.MessageTS {
		t.Fatalf("conversation override persistence = %q, %q, %v", thread, referenced, err)
	}
	newConversation := operator
	newConversation.MessageTS = "1700.900"
	thread, _, err = svc.resolveConversationRoute(ctx, newConversation)
	if err != nil || thread != newConversation.MessageTS {
		t.Fatalf("new conversation preference route = %q, %v", thread, err)
	}
}

func TestConversationReplyReturnsToPreviouslyExitedThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"COPS"}
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":1},"reason":"direct request","message":"hi","memory":{}}`,
	}
	slack := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	exit := core.SlackInput{
		ChannelID: "COPS", ThreadTS: "1700.100", MessageTS: "1700.200",
		UserID: "U123ABC", Text: "no lets get back to channel, 9-1",
	}
	if _, _, err := svc.resolveConversationRoute(ctx, exit); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "return-to-thread", EnvelopeID: "return-to-thread-envelope",
		EventID: "return-to-thread-event", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.300", UserID: "U123ABC",
		Text: "Can you post hi back to that thread?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slack.posts) == 0 {
		// drainSlackDeliveries is synchronous — it calls processSlackDelivery
		// directly rather than going through the paced write slot — so there is
		// nothing to wait for here.
		drainSlackDeliveries(t, ctx, svc)
	}
	if len(slack.posts) != 1 ||
		slack.posts[0].thread != exit.ThreadTS ||
		slack.posts[0].broadcast ||
		strings.TrimSpace(slack.posts[0].message.Text) != "hi" {
		delivery, deliveryErr := st.GetSlackDelivery(
			ctx,
			"watch_reply_"+input.ID,
		)
		t.Fatalf(
			"thread reply = %+v; delivery = %+v, %v",
			slack.posts,
			delivery,
			deliveryErr,
		)
	}
}

func TestPrewarmConversationSessionsUsesConfiguredBoundedLane(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWARM"}
	cfg.Coop.PrewarmSessions = 1
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
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

	svc.prewarmConversationSessions(ctx)

	if len(coopClient.createPolicies) != 1 ||
		coopClient.createPolicies[0] != "repo-conversation" {
		t.Fatalf("prewarm policies = %v", coopClient.createPolicies)
	}
	if !slices.Equal(coopClient.prepareSessions, []string{"ses_1"}) {
		t.Fatalf("prepared conversation sessions = %v", coopClient.prepareSessions)
	}
	session, err := st.GetConversationSession(ctx, "CWARM")
	if err != nil {
		t.Fatal(err)
	}
	if session.Policy != "repo-conversation" || session.Repository != "repo" {
		t.Fatalf("prewarmed session = %+v", session)
	}
}

func TestPrewarmConversationSessionsPrefersRecentDynamicLane(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CSTATIC"}
	cfg.Coop.PrewarmSessions = 1
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.BindConversationSession(
		ctx, "CDYNAMIC", "repo", "repo-conversation", "ses_dynamic", 3, 1, time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)

	svc.prewarmConversationSessions(ctx)

	if len(coopClient.createPolicies) != 0 ||
		!slices.Equal(coopClient.prepareSessions, []string{"ses_1"}) ||
		len(coopClient.prepareKeys) != 1 ||
		!strings.Contains(coopClient.prepareKeys[0], "CDYNAMIC") {
		t.Fatalf(
			"dynamic prewarm create=%v prepare=%v keys=%v",
			coopClient.createPolicies,
			coopClient.prepareSessions,
			coopClient.prepareKeys,
		)
	}
}

func TestPrewarmConversationSessionsRotatesChangedPolicy(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = nil
	cfg.Coop.PrewarmSessions = 1
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.BindConversationSession(
		ctx, "CSTALE", "repo", "repo-conversation", "ses_1", 1, 1, time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.openAfterCreateKey = "responder:conversation-session:CSTALE:2"
	coopClient.prepareErrors = []error{&coop.APIError{
		Status: 409,
		Code:   "invalid_session_state",
		Detail: "session policy no longer matches the operator policy",
	}}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)

	svc.prewarmConversationSessions(ctx)

	if !slices.Equal(coopClient.prepareSessions, []string{"ses_1", "ses_2"}) {
		t.Fatalf("prepared conversation sessions = %v", coopClient.prepareSessions)
	}
	session, err := st.GetConversationSession(ctx, "CSTALE")
	if err != nil {
		t.Fatal(err)
	}
	if session.SessionID != "ses_2" {
		t.Fatalf("rotated conversation session = %+v", session)
	}
	if session.Generation != 2 {
		t.Fatalf("rotated conversation generation = %d", session.Generation)
	}
}

func TestBoundedConversationLaneRepliesWithoutInvestigation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":1},"reason":"ordinary arithmetic","message":"8","memory":{}}`,
	}
	slack := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "fast-conversation", EnvelopeID: "fast-conversation-envelope",
		EventID: "fast-conversation-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@UBOT> 3+5?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(coopClient.createPolicies) != 1 ||
		coopClient.createPolicies[0] != "repo-conversation" {
		t.Fatalf("created policies = %v", coopClient.createPolicies)
	}
	if len(coopClient.submitPrompts) != 1 ||
		!strings.Contains(coopClient.submitPrompts[0], "bounded conversation turn") ||
		strings.Contains(coopClient.submitPrompts[0], "Run independent read-only") {
		t.Fatalf("conversation prompt = %q", coopClient.submitPrompts)
	}
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "8") {
		t.Fatalf("conversation reply = %+v", slack.posts)
	}
}

func TestSlackVerificationReplayBypassesBoundedConversationLane(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
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
		ID: "replayed-conversation", EnvelopeID: "replay:source-envelope",
		EventID: "replay:source-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.150", UserID: "U123ABC",
		Text: "<@UBOT> Give me a decision-ready production health assessment.",
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
	if len(coopClient.createPolicies) != 1 ||
		coopClient.createPolicies[0] != "repo-observe" {
		t.Fatalf("created policies = %v", coopClient.createPolicies)
	}
	if len(coopClient.submitPrompts) != 1 ||
		!strings.Contains(coopClient.submitPrompts[0], "explicit host verification replay") ||
		!strings.Contains(coopClient.submitPrompts[0], "Run independent read-only") ||
		strings.Contains(coopClient.submitPrompts[0], "bounded conversation turn") {
		t.Fatalf("verification replay prompt = %q", coopClient.submitPrompts)
	}
}

func TestConversationLaneEscalatesOperationalWorkWithoutRetryPenalty(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"escalate","attention":{"addressee":"responder","confidence":3,"ownership":2},"reason":"requires current CI evidence","memory":{}}`,
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":3},"reason":"verified current state","message":"CI is green.","evidence":[],"coverage":[],"memory":{}}`,
	}
	slack := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "escalated-conversation", EnvelopeID: "escalated-envelope",
		EventID: "escalated-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@UBOT> is CI green?",
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
	svc.pollAgentRuns(ctx)
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.State != core.AgentRunPending || run.Failures != 0 {
		t.Fatalf("escalated run = %+v", run)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(coopClient.createPolicies) != 2 ||
		coopClient.createPolicies[0] != "repo-conversation" ||
		coopClient.createPolicies[1] != "repo-observe" {
		t.Fatalf("escalation policies = %v", coopClient.createPolicies)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[1], "full evidence-backed work") ||
		!strings.Contains(coopClient.submitPrompts[1], "Run independent read-only") {
		t.Fatalf("investigation prompt = %q", coopClient.submitPrompts)
	}
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "CI is green") {
		t.Fatalf("escalated reply = %+v", slack.posts)
	}
}

func TestEscalatedDeepWorkReceivesStructuredCorrection(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"escalate","attention":{"addressee":"responder","confidence":3,"ownership":2},"reason":"requires current production evidence","memory":{}}`,
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":3},"reason":"checked production","message":"Production is healthy.","evidence":[],"coverage":[],"memory":{}}`,
		`{
		  "action":"reply",
		  "attention":{"addressee":"responder","confidence":3,"ownership":3},
		  "reason":"completed every required check",
		  "message":"Production is healthy across the requested scope.",
		  "coverage":[
		    {"layer":"change","status":"healthy","detail":"current revision verified"},
		    {"layer":"host","status":"healthy","detail":"hosts verified"},
		    {"layer":"runtime","status":"healthy","detail":"runtime verified"},
		    {"layer":"workload","status":"healthy","detail":"workloads verified"},
		    {"layer":"dependency","status":"healthy","detail":"dependencies verified"},
		    {"layer":"application","status":"healthy","detail":"application verified"},
		    {"layer":"slo","status":"healthy","detail":"SLO verified"}
		  ],
		  "completion":{"status":"decision_ready","verdict":"healthy","summary":"Production is healthy across the requested scope."},
		  "memory":{}
		}`,
	}
	slack := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "deep-escalated-conversation", EnvelopeID: "deep-escalated-envelope",
		EventID: "deep-escalated-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.200", UserID: "U123ABC",
		Text: "<@UBOT> Give me a decision-ready production health assessment. " +
			"Cover recent changes, hosts, workloads, dependencies, application behavior, and SLOs.",
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
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunPending || run.Failures != 1 {
		t.Fatalf("corrected deep run = %+v, %v", run, err)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("invalid deep answer reached Slack: %+v", slack.posts)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(coopClient.submitPrompts) != 3 ||
		!strings.Contains(coopClient.submitPrompts[1], "full evidence-backed work") ||
		!strings.Contains(coopClient.submitPrompts[2], "host-decision-correction") ||
		!strings.Contains(coopClient.submitPrompts[2], "completion.verdict") ||
		strings.Contains(coopClient.submitPrompts[2], "bounded conversation turn") {
		t.Fatalf("deep correction prompts = %q", coopClient.submitPrompts)
	}
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "Production is healthy") {
		t.Fatalf("corrected deep reply = %+v", slack.posts)
	}
}
