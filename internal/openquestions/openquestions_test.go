package openquestions_test

import (
	"strings"
	"testing"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/openquestions"
)

// An open question the host has agreed to leave open still has to say why.
//
// The correction now lets an unexplained finding rest when one of its
// alternatives says what check would settle it and why that check is not
// available — the exit two eval-prompts cases were reaching for on 2026-08-16
// and could not express. The operator reads the reply, not the ledger, so the
// caveat has to carry both halves: the question, and the reason it is still a
// question. A bare "Unexplained: ..." beside a decision_ready verdict reads as
// the host having given up rather than as a bounded answer.
func TestAnUnexplainedFindingSaysWhyItIsNotCheckableNow(t *testing.T) {
	// The finding is the recorded Nomad rollback, with the sentence the model's
	// own completion used for why nothing available settles it.
	decision := decisionpkg.WatchDecision{
		Action: "reply",
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "confirmed",
			Summary: "The VA1 pyke rollout failure and automatic rollback are confirmed.",
		},
		Findings: []investigation.FindingOperation{{
			What: "VA1 pyke failed to deploy and automatically rolled back after all three " +
				"replacement allocations failed to start.",
			Scope:  "VA1 production pyke workload",
			Status: "unexplained",
			Alternatives: []investigation.FindingAlternative{{
				Hypothesis: "An image, task configuration, placement, or resource error " +
					"prevented allocation startup.",
				NotCheckable: "the Emisar catalog has no Nomad allocation diagnostic; the " +
					"allocation events and task startup logs would settle it",
			}},
		}},
	}
	open := openquestions.For(decision)
	if len(open.Unexplained) != 1 {
		t.Fatalf("the unexplained finding did not reach the caveat: %+v", open)
	}
	line := open.Unexplained[0]
	if !strings.Contains(line, "not checkable now:") {
		t.Fatalf("the caveat does not say why the question is still open: %q", line)
	}
	if !strings.Contains(line, "VA1 pyke failed to deploy") {
		t.Fatalf("the caveat lost the open question itself: %q", line)
	}
	if !strings.Contains(line, "no Nomad allocation diagnostic") {
		t.Fatalf("the caveat lost the reason the check is unavailable: %q", line)
	}
	// Bounded like every other model-controlled string that reaches a Slack
	// context line, which already truncates the whole joined caveat at 700.
	if len([]rune(line)) > 200 {
		t.Fatalf("the caveat line is %d runes: %q", len([]rune(line)), line)
	}

	// A finding with no uncheckable alternative still renders exactly what it
	// rendered before: the question, and nothing invented after it.
	plain := decision
	bare := decision.Findings[0]
	bare.Alternatives = nil
	plain.Findings = []investigation.FindingOperation{bare}
	if got := openquestions.For(plain).Unexplained; len(got) != 1 || got[0] != bare.What {
		t.Fatalf("a finding with no uncheckable alternative changed shape: %+v", got)
	}
}
