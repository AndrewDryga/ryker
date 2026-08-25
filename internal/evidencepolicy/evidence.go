// Package evidencepolicy owns the bounded evidence vocabularies.
package evidencepolicy

import (
	"strconv"
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

func HasSource(evidence []core.Evidence, sourceType string) bool {
	for _, item := range evidence {
		if item.SourceType == sourceType {
			return true
		}
	}
	return false
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
	// Which field is empty, rather than both: an assessment that named its
	// claims and cited nothing was told to name its claims.
	if len(assessment.CauseClaimIDs) == 0 || len(assessment.EvidenceRefs) == 0 {
		if len(assessment.CauseClaimIDs) == 0 && len(assessment.EvidenceRefs) == 0 {
			return "this assessment assigns a cause with both cause_claim_ids and evidence_refs empty; name the recorded claim ids the cause rests on, cite one exact evidence id for each of them, or leave cause_status unverified"
		}
		if len(assessment.EvidenceRefs) == 0 {
			return "this assessment assigns a cause to " + namedIDs(assessment.CauseClaimIDs) + " with evidence_refs empty; cite at least one exact evidence id recorded against each of those claims, or leave cause_status unverified"
		}
		return "this assessment assigns a cause citing " + namedIDs(assessment.EvidenceRefs) + " with cause_claim_ids empty; name in cause_claim_ids the claim_id each of those records carries, or leave cause_status unverified"
	}
	claims := make(map[string]bool, len(assessment.CauseClaimIDs))
	covered := make(map[string]bool, len(assessment.CauseClaimIDs))
	for _, claimID := range assessment.CauseClaimIDs {
		claims[claimID] = true
	}
	byID := make(map[string]core.Evidence, len(evidence))
	recorded := make([]string, 0, len(evidence))
	byClaim := make(map[string][]string, len(evidence))
	for _, item := range evidence {
		if item.ID != "" {
			byID[item.ID] = item
			recorded = append(recorded, item.ID)
			byClaim[item.ClaimID] = append(byClaim[item.ClaimID], item.ID)
		}
	}
	// Hoisted so the unresolved-reference message below can always offer a real
	// list. Every reference misses when the ledger is empty, and "cite one of
	// these instead" with nothing after it is the blindness this rule had.
	if len(byID) == 0 {
		return "evidence_refs names " + namedIDs(assessment.EvidenceRefs) + " and this episode has no recorded evidence at all; record each observation with a record_evidence operation, then cite the ids those operations carry"
	}
	for _, ref := range assessment.EvidenceRefs {
		item, ok := byID[ref]
		switch {
		case !ok:
			// Usually a renamed or misremembered id, so the answer the model
			// needs is the list of ids that do exist.
			return "evidence_refs names " + namedIDs([]string{ref}) + ", which is not a recorded evidence id; the ids on record are " + namedIDs(recorded) + " — cite one of those, or record that observation as evidence before citing it"
		case !claims[item.ClaimID]:
			// Two ways out, and they are not the same repair: cite a record
			// already bound to a named claim, or admit this claim into the
			// cause. The model cannot choose without being told both.
			return "evidence_refs names " + namedIDs([]string{ref}) + ", whose claim_id is " + namedIDs([]string{item.ClaimID}) + ", and cause_claim_ids names " + namedIDs(assessment.CauseClaimIDs) + "; cite an evidence id whose claim_id is already in cause_claim_ids, or add " + namedIDs([]string{item.ClaimID}) + " to cause_claim_ids if that claim really is part of the cause"
		case strings.TrimSpace(item.Claim) == "" && strings.TrimSpace(item.Observation) == "":
			return "evidence_refs names " + namedIDs([]string{ref}) + ", which carries neither a claim nor an observation; cite an evidence id that records what was actually observed, or re-record that evidence with its observation"
		}
		covered[item.ClaimID] = true
	}
	// Over the assessment's own order rather than the claims map, so the same
	// unbound claim is named the same way twice running.
	for _, claimID := range assessment.CauseClaimIDs {
		if covered[claimID] {
			continue
		}
		if available := namedIDs(byClaim[claimID]); available != "" {
			return "cause_claim_ids names " + namedIDs([]string{claimID}) + " with no evidence_ref citing it; cite one of the evidence ids recorded against that claim — " + available + " — or drop it from cause_claim_ids"
		}
		return "cause_claim_ids names " + namedIDs([]string{claimID}) + " and no recorded evidence carries that claim_id; record the observation that establishes the claim and cite it, or drop the claim from cause_claim_ids"
	}
	return ""
}

// CauseBoundaryCorrection refuses an active issue whose cause_status claims a
// boundary the cause sentence never states.
//
// It reads back the verdict and the cause_status because those are what the
// model believes it already supplied: "the active issue has no actionable cause
// boundary" was the whole message until 2026-08-16, and a model that had just
// written cause_status: bounded has no way to tell from it which of the two
// fields the host was looking at.
func CauseBoundaryCorrection(assessment *investigation.AlertAssessment) string {
	return "this assessment reports verdict " + named(assessment.Verdict) +
		" with cause_status " + named(assessment.CauseStatus) +
		" and cause empty; state in cause the component that is failing and the " +
		"change or condition that made it fail, or set cause_status to unverified " +
		"and continue the diagnosis"
}

// VerificationPlanCorrection refuses a mitigation nobody can check.
//
// The immediate_action is quoted back because it is the thing the missing plan
// would verify, and because an assessment that has one and not the other is a
// step from finished rather than a rewrite.
func VerificationPlanCorrection(assessment *investigation.AlertAssessment) string {
	action := "immediate_action empty"
	if trimmed := strings.TrimSpace(assessment.ImmediateAction); trimmed != "" {
		action = "immediate_action " + named(trimmed)
	}
	return "this assessment reports verdict " + named(assessment.Verdict) +
		" and " + action + " with verification empty; state in verification the " +
		"exact check that would show that mitigation worked — the signal, the " +
		"threshold, and the window — or return an exact external blocker"
}

// named renders one model-supplied field into a correction, bounded and quoted
// so a runaway value cannot become the whole message.
func named(value string) string {
	if value = core.BoundedText(strings.TrimSpace(value), 200); value == "" {
		return "empty"
	}
	return strconv.Quote(value)
}

// maximumNamedIDs bounds how many ids one correction reads back. Eight matches
// the cap decision.BoundedUniqueFields already puts on cause_claim_ids, and is
// past every recorded alert episode's evidence count; a longer list stops being
// a menu the model can choose from.
const maximumNamedIDs = 8

// namedIDs renders model-supplied ids into a correction. Every id is bounded
// individually — they are model text like any other, and 120 bytes is the same
// bound the decision layer applies when it stores them — the list is capped,
// and what it dropped is counted rather than silently lost.
func namedIDs(ids []string) string {
	shown := make([]string, 0, maximumNamedIDs)
	kept := 0
	for _, id := range ids {
		if id = core.BoundedText(id, 120); id == "" {
			continue
		}
		kept++
		if len(shown) < maximumNamedIDs {
			shown = append(shown, id)
		}
	}
	list := strings.Join(shown, ", ")
	if kept > len(shown) {
		list += " and " + strconv.Itoa(kept-len(shown)) + " more"
	}
	return list
}
