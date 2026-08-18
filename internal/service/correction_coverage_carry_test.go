package service

import (
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// A task-offer correction must keep the repository evidence that made the
// offer safe. One live acceptance spent twelve provider turns alternating
// between "return decision_ready", "add repository evidence", and "add change
// coverage": the parser rejected each partial correction before the run could
// carry the records accepted in the preceding round.
func TestATaskOfferCorrectionKeepsRepositoryEvidenceAcrossRounds(t *testing.T) {
	now := time.Now().UTC()
	first, err := decisionpkg.ParseWatchDecision(
		freshenTaskOfferHarvest(t, "testdata/live_task_offer_blocked.txt", now), now,
	)
	if err != nil {
		t.Fatalf("parse evidence-bearing first round: %v", err)
	}
	input := core.SlackInput{Kind: "mention", Text: "Fix one typo and commit it."}
	if correction := decisionpkg.WatchDecisionCorrectionAt(
		input, decisionpkg.WatchTurnState{}, first, now, nil,
	); !strings.Contains(correction, "decision-ready") {
		t.Fatalf("first round correction = %q, want decision-ready boundary", correction)
	}

	second, err := decisionpkg.ParseWatchDecision(
		freshenTaskOfferHarvest(t, "testdata/live_task_offer_corrected.txt", now), now,
	)
	if err != nil {
		t.Fatalf("parse corrected task-offer round: %v", err)
	}
	second.Evidence = decisionpkg.CarryEvidence(first.Evidence, second.Evidence)
	second.Coverage = decisionpkg.CarryCoverage(first.Coverage, second.Coverage)
	if correction := decisionpkg.WatchDecisionCorrectionAt(
		input, decisionpkg.WatchTurnState{}, second, now, nil,
	); correction != "" {
		t.Fatalf("corrected task offer rejected after carrying proof: %q", correction)
	}
}

func freshenTaskOfferHarvest(t *testing.T, path string, now time.Time) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read harvested task-offer turn: %v", err)
	}
	return strings.ReplaceAll(
		string(contents), "2026-08-18T12:55:39Z", now.Format(time.RFC3339),
	)
}

// A correction round is judged against the investigation, not against the
// fragment of it the model resubmitted.
//
// All three rounds below are verbatim Coop turns from one recorded 2026-08-15
// session (remote_543b4ddacb178a1ab285ba30fa6ff903), and before the carry they
// reproduced its loop exactly, complaint for complaint. Round 1 records three
// coverage rows and three evidence rows and is told its change coverage does not
// establish change.recent. Round 2 returns nothing but the completion and is
// told it has no record_alert_assessment. Round 3 restores the assessment and
// cites evidence-current-metrics and evidence-user-paths — the exact ids round 1
// recorded and the host accepted — and was told the active issue "cites absent
// or unrelated cause evidence". Each round answered the last complaint and
// manufactured the next.
//
// Nothing persisted those rows: a correction requeues the run before the
// decision is applied, so the episode's coverage and evidence were empty at
// every round and a store lookup would have found nothing to merge. The run's
// own context is what carries them.
//
// The coverage half of the same defect is what made three eval cases flap for a
// day on "the deep work episode has not assessed required coverage layers:
// change, application, slo" — see the evaluation package for that side.
func TestACorrectionRoundKeepsTheCoverageAndEvidenceTheFirstRoundRecorded(t *testing.T) {
	decode := func(raw string) decisionpkg.WatchDecision {
		t.Helper()
		decision, err := decisionpkg.ParseWatchDecision(freshenHarvest(raw), time.Now().UTC())
		if err != nil {
			t.Fatalf("decode harvested round: %v", err)
		}
		return decision
	}
	first := decode(harvestedFirstRound)
	second := decode(harvestedCorrectedRound)
	third := decode(harvestedRecoveredRound)

	evidence := decisionpkg.CarryEvidence(first.Evidence, second.Evidence)
	evidence = decisionpkg.CarryEvidence(evidence, third.Evidence)
	coverage := decisionpkg.CarryCoverage(first.Coverage, second.Coverage)
	coverage = decisionpkg.CarryCoverage(coverage, third.Coverage)
	ids := make([]string, 0, len(evidence))
	for _, item := range evidence {
		ids = append(ids, item.ID)
	}
	for _, want := range []string{"evidence-current-metrics", "evidence-user-paths", "evidence-change-context"} {
		if !slices.Contains(ids, want) {
			t.Fatalf("harvested correction rounds lost %q: %v", want, ids)
		}
	}
	layers := make([]string, 0, len(coverage))
	for _, item := range coverage {
		layers = append(layers, item.Layer)
	}
	for _, want := range []string{"change", "application", "slo"} {
		if !slices.Contains(layers, want) {
			t.Fatalf("harvested correction rounds lost %q coverage: %v", want, layers)
		}
	}
}

// freshenHarvest re-stamps the recorded observation times onto this run's clock.
// The rounds are otherwise verbatim; only the freshness window, which is
// measured against wall time, would otherwise decide the test by its age.
func freshenHarvest(round string) string {
	now := time.Now().UTC().Format(time.RFC3339)
	return strings.NewReplacer(
		"2026-08-15T08:02:14Z", now,
		"2026-08-15T08:02:38Z", now,
	).Replace(round)
}

// Round 1, harvested verbatim from Coop turn turn_b741c3fd2d52a388459eb3dc07246ab7.
const harvestedFirstRound = `I’m checking the live application path, current error signal, and recent production revision before classifying the alert.{"action":"reply","reaction":"","title":"","attention":{"addressee":"channel","urgency":2,"confidence":3,"novelty":2,"ownership":2,"contribution":"new_evidence","material":true},"reason":"Fresh production metrics and representative requests show the earlier 5xx spike is no longer present.","task_pull_request":"","publication_updates":[],"operations":[{"id":"goal-1","type":"plan_goal","goal":{"id":"check-current-errors","kind":"check","requested_outcome":"Measure the current load-balancer error rate","completion_contract":"Fresh 10-minute request metrics classify current 5xx behavior","required":true,"prerequisite_goal_ids":[],"authority":"read_only"}},{"id":"goal-2","type":"plan_goal","goal":{"id":"check-user-paths","kind":"check","requested_outcome":"Test representative public application paths","completion_contract":"Multiple production pages return usable content without errors","required":true,"prerequisite_goal_ids":[],"authority":"read_only"}},{"id":"goal-3","type":"plan_goal","goal":{"id":"check-change-context","kind":"check","requested_outcome":"Review recent repository change context","completion_contract":"Current checkout revision and recent relevant commits are recorded","required":true,"prerequisite_goal_ids":[],"authority":"read_only"}},{"id":"evidence-current-metrics","type":"record_evidence","evidence":{"claim_id":"impact.current","claim":"Current service indicators show no material degradation.","observation":"Cloud Monitoring returned only 200 and 301 response series for the production HTTPS load balancer during the 10-minute window ending around 08:01 UTC; no 5xx series appeared.","relation":"supports","health_effect":"none","source_type":"emisar","source_id":"01a00471-4c14-79fa-a3f1-b1f4a309ae35","source_name":"Emisar gcp.metric_query run","observed_at":"2026-08-15T08:02:14Z","freshness":"live, under 2 minutes","confidence":"high","dimensions":{"service":"global external application load balancer","indicator":"HTTPS response codes","environment":"production","window":"10 minutes"},"scope_note":"Traffic was low and sparse, so this proves the current spike ended but not its historical cause."}},{"id":"evidence-user-paths","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"Representative user paths work without a current error or timeout spike.","observation":"The production homepage and pricing page both returned complete rendered content during fresh external requests.","relation":"supports","health_effect":"none","source_type":"other","source_id":"https://emisar.dev/","source_name":"External production page fetches","observed_at":"2026-08-15T08:02:38Z","freshness":"live, under 2 minutes","confidence":"high","dimensions":{"service":"Emisar portal","endpoint":"/ and /pricing","environment":"production","window":"point-in-time"},"scope_note":"The /readyz probe could not be evaluated through this fetch route, so database-aware readiness remains unverified."}},{"id":"evidence-change-context","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"The observed state is consistent with the intended current revision and recent rollout.","observation":"The checked-out repository is at cd8c8a1dce9ea29b57666f4621418c1a51999d7d, committed 2026-08-15T05:04:11Z; recent portal changes are primarily UI and content work. No authoritative deployed revision was available from this source.","relation":"supports","health_effect":"unknown","source_type":"repository","source_id":"cd8c8a1dce9ea29b57666f4621418c1a51999d7d","source_name":"Emisar repository git history","observed_at":"2026-08-15T08:02:38Z","freshness":"current checkout","confidence":"medium","dimensions":{"repository":"emisar","environment":"production","revision":"cd8c8a1dce9ea29b57666f4621418c1a51999d7d"},"scope_note":"Repository history establishes intent, not the production deployment revision."}},{"id":"coverage-change","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"unknown","source":"Current repository history","detail":"Recent source changes were reviewed, but the exact deployed production revision was not established.","observed_at":"2026-08-15T08:02:38Z"}},{"id":"coverage-application","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"healthy","source":"Fresh external page fetches","detail":"The homepage and pricing page returned complete content; readiness remained unverified.","observed_at":"2026-08-15T08:02:38Z"}},{"id":"coverage-slo","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"healthy","source":"Cloud Monitoring request metric","detail":"No 5xx response series appeared in the latest 10-minute query.","observed_at":"2026-08-15T08:02:14Z"}},{"id":"goal-1-done","type":"update_goal","goal_state":{"goal_id":"check-current-errors","state":"completed","detail":"Fresh 10-minute metrics contained only 2xx and 3xx responses."}},{"id":"goal-2-done","type":"update_goal","goal_state":{"goal_id":"check-user-paths","state":"completed","detail":"Two representative public pages rendered successfully."}},{"id":"goal-3-done","type":"update_goal","goal_state":{"goal_id":"check-change-context","state":"completed","detail":"Repository context recorded; exact deployed revision remains bounded as unknown."}},{"id":"alert-assessment","type":"record_alert_assessment","alert_assessment":{"verdict":"not_issue","impact":"No current user-facing degradation was observed on representative public paths, and no 5xx series appeared in the latest 10-minute metric window.","cause_status":"bounded","cause":"The alert reflects an earlier, low-volume 5xx spike that has ended; its historical cause was not established.","cause_claim_ids":["impact.current","application.functional_behavior"],"evidence_refs":["evidence-current-metrics","evidence-user-paths"],"immediate_action":"Leave production unchanged and allow monitoring to close the stale alert state.","verification":"A fresh 10-minute load-balancer query remains free of 5xx responses and representative public pages continue to render.","long_term_solution":"If the signal recurs, correlate response-code series with request logs and the exact deployed revision before changing infrastructure."}},{"id":"complete","type":"complete_episode","completion":{"message":"The Emisar portal has recovered. Fresh load-balancer metrics show no 5xx responses in the latest 10-minute window, and both the homepage and pricing path render normally. The alert reflects an earlier transient spike; its cause and the exact deployed revision remain unverified.","followup_messages":[],"completion":{"status":"decision_ready","verdict":"healthy","summary":"Current production behavior is healthy; the earlier 5xx spike is no longer present."}}}]}`

// Round 2, harvested verbatim from Coop turn turn_13711962c3f06bfa029af87d5ab4645d.
const harvestedCorrectedRound = `{"action":"reply","reaction":"","title":"","attention":{"addressee":"channel","urgency":2,"confidence":3,"novelty":2,"ownership":2,"contribution":"new_evidence","material":true},"reason":"Current behavior is healthy, but the required production revision comparison cannot be completed from available evidence.","task_pull_request":"","publication_updates":[],"operations":[{"id":"complete-corrected","type":"complete_episode","completion":{"message":"The Emisar portal is currently serving representative pages without a 5xx spike. I couldn’t verify the exact deployed revision, so I can’t rule a recent rollout in or out as the cause of the earlier alert.","followup_messages":[],"completion":{"status":"blocked","summary":"Current behavior appears healthy, but recent-change correlation is incomplete.","material_gaps":["The exact production deployment revision and rollout time are unavailable."],"blocker_kind":"source_unavailable","attempts":["Queried fresh load-balancer request metrics through Emisar.","Fetched representative production pages externally.","Reviewed the current repository revision and recent history.","Searched Emisar for a deployed-revision inspection action."],"next_action":"Provide access to the authoritative production deployment record or revision source so it can be compared with repository history."}}}]}`

// Round 3, harvested verbatim from Coop turn turn_c96afcede127cda483b7a39827b4a90a.
// It re-adds the alert assessment the round before dropped, and cites round 1's
// evidence by the exact ids round 1 recorded.
const harvestedRecoveredRound = `{"action":"reply","reaction":"","title":"","attention":{"addressee":"channel","urgency":2,"confidence":3,"novelty":2,"ownership":2,"contribution":"new_evidence","material":true},"reason":"Fresh evidence shows the 5xx spike ended, while deployment correlation remains unavailable.","task_pull_request":"","publication_updates":[],"operations":[{"id":"alert-assessment-corrected","type":"record_alert_assessment","alert_assessment":{"verdict":"not_issue","impact":"No current user-facing degradation was observed on representative public paths, and the latest 10-minute load-balancer query contained no 5xx series.","cause_status":"bounded","cause":"The signal was a transient earlier spike; the exact cause cannot be correlated because the deployed production revision is unavailable.","cause_claim_ids":["impact.current","application.functional_behavior"],"evidence_refs":["evidence-current-metrics","evidence-user-paths"],"immediate_action":"Leave production unchanged while normal alert evaluation confirms the cleared condition.","verification":"The latest 10-minute load-balancer window remains free of 5xx responses and representative public pages continue to render.","long_term_solution":"Expose the deployed commit and rollout timestamp through an authoritative read-only source so future error spikes can be correlated with releases."}},{"id":"complete-corrected","type":"complete_episode","completion":{"message":"The Emisar portal is currently serving representative pages without a 5xx spike. No immediate production change is warranted. I couldn’t verify the exact deployed revision, so the earlier spike’s cause remains uncorrelated.","followup_messages":[],"completion":{"status":"blocked","summary":"The current alert condition has cleared, but required recent-change correlation is incomplete.","material_gaps":["The exact production deployment revision and rollout time are unavailable."],"blocker_kind":"source_unavailable","attempts":["Queried fresh load-balancer request metrics through Emisar.","Fetched representative production pages externally.","Reviewed the current repository revision and recent history.","Searched Emisar for a deployed-revision inspection action."],"next_action":"Provide an authoritative production deployment record or deployed-revision source for correlation."}}}]}`
