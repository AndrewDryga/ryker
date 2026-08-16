// Package openquestions reads what a finished answer still does not know out of
// its typed result, so the reply can say so. It is its own package because the
// watch reply and the incident report both render the same line and neither
// owns the rule.
package openquestions

import (
	"strings"
	"time"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// Questions is what a finished answer still does not know, read out of the
// typed result rather than out of its prose.
//
// Every field here was already recorded on 2026-08-16 and none of it was
// rendered: cause_status "bounded", a material gap saying the load-versus-leak
// split "is unresolved", and a long_term_solution asking for a heap profile. The
// reply said "raise the cap and roll the job".
type Questions struct {
	CauseStatus  string
	Cause        string
	MaterialGaps []string
	Unexplained  []string
	NextCheck    string
}

// scheduledVerificationWait is the wait_external kind the prompt asks for when a
// reported fix has to be checked later. It is the shape a bounded cause should
// leave behind, so it is also the one the reply names.
const scheduledVerificationWait = "scheduled_verification"

// For reads them off a decision. It lives beside the decision rather than in
// the service so the watch reply and the incident report render the
// same line from the same rules; the incident report carries no alert
// assessment, and an absent one simply leaves the cause fields empty.
func For(decision decisionpkg.WatchDecision) Questions {
	open := Questions{}
	// A blocked completion already renders its gaps and its next action through
	// WithBlockedAssessment. A second line beside it would repeat the next step
	// under a different word, and a caveat an operator has learned to skip is
	// worth less than no caveat at all.
	if decision.Completion != nil && decision.Completion.Status == "blocked" {
		return open
	}
	// A verdict that found no issue has no cause to qualify, and "cause bounded"
	// under "nothing is wrong" is a contradiction the operator has to resolve.
	if assessment := decision.AlertAssessment; assessment != nil &&
		(assessment.Verdict == "confirmed_issue" || assessment.Verdict == "likely_issue") {
		open.CauseStatus = strings.ToLower(strings.TrimSpace(assessment.CauseStatus))
		open.Cause = assessment.Cause
	}
	// Only for a decision_ready completion: a blocked one already renders its own
	// gaps and next action through WithBlockedAssessment, and saying it twice is
	// how a caveat becomes wallpaper.
	if decision.Completion != nil && decision.Completion.Status == "decision_ready" {
		open.MaterialGaps = decision.Completion.MaterialGaps
	}
	for _, finding := range decision.Findings {
		if finding.Status == "unexplained" {
			open.Unexplained = append(open.Unexplained, finding.What)
		}
	}
	open.NextCheck = nextCheckFor(decision)
	return open
}

// nextCheckFor names the thing that will answer the open question, in the order
// the host trusts: what the model wrote down, then what it actually scheduled,
// then the host's own recheck. Empty is an honest answer — it means nothing will
// answer it, which is exactly what decision.BoundedCauseCorrection refuses.
func nextCheckFor(decision decisionpkg.WatchDecision) string {
	if decision.Completion != nil {
		if next := strings.TrimSpace(decision.Completion.NextAction); next != "" {
			return next
		}
	}
	for _, operation := range decision.AppliedOperations {
		if operation.Type != "wait_external" || operation.ExternalWait == nil ||
			operation.ExternalWait.Kind != scheduledVerificationWait {
			continue
		}
		// The wake time, not the raw RFC3339 stamp: this is a sentence an
		// operator reads in Slack, and "at 2026-08-16T16:30:00Z" is not one.
		if at, err := time.Parse(time.RFC3339, operation.ExternalWait.PollAfter); err == nil {
			return "scheduled follow-up at " + at.UTC().Format("15:04") + " UTC"
		}
		return "scheduled follow-up"
	}
	if decision.Completion != nil && decision.Completion.Recheck != nil {
		return "recheck scheduled"
	}
	return ""
}
