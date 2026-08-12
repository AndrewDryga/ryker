package service

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/resultwire"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestAgentReportStrictSchemaAndLegacyCompatibility(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport("A concise legacy answer.")
	if err != nil || structured || report.Message != "A concise legacy answer." {
		t.Fatalf("legacy = %+v, %v, %v", report, structured, err)
	}
	report, structured, err = decisionpkg.ParseAgentReport(`{
	  "message":"Current state is degraded.",
	  "evidence":[],
	  "coverage":[],
	  "memory":{},
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
	}`)
	if err != nil || !structured || report.Message != "Current state is degraded." ||
		report.PendingApproval == nil || report.PendingApproval.RequestID != "apr_123" {
		t.Fatalf("structured = %+v, %v, %v", report, structured, err)
	}
	for name, input := range map[string]string{
		"empty message": `{"message":"","evidence":[]}`,
		"two values":    `{"message":"answer"} {"message":"other"}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := decisionpkg.ParseAgentReport(input); err == nil {
				t.Fatal("invalid structured report was accepted")
			}
		})
	}
}

func TestAgentReportAcceptsBoundedOrderedFollowupMessages(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport(`{
	  "message":"CI is green.",
	  "followup_messages":[
	    "The deployment is waiting for approval.",
	    "Two unrelated incidents remain open."
	  ],
	  "evidence":[],
	  "coverage":[]
	}`)
	if err != nil || !structured || report.Message != "CI is green." ||
		len(report.FollowupMessages) != 2 ||
		report.FollowupMessages[1] != "Two unrelated incidents remain open." {
		t.Fatalf("compound report = %+v, structured=%t, err=%v", report, structured, err)
	}

	if _, err := decisionpkg.DecodeAgentReport(`{
	  "message":"First.",
	  "followup_messages":["1","2","3","4","5","6"]
	}`); err == nil || !strings.Contains(err.Error(), "more than 5") {
		t.Fatalf("unbounded follow-up sequence error = %v", err)
	}
	if _, err := decisionpkg.ParseWatchDecision(`{
	  "action":"reply",
	  "message":"First.",
	  "followup_messages":[""]
	}`, testDecodeClock); err == nil || !strings.Contains(err.Error(), "empty follow-up") {
		t.Fatalf("empty watch follow-up error = %v", err)
	}
}

func TestAgentReportGeneratedVisualContract(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport(`{
	  "message":"Here is the requested load chart.",
	  "visuals":[{"artifact":"load.png","title":"Production load","alt_text":"Line chart of load over 24 hours."}]
	}`)
	if err != nil || !structured || len(report.Visuals) != 1 ||
		report.Visuals[0].Artifact != "load.png" {
		t.Fatalf("generated visual report = %+v, %v, %v", report, structured, err)
	}
	if _, err := decisionpkg.DecodeAgentReport(`{
	  "message":"Remember this and show a chart.",
	  "visuals":[{"artifact":"load.png","title":"Load","alt_text":"Load chart."}],
	  "memory_offer":{"scope":"workspace","subject":"health","predicate":"guidance","value":"deep","visibility":"workspace"}
	}`); err == nil {
		t.Fatal("generated visual was combined with a durable behavior offer")
	}
	if _, err := decisionpkg.ParseWatchDecision(`{
	  "action":"ignore",
	  "visuals":[{"artifact":"load.png","title":"Load","alt_text":"Load chart."}]
	}`, testDecodeClock); err == nil {
		t.Fatal("ignore decision carried a generated visual")
	}
}

func TestAgentReportPreservesMessageWhenOptionalEnvelopeIsMalformed(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport(
		`{"message":"The database is healthy.","evidence":{"unexpected":"shape"}}`,
	)
	if err != nil || structured || report.Message != "The database is healthy." {
		t.Fatalf("degraded envelope = %+v, %v, %v", report, structured, err)
	}
	if len(report.Evidence) != 0 {
		t.Fatalf("malformed evidence escaped recovery: %+v", report.Evidence)
	}
}

func TestAgentReportPreservesScheduleOfferWithDecisionReadyFollowup(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport(`{
	  "message":"I’ll recheck cms-web in 24 hours and report here.",
	  "schedule_offer":{
	    "title":"Recheck cms-web after 24 hours",
	    "prompt":"Perform a fresh read-only cms-web health assessment.",
	    "repository":"repo",
	    "recurrence":"once",
	    "start_at":"2026-08-03T19:18:03Z",
	    "timezone":"UTC",
	    "catch_up":"latest",
	    "expires_in":"7d"
	  },
	  "completion":{
	    "status":"decision_ready",
	    "summary":"The follow-up is ready for confirmation.",
	    "next_action":"Confirm the schedule."
	  }
	}`)
	if err != nil || !structured || report.ScheduleOffer == nil ||
		report.Completion == nil || report.Completion.NextAction == "" {
		t.Fatalf("schedule report = %+v, structured=%v, err=%v", report, structured, err)
	}
}

func TestAgentReportExtractsFinalEnvelopeAfterCoopProgress(t *testing.T) {
	output := "I’m inspecting declared and live state." +
		"The audit is converging; I’m running validation now." +
		`{"message":"**Audit complete:** no repository change was needed.",` +
		`"evidence":[{"claim":"Packs match","observation":"Nine declared packs are live",` +
		`"source_type":"emisar","source_name":"list_packs"}],` +
		`"coverage":[{"layer":"runtime","status":"healthy"}],"memory":{}}`
	report, structured, err := decisionpkg.ParseAgentReport(output)
	if err != nil || !structured {
		t.Fatalf("progress-prefixed report = %+v, %v, %v", report, structured, err)
	}
	if report.Message != "**Audit complete:** no repository change was needed." ||
		len(report.Evidence) != 1 || len(report.Coverage) != 1 {
		t.Fatalf("extracted report = %+v", report)
	}
}

func TestAgentReportAcceptsEmptyOptionalObservationTimestamps(t *testing.T) {
	output := `Progress update.{"message":"Assessment complete.",` +
		`"evidence":[{"claim":"Topology is declared","observation":"One region",` +
		`"source_type":"repository","source_name":"infra/main.tf","observed_at":""}],` +
		`"coverage":[{"layer":"application","status":"unknown","observed_at":""}],` +
		`"memory":{}}`
	report, structured, err := decisionpkg.ParseAgentReport(output)
	if err != nil || !structured || len(report.Evidence) != 1 ||
		len(report.Coverage) != 1 || !report.Evidence[0].ObservedAt.IsZero() ||
		!report.Coverage[0].ObservedAt.IsZero() {
		t.Fatalf("empty timestamps = %+v, structured:%v, err:%v", report, structured, err)
	}
}

func TestAgentReportRendersOnlyEvidenceBoundPackRecommendation(t *testing.T) {
	output := `{"operations":[` +
		`{"id":"evidence-pack","type":"record_evidence","evidence":{` +
		`"claim_id":"task.requested_outcome","claim":"A GitHub Actions inspection pack exists",` +
		`"observation":"The repository pack catalog contains github-cli with workflow run view and logs actions",` +
		`"relation":"supports","health_effect":"none","source_type":"repository",` +
		`"source_id":"pack-catalog","source_name":"packs/github-cli/pack.yaml","confidence":"high"}},` +
		`{"id":"complete","type":"complete_episode","completion":{` +
		`"message":"I cannot inspect the exact workflow run from the currently advertised actions.",` +
		`"completion":{"status":"blocked","summary":"The exact run result is unavailable",` +
		`"material_gaps":["GitHub Actions run and job result"],` +
		`"blocker_kind":"capability_unavailable",` +
		`"attempts":["Searched Emisar actions and the available pack catalog"],` +
		`"next_action":"Add the GitHub Actions inspection capability",` +
		`"capability_gaps":[{"capability":"GitHub Actions run and job inspection",` +
		`"status":"not_installed","pack_id":"github-cli","evidence_refs":["pack-catalog"],` +
		`"recommendation":"Install the ` + "`github-cli`" + ` pack on a runner with repository read access."}]}}}]}`
	report, structured, err := decisionpkg.ParseAgentReport(output)
	if err != nil || !structured {
		t.Fatalf("capability report = %+v, structured=%v, err=%v", report, structured, err)
	}
	if !strings.Contains(report.Message, "**Capability to add:** Install the `github-cli` pack") {
		t.Fatalf("capability guidance was not rendered: %q", report.Message)
	}

	output = strings.Replace(output, "contains github-cli", "contains git provider utilities", 1)
	output = strings.Replace(output, "packs/github-cli/pack.yaml", "packs/provider-tools/pack.yaml", 1)
	if _, _, err := decisionpkg.ParseAgentReport(output); err == nil || !strings.Contains(err.Error(), "not identified by its evidence") {
		t.Fatalf("fabricated pack recommendation accepted: %v", err)
	}
}

func TestAgentReportAddsObservedPackIDToCapabilityGuidance(t *testing.T) {
	output := `{"message":"The billing check is blocked.",` +
		`"evidence":[{"id":"pack-catalog","claim":"A billing pack exists",` +
		`"observation":"The repository catalog contains gcp-billing actions",` +
		`"source_type":"repository","source_name":"packs/gcp-billing/pack.yaml"}],` +
		`"completion":{"status":"blocked","summary":"Billing actions are unavailable",` +
		`"material_gaps":["current billing usage"],"blocker_kind":"capability_unavailable",` +
		`"attempts":["Searched the live action catalog"],"next_action":"Deploy the observed pack",` +
		`"capability_gaps":[{"capability":"GCP billing inspection","status":"not_advertised",` +
		`"pack_id":"gcp-billing","evidence_refs":["pack-catalog"],` +
		`"recommendation":"Reload the runner after deploying the observed version."}]}}`
	report, structured, err := decisionpkg.ParseAgentReport(output)
	if err != nil || !structured {
		t.Fatalf("capability report = %+v, structured=%t, err=%v", report, structured, err)
	}
	if !strings.Contains(
		report.Message,
		"**Capability to add:** `gcp-billing`: Reload the runner",
	) {
		t.Fatalf("host did not add the observed pack identity: %q", report.Message)
	}
}

func TestAgentReportRecoversMessageFromMalformedFinalEnvelopeAfterCoopProgress(t *testing.T) {
	output := `I’m checking the repository.{"message":"Audit complete","tool_output":"secret"}`
	report, structured, err := decisionpkg.ParseAgentReport(output)
	if err != nil || structured || report.Message != "Audit complete" {
		t.Fatalf("recovered progress-prefixed report = %+v structured:%v err:%v",
			report, structured, err)
	}
}

func TestStructuredEvidenceAndCoverageEnumsAreHostValidated(t *testing.T) {
	evidence := decisionpkg.SanitizeEvidence([]core.Evidence{{
		Claim: "A claim", Observation: "An observation",
		SourceType: "shell", SourceName: "tool",
		Confidence: "certain",
		SourceURL:  "https://user:secret@example.test/path?token=secret",
	}}, "", "C1", "slack_1", testDecodeClock)
	if len(evidence) != 1 || evidence[0].SourceType != "other" ||
		evidence[0].Confidence != "" || evidence[0].SourceURL != "" {
		t.Fatalf("evidence = %+v", evidence)
	}
	coverage := decisionpkg.SanitizeCoverage([]core.Coverage{
		{Layer: "scheduler", Status: "healthy"},
		{Layer: "application", Status: "covered", Detail: "The route was checked."},
		{Layer: "everything", Status: "perfect"},
	}, "", "C1", "slack_1", testDecodeClock)
	if len(coverage) != 2 || coverage[0].Layer != "scheduler" ||
		coverage[1].Layer != "application" || coverage[1].Status != "unknown" {
		t.Fatalf("coverage = %+v", coverage)
	}
}

func TestStructuredResponseInstructionsOwnFormattingAndApprovalRouting(t *testing.T) {
	policy := structuredResponseInstructions()
	for _, required := range []string{
		"Return exactly one JSON object",
		"Slack-supported standard Markdown",
		"Never invent a source",
		"approval.url",
		"Do not place the approval URL in message",
		"followup_messages",
	} {
		if !strings.Contains(policy, required) {
			t.Fatalf("policy lacks %q:\n%s", required, policy)
		}
	}
	// The action-proposal catalog used to be appended here, and said "No
	// actions are configured. Return an empty proposals array." on both
	// deployments, every turn. Proposing an action is not an operation any
	// more, and the instructions say where the request goes instead.
	for _, forbidden := range []string{"propose_action", "proposals array"} {
		if strings.Contains(policy, forbidden) {
			t.Fatalf("policy still advertises %q:\n%s", forbidden, policy)
		}
	}
}

func TestTypedResultOperationsFoldIntoAgentAndWatchResults(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport(`{
  "operations": [
    {"id":"e1","type":"record_evidence","evidence":{"claim_id":"host.current_state","relation":"supports","claim":"host responds","observation":"api-1 responded","source_type":"emisar","source_name":"host check","dimensions":{"host":"api-1","environment":"production"}}},
    {"id":"p1","type":"report_progress","progress":{"phase":"verifying","summary":"Host evidence is complete"}},
    {"id":"c1","type":"complete_episode","completion":{"message":"**Healthy in the checked scope.**","coverage":[{"layer":"host","status":"healthy","claim_ids":["host.current_state"]}],"completion":{"status":"decision_ready","verdict":"healthy","summary":"Healthy"}}}
  ]
}`)
	if err != nil || !structured || report.Message != "**Healthy in the checked scope.**" ||
		len(report.Evidence) != 1 || len(report.AppliedOperations) != 3 {
		t.Fatalf("typed report = %+v, structured = %t, err = %v", report, structured, err)
	}

	decision, err := decisionpkg.ParseWatchDecision(`{
  "action":"reply",
  "attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":1,"ownership":3,"contribution":"decision","material":true},
  "reason":"direct request",
  "operations":[
    {"id":"c1","type":"complete_episode","completion":{"message":"The check passed.","completion":{"status":"decision_ready","summary":"Passed"}}}
  ]
}`, testDecodeClock)
	if err != nil || decision.Message != "The check passed." || len(decision.AppliedOperations) != 1 {
		t.Fatalf("typed decision = %+v, err = %v", decision, err)
	}
}

func TestTypedResultOperationsAreAuthoritativeOverRedundantLegacyFields(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport(`Result follows:
{
  "message":"Old projection that should not win.",
  "verdict":"healthy",
  "operations":[
    {"id":"c1","type":"complete_episode","completion":{"message":"The current check passed.","completion":{"status":"decision_ready","summary":"Passed"}}}
  ]
}
That is the complete result.`)
	if err != nil || !structured || report.Message != "The current check passed." ||
		len(report.AppliedOperations) != 1 {
		t.Fatalf("authoritative typed report = %+v, structured=%t, err=%v", report, structured, err)
	}

	decision, err := decisionpkg.ParseWatchDecision(`{
  "action":"ignore",
  "message":"Redundant legacy projection.",
  "operations":[
    {"id":"c1","type":"complete_episode","completion":{"message":"The run failed during apply.","completion":{"status":"decision_ready","summary":"Apply failed"}}}
  ]
}`, testDecodeClock)
	if err != nil || decision.Action != "reply" ||
		decision.Message != "The run failed during apply." {
		t.Fatalf("authoritative typed watch result = %+v, err=%v", decision, err)
	}
}

func TestTypedAgentReportPersistsAsCanonicalOperations(t *testing.T) {
	report, structured, err := decisionpkg.ParseAgentReport(`Progress that must not survive storage.
{
  "operations": [
    {"id":"e1","type":"record_evidence","evidence":{"claim_id":"run.state","relation":"supports","claim":"the run completed","observation":"HCP Terraform reported applied","source_type":"monitoring","source_name":"HCP Terraform"}},
    {"id":"c1","type":"complete_episode","completion":{"message":"The run applied successfully.","completion":{"status":"decision_ready","verdict":"succeeded","summary":"Apply succeeded"}}}
  ]
}`)
	if err != nil || !structured {
		t.Fatalf("parse report: structured=%t err=%v", structured, err)
	}
	canonical, err := resultwire.AgentReport(report)
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(canonical, &envelope); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(canonical), "Progress that must not survive storage") || envelope["message"] != nil {
		t.Fatalf("canonical result retained transport or projected fields: %s", canonical)
	}
	reparsed, reparsedStructured, err := decisionpkg.ParseAgentReport(string(canonical))
	if err != nil || !reparsedStructured || reparsed.Message != "The run applied successfully." ||
		len(reparsed.Operations) != 2 || len(reparsed.AppliedOperations) != 2 {
		t.Fatalf("reparsed report = %+v, structured=%t, err=%v; raw=%s", reparsed, reparsedStructured, err, canonical)
	}
}

func TestMalformedTypedOperationsCannotDisappearBehindLegacyIgnore(t *testing.T) {
	_, err := decisionpkg.ParseWatchDecision(`{
  "action":"ignore",
  "operations":[
    {"id":"bad","type":"request_approval","task":{"kind":"incident","title":"wrong payload"}}
  ]
}`, testDecodeClock)
	if err == nil || !strings.Contains(err.Error(), "requires approval") {
		t.Fatalf("malformed operation stream was silently ignored: %v", err)
	}
}

func TestTypedResultOperationsReturnExactOperationError(t *testing.T) {
	_, _, err := decisionpkg.ParseAgentReport(`{
  "operations":[
    {"id":"e1","type":"record_evidence","evidence":{"claim_id":"host.current_state","claim":"host state","observation":"host responded","relation":"supports","source_type":"emisar","source_name":"host check"}},
    {"id":"bad","type":"request_approval","task":{"kind":"incident","title":"wrong payload"}}
  ]
}`)
	if err == nil || !strings.Contains(err.Error(), `result operation 2`) ||
		!strings.Contains(err.Error(), `requires approval`) {
		t.Fatalf("operation error = %v", err)
	}
}

func TestTypedResultOperationsReturnActionableCompletionShapeError(t *testing.T) {
	_, _, err := decisionpkg.ParseAgentReport(`{
  "operations":[
    {"id":"c1","type":"complete_episode","completion":{"message":"Blocked.","completion":{"status":"blocked","blocker_kind":"source_unavailable","blocker":"missing later evidence"}}}
  ]
}`)
	if err == nil || !strings.Contains(err.Error(), "material_gaps") ||
		!strings.Contains(err.Error(), "next_action") {
		t.Fatalf("completion shape error = %v", err)
	}
}

func TestPendingEmisarApprovalRequiresOperatorAndAuthoritativeURL(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	expires := time.Now().UTC().Add(time.Hour).Truncate(time.Second)
	pending := core.EmisarApproval{
		RequestID: "apr_123", RunID: "run_123", OperationID: "op_123",
		ActionID: "nomad.alloc_restart", PackRef: "nomad@1.2.3#sha256:abc",
		RunnerRef: "prod-1~abc123", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_123",
		ExpiresAt:   expires,
	}
	report, err := svc.persistAgentReport(
		ctx,
		decisionpkg.AgentReport{Message: "Emisar is waiting for approval.", PendingApproval: &pending},
		incident,
		incident.ChannelID,
		"slack_approval_1",
		cfg.Slack.Operators[0],
	)
	if err != nil || report.PendingApproval == nil {
		t.Fatalf("persist pending approval = %+v, %v", report, err)
	}
	stored, err := st.GetEmisarApproval(ctx, pending.RequestID)
	if err != nil || stored.RunID != pending.RunID ||
		stored.ApprovalURL != pending.ApprovalURL || !stored.ExpiresAt.Equal(expires) {
		t.Fatalf("stored pending approval = %+v, %v", stored, err)
	}

	foreign := pending
	foreign.RequestID = "apr_evil"
	foreign.RunID = "run_evil"
	foreign.ApprovalURL = "https://evil.example/app/acme/approvals/apr_evil"
	report, err = svc.persistAgentReport(
		ctx,
		decisionpkg.AgentReport{Message: "Untrusted link.", PendingApproval: &foreign},
		incident,
		incident.ChannelID,
		"slack_approval_2",
		cfg.Slack.Operators[0],
	)
	if err != nil || report.PendingApproval != nil {
		t.Fatalf("foreign approval escaped validation = %+v, %v", report, err)
	}
	if _, err := st.GetEmisarApproval(ctx, foreign.RequestID); err != store.ErrNotFound {
		t.Fatalf("foreign approval persisted: %v", err)
	}

	unowned := pending
	unowned.RequestID = "apr_unowned"
	unowned.RunID = "run_unowned"
	unowned.ApprovalURL = "https://emisar.dev/app/acme/approvals/apr_unowned"
	report, err = svc.persistAgentReport(
		ctx,
		decisionpkg.AgentReport{Message: "No operator.", PendingApproval: &unowned},
		incident,
		incident.ChannelID,
		"initial_turn",
		"",
	)
	if err != nil || report.PendingApproval != nil {
		t.Fatalf("non-operator approval escaped validation = %+v, %v", report, err)
	}

	shared := pending
	shared.RequestID = "apr_shared"
	shared.RunID = "run_shared"
	shared.ApprovalURL = "https://emisar.dev/app/acme/approvals/apr_shared"
	report, err = svc.persistAgentReport(
		ctx,
		decisionpkg.AgentReport{Message: "Emisar is waiting for approval.", PendingApproval: &shared},
		core.Incident{},
		"CSHARED",
		"slack_shared_approval",
		cfg.Slack.Operators[0],
	)
	if err != nil || report.PendingApproval == nil ||
		report.PendingApproval.IncidentID != "" ||
		report.PendingApproval.ChannelID != "CSHARED" {
		t.Fatalf("shared conversation approval = %+v, %v", report, err)
	}
	stored, err = st.GetEmisarApproval(ctx, shared.RequestID)
	if err != nil || stored.IncidentID != "" || stored.ChannelID != "CSHARED" {
		t.Fatalf("stored shared conversation approval = %+v, %v", stored, err)
	}
}

// The typed operation stream is now the only authoritative reading. A response
// that carries no operations at all is still accepted — plain prose is a valid
// reply — but a malformed operation stream is a loud failure rather than a
// silent fall back to whatever prose happened to sit beside it.
//
// Silently reading the same turn two ways was the thing worth deleting: nobody
// downstream could tell which reading they got.
func TestResultProtocolShapeIsRecorded(t *testing.T) {
	// A response with no operations at all never used the typed protocol.
	legacyOnly, _, err := decisionpkg.ParseAgentReport(`{"message":"plain prose answer"}`)
	if err != nil {
		t.Fatal(err)
	}
	if !legacyOnly.LegacyShape {
		t.Fatal("a prose-only reply was not recorded as legacy shape")
	}

	// A well-formed typed response used it, so neither flag is set.
	typed, _, err := decisionpkg.ParseAgentReport(`{"message":"","operations":[
		{"id":"c1","type":"complete_episode","completion":{"message":"answered"}}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if typed.LegacyShape {
		t.Fatal("a typed report was recorded as legacy shape")
	}

	// A malformed operation stream is now rejected even when usable prose sits
	// beside it. Accepting the prose would mean the same turn could be read two
	// ways with nobody told which happened — and the model would never learn
	// that its operation stream was wrong.
	_, _, err = decisionpkg.ParseAgentReport(`{"message":"usable prose","operations":[
		{"id":"bad","type":"complete_episode"}]}`)
	if err == nil {
		t.Fatal("a malformed operation stream was silently accepted beside legacy prose")
	}
}
