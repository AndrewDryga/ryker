package service

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
