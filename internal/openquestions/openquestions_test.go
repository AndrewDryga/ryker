package openquestions_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/openquestions"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// An open question the host has agreed to leave open still has to say why.
//
// The correction now lets an unexplained finding rest when one of its
// alternatives says what check would settle it and why that check is not
// available — the exit two eval-prompts cases were reaching for on 2026-08-16
// and could not express. The operator reads the reply, not the ledger, so the
// caveat has to carry both halves: the question, and the reason it is still a
// question. A bare uncertainty label beside a decision_ready verdict reads as
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
	// Bounded below Slack's 500-byte context-element limit, leaving room for the
	// "Remaining uncertainty: " label applied by the renderer.
	if len([]byte(line)) > 480 {
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

// The typed wait is what Responder actually scheduled. A vague freeform next
// action must not hide it, and an already-imperative verification must not
// render as "verify verify".
func TestScheduledVerificationOutranksVagueNextActionAndRendersOnce(t *testing.T) {
	decision := decisionpkg.WatchDecision{
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", NextAction: "Monitor it later.",
		},
		AppliedOperations: []investigation.ResultOperation{{
			Type: "wait_external", ExternalWait: &investigation.ExternalWaitOperation{
				Kind:         "scheduled_verification",
				Verification: "Verify all eight routed services are healthy after the rollout",
				PollAfter:    time.Date(2026, 8, 17, 19, 25, 0, 0, time.UTC).Format(time.RFC3339),
			},
		}},
	}
	got := openquestions.For(decision).NextCheck
	if got != "verify all eight routed services are healthy after the rollout at 19:25 UTC" {
		t.Fatalf("scheduled next check = %q", got)
	}
}

// The complete production caveat is 282 bytes and fits comfortably in one
// Slack context element. A private 200-byte bound nevertheless cut it after
// "acknowledgements no", removing the check that would resolve the question.
func TestUnexplainedFindingKeepsItsNotCheckableReasonWholeWhenItFitsSlack(t *testing.T) {
	decision := decisionpkg.WatchDecision{
		Action: "reply",
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "not_confirmed",
		},
		Findings: []investigation.FindingOperation{{
			What:   "Both long-lived Gate sessions accept requests but return no matching RPC responses before the five-second deadline",
			Status: "unexplained",
			Alternatives: []investigation.FindingAlternative{{
				Hypothesis:   "The connected sessions are stale or half-open and need forced reauthentication",
				NotCheckable: "The current code records neither heartbeat acknowledgements nor timeout-triggered reconnect outcomes; a controlled reconnect canary is required.",
			}},
		}},
	}
	open := openquestions.For(decision)
	message := slackui.WithOpenQuestions(
		slackui.Notice("Rivals remains degraded."), "", "", nil,
		open.Unexplained, "", slackui.NewSanitizer(12000),
	)
	blocks, err := json.Marshal(message.Blocks())
	if err != nil {
		t.Fatal(err)
	}
	rendered := string(blocks)
	if !strings.Contains(rendered, "a controlled reconnect canary is required.") {
		t.Fatalf("rendered caveat lost its actionable ending: %s", rendered)
	}
	if strings.Contains(rendered, "acknowledgements no\"") {
		t.Fatalf("rendered caveat kept the production fragment: %s", rendered)
	}

	long := decision
	longFinding := long.Findings[0]
	longFinding.Alternatives = []investigation.FindingAlternative{{
		NotCheckable: strings.Repeat("bounded evidence remains unavailable ", 40),
	}}
	long.Findings = []investigation.FindingOperation{longFinding}
	bounded := openquestions.For(long).Unexplained[0]
	if !strings.HasSuffix(bounded, "…") {
		t.Fatalf("an over-limit caveat hides its elision: %q", bounded)
	}
}
