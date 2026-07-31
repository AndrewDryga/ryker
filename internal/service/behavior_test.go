package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestBehaviorOffersRequireExplicitTypedOperatorIntent(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	input := core.SlackInput{
		ID: "slack_behavior", EventID: "EvBehavior",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
		Text:   "When I ask for infrastructure health I always mean a deep check.",
	}
	preferenceOffer := &core.PreferenceOffer{
		Scope: "operator", Name: "health_check_depth",
		Value: "deep", ExpiresIn: "90d",
	}
	value, preference, expires, ok := s.preparePreferenceOfferAction(
		input, preferenceOffer,
	)
	if !ok || !strings.Contains(value, `"version":1`) ||
		preference.ScopeKind != "operator" || preference.ScopeKey != input.UserID ||
		preference.Value != "deep" || expires != "90 days" {
		t.Fatalf("preference offer = ok=%t value=%q preference=%+v expiry=%q",
			ok, value, preference, expires)
	}

	input.Text = "When you see a new Terraform plan here, review it for each change."
	ruleOffer := &core.RuleOffer{
		Scope: "channel", Repository: "repo", Trigger: "terraform_plan",
		Action: "review_terraform_plan", SourceKind: "app", ExpiresIn: "30d",
	}
	value, rule, expires, ok := s.prepareRuleOfferAction(input, ruleOffer)
	if !ok || !strings.Contains(value, `"version":1`) ||
		rule.ChannelID != input.ChannelID || rule.Repository != "repo" ||
		rule.SourceKind != "app" || expires != "30 days" {
		t.Fatalf("rule offer = ok=%t value=%q rule=%+v expiry=%q",
			ok, value, rule, expires)
	}

	input.Text = "Run a deep health check once."
	if _, _, _, ok := s.preparePreferenceOfferAction(input, preferenceOffer); ok {
		t.Fatal("one-time request produced a durable preference offer")
	}
	if _, _, _, ok := s.prepareRuleOfferAction(input, ruleOffer); ok {
		t.Fatal("one-time request produced a standing rule offer")
	}
	input.Text = "When you see this, deploy it."
	ruleOffer.Action = "verify_deployment"
	if _, _, _, ok := s.prepareRuleOfferAction(input, ruleOffer); ok {
		t.Fatal("invalid trigger/action pair produced a standing rule offer")
	}
}

func TestFailedWatchSessionIsDetachedAndQueuedForCleanup(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	started := time.Now().UTC().Add(-time.Minute)
	if err := st.BindChannelSession(
		ctx, "COPS", "emisar", "ses_1", 1, 2, started,
	); err != nil {
		t.Fatal(err)
	}
	memoryState := core.AgentMemory{
		Goal: "Review Terraform plans against repository and live evidence",
	}
	if err := st.AdvanceChannelMemory(ctx, "COPS", 2, memoryState); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack_failed_watch", EnvelopeID: "env_failed_watch",
		EventID: "EvFailedWatch", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.500",
		UserID: cfg.Slack.Operators[0], Text: "<@U999BOT> remember this rule",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit failed watch = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.finishSlackInput(ctx, leased); err != nil {
		t.Fatal(err)
	}
	if err := svc.finishTriageRunFailure(
		ctx,
		core.AgentRun{ID: "run_failed_watch"},
		leased,
		watchTurnState{SessionID: "ses_1"},
		"watch triage failed: turn cleanup failed",
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	failed, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if failed.State != "done" {
		t.Fatalf("failed input state = %q", failed.State)
	}
	memory, err := st.GetChannelMemory(ctx, "COPS")
	if err != nil {
		t.Fatal(err)
	}
	if memory.SessionID != "" || memory.Generation != 2 ||
		memory.State.Goal != memoryState.Goal {
		t.Fatalf("detached failed session memory = %+v", memory)
	}
	if coopClient.session.State != "closed" {
		t.Fatalf("failed Coop session state = %q", coopClient.session.State)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.CleanupPending != 1 {
		t.Fatalf("cleanup pending = %d", metrics.CleanupPending)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "could not complete") {
		t.Fatalf("failure posts = %+v", slackClient.posts)
	}
}

func TestWatchSessionTerminalIncludesDiscarded(t *testing.T) {
	for state, want := range map[string]bool{
		"open": false, "exhausted": false, "closed": true, "discarded": true,
	} {
		if got := watchSessionTerminal(state); got != want {
			t.Fatalf("watchSessionTerminal(%q) = %t, want %t", state, got, want)
		}
	}
}

func TestDiscardedPersistedWatchSessionRotatesWithoutFailureNotice(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if err := st.BindChannelSession(
		ctx, "COPS", "emisar", "ses_1", 1, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	if err := st.AdvanceChannelEvents(ctx, "COPS", "ses_1", 13); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack_discarded_watch", EnvelopeID: "env_discarded_watch",
		EventID: "EvDiscardedWatch", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.600",
		UserID: cfg.Slack.Operators[0], Text: "<@U999BOT> remember this rule",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit discarded watch = %t, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.session.State = "discarded"
	coopClient.openAfterCreateKey = "responder:watch-session:COPS:2"
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, session, err := svc.ensureWatchSession(ctx, input.ChannelID)
	if err != nil {
		t.Fatal(err)
	}
	if memory.SessionID == "" || session.ID == "" || memory.Generation != 2 ||
		memory.CoopEventSequence != 0 {
		t.Fatalf("rotated channel memory = %+v", memory)
	}
	memory, err = st.GetChannelMemory(ctx, "COPS")
	if err != nil {
		t.Fatal(err)
	}
	if memory.SessionID == "" || memory.Generation != 2 ||
		memory.CoopEventSequence != 0 {
		t.Fatalf("persisted rotated channel memory = %+v", memory)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("terminal session rotation posted a failure notice: %+v", slackClient.posts)
	}
}

func TestCreateWatchSessionRefreshesStaleCreateReplay(t *testing.T) {
	cfg := serviceConfig(t)
	coopClient := newFakeCoop()
	coopClient.session.State = "discarded"
	coopClient.createResultState = "open"
	coopClient.openAfterCreateKey = "responder:watch-session:COPS:2"
	svc := &Service{cfg: cfg, coop: coopClient}

	session, generation, err := svc.createWatchSession(
		context.Background(), "COPS", "observe", 1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_2" || session.State != "open" || generation != 2 {
		t.Fatalf("refreshed session = %+v generation=%d", session, generation)
	}
	if len(coopClient.createKeys) != 2 ||
		coopClient.createKeys[0] != "responder:watch-session:COPS" ||
		coopClient.createKeys[1] != "responder:watch-session:COPS:2" {
		t.Fatalf("create keys = %v", coopClient.createKeys)
	}
}

func TestWatchTurnIdempotencyKeyTracksReplacementGeneration(t *testing.T) {
	const inputID = "slack_once"
	if got := watchTurnIdempotencyKey(inputID, 1); got != "responder:watch-turn:"+inputID {
		t.Fatalf("generation one key = %q", got)
	}
	if got := watchTurnIdempotencyKey(inputID, 2); got != "responder:watch-turn:"+inputID+":2" {
		t.Fatalf("generation two key = %q", got)
	}
}

func TestConfirmedPreferenceReachesFutureHealthPrompt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"COPS"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "message":"I can make deep health checks your operator preference.",
	  "preference_offer":{
	    "scope":"operator",
	    "name":"health_check_depth",
	    "value":"deep",
	    "expires_in":"90d"
	  }
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	request := core.SlackInput{
		ID: "slack_preference_offer", EnvelopeID: "env_preference_offer",
		EventID: "EvPreferenceOffer", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.100", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> when I ask you to check infrastructure health, " +
			"I always mean a deep check.",
	}
	if created, err := st.AdmitSlackInput(ctx, request); err != nil || !created {
		t.Fatalf("admit preference request = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) == 0 {
		run, runErr := st.GetAgentRunBySource(ctx, "watch", request.ID)
		stored, storedErr := st.GetSlackInput(ctx, request.ID)
		queueErr := svc.queueWatchedInput(ctx, stored)
		t.Fatalf(
			"preference offer produced no Slack reply: run=%+v err=%v input=%+v input_err=%v queue_err=%v",
			run, runErr, stored, storedErr, queueErr,
		)
	}
	action := findSlackAction(t, slackClient.posts[0].message, slackui.ActionRememberPreference)
	confirm := core.SlackInput{
		ID: "slack_preference_confirm", EnvelopeID: "env_preference_confirm",
		EventID: "EvPreferenceConfirm", Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: request.MessageTS, MessageTS: "1700.101",
		UserID: cfg.Slack.Operators[0], ActionID: action.ID, ActionValue: action.Value,
	}
	if created, err := st.AdmitSlackInput(ctx, confirm); err != nil || !created {
		t.Fatalf("admit preference confirmation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	preferences, err := st.ListPreferencesForContext(
		ctx, cfg.Slack.TeamID, "COPS", "repo", cfg.Slack.Operators[0], true, 20,
	)
	if err != nil || len(preferences) != 1 ||
		preferences[0].Name != "health_check_depth" ||
		preferences[0].Value != "deep" {
		t.Fatalf("saved preferences = %+v, %v", preferences, err)
	}

	coopClient.completeOnSubmit = `{"action":"reply","message":"Deep health check complete."}`
	health := core.SlackInput{
		ID: "slack_deep_health", EnvelopeID: "env_deep_health",
		EventID: "EvDeepHealth", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.200", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> check infrastructure health.",
	}
	if created, err := st.AdmitSlackInput(ctx, health); err != nil || !created {
		t.Fatalf("admit health request = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	prompt := coopClient.submitPrompts[len(coopClient.submitPrompts)-1]
	for _, expected := range []string{
		"<trusted-responder-preferences>",
		`"name":"health_check_depth"`,
		`"value":"deep"`,
		"Do not stop after an easy healthy",
	} {
		if !strings.Contains(prompt, expected) {
			t.Fatalf("deep preference prompt lacks %q:\n%s", expected, prompt)
		}
	}
}

func TestStandingRuleRunsWithProactiveOffAndRecordsOneExecution(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "message":"I can review matching Terraform plans in this channel.",
	  "rule_offer":{
	    "scope":"channel",
	    "repository":"repo",
	    "trigger":"terraform_plan",
	    "action":"review_terraform_plan",
	    "source_kind":"app",
	    "expires_in":"30d"
	  }
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	request := core.SlackInput{
		ID: "slack_rule_offer", EnvelopeID: "env_rule_offer", EventID: "EvRuleOffer",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.300", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> when you see a new message about Terraform plan here, " +
			"check it and report the main diff and red flags for each one.",
	}
	if created, err := st.AdmitSlackInput(ctx, request); err != nil || !created {
		t.Fatalf("admit rule request = %t, %v", created, err)
	}
	if cfg.IsSummonChannel(request.ChannelID) {
		t.Fatal("standing-rule setup test must exercise a non-summon channel")
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	action := findSlackAction(t, slackClient.posts[0].message, slackui.ActionRememberRule)
	confirm := core.SlackInput{
		ID: "slack_rule_confirm", EnvelopeID: "env_rule_confirm",
		EventID: "EvRuleConfirm", Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: request.MessageTS, MessageTS: "1700.301",
		UserID: cfg.Slack.Operators[0], ActionID: action.ID, ActionValue: action.Value,
	}
	if created, err := st.AdmitSlackInput(ctx, confirm); err != nil || !created {
		t.Fatalf("admit rule confirmation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	rules, err := st.ListStandingRulesForChannel(ctx, "COPS", true, 20)
	if err != nil || len(rules) != 1 {
		t.Fatalf("saved rules = %+v, %v", rules, err)
	}
	if proactive, err := svc.proactiveEnabled(ctx, "COPS"); err != nil || proactive {
		t.Fatalf("proactive setting = %t, %v", proactive, err)
	}

	plan := core.SlackInput{
		ID: "slack_plan", EnvelopeID: "env_plan", EventID: "EvPlan",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.400", UserID: "BTERRAFORM",
		Text: "Terraform plan\nPlan: 2 to add, 1 to change, 1 to destroy.",
	}
	admit, err := svc.shouldAdmitChannelMessage(ctx, core.SlackInput{
		Kind: plan.Kind, ChannelID: plan.ChannelID,
		MessageTS: plan.MessageTS, Text: plan.Text,
	})
	if err != nil || !admit {
		t.Fatalf("standing-rule admission = %t, %v", admit, err)
	}
	if created, err := st.AdmitSlackInput(ctx, plan); err != nil || !created {
		t.Fatalf("admit plan = %t, %v", created, err)
	}
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "message":"The plan adds two resources, changes one, and destroys one. The destructive operation needs owner and state verification."
	}`
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	rule, err := st.GetStandingRule(ctx, rules[0].ID)
	if err != nil || rule.TriggerCount != 1 || rule.LastTriggered.IsZero() {
		t.Fatalf("triggered rule = %+v, %v", rule, err)
	}
	lastPrompt := coopClient.submitPrompts[len(coopClient.submitPrompts)-1]
	for _, expected := range []string{
		"<trusted-responder-standing-rules>",
		rule.ID,
		"review_terraform_plan",
		"read_only",
	} {
		if !strings.Contains(lastPrompt, expected) {
			t.Fatalf("standing rule prompt lacks %q:\n%s", expected, lastPrompt)
		}
	}
	lastPost := slackClient.posts[len(slackClient.posts)-1]
	if lastPost.thread != plan.MessageTS ||
		!strings.Contains(lastPost.message.Text, "destructive operation") {
		t.Fatalf("standing rule reply = %+v", lastPost)
	}
	incidents, err := st.ListIncidents(ctx, 20)
	if err != nil || len(incidents) != 0 {
		t.Fatalf("standing rule created work = %+v, %v", incidents, err)
	}
}

func TestStandingRuleMatcherIsTypedAndSourceAware(t *testing.T) {
	cases := []struct {
		trigger string
		text    string
		want    bool
	}{
		{"terraform_plan", "Terraform plan: Plan: 1 to add, 0 to change, 0 to destroy.", true},
		{"terraform_plan", "Here is our planning document.", false},
		{"deployment", "Production rollout completed.", true},
		{"deployment", "The team planned a meeting.", false},
		{"operational_alert", "ALERT FIRING: API latency is degraded.", true},
		{"operational_alert", "Daily status is normal.", false},
	}
	for _, test := range cases {
		if got := standingRuleTextMatches(test.trigger, test.text); got != test.want {
			t.Fatalf("%s match for %q = %t, want %t",
				test.trigger, test.text, got, test.want)
		}
	}
	if standingRuleSourceMatches("app", "message") ||
		!standingRuleSourceMatches("app", "bot_message") ||
		!standingRuleSourceMatches("human", "mention") {
		t.Fatal("standing rule source matching is incorrect")
	}
}

func findSlackAction(
	t *testing.T,
	message slackui.Message,
	actionID string,
) slackui.Action {
	t.Helper()
	for _, action := range message.Actions {
		if action.ID == actionID {
			return action
		}
	}
	t.Fatalf("message has no action %q: %+v", actionID, message)
	return slackui.Action{}
}

func TestBehaviorOfferExpiryValidation(t *testing.T) {
	if !offerIssuedAtInvalid(time.Now().UTC().Add(-25*time.Hour)) ||
		!offerIssuedAtInvalid(time.Now().UTC().Add(10*time.Minute)) ||
		offerIssuedAtInvalid(time.Now().UTC()) {
		t.Fatal("behavior offer age validation is incorrect")
	}
}
