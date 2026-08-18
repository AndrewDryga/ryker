// Package operationalscope owns the machine-readable boundary around an
// operational alert conclusion and the host rendering derived from it.
package operationalscope

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

type Assessment struct {
	Verdict             string   `json:"verdict"`
	Impact              string   `json:"impact"`
	CauseStatus         string   `json:"cause_status,omitempty"`
	Cause               string   `json:"cause,omitempty"`
	CauseClaimIDs       []string `json:"cause_claim_ids,omitempty"`
	EvidenceRefs        []string `json:"evidence_refs,omitempty"`
	ImmediateActionKind string   `json:"immediate_action_kind,omitempty"`
	ImmediateAction     string   `json:"immediate_action,omitempty"`
	Verification        string   `json:"verification,omitempty"`
	LongTermSolution    string   `json:"long_term_solution,omitempty"`
	Scope               *Scope   `json:"scope,omitempty"`
}

type Scope struct {
	Status              string   `json:"status"`
	CheckedTargets      []string `json:"checked_targets"`
	UnverifiedTargets   []string `json:"unverified_targets,omitempty"`
	EvidenceRefs        []string `json:"evidence_refs"`
	UniverseEvidenceRef string   `json:"universe_evidence_ref,omitempty"`
}

// TargetUniverse is host-owned proof of the complete set a scope claims to
// cover. It is deliberately not part of the model result schema: a model may
// cite the evidence record that produced an inventory, but it cannot attest
// that the inventory was complete.
type TargetUniverse struct {
	EvidenceRef string
	Targets     []string
}

// UnmarshalJSON accepts the previously emitted durable_solution alias while
// keeping the canonical assessment strict against unknown model fields.
func (assessment *Assessment) UnmarshalJSON(data []byte) error {
	var value struct {
		Verdict             string   `json:"verdict"`
		Impact              string   `json:"impact"`
		CauseStatus         string   `json:"cause_status,omitempty"`
		Cause               string   `json:"cause,omitempty"`
		CauseClaimIDs       []string `json:"cause_claim_ids,omitempty"`
		ImmediateActionKind string   `json:"immediate_action_kind,omitempty"`
		ImmediateAction     string   `json:"immediate_action,omitempty"`
		Verification        string   `json:"verification,omitempty"`
		LongTermSolution    string   `json:"long_term_solution,omitempty"`
		DurableSolution     string   `json:"durable_solution,omitempty"`
		Alert               string   `json:"alert,omitempty"`
		Component           string   `json:"component,omitempty"`
		State               string   `json:"state,omitempty"`
		EvidenceRefs        []string `json:"evidence_refs,omitempty"`
		Scope               *Scope   `json:"scope,omitempty"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	if value.LongTermSolution == "" {
		value.LongTermSolution = value.DurableSolution
	}
	*assessment = Assessment{
		Verdict: value.Verdict, Impact: value.Impact,
		CauseStatus: value.CauseStatus, Cause: value.Cause,
		CauseClaimIDs: value.CauseClaimIDs, EvidenceRefs: value.EvidenceRefs,
		ImmediateActionKind: value.ImmediateActionKind,
		ImmediateAction:     value.ImmediateAction, Verification: value.Verification,
		LongTermSolution: value.LongTermSolution, Scope: value.Scope,
	}
	return nil
}

func ValidateAssessment(assessment *Assessment) error {
	assessment.Verdict = strings.TrimSpace(assessment.Verdict)
	assessment.Impact = strings.TrimSpace(assessment.Impact)
	assessment.CauseStatus = strings.TrimSpace(assessment.CauseStatus)
	assessment.Cause = strings.TrimSpace(assessment.Cause)
	assessment.CauseClaimIDs = boundedUnique(assessment.CauseClaimIDs, 8, 120)
	assessment.EvidenceRefs = boundedUnique(assessment.EvidenceRefs, 12, 120)
	assessment.ImmediateActionKind = strings.ToLower(strings.TrimSpace(assessment.ImmediateActionKind))
	if assessment.ImmediateActionKind == "" {
		switch assessment.Verdict {
		case "confirmed_issue", "likely_issue":
			assessment.ImmediateActionKind = "mitigation"
		case "not_issue":
			assessment.ImmediateActionKind = "monitor"
		case "unverified":
			assessment.ImmediateActionKind = "investigation"
		}
	}
	assessment.ImmediateAction = strings.TrimSpace(assessment.ImmediateAction)
	assessment.Verification = strings.TrimSpace(assessment.Verification)
	assessment.LongTermSolution = strings.TrimSpace(assessment.LongTermSolution)
	if len(assessment.Verdict) > 32 || len(assessment.Impact) > 2000 ||
		len(assessment.CauseStatus) > 32 || len(assessment.Cause) > 2000 ||
		len(assessment.ImmediateActionKind) > 32 || len(assessment.ImmediateAction) > 2000 ||
		len(assessment.Verification) > 2000 || len(assessment.LongTermSolution) > 2000 {
		return errors.New("alert assessment exceeds its field bounds")
	}
	switch assessment.ImmediateActionKind {
	case "mitigation", "monitor", "investigation", "none":
	default:
		return errors.New("alert assessment immediate_action_kind must be mitigation, monitor, investigation, or none")
	}
	if err := validateScopeShape(assessment.Scope); err != nil {
		return err
	}
	switch assessment.Verdict {
	case "confirmed_issue", "likely_issue":
		if assessment.Impact == "" || assessment.Cause == "" ||
			assessment.ImmediateAction == "" || assessment.Verification == "" ||
			assessment.LongTermSolution == "" {
			return errors.New("confirmed or likely alert assessment requires impact, cause, immediate_action, verification, and long_term_solution")
		}
		if assessment.CauseStatus != "identified" && assessment.CauseStatus != "bounded" {
			return errors.New("confirmed or likely alert assessment requires cause_status identified or bounded")
		}
	case "not_issue":
		if assessment.Impact == "" {
			return errors.New("not_issue alert assessment requires impact")
		}
	case "unverified":
		if assessment.Impact == "" || assessment.ImmediateAction == "" {
			return errors.New("unverified alert assessment requires impact and the next verification in immediate_action")
		}
	default:
		return errors.New("alert assessment verdict must be confirmed_issue, likely_issue, not_issue, or unverified")
	}
	return nil
}

func validateScopeShape(scope *Scope) error {
	if scope == nil {
		return nil
	}
	scope.Status = strings.ToLower(strings.TrimSpace(scope.Status))
	scope.CheckedTargets = boundedUnique(scope.CheckedTargets, 50, 200)
	scope.UnverifiedTargets = boundedUnique(scope.UnverifiedTargets, 50, 200)
	scope.EvidenceRefs = boundedUnique(scope.EvidenceRefs, 50, 120)
	scope.UniverseEvidenceRef = bounded(scope.UniverseEvidenceRef, 120)
	if len(scope.CheckedTargets) == 0 || len(scope.EvidenceRefs) == 0 {
		return errors.New("alert assessment scope requires checked_targets and evidence_refs")
	}
	switch scope.Status {
	case "bounded":
		if len(scope.UnverifiedTargets) == 0 {
			return errors.New("bounded alert assessment scope requires unverified_targets")
		}
		if scope.UniverseEvidenceRef != "" {
			return errors.New("bounded alert assessment scope cannot claim a universe evidence reference")
		}
	case "exhaustive":
		if len(scope.UnverifiedTargets) != 0 || scope.UniverseEvidenceRef == "" {
			return errors.New("exhaustive alert assessment scope requires universe_evidence_ref and no unverified_targets")
		}
		if !slices.Contains(scope.EvidenceRefs, scope.UniverseEvidenceRef) {
			return errors.New("exhaustive alert assessment scope must include universe_evidence_ref in evidence_refs")
		}
	default:
		return errors.New("alert assessment scope status must be bounded or exhaustive")
	}
	return nil
}

// Correction validates scope against typed evidence. Exhaustive is accepted
// only when a trusted inventory enumerates exactly the checked target set and
// each target also has its own cited observation.
func Correction(assessment *Assessment, evidence []core.Evidence) string {
	return CorrectionWithUniverse(assessment, evidence, nil)
}

func CorrectionWithUniverse(
	assessment *Assessment,
	evidence []core.Evidence,
	universe *TargetUniverse,
) string {
	if assessment == nil {
		return "the operational alert has no structured alert assessment"
	}
	if assessment.Scope == nil {
		return "the alert assessment has no structured scope; record bounded or exhaustive scope, checked targets, unverified targets, and the evidence references that cover them"
	}
	if err := ValidateAssessment(assessment); err != nil {
		return err.Error()
	}
	scope := assessment.Scope
	byID := make(map[string]core.Evidence, len(evidence))
	for _, item := range evidence {
		byID[strings.TrimSpace(item.ID)] = item
	}
	for _, ref := range scope.EvidenceRefs {
		if _, ok := byID[ref]; !ok {
			return fmt.Sprintf("the alert scope cites absent evidence %q", ref)
		}
	}
	for _, target := range scope.CheckedTargets {
		covered := false
		for _, ref := range scope.EvidenceRefs {
			if ref != scope.UniverseEvidenceRef && evidenceCoversTarget(byID[ref], target) {
				covered = true
				break
			}
		}
		if !covered {
			return fmt.Sprintf("the checked target %q has no matching evidence reference in the alert scope", target)
		}
	}
	if scope.Status != "exhaustive" {
		return ""
	}
	if universe == nil {
		return "the exhaustive alert scope is unsupported because the host has not attested a complete target universe; use bounded scope"
	}
	universe.EvidenceRef = strings.TrimSpace(universe.EvidenceRef)
	universe.Targets = boundedUnique(universe.Targets, 50, 200)
	if universe.EvidenceRef == "" || len(universe.Targets) == 0 ||
		universe.EvidenceRef != scope.UniverseEvidenceRef {
		return "the exhaustive alert scope does not match a host-attested target universe; use bounded scope"
	}
	universeEvidence, ok := byID[scope.UniverseEvidenceRef]
	if !ok {
		return fmt.Sprintf("the exhaustive scope cites absent target-universe evidence %q", scope.UniverseEvidenceRef)
	}
	if universeEvidence.ClaimID != "scope.target_universe" ||
		strings.ToLower(strings.TrimSpace(universeEvidence.Relation)) != "supports" {
		return fmt.Sprintf("evidence %q does not record a supported complete target universe", scope.UniverseEvidenceRef)
	}
	checked, configured := normalizedSet(scope.CheckedTargets), normalizedSet(universe.Targets)
	missing, extra := difference(configured, checked), difference(checked, configured)
	if len(missing) != 0 || len(extra) != 0 {
		parts := make([]string, 0, 2)
		if len(missing) != 0 {
			parts = append(parts, "configured but unchecked: "+strings.Join(missing, ", "))
		}
		if len(extra) != 0 {
			parts = append(parts, "checked but absent from the configured universe: "+strings.Join(extra, ", "))
		}
		return "the exhaustive scope does not match its complete target universe; " + strings.Join(parts, "; ")
	}
	return ""
}

func evidenceCoversTarget(item core.Evidence, target string) bool {
	want := strings.ToLower(strings.TrimSpace(target))
	if want == "" || strings.TrimSpace(item.ClaimID) == "" {
		return false
	}
	switch strings.ToLower(strings.TrimSpace(item.Relation)) {
	case "supports", "contradicts":
	default:
		return false
	}
	return strings.ToLower(strings.TrimSpace(item.Target)) == want
}

func normalizedSet(targets []string) []string {
	result := boundedUnique(targets, len(targets), 200)
	for index := range result {
		result[index] = strings.ToLower(result[index])
	}
	slices.Sort(result)
	return result
}

func difference(left, right []string) []string {
	return slices.DeleteFunc(slices.Clone(left), func(value string) bool {
		return slices.Contains(right, value)
	})
}

func boundedUnique(values []string, limit, fieldLimit int) []string {
	result := make([]string, 0, min(len(values), limit))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = bounded(value, fieldLimit)
		if value == "" {
			continue
		}
		key := strings.ToLower(value)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, value)
		if len(result) == limit {
			break
		}
	}
	return result
}

func bounded(value string, limit int) string {
	return strings.TrimSpace(core.TruncateUTF8(strings.TrimSpace(value), limit))
}

// Render returns host-owned Slack prose for a validated assessment. Free-form
// model fields remain in the durable assessment for review, but they are not
// public assertions: scope, verdict, cause state, and next-step kind are the
// structured facts the host can render without interpreting prose.
func Render(assessment *Assessment) (string, bool) {
	if assessment == nil || assessment.Scope == nil {
		return "", false
	}
	scope := assessment.Scope
	parts := make([]string, 0, 5)
	if scope.Status == "exhaustive" {
		parts = append(parts, "**All configured targets were checked:** "+strings.Join(scope.CheckedTargets, ", ")+".")
	} else {
		parts = append(parts, "**Among the checked targets:** "+strings.Join(scope.CheckedTargets, ", ")+".")
	}
	switch assessment.Verdict {
	case "confirmed_issue":
		parts = append(parts, "**Status:** The checked evidence confirms an active issue on this bounded scope.")
	case "likely_issue":
		parts = append(parts, "**Status:** The checked evidence indicates a likely active issue on this bounded scope.")
	case "not_issue":
		parts = append(parts, "**Status:** The checked evidence does not show the alert condition as active on this bounded scope.")
	case "unverified":
		parts = append(parts, "**Status:** The alert condition remains unverified on this bounded scope.")
	}
	if scope.Status == "bounded" {
		parts = append(parts, "**Still unverified:** Targets outside the checked set remain unverified.")
	}
	if assessment.CauseStatus == "identified" {
		parts = append(parts, "**Cause:** Identified by the cited evidence for the checked scope.")
	} else if assessment.CauseStatus == "bounded" {
		parts = append(parts, "**Cause:** Bounded by the cited evidence; the exact cause is not fully identified.")
	}
	switch assessment.ImmediateActionKind {
	case "mitigation":
		parts = append(parts, "**Next:** Mitigate the affected checked targets, then verify the same scope again.")
	case "monitor":
		parts = append(parts, "**Next:** Continue monitoring the checked targets for recurrence.")
	case "investigation":
		parts = append(parts, "**Next:** Continue investigating the checked targets and record the next bounded verification.")
	}
	return strings.Join(parts, "\n\n"), true
}
