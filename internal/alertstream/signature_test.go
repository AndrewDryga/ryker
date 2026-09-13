package alertstream

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

// streamCard is the Grafana card these decisions were produced from, held
// constant so a test that means to move the decision moves nothing else.
const streamCard = "[VA1 FIRING:2] WARNING | Alloc resident memory near limit"

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
	if !SignatureOf(first, streamCard).Equal(SignatureOf(second, streamCard)) {
		t.Fatalf(
			"rewording changed the decision:\n%+v\n%+v",
			SignatureOf(first, streamCard), SignatureOf(second, streamCard),
		)
	}
}

// And the things that ARE the decision each move it, one at a time, because a
// comparator that ignores prose is only safe if it misses nothing else.
func TestEachPartOfTheDecisionChangesTheSignature(t *testing.T) {
	base := SignatureOf(confirmed(), streamCard)
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
			d.TaskTitle, d.TaskRepository = "Raise the cap", "blitz-infra"
		},
	} {
		t.Run(name, func(t *testing.T) {
			changed := confirmed()
			mutate(&changed)
			signature := SignatureOf(changed, streamCard)
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

// A Grafana card carries its own count in its title — "[VA1 FIRING:3] WARNING |
// Alloc resident memory near limit", and "[VA1 FIRING:3, RESOLVED:1] …" once
// part of the group has come back — and that number is material.
//
// A Grafana card going FIRING:2 to FIRING:3 was silent under the 2026-08-16 flap
// comparator; the operator decided the count is the fact they are watching, at
// the cost of about three extra posts on that day's stream.
func TestTheFiringCountIsPartOfTheDecision(t *testing.T) {
	const twoOverTheLine = "[VA1 FIRING:2] WARNING | Alloc resident memory near limit"
	const threeOverTheLine = "[VA1 FIRING:3] WARNING | Alloc resident memory near limit"
	first := SignatureOf(confirmed(), twoOverTheLine)
	second := SignatureOf(confirmed(), threeOverTheLine)
	if first.Equal(second) {
		t.Fatalf(
			"a third allocation over the line read as the same card:\n%+v\n%+v",
			first, second,
		)
	}
	// And the trace names the count, because the first question about a post is
	// always what moved.
	detail := second.Change(first)
	if !strings.Contains(detail, "firing 2") || !strings.Contains(detail, "3") {
		t.Fatalf("the trace does not name the count that moved: %q", detail)
	}
	// The same card is still the same decision. This widens what counts as news;
	// it does not stop the comparator firing.
	if repeat := SignatureOf(confirmed(), twoOverTheLine); !repeat.Equal(first) {
		t.Fatalf("the same card compared unequal with itself:\n%+v\n%+v", first, repeat)
	}
}

// And a stream whose cards carry no count compares exactly as it did before.
//
// A Terraform run notification and a Better Stack alert have no bracketed
// marker at all, so both sides parse as 0, and 0 to 0 is not news. A parser that
// guessed here would turn every non-Grafana repeat into a post.
func TestACardWithNoFiringMarkerIsUnaffected(t *testing.T) {
	const card = "Run notification for SME-Blitz/blitz-infra\nStatus: errored"
	first := SignatureOf(confirmed(), card)
	second := SignatureOf(confirmed(), card)
	if !first.Equal(second) {
		t.Fatalf("a card carrying no count read as changed:\n%+v\n%+v", first, second)
	}
	if detail := second.Change(first); detail != "nothing in the typed decision moved" {
		t.Fatalf("a card carrying no count invented a change: %q", detail)
	}
}

// The count comes from the card's own bracketed marker and from nowhere else.
//
// All 21 marker-carrying cards on the blitz deployment carry it in the title,
// inside the Slack link label, on the first line. The body of that same card
// then says "*FIRING - 2 alerts*" in a shape this must not read, and a Terraform
// notification carries no marker at all.
func TestAlertCountsReadsOnlyTheCardsBracketedMarker(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		text     string
		firing   int
		resolved int
	}{
		{"one alert firing", "[VA1 FIRING:1] WARNING | Alloc resident memory near limit", 1, 0},
		{
			"some firing and one back",
			"[VA1 FIRING:3, RESOLVED:1] WARNING | Alloc resident memory near limit", 3, 1,
		},
		{"a recovery", "[VA1 RESOLVED:2] WARNING | Alloc resident memory near limit", 0, 2},
		{"a card with no marker", "Run notification for SME-Blitz/blitz-infra", 0, 0},
		{
			"a marker in lower case",
			"[va1 firing:4] warning | alloc resident memory near limit", 4, 0,
		},
		{
			"prose about firing under a title with no marker",
			"CRITICAL alert: checkout error rate is firing above 20 percent.\n" +
				"The [VA1 FIRING:9] quoted from an earlier card is not this card's count.",
			0, 0,
		},
		{
			"the card that actually arrives",
			"<https://grafana.example/alerting/grafana/va1-nomad-oom-risk/view?orgId=1|" +
				"[VA1 FIRING:2, RESOLVED:1] WARNING | Alloc resident memory near limit>\n" +
				"*FIRING - 2 alerts*\n*traefik/traefik resident memory and swap exceed 95%*",
			2, 1,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			firing, resolved := AlertCounts(testCase.text)
			if firing != testCase.firing || resolved != testCase.resolved {
				t.Fatalf(
					"AlertCounts(%q) = %d firing, %d resolved; want %d, %d",
					testCase.text, firing, resolved, testCase.firing, testCase.resolved,
				)
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
