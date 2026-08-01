package service

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

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

func TestEvaluationChecksGovernedApprovalAndProposalCounts(t *testing.T) {
	wantApproval := true
	wantProposals := 0
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
		  },
		  "proposals":[]
		}`,
		WantMessageContains:   []string{"waiting", "has not run"},
		ForbidMessageContains: []string{"restart completed"},
		WantPendingApproval:   &wantApproval,
		WantProposals:         &wantProposals,
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
		recent[2].Text != "RESOLVED alert_id=42" {
		t.Fatalf("ordered evaluation context = %+v, input=%+v", recent, input)
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
				Action: "review_terraform_plan", Repository: "repo",
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
	for _, name := range []string{
		"proactive.jsonl",
		"evidence.jsonl",
		"productivity.jsonl",
	} {
		file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", name))
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
