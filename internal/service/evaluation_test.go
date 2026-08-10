package service

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

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
	if err != nil || action != "reply" || len(message.Actions) != 1 ||
		message.Actions[0].ID != slackui.ActionRememberSchedule ||
		strings.Contains(strings.Join(message.Sections, "\n"), "engineering task") {
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
	input, recent, err := liveEvaluationWatchContext(testCase, "eval", "UEVALOPERATOR")
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
	  "attention":{"addressee":"responder","confidence":3,"ownership":2},
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
	input, recent, err := liveEvaluationWatchContext(
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

func TestLiveEvaluationContextPreservesResponderMessages(t *testing.T) {
	cfg := serviceConfig(t)
	_, recent, err := liveEvaluationWatchContext(
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
		`{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3},"reason":"direct question","message":"Cloud SQL latency remains unverified.","memory":{"goal":"finish health review","open_loops":["verify Cloud SQL latency"]}}`,
		`{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3},"reason":"follow-up","message":"It prevents an end-to-end health verdict.","memory":{"goal":"finish health review","open_loops":["verify Cloud SQL latency"]}}`,
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
	if !strings.Contains(correction, "no alert_assessment") {
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
