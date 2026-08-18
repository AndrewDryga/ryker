// Package completionpolicy validates host-authored completion invariants that
// sit above one investigation contract.
package completionpolicy

import (
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// PublishedArtifactCriterion marks a task whose requested result must be live
// for a future run, rather than merely drafted in the current workspace.
const PublishedArtifactCriterion = "artifact_outcome:published_and_adopted"

// ScheduledOutcomeOnlyCriterion marks a scheduled assessment whose successful
// Slack result should contain the outcome, bounded scope, and next action, not
// the reusable workflow identity used to gather it. Blocked and approval-bound
// runs keep those identities because they explain the boundary to the operator.
const ScheduledOutcomeOnlyCriterion = "scheduled_result:outcome_only"

// ScheduledResultCorrection checks versioned workflow references structurally.
// It does not search generated prose for a phrase list: the host extracts the
// versioned references supplied in the trusted schedule prompt, stores the
// output policy as a completion criterion, and rejects only matching identities
// in a successful public result.
func ScheduledResultCorrection(
	criteria []string,
	trigger, action, message, completionStatus string,
	pendingApproval bool,
) string {
	if !slices.Contains(criteria, ScheduledOutcomeOnlyCriterion) ||
		action != "reply" || completionStatus != "decision_ready" || pendingApproval {
		return ""
	}
	privateBases := versionedReferenceBases(trigger)
	if len(privateBases) == 0 {
		return ""
	}
	for _, reference := range versionedReferences(message) {
		if _, private := privateBases[strings.ToLower(reference.base)]; !private {
			continue
		}
		return "the successful scheduled result exposes the execution reference `" +
			reference.full + "`; omit reusable-workflow identities and execution mechanics " +
			"from a decision-ready result, and report only the evidence-backed verdict, " +
			"bounded scope, and actionable next step. Keep the reference only when the run " +
			"is blocked or an approval actually requires it"
	}
	return ""
}

type versionedReference struct {
	base string
	full string
}

func versionedReferenceBases(text string) map[string]struct{} {
	result := make(map[string]struct{})
	for _, reference := range versionedReferences(text) {
		result[strings.ToLower(reference.base)] = struct{}{}
	}
	return result
}

func versionedReferences(text string) []versionedReference {
	result := make([]versionedReference, 0, 2)
	for _, field := range strings.Fields(text) {
		field = strings.Trim(field, "`'\"()[]{}<>,.;:")
		base, version, found := strings.Cut(field, "@")
		if !found || base == "" || version == "" || strings.Contains(version, "@") ||
			!containsDigit(version) || !referencePart(base) || !referencePart(version) {
			continue
		}
		result = append(result, versionedReference{base: base, full: base + "@" + version})
	}
	return result
}

func containsDigit(value string) bool {
	return strings.IndexFunc(value, func(r rune) bool { return r >= '0' && r <= '9' }) >= 0
}

func referencePart(value string) bool {
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || strings.ContainsRune("._/-", r) {
			continue
		}
		return false
	}
	return true
}

func PublishedArtifactCorrection(
	criteria []string,
	evidence []core.Evidence,
	completionStatus string,
) string {
	if completionStatus != "decision_ready" ||
		!slices.Contains(criteria, PublishedArtifactCriterion) {
		return ""
	}
	for _, item := range evidence {
		if item.ClaimID != "task.requested_outcome" || item.Relation != "supports" {
			continue
		}
		artifact := strings.TrimSpace(item.Dimensions["artifact"])
		if item.SourceType == "emisar" && strings.TrimSpace(item.SourceID) != "" &&
			artifact != "" && strings.TrimSpace(item.Dimensions["revision"]) != "" &&
			strings.EqualFold(strings.TrimSpace(item.Target), artifact) &&
			strings.EqualFold(strings.TrimSpace(item.Dimensions["artifact_state"]), "published") &&
			strings.EqualFold(strings.TrimSpace(item.Dimensions["adoption_state"]), "active") {
			return ""
		}
	}
	return "the parent task requires the artifact to be published and adopted by the requested " +
		"future run; a draft-only result cannot complete it — cite the current Emisar publication " +
		"receipt as task.requested_outcome evidence with matching artifact, target, revision, " +
		"artifact_state=published and adoption_state=active, or return the exact publication or " +
		"approval boundary"
}

// CurrentCandidateCorrection validates claims that must be proven by this
// candidate before the service appends correlation ancestry to the ordinary
// evidence ledger.
func CurrentCandidateCorrection(
	criteria []string,
	effort core.EffortContract,
	evidence []core.Evidence,
	coverage []core.Coverage,
	completionStatus, completionVerdict string,
	now time.Time,
) string {
	if correction := PublishedArtifactCorrection(criteria, evidence, completionStatus); correction != "" {
		return correction
	}
	return HealthyOperationalTrendCorrection(
		effort, evidence, CurrentCoverage(coverage, now), completionVerdict, now,
	)
}

// CurrentCoverage timestamps the candidate assessment so the ledger does not
// let an older persisted row outrank an unstamped current row.
func CurrentCoverage(coverage []core.Coverage, now time.Time) []core.Coverage {
	stamped := make([]core.Coverage, 0, len(coverage))
	for _, item := range coverage {
		if item.ObservedAt.IsZero() && item.CreatedAt.IsZero() {
			item.CreatedAt = now
		}
		stamped = append(stamped, item)
	}
	return stamped
}

// HealthyOperationalTrendCorrection requires typed comparable measurements,
// never an interpretation of model-authored prose.
func HealthyOperationalTrendCorrection(
	effort core.EffortContract,
	evidence []core.Evidence,
	coverage []core.Coverage,
	verdict string,
	now time.Time,
) string {
	if effort != core.EffortOperationalAssessment || verdict != "healthy" {
		return ""
	}
	functional := false
	type comparisonSignature struct {
		window, comparison, population, denominator string
	}
	trends := map[string]map[string]comparisonSignature{"broad": {}, "service": {}}
	for _, item := range evidence {
		if item.ClaimID != "application.functional_behavior" || item.Relation != "supports" {
			continue
		}
		if item.SourceType != "emisar" && item.SourceType != "monitoring" {
			continue
		}
		if item.ObservedAt.IsZero() || item.ObservedAt.After(now.Add(5*time.Minute)) ||
			now.Sub(item.ObservedAt) > 30*time.Minute {
			continue
		}
		dimensions := item.Dimensions
		kind := strings.ToLower(strings.TrimSpace(dimensions["measurement_kind"]))
		if kind == "functional_probe" && strings.TrimSpace(dimensions["endpoint"]) != "" {
			functional = true
			continue
		}
		scope := strings.ToLower(strings.TrimSpace(dimensions["measurement_scope"]))
		if _, ok := trends[scope]; !ok || strings.TrimSpace(dimensions["window"]) == "" ||
			strings.TrimSpace(dimensions["comparison_window"]) == "" ||
			strings.TrimSpace(dimensions["population"]) == "" ||
			strings.TrimSpace(dimensions["denominator"]) == "" {
			continue
		}
		if kind == "error_rate" || kind == "timeout_rate" {
			trends[scope][kind] = comparisonSignature{
				window:      strings.ToLower(strings.TrimSpace(dimensions["window"])),
				comparison:  strings.ToLower(strings.TrimSpace(dimensions["comparison_window"])),
				population:  strings.ToLower(strings.TrimSpace(dimensions["population"])),
				denominator: strings.ToLower(strings.TrimSpace(dimensions["denominator"])),
			}
		}
	}
	missing := make([]string, 0, 5)
	if !functional {
		missing = append(missing, "a typed functional_probe")
	}
	for _, scope := range []string{"broad", "service"} {
		for _, kind := range []string{"error_rate", "timeout_rate"} {
			if _, ok := trends[scope][kind]; !ok {
				missing = append(missing, scope+" "+kind)
			}
		}
	}
	if len(missing) != 0 {
		return "a healthy platform verdict requires fresh equivalent-window application evidence: " +
			strings.Join(missing, ", ") +
			"; record trusted measurement_kind, measurement_scope, window, comparison_window, " +
			"population, and denominator as typed evidence dimensions"
	}
	for _, scope := range []string{"broad", "service"} {
		if trends[scope]["error_rate"] != trends[scope]["timeout_rate"] {
			return "the " + scope + " error-rate and timeout-rate measurements do not share " +
				"the same window, comparison window, population, and denominator; query comparable " +
				"series before returning a healthy platform verdict"
		}
	}
	return ""
}
