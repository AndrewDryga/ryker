package investigation

import (
	"github.com/AndrewDryga/responder/internal/core"
	"strings"
	"testing"
)

// A missing runbook is a reproducibility gap, not a blocker.
//
// The contract has said so in prose for a long time and the model ignored it.
// Asked for a scheduled platform health verdict it looked up one published
// runbook, got runbook_not_found from Emisar — correctly; there are no
// published runbooks at all — and returned "blocked" with that as its only
// material gap, never touching the underlying read-only tools. The quality
// judge scored that answer 3.33 for "fails the central request to reach a
// current verdict after exhausting equivalent read-only evidence routes".
func TestAMissingRunbookIsNotABlockerOnItsOwn(t *testing.T) {
	blockedOnTheRunbook := &CompletionAssessment{
		Status: "blocked", Summary: "cannot run the review",
		MaterialGaps: []string{
			"Published runbook deep-infrastructure-health-review-va1 was not found in the Emisar catalog",
		},
		BlockerKind: "source_unavailable",
		Attempts:    []string{"looked up the published runbook"},
		NextAction:  "publish the runbook",
	}
	err := validateBlockedCompletion(blockedOnTheRunbook)
	if err == nil {
		t.Fatal("a missing runbook was accepted as the whole blocker")
	}
	if !strings.Contains(err.Error(), "equivalent read-only checks") {
		t.Errorf("the refusal does not say what to do instead: %v", err)
	}

	// The underlying evidence genuinely being unavailable is a real blocker,
	// and it keeps its block even when a runbook is missing alongside.
	alsoMissingEvidence := &CompletionAssessment{
		Status: "blocked", Summary: "cannot reach the cluster",
		MaterialGaps: []string{
			"Published runbook deep-infrastructure-health-review-va1 was not found",
			"Prometheus is unreachable, so no current service indicator can be read",
		},
		BlockerKind: "source_unavailable",
		Attempts:    []string{"queried Prometheus directly", "looked up the runbook"},
		NextAction:  "restore Prometheus access",
	}
	if err := validateBlockedCompletion(alsoMissingEvidence); err != nil {
		t.Fatalf("a real evidence blocker was refused: %v", err)
	}
}

// direct_answer — "what is the disk usage on nomad-hst03" — defines no
// verdicts, because answering a question is not reaching a verdict. The
// mismatch branch fired anyway and told the model its verdict did not match
// the contract and to "use one of:" followed by nothing at all. There was no
// reply it could have written that would pass: fifty-three corrections across
// eight episodes, every one unanswerable.
func TestNoVerdictContractTellsTheModelToOmitIt(t *testing.T) {
	episode := core.WorkEpisode{Objective: "what is the disk usage on nomad-hst03"}
	contract := Compile(episode)
	if len(contract.Completion.AllowedVerdicts) != 0 {
		t.Skip("this conclusion kind now defines verdicts; the deadlock cannot arise")
	}
	correction := CompletionCorrection(episode, "reply", nil, &CompletionAssessment{
		Status: "decision_ready", Verdict: "degraded", Summary: "The disk is at 82%.",
	})
	if correction == "" {
		t.Fatal("a verdict on a no-verdict contract was accepted")
	}
	if strings.Contains(correction, "use one of: \n") || strings.HasSuffix(correction, "use one of: ") {
		t.Fatalf("the correction offers an empty list of verdicts: %q", correction)
	}
	if !strings.Contains(correction, "omit completion.verdict") {
		t.Fatalf("the correction does not say what to do instead: %q", correction)
	}

	// Omitting it is accepted, so the instruction is one the model can follow.
	if correction := CompletionCorrection(episode, "reply", nil, &CompletionAssessment{
		Status: "decision_ready", Summary: "The disk is at 82%.",
	}); correction != "" {
		t.Fatalf("omitting the verdict was still corrected: %q", correction)
	}
}
