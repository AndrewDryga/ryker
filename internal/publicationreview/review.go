// Package publicationreview turns Coop review evidence into the publication
// decision and operator-facing readiness summary used by every control surface.
package publicationreview

import (
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
)

// ReviewSummary renders Coop's machine review as operator-facing readiness evidence.
func ReviewSummary(review coop.Review) string {
	original := review
	review = NormalizeReview(review)
	gate := map[string]string{
		"none":          "not configured (recommended)",
		"passed":        "passed",
		"failed":        "failed",
		"startup_error": "could not start",
		"not_run":       "not run",
	}[review.Gate]
	if gate == "" {
		gate = displayOr(review.Gate, "not run")
	}
	rebase := map[string]string{
		"clean":    "clean",
		"conflict": "has conflicts",
	}[review.Rebase]
	if rebase == "" {
		rebase = displayOr(review.Rebase, "not run")
	}
	lines := []string{
		"*Readiness checks*",
		"• Repository gate: " + gate,
		"• Rebase onto the current base branch: " + rebase,
	}
	var blockers []string
	for _, reason := range review.NotPublishableReasons {
		if message := reviewReasonMessage(reason, review.GateError); message != "" {
			blockers = append(blockers, "• "+message)
		}
	}
	for _, finding := range review.PolicyFindings {
		if finding = strings.TrimSpace(finding); finding != "" {
			blockers = append(blockers, "• Policy check: "+finding)
		}
	}
	_, baselineFindings := publicationPolicyFindings(original)
	if len(baselineFindings) > 0 {
		noun := "value"
		if len(baselineFindings) != 1 {
			noun = "values"
		}
		lines = append(lines, "", "*Baseline scan note*")
		lines = append(lines, fmt.Sprintf(
			"• Coop flagged %d secret-shaped %s outside the lines changed by this task. "+
				"Those pre-existing findings do not block the draft; newly added secrets still do.",
			len(baselineFindings), noun,
		))
	}
	if len(blockers) > 0 {
		lines = append(lines, "", "*What needs attention*")
		lines = append(lines, blockers[:min(len(blockers), 12)]...)
	}
	if detail := strings.TrimSpace(review.GateError); detail != "" {
		lines = append(lines, "", "*Gate error*", "`"+strings.ReplaceAll(detail, "`", "'")+"`")
	}
	if review.Gate == "none" {
		lines = append(lines, "", "*Recommendation*")
		lines = append(lines,
			"• Add `gate:` to `.agent/project.yaml` for repeatable repository validation. "+
				"Responder can still open a draft PR, but this review did not run a repository-defined gate.",
		)
	}
	if GateIncomplete(original) {
		lines = append(lines, "", "*Validation warning*")
		lines = append(lines,
			"• The repository gate did not complete cleanly. Responder can still publish the exact "+
				"reviewed tree as a draft PR; inspect its diff and GitHub checks before merging.",
		)
		if slices.Contains(original.NotPublishableReasons, "gate_modified_candidate") {
			lines = append(lines,
				"• Validation changed tracked files in its disposable checkout, so that gate result was "+
					"discarded. Those gate-authored changes are not included in the draft.",
			)
		}
	}
	return strings.Join(lines, "\n")
}

// NormalizeReview removes advisory gate and baseline findings from publication blockers.
func NormalizeReview(review coop.Review) coop.Review {
	filtered := make([]string, 0, len(review.NotPublishableReasons))
	originalPolicyCount := len(review.PolicyFindings)
	actionablePolicy, _ := publicationPolicyFindings(review)
	policyAdvisory := len(actionablePolicy) < originalPolicyCount
	review.PolicyFindings = actionablePolicy
	gateAdvisory := false
	switch strings.TrimSpace(review.Gate) {
	case "none", "failed", "startup_error", "not_run":
		gateAdvisory = true
	}
	for _, reason := range review.NotPublishableReasons {
		switch strings.TrimSpace(reason) {
		case "gate_not_configured", "gate_failed", "gate_startup_error", "gate_modified_candidate":
			gateAdvisory = true
			continue
		case "policy_findings":
			if policyAdvisory && len(actionablePolicy) == 0 {
				continue
			}
		}
		filtered = append(filtered, reason)
	}
	review.NotPublishableReasons = filtered
	if gateAdvisory || policyAdvisory {
		review.Publishable = review.Rebase == "clean" &&
			len(filtered) == 0 && len(review.PolicyFindings) == 0
	}
	return review
}

var reviewPolicyLocation = regexp.MustCompile(`\bin (.+):([0-9]+)(?:\s|$)`)

func publicationPolicyFindings(review coop.Review) (actionable, baseline []string) {
	if len(review.PolicyFindings) == 0 {
		return nil, nil
	}
	if review.PatchTruncated || len(review.Patch) == 0 {
		return slices.Clone(review.PolicyFindings), nil
	}
	added := addedPatchLines(review.Patch)
	for _, finding := range review.PolicyFindings {
		match := reviewPolicyLocation.FindStringSubmatch(strings.TrimSpace(finding))
		if len(match) != 3 {
			actionable = append(actionable, finding)
			continue
		}
		line, err := strconv.Atoi(match[2])
		if err != nil || added[match[1]][line] {
			actionable = append(actionable, finding)
			continue
		}
		baseline = append(baseline, finding)
	}
	return actionable, baseline
}

func addedPatchLines(patch []byte) map[string]map[int]bool {
	added := make(map[string]map[int]bool)
	path := ""
	line := 0
	for _, raw := range strings.Split(string(patch), "\n") {
		switch {
		case strings.HasPrefix(raw, "+++ b/"):
			path = strings.TrimPrefix(raw, "+++ b/")
		case strings.HasPrefix(raw, "@@"):
			line = patchHunkNewLine(raw)
		case path == "" || line == 0:
			continue
		case strings.HasPrefix(raw, "+"):
			if added[path] == nil {
				added[path] = make(map[int]bool)
			}
			added[path][line] = true
			line++
		case strings.HasPrefix(raw, "-") || strings.HasPrefix(raw, "\\"):
			continue
		default:
			line++
		}
	}
	return added
}

func patchHunkNewLine(header string) int {
	plus := strings.IndexByte(header, '+')
	if plus == -1 {
		return 0
	}
	rest := header[plus+1:]
	if end := strings.IndexAny(rest, ", "); end != -1 {
		rest = rest[:end]
	}
	line, _ := strconv.Atoi(rest)
	return line
}

// GateIncomplete reports whether publication is proceeding with an incomplete repository gate.
func GateIncomplete(review coop.Review) bool {
	switch strings.TrimSpace(review.Gate) {
	case "failed", "startup_error", "not_run":
		return true
	}
	for _, reason := range review.NotPublishableReasons {
		switch strings.TrimSpace(reason) {
		case "gate_failed", "gate_startup_error", "gate_modified_candidate":
			return true
		}
	}
	return false
}

func reviewReasonMessage(reason string, gateError string) string {
	switch strings.TrimSpace(reason) {
	case "gate_not_configured":
		return "Add `gate:` to `.agent/project.yaml` for repeatable repository validation."
	case "gate_failed":
		if strings.TrimSpace(gateError) == "" {
			return "The repository gate failed, but Coop did not retain the failing command output for this card. Ask Emisar to diagnose it in the task fork."
		}
		return "The repository gate failed. Ask Emisar to fix the reported check, then retry the draft PR."
	case "gate_startup_error":
		return "Coop could not start the repository gate. Check the box runtime and project review configuration."
	case "gate_modified_candidate":
		return "Validation changed tracked files. Emisar needs to inspect that diff and either keep an intended generated update or make the gate read-only."
	case "rebase_conflict":
		return "The change conflicts with the current base branch and needs a rebase."
	case "parent_moved":
		return "The base branch changed during review. Retry against its latest commit."
	case "source_moved":
		return "The task changed while it was being reviewed. Wait for it to finish, then retry."
	case "fork_owner_active":
		return "The agent is still working in this task. Wait for it to finish, then retry."
	case "policy_findings":
		return "Coop found a policy issue in the proposed change."
	case "patch_truncated":
		return "The complete patch is unavailable from this older Coop review. Run the review again."
	case "patch_artifact_unavailable":
		return "Coop could not preserve a complete verified patch artifact. Reduce generated changes or inspect Coop storage, then retry."
	default:
		if reason == "" {
			return ""
		}
		return "Coop reported: " + strings.ReplaceAll(reason, "_", " ")
	}
}

func displayOr(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}
