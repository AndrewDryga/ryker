// Package sourcecausepolicy keeps an unresolved application or dependency
// investigation on its owning source path until it is checked or blocked.
package sourcecausepolicy

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/evidencepolicy"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func Correction(
	assessment *investigation.AlertAssessment,
	evidence []core.Evidence,
	requireSource bool,
) string {
	if correction := evidencepolicy.AlertCauseCorrection(assessment, evidence); correction != "" {
		return correction
	}
	if !requireSource || assessment == nil || assessment.CauseStatus != "bounded" ||
		(assessment.Verdict != "confirmed_issue" && assessment.Verdict != "likely_issue") {
		return ""
	}
	for _, claimID := range assessment.CauseClaimIDs {
		switch claimID {
		case "application.functional_behavior", "dependency.current_health":
		default:
			continue
		}
		if hasRepositoryEvidence(evidence, claimID) {
			continue
		}
		return "the bounded application or dependency cause still has an unexplored source " +
			"repository path for " + claimID + "; inspect the owning configured source and " +
			"record what it establishes, or return the exact repository access or ownership blocker"
	}
	return ""
}

func hasRepositoryEvidence(evidence []core.Evidence, claimID string) bool {
	for _, item := range evidence {
		if item.ClaimID != claimID ||
			!strings.EqualFold(strings.TrimSpace(item.SourceType), "repository") {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(item.Relation)) {
		case "supports", "contradicts":
			return true
		}
	}
	return false
}
