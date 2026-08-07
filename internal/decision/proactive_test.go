package decision

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func eligibleInputs(t *testing.T) (
	core.StandingAssignment, core.SlackInput, *investigation.CompletionAssessment, []core.Evidence,
) {
	t.Helper()
	assignment := core.StandingAssignment{
		ChannelID: "CALERTS", SignalPattern: "payments timeout",
		Repository: "payments-api", ChangeClass: "observability",
		DailyBudget: 3, ActorID: "UOPERATOR", Enabled: true,
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}
	input := core.SlackInput{
		Kind: "bot_message", ChannelID: "CALERTS",
		Text: "FIRING: payments API timeout rate above threshold",
	}
	completion := &investigation.CompletionAssessment{
		Status: "decision_ready", Summary: "timeouts trace to a missing client deadline",
		Verdict: "unhealthy",
	}
	evidence := []core.Evidence{{SourceType: "emisar", Claim: "timeout rate is 8%"}}
	return assignment, input, completion, evidence
}

// Every refusal here is a way this feature turns from useful into something
// people mute. They are worth stating one at a time.
func TestProactiveActsOnlyWhenEveryGuardAgrees(t *testing.T) {
	now := time.Now().UTC()
	assignment, input, completion, evidence := eligibleInputs(t)

	if got := ProactiveEligible(assignment, input, 5, completion, evidence, now); !got.Eligible {
		t.Fatalf("a recurring, in-scope, evidence-backed signal was refused: %s", got.Reason)
	}

	for _, testCase := range []struct {
		name   string
		mutate func(*core.StandingAssignment, *core.SlackInput, **investigation.CompletionAssessment, *[]core.Evidence, *int)
		reason string
	}{
		{
			name: "a paused assignment does nothing",
			mutate: func(a *core.StandingAssignment, _ *core.SlackInput, _ **investigation.CompletionAssessment, _ *[]core.Evidence, _ *int) {
				a.Enabled = false
			},
			reason: "paused",
		},
		{
			name: "an expired assignment does nothing",
			mutate: func(a *core.StandingAssignment, _ *core.SlackInput, _ **investigation.CompletionAssessment, _ *[]core.Evidence, _ *int) {
				a.ExpiresAt = time.Now().UTC().Add(-time.Hour)
			},
			reason: "expired",
		},
		{
			name: "a signal in another channel is out of scope",
			mutate: func(_ *core.StandingAssignment, i *core.SlackInput, _ **investigation.CompletionAssessment, _ *[]core.Evidence, _ *int) {
				i.ChannelID = "CELSEWHERE"
			},
			reason: "channel",
		},
		{
			name: "a different problem in the same channel is out of scope",
			mutate: func(_ *core.StandingAssignment, i *core.SlackInput, _ **investigation.CompletionAssessment, _ *[]core.Evidence, _ *int) {
				i.Text = "FIRING: checkout disk usage above threshold"
			},
			reason: "match",
		},
		{
			name: "a first sighting is not a pattern",
			mutate: func(_ *core.StandingAssignment, _ *core.SlackInput, _ **investigation.CompletionAssessment, _ *[]core.Evidence, r *int) {
				*r = 1
			},
			reason: "often enough",
		},
		{
			name: "a blocked investigation must not open a pull request",
			mutate: func(_ *core.StandingAssignment, _ *core.SlackInput, c **investigation.CompletionAssessment, _ *[]core.Evidence, _ *int) {
				(*c).Status = "blocked"
			},
			reason: "decision-ready",
		},
		{
			name: "an investigation with material gaps must not either",
			mutate: func(_ *core.StandingAssignment, _ *core.SlackInput, c **investigation.CompletionAssessment, _ *[]core.Evidence, _ *int) {
				(*c).MaterialGaps = []string{"could not read the deploy history"}
			},
			reason: "material gaps",
		},
		{
			name: "a conclusion with no completion at all",
			mutate: func(_ *core.StandingAssignment, _ *core.SlackInput, c **investigation.CompletionAssessment, _ *[]core.Evidence, _ *int) {
				*c = nil
			},
			reason: "decision-ready",
		},
		{
			name: "repository reads alone do not justify a change",
			mutate: func(_ *core.StandingAssignment, _ *core.SlackInput, _ **investigation.CompletionAssessment, e *[]core.Evidence, _ *int) {
				*e = []core.Evidence{{SourceType: "repository", Claim: "the client sets no deadline"}}
			},
			reason: "evidence",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			a, i, c, e := eligibleInputs(t)
			recurrences := 5
			testCase.mutate(&a, &i, &c, &e, &recurrences)
			got := ProactiveEligible(a, i, recurrences, c, e, now)
			if got.Eligible {
				t.Fatalf("acted when it should not have")
			}
			if got.Reason == "" {
				t.Fatal("refused without saying why; silent inaction is undebuggable")
			}
		})
	}
}

// The pattern is a plain word match, not a regular expression.
//
// Whoever confirms an assignment writes this, and "what does this cover?" has
// to be answerable by reading it. A regex there is both a foot-gun and an
// unreviewable grant.
func TestSignalPatternIsPlainWords(t *testing.T) {
	for _, testCase := range []struct {
		text, pattern string
		match         bool
	}{
		{"FIRING: payments API timeout rate high", "payments timeout", true},
		{"FIRING: PAYMENTS api TIMEOUT", "payments timeout", true},
		{"FIRING: checkout latency", "payments timeout", false},
		{"FIRING: payments deploy finished", "payments timeout", false},
		{"anything at all", "", false},
	} {
		if got := signalMatchesPattern(testCase.text, testCase.pattern); got != testCase.match {
			t.Errorf("match(%q, %q) = %t, want %t",
				testCase.text, testCase.pattern, got, testCase.match)
		}
	}
}
