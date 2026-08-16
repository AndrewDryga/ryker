package decision

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// zotTriageReply is the 12:16 message from the Zot thread on 2026-08-11, copied
// out of episode_run_ebbee0227d72743cc4aee48ef01113ba's completion_submitted
// event. It is the reason this whole file exists.
//
// The turn met its contract exactly: decision_ready, verdict succeeded, on a
// Terraform Run-Applied event. The failure it had DISCOVERED — a rollout that
// missed its progress deadline and rolled back — was reported in prose and
// handed to the readers as "avoid retrying until the failed allocation or health
// check is identified". No validator could see it, so nothing refused the
// completion. Three human nudges and 88 minutes later a deep dive found the root
// cause (Zot auth masked as a manifest-unknown 404) in four.
const zotTriageReply = "Production `pyke-server` applied, but VA1 `pyke` **did not deploy**: " +
	"its rollout missed the progress deadline and automatically rolled back to job version 5. " +
	"Keep that rollback in place and avoid retrying until the failed allocation or health check " +
	"is identified; verification is a new deployment reaching `successful` with the intended " +
	"allocations healthy. Customer impact is unverified."

// sentryRecoveryReply is the false positive the negative guards exist for, from
// the same corpus (2026-08-05T20:58:57Z). It contains "rollback" — in "a
// health-gated rollout and rollback procedure", a recommendation about the
// future — while reporting that the service came back. A rule that read the
// failure vocabulary alone would demand a finding for a recovery report, which
// is how a correction becomes noise and stops being read.
const sentryRecoveryReply = "**Sentry recovered.** A fresh `/_health/` request returns 200, the " +
	"sole instance and load-balancer backend are both healthy, and the new 26.7.2 template has " +
	"finished rolling out.\n\nThe 21-minute outage was caused by recreating that only instance " +
	"with no surge capacity; Sentry stayed unavailable until startup completed. No immediate " +
	"mitigation is needed now. The durable fix is redundancy or a health-gated rollout and " +
	"rollback procedure so future replacements don't remove the only serving instance."

// zotClosureReply is the second recovery shape, from 2026-08-15T19:55:31Z: the
// same Zot subject, reported clear. "no matching auth or upstream-sync failures"
// is an absence of failures, and an absence is not a finding.
const zotClosureReply = "Zot’s Artifact Registry authentication issue is **not recurring**. The " +
	"last 24 hours contain no matching auth or upstream-sync failures, and all five node-local " +
	"Zot instances performed an on-demand upstream sync of the exact pinned frontend-utilities " +
	"manifest and returned the same OCI manifest successfully. Nomad also shows five healthy Zot " +
	"allocations, one per VA1 node, with no node-specific contradiction."

func decisionReady(message string) WatchDecision {
	return WatchDecision{
		Action: "reply", Message: message,
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "succeeded",
			Summary: "The target production run succeeded; the same revision’s VA1 rollout failed.",
		},
	}
}

func watchEpisode() core.WorkEpisode {
	return core.WorkEpisode{Effort: core.EffortFocusedCheck}
}

// A reply that reports a failure must record it where a contract can see it.
//
// This is the exact turn that cost 88 minutes: the reply names a rollback and a
// missed progress deadline, the result carries no record_finding, and the
// completion is decision_ready. Nothing else about it was wrong, which is the
// point — the contract was the gap.
func TestAReplyThatReportsAFailureMustRecordAFinding(t *testing.T) {
	correction := FindingCorrection(watchEpisode(), decisionReady(zotTriageReply), nil)
	if correction == "" {
		t.Fatal("the Zot triage reply reported a rollback and recorded no finding, uncorrected")
	}
	for _, required := range []string{"typed finding", "unexplained"} {
		if !strings.Contains(correction, required) {
			t.Fatalf("the correction does not name %q: %q", required, correction)
		}
	}

	// A followup carries the same weight as the message. Splitting the failure
	// into a second Slack part must not be a way past the rule.
	split := decisionReady("Production `pyke-server` applied.")
	split.FollowupMessages = []string{"VA1 `pyke` **did not deploy**: it rolled back to job version 5."}
	if FindingCorrection(watchEpisode(), split, nil) == "" {
		t.Fatal("a failure reported in a follow-up message escaped the rule")
	}

	// And the way out is the operation itself, not silence.
	recorded := []investigation.FindingOperation{{
		What:  "VA1 pyke did not deploy; its rollout missed the progress deadline",
		Scope: "va1-apps", Status: "unexplained",
	}}
	continued := decisionReady(zotTriageReply)
	continued.AppliedOperations = []investigation.ResultOperation{{
		ID: "goal-root-cause", Type: "plan_goal",
		Goal: &investigation.GoalOperation{ID: "goal-1", Kind: "check"},
	}}
	if correction := FindingCorrection(watchEpisode(), continued, recorded); correction != "" {
		t.Fatalf("a recorded finding with a continuation goal was still corrected: %q", correction)
	}
}

// A recovery report is not a failure report, however much failure vocabulary it
// contains.
//
// Both fixtures are real completions. The Sentry one recommends "a health-gated
// rollout and rollback procedure" while saying the service came back; the Zot
// one reports "no matching auth or upstream-sync failures". A finding demanded
// on either is a correction round spent, an episode's budget spent with it, and
// the next real correction read as noise.
func TestARecoveryReportDoesNotDemandAFinding(t *testing.T) {
	for _, reply := range []string{sentryRecoveryReply, zotClosureReply} {
		if correction := FindingCorrection(watchEpisode(), decisionReady(reply), nil); correction != "" {
			t.Fatalf("a recovery report was told to record a finding: %q\nreply: %s", correction, reply)
		}
	}

	// Nor is anything that never mentions a failure at all, and nor is a reply
	// that already said it could not finish: a blocked completion has named its
	// obstacle in the shape the host asked for.
	quiet := decisionReady("Disk usage on `nomad-hst03` is 41% of 1.8 TiB, unchanged since Tuesday.")
	if correction := FindingCorrection(watchEpisode(), quiet, nil); correction != "" {
		t.Fatalf("an ordinary answer was told to record a finding: %q", correction)
	}
	blocked := decisionReady(zotTriageReply)
	blocked.Completion = &investigation.CompletionAssessment{
		Status: "blocked", Summary: "The allocation state cannot be read.",
	}
	if correction := FindingCorrection(watchEpisode(), blocked, nil); correction != "" {
		t.Fatalf("a blocked completion was told to record a finding: %q", correction)
	}
}

// The governing invariant, in the one place it is enforceable: an unexplained
// failure in scope means the episode is not done.
//
// Fast completions are supposed to happen because nothing is unexplained, never
// because a turn preferred to stop. The four exits the correction names are the
// whole stop-set — an evidence-backed cause, a continuation, a typed blocker, or
// a classification an operator can audit — and each is tested here, because a
// rule with no reachable exit is the 6.6-repeat correction loop again.
func TestAnUnexplainedFindingCannotRestAtDecisionReady(t *testing.T) {
	unexplained := []investigation.FindingOperation{{
		What:  "VA1 pyke did not deploy; its rollout missed the progress deadline",
		Scope: "va1-apps", Status: "unexplained",
	}}
	// The reply that carries the finding still says nothing about a failure in
	// so many words, so this is the finding rule firing and not the reply rule.
	resting := decisionReady("Production applied; the VA1 rollout needs another look.")
	correction := FindingCorrection(watchEpisode(), resting, unexplained)
	if correction == "" {
		t.Fatal("an unexplained finding completed decision_ready uncorrected")
	}
	for _, required := range []string{
		"VA1 pyke did not deploy", "evidence ids", "blocked", "out_of_scope",
	} {
		if !strings.Contains(correction, required) {
			t.Fatalf("the correction does not name %q: %q", required, correction)
		}
	}

	// Exit one: the cause is identified with evidence.
	explained := []investigation.FindingOperation{{
		What: unexplained[0].What, Status: "explained",
		CauseEvidence: []string{"evidence-zot-auth"},
	}}
	if correction := FindingCorrection(watchEpisode(), resting, explained); correction != "" {
		t.Fatalf("an explained finding was corrected: %q", correction)
	}

	// Exit two: the episode keeps going. A planned goal, a scheduled wait, or a
	// recheck directive each say the work continues in this same episode, which
	// is the delta-update shape the prompt asks for.
	for _, continuation := range []investigation.ResultOperation{
		{ID: "goal-1", Type: "plan_goal", Goal: &investigation.GoalOperation{ID: "goal-1", Kind: "check"}},
		{ID: "wait-1", Type: "wait_external", ExternalWait: &investigation.ExternalWaitOperation{ID: "w1"}},
	} {
		continuing := resting
		continuing.AppliedOperations = []investigation.ResultOperation{continuation}
		if correction := FindingCorrection(watchEpisode(), continuing, unexplained); correction != "" {
			t.Fatalf("a turn continuing via %s was corrected: %q", continuation.Type, correction)
		}
	}
	rechecking := resting
	rechecking.Completion = &investigation.CompletionAssessment{
		Status: "decision_ready", Verdict: "succeeded", Summary: "posted; still looking",
		Recheck: &investigation.RecheckDirective{Key: "nomad:alloc:pyke", Reason: "the allocation may settle"},
	}
	if correction := FindingCorrection(watchEpisode(), rechecking, unexplained); correction != "" {
		t.Fatalf("a turn with a recheck directive was corrected: %q", correction)
	}

	// A turn that has not concluded anything yet is not resting on the finding.
	// CompletionCorrection owns the missing completion, and firing here first
	// would spend a round telling the model about the second problem.
	unfinished := resting
	unfinished.Completion = nil
	if correction := FindingCorrection(watchEpisode(), unfinished, unexplained); correction != "" {
		t.Fatalf("a turn with no completion was corrected for its finding: %q", correction)
	}

	// Exit three: a typed blocker. The obstacle is stated in the shape the host
	// already validates, so there is nothing left to refuse.
	blocked := resting
	blocked.Completion = &investigation.CompletionAssessment{
		Status: "blocked", Summary: "The failed allocation cannot be read.",
	}
	if correction := FindingCorrection(watchEpisode(), blocked, unexplained); correction != "" {
		t.Fatalf("a blocked completion was corrected for an unexplained finding: %q", correction)
	}

	// Exit four: the classification. Recorded, correctable, and auditable later
	// — which is what makes it a legal exit rather than a way to stop caring.
	for _, status := range []string{"expected", "out_of_scope"} {
		classified := []investigation.FindingOperation{{
			What: unexplained[0].What, Status: status,
			Reason: "the rollback is the configured safety behaviour for a missed deadline.",
		}}
		if correction := FindingCorrection(watchEpisode(), resting, classified); correction != "" {
			t.Fatalf("a %s classification was corrected: %q", status, correction)
		}
	}
}

// An identified cause has to survive its strongest alternative, and the host
// checks the residue rather than the process.
//
// The deep prompt tells the model to spawn its own subagents and falsify its top
// hypothesis. Prompts drift, and a process nothing verifies is a process that
// quietly stops happening — so what is checked is the typed residue: the rival
// hypothesis and the evidence id that discriminates, or the reason no check can.
func TestAnIdentifiedCauseMustSurviveItsStrongestAlternative(t *testing.T) {
	asserted := []investigation.FindingOperation{{
		What: "VA1 pyke did not deploy", Status: "explained",
		CauseEvidence: []string{"evidence-zot-auth"},
	}}
	reply := decisionReady("The VA1 rollout failed because Zot returned a 404 for the pinned manifest.")
	for _, effort := range []core.EffortContract{
		core.EffortOperationalAssessment, core.EffortIncidentInvestigation,
	} {
		episode := core.WorkEpisode{Effort: effort}
		correction := FindingCorrection(episode, reply, asserted)
		if correction == "" {
			t.Fatalf("the %s lane asserted a cause with no alternative, uncorrected", effort)
		}
		for _, required := range []string{"strongest alternative", "discriminates"} {
			if !strings.Contains(correction, required) {
				t.Fatalf("the correction does not name %q: %q", required, correction)
			}
		}
	}

	// Either residue satisfies it. "No check discriminates, and here is why" is
	// an honest answer; the rule is against silence, not against limits.
	for _, alternative := range []investigation.FindingAlternative{
		{Hypothesis: "the health check threshold changed", DiscriminatedBy: "evidence-job-diff"},
		{Hypothesis: "the node ran out of disk", NotCheckable: "the allocation is already garbage collected"},
	} {
		attacked := []investigation.FindingOperation{{
			What: asserted[0].What, Status: "explained",
			CauseEvidence: asserted[0].CauseEvidence,
			Alternatives:  []investigation.FindingAlternative{alternative},
		}}
		episode := core.WorkEpisode{Effort: core.EffortIncidentInvestigation}
		if correction := FindingCorrection(episode, reply, attacked); correction != "" {
			t.Fatalf("an attacked cause was still corrected: %q", correction)
		}
	}
}

// The fast path stays fast. Depth is triggered by anomaly, never rationed by
// budget — and equally never charged to a lane that did not discover one.
//
// A watch turn answering a question and a conversational turn are the unexciting
// 95%; making either pay a round for adversarial residue would be the rule
// eating the latency it exists to justify.
func TestTheFastLanesDoNotPayForAdversarialResidue(t *testing.T) {
	asserted := []investigation.FindingOperation{{
		What: "VA1 pyke did not deploy", Status: "explained",
		CauseEvidence: []string{"evidence-zot-auth"},
	}}
	reply := decisionReady("The VA1 rollout failed because Zot returned a 404 for the pinned manifest.")
	for _, effort := range []core.EffortContract{
		core.EffortConversational, core.EffortFocusedCheck,
	} {
		episode := core.WorkEpisode{Effort: effort}
		if correction := FindingCorrection(episode, reply, asserted); correction != "" {
			t.Fatalf("the %s lane was charged for adversarial residue: %q", effort, correction)
		}
	}
}

// A correction round keeps the findings the earlier rounds established.
//
// This repo has already paid for the general version of this bug twice, in
// evidence and in coverage: a correction round returns only the operations the
// correction named, nothing persists the rest, and every validator that reads
// accumulated state then sees one round's fragment. For findings the failure is
// worse than a redundant complaint — an unexplained finding refuses the
// completion, so a round that dropped it would be judged as having discovered
// nothing, and the very rule that keeps the episode open would be the thing
// that lost it.
func TestFindingsSurviveACorrectionRound(t *testing.T) {
	first := []investigation.FindingOperation{{
		What: "VA1 pyke did not deploy", Scope: "va1-apps", Status: "unexplained",
	}}
	// Round two answers a different complaint entirely and re-emits nothing.
	carried := CarryFindings(first, nil)
	if len(carried) != 1 || carried[0].Status != "unexplained" {
		t.Fatalf("the round-one finding did not survive round two: %+v", carried)
	}
	// Round three finally explains it, and the newer verdict replaces the older
	// one rather than accumulating beside it — the id is the failure state
	// named, because a correction round's operation ids are suffixed
	// "-corrected" and would fold nothing.
	explained := []investigation.FindingOperation{{
		What: "VA1 pyke did not deploy", Scope: "va1-apps", Status: "explained",
		CauseEvidence: []string{"evidence-zot-auth"},
	}}
	settled := CarryFindings(carried, explained)
	if len(settled) != 1 || settled[0].Status != "explained" {
		t.Fatalf("the explanation did not replace the unexplained record: %+v", settled)
	}
	// And a second, genuinely different failure is not folded into the first.
	other := CarryFindings(settled, []investigation.FindingOperation{{
		What: "the Consul registration for zot flapped", Status: "unexplained",
	}})
	if len(other) != 2 {
		t.Fatalf("two distinct failure states collapsed into one: %+v", other)
	}
}

// Findings reach the decision the same way evidence and coverage do, or the
// three rules above are enforcing a field nothing fills.
func TestFindingsFoldOutOfTheOperationStream(t *testing.T) {
	result := `{"action":"reply","operations":[
		{"id":"finding-1","type":"record_finding","finding":{
			"what":"VA1 pyke did not deploy","scope":"va1-apps","status":"unexplained"}},
		{"id":"complete-1","type":"complete_episode","completion":{
			"message":"` + "Production applied; VA1 did not." + `",
			"completion":{"status":"decision_ready","verdict":"succeeded","summary":"mixed"}}}]}`
	decision, err := ParseWatchDecision(result, time.Date(2026, 8, 11, 18, 16, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if len(decision.Findings) != 1 || decision.Findings[0].Status != "unexplained" {
		t.Fatalf("findings did not fold out of the operation stream: %+v", decision.Findings)
	}
}

// Bounds, on the same reasoning as every other sanitizer here: a payload the
// model controls is a payload that must not be able to fill the database or the
// next prompt.
func TestSanitizeFindingsBoundsWhatItStores(t *testing.T) {
	long := strings.Repeat("x", 4000)
	ids := make([]string, investigation.MaxFindingCauseEvidence+5)
	for index := range ids {
		ids[index] = "evidence-" + strings.Repeat("y", index+1)
	}
	alternatives := make([]investigation.FindingAlternative, investigation.MaxFindingAlternatives+3)
	for index := range alternatives {
		alternatives[index] = investigation.FindingAlternative{
			Hypothesis: long, DiscriminatedBy: long,
		}
	}
	sanitized := SanitizeFindings([]investigation.FindingOperation{
		{
			What: long, Scope: long, Status: " EXPLAINED ", Reason: long,
			CauseEvidence: ids, Alternatives: alternatives,
		},
		// Dropped, not stored: a finding with no failure state names nothing,
		// and an unrecognised status would make the rules above read it as
		// neither unexplained nor resolved.
		{What: "", Status: "unexplained"},
		{What: "something broke", Status: "probably_fine"},
	})
	if len(sanitized) != 1 {
		t.Fatalf("sanitize kept %d findings, want 1: %+v", len(sanitized), sanitized)
	}
	kept := sanitized[0]
	if kept.Status != "explained" {
		t.Fatalf("status was not normalized: %q", kept.Status)
	}
	if len(kept.What) >= len(long) || len(kept.Scope) >= len(long) || len(kept.Reason) >= len(long) {
		t.Fatalf("unbounded text survived: what=%d scope=%d reason=%d",
			len(kept.What), len(kept.Scope), len(kept.Reason))
	}
	if len(kept.CauseEvidence) > investigation.MaxFindingCauseEvidence {
		t.Fatalf("cause evidence = %d ids", len(kept.CauseEvidence))
	}
	if len(kept.Alternatives) > investigation.MaxFindingAlternatives {
		t.Fatalf("alternatives = %d", len(kept.Alternatives))
	}
	if len(kept.Alternatives[0].Hypothesis) >= len(long) {
		t.Fatalf("an unbounded hypothesis survived: %d bytes", len(kept.Alternatives[0].Hypothesis))
	}
}
