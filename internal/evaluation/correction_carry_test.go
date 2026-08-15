package evaluation

import (
	"strings"
	"testing"
	"time"
)

// The harness scores a correction round against the whole investigation.
//
// The live loop replaces the response with each corrected one and re-scores it,
// so it reproduced the exact host defect it exists to catch. On a correction
// round the model returns only the operations the correction named — the ids
// below are literally suffixed "-corrected" — and drops the record_coverage rows
// round 1 emitted and the harness accepted. Scoring that stream alone reported:
//
//	premature completion: the deep work episode has not assessed required
//	coverage layers: change, application, slo
//
// which is a complaint round 1 had already answered. Three cases flapped on it
// for a day ("alert triage returns an alert assessment", "coverage statuses come
// from the allowed set", sometimes "asserted cause"); the run recorded at
// ~/.local/state/responder/eval-history/prompts-20260815T103843Z.json failed
// results 0 and 8 with that exact detail and nothing else wrong.
//
// Both rounds below are verbatim: round 1 from Coop turn
// turn_b741c3fd2d52a388459eb3dc07246ab7, the corrected round from that eval
// run's own recorded response for "alert triage returns an alert assessment".
//
// Without the carry the host fix alone would not settle these cases, because the
// gate measuring them would still be judging one round's fragment.
func TestTheHarnessScoresACorrectionRoundAgainstTheWholeInvestigation(t *testing.T) {
	cfg := serviceConfig(t)
	now := time.Now().UTC()
	testCase := EvaluationCase{
		Name:  "alert triage returns an alert assessment",
		Kind:  "watch",
		Input: harvestedAlertInput,
		StandingRules: []EvaluationStandingRule{
			{Trigger: "operational_alert", Action: "triage_alert", SourceKind: "app"},
		},
		SenderType:        "external_app",
		WantAction:        "reply",
		RequireCompletion: true,
	}

	// Round 1 records change, application and slo coverage and is corrected for
	// something else entirely.
	carryEvaluationRound(&testCase, harvestedCoverageRound, now)
	if len(testCase.CarriedCoverage) != 3 {
		t.Fatalf("round 1 established %d coverage rows, want 3", len(testCase.CarriedCoverage))
	}

	// The corrected round keeps only what the correction was about.
	testCase.Output = harvestedCorrectedAlertRound
	result := evaluateCaseWithConfig(testCase, &cfg, now)
	if strings.Contains(result.Detail, "has not assessed required coverage layers") {
		t.Fatalf(
			"the harness refused a corrected round for coverage round 1 recorded: %s",
			result.Detail,
		)
	}
}

const harvestedAlertInput = "*<https://console.cloud.google.com/monitoring/alerting/alerts/" +
	"0.obeaujx8bfxn?channelType=slack&amp;project=emisar|Emisar: Load Balancer 5xx Ratio High>*\n" +
	"ratio(loadbalancing/https/request_count, loadbalancing for emisar Global External " +
	"Application Load Balancer Rule labels {project_id=emisar} is above the threshold of " +
	"0.050 with a value of 0.273.\nAlert status\nAlert open\nNo severity"

// Round 1, harvested verbatim from Coop turn turn_b741c3fd2d52a388459eb3dc07246ab7.
const harvestedCoverageRound = `{"action":"reply","reaction":"","title":"","attention":{"addressee":"channel","urgency":2,"confidence":3,"novelty":2,"ownership":2,"contribution":"new_evidence","material":true},"reason":"Fresh production metrics and representative requests show the earlier 5xx spike is no longer present.","task_pull_request":"","publication_updates":[],"operations":[{"id":"evidence-current-metrics","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"Current service indicators show no material degradation.","observation":"Cloud Monitoring returned only 200 and 301 response series for the production HTTPS load balancer during the 10-minute window ending around 08:01 UTC; no 5xx series appeared.","relation":"supports","health_effect":"none","source_type":"emisar","source_id":"01a00471-4c14-79fa-a3f1-b1f4a309ae35","source_name":"Emisar gcp.metric_query run","freshness":"live, under 2 minutes","confidence":"high","dimensions":{"service":"global external application load balancer","indicator":"HTTPS response codes","environment":"production","window":"10 minutes"},"scope_note":"Traffic was low and sparse, so this proves the current spike ended but not its historical cause."}},{"id":"evidence-user-paths","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"Representative user paths work without a current error or timeout spike.","observation":"The production homepage and pricing page both returned complete rendered content during fresh external requests.","relation":"supports","health_effect":"none","source_type":"other","source_id":"https://emisar.dev/","source_name":"External production page fetches","freshness":"live, under 2 minutes","confidence":"high","dimensions":{"service":"Emisar portal","endpoint":"/ and /pricing","environment":"production","window":"point-in-time"},"scope_note":"The /readyz probe could not be evaluated through this fetch route, so database-aware readiness remains unverified."}},{"id":"coverage-change","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","source":"Current repository history","detail":"Recent source changes were reviewed against the deployed revision."}},{"id":"coverage-application","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"healthy","source":"Fresh external page fetches","detail":"The homepage and pricing page returned complete content; readiness remained unverified."}},{"id":"coverage-slo","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"healthy","source":"Cloud Monitoring request metric","detail":"No 5xx response series appeared in the latest 10-minute query."}},{"id":"alert-assessment","type":"record_alert_assessment","alert_assessment":{"verdict":"not_issue","impact":"No current user-facing degradation was observed on representative public paths, and no 5xx series appeared in the latest 10-minute metric window.","cause_status":"bounded","cause":"The alert reflects an earlier, low-volume 5xx spike that has ended; its historical cause was not established.","cause_claim_ids":["impact.current","application.functional_behavior"],"evidence_refs":["evidence-current-metrics","evidence-user-paths"],"immediate_action":"Leave production unchanged and allow monitoring to close the stale alert state.","verification":"A fresh 10-minute load-balancer query remains free of 5xx responses and representative public pages continue to render.","long_term_solution":"If the signal recurs, correlate response-code series with request logs and the exact deployed revision before changing infrastructure."}},{"id":"complete","type":"complete_episode","completion":{"message":"The Emisar portal has recovered. Fresh load-balancer metrics show no 5xx responses in the latest 10-minute window, and both the homepage and pricing path render normally.","followup_messages":[],"completion":{"status":"decision_ready","verdict":"healthy","summary":"Current production behavior is healthy; the earlier 5xx spike is no longer present."}}}]}`

// The corrected round, harvested verbatim from the recorded eval run: only the
// two operations the correction named, both ids suffixed "-corrected".
const harvestedCorrectedAlertRound = "{\"action\":\"reply\",\"reaction\":\"\",\"title\":\"\",\"attention\":{\"addressee\":\"channel\",\"urgency\":2,\"confidence\":3,\"novelty\":3,\"ownership\":3,\"contribution\":\"new_evidence\",\"material\":true},\"reason\":\"Fresh monitoring and Emisar checks establish that the transient load-balancer error spike has cleared and production is currently healthy.\",\"task_pull_request\":\"\",\"publication_updates\":[],\"operations\":[{\"id\":\"alert-assessment-corrected\",\"type\":\"record_alert_assessment\",\"alert_assessment\":{\"verdict\":\"not_issue\",\"impact\":\"No current degradation is visible. The public application probe passes, both production backends are healthy, and the latest 10-minute load-balancer window contains HTTP 200 traffic with no 5xx series. Impact during the earlier spike is unverified.\",\"cause_status\":\"bounded\",\"cause\":\"The 27.3% ratio was a transient event that cleared. Low request volume could have amplified a small number of failures, but available evidence does not identify the initiating request or exact error.\",\"cause_claim_ids\":[\"impact.current\"],\"evidence_refs\":[\"evidence-current-metrics\"],\"immediate_action\":\"No production mitigation is justified while the service is healthy; allow the alert to clear from the recovered metric state.\",\"verification\":\"Re-query the HTTPS request-count metric for a fresh 10-minute window and confirm no 5xx series, a passing emisar.dev uptime check, and both backends HEALTHY.\",\"long_term_solution\":\"On recurrence, correlate the exact 5xx response-code series with sampled edge request logs to identify the failing path before changing capacity or alert thresholds.\"}},{\"id\":\"complete-alert-corrected\",\"type\":\"complete_episode\",\"completion\":{\"message\":\"Emisar’s public application path has recovered. Fresh checks show both production backends healthy, the external `emisar.dev` probe passing throughout the alert window, and only HTTP 200 traffic in the latest 10-minute load-balancer query.\\n\\nThe 27.3% spike was transient and may have been amplified by low request volume. Past user impact and the exact triggering request remain unverified; both production nodes consistently run release `0.40.0`, though the runtime check did not expose its Git revision.\",\"followup_messages\":[],\"completion\":{\"status\":\"decision_ready\",\"verdict\":\"healthy\",\"summary\":\"The load-balancer 5xx spike cleared; fresh application, backend, response-code, and rollout-consistency evidence is healthy.\"}}}]}"
