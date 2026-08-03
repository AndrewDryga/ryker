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
	Contract Contract             `json:"contract"`
	Claims   map[string]ClaimView `json:"claims"`
}

func BuildLedger(contract Contract, evidence []core.Evidence, coverage []core.Coverage, now time.Time) Ledger {
	ledger := Ledger{Contract: contract, Claims: make(map[string]ClaimView, len(contract.Claims))}
	byLayer := make(map[string]core.Coverage, len(coverage))
	for _, item := range coverage {
		byLayer[item.Layer] = item
	}
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
			if item.ClaimID != requirement.ID && !contains(coverageItem.ClaimIDs, item.ClaimID) {
				continue
			}
			stale := requirement.Freshness.MaxAge > 0 &&
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
			view, coverageItem, covered, contract.Completion.AllowUnknownSLO,
		)
		ledger.Claims[requirement.ID] = view
	}
	return ledger
}

func (ledger Ledger) CompletionCorrection(status string) string {
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
					detail += "missing dimensions: " + strings.Join(view.MissingDimensions, ", ")
				}
				missing = append(missing, requirement.ID+" ("+detail+")")
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
		sort.Strings(contradicted)
		return "required claims still contain unresolved contradictions: " + strings.Join(contradicted, ", ")
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return "required claims do not have fresh supporting evidence: " + strings.Join(missing, ", ")
	}
	return ""
}

func claimResolution(
	view ClaimView,
	coverage core.Coverage,
	covered bool,
	allowUnknownSLO bool,
) bool {
	if !covered || strings.TrimSpace(coverage.Detail) == "" {
		return false
	}
	switch view.State {
	case ClaimSupported:
		return coverage.Status == "healthy"
	case ClaimContradicted, ClaimMixed:
		return coverage.Status == "degraded" || coverage.Status == "unhealthy"
	case ClaimUnknown:
		return allowUnknownSLO && view.Requirement.Layer == "slo" &&
			view.Requirement.Required && coverage.Status == "unknown"
	case ClaimNotApplicable:
		return coverage.Status == "not_applicable"
	default:
		return false
	}
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
