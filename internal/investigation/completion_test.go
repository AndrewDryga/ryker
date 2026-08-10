package investigation

import (
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
