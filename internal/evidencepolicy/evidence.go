// Package evidencepolicy owns the bounded evidence vocabularies.
package evidencepolicy

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func ValidHealthEffect(value string) bool {
	switch value {
	case "none", "risk", "degraded", "unhealthy", "unknown":
		return true
	default:
		return false
	}
}

func ValidSourceType(value string) bool {
	switch value {
	case "repository", "emisar", "monitoring", "slack", "other":
		return true
	default:
		return false
	}
}

func ValidConfidence(value string) bool {
	switch value {
	case "", "high", "medium", "low":
		return true
	default:
		return false
	}
}

// AlertCauseCorrection enforces the strongest structural causal boundary the
// host can prove without pretending to understand prose: every asserted cause
// names typed claims, every cited evidence row belongs to one of those claims,
// and every named claim has a cited observation. A contradiction can be valid
// evidence (for example, a healthy-state claim contradicted by a live probe),
// so relation alone is intentionally not treated as support or refutation.
// AlertCauseCorrection binds an asserted cause to the evidence behind it.
//
// Gated on the assertion rather than on the verdict. It used to run only for a
// confirmed or likely issue, so a recovered alert could name a root cause —
// "the leak in the new revision, now resolved" — with nothing tying it to
// anything observed, and say so in the channel. A claim about why something
// broke needs the same support whether or not it is still broken; the operator
// acts on the cause either way.
func AlertCauseCorrection(assessment *investigation.AlertAssessment, evidence []core.Evidence) string {
	if assessment == nil {
		return ""
	}
	active := assessment.Verdict == "confirmed_issue" || assessment.Verdict == "likely_issue"
	status := strings.ToLower(strings.TrimSpace(assessment.CauseStatus))
	asserted := strings.TrimSpace(assessment.Cause) != "" &&
		(status == "identified" || status == "bounded")
	if !active && !asserted {
		return ""
	}
	if len(assessment.CauseClaimIDs) == 0 || len(assessment.EvidenceRefs) == 0 {
		return "this assessment assigns a cause without cause_claim_ids and evidence_refs; bind the cause to exact recorded claims and evidence operation ids, or leave cause_status unverified"
	}
	claims := make(map[string]bool, len(assessment.CauseClaimIDs))
	covered := make(map[string]bool, len(assessment.CauseClaimIDs))
	for _, claimID := range assessment.CauseClaimIDs {
		claims[claimID] = true
	}
	byID := make(map[string]core.Evidence, len(evidence))
	for _, item := range evidence {
		if item.ID != "" {
			byID[item.ID] = item
		}
	}
	for _, ref := range assessment.EvidenceRefs {
		item, ok := byID[ref]
		if !ok || !claims[item.ClaimID] ||
			(strings.TrimSpace(item.Claim) == "" && strings.TrimSpace(item.Observation) == "") {
			return "the active issue cites absent or unrelated cause evidence; use exact evidence ids whose claim_id is named in cause_claim_ids"
		}
		covered[item.ClaimID] = true
	}
	for claimID := range claims {
		if !covered[claimID] {
			return "the active issue names a causal claim without cited evidence; cite at least one exact evidence id for every cause_claim_id"
		}
	}
	return ""
}
