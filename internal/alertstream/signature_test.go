package alertstream

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func confirmed() decisionpkg.WatchDecision {
	return decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "**Traefik memory is near its cap:** all five allocations are over 95 percent.",
		Reason:  "live memory readings agree with the alert",
		AlertAssessment: &decisionpkg.AlertAssessment{
			Verdict: "confirmed_issue", CauseStatus: "identified",
			Impact:          "All five allocations sit within 200 MiB of the 4 GiB cap.",
			ImmediateAction: "Raise the memory cap and roll the job.",
		},
		Coverage: []core.Coverage{
			{Layer: "change", Status: "healthy"},
			{Layer: "application", Status: "degraded"},
			{Layer: "slo", Status: "degraded"},
		},
		Findings: []investigation.FindingOperation{{What: "memory near cap", Status: "explained"}},
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "degraded",
			Summary: "The memory alert is a confirmed live problem with a bounded remediation.",
		},
	}
}

// Five replies on 2026-08-16 differed in every sentence and in nothing that
// mattered: the same verdict, the same unwell layers, the same finding, the
// same recommended change described three different ways. A comparator that
// reads any of that prose is a comparator that never fires.
func TestARewordedAlertReplyIsTheSameDecision(t *testing.T) {
	first := confirmed()
	second := confirmed()
	second.Message = "**Traefik is still close to the cap.** Nothing has moved since the last check."
	second.Reason = "the same readings, taken again"
	second.AlertAssessment.Impact = "Every allocation is still crowding the 4 GiB ceiling."
	second.AlertAssessment.Cause = "The job's allocation ceiling is lower than its working set."
	second.AlertAssessment.ImmediateAction = "Lift the ceiling and redeploy."
	// The order of the coverage rows is an artifact of how the turn happened to
	// report them, not a decision anybody made.
	second.Coverage = []core.Coverage{
		{Layer: "slo", Status: "degraded"},
		{Layer: "application", Status: "degraded"},
		{Layer: "change", Status: "healthy"},
	}
	if !SignatureOf(first).Equal(SignatureOf(second)) {
		t.Fatalf(
			"rewording changed the decision:\n%+v\n%+v",
			SignatureOf(first), SignatureOf(second),
		)
	}
}

// And the things that ARE the decision each move it, one at a time, because a
// comparator that ignores prose is only safe if it misses nothing else.
func TestEachPartOfTheDecisionChangesTheSignature(t *testing.T) {
	base := SignatureOf(confirmed())
	for name, mutate := range map[string]func(*decisionpkg.WatchDecision){
		"verdict": func(d *decisionpkg.WatchDecision) {
			d.AlertAssessment.Verdict = "not_issue"
		},
		"cause status": func(d *decisionpkg.WatchDecision) {
			d.AlertAssessment.CauseStatus = "bounded"
		},
		"completion status": func(d *decisionpkg.WatchDecision) {
			d.Completion.Status = "blocked"
		},
		"completion verdict": func(d *decisionpkg.WatchDecision) {
			d.Completion.Verdict = "unhealthy"
		},
		"a layer that went unwell": func(d *decisionpkg.WatchDecision) {
			d.Coverage[0].Status = "unhealthy"
		},
		"a finding nobody explained": func(d *decisionpkg.WatchDecision) {
			d.Findings[0].Status = "unexplained"
		},
		"an engineering offer": func(d *decisionpkg.WatchDecision) {
			d.TaskTitle, d.TaskRepository = "Raise the cap", "tenant-infra"
		},
	} {
		t.Run(name, func(t *testing.T) {
			changed := confirmed()
			mutate(&changed)
			signature := SignatureOf(changed)
			if base.Equal(signature) {
				t.Fatalf("%s did not change the decision: %+v", name, signature)
			}
			// And the trace says which part moved, in words an operator asking
			// "compared with what" can read.
			if detail := signature.Change(base); detail == "" ||
				detail == "nothing in the typed decision moved" {
				t.Fatalf("%s produced no explanation: %q", name, detail)
			}
		})
	}
}

// A stream with no answer behind it is briefed as a first card, because a
// stream's first card is exactly when silence is not allowed.
func TestAnsweredPromptIsSilentUntilSomethingWasPosted(t *testing.T) {
	if section := AnsweredPrompt(decisionpkg.WatchTurnState{}); section != "" {
		t.Fatalf("an unanswered stream was told it had been answered: %q", section)
	}
	section := AnsweredPrompt(decisionpkg.WatchTurnState{
		StreamAnsweredAt:      "2026-08-16T14:51:00Z",
		StreamAnsweredVerdict: "confirmed_issue",
		StreamAnsweredAction:  "Raise the memory cap and roll the job.",
	})
	for _, want := range []string{
		"<host-stream-answered>", "2026-08-16T14:51:00Z", "confirmed_issue",
		"Raise the memory cap and roll the job.", "return ignore",
	} {
		if !strings.Contains(section, want) {
			t.Fatalf("the answered-stream section omits %q:\n%s", want, section)
		}
	}
}
