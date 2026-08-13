package investigation

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

type ClaimState string

const (
	ClaimSupported     ClaimState = "supported"
	ClaimContradicted  ClaimState = "contradicted"
	ClaimMixed         ClaimState = "mixed"
	ClaimUnknown       ClaimState = "unknown"
	ClaimNotApplicable ClaimState = "not_applicable"
)

type ClaimView struct {
	Requirement       ClaimRequirement `json:"requirement"`
	State             ClaimState       `json:"state"`
	Confidence        string           `json:"confidence,omitempty"`
	Evidence          []core.Evidence  `json:"evidence,omitempty"`
	Contradictions    []core.Evidence  `json:"contradictions,omitempty"`
	StaleEvidence     []core.Evidence  `json:"stale_evidence,omitempty"`
	MissingDimensions []string         `json:"missing_dimensions,omitempty"`
	Stale             bool             `json:"stale"`
	Resolved          bool             `json:"resolved"`
	CoverageStatus    string           `json:"coverage_status,omitempty"`
	Detail            string           `json:"detail,omitempty"`
}

type Ledger struct {
	Contract InvestigationContract `json:"contract"`
	Claims   map[string]ClaimView  `json:"claims"`
}

func BuildLedger(contract InvestigationContract, evidence []core.Evidence, coverage []core.Coverage, now time.Time) Ledger {
	ledger := Ledger{Contract: contract, Claims: make(map[string]ClaimView, len(contract.Claims))}
	byLayer := make(map[string]core.Coverage, len(coverage))
	for _, item := range coverage {
		current, ok := byLayer[item.Layer]
		if !ok || observationTime(item.ObservedAt, item.CreatedAt).After(
			observationTime(current.ObservedAt, current.CreatedAt),
		) {
			byLayer[item.Layer] = item
		}
	}
	latestEvidence := latestEvidenceObservationTimes(evidence)
	for _, requirement := range contract.Claims {
		view := ClaimView{Requirement: requirement, State: ClaimUnknown}
		coverageItem, covered := byLayer[requirement.Layer]
		if covered {
			view.CoverageStatus = coverageItem.Status
			view.Detail = coverageItem.Detail
		}
		if covered && coverageItem.Status == "not_applicable" {
			view.State = ClaimNotApplicable
		}
		for _, item := range evidence {
			resolved, resolvable := contract.ResolveClaimID(item.ClaimID)
			if (!resolvable || resolved != requirement.ID) &&
				!contains(coverageItem.ClaimIDs, item.ClaimID) {
				continue
			}
			stale := observationTime(item.ObservedAt, item.CreatedAt).Before(
				latestEvidence[evidenceObservationKey(item)],
			) || requirement.Freshness.MaxAge > 0 &&
				(item.ObservedAt.IsZero() || now.Sub(item.ObservedAt) > requirement.Freshness.MaxAge)
			stale = stale || (!item.ValidUntil.IsZero() && now.After(item.ValidUntil))
			if stale {
				view.StaleEvidence = append(view.StaleEvidence, item)
				continue
			}
			relation := strings.ToLower(strings.TrimSpace(item.Relation))
			if relation == "contradicts" || relation == "contradiction" {
				view.Contradictions = append(view.Contradictions, item)
			} else {
				view.Evidence = append(view.Evidence, item)
			}
		}
		view.Stale = len(view.StaleEvidence) > 0 &&
			len(view.Evidence) == 0 && len(view.Contradictions) == 0
		for _, dimension := range requirement.Dimensions {
			if !dimensionPresent(view.Evidence, dimension) && !dimensionPresent(view.Contradictions, dimension) {
				view.MissingDimensions = append(view.MissingDimensions, dimension)
			}
		}
		if view.State != ClaimNotApplicable {
			switch {
			case len(view.Evidence) > 0 && len(view.Contradictions) > 0:
				view.State = ClaimMixed
			case len(view.Contradictions) > 0:
				view.State = ClaimContradicted
			case len(view.Evidence) > 0:
				view.State = ClaimSupported
			}
		}
		view.Confidence = weakestConfidence(append(append([]core.Evidence{}, view.Evidence...), view.Contradictions...))
		view.Resolved = claimResolution(
			view, coverageItem, covered, contract.Completion,
		)
		ledger.Claims[requirement.ID] = view
	}
	return ledger
}

func latestEvidenceObservationTimes(items []core.Evidence) map[string]time.Time {
	latest := make(map[string]time.Time, len(items))
	for _, item := range items {
		key := evidenceObservationKey(item)
		observed := observationTime(item.ObservedAt, item.CreatedAt)
		if current, ok := latest[key]; !ok || observed.After(current) {
			latest[key] = observed
		}
	}
	return latest
}

func evidenceObservationKey(item core.Evidence) string {
	dimensionKeys := make([]string, 0, len(item.Dimensions))
	for key := range item.Dimensions {
		dimensionKeys = append(dimensionKeys, key)
	}
	sort.Strings(dimensionKeys)
	var dimensions strings.Builder
	for _, key := range dimensionKeys {
		dimensions.WriteString("|")
		dimensions.WriteString(key)
		dimensions.WriteString("=")
		dimensions.WriteString(item.Dimensions[key])
	}
	return strings.Join([]string{
		strings.TrimSpace(item.ClaimID),
		strings.TrimSpace(item.Target),
		strings.TrimSpace(item.SourceType),
		strings.TrimSpace(item.SourceID),
		strings.TrimSpace(item.SourceName),
		dimensions.String(),
	}, "\x00")
}

func observationTime(observedAt, createdAt time.Time) time.Time {
	if !observedAt.IsZero() {
		return observedAt
	}
	return createdAt
}

func (ledger Ledger) CompletionCorrection(status string) string {
	return ledger.CompletionCorrectionFor(status, "")
}

func (ledger Ledger) CompletionCorrectionFor(status, verdict string) string {
	if status == "blocked" {
		return ""
	}
	missing := make([]string, 0)
	contradicted := make([]string, 0)
	for _, requirement := range ledger.Contract.Claims {
		if !requirement.Required {
			continue
		}
		view := ledger.Claims[requirement.ID]
		switch view.State {
		case ClaimSupported:
			if view.Stale || len(view.MissingDimensions) > 0 {
				detail := ""
				if view.Stale {
					detail = "stale"
				}
				if len(view.MissingDimensions) > 0 {
					if detail != "" {
						detail += "; "
					}
					// Named as keys of the evidence payload, because "missing
					// dimensions: artifact, revision" was read three corrections
					// running as a remark about scope rather than as the two
					// object keys the host is waiting for.
					detail += "no evidence carries the dimensions keys: " +
						strings.Join(view.MissingDimensions, ", ")
				}
				missing = append(missing, requirement.ID+" ("+detail+")")
			} else if !view.Resolved {
				contradicted = append(contradicted, requirement.ID)
			}
		case ClaimNotApplicable:
			if requirement.Layer != "slo" || !ledger.Contract.Completion.AllowUnknownSLO {
				missing = append(missing, requirement.ID)
			}
		case ClaimUnknown:
			if !view.Resolved {
				detail := requirement.ID
				if view.Stale {
					detail += " (stale)"
				}
				missing = append(missing, detail)
			}
		case ClaimContradicted, ClaimMixed:
			if !view.Resolved {
				contradicted = append(contradicted, requirement.ID)
			}
		}
	}
	if len(contradicted) > 0 {
		if ledger.negativeVerdictIsDecisive(verdict) {
			return ""
		}
		sort.Strings(contradicted)
		return "required claims still contain unresolved contradictions: " + strings.Join(contradicted, ", ")
	}
	if len(missing) > 0 {
		if ledger.negativeVerdictIsDecisive(verdict) {
			return ""
		}
		sort.Strings(missing)
		return "required claims do not have fresh supporting evidence: " + strings.Join(missing, ", ")
	}
	return ""
}

func (ledger Ledger) negativeVerdictIsDecisive(verdict string) bool {
	if ledger.Contract.Completion.ConclusionKind == "change_review" && verdict == "failed" {
		for _, view := range ledger.Claims {
			if !view.Requirement.Required || view.Requirement.Layer != "change" ||
				view.CoverageStatus != "unhealthy" {
				continue
			}
			if len(view.Evidence) > 0 || len(view.Contradictions) > 0 {
				return true
			}
		}
		return false
	}
	if ledger.Contract.Completion.ConclusionKind != "operational_health" ||
		(verdict != "degraded" && verdict != "unhealthy") {
		return false
	}
	for _, view := range ledger.Claims {
		if !view.Requirement.Required || !view.Resolved {
			continue
		}
		if verdict == "unhealthy" && view.CoverageStatus == "unhealthy" {
			return true
		}
		if verdict == "degraded" &&
			(view.CoverageStatus == "degraded" || view.CoverageStatus == "unhealthy") {
			return true
		}
	}
	return false
}

func claimResolution(
	view ClaimView,
	coverage core.Coverage,
	covered bool,
	completion CompletionRule,
) bool {
	if !covered || strings.TrimSpace(coverage.Detail) == "" {
		return false
	}
	switch view.State {
	case ClaimSupported:
		return coverage.Status == "healthy" ||
			(completion.ConclusionKind == "change_review" && coverage.Status == "unknown")
	case ClaimMixed:
		// A contradiction every supporting observation post-dates is history,
		// not a live disagreement, and the claim has recovered rather than
		// stayed in conflict.
		//
		// Correlation-based staleness cannot see this. Its key carries the
		// source id and every dimension value, so evidence about the revision
		// that fixed a problem never supersedes evidence about the revision
		// that caused it — the thing that changed is the thing keeping the two
		// records apart. That left a permanently mixed claim, and a mixed
		// claim could only resolve through a material health effect, which
		// requires a degraded or unhealthy status. A healthy verdict was
		// therefore unreachable: the host asked for the contradiction to be
		// resolved, the model had already recorded the evidence resolving it,
		// and the loop ran until the continuation budget was spent. Forty-four
		// episodes did this, ninety-two turns between them.
		//
		// The guard survives where it earns its keep. A contradiction that is
		// the newest thing known still blocks a healthy verdict, because that
		// is a disagreement about now rather than a record of something fixed.
		if contradictionsPredateSupport(view) {
			return coverage.Status == "healthy" ||
				(completion.ConclusionKind == "change_review" && coverage.Status == "unknown")
		}
		return materialHealthEffectPresent(view, coverage.Status)
	case ClaimContradicted:
		return materialHealthEffectPresent(view, coverage.Status)
	case ClaimUnknown:
		return (completion.AllowUnknownSLO && view.Requirement.Layer == "slo" &&
			view.Requirement.Required && coverage.Status == "unknown") ||
			(completion.ConclusionKind == "factual_assessment" && coverage.Status == "unknown")
	case ClaimNotApplicable:
		return coverage.Status == "not_applicable"
	default:
		return false
	}
}

// contradictionsPredateSupport reports whether every contradiction is strictly
// older than the newest supporting observation.
//
// Strictly, and with an unknown time counting against: a contradiction whose
// observation instant was never recorded cannot be shown to be history, and
// the safe reading of "we do not know when this was seen" is "it may be now".
func contradictionsPredateSupport(view ClaimView) bool {
	if len(view.Evidence) == 0 || len(view.Contradictions) == 0 {
		return false
	}
	var newestSupport time.Time
	for _, item := range view.Evidence {
		if at := observationTime(item.ObservedAt, item.CreatedAt); at.After(newestSupport) {
			newestSupport = at
		}
	}
	if newestSupport.IsZero() {
		return false
	}
	for _, item := range view.Contradictions {
		at := observationTime(item.ObservedAt, item.CreatedAt)
		if at.IsZero() || !at.Before(newestSupport) {
			return false
		}
	}
	return true
}

func materialHealthEffectPresent(view ClaimView, status string) bool {
	if status != "degraded" && status != "unhealthy" {
		return false
	}
	items := append(append([]core.Evidence{}, view.Evidence...), view.Contradictions...)
	for _, item := range items {
		effect := strings.ToLower(strings.TrimSpace(item.HealthEffect))
		if status == "unhealthy" && effect == "unhealthy" {
			return true
		}
		if status == "degraded" && (effect == "degraded" || effect == "unhealthy") {
			return true
		}
	}
	return false
}

func (ledger Ledger) Assessments(episodeID string, now time.Time) []core.ClaimAssessment {
	result := make([]core.ClaimAssessment, 0, len(ledger.Contract.Claims))
	for _, requirement := range ledger.Contract.Claims {
		view := ledger.Claims[requirement.ID]
		assessment := core.ClaimAssessment{
			ID:        "claim_" + episodeID + "_" + strings.ReplaceAll(requirement.ID, ".", "_"),
			EpisodeID: episodeID, ClaimID: requirement.ID, Status: string(view.State),
			Confidence: view.Confidence, Detail: view.Detail, UpdatedAt: now,
		}
		for _, item := range view.Evidence {
			assessment.EvidenceIDs = append(assessment.EvidenceIDs, item.ID)
		}
		for _, item := range view.Contradictions {
			assessment.ContradictionIDs = append(assessment.ContradictionIDs, item.ID)
		}
		result = append(result, assessment)
	}
	return result
}

func ValidateEvidence(item core.Evidence) error {
	if strings.TrimSpace(item.ClaimID) == "" {
		return fmt.Errorf("evidence requires claim_id")
	}
	if strings.TrimSpace(item.SourceType) == "" || strings.TrimSpace(item.SourceName) == "" {
		return fmt.Errorf("evidence requires source_type and source_name")
	}
	if strings.TrimSpace(item.Observation) == "" && len(item.Dimensions) == 0 {
		return fmt.Errorf("evidence requires observation or structured dimensions")
	}
	switch strings.ToLower(strings.TrimSpace(item.Relation)) {
	case "", "supports", "contradicts":
	default:
		return fmt.Errorf("unsupported evidence relation %q", item.Relation)
	}
	switch strings.ToLower(strings.TrimSpace(item.HealthEffect)) {
	case "", "none", "risk", "degraded", "unhealthy", "unknown":
	default:
		return fmt.Errorf("unsupported evidence health_effect %q", item.HealthEffect)
	}
	return nil
}

func contains(values []string, target string) bool {
	if target == "" {
		return false
	}
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func dimensionPresent(items []core.Evidence, dimension string) bool {
	for _, item := range items {
		if strings.TrimSpace(item.Dimensions[dimension]) != "" {
			return true
		}
	}
	return false
}

func weakestConfidence(items []core.Evidence) string {
	if len(items) == 0 {
		return ""
	}
	result := "high"
	for _, item := range items {
		switch strings.ToLower(strings.TrimSpace(item.Confidence)) {
		case "low":
			return "low"
		case "medium", "":
			result = "medium"
		}
	}
	return result
}
