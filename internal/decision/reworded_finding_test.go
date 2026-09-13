package decision

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

// liveCarriedFindings is the carried_findings list out of the context envelope
// of live run run_532f8d62871320dc9d0696cb334d3503, harvested whole. Five
// entries, and four of them are the same blitz-infra refresh drift under four
// different sentences: that is what keying a finding's identity on its text
// produces once the model starts rewording.
func liveCarriedFindings(t *testing.T) []investigation.FindingOperation {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "live_run_532f8d62_carried_findings.json"))
	if err != nil {
		t.Fatal(err)
	}
	var findings []investigation.FindingOperation
	if err := json.Unmarshal(data, &findings); err != nil {
		t.Fatal(err)
	}
	if len(findings) < 2 {
		t.Fatalf("the harvested envelope carries %d findings", len(findings))
	}
	return findings
}

// recordedReply parses a recorded response as the reply the correction ran on.
// The blitz-infra result was accepted with action "ignore" because the host
// suppressed a successful lifecycle status; the thirteen corrections were
// judged before that, on the reply shape, so the action is the one thing
// rewritten here and every sentence stays the model's.
func recordedReply(t *testing.T, name string) WatchDecision {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Replace(string(data), `"action":"ignore"`, `"action":"reply"`, 1)
	decision, err := ParseWatchDecision(body, time.Date(2026, 8, 16, 17, 22, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return decision
}

// A finding is the failure state it names, not the sentence that named it.
//
// Thirteen corrections and twenty-three minutes on 2026-08-16 for a finding the
// model had already reclassified under different words. Live run
// run_532f8d62871320dc9d0696cb334d3503, a Terraform apply on blitz-infra, was
// told the same thing every ninety seconds from 17:03 to 17:22 — finding "The
// blitz-infra refresh reports 121 resources changed outside Terraform,
// dominated by betteruptime_monitor" is unexplained — while the finding it was
// emitting said the same thing in new words and said it out_of_scope.
func TestARewordedFindingIsTheSameFinding(t *testing.T) {
	live := liveCarriedFindings(t)
	drift, otherRun := live[0], live[1]
	reclassified := recordedReply(t, "live_run_532f8d62_result.json").Findings[0]
	pyke := recordedReply(t, "eval_pyke_rollback_unexplained.json").Findings[0]
	drift.Key = "finding-refresh-drift"
	reclassified.Key = "finding-refresh-drift"

	for _, testCase := range []struct {
		name    string
		prior   investigation.FindingOperation
		current investigation.FindingOperation
		same    bool
	}{
		// The live pair. The stable key, rather than eleven coincidentally shared
		// or similar words, says these are the same failure state.
		{"the wording the model dropped", drift, reclassified, true},
		{"and the same pair read the other way", reclassified, drift, true},
		// A prior run's rollback in a different workspace. Nothing about the
		// two sentences overlaps except the words any two findings share.
		{"a prior run's va1-apps rollback", otherRun, reclassified, false},
		// Two genuinely different failures that both happen to be about
		// production.
		{"a pyke rollout failure is not blitz-infra drift", drift, pyke, false},
		// The operation id settles it outright when it survives, without
		// reading a word of either sentence.
		{
			"the same stable key under a total rewrite",
			investigation.FindingOperation{
				Key: "finding-refresh-drift", What: drift.What,
				Scope: drift.Scope, Status: "unexplained",
			},
			investigation.FindingOperation{
				Key: "finding-refresh-drift", What: pyke.What,
				Scope: pyke.Scope, Status: "out_of_scope",
			},
			true,
		},
		{
			"similar generated prose has no identity authority",
			investigation.FindingOperation{What: drift.What, Scope: drift.Scope},
			investigation.FindingOperation{What: reclassified.What, Scope: reclassified.Scope},
			false,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if same := sameFinding(testCase.prior, testCase.current); same != testCase.same {
				t.Fatalf("sameFinding = %t, want %t\nprior:   %q (%q)\ncurrent: %q (%q)",
					same, testCase.same,
					testCase.prior.What, testCase.prior.Scope,
					testCase.current.What, testCase.current.Scope)
			}
		})
	}
}

// A finding the model was corrected about is not carried past its answer.
//
// Thirteen corrections and twenty-three minutes on 2026-08-16 for a finding the
// model had already reclassified under different words. Correction rounds carry
// earlier rounds' findings forward keyed on the lower-cased `what`, so the
// reworded reclassification landed beside the old unexplained copy instead of
// replacing it, and every round after that was judged on a finding the model no
// longer emitted and could not edit.
func TestAReclassifiedFindingIsNotJudgedByItsOldWording(t *testing.T) {
	prior := liveCarriedFindings(t)[:1]
	prior[0].Key = "finding-refresh-drift"
	if prior[0].Status != "unexplained" {
		t.Fatalf("the harvested prior is not the unexplained wording: %+v", prior[0])
	}
	accepted := recordedReply(t, "live_run_532f8d62_result.json")
	if len(accepted.Findings) != 1 || accepted.Findings[0].Status != "out_of_scope" {
		t.Fatalf("the accepted result is not one out_of_scope finding: %+v", accepted.Findings)
	}

	carried := CarryFindings(prior, accepted.Findings)
	if len(carried) != 1 {
		t.Fatalf("the answer did not retire its own earlier wording: %+v", carried)
	}
	if carried[0].Status != "out_of_scope" {
		t.Fatalf("the carried verdict is %q, want out_of_scope: %+v", carried[0].Status, carried[0])
	}

	episode := core.WorkEpisode{Effort: core.EffortOperationalAssessment}
	if correction := FindingCorrection(episode, accepted, carried); correction != "" {
		t.Fatalf("the reclassified finding was corrected a fourteenth time: %q", correction)
	}
}

// "Unexplained, and no available check can settle it now" is an honest final
// state, and it needs a shape or the rule is unsatisfiable.
//
// Two eval-prompts cases failed on 2026-08-16 saying exactly that. The Nomad
// rollback put the check that would settle it in discriminated_by — which is an
// evidence id field — because the four exits the correction offered had no room
// for "the current Emisar catalog has no Nomad diagnostic", which is what its
// own reply said. The recovered portal 503 did the same in prose: "current
// evidence can't distinguish a brief no-healthy-backend interval from an
// application-generated 503". Neither could identify a cause, continue, block,
// or honestly call the failure expected or out_of_scope, so both looped.
func TestAnUnexplainedFindingWithANamedUncheckableCheckMayRest(t *testing.T) {
	episode := core.WorkEpisode{Effort: core.EffortOperationalAssessment}

	rollback := recordedReply(t, "eval_pyke_rollback_unexplained.json")
	if len(rollback.Findings) != 1 || rollback.Findings[0].Status != "unexplained" {
		t.Fatalf("the recorded rollback is not one unexplained finding: %+v", rollback.Findings)
	}
	// As recorded: the alternative describes the check in prose, in the field
	// that takes an evidence id, and names nothing the catalog can fetch. That
	// is still an unexplained finding resting at decision_ready, and it is still
	// refused — the exit is the model saying so in not_checkable, not the model
	// misfiling a sentence.
	correction := FindingCorrection(episode, rollback, rollback.Findings)
	if correction == "" {
		t.Fatal("an unexplained finding rested at decision_ready with no uncheckable rival named")
	}
	for _, exit := range []string{"not_checkable", "wait_external", "blocked", "out_of_scope"} {
		if !strings.Contains(correction, exit) {
			t.Fatalf("the correction does not offer the %q exit: %q", exit, correction)
		}
	}

	// And the same answer with the check named where the contract can read it.
	// The sentence is the model's own, out of the recorded completion message.
	settled := rollback
	rested := rollback.Findings[0]
	rested.Alternatives = []investigation.FindingAlternative{{
		Hypothesis: rollback.Findings[0].Alternatives[0].Hypothesis,
		NotCheckable: "the Emisar catalog has no Nomad allocation diagnostic; the allocation " +
			"events and task startup logs would settle it",
	}}
	settled.Findings = []investigation.FindingOperation{rested}
	if correction := FindingCorrection(episode, settled, settled.Findings); correction != "" {
		t.Fatalf("a named uncheckable check did not let the finding rest: %q", correction)
	}

	// The recovered portal 503, whose recorded response carries this failure
	// state only in the eval case's carried findings. It is rebuilt here from
	// the same response's own sentences: `what` is the recorded alert
	// assessment's cause, and not_checkable is the completion's closing line.
	recovered := recordedReply(t, "eval_recovered_transient_503_unexplained.json")
	if recovered.AlertAssessment == nil {
		t.Fatal("the recorded 503 response carries no alert assessment")
	}
	transient := investigation.FindingOperation{
		What:   recovered.AlertAssessment.Cause,
		Scope:  "emisar portal load balancer",
		Status: "unexplained",
	}
	if correction := FindingCorrection(episode, recovered, []investigation.FindingOperation{
		transient,
	}); correction == "" {
		t.Fatal("the transient 503 rested unexplained with no uncheckable rival named")
	}
	transient.Alternatives = []investigation.FindingAlternative{{
		Hypothesis: "An application-generated 503 rather than a brief no-healthy-backend interval",
		NotCheckable: "current evidence can't distinguish a brief no-healthy-backend interval " +
			"from an application-generated 503; if it recurs, " +
			"statusDetails=failed_to_pick_backend in the load-balancer logs will distinguish them",
	}}
	if correction := FindingCorrection(episode, recovered, []investigation.FindingOperation{
		transient,
	}); correction != "" {
		t.Fatalf("the recovered 503 could not rest on a check it cannot run: %q", correction)
	}
}
