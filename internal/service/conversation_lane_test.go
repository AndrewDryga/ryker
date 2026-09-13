package service

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
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
	for _, preference := range []core.RykerPreference{
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
		if _, _, err := st.Behavior.UpsertPreference(ctx, preference, 20, 10); err != nil {
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
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":1,"contribution":"decision","material":true},"reason":"direct request","operations":[` +
			`{"id":"complete","type":"complete_episode","completion":{"message":"hi",` +
			`"completion":{"status":"decision_ready","summary":"posted the greeting"}}}]}`,
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
	coopClient.openAfterCreateKey = "ryker:conversation-session:CSTALE:2"
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

// An ordinary Slack session must not retain the authority of a session created
// before repository read-only policies were enforced. The live test channel
// reused one such writable session after the policy rollout, so every later
// conversation inherited a checkout it was no longer allowed to mutate.
func TestAReadOnlyPolicyNeverReusesLegacyWritableConversationSession(t *testing.T) {
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
	if err := st.BindConversationSession(
		ctx, "CLEGACY", "repo", "repo-conversation", "ses_legacy", 1, 1, time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_legacy"
	coopClient.session.RepositoryReadOnly = false
	coopClient.openAfterCreateKey = "ryker:conversation-session:CLEGACY:2"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	memory, session, err := svc.ensureConversationSession(
		ctx, "CLEGACY", "repo", "repo-conversation",
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_2" || !session.RepositoryReadOnly || memory.SessionID != "ses_2" ||
		memory.Generation != 2 {
		t.Fatalf("legacy writable session was reused: memory=%+v session=%+v", memory, session)
	}
}

func TestAReadOnlyPolicyNeverReusesLegacyWritableWatchSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Intelligence.BindChannelSession(
		ctx, "CLEGACY", "repo", "ses_legacy", 1, 1, time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_legacy"
	coopClient.session.RepositoryReadOnly = false
	coopClient.openAfterCreateKey = "ryker:watch-session:CLEGACY:2"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	memory, session, err := svc.ensureWatchSessionForRepositoryAtGeneration(
		ctx, "CLEGACY", "repo", 1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_2" || !session.RepositoryReadOnly || memory.SessionID != "ses_2" ||
		memory.Generation != 2 {
		t.Fatalf("legacy writable watch session was reused: memory=%+v session=%+v", memory, session)
	}
}

func TestFailedConversationPrewarmAdvancesDurableGeneration(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CRECOVER"}
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
		ctx, "CRECOVER", "repo", "repo-conversation", "ses_old", 1, 5, time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.DetachConversationSession(ctx, "CRECOVER", "ses_old"); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.createErrors = []error{&coop.APIError{
		Status: 500, Code: "internal_error", Detail: "durable create failure",
	}}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)

	svc.prewarmConversationSessions(ctx)
	failed, err := st.GetConversationSession(ctx, "CRECOVER")
	if err != nil {
		t.Fatal(err)
	}
	if failed.SessionID != "" || failed.Generation != 6 {
		t.Fatalf("failed generation was not advanced durably: %+v", failed)
	}

	svc.prewarmConversationSessions(ctx)
	recovered, err := st.GetConversationSession(ctx, "CRECOVER")
	if err != nil {
		t.Fatal(err)
	}
	if recovered.SessionID == "" || recovered.Generation != 6 {
		t.Fatalf("recovered conversation session = %+v", recovered)
	}
	want := []string{
		"ryker:conversation-session:CRECOVER:5",
		"ryker:conversation-session:CRECOVER:6",
	}
	if !slices.Equal(coopClient.createKeys, want) {
		t.Fatalf("conversation create keys = %v, want %v", coopClient.createKeys, want)
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
	coopClient.session.BaseCommit = "repo-commit"
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":1,"contribution":"decision","material":true},"reason":"ordinary arithmetic","operations":[` +
			`{"id":"complete","type":"complete_episode","completion":{"message":"8",` +
			`"completion":{"status":"decision_ready","summary":"answered the arithmetic question"}}}]}`,
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
		!strings.Contains(coopClient.submitPrompts[0], "<trusted-ryker-repository-capabilities>") ||
		!strings.Contains(coopClient.submitPrompts[0], `"access_mode":"pinned_read_only"`) ||
		// Which lane ran, told by a line only the full watch prompt carries.
		// This was the compound-request policy until 2026-08-15, when that
		// block became conditional on the message carrying more than one
		// instruction — so its absence stopped meaning "the bounded lane ran"
		// and started meaning "the question was short".
		strings.Contains(coopClient.submitPrompts[0], "Choose exactly one action:") {
		t.Fatalf("conversation prompt = %q", coopClient.submitPrompts)
	}
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "8") {
		t.Fatalf("conversation reply = %+v", slack.posts)
	}
}

func TestRepositoryAccessQuestionUsesPinnedSessionCapabilities(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Repositories = map[string]config.Repository{
		"blitz-core": {
			DisplayName: "Blitz Core", CoopPolicy: "blitz-core-observe",
			ConversationPolicy: "blitz-core-conversation",
		},
		"blitz-flutter": {
			DisplayName: "Blitz Flutter", CoopPolicy: "blitz-flutter-observe",
			ConversationPolicy: "blitz-flutter-conversation",
		},
		"blitz-infra": {
			DisplayName: "Blitz Infrastructure", CoopPolicy: "blitz-infra-observe",
			ConversationPolicy: "blitz-infra-conversation",
		},
		"nexus": {
			DisplayName: "Nexus", CoopPolicy: "nexus-observe",
			ConversationPolicy: "nexus-conversation",
		},
		"ultralite-overlay": {
			DisplayName: "Ultralite Overlay", CoopPolicy: "ultralite-overlay-observe",
			ConversationPolicy: "ultralite-overlay-conversation",
		},
	}
	cfg.RepositorySets = map[string]config.RepositorySet{
		"blitz-platform": {
			DisplayName: "All Blitz repositories", Primary: "blitz-infra",
			CoopPolicy:         "blitz-platform-observe",
			ConversationPolicy: "blitz-platform-conversation",
		},
	}
	cfg.Slack.DefaultRepository = "blitz-platform"
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.BaseCommit = "infra-commit"
	coopClient.session.Companions = []coop.CompanionRepository{
		{Name: "blitz-core", BaseCommit: "core-commit"},
		{Name: "blitz-flutter", BaseCommit: "flutter-commit"},
		{Name: "ultralite-overlay", BaseCommit: "overlay-commit"},
	}
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":2,"contribution":"decision","material":true},"reason":"bound session manifest verifies read access","message":"Yes, I have read access to all three repositories.","memory":{}}`,
	}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "repository-access", EnvelopeID: "repository-access-envelope",
		EventID: "repository-access-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.300", UserID: "U123ABC",
		Text: "<@UBOT> do you have access to the `blitz-flutter`, `blitz-core`, or `ultralite-overlay` repos?",
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
		coopClient.createPolicies[0] != "blitz-platform-observe" {
		t.Fatalf("created policies = %v", coopClient.createPolicies)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted prompts = %d", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	for _, required := range []string{
		"Choose exactly one action:",
		"<trusted-ryker-repository-capabilities>",
		`"key":"blitz-core","display_name":"Blitz Core","role":"companion","access_mode":"pinned_read_only","pinned_commit":"core-commit","can_publish":false`,
		`"key":"blitz-flutter","display_name":"Blitz Flutter","role":"companion","access_mode":"pinned_read_only","pinned_commit":"flutter-commit","can_publish":false`,
		`"key":"nexus","display_name":"Nexus","role":"unbound","access_mode":"configured","can_publish":false`,
		`"key":"ultralite-overlay","display_name":"Ultralite Overlay","role":"companion","access_mode":"pinned_read_only","pinned_commit":"overlay-commit","can_publish":false`,
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("repository access prompt lacks %q:\n%s", required, prompt)
		}
	}
	if strings.Contains(prompt, "bounded conversation turn") {
		t.Fatalf("repository access question used bounded lane:\n%s", prompt)
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
		!strings.Contains(coopClient.submitPrompts[0], "Choose exactly one action:") ||
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
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":3,"contribution":"decision","material":true},"reason":"verified current state","operations":[` +
			`{"id":"complete","type":"complete_episode","completion":{"message":"CI is green.",` +
			`"completion":{"status":"decision_ready","summary":"CI is green."}}}]}`,
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
		!strings.Contains(coopClient.submitPrompts[1], "Choose exactly one action:") {
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
	observedAt := time.Now().UTC().Format(time.RFC3339)
	coopClient.completeQueue = []string{
		`{"action":"escalate","attention":{"addressee":"responder","confidence":3,"ownership":2},"reason":"requires current production evidence","memory":{}}`,
		// Deliberately incomplete: a deep-work answer with no completion
		// assessment and no claim evidence, which the host must send back.
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":3,"contribution":"decision","material":true},"reason":"checked production","operations":[` +
			`{"id":"complete","type":"complete_episode","completion":{"message":"Production is healthy."}}]}`,
		`{
		  "action":"reply",
		  "attention":{"addressee":"responder","confidence":3,"ownership":3,"contribution":"decision","material":true},
		  "reason":"completed every required check",
		  "operations":[
		    {"id":"ev-change","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"the deployed revision is the intended one","observation":"the running revision matches the intended rollout","relation":"supports","health_effect":"none","source_type":"repository","source_name":"deployment manifest","observed_at":"` + observedAt + `","dimensions":{"repository":"repo","environment":"production","revision":"current"}}},
		    {"id":"ev-host","type":"record_evidence","evidence":{"claim_id":"host.current_state","claim":"expected hosts are responsive","observation":"every expected host reports ready with no pressure","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"host inventory","observed_at":"` + observedAt + `","dimensions":{"host":"prod-1","environment":"production"}}},
		    {"id":"ev-runtime","type":"record_evidence","evidence":{"claim_id":"runtime.current_state","claim":"required runtimes are healthy","observation":"each runtime reports current healthy state","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"runtime status","observed_at":"` + observedAt + `","dimensions":{"runtime":"container","host":"prod-1"}}},
		    {"id":"ev-workload","type":"record_evidence","evidence":{"claim_id":"workload.desired_state","claim":"workloads run at desired capacity","observation":"every workload reports its desired replica count with no restarts","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"workload state","observed_at":"` + observedAt + `","dimensions":{"service":"api","workload":"api","environment":"production"}}},
		    {"id":"ev-dependency","type":"record_evidence","evidence":{"claim_id":"dependency.current_health","claim":"critical dependencies are available","observation":"every dependency check succeeds within its bounds","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"dependency checks","observed_at":"` + observedAt + `","dimensions":{"dependency":"database","service":"api","environment":"production"}}},
		    {"id":"ev-application","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"representative user paths work","observation":"the checkout and login paths return success","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"synthetic checks","observed_at":"` + observedAt + `","dimensions":{"service":"api","endpoint":"checkout","environment":"production","measurement_kind":"functional_probe"}}},
		    {"id":"ev-broad-errors","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"broad error trend is healthy","observation":"the current and prior broad windows have no error increase","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"request metrics","observed_at":"` + observedAt + `","dimensions":{"measurement_kind":"error_rate","measurement_scope":"broad","window":"10m","comparison_window":"previous 10m","population":"all requests","denominator":"all requests"}}},
		    {"id":"ev-broad-timeouts","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"broad timeout trend is healthy","observation":"the current and prior broad windows have no timeout increase","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"request metrics","observed_at":"` + observedAt + `","dimensions":{"measurement_kind":"timeout_rate","measurement_scope":"broad","window":"10m","comparison_window":"previous 10m","population":"all requests","denominator":"all requests"}}},
		    {"id":"ev-service-errors","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"service error trend is healthy","observation":"the current and prior API windows have no error increase","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"service metrics","observed_at":"` + observedAt + `","dimensions":{"measurement_kind":"error_rate","measurement_scope":"service","window":"10m","comparison_window":"previous 10m","population":"api requests","denominator":"api requests"}}},
		    {"id":"ev-service-timeouts","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"service timeout trend is healthy","observation":"the current and prior API windows have no timeout increase","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"service metrics","observed_at":"` + observedAt + `","dimensions":{"measurement_kind":"timeout_rate","measurement_scope":"service","window":"10m","comparison_window":"previous 10m","population":"api requests","denominator":"api requests"}}},
		    {"id":"ev-slo","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"no current user impact","observation":"the current service indicator is within its objective and no alert is firing","relation":"supports","health_effect":"none","source_type":"monitoring","source_name":"service indicators","observed_at":"` + observedAt + `","dimensions":{"service":"api","indicator":"availability","environment":"production","window":"current"}}},
		    {"id":"cov-change","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","detail":"current revision verified"}},
		    {"id":"cov-host","type":"record_coverage","coverage":{"layer":"host","claim_ids":["host.current_state"],"status":"healthy","detail":"hosts verified"}},
		    {"id":"cov-runtime","type":"record_coverage","coverage":{"layer":"runtime","claim_ids":["runtime.current_state"],"status":"healthy","detail":"runtime verified"}},
		    {"id":"cov-workload","type":"record_coverage","coverage":{"layer":"workload","claim_ids":["workload.desired_state"],"status":"healthy","detail":"workloads verified"}},
		    {"id":"cov-dependency","type":"record_coverage","coverage":{"layer":"dependency","claim_ids":["dependency.current_health"],"status":"healthy","detail":"dependencies verified"}},
		    {"id":"cov-application","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"healthy","detail":"application verified"}},
		    {"id":"cov-slo","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"healthy","detail":"SLO verified"}},
		    {"id":"complete","type":"complete_episode","completion":{
		      "message":"Production is healthy across the requested scope.",
		      "completion":{"status":"decision_ready","verdict":"healthy","summary":"Production is healthy across the requested scope."}
		    }}
		  ]
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
	// Failures stays 0: a correction round is not a failed attempt. The
	// correction itself is what proves the answer went back.
	if err != nil || run.State != core.AgentRunPending || run.Failures != 0 ||
		!strings.Contains(run.LastError, "no completion assessment") {
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
