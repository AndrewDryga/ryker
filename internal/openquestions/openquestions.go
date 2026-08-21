// Package openquestions reads what a finished answer still does not know out of
// its typed result, so the reply can say so. It is its own package because the
// watch reply and the incident report both render the same line and neither
// owns the rule.
package openquestions

import (
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
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
	seenUnexplained := make(map[string]struct{})
	for _, finding := range decision.Findings {
		if finding.Status == "unexplained" {
			// Stable keys own ledger identity, but historical model output can
			// contain duplicate keys for the exact same failure. Presentation is
			// defense in depth: one uncertainty should occupy one operator-facing
			// context item even before a later correction repairs the ledger.
			identity := strings.ToLower(strings.TrimSpace(finding.What))
			if _, duplicate := seenUnexplained[identity]; duplicate {
				continue
			}
			seenUnexplained[identity] = struct{}{}
			open.Unexplained = append(open.Unexplained, unexplainedLine(finding))
		}
	}
	open.NextCheck = nextCheckFor(decision)
	return open
}

// ForPublicReply removes uncertainty already rendered by a structured alert
// assessment. A scheduled check remains because it is a concrete promise about
// future work, not a second copy of the assessment ledger.
func ForPublicReply(decision decisionpkg.WatchDecision) Questions {
	open := For(decision)
	if decision.AlertAssessment == nil {
		return open
	}
	open.CauseStatus = ""
	open.Cause = ""
	open.MaterialGaps = nil
	open.Unexplained = nil
	return open
}

// unexplainedLine is what the operator reads about a question that is still
// open. Since 2026-08-16 a finding may rest unexplained when one of its
// alternatives says which check would settle it and why that check is not
// available now, so the caveat has to carry both halves: a bare uncertainty
// label beside a decision_ready verdict reads as the host having given up, where
// "... — not checkable now: the Emisar catalog has no Nomad diagnostic" is a
// bounded answer an operator can act on.
func unexplainedLine(finding investigation.FindingOperation) string {
	what := strings.TrimSpace(finding.What)
	for _, alternative := range finding.Alternatives {
		if why := strings.TrimSpace(alternative.NotCheckable); why != "" {
			return boundedDisplayLine(sentence(what)+" "+sentence(why), 480)
		}
	}
	return what
}

func sentence(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value[len(value)-1:], ".!?") {
		return value
	}
	return value + "."
}

// boundedDisplayLine preserves a complete caveat whenever Slack can carry it,
// and makes shortening visible when it cannot. The former 200-byte cut removed
// the actionable end of a 282-byte explanation even though its context element
// had room; core.TruncateUTF8 then left the reader with a sentence ending in
// the middle of "not".
func boundedDisplayLine(value string, limit int) string {
	value = strings.TrimSpace(value)
	if len(value) <= limit {
		return value
	}
	const suffix = "…"
	short := core.TruncateUTF8(value, limit-len(suffix))
	if boundary := strings.LastIndexAny(short, " \t\n"); boundary > 0 {
		short = strings.TrimSpace(short[:boundary])
	}
	return short + suffix
}

// nextCheckFor names the thing that will answer the open question, in the order
// the host trusts: what it actually scheduled, then the model's freeform next
// action, then the host's own recheck. Empty is an honest answer — it means nothing will
// answer it, which is exactly what decision.BoundedCauseCorrection refuses.
func nextCheckFor(decision decisionpkg.WatchDecision) string {
	for _, operation := range decision.AppliedOperations {
		if operation.Type != "wait_external" || operation.ExternalWait == nil ||
			operation.ExternalWait.Kind != scheduledVerificationWait {
			continue
		}
		// A scheduled check is a promise about an observable result, not merely
		// an alarm clock. The 0754fcb5 rollout said only "scheduled follow-up at
		// 19:25 UTC" even though the work it owed was verifying eight services.
		verification := strings.TrimSpace(operation.ExternalWait.Verification)
		if at, err := time.Parse(time.RFC3339, operation.ExternalWait.PollAfter); err == nil {
			if verification != "" {
				return verificationCheck(verification) + " at " + at.UTC().Format("15:04") + " UTC"
			}
			return "scheduled follow-up at " + at.UTC().Format("15:04") + " UTC"
		}
		if verification != "" {
			return verificationCheck(verification)
		}
		return "scheduled follow-up"
	}
	if decision.Completion != nil {
		if next := strings.TrimSpace(decision.Completion.NextAction); next != "" {
			return next
		}
	}
	if decision.Completion != nil && decision.Completion.Recheck != nil {
		return "recheck scheduled"
	}
	return ""
}

func verificationCheck(value string) string {
	words := strings.Fields(strings.TrimSpace(value))
	if len(words) == 0 {
		return "verify"
	}
	switch strings.ToLower(strings.TrimRight(words[0], ":")) {
	case "verify", "check", "confirm":
		words = words[1:]
	}
	if len(words) == 0 {
		return "verify"
	}
	return "verify " + lowerFirst(strings.Join(words, " "))
}

func lowerFirst(value string) string {
	if value == "" {
		return ""
	}
	first := []rune(value)
	first[0] = []rune(strings.ToLower(string(first[0])))[0]
	return string(first)
}
