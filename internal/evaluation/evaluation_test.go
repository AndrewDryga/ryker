package evaluation

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/agentprompt"
	"github.com/AndrewDryga/responder/internal/coop"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
)

func TestGoldenEvaluationCorpus(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "golden.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	summary, err := EvaluateJSONL(file)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Total < 5 || summary.Failed != 0 || summary.Passed != summary.Total {
		t.Fatalf("evaluation summary = %+v", summary)
	}
}

func TestEvaluationRendersEmisarRunbookResultAndScheduleSurface(t *testing.T) {
	cfg := serviceConfig(t)
	output := `{
		"action":"reply",
		"message":"I created and published the reusable Emisar health runbook. Confirm the daily schedule below.",
		"schedule_offer":{
			"title":"Daily deep health review",
			"prompt":"Execute the exact published Emisar runbook deep-health@1 and report its fresh evidence.",
			"repository":"repo",
			"recurrence":"daily",
			"local_time":"09:00",
			"timezone":"UTC",
			"catch_up":"latest",
			"expires_in":"90d"
		},
		"evidence":[{"claim":"the runbook is published","observation":"Emisar published deep-health@1","source_type":"emisar","source_name":"publish_runbook"}]
	}`
	message, action, err := renderEvaluationMessage(cfg, EvaluationCase{
		Kind: "watch", Input: "Schedule a daily deep health review around 9 am and create a reusable runbook.",
		MentionsResponder: true, Repository: "repo",
	}, output)
	// Supersedes the flat-Actions form: the schedule's confirmation is attached
	// to the proposal row it confirms.
	offerText := strings.Join(message.Sections, "\n")
	for _, row := range message.Rows {
		offerText += "\n" + row.Text
	}
	if err != nil || action != "reply" || len(message.Rows) != 1 ||
		len(message.Rows[0].Actions) != 1 ||
		message.Rows[0].Actions[0].ID != slackui.ActionRememberSchedule ||
		strings.Contains(offerText, "engineering task") {
		t.Fatalf("rendered compound offer = %+v, action=%q, err=%v", message, action, err)
	}
}

func TestEvaluationChecksCustomerVisibleContract(t *testing.T) {
	watchOutput := `{
	  "action":"reply",
	  "message":"Production health is degraded and database health remains unverified.",
	  "incident_title":"Investigate production health",
	  "evidence":[{
	    "claim":"runner connectivity is degraded",
	    "observation":"one runner is disconnected",
	    "source_type":"emisar",
	    "source_name":"list_runners"
	  }],
	  "coverage":[
	    {"layer":"host","status":"degraded"},
	    {"layer":"dependency","status":"unknown"}
	  ]
	}`
	passing := EvaluationCase{
		Name:                  "customer contract",
		Kind:                  "watch",
		Output:                watchOutput,
		WantAction:            "reply",
		WantOffer:             "incident",
		WantMessageContains:   []string{"degraded", "unverified"},
		ForbidMessageContains: []string{"fully healthy"},
		WantEvidenceSources:   []string{"emisar"},
		WantCoverage: map[string]string{
			"host":       "degraded",
			"dependency": "unknown",
		},
		MinEvidence:     1,
		MinCoverage:     2,
		MaxMessageBytes: 200,
	}
	if result := evaluateCase(passing); !result.Passed {
		t.Fatalf("passing customer contract = %+v", result)
	}

	cases := []struct {
		name   string
		mutate func(*EvaluationCase)
		detail string
	}{
		{
			name: "wrong offer",
			mutate: func(item *EvaluationCase) {
				item.WantOffer = "engineering_task"
			},
			detail: `offer = "incident"`,
		},
		{
			name: "missing required wording",
			mutate: func(item *EvaluationCase) {
				item.WantMessageContains = []string{"operator decision"}
			},
			detail: `does not contain "operator decision"`,
		},
		{
			name: "forbidden overclaim",
			mutate: func(item *EvaluationCase) {
				item.ForbidMessageContains = []string{"database health"}
			},
			detail: `forbidden text "database health"`,
		},
		{
			name: "missing source",
			mutate: func(item *EvaluationCase) {
				item.WantEvidenceSources = []string{"repository"}
			},
			detail: `no source_type "repository"`,
		},
		{
			name: "wrong layer status",
			mutate: func(item *EvaluationCase) {
				item.WantCoverage = map[string]string{"host": "healthy"}
			},
			detail: `status "healthy"`,
		},
		{
			name: "response too large",
			mutate: func(item *EvaluationCase) {
				item.MaxMessageBytes = 10
			},
			detail: "want at most 10",
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			item := passing
			test.mutate(&item)
			result := evaluateCase(item)
			if result.Passed || !strings.Contains(result.Detail, test.detail) {
				t.Fatalf("result = %+v, want detail containing %q", result, test.detail)
			}
		})
	}
}

func TestEvaluationRejectsPrematureDeepCompletion(t *testing.T) {
	cfg := serviceConfig(t)
	base := EvaluationCase{
		Name: "deep completion", Kind: "watch",
		Input: "Give me a deep production health assessment", MentionsResponder: true,
		RequireCompletion:    true,
		WantCompletionStatus: "decision_ready",
		Output: `{
			"action":"reply",
			"message":"The checked scope is healthy.",
			"completion":{"status":"decision_ready","verdict":"healthy","summary":"Healthy"},
			"coverage":[
				{"layer":"change","status":"healthy","detail":"revision is current"},
				{"layer":"host","status":"healthy","detail":"hosts respond"},
				{"layer":"runtime","status":"healthy","detail":"runtime responds"},
				{"layer":"workload","status":"healthy","detail":"workloads run"},
				{"layer":"dependency","status":"healthy","detail":"dependencies respond"},
				{"layer":"application","status":"healthy","detail":"transactions pass"},
				{"layer":"slo","status":"healthy","detail":"SLO is within target"}
			]
		}`,
	}
	if result := evaluateCaseWithConfig(base, &cfg, time.Now().UTC()); !result.Passed {
		t.Fatalf("decision-ready completion = %+v", result)
	}
	premature := base
	premature.Output = `{
		"action":"reply","message":"Hosts look healthy.",
		"completion":{"status":"decision_ready","verdict":"healthy","summary":"Healthy"},
		"coverage":[{"layer":"host","status":"healthy","detail":"hosts respond"}]
	}`
	if result := evaluateCaseWithConfig(premature, &cfg, time.Now().UTC()); result.Passed ||
		!strings.Contains(result.Detail, "premature completion") {
		t.Fatalf("premature completion = %+v", result)
	}
}

func TestEvaluationRejectsUnsubstantiatedDeepWorkBlocker(t *testing.T) {
	cfg := serviceConfig(t)
	testCase := EvaluationCase{
		Name: "unfinished investigation", Kind: "watch",
		Input: "Give me a deep production health assessment", MentionsResponder: true,
		Output: `{
			"action":"reply",
			"message":"Application health still needs investigation.",
			"completion":{
				"status":"blocked",
				"summary":"Application impact is unknown.",
				"material_gaps":["application impact"],
				"next_action":"Query application logs and SLO metrics"
			},
			"coverage":[
				{"layer":"change","status":"healthy","detail":"revision is current"},
				{"layer":"host","status":"healthy","detail":"hosts respond"},
				{"layer":"runtime","status":"healthy","detail":"runtime responds"},
				{"layer":"workload","status":"healthy","detail":"workloads run"},
				{"layer":"dependency","status":"healthy","detail":"dependencies respond"},
				{"layer":"application","status":"unknown","detail":"not queried"},
				{"layer":"slo","status":"unknown","detail":"not queried"}
			]
		}`,
	}
	result := evaluateCaseWithConfig(testCase, &cfg, time.Now().UTC())
	if result.Passed || !strings.Contains(result.Detail, "blocker_kind") {
		t.Fatalf("unsubstantiated blocker = %+v", result)
	}
}

func TestEvaluationRendersGenuineBlockerAsSlackGuidance(t *testing.T) {
	cfg := serviceConfig(t)
	message, action, err := renderEvaluationMessage(cfg, EvaluationCase{
		Name: "blocked health", Kind: "watch",
	}, `{
		"action":"reply",
		"message":"Scheduler state is healthy, but SLO impact is not available.",
		"completion":{
			"status":"blocked",
			"summary":"The configured SLO source denied access.",
			"material_gaps":["Current SLO and customer impact"],
			"blocker_kind":"access_denied",
			"attempts":["Queried the configured SLO source; it returned permission denied"],
			"next_action":"Grant the monitoring identity SLO read access, then retry"
		}
	}`)
	if err != nil || action != "reply" {
		t.Fatalf("render blocked assessment: action=%q err=%v", action, err)
	}
	context := strings.Join(message.Context, "\n")
	if !strings.Contains(context, "Blocked:") ||
		!strings.Contains(context, "Next:") ||
		!strings.Contains(context, "Grant the monitoring identity") {
		t.Fatalf("rendered blocker = %+v", message)
	}
}

func TestLiveEvaluationPromptCarriesProductionWorkContract(t *testing.T) {
	cfg := serviceConfig(t)
	prompt, err := liveEvaluationPrompt(cfg, EvaluationCase{
		Name: "deep health", Kind: "watch", Repository: "repo",
		Input: "Give me a deep production health assessment", MentionsResponder: true,
	}, "repo", "eval_contract")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"<host-investigation-contract>",
		`"effort":"operational_assessment"`,
		`"authority":"read_only"`,
		"A blocker is an external boundary, not unfinished work",
		"blocker_kind",
	} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("live prompt lacks %q", want)
		}
	}
}

func TestEvaluationRequiresDecisionReadyAlertAssessment(t *testing.T) {
	passing := EvaluationCase{
		Name: "decision-ready alert", Kind: "watch", WantAction: "reply",
		WantAlertAssessment: true, WantAlertVerdict: "likely_issue",
		WantImmediateAction: true, WantLongTermSolution: true,
		Output: `{
		  "action":"reply",
		  "message":"Likely storage-path issue. Drain the host if latency persists.",
		  "alert_assessment":{
		    "verdict":"likely_issue",
		    "impact":"Cassandra latency may affect requests on one host.",
		    "cause_status":"bounded",
		    "cause":"Both affected devices share the same storage path on one host.",
		    "immediate_action":"Drain the host if latency persists.",
		    "verification":"Confirm device latency returns below 50 ms after draining.",
		    "long_term_solution":"Repair the shared NVMe/TCP path and alert on path saturation."
		  }
		}`,
	}
	if result := evaluateCase(passing); !result.Passed {
		t.Fatalf("passing alert assessment = %+v", result)
	}
	passing.WantAlertVerdict = "confirmed_issue"
	if result := evaluateCase(passing); result.Passed ||
		!strings.Contains(result.Detail, "alert verdict") {
		t.Fatalf("wrong alert verdict passed = %+v", result)
	}
}

func TestEvaluationProjectsRecoveredAlertLinkFromRecentContext(t *testing.T) {
	cfg := serviceConfig(t)
	testCase := EvaluationCase{
		Name:       "recovered alert link",
		Kind:       "watch",
		SenderType: "external_app",
		Input:      "[VA1 RESOLVED:1] WARNING | Cassandra repair overdue",
		RecentMessages: []EvaluationMessage{{
			SenderType: "external_app",
			Text:       "[VA1 FIRING:1] WARNING | Cassandra repair overdue",
		}},
	}
	input, recent, _, err := liveEvaluationWatchContext(testCase, "eval", "UEVALOPERATOR")
	if err != nil {
		t.Fatal(err)
	}
	state := evaluationWatchState(testCase)
	state.RecentMessages = recent
	decision, adjusted := decisionpkg.EnforceRecoveredAlertLink(input, state, decisionpkg.WatchDecision{
		Action:          "reply",
		Message:         "The scheduled repair completed.",
		AlertAssessment: &decisionpkg.AlertAssessment{Verdict: "not_issue", Impact: "The alert cleared."},
	})
	if !adjusted || !strings.Contains(
		decision.Message,
		"https://app.slack.com/client/TEVALUATION/CEVALUATION/thread/",
	) {
		t.Fatalf("linked recovery = %+v, adjusted=%t, config=%s", decision, adjusted, cfg.Slack.TeamID)
	}

	testCase.Output = `{
	  "action":"reply",
	  "message":"The scheduled repair completed.",
	  "alert_assessment":{"verdict":"not_issue","impact":"The alert cleared."},
	  "coverage":[
	    {"layer":"change","status":"unknown","detail":"No change evidence was needed for the exact recovery."},
	    {"layer":"application","status":"unknown","detail":"Application behavior was outside the exact alert condition."},
	    {"layer":"slo","status":"healthy","detail":"The overdue gauge returned to zero."},
	    {"layer":"dependency","status":"healthy","detail":"The scheduled Cassandra repair completed."}
	  ],
	  "completion":{"status":"decision_ready","verdict":"healthy","summary":"The exact alert condition cleared."}
	}`
	testCase.WantAction = "reply"
	testCase.WantMessageContains = []string{
		"https://app.slack.com/client/TEVALUATION/CEVALUATION/thread/",
	}
	if result := evaluateCaseWithConfig(testCase, &cfg, time.Now().UTC()); !result.Passed {
		t.Fatalf("evaluated recovered alert = %+v", result)
	}
}

func TestEvaluationRequiresCompoundReplyCoverage(t *testing.T) {
	testCase := EvaluationCase{
		Name: "three independent outcomes",
		Kind: "watch",
		Output: `{
		  "action":"reply",
		  "message":"CI is green.",
		  "followup_messages":["Deployment is waiting.","Two incidents are open."]
		}`,
		WantAction:          "reply",
		MinReplyMessages:    3,
		WantMessageContains: []string{"CI", "Deployment", "incidents"},
	}
	result := evaluateCase(testCase)
	if !result.Passed {
		t.Fatalf("compound evaluation = %+v", result)
	}
	testCase.Output = `{"action":"reply","message":"CI is green."}`
	result = evaluateCase(testCase)
	if result.Passed || !strings.Contains(result.Detail, "reply messages = 1") {
		t.Fatalf("collapsed compound evaluation = %+v", result)
	}
}

func TestEvaluationAcceptsAnyAllowedNaturalReaction(t *testing.T) {
	testCase := EvaluationCase{
		Name:              "natural acknowledgement",
		Kind:              "watch",
		Output:            `{"action":"react","reaction":"thumbsup"}`,
		WantAction:        "react",
		WantReactionOneOf: []string{"white_check_mark", "thumbsup"},
	}
	if result := evaluateCase(testCase); !result.Passed {
		t.Fatalf("allowed reaction = %+v", result)
	}
	testCase.WantReactionOneOf = []string{"white_check_mark", "eyes"}
	if result := evaluateCase(testCase); result.Passed ||
		!strings.Contains(result.Detail, "want one of") {
		t.Fatalf("disallowed reaction = %+v", result)
	}
}

func TestEvaluationChecksGovernedApprovalCounts(t *testing.T) {
	wantApproval := true
	result := evaluateCase(EvaluationCase{
		Name: "pending approval",
		Kind: "incident",
		Output: `{
		  "message":"Restart is waiting for operator approval in Emisar; it has not run.",
		  "pending_approval":{
		    "request_id":"apr_123",
		    "run_id":"run_123",
		    "operation_id":"op_123",
		    "action_id":"nomad.alloc_restart",
		    "pack_ref":"nomad@1.2.3#sha256:abc",
		    "runner_ref":"prod-1~abc123",
		    "status":"pending_approval",
		    "approval_url":"https://emisar.dev/app/acme/approvals/apr_123",
		    "expires_at":"2026-07-29T00:00:00Z"
		  }
		}`,
		WantMessageContains:   []string{"waiting", "has not run"},
		ForbidMessageContains: []string{"restart completed"},
		WantPendingApproval:   &wantApproval,
	})
	if !result.Passed {
		t.Fatalf("approval contract = %+v", result)
	}

	wantApproval = false
	result = evaluateCase(EvaluationCase{
		Name:                "wrong approval expectation",
		Kind:                "incident",
		Output:              `{"message":"Waiting for approval.","pending_approval":{"request_id":"apr_123"}}`,
		WantPendingApproval: &wantApproval,
	})
	if result.Passed || !strings.Contains(result.Detail, "pending approval = true") {
		t.Fatalf("approval mismatch = %+v", result)
	}
}

func TestLiveEvaluationCallsCoopWithProductionPromptAndCleansSession(t *testing.T) {
	cfg := serviceConfig(t)
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"ignore",
	  "reason":"The humans are talking to each other.",
	  "evidence":[],
	  "coverage":[],
	  "memory":{}
	}`
	corpus := strings.NewReader(
		`{"name":"ambient conversation","kind":"watch","input":"Thanks, I will handle the deploy.","recent_messages":[{"sender_type":"human","text":"Alex, can you deploy the release?"}],"want_action":"ignore"}`,
	)

	summary, err := EvaluateLiveJSONL(
		context.Background(),
		corpus,
		cfg,
		coopClient,
		LiveEvaluationOptions{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Mode != "live" || summary.Total != 1 || summary.Passed != 1 ||
		summary.ModelCalls != 1 {
		t.Fatalf("live summary = %+v", summary)
	}
	if len(coopClient.submitPrompts) != 1 ||
		!strings.Contains(coopClient.submitPrompts[0], "shared Slack operations feed") ||
		!strings.Contains(
			coopClient.submitPrompts[0],
			`"target_is_configured_operator":true`,
		) ||
		!strings.Contains(
			coopClient.submitPrompts[0],
			"source_type must be\nexactly one of repository, emisar, monitoring, slack, or other",
		) ||
		!strings.Contains(coopClient.submitPrompts[0], "Thanks, I will handle the deploy.") {
		t.Fatalf("live prompt = %q", coopClient.submitPrompts)
	}
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf(
			"live evaluation session was not discarded: calls=%d state=%s",
			coopClient.discardCalls,
			coopClient.session.State,
		)
	}
}

func TestLiveConversationEvaluationPreparesSessionBeforeMeasuredTurn(t *testing.T) {
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "attention":{"addressee":"responder","confidence":3,"ownership":2,"contribution":"decision","material":true},
	  "reason":"ordinary arithmetic",
	  "message":"8",
	  "evidence":[],
	  "coverage":[],
	  "memory":{}
	}`
	corpus := strings.NewReader(
		`{"name":"arithmetic","kind":"watch","lane":"conversation","input":"3+5?","mentions_responder":true,"want_action":"reply","want_message_contains":["8"]}`,
	)

	summary, err := EvaluateLiveJSONL(
		context.Background(),
		corpus,
		cfg,
		coopClient,
		LiveEvaluationOptions{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Passed != 1 {
		t.Fatalf("live conversation summary = %+v", summary)
	}
	if !slices.Equal(coopClient.prepareSessions, []string{"ses_1"}) {
		t.Fatalf("prepared sessions = %v", coopClient.prepareSessions)
	}
	if len(coopClient.createPolicies) != 1 || coopClient.createPolicies[0] != "repo-conversation" {
		t.Fatalf("conversation policies = %v", coopClient.createPolicies)
	}
}

func TestLiveEvaluationContextPreservesMessagesAfterTarget(t *testing.T) {
	cfg := serviceConfig(t)
	input, recent, _, err := liveEvaluationWatchContext(
		EvaluationCase{
			Input:      "FIRING alert_id=42",
			SenderType: "external_app",
			RecentMessages: []EvaluationMessage{{
				SenderType: "human",
				Text:       "The alert just started.",
			}},
			FollowingMessages: []EvaluationMessage{{
				SenderType: "external_app",
				Text:       "RESOLVED alert_id=42",
			}},
		},
		"eval_context",
		cfg.Slack.Operators[0],
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 3 || recent[0].Target || !recent[1].Target ||
		recent[2].Target || recent[1].MessageTS != input.MessageTS ||
		recent[2].Text != "RESOLVED alert_id=42" ||
		recent[0].MessageLink != "https://app.slack.com/client/TEVALUATION/CEVALUATION/thread/CEVALUATION-1700.000001" ||
		recent[1].MessageLink == "" || recent[2].MessageLink == "" {
		t.Fatalf("ordered evaluation context = %+v, input=%+v", recent, input)
	}
}

// A case that stages a thread turn has to reach the model as one.
//
// channel_around_root is the only way a case can pose a reference that resolves
// outside its own thread — "see above", "^", a reply to a notice that asked for
// one — and a field the prompt builder quietly ignored would be a gate that
// looks like a gate and is not. That has happened here before: the prompts
// corpus shipped six cases naming a sender_type the harness never accepted, and
// nothing offline said so.
func TestAThreadSurroundCaseReachesThePromptAsAThreadTurn(t *testing.T) {
	cfg := serviceConfig(t)
	testCase := EvaluationCase{
		Kind: "watch", Input: "see in the channel above", MentionsResponder: true,
		RecentMessages: []EvaluationMessage{{
			SenderType: "human", SenderRole: "operator", Text: "<@UEVALBOT>",
		}},
		ChannelAroundRoot: []EvaluationMessage{{
			SenderType: "external_app", Text: "5xx ratio is above the threshold",
		}},
	}
	prompt, err := liveEvaluationPrompt(cfg, testCase, "repo", "eval_thread_surround")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(prompt, `"channel_messages_around_thread_root"`) ||
		!strings.Contains(prompt, "5xx ratio is above the threshold") {
		t.Fatalf("thread surround did not reach the prompt: %q", prompt)
	}
	input, recent, around, err := liveEvaluationWatchContext(
		testCase, "eval_thread_surround", "UEVALOPERATOR",
	)
	if err != nil {
		t.Fatal(err)
	}
	// Above the root, not inside the thread: a surround numbered alongside the
	// thread's own messages would pose "see above" against a transcript where
	// nothing is above.
	if input.ThreadTS == "" || input.ThreadTS != recent[0].MessageTS {
		t.Fatalf("surround case was not staged inside a thread: %+v", input)
	}
	if len(around) != 1 || around[0].MessageTS >= recent[0].MessageTS {
		t.Fatalf("channel surround does not sit above the root: %+v", around)
	}
}

func TestLiveEvaluationContextPreservesResponderMessages(t *testing.T) {
	cfg := serviceConfig(t)
	_, recent, _, err := liveEvaluationWatchContext(
		EvaluationCase{
			Input: "Did it pass?",
			RecentMessages: []EvaluationMessage{{
				SenderType: "responder",
				Text:       "I fixed the formatting and reran the check.",
			}},
		},
		"eval_responder_context",
		cfg.Slack.Operators[0],
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 2 || recent[0].SenderType != "responder" ||
		recent[0].SenderID != "UEVALBOT" || recent[0].Target {
		t.Fatalf("responder evaluation context = %+v", recent)
	}
}

func TestLiveEvaluationScoresHostValidatedEvidenceAndOffers(t *testing.T) {
	cfg := serviceConfig(t)
	memberPreference := EvaluationCase{
		Name:              "member preference",
		Kind:              "watch",
		Input:             "Remember that health checks should be deep.",
		SenderRole:        "member",
		MentionsResponder: true,
		Output: `{
		  "action":"reply",
		  "message":"I can save that.",
		  "preference_offer":{
		    "scope":"operator",
		    "name":"health_check_depth",
		    "value":"deep",
		    "expires_in":"90d"
		  }
		}`,
		WantAction: "reply",
		WantOffer:  "none",
	}
	if result := evaluateCaseWithConfig(
		memberPreference,
		&cfg,
		time.Now().UTC(),
	); !result.Passed {
		t.Fatalf("host-validated member offer = %+v", result)
	}

	invalidEvidence := EvaluationCase{
		Name:  "invalid evidence",
		Kind:  "watch",
		Input: "Check health.",
		Output: `{
		  "action":"reply",
		  "message":"Healthy.",
		  "evidence":[{
		    "claim":"healthy",
		    "observation":"command succeeded",
		    "source_type":"shell",
		    "source_name":"curl"
		  }]
		}`,
		WantEvidenceSources: []string{"emisar"},
		MinEvidence:         1,
	}
	result := evaluateCaseWithConfig(
		invalidEvidence,
		&cfg,
		time.Now().UTC(),
	)
	if result.Passed || !strings.Contains(result.Detail, `source_type "emisar"`) {
		t.Fatalf("invalid evidence result = %+v", result)
	}
}

func TestFilterEvaluationCasesMatchesNamesAndTags(t *testing.T) {
	cases := []EvaluationCase{
		{Name: "Health check", Tags: []string{"evidence"}},
		{Name: "Prompt injection", Tags: []string{"security"}},
	}
	for filter, want := range map[string]string{
		"health":   "Health check",
		"SECURITY": "Prompt injection",
	} {
		filtered := filterEvaluationCases(cases, filter)
		if len(filtered) != 1 || filtered[0].Name != want {
			t.Fatalf("filter %q = %+v, want %q", filter, filtered, want)
		}
	}
}

func TestLiveEvaluationPromptIncludesConfirmedBehaviorContext(t *testing.T) {
	cfg := serviceConfig(t)
	prompt, err := liveEvaluationPrompt(
		cfg,
		EvaluationCase{
			Name:              "trusted behavior",
			Kind:              "watch",
			Input:             "Check this Terraform plan.",
			MentionsResponder: true,
			Memories: []EvaluationMemory{{
				Scope: "workspace:TWORKSPACE", Subject: "fix_explanation_style",
				Predicate: "guidance",
				Value:     "Start fix explanations with a plain-language summary.",
				ExpiresAt: "2026-10-27T00:00:00Z",
			}},
			Preferences: []EvaluationPreference{{
				Scope: "operator:U123ABC", Name: "response_detail",
				Value: "detailed", ExpiresAt: "2026-10-27T00:00:00Z",
			}},
			StandingRules: []EvaluationStandingRule{{
				ID: "rule_eval", Trigger: "terraform_plan",
				Action: "review_terraform_plan", Repository: "$default",
				SourceKind: "app",
			}},
		},
		"repo",
		"eval_behavior",
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		`"predicate":"guidance"`,
		"Start fix explanations with a plain-language summary.",
		"<trusted-responder-preferences>",
		`"name":"response_detail"`,
		"<trusted-responder-standing-rules>",
		`"id":"rule_eval"`,
		`"repository":"repo"`,
		`"safety":"read_only"`,
	} {
		if !strings.Contains(prompt, expected) {
			t.Fatalf("behavior prompt lacks %q:\n%s", expected, prompt)
		}
	}
}

func TestLiveEvaluationDoesNotCountInvalidCaseAsModelCall(t *testing.T) {
	cfg := serviceConfig(t)
	coopClient := newFakeCoop()
	summary, err := EvaluateLiveJSONL(
		context.Background(),
		strings.NewReader(`{"name":"missing input","kind":"watch"}`),
		cfg,
		coopClient,
		LiveEvaluationOptions{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Total != 1 || summary.Failed != 1 || summary.ModelCalls != 0 {
		t.Fatalf("invalid live summary = %+v", summary)
	}
	if len(coopClient.createKeys) != 0 || len(coopClient.submitKeys) != 0 {
		t.Fatalf(
			"invalid case called Coop: create=%v submit=%v",
			coopClient.createKeys,
			coopClient.submitKeys,
		)
	}
}

func TestEvaluationQualityParserAndSlackUXRejectBadSurfaces(t *testing.T) {
	good, err := parseQualityAssessment(`{
	  "passed":true,
	  "human_likeness":5,
	  "conversational_fit":5,
	  "directness":4,
	  "productivity":4,
	  "slack_fit":5,
	  "evidence_discipline":5,
	  "critical_failures":[],
	  "reason":"Direct and useful."
	}`)
	if err != nil || !good.Passed || good.MeanScore < 4.6 {
		t.Fatalf("good quality = %+v, %v", good, err)
	}
	bad, err := parseQualityAssessment(`{
	  "passed":true,
	  "human_likeness":5,
	  "conversational_fit":5,
	  "directness":5,
	  "productivity":5,
	  "slack_fit":5,
	  "evidence_discipline":5,
	  "critical_failures":["claims an unverified deployment"],
	  "reason":"Unsafe claim."
	}`)
	if err != nil || bad.Passed {
		t.Fatalf("critical failure quality = %+v, %v", bad, err)
	}
	verification, err := parseEvidenceVerification(`I am checking the cited sources before judging the answer.
{"supported":false,"verified_sources":["current metrics"],"unsupported_claims":["healthy application behavior"],"material_gaps":["functional probe"],"reason":"The report overstates application health."}`)
	if err != nil || verification.Passed || len(verification.UnsupportedClaims) != 1 {
		t.Fatalf("prefixed verification = %+v, %v", verification, err)
	}
	gapDetail := evidenceVerificationFailure(EvidenceVerification{
		MaterialGaps: []string{"affected workflow was not checked"},
		Reason:       "The verdict needs one more source.",
	})
	if !strings.Contains(gapDetail, "material gaps: affected workflow was not checked") ||
		!strings.Contains(gapDetail, "reason: The verdict needs one more source.") {
		t.Fatalf("verification failure detail = %q", gapDetail)
	}

	ux := assessSlackUX(slackui.Message{
		Text:     "Fallback",
		Markdown: `{"action":"reply"}`,
		Sections: []string{
			"No merge occurred.",
			"No merge occurred.",
			"No merge occurred.",
		},
		Actions: []slackui.Action{
			{ID: "same", Label: "First"},
			{ID: "same", Label: "Second", URL: "http://example.com"},
		},
	}, "reply")
	if ux.Passed ||
		!slices.Contains(ux.Issues, "transport JSON leaked into the Slack response") ||
		!slices.Contains(ux.Issues, "duplicate action ID same") {
		t.Fatalf("bad Slack UX = %+v", ux)
	}

	incidentFooter := slackui.ConversationResponseWithIncidentOffer(
		"Production is degraded.", "slack-source", slackui.NewSanitizer(12000),
	)
	incidentFooter.Context = []string{
		"No incident has been created. Opening one creates a dedicated room.",
	}
	encodedFooter, err := slackui.Encode(incidentFooter)
	if err != nil {
		t.Fatal(err)
	}
	assessment, err := AssessSlackDeliveryUX(encodedFooter, "reply")
	if err == nil || assessment.Passed ||
		!slices.Contains(assessment.Issues, "incident offer has a redundant context footer") {
		t.Fatalf("incident footer assessment = %+v, %v", assessment, err)
	}
}

func TestEvaluationMetricsAndRegressionGate(t *testing.T) {
	summary := EvaluationSummary{
		CorpusDigest: "digest",
		Total:        4,
		Passed:       3,
		Failed:       1,
		Results: []EvaluationResult{
			{Name: "answer [1/2]", CaseName: "answer", Passed: true},
			{Name: "answer [2/2]", CaseName: "answer", Passed: false},
			{Name: "silence [1/2]", CaseName: "silence", Passed: true},
			{Name: "silence [2/2]", CaseName: "silence", Passed: true},
		},
	}
	updateProactivity(&summary.Proactivity, "act", "reply")
	updateProactivity(&summary.Proactivity, "act", "ignore")
	updateProactivity(&summary.Proactivity, "silent", "ignore")
	updateProactivity(&summary.Proactivity, "silent", "reply")
	ApplyEvaluationGates(&summary, EvaluationGateOptions{
		MinOverallPassRate:       0.8,
		MinCasePassRate:          0.75,
		MinProactivePrecision:    0.8,
		MinProactiveRecall:       0.8,
		MaxFalseInterruptionRate: 0.1,
		Baseline: &EvaluationBaseline{
			Version:       1,
			CorpusDigest:  "digest",
			CasePassRates: map[string]float64{"answer": 1},
		},
		MaxBaselineRegression: 0.1,
	})
	if summary.Gate.Passed || len(summary.Gate.Failures) < 4 {
		t.Fatalf("weak evaluation passed its gate: %+v", summary.Gate)
	}
}

// baselineSummary builds a finished run over two cases with judge scores, so a
// baseline comparison has both numbers a release cares about: how often the
// answer was right, and how good the answer was.
func baselineSummary(passed bool, quality float64) EvaluationSummary {
	summary := EvaluationSummary{
		CorpusDigest: "digest",
		Total:        2,
		Passed:       2,
		Results: []EvaluationResult{
			{Name: "answer", CaseName: "answer", Passed: true},
			{Name: "silence", CaseName: "silence", Passed: passed},
		},
	}
	if !passed {
		summary.Passed = 1
		summary.Failed = 1
	}
	for index := range summary.Results {
		summary.Results[index].Quality = QualityAssessment{
			Evaluated: true, Passed: true, MeanScore: quality,
		}
	}
	// A baseline is taken from a finished run, and the per-case rates and the
	// judge mean only exist once the results have been aggregated.
	summarizeEvaluation(&summary)
	return summary
}

// TestTheGateFailsWhenTheOverallPassRateFallsBelowTheBaseline holds the reason
// the baseline exists at all.
//
// `EvaluationGateOptions.MaxBaselineRegression` shipped comparing per-case rates
// and nothing else, and no target passed --baseline, so a release could lose a
// tenth of its answers and every gate would still be green — the trend was a
// table somebody read afterwards rather than a thing that could fail.
func TestTheGateFailsWhenTheOverallPassRateFallsBelowTheBaseline(t *testing.T) {
	summary := baselineSummary(false, 4.5)
	baseline := BaselineFromSummary(baselineSummary(true, 4.5))
	ApplyEvaluationGates(&summary, EvaluationGateOptions{
		Baseline: &baseline, MaxBaselineRegression: 0.1,
	})
	if summary.Gate.Passed ||
		!strings.Contains(strings.Join(summary.Gate.Failures, "\n"), "overall pass rate regressed") {
		t.Fatalf("overall regression gate = %+v", summary.Gate)
	}
}

// TestTheGateFailsWhenTheMeanJudgeScoreFallsBelowTheBaseline covers the other
// half: every answer still passes its assertions and every one of them got
// worse. The judge scores 1 to 5, so its tolerance is in judge points and not
// the 0-to-1 currency the rate thresholds use — one knob for both units would
// be either meaningless for the rate or unusable for the score.
func TestTheGateFailsWhenTheMeanJudgeScoreFallsBelowTheBaseline(t *testing.T) {
	summary := baselineSummary(true, 3.5)
	baseline := BaselineFromSummary(baselineSummary(true, 4.6))
	ApplyEvaluationGates(&summary, EvaluationGateOptions{
		Baseline:              &baseline,
		MaxBaselineRegression: 0.1,
		MaxQualityRegression:  0.5,
	})
	if summary.Gate.Passed ||
		!strings.Contains(strings.Join(summary.Gate.Failures, "\n"), "mean judge score regressed") {
		t.Fatalf("judge regression gate = %+v", summary.Gate)
	}
	within := baselineSummary(true, 4.3)
	ApplyEvaluationGates(&within, EvaluationGateOptions{
		Baseline:              &baseline,
		MaxBaselineRegression: 0.1,
		MaxQualityRegression:  0.5,
	})
	if !within.Gate.Passed {
		t.Fatalf("a drop inside the tolerance failed: %+v", within.Gate)
	}
}

// TestAnUnjudgedRunIsNotComparedAgainstAJudgedBaseline stops the comparison
// from reading "nobody judged this run" as "every answer collapsed".
//
// A run without --judge reports mean_score 0. Against a baseline of 4.6 that is
// the largest regression the arithmetic can produce, and it would fail every
// unjudged corpus in model-release-check the day a baseline was committed.
func TestAnUnjudgedRunIsNotComparedAgainstAJudgedBaseline(t *testing.T) {
	summary := baselineSummary(true, 0)
	for index := range summary.Results {
		summary.Results[index].Quality = QualityAssessment{}
	}
	baseline := BaselineFromSummary(baselineSummary(true, 4.6))
	ApplyEvaluationGates(&summary, EvaluationGateOptions{
		Baseline: &baseline, MaxBaselineRegression: 0.1, MaxQualityRegression: 0.5,
	})
	if !summary.Gate.Passed {
		t.Fatalf("an unjudged run was compared as a regression: %+v", summary.Gate)
	}
}

// TestAGrownCorpusIsComparedRatherThanRefused is what makes a committed
// baseline survive its own pipeline.
//
// The corpus this gate protects grows by promotion — that is the point of the
// corrections loop — and a whole-corpus digest equality check answers a promoted
// fixture with "baseline corpus digest does not match this corpus", which fails
// the release for the corpus having done its job. Cases are joined by name: the
// ones the baseline knows are compared, a new one is not a regression, and a
// case that vanished is reported rather than quietly skipped.
func TestAGrownCorpusIsComparedRatherThanRefused(t *testing.T) {
	baseline := BaselineFromSummary(baselineSummary(true, 4.5))
	grown := baselineSummary(true, 4.5)
	grown.CorpusDigest = "a different corpus"
	grown.Total = 3
	grown.Passed = 3
	grown.Results = append(grown.Results, EvaluationResult{
		Name: "promoted lesson", CaseName: "promoted lesson", Passed: true,
		Quality: QualityAssessment{Evaluated: true, Passed: true, MeanScore: 4.5},
	})
	ApplyEvaluationGates(&grown, EvaluationGateOptions{
		Baseline: &baseline, MaxBaselineRegression: 0.1, MaxQualityRegression: 0.5,
	})
	if !grown.Gate.Passed {
		t.Fatalf("a grown corpus was refused rather than compared: %+v", grown.Gate)
	}
}

// TestABaselineCaseMissingFromTheRunFailsTheGate is the other side of joining
// by name: deleting a fixture must not be a way to make its regression
// disappear, which is exactly what skipping unknown names would allow.
func TestABaselineCaseMissingFromTheRunFailsTheGate(t *testing.T) {
	baseline := BaselineFromSummary(baselineSummary(true, 4.5))
	shrunk := EvaluationSummary{
		CorpusDigest: "digest", Total: 1, Passed: 1,
		Results: []EvaluationResult{{Name: "answer", CaseName: "answer", Passed: true}},
	}
	ApplyEvaluationGates(&shrunk, EvaluationGateOptions{
		Baseline: &baseline, MaxBaselineRegression: 0.1,
	})
	if shrunk.Gate.Passed ||
		!strings.Contains(strings.Join(shrunk.Gate.Failures, "\n"), `"silence"`) {
		t.Fatalf("a vanished case passed its baseline: %+v", shrunk.Gate)
	}
}

func TestEvaluationGateCanRequireZeroFalseInterruptions(t *testing.T) {
	summary := EvaluationSummary{
		Total:  1,
		Passed: 1,
		Results: []EvaluationResult{{
			Name: "ambient reply", CaseName: "ambient reply", Passed: true,
		}},
	}
	updateProactivity(&summary.Proactivity, "silent", "react")
	ApplyEvaluationGates(&summary, EvaluationGateOptions{
		MaxFalseInterruptionRate: 0,
		EnforceFalseInterruption: true,
	})
	if summary.Gate.Passed ||
		!strings.Contains(
			strings.Join(summary.Gate.Failures, "\n"),
			"false interruption rate",
		) {
		t.Fatalf("zero false-interruption gate = %+v", summary.Gate)
	}
}

func TestWorkspaceOutcomeRequiresObservableReviewedArtifacts(t *testing.T) {
	want := true
	testCase := EvaluationCase{
		Kind:                  "task",
		WantCommittedChanges:  &want,
		WantChangedPaths:      []string{"testdata/eval/*.md"},
		ForbidChangedPaths:    []string{"infra/**"},
		WantReviewPublishable: &want,
		WantReviewGate:        "passed",
	}
	artifacts := WorkspaceAssessment{
		Evaluated:         true,
		Committed:         1,
		ChangedPaths:      []string{"testdata/eval/task-fixture.md"},
		ReviewGate:        "passed",
		ReviewPublishable: true,
	}
	if err := assessWorkspaceExpectations(testCase, artifacts); err != nil {
		t.Fatal(err)
	}
	artifacts.ChangedPaths = append(artifacts.ChangedPaths, "infra/main.tf")
	if err := assessWorkspaceExpectations(testCase, artifacts); err == nil ||
		!strings.Contains(err.Error(), "forbidden") {
		t.Fatalf("forbidden task path was accepted: %v", err)
	}
}

func TestStatefulScenarioUsesPriorConversationAcrossChannelsAndRestart(t *testing.T) {
	cfg := serviceConfig(t)
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"reason":"direct question","message":"Cloud SQL latency remains unverified.","memory":{"goal":"finish health review","open_loops":["verify Cloud SQL latency"]}}`,
		`{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"reason":"follow-up","message":"It prevents an end-to-end health verdict.","memory":{"goal":"finish health review","open_loops":["verify Cloud SQL latency"]}}`,
	}
	corpus := strings.NewReader(`{"name":"cross channel","repository":"repo","seeds":[{"channel":"CINFRA","repository":"repo","memory":{"goal":"finish health review","open_loops":["verify Cloud SQL latency"]}}],"steps":[{"name":"ask elsewhere","channel":"CALERTS","input":"What remains?","mentions_responder":true,"expect":{"want_action":"reply","want_message_contains":["Cloud SQL"]}},{"name":"restart followup","channel":"CALERTS","restart_before":true,"input":"Why does that matter?","mentions_responder":true,"expect":{"want_action":"reply","want_message_contains":["health verdict"]}}]}`)
	summary, err := EvaluateLiveScenariosJSONL(
		context.Background(),
		corpus,
		cfg,
		coopClient,
		LiveEvaluationOptions{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Total != 2 || summary.Passed != 2 || summary.ModelCalls != 2 {
		t.Fatalf("scenario summary = %+v", summary)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[0], "related_situations") ||
		!strings.Contains(coopClient.submitPrompts[0], "Cloud SQL latency") ||
		!strings.Contains(coopClient.submitPrompts[1], "conversation_continuation") {
		t.Fatalf("scenario prompts = %+v", coopClient.submitPrompts)
	}
}

func TestAllEvaluationCorporaDecode(t *testing.T) {
	corpora := []string{
		filepath.Join("..", "..", "testdata", "eval", "proactive.jsonl"),
		filepath.Join("..", "..", "testdata", "eval", "evidence.jsonl"),
		filepath.Join("..", "..", "testdata", "eval", "productivity.jsonl"),
	}
	// Globbed rather than listed: the replay corpus is one file per deployment,
	// so a new deployment's corpus must be decoded without anyone remembering
	// to add it here.
	replay, err := filepath.Glob(
		filepath.Join("..", "..", "testdata", "eval", "episode-replay", "*.jsonl"),
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(replay) == 0 {
		t.Fatal("no replay corpora found; this test would silently check nothing")
	}
	for _, name := range append(corpora, replay...) {
		file, err := os.Open(name)
		if err != nil {
			t.Fatal(err)
		}
		_, decodeErr := decodeEvaluationCases(file)
		file.Close()
		if decodeErr != nil {
			t.Fatalf("%s: %v", name, decodeErr)
		}
	}
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "scenarios.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	scenarios, err := decodeEvaluationScenarios(file)
	if err != nil || len(scenarios) < 4 {
		t.Fatalf("scenario corpus = %d, %v", len(scenarios), err)
	}
	calibration, err := os.Open(filepath.Join(
		"..", "..", "testdata", "eval", "quality-calibration.jsonl",
	))
	if err != nil {
		t.Fatal(err)
	}
	defer calibration.Close()
	calibrationCases, err := decodeQualityCalibrationCases(calibration)
	if err != nil || len(calibrationCases) < 8 {
		t.Fatalf(
			"quality calibration corpus = %d, %v",
			len(calibrationCases),
			err,
		)
	}
}

func TestDeterministicEpisodeReplayPromptIsBoundedToRecordedEvidence(t *testing.T) {
	cases, err := decodeEvaluationCases(strings.NewReader(`{"name":"recorded","kind":"watch","input":"assess rollout","recorded_events":[{"sequence":1,"kind":"episode.created","occurred_at":"2026-08-02T12:00:00Z","payload":{"objective":"assess rollout"}}],"recorded_tool_results":[{"id":"rollout","tool":"emisar.wait_for_run","source_type":"emisar","observed_at":"2026-08-02T12:01:00Z","sanitized":true,"output":{"state":"successful"}}]}`))
	if err != nil {
		t.Fatal(err)
	}
	prompt, err := deterministicEpisodeReplayPrompt("production contract", cases[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"<host-deterministic-episode-replay>",
		"Do not call any tool",
		`"sequence":1`,
		`"tool":"emisar.wait_for_run"`,
		"produce the same typed result operations",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("episode replay prompt lacks %q: %s", required, prompt)
		}
	}
}

func TestEvaluationLifecycleAllowsOneCompletionPerCorrectionTurn(t *testing.T) {
	client := newFakeCoop()
	client.events = []coop.Event{
		{Sequence: 1, Type: "turn.completed", TurnID: "turn-initial"},
		{Sequence: 2, Type: "turn.completed", TurnID: "turn-correction"},
	}
	assessment := assessEvaluationLifecycle(
		context.Background(), client, client.session.ID, "", 2,
	)
	if !assessment.Passed || assessment.CompletedEvents != 2 {
		t.Fatalf("lifecycle assessment = %+v", assessment)
	}

	client.events = append(client.events, coop.Event{
		Sequence: 3, Type: "turn.completed", TurnID: "turn-correction",
	})
	assessment = assessEvaluationLifecycle(
		context.Background(), client, client.session.ID, "", 2,
	)
	if assessment.Passed {
		t.Fatalf("duplicate completion was accepted: %+v", assessment)
	}
}

func TestEvaluationLifecycleDoesNotConfuseRetriesWithTurns(t *testing.T) {
	client := newFakeCoop()
	client.events = []coop.Event{
		{Sequence: 1, Type: "turn.completed", TurnID: "turn-initial"},
		{Sequence: 2, Type: "turn.completed", TurnID: "turn-correction"},
	}
	assessment := assessEvaluationLifecycle(
		context.Background(), client, client.session.ID, "", 0,
	)
	if !assessment.Passed || assessment.CompletedEvents != 2 {
		t.Fatalf("lifecycle assessment = %+v", assessment)
	}

	client.events = nil
	assessment = assessEvaluationLifecycle(
		context.Background(), client, client.session.ID, "", 0,
	)
	if assessment.Passed {
		t.Fatalf("missing completion was accepted: %+v", assessment)
	}
}

func TestEvaluationReferenceTimeUsesLatestRecordedObservation(t *testing.T) {
	testCase := EvaluationCase{
		RecordedEvents: []EvaluationRecordedEvent{
			{OccurredAt: "2026-08-02T12:00:00Z"},
			{OccurredAt: "2026-08-02T12:03:00Z"},
		},
		RecordedToolResults: []EvaluationToolResult{
			{ObservedAt: "2026-08-02T12:02:00Z"},
			{ObservedAt: "2026-08-02T12:04:00Z"},
		},
	}
	got := evaluationReferenceTime(testCase, time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC))
	want := time.Date(2026, 8, 2, 12, 4, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("reference time = %s, want %s", got, want)
	}
}

func TestEvaluationStructuredCorrectionUsesProductionContract(t *testing.T) {
	cfg := serviceConfig(t)
	testCase := EvaluationCase{
		Name: "typed evidence", Kind: "watch", Input: "Check whether CI is green",
		MentionsResponder: true, WantAction: "reply",
	}
	response := `{"action":"reply","operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"CI is green.","coverage":[{"layer":"change","claim_ids":[],"status":"healthy","detail":"checks passed"}],"completion":{"status":"decision_ready","summary":"CI is green"}}}]}`
	correction := evaluationStructuredCorrection(
		cfg, testCase, response, time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC),
	)
	if !strings.Contains(correction, "no typed evidence") {
		t.Fatalf("correction = %q", correction)
	}
}

func TestEvaluationStructuredCorrectionUsesProductionAlertStateMachine(t *testing.T) {
	cfg := serviceConfig(t)
	testCase := EvaluationCase{
		Name: "active alert", Kind: "watch", SenderType: "external_app",
		Input:      "[VA1 FIRING:1] WARNING | Cassandra repair overdue",
		WantAction: "reply", WantAlertAssessment: true, RequireCompletion: true,
	}
	response := `{"action":"reply","message":"The repair is progressing.","evidence":[{"claim":"repair progress advanced","observation":"progress moved from 73% to 74%","source_type":"emisar","source_name":"repair status","observed_at":"2026-08-05T14:02:00Z"}],"completion":{"status":"decision_ready","verdict":"degraded","summary":"The repair is progressing."}}`
	correction := evaluationStructuredCorrection(
		cfg, testCase, response, time.Date(2026, 8, 5, 14, 2, 0, 0, time.UTC),
	)
	if !strings.Contains(correction, "no record_alert_assessment result") {
		t.Fatalf("correction = %q", correction)
	}
}

func TestEvaluationStructuredCorrectionRequiresTerraformLifecycleContinuation(t *testing.T) {
	cfg := serviceConfig(t)
	testCase := EvaluationCase{
		Name:       "terraform planning starts durable watch",
		Kind:       "watch",
		SenderType: "external_app",
		Input: `Run notification for Dryga/emisar
Run run-Q9nWxoGwkdkKQdu6
Run Planning`,
		StandingRules: []EvaluationStandingRule{{
			ID:         "terraform-lifecycle",
			Trigger:    "terraform_lifecycle",
			Action:     "monitor_terraform_lifecycle",
			Repository: "emisar",
			SourceKind: "app",
		}},
	}
	response := `{"action":"ignore","reason":"The run is still planning."}`
	correction := evaluationStructuredCorrection(
		cfg, testCase, response, time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC),
	)
	lowerCorrection := strings.ToLower(correction)
	if !strings.Contains(lowerCorrection, "wait_external") ||
		!strings.Contains(lowerCorrection, "run-q9nwxogwkdkkqdu6") {
		t.Fatalf("correction = %q", correction)
	}
}

func TestEpisodeReplayRequiresCompleteSanitizedFixtures(t *testing.T) {
	cases := strings.NewReader(`{"name":"incomplete replay","kind":"watch","input":"assess rollout","recorded_events":[{"sequence":1,"kind":"episode.created","occurred_at":"2026-08-02T12:00:00Z","payload":{"objective":"assess rollout"}}]}`)
	_, err := EvaluateLiveJSONL(
		context.Background(),
		cases,
		serviceConfig(t),
		newFakeCoop(),
		LiveEvaluationOptions{EpisodeReplay: true},
	)
	if err == nil || !strings.Contains(err.Error(), "requires recorded_events and recorded_tool_results") {
		t.Fatalf("incomplete episode replay = %v", err)
	}

	_, err = decodeEvaluationCases(strings.NewReader(`{"name":"unsafe replay","kind":"watch","input":"assess rollout","recorded_events":[{"sequence":1,"kind":"episode.created","occurred_at":"2026-08-02T12:00:00Z","payload":{"objective":"assess rollout"}}],"recorded_tool_results":[{"id":"rollout","tool":"emisar.wait_for_run","source_type":"emisar","observed_at":"2026-08-02T12:01:00Z","sanitized":false,"output":{"state":"successful"}}]}`))
	if err == nil || !strings.Contains(err.Error(), "valid sanitized result") {
		t.Fatalf("unsafe episode replay fixture = %v", err)
	}
}

// A corpus the provider would not run is unrun, not failed.
//
// The first real execution of the promoted-corrections gate printed
// "0/4 passed, 4 failed" and "overall pass rate 0.000 is below 1.000" when all
// four cases had been rate limited before the model saw them. Both sentences
// are true and both send a reader to look for four regressions that do not
// exist — and the second time somebody reads that, they stop believing the
// gate. The run must still fail, because an unproven fixture cannot pass on
// the grounds that a provider was busy; only the reason changes.
func TestRateLimitedCasesFailAsUnrunRatherThanAsRegressions(t *testing.T) {
	summary := EvaluationSummary{
		Total: 4, Passed: 0, Failed: 0, Unevaluated: 4,
		Results: []EvaluationResult{
			{Name: "runbook", Unevaluated: true, Detail: "model call: provider rate limited the turn"},
			{Name: "baseline", Unevaluated: true, Detail: "model call: provider rate limited the turn"},
			{Name: "terraform", Unevaluated: true, Detail: "model call: provider rate limited the turn"},
			{Name: "feedback", Unevaluated: true, Detail: "model call: provider rate limited the turn"},
		},
	}
	ApplyEvaluationGates(&summary, EvaluationGateOptions{MinOverallPassRate: 1})
	if summary.Gate.Passed {
		t.Fatal("an unevaluated corpus passed its gate")
	}
	joined := strings.Join(summary.Gate.Failures, "\n")
	if !strings.Contains(joined, "never evaluated") {
		t.Errorf("gate did not say the cases were never evaluated: %q", joined)
	}
	if strings.Contains(joined, "pass rate") {
		t.Errorf("gate blamed the corpus for a provider refusal: %q", joined)
	}
}

// The shape the host accepts back from a retiring session: a silent ignore
// carrying exactly one update_memory. Harvested from the handoff path's own
// tests (internal/service/session_handoff_test.go), so what the corpus grades
// against is the same string the landed feature was proven with.
const handoffCarriesMemoryForward = `{
	"action":"ignore",
	"reason":"carrying this session's context into the next one",
	"operations":[{"id":"handoff","type":"update_memory","memory":{
		"situation_summary":"Checkout latency was traced to cache warmup after the rollout.",
		"open_loops":["Confirm the rollout guard landed."],
		"decisions":["Keep watching checkout p99 for the next deploy."]}}]
}`

// The same turn deciding to answer instead. It is what a session that ignored
// "do not investigate, read anything, or reply in Slack" comes back with, and
// the host's silent-ignore path accepts none of it.
const handoffRepliedInsteadOfHandingOver = `{
	"action":"reply",
	"operations":[
		{"id":"mem","type":"update_memory","memory":{
			"situation_summary":"Checkout latency recovered after the cache rollout."}},
		{"id":"complete","type":"complete_episode","completion":{
			"message":"Checkout latency is back inside its budget.",
			"completion":{"status":"decision_ready","summary":"answered"}}}]
}`

// A contract addition with no corpus case reaches production read by nobody
// but its author.
//
// request_record is the whole answer to "give me a handoff summary" now that
// the slash spelling is gone, and the failure it prevents is invisible from the
// host side: a model that writes the summary itself returns a perfectly valid
// result, passes every deterministic test in this repository, and hands the
// operator its own recollection of the work in place of the record. Only a case
// that runs a real model against the real prompt can tell the two apart.
func TestTheRecordRequestContractHasACorpusCase(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "prompts.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	cases, err := decodeEvaluationCases(file)
	if err != nil {
		t.Fatal(err)
	}
	asked := 0
	for _, testCase := range cases {
		if slices.Contains(testCase.WantOperations, "request_record") {
			asked++
		}
	}
	if asked == 0 {
		t.Fatal(
			"no prompts case requires request_record; the operation the four durable " +
				"reports depend on would be exercised by nothing",
		)
	}
}

// The same rule, for the operation that asks for AUTHORITY.
//
// offer_assignment replaced `/responder assignments create` on 2026-08-15, and
// both of its failure modes are invisible from the host side. A model that
// agrees in prose — "sure, I'll watch for that" — returns a perfectly valid
// result, passes every deterministic test here, and promises an operator
// unattended work that nothing will ever do. A model that emits the operation
// alone repeats the pairing failure request_record's first live gate run
// produced on both of its cases the same day. Only a real model against the
// real prompt tells either apart from a correct answer.
func TestTheAssignmentOfferContractHasACorpusCase(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "prompts.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	cases, err := decodeEvaluationCases(file)
	if err != nil {
		t.Fatal(err)
	}
	for _, testCase := range cases {
		if !slices.Contains(testCase.WantOperations, "offer_assignment") {
			continue
		}
		// The pairing half. A case that wanted the operation and did not
		// require a completion beside it would pass on exactly the result the
		// prompt's BESIDE sentence exists to prevent.
		if !testCase.RequireCompletion {
			t.Errorf(
				"case %q wants offer_assignment without requiring a completion beside it, "+
					"so the pairing rule the prompt states is exercised by nothing",
				testCase.Name,
			)
		}
		return
	}
	t.Fatal(
		"no prompts case requires offer_assignment; the only surface that grants " +
			"standing pull-request authority would be exercised by nothing",
	)
}

// eval-prompts must submit the host's own handoff prompt, not a paraphrase and
// not a paraphrase wrapped in scaffolding.
//
// agentprompt.SessionHandoff() is the entire turn in production: rotation asks
// the session it is retiring for the summary that dies with its transcript, and
// prepareSessionHandoffTurn adds no watch instructions, no episode contract and
// no structured-response suffix to it. There is also no correction ladder behind
// the answer and no second attempt, so whatever the prompt gets first time is
// what the next session inherits. A corpus that assembled a different turn
// around the same words would report a pass for something the host never sends.
func TestTheHandoffCorpusCaseSubmitsTheProductionHandoffTurn(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "prompts.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	cases, err := decodeEvaluationCases(file)
	if err != nil {
		t.Fatal(err)
	}
	var handoffs []EvaluationCase
	smoke := false
	for _, testCase := range cases {
		if testCase.Kind != "handoff" {
			continue
		}
		handoffs = append(handoffs, testCase)
		smoke = smoke || slices.Contains(testCase.Tags, "smoke")
	}
	if len(handoffs) == 0 {
		t.Fatal(
			"no prompts case exercises agentprompt.SessionHandoff(); a prompt string with " +
				"no case reaches production having been read by nobody but its author",
		)
	}
	if !smoke {
		t.Error(
			"no handoff case carries the smoke tag, so the five-minute tier that gates a " +
				"wording deploy never runs one and only the half-hour tier would notice",
		)
	}
	if strings.TrimSpace(handoffs[0].Input) == "" {
		t.Fatal("a handoff case with no input asks the model to summarize nothing")
	}

	cfg := serviceConfig(t)
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = handoffCarriesMemoryForward
	encoded, err := json.Marshal(handoffs[0])
	if err != nil {
		t.Fatal(err)
	}
	summary, err := EvaluateLiveJSONL(
		context.Background(),
		strings.NewReader(string(encoded)),
		cfg,
		coopClient,
		LiveEvaluationOptions{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Passed != 1 || summary.Total != 1 {
		t.Fatalf("the corpus handoff case did not pass its own harness: %+v", summary.Results)
	}
	// One call, not one plus a correction round: the host would never send the
	// second, so a corpus that did would be grading a turn production cannot run.
	if summary.ModelCalls != 1 || len(coopClient.submitPrompts) != 1 {
		t.Fatalf(
			"handoff took %d model calls over %d turns, want exactly one of each",
			summary.ModelCalls, len(coopClient.submitPrompts),
		)
	}
	submitted := coopClient.submitPrompts[0]
	if !strings.HasSuffix(submitted, agentprompt.SessionHandoff()) {
		t.Fatalf("the submitted turn is not the host's handoff prompt: %q", submitted)
	}
	transcript, _, _ := strings.Cut(handoffs[0].Input, "\n")
	if !strings.Contains(submitted, transcript) {
		t.Errorf(
			"the retiring transcript never reached the turn, so the model was asked to "+
				"hand forward an empty session: %q",
			submitted,
		)
	}
	for _, scaffolding := range []string{
		"shared Slack operations feed",
		"The final watch response uses this outer envelope",
		"<host-investigation-contract>",
	} {
		if strings.Contains(submitted, scaffolding) {
			t.Errorf(
				"the handoff turn was assembled with %s, which no handoff in production carries",
				scaffolding,
			)
		}
	}
	if coopClient.discardCalls != 1 {
		t.Errorf("handoff evaluation left its session behind: discards = %d", coopClient.discardCalls)
	}
}

// A handoff passes only when the channel is left holding something it did not
// have before.
//
// Every rejection here is a turn the host would spend and throw away.
// finalizeSessionHandoffTurn parses the watch dialect, hands
// decision.Memory.WithoutThreadScope() to ApplyHandoffMemory, retires the
// session and never asks again — and ApplyHandoffMemory writes nothing at all
// when that memory marshals to "{}". So a handoff that answers in prose, that
// replies instead of staying silent, or that fills in only a goal reads as a
// completed run in every log and leaves the next session on exactly the stale
// summary the rotation existed to refresh.
func TestAHandoffPassesOnlyWhenItCarriesMemoryForward(t *testing.T) {
	accepted := EvaluationCase{
		Name:       "a rotated session hands its memory forward",
		Kind:       "handoff",
		Output:     handoffCarriesMemoryForward,
		WantAction: "ignore",
	}
	if result := evaluateCase(accepted); !result.Passed {
		t.Fatalf("the shape the host applies was rejected: %+v", result)
	}

	for _, testCase := range []struct {
		name   string
		output string
		detail string
	}{
		{
			name:   "replied instead of handing over",
			output: handoffRepliedInsteadOfHandingOver,
			detail: "want exactly one update_memory",
		},
		{
			// Held to the shape the prompt printed rather than to the widest
			// shape the parser tolerates. Everywhere else a result that puts its
			// answer in the envelope is refused and the model gets another turn
			// to re-emit it typed; a handoff has no second turn to be asked in.
			// The prompt shows exactly one shape for that reason, so the corpus
			// grades exactly one shape.
			name: "answered in the shape the prompt did not print",
			output: `{"action":"ignore","reason":"carrying this session's context",` +
				`"memory":{"situation_summary":"Checkout latency was traced to cache warmup."}}`,
			detail: "handoff operations = [], want exactly one update_memory",
		},
		{
			name: "wrote the memory down twice",
			output: `{"action":"reply","operations":[` +
				`{"id":"one","type":"update_memory","memory":{"situation_summary":"cache warmup"}},` +
				`{"id":"two","type":"update_memory","memory":{"open_loops":["guard"]}}]}`,
			detail: "duplicates update_memory",
		},
		{
			name: "handed forward an empty memory",
			output: `{"action":"ignore","reason":"nothing worth carrying",` +
				`"operations":[{"id":"handoff","type":"update_memory","memory":{}}]}`,
			detail: "carried no channel memory forward",
		},
		{
			// The subtle one. This memory is not empty, and it is still dropped:
			// WithoutThreadScope clears the goal before the write because a
			// channel does not have an objective, so ApplyHandoffMemory sees "{}"
			// and returns without touching the row.
			name: "carried only a goal the channel does not keep",
			output: `{"action":"ignore","reason":"carrying the objective",` +
				`"operations":[{"id":"handoff","type":"update_memory","memory":{` +
				`"goal":"Explain why checkout p99 doubled after the rollout."}}]}`,
			detail: "carried no channel memory forward",
		},
		{
			name:   "answered in prose",
			output: "The session is retiring. Checkout latency was traced to cache warmup.",
			detail: "not in the watch dialect",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			rejected := accepted
			rejected.Output = testCase.output
			result := evaluateCase(rejected)
			if result.Passed || !strings.Contains(result.Detail, testCase.detail) {
				t.Fatalf(
					"handoff %q = passed %t, detail %q, want a failure naming %q",
					testCase.name, result.Passed, result.Detail, testCase.detail,
				)
			}
		})
	}
}

// A kind nothing runs must not survive the loader.
//
// Kind routes both halves of a case: which prompt is submitted and which
// dialect the answer is graded in. A typo in it produces a corpus that decodes
// cleanly, ships, and then fails one credentialed case at a time half an hour
// into a run nobody wants to be debugging JSON inside of — which is the exact
// failure the offline corpus checks were written for.
func TestTheLoaderRefusesACaseNothingCanRun(t *testing.T) {
	if _, err := decodeEvaluationCases(strings.NewReader(
		`{"name":"handoff","kind":"handoff","input":"session working notes","want_action":"ignore"}`,
	)); err != nil {
		t.Fatalf("the loader refused the handoff kind the prompts corpus ships: %v", err)
	}
	_, err := decodeEvaluationCases(strings.NewReader(
		`{"name":"typo","kind":"handof","input":"session working notes"}`,
	))
	if err == nil || !strings.Contains(err.Error(), "is not run by anything") {
		t.Fatalf("a kind nothing runs decoded cleanly: %v", err)
	}
}
