package decision

import (
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// ProactiveEligibility is why an assignment may or may not act on a signal.
//
// It carries a reason even when the answer is no, because "Responder did
// nothing" is the hardest behaviour to debug: without a stated reason, a
// misconfigured scope and a working system look identical from Slack.
type ProactiveEligibility struct {
	Eligible bool
	Reason   string
}

func ineligible(reason string) ProactiveEligibility {
	return ProactiveEligibility{Reason: reason}
}

// minimumRecurrences is how many times a signal must have been seen before
// Responder will open a pull request about it.
//
// One occurrence is not a pattern. A transient error during a deploy, a
// one-off timeout, an alert that resolved itself — each looks exactly like a
// real problem at the moment it arrives, and only repetition distinguishes
// them. Opening a pull request for the first sighting of anything is how a
// proactive agent becomes something people mute.
const minimumRecurrences = 3

// ProactiveEligible reports whether a standing assignment may act on a signal.
//
// The checks are ordered cheapest-first and every one of them is a way this
// feature could become intolerable rather than useful: acting outside the
// granted scope, acting on noise, or acting on a conclusion Responder could
// not actually support.
func ProactiveEligible(
	assignment core.StandingAssignment,
	input core.SlackInput,
	recurrences int,
	completion *investigation.CompletionAssessment,
	evidence []core.Evidence,
	now time.Time,
) ProactiveEligibility {
	if !assignment.Live(now) {
		return ineligible("the standing assignment is paused or has expired")
	}
	if input.ChannelID != assignment.ChannelID {
		return ineligible("the signal is not in the channel this assignment watches")
	}
	if !signalMatchesPattern(input.Text, assignment.SignalPattern) {
		return ineligible("the signal does not match what this assignment watches for")
	}
	if recurrences < minimumRecurrences {
		return ineligible("this has not happened often enough to be a pattern yet")
	}
	// The completion gate. A pull request asserts that Responder understood the
	// problem; a completion that is blocked, or decision-ready without
	// evidence, asserts the opposite. Opening one anyway spends a reviewer's
	// attention on a guess.
	if completion == nil || completion.Status != "decision_ready" {
		return ineligible("the investigation did not reach a decision-ready conclusion")
	}
	if len(completion.MaterialGaps) > 0 {
		return ineligible("the investigation still has material gaps")
	}
	if !hasSupportingEvidence(evidence) {
		return ineligible("no verified evidence supports the change")
	}
	return ProactiveEligibility{Eligible: true, Reason: "in scope, recurring, and evidence-backed"}
}

// signalMatchesPattern is a deliberately dull substring match over the words an
// operator gave.
//
// It is not a regular expression on purpose. The pattern is written by whoever
// confirms the assignment, and a regex there is both a foot-gun and an
// unreviewable grant — "what does this assignment actually cover?" should be
// answerable by reading it.
func signalMatchesPattern(text, pattern string) bool {
	text = strings.ToLower(text)
	terms := strings.Fields(strings.ToLower(pattern))
	if len(terms) == 0 {
		return false
	}
	for _, term := range terms {
		if !strings.Contains(text, term) {
			return false
		}
	}
	return true
}

// hasSupportingEvidence requires at least one piece of evidence from a source
// that observed the system, rather than only repository or memory reads.
//
// A change justified solely by reading the repository is a change justified by
// what someone intended, not by what is happening.
func hasSupportingEvidence(evidence []core.Evidence) bool {
	for _, item := range evidence {
		switch item.SourceType {
		case "emisar", "monitoring", "github":
			return true
		}
	}
	return false
}
