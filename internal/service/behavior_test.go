package service

import (
	"context"
	"encoding/json"
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

	input.Text = "I prefer threads by default."
	locationOffer, acknowledgement, ok := normalizeResponseLocationPreference(
		input,
		&core.PreferenceOffer{Scope: "workspace", ExpiresIn: "365d"},
	)
	if !ok || locationOffer.Scope != "operator" ||
		locationOffer.Name != "response_location" ||
		locationOffer.Value != "prefer_thread" ||
		locationOffer.ExpiresIn != "365d" ||
		!strings.Contains(acknowledgement, "replying to you") {
		t.Fatalf("operator location offer = %+v, %q, %t", locationOffer, acknowledgement, ok)
	}
	input.Text = "For everyone in the workspace, always reply in threads."
	locationOffer, _, ok = normalizeResponseLocationPreference(input, nil)
	if !ok || locationOffer.Scope != "workspace" {
		t.Fatalf("workspace location offer = %+v, %t", locationOffer, ok)
	}
	input.Text = "In this channel I prefer replies in threads."
	locationOffer, _, ok = normalizeResponseLocationPreference(input, nil)
	if !ok || locationOffer.Scope != "channel" {
		t.Fatalf("channel location offer = %+v, %t", locationOffer, ok)
	}
	input.Text = "Switch to a thread for this answer."
	if _, _, ok := normalizeResponseLocationPreference(input, nil); ok {
		t.Fatal("one-turn location request produced a durable preference")
	}
}

func TestNaturalThreadPreferenceOverridesUnsupportedModelReplyAndRoutesFutureTurn(t *testing.T) {
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
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":2},"reason":"direct preference request","message":"That durable setting is not supported.","evidence":[{"claim":"preference unsupported","observation":"no setting exists","source_type":"other","source_name":"model","target":"Responder","confidence":"low"}],"memory":{}}`,
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":2},"reason":"direct follow-up","message":"I remembered the thread preference.","memory":{}}`,
	}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	request := core.SlackInput{
		ID: "slack_location_offer", EnvelopeID: "env_location_offer",
		EventID: "EvLocationOffer", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.500", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> I prefer threads by default.",
	}
	if created, err := st.AdmitSlackInput(ctx, request); err != nil || !created {
		t.Fatalf("admit location request = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) == 0 {
		drainSlackDeliveries(t, ctx, svc)
	}
	offerPost := slackClient.posts[len(slackClient.posts)-1]
	if strings.Contains(offerPost.message.Text, "not supported") ||
		strings.Contains(strings.Join(offerPost.message.Context, " "), "Details saved") {
		t.Fatalf("location offer retained model refusal or evidence counter: %+v", offerPost.message)
	}
	action := findSlackAction(t, offerPost.message, slackui.ActionRememberPreference)
	confirm := core.SlackInput{
		ID: "slack_location_confirm", EnvelopeID: "env_location_confirm",
		EventID: "EvLocationConfirm", Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: request.MessageTS, MessageTS: "1700.501",
		UserID: cfg.Slack.Operators[0], ActionID: action.ID, ActionValue: action.Value,
	}
	if created, err := st.AdmitSlackInput(ctx, confirm); err != nil || !created {
		t.Fatalf("admit location confirmation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	followup := core.SlackInput{
		ID: "slack_location_followup", EnvelopeID: "env_location_followup",
		EventID: "EvLocationFollowup", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.600", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> where should this reply appear?",
	}
	if created, err := st.AdmitSlackInput(ctx, followup); err != nil || !created {
		t.Fatalf("admit location follow-up = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	last := slackClient.posts[len(slackClient.posts)-1]
	if last.thread != followup.MessageTS || last.broadcast {
		t.Fatalf("remembered thread route = %+v", last)
	}
}

func TestCompoundThreadAndAlertBehaviorRequestPreservesEveryClause(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"COPS"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,"ownership":3},"reason":"lasting channel behavior","message":"I can remember the thread preference.","preference_offer":{"scope":"channel","name":"response_location","value":"prefer_thread","expires_in":"90d"},"memory":{}}`,
		`{"action":"incident","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3},"reason":"The critical checkout alert needs investigation.","title":"Critical checkout error rate","evidence":[{"claim":"checkout errors are firing","observation":"the app reports an error rate above 20 percent","source_type":"slack","source_name":"Grafana alert"}],"memory":{}}`,
		fmt.Sprintf(`{"action":"reply","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3},"reason":"fresh repository and live evidence confirm the alert","message":"**Checkout errors are affecting current requests:** more than 20 percent are failing.\n\nRemove the unhealthy backend from service and verify the error rate falls. The durable fix is to correct the deployment regression and add a rollout guard for checkout errors.","alert_assessment":{"verdict":"confirmed_issue","impact":"More than 20 percent of current checkout requests fail.","cause_status":"identified","cause":"One load balancer backend is unhealthy after the current deployment.","immediate_action":"Remove the unhealthy backend from service.","verification":"Confirm checkout errors return below the alert threshold after the backend is removed.","long_term_solution":"Correct the deployment regression and add a checkout-error rollout guard."},"evidence":[{"claim":"checkout topology has two backends","observation":"the production manifest declares two checkout backends behind the load balancer","source_type":"repository","source_name":"infra/checkout.tf"},{"claim":"checkout errors remain elevated","observation":"the live checkout error rate is 20.5 percent and one backend is unhealthy","source_type":"emisar","source_name":"Emisar checkout health","observed_at":%q}],"coverage":[{"layer":"change","status":"healthy","source":"infra/checkout.tf","detail":"the declared two-backend topology was reconciled"},{"layer":"application","status":"unhealthy","source":"Emisar checkout health","detail":"current requests are failing"},{"layer":"slo","status":"degraded","source":"Emisar checkout health","detail":"error rate exceeds the alert threshold"}],"completion":{"status":"decision_ready","verdict":"unhealthy","summary":"The checkout alert is a confirmed current issue with a bounded immediate remediation."},"memory":{"situation_summary":"A critical checkout error-rate alert was confirmed from repository and live evidence.","decisions":["Continue the alert investigation in its source thread."]}}`, observedAt),
	}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	request := core.SlackInput{
		ID: "slack_compound_behavior", EnvelopeID: "env_compound_behavior",
		EventID: "EvCompoundBehavior", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1701.100", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> in this channel prefer threads and react for alerts, " +
			"investigate them, suggest fixes and suggest immediate remediation for critical ones",
	}
	if created, err := st.AdmitSlackInput(ctx, request); err != nil || !created {
		t.Fatalf("admit compound behavior request = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) == 0 {
		drainSlackDeliveries(t, ctx, svc)
	}
	offerPost := slackClient.posts[len(slackClient.posts)-1]
	preferenceAction := findSlackAction(
		t, offerPost.message, slackui.ActionRememberPreference,
	)
	ruleAction := findSlackAction(t, offerPost.message, slackui.ActionRememberRule)
	content := offerPost.message.Text + "\n" +
		strings.Join(offerPost.message.Sections, "\n") + "\n" +
		strings.Join(offerPost.message.Context, "\n")
	for _, expected := range []string{
		"separate settings", "Reply location", "Proposed standing rule",
		"acknowledge with :eyes:", "focused fixes", "critical alerts",
		"safest immediate remediation", "read-only",
	} {
		if !strings.Contains(content, expected) {
			t.Fatalf("compound offer lacks %q:\n%s", expected, content)
		}
	}

	for index, action := range []slackui.Action{preferenceAction, ruleAction} {
		confirm := core.SlackInput{
			ID:         fmt.Sprintf("slack_compound_confirm_%d", index),
			EnvelopeID: fmt.Sprintf("env_compound_confirm_%d", index),
			EventID:    fmt.Sprintf("EvCompoundConfirm%d", index), Kind: "action",
			TeamID: cfg.Slack.TeamID, ChannelID: request.ChannelID,
			ThreadTS: request.MessageTS, MessageTS: fmt.Sprintf("1701.10%d", index+1),
			UserID: cfg.Slack.Operators[0], ActionID: action.ID, ActionValue: action.Value,
		}
		if created, err := st.AdmitSlackInput(ctx, confirm); err != nil || !created {
			t.Fatalf("admit compound confirmation %d = %t, %v", index, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatal(err)
		}
	}
	preferences, err := st.ListPreferencesForContext(
		ctx, cfg.Slack.TeamID, request.ChannelID, "repo", request.UserID, true, 20,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(preferences) != 1 || preferences[0].Name != "response_location" ||
		preferences[0].Value != "prefer_thread" {
		t.Fatalf("saved compound preference = %+v", preferences)
	}
	rules, err := st.ListStandingRulesForChannel(ctx, request.ChannelID, true, 20)
	if err != nil || len(rules) != 1 || rules[0].Trigger != "operational_alert" ||
		rules[0].Action != "triage_alert" || rules[0].SourceKind != "app" {
		t.Fatalf("saved compound rules = %+v, %v", rules, err)
	}
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: request.ChannelID, Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: request.UserID,
	}); err != nil {
		t.Fatal(err)
	}

	alert := core.SlackInput{
		ID: "slack_compound_alert", EnvelopeID: "env_compound_alert",
		EventID: "EvCompoundAlert", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
		ChannelID: request.ChannelID, MessageTS: "1701.200", UserID: "BGRAFANA",
		Text: "CRITICAL alert: checkout error rate is firing above 20 percent.",
	}
	if created, err := st.AdmitSlackInput(ctx, alert); err != nil || !created {
		t.Fatalf("admit matching alert = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.reactions) != 1 || slackClient.reactions[0].name != "eyes" ||
		slackClient.reactions[0].timestamp != alert.MessageTS {
		t.Fatalf("alert acknowledgement = %+v", slackClient.reactions)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.removedReactions) != 0 {
		t.Fatalf("alert acknowledgement cleared before deep triage completed: %+v", slackClient.removedReactions)
	}
	finishQueuedAgentRun(t, ctx, svc)
	correctionPrompt := coopClient.submitPrompts[len(coopClient.submitPrompts)-1]
	if !strings.Contains(correctionPrompt, "decision-ready alert assessment") {
		t.Fatalf("shallow alert decision was not corrected:\n%s", correctionPrompt)
	}
	if len(slackClient.removedReactions) != 1 ||
		slackClient.removedReactions[0].name != "eyes" ||
		slackClient.removedReactions[0].timestamp != alert.MessageTS {
		t.Fatalf("cleared alert acknowledgement = %+v", slackClient.removedReactions)
	}
	last := slackClient.posts[len(slackClient.posts)-1]
	if last.thread != alert.MessageTS || !strings.Contains(last.message.Text, "Checkout errors") {
		t.Fatalf("alert triage reply = %+v", last)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 0 {
		t.Fatalf("reply-only alert policy created incidents = %+v, %v", incidents, err)
	}
	memory, err := st.GetChannelMemory(ctx, alert.ChannelID)
	if err != nil {
		t.Fatal(err)
	}
	memoryJSON, err := json.Marshal(memory.State)
	if err != nil {
		t.Fatal(err)
	}
	memoryText := strings.ToLower(string(memoryJSON))
	if strings.Contains(memoryText, "existing incident") ||
		strings.Contains(memoryText, "incident is being opened") ||
		strings.Contains(memoryText, "no incident was created") ||
		!strings.Contains(memoryText, "source thread") {
		t.Fatalf("normalized alert memory = %s", memoryJSON)
	}
}

func TestStructuredResponsesAllowCompoundDurableOffers(t *testing.T) {
	decision, err := decisionpkg.DecodeWatchDecision(`{
	  "action":"reply",
	  "message":"Confirm both settings.",
	  "preference_offer":{"scope":"channel","name":"response_location","value":"prefer_thread"},
	  "rule_offer":{"scope":"channel","repository":"repo","trigger":"operational_alert","action":"triage_alert","source_kind":"app"}
	}`, testDecodeClock)
	if err != nil || decision.PreferenceOffer == nil || decision.RuleOffer == nil {
		t.Fatalf("compound watch decision = %+v, %v", decision, err)
	}
	report, err := decisionpkg.DecodeAgentReport(`{
	  "message":"Confirm both settings.",
	  "preference_offer":{"scope":"channel","name":"response_location","value":"prefer_thread"},
	  "rule_offer":{"scope":"channel","repository":"repo","trigger":"operational_alert","action":"triage_alert","source_kind":"app"}
	}`)
	if err != nil || report.PreferenceOffer == nil || report.RuleOffer == nil {
		t.Fatalf("compound agent report = %+v, %v", report, err)
	}
	approvalAndSchedule, err := decisionpkg.DecodeWatchDecision(`{
	  "action":"reply",
	  "message":"Runbook publication is waiting in Emisar. The daily review is ready for separate confirmation.",
	  "pending_approval":{"request_id":"apr_1","run_id":"run_1","operation_id":"op_1","action_id":"runbooks.publish","pack_ref":"runbooks@1#sha256:abc","runner_ref":"control~abc","status":"pending_approval","approval_url":"https://emisar.dev/app/acme/approvals/apr_1","expires_at":"2026-08-02T00:00:00Z"},
	  "schedule_offer":{"title":"Daily health review","prompt":"Run a fresh deep health review.","repository":"repo","recurrence":"daily","local_time":"09:00","timezone":"UTC","catch_up":"latest","expires_in":"90d"}
	}`, testDecodeClock)
	if err != nil || approvalAndSchedule.PendingApproval == nil ||
		approvalAndSchedule.ScheduleOffer == nil {
		t.Fatalf("approval and schedule decision = %+v, %v", approvalAndSchedule, err)
	}
}

func TestAlertAssessmentRequiresDecisionUsefulRemediation(t *testing.T) {
	for name, raw := range map[string]string{
		"missing durable solution": `{
		  "action":"reply",
		  "message":"The alert is likely real.",
		  "alert_assessment":{"verdict":"likely_issue","impact":"Requests may be slow.","immediate_action":"Drain the affected node."}
		}`,
		"unknown verdict": `{
		  "action":"reply",
		  "message":"The alert needs work.",
		  "alert_assessment":{"verdict":"maybe","impact":"Unknown.","immediate_action":"Check it."}
		}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decisionpkg.DecodeWatchDecision(raw, testDecodeClock); err == nil {
				t.Fatalf("accepted incomplete alert assessment: %s", raw)
			}
		})
	}
	decision, err := decisionpkg.DecodeWatchDecision(`{
	  "action":"reply",
	  "message":"The alert is not verified because the live runner is unavailable.",
	  "alert_assessment":{"verdict":"unverified","impact":"Current impact is unknown.","immediate_action":"Restore the read-only runner and repeat the storage check."}
	}`, testDecodeClock)
	if err != nil || decision.AlertAssessment == nil ||
		decision.AlertAssessment.Verdict != "unverified" {
		t.Fatalf("valid alert assessment = %+v, %v", decision, err)
	}
}

func TestWatchDecisionNormalizesRecoverableCompletionVerdictMistakes(t *testing.T) {
	decision, err := decisionpkg.DecodeWatchDecision(`{
	  "action":"reply",
	  "message":"The repair is behind schedule but still progressing.",
	  "alert_assessment":{"verdict":"confirmed_issue","impact":"The repair missed its cadence.","cause_status":"bounded","cause":"The current cycle is taking longer than its configured interval.","immediate_action":"Let the active repair finish.","verification":"Confirm progress reaches 100 percent and the overdue gauge clears.","long_term_solution":"Deploy the Reaper scheduling fix."},
	  "completion":{"status":"decision_ready","verdict":"confirmed_issue","summary":"The overdue repair is active but progressing."}
	}`, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	if decision.Completion == nil || decision.Completion.Verdict != "degraded" {
		t.Fatalf("normalized completion = %+v", decision.Completion)
	}

	inferred, err := decisionpkg.DecodeWatchDecision(`{
	  "action":"reply",
	  "message":"The repair is behind schedule but still progressing.",
	  "alert_assessment":{"verdict":"confirmed_issue","impact":"The repair missed its cadence.","cause_status":"bounded","cause":"The current cycle is taking longer than its configured interval.","immediate_action":"Let the active repair finish.","verification":"Confirm progress reaches 100 percent and the overdue gauge clears.","long_term_solution":"Deploy the Reaper scheduling fix."},
	  "completion":{"status":"decision_ready","summary":"The overdue repair is active but progressing."}
	}`, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	decisionpkg.NormalizeAppAlertCompletion(core.SlackInput{
		Kind: "bot_message", Text: "FIRING: Cassandra repair overdue",
	}, &inferred)
	if inferred.Completion == nil || inferred.Completion.Verdict != "degraded" {
		t.Fatalf("inferred completion = %+v", inferred.Completion)
	}

	blocked, err := decisionpkg.DecodeWatchDecision(`{
	  "action":"reply",
	  "message":"The exact repair completed, but the result needs correction.",
	  "alert_assessment":{"verdict":"not_issue","impact":"The overdue condition cleared."},
	  "completion":{"status":"blocked","verdict":"healthy","summary":"Broader health was not checked.","material_gaps":["application health"],"blocker_kind":"source_unavailable","attempts":["verified the repair status"],"next_action":"check application traffic"}
	}`, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	if blocked.Completion == nil || blocked.Completion.Verdict != "" {
		t.Fatalf("blocked completion retained verdict = %+v", blocked.Completion)
	}
}

func TestAlertTriageCorrectionRejectsShallowEvidence(t *testing.T) {
	input := core.SlackInput{Text: "FIRING: storage latency is above 50 ms"}
	state := decisionpkg.WatchTurnState{MatchedRules: []core.StandingRule{{
		Trigger: "operational_alert", Action: "triage_alert",
	}}}
	assessment := &decisionpkg.AlertAssessment{
		Verdict: "likely_issue", Impact: "One database host may be slow.",
		CauseStatus: "bounded", Cause: "Both devices on one host share a degraded storage path.",
		ImmediateAction:  "Drain the host if latency persists.",
		Verification:     "Confirm device latency returns below 50 ms after draining.",
		LongTermSolution: "Repair the shared storage path.",
	}
	now := time.Now().UTC()
	repositoryEvidence := core.Evidence{
		Claim: "three Cassandra hosts are declared", Observation: "inventory contains three hosts",
		SourceType: "repository", SourceName: "infra/inventory",
	}
	liveEvidence := core.Evidence{
		Claim: "latency is elevated", Observation: "both devices exceed 50 ms",
		SourceType: "emisar", SourceName: "storage health", ObservedAt: now,
	}
	for name, decision := range map[string]decisionpkg.WatchDecision{
		"symptom summary": {Action: "reply", Message: "Both devices are slow."},
		"no topology": {
			Action: "reply", Message: "Likely shared-path issue.", AlertAssessment: assessment,
			Evidence: []core.Evidence{liveEvidence},
		},
		"no fresh live observation": {
			Action: "reply", Message: "Likely shared-path issue.", AlertAssessment: assessment,
			Evidence: []core.Evidence{repositoryEvidence, {
				Claim: "latency was elevated", Observation: "both devices exceeded 50 ms",
				SourceType: "monitoring", SourceName: "metrics", ObservedAt: now.Add(-time.Hour),
			}},
		},
	} {
		t.Run(name, func(t *testing.T) {
			if correction := decisionpkg.WatchDecisionCorrection(input, state, decision, operationalCorrelationKey); correction == "" {
				t.Fatalf("accepted shallow alert decision: %+v", decision)
			}
		})
	}
	complete := decisionpkg.WatchDecision{
		Action: "reply", Message: "Likely shared-path issue.", AlertAssessment: assessment,
		Evidence: []core.Evidence{repositoryEvidence, liveEvidence},
	}
	if correction := decisionpkg.WatchDecisionCorrection(input, state, complete, operationalCorrelationKey); correction != "" {
		t.Fatalf("rejected decision-ready alert: %s", correction)
	}
	state.FailureDetail = "the first alert reply was incomplete"
	if correction := decisionpkg.WatchDecisionCorrection(
		input, state, decisionpkg.WatchDecision{Action: "ignore"}, operationalCorrelationKey,
	); correction == "" {
		t.Fatal("corrected alert investigation was allowed to disappear")
	}
}

func TestRecoveredAlertCanCloseFromFreshExactEvidenceWithoutRepositorySweep(t *testing.T) {
	now := time.Date(2026, 8, 5, 15, 0, 20, 0, time.UTC)
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 RESOLVED:1] WARNING | Cassandra repair overdue\n" +
			"sts_ks overdue gauge returned to zero.",
	}
	state := decisionpkg.WatchTurnState{AlertPolicy: "reply_here"}
	decision := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "The scheduled `sts_ks` repair completed, closing the earlier alert.",
		AlertAssessment: &decisionpkg.AlertAssessment{
			Verdict: "not_issue",
			Impact:  "The overdue repair condition is no longer active.",
		},
		Evidence: []core.Evidence{{
			Claim:       "the scheduled repair completed",
			Observation: "progress reached 100% and the overdue gauge returned to zero",
			SourceType:  "emisar",
			SourceName:  "Cassandra repair status",
			ObservedAt:  now,
		}},
		Completion: &completionAssessment{
			Status:  "decision_ready",
			Verdict: "healthy",
			Summary: "The scheduled repair completed.",
		},
	}
	if correction := decisionpkg.WatchDecisionCorrectionAt(input, state, decision, now, operationalCorrelationKey); correction != "" {
		t.Fatalf("rejected exact recovered-alert evidence: %s", correction)
	}
}

func TestRecoveredAlertCorrectsBlockedBroadAssessmentAndRequiresPriorLink(t *testing.T) {
	now := time.Date(2026, 8, 5, 15, 0, 20, 0, time.UTC)
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 RESOLVED:1] WARNING | Cassandra repair overdue\n" +
			"sts_ks overdue gauge returned to zero.",
	}
	state := decisionpkg.WatchTurnState{
		AlertPolicy: "reply_here",
		RecentMessages: []decisionpkg.WatchContextMessage{{
			SenderType:  "external_app",
			Text:        "[VA1 FIRING:1] WARNING | Cassandra repair overdue",
			MessageLink: "https://app.slack.com/client/T123/C123/thread/C123-1700.100",
		}},
	}
	decision := decisionpkg.WatchDecision{
		Action:          "reply",
		Message:         "The scheduled repair completed.",
		AlertAssessment: &decisionpkg.AlertAssessment{Verdict: "not_issue", Impact: "The overdue condition cleared."},
		Evidence: []core.Evidence{{
			Claim: "the repair completed", Observation: "progress reached 100 percent",
			SourceType: "emisar", SourceName: "repair status", ObservedAt: now,
		}},
		Completion: &completionAssessment{
			Status: "blocked", Summary: "Broader health was not checked.",
			MaterialGaps: []string{"application health"}, BlockerKind: "source_unavailable",
			Attempts: []string{"verified the repair"}, NextAction: "check application traffic",
		},
	}
	if correction := decisionpkg.WatchDecisionCorrectionAt(input, state, decision, now, operationalCorrelationKey); correction == "" {
		t.Fatal("accepted a blocked completion for an exactly verified recovery")
	}
	decision.Completion = &completionAssessment{
		Status: "decision_ready", Verdict: "healthy", Summary: "The repair completed.",
	}
	if correction := decisionpkg.AlertReplyLanguageCorrectionWithContext(input, state, decision); correction == "" ||
		!strings.Contains(correction, state.RecentMessages[0].MessageLink) {
		t.Fatalf("recovery link correction = %q", correction)
	}
	decision.Message = "The scheduled repair completed, closing [the earlier alert](" +
		state.RecentMessages[0].MessageLink + ")."
	if correction := decisionpkg.AlertReplyLanguageCorrectionWithContext(input, state, decision); correction != "" {
		t.Fatalf("rejected linked recovery closure: %s", correction)
	}
	decision.Message = "The scheduled repair completed."
	linked, adjusted := decisionpkg.EnforceRecoveredAlertLink(input, state, decision)
	if !adjusted || !strings.Contains(linked.Message, state.RecentMessages[0].MessageLink) {
		t.Fatalf("host-linked recovery = %+v, adjusted=%t", linked, adjusted)
	}
}

func TestOperationalAlertReplyLeadsWithPlainServiceState(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 RESOLVED:2] CRITICAL | Scrape target down\n" +
			"Target typesense-metrics on nomad-hst01 is DOWN",
	}
	for name, message := range map[string]string{
		"monitoring event as subject": "**This resolution is not workload recovery.** Typesense is down.",
		"monitoring shorthand":        "**Typesense is still down.** The alert split moved to an exporter-deficit alert.",
		"architecture narration":      "**Typesense has recovered at the host, scheduler, and workload layers.** One alert path check remains.",
		"implementation nouns":        "**Typesense metrics scraping recovered.** Consul has three exporter registrations and Nomad has one allocation per group.",
		"acknowledgement narration":   "**Typesense remains down; acknowledging the incident did not restore service.**",
		"unfinished investigation":    "**Typesense is down.** The fault remains bounded to its current allocation state.",
	} {
		t.Run(name, func(t *testing.T) {
			decision := decisionpkg.WatchDecision{Action: "reply", Message: message}
			if correction := alertReplyLanguageCorrection(input, decision); correction == "" {
				t.Fatalf("accepted cryptic operational reply %q", message)
			}
		})
	}
	good := decisionpkg.WatchDecision{
		Action: "reply",
		Message: "**Typesense is still down.** Grafana marked this alert resolved because " +
			"monitoring stopped seeing the failed node; the service did not recover.\n\n" +
			"All three instances are stopped because they could not pull their images. Fix the " +
			"local image mirror, then verify all three instances are running and visible to monitoring.",
	}
	if correction := alertReplyLanguageCorrection(input, good); correction != "" {
		t.Fatalf("rejected plain operational reply: %s", correction)
	}
}

func TestOperationalAlertReplyEditsToTheDecisionUsefulDelta(t *testing.T) {
	active := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 FIRING:1] WARNING | Cassandra repair overdue",
	}
	verboseActive := decisionpkg.WatchDecision{
		Action: "reply",
		Message: "Cassandra remains available, but the sts_ks repair schedule is genuinely degraded: " +
			"its last completed cycle was 5.625 days ago, beyond the five-day interval plus grace. " +
			"The active repair is progressing from 73.10% to 74.62% during this check, so it is not " +
			"stalled. Traffic shows no error spike. All three Cassandra nodes are Up/Normal, compaction " +
			"backlog is below Reaper's limit, and every node has four storage paths. Do not start an " +
			"overlapping repair. Let this run finish; success is 100% progress and the overdue gauge " +
			"returning to zero. If overruns recur, compare runtimes around today's Reaper 5.0.0 upgrade " +
			"and tune cadence or repair parameters.",
	}
	if correction := alertReplyLanguageCorrection(active, verboseActive); correction == "" {
		t.Fatal("accepted an evidence-inventory alert reply")
	}
	conciseActive := decisionpkg.WatchDecision{
		Action: "reply",
		Message: "**`sts_ks` repair is behind schedule**, but the active repair advanced from " +
			"73.10% to 74.62% during this check and traffic has no error spike, so there is nothing " +
			"to do right now.\n\nThis matches the known Reaper issue; version 5.0.0 is already deploying " +
			"with the fix.",
	}
	if correction := alertReplyLanguageCorrection(active, conciseActive); correction != "" {
		t.Fatalf("rejected concise active alert: %s", correction)
	}

	resolved := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 RESOLVED:1] WARNING | Cassandra repair overdue",
	}
	verboseResolved := decisionpkg.WatchDecision{
		Action: "reply",
		Message: "Cassandra Reaper has recovered: the sts_ks repair reached 100%, its overdue " +
			"gauge returned to zero, and the completion-age metric reset. All three Cassandra nodes " +
			"remain Up/Normal, compaction backlog is negligible, every node has four storage paths, " +
			"and the five-minute 5xx rate is 0.0981%. No mitigation is needed, and another repair " +
			"should not be started. Keep this cycle's runtime for comparison; if later cycles also " +
			"exceed the five-day cadence, compare them around the Reaper 5.0.0 upgrade before tuning " +
			"the schedule or repair parameters.",
		AlertAssessment: &decisionpkg.AlertAssessment{Verdict: "not_issue"},
	}
	if correction := alertReplyLanguageCorrection(resolved, verboseResolved); correction == "" {
		t.Fatal("accepted a verbose recovered-alert inventory")
	}
	conciseResolved := decisionpkg.WatchDecision{
		Action:          "reply",
		Message:         "**`sts_ks` is fully repaired**, closing [the earlier alert](https://app.slack.com/client/T123/C123/thread/C123-1700.100).",
		AlertAssessment: &decisionpkg.AlertAssessment{Verdict: "not_issue"},
	}
	if correction := alertReplyLanguageCorrection(resolved, conciseResolved); correction != "" {
		t.Fatalf("rejected concise recovered alert: %s", correction)
	}
}

func TestWatchContextIncludesExactSlackThreadLink(t *testing.T) {
	message := watchPromptMessage(core.SlackInput{
		TeamID: "T123ABC", ChannelID: "C456DEF", MessageTS: "1700.200",
		ThreadTS: "1700.100", Kind: "bot_message", Text: "Alert resolved",
	}, "U999BOT", false)
	if message.MessageLink != "https://app.slack.com/client/T123ABC/C456DEF/thread/C456DEF-1700.100" {
		t.Fatalf("message link = %q", message.MessageLink)
	}
	if link := slackMessageLink(core.SlackInput{
		TeamID: "T123ABC", ChannelID: "C456DEF", MessageTS: "not-a-timestamp",
	}); link != "" {
		t.Fatalf("unsafe message link = %q", link)
	}
}

func TestAppAlertReplyOmitsInternalEvidenceCount(t *testing.T) {
	s := &Service{sanitizer: slackui.NewSanitizer(16 << 10)}
	message := s.watchReplyMessage(
		core.SlackInput{Kind: "bot_message"},
		"Typesense is still down.",
		[]core.Evidence{{Claim: "Typesense is down", SourceType: "emisar"}},
		[]core.Coverage{{Layer: "workload", Status: "degraded"}},
	)
	if len(message.Context) != 0 {
		t.Fatalf("app alert exposed evidence bookkeeping: %#v", message.Context)
	}
	if message.Markdown != "Typesense is still down." {
		t.Fatalf("markdown = %q", message.Markdown)
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
		decisionpkg.WatchTurnState{SessionID: "ses_1"},
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
	cleanup, err := st.NextCleanup(ctx, time.Now().UTC())
	if err != nil || cleanup.SessionID != "ses_1" {
		t.Fatalf("failed session was not immediately eligible for cleanup: %+v, %v", cleanup, err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "could not complete") {
		t.Fatalf("failure posts = %+v", slackClient.posts)
	}
}

func TestAmbientBotAlertFailureDoesNotPostToSlack(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slack_failed_grafana_alert", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CALERTS",
		MessageTS: "1700.900", UserID: "B_GRAFANA",
		Text: "FIRING: allocation memory is near its limit",
	}
	if err := svc.finishTriageRunFailure(
		ctx,
		core.AgentRun{ID: "run_failed_grafana_alert"},
		input,
		decisionpkg.WatchTurnState{},
		"Coop API invalid_request (400): prompt must be bounded UTF-8 text",
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 {
		t.Fatalf("ambient alert failure posts = %+v", slackClient.posts)
	}
	if publishTriageFailure(input, decisionpkg.WatchTurnState{}) {
		t.Fatal("ambient app alert failure is publishable")
	}
	if !publishTriageFailure(input, decisionpkg.WatchTurnState{ApprovalContinuation: true}) {
		t.Fatal("approval continuation failure was suppressed")
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

func TestMentionOnlyFollowupNudgesExistingWork(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = false
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	existing, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.100",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: "request",
		NextAttemptAt: time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	nudge := core.SlackInput{
		ID: "slack_nudge", EnvelopeID: "env_nudge", EventID: "event_nudge",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		ThreadTS: "1700.100", MessageTS: "1700.200", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT>",
	}
	if created, err := st.AdmitSlackInput(ctx, nudge); err != nil || !created {
		t.Fatalf("admit nudge = %t, %v", created, err)
	}
	storedInput, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.queueWatchedInput(ctx, storedInput); err != nil {
		t.Fatal(err)
	}
	storedInput, err = st.GetSlackInput(ctx, nudge.ID)
	if err != nil || storedInput.State != "done" {
		t.Fatalf("finished nudge = %+v, %v", storedInput, err)
	}
	if _, err := st.GetAgentRunBySource(ctx, "watch", nudge.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("nudge queued duplicate work: %v", err)
	}
	storedRun, err := st.GetAgentRun(ctx, existing.ID)
	if err != nil || storedRun.NextAttemptAt.After(time.Now().UTC().Add(time.Minute)) {
		t.Fatalf("existing run was not woken = %+v, %v", storedRun, err)
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

func TestConversationReplyConfirmsSinglePendingPreference(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "message":"I can use threads in this channel. Confirm below so I remember it.",
	  "preference_offer":{
	    "scope":"channel",
	    "name":"response_location",
	    "value":"prefer_thread",
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
		ID: "slack_thread_preference", EnvelopeID: "env_thread_preference",
		EventID: "EvThreadPreference", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.500", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> use threads in this channel; do not post answers directly to the channel",
	}
	if created, err := st.AdmitSlackInput(ctx, request); err != nil || !created {
		t.Fatalf("admit preference request = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("preference offer posts = %+v", slackClient.posts)
	}
	findSlackAction(
		t, slackClient.posts[0].message, slackui.ActionRememberPreference,
	)

	confirmation := core.SlackInput{
		ID: "slack_thread_preference_ok", EnvelopeID: "env_thread_preference_ok",
		EventID: "EvThreadPreferenceOK", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: request.ChannelID, ThreadTS: "1700.001", MessageTS: "1700.501",
		UserID: cfg.Slack.Operators[0], Text: "Ok",
	}
	if created, err := st.AdmitSlackInput(ctx, confirmation); err != nil || !created {
		t.Fatalf("admit conversational confirmation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	preferences, err := st.ListPreferencesForContext(
		ctx, cfg.Slack.TeamID, request.ChannelID, "repo",
		cfg.Slack.Operators[0], true, 20,
	)
	if err != nil || len(preferences) != 1 ||
		preferences[0].ScopeKind != "channel" ||
		preferences[0].Name != "response_location" ||
		preferences[0].Value != "prefer_thread" {
		t.Fatalf("saved conversational preference = %+v, %v", preferences, err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("confirmation invoked Coop again: %d prompts", len(coopClient.submitPrompts))
	}

	followup := core.SlackInput{
		ChannelID: request.ChannelID, MessageTS: "1700.600",
		UserID: cfg.Slack.Operators[0], Text: "Check the latest apply failure.",
	}
	thread, _, err := svc.resolveConversationRoute(ctx, followup)
	if err != nil || thread != followup.MessageTS {
		t.Fatalf("confirmed thread route = %q, %v", thread, err)
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
	postsAfterReview := len(slackClient.posts)
	pending := core.SlackInput{
		ID: "slack_plan_pending", EnvelopeID: "env_plan_pending", EventID: "EvPlanPending",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.401", UserID: "BTERRAFORM",
		Text: "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\n" +
			"Run run-pending\nRun Planning",
	}
	if created, err := st.AdmitSlackInput(ctx, pending); err != nil || !created {
		t.Fatalf("admit pending plan = %t, %v", created, err)
	}
	// The host owns lifecycle communication. Even if the model tries to narrate
	// an intermediate state, no public reply should be posted and no model turn
	// should be needed.
	submitsBeforePending := len(coopClient.submitPrompts)
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "message":"The Terraform run is planning. I will wait for the plan."
	}`
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != postsAfterReview {
		t.Fatalf("pending lifecycle event posted a Slack reply: %+v", slackClient.posts[postsAfterReview:])
	}
	rule, err = st.GetStandingRule(ctx, rules[0].ID)
	if err != nil || rule.TriggerCount != 2 {
		t.Fatalf("rule executions after silent evaluation = %+v, %v", rule, err)
	}
	if len(coopClient.submitPrompts) != submitsBeforePending {
		t.Fatalf(
			"pending lifecycle used the model: before=%d after=%d",
			submitsBeforePending, len(coopClient.submitPrompts),
		)
	}
	incidents, err := st.ListIncidents(ctx, 20)
	if err != nil || len(incidents) != 0 {
		t.Fatalf("standing rule created work = %+v, %v", incidents, err)
	}

	failed := core.SlackInput{
		ID: "slack_plan_failed", EnvelopeID: "env_plan_failed", EventID: "EvPlanFailed",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.402", UserID: "BTERRAFORM",
		Text: "Run notification for <https://app.terraform.io/app/SME-Tenant/tenant-infra|SME-Tenant/tenant-infra>\n" +
			"<https://app.terraform.io/app/SME-Tenant/tenant-infra/runs/run-6d2hQfNJrTeyAP4T|Run run-6d2hQfNJrTeyAP4T>\n" +
			"CI apply - ddd526f205c76b0499b4d755a2a0c3d197d7acdf\nRun Errored",
	}
	if created, err := st.AdmitSlackInput(ctx, failed); err != nil || !created {
		t.Fatalf("admit terminal failure = %t, %v", created, err)
	}
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "message":"Apply failed after execution began. Do not retry it yet; inspect the exact diagnostics and reconcile state first because partial changes are still unknown.",
	  "evidence":[{
	    "claim_id":"change.recent",
	    "claim":"the run reached its intended terminal state",
	    "observation":"run-6d2hQfNJrTeyAP4T is terminally errored after apply began",
	    "relation":"contradicts",
	    "source_type":"emisar",
	    "source_name":"tfc.run_details",
	    "confidence":"high",
	    "dimensions":{"repository":"SME-Tenant/tenant-infra","environment":"production","revision":"ddd526f"}
	  }],
	  "coverage":[{
	    "layer":"change",
	    "claim_ids":["change.recent"],
	    "status":"unhealthy",
	    "detail":"The exact Terraform run is terminally errored after apply began."
	  }],
	  "completion":{
	    "status":"decision_ready",
	    "verdict":"failed",
	    "summary":"The apply failed and possible partial changes must be reconciled before retrying.",
	    "material_gaps":["the exact partial infrastructure changes are not yet known"],
	    "next_action":"Inspect terminal diagnostics and refresh state before any retry."
	  }
	}`
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != postsAfterReview+1 {
		run, runErr := st.GetAgentRunBySource(ctx, "watch", failed.ID)
		t.Fatalf(
			"terminal failure reply count = %d, want %d; run=%+v err=%v",
			len(slackClient.posts), postsAfterReview+1, run, runErr,
		)
	}
	terminalPost := slackClient.posts[len(slackClient.posts)-1]
	if terminalPost.thread != failed.MessageTS ||
		!strings.Contains(terminalPost.message.Text, "Apply failed") ||
		!strings.Contains(terminalPost.message.Text, "Do not retry") {
		t.Fatalf("terminal failure reply = %+v", terminalPost)
	}
}

func TestStandingRuleMatcherIsTypedAndSourceAware(t *testing.T) {
	cases := []struct {
		trigger string
		text    string
		want    bool
	}{
		{"terraform_plan", "Terraform plan: Plan: 1 to add, 0 to change, 0 to destroy.", true},
		{"terraform_plan", "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\nRun run-abc\nRun Planning", true},
		{"terraform_plan", "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\nRun run-abc\nRun Planned", true},
		{"terraform_plan", "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\nRun run-abc\nRun Applying", true},
		{"terraform_plan", "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\nRun run-abc\nRun Errored", true},
		{"terraform_plan", "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\nRun run-abc\nRun Discarded", true},
		{"terraform_plan", "Can you review this plan?", true},
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
	now := testDecodeClock
	if !offerIssuedAtInvalid(now.Add(-25*time.Hour), now) ||
		!offerIssuedAtInvalid(now.Add(10*time.Minute), now) ||
		offerIssuedAtInvalid(now, now) {
		t.Fatal("behavior offer age validation is incorrect")
	}
}
