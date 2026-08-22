// Package operationalreply renders a validated operational assessment for a
// human Slack reader without exposing its machine-readable scope ledger.
package operationalreply

import (
	"slices"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/operationalscope"
)

func Render(assessment *operationalscope.Assessment, evidence []core.Evidence) (string, bool) {
	if assessment == nil || assessment.Scope == nil {
		return "", false
	}
	byID := make(map[string]core.Evidence, len(evidence))
	for _, item := range evidence {
		byID[strings.TrimSpace(item.ID)] = item
	}
	parts := make([]string, 0, 5)
	// No host-rendered lead line above these observations. A bolded
	// assessment.Impact was tried on 2026-08-22 and reverted the same hour: the
	// field carries arbitrary model prose, and the exclusive paraphrases
	// TestBoundedOperationalScopeMakesExclusiveParaphrasesIrrelevant pins
	// ("Rivals stands alone as the unhealthy path") reach Slack as an exhaustive
	// claim the bounded scope never supported. The affected signal leads on its
	// own merit because referencedEvidence sorts it first.
	items := referencedEvidence(assessment, byID)
	lines := make([]string, 0, 3)
	problems := make([]string, 0, 2)
	for _, item := range items {
		if evidencePriority(item) > 1 || strings.TrimSpace(item.Observation) == "" {
			continue
		}
		problems = append(problems, sentence(item.Observation))
		if len(problems) == 2 {
			break
		}
	}
	if len(problems) > 0 {
		lines = append(lines, problems...)
		if healthy := healthyTargetSummary(items); healthy != "" {
			lines = append(lines, healthy)
		}
	} else {
		for _, item := range items[:min(len(items), 3)] {
			lines = append(lines, sentence(item.Observation))
		}
	}
	if len(lines) > 0 {
		parts = append(parts, bulletList(lines))
	}
	if assessment.Scope.Status == "bounded" {
		parts = append(parts, "I haven’t yet verified "+humanList(assessment.Scope.UnverifiedTargets, 3)+".")
	}
	if assessment.ImmediateAction != "" {
		parts = append(parts, "Next: "+sentence(assessment.ImmediateAction))
	}
	return strings.Join(parts, "\n\n"), true
}

// referencedEvidence leads with evidence cited for the assessment itself, then
// adds at most one observation from each operational layer.
func referencedEvidence(
	assessment *operationalscope.Assessment,
	byID map[string]core.Evidence,
) []core.Evidence {
	refs := append(slices.Clone(assessment.EvidenceRefs), assessment.Scope.EvidenceRefs...)
	sort.SliceStable(refs, func(left, right int) bool {
		return evidencePriority(byID[strings.TrimSpace(refs[left])]) <
			evidencePriority(byID[strings.TrimSpace(refs[right])])
	})
	causal := make(map[string]struct{}, len(assessment.EvidenceRefs))
	for _, ref := range assessment.EvidenceRefs {
		causal[strings.TrimSpace(ref)] = struct{}{}
	}
	seenRefs, seenObservations, seenLayers := map[string]struct{}{}, map[string]struct{}{}, map[string]struct{}{}
	result := make([]core.Evidence, 0, len(refs))
	for _, ref := range refs {
		if ref = strings.TrimSpace(ref); ref == "" || ref == assessment.Scope.UniverseEvidenceRef {
			continue
		}
		if _, seen := seenRefs[ref]; seen {
			continue
		}
		seenRefs[ref] = struct{}{}
		item, ok := byID[ref]
		observation := strings.TrimSpace(item.Observation)
		if !ok || observation == "" {
			continue
		}
		layer := renderLayer(item.ClaimID)
		if _, isCausal := causal[ref]; !isCausal && layer != "" {
			if _, seen := seenLayers[layer]; seen {
				continue
			}
			seenLayers[layer] = struct{}{}
		}
		if _, seen := seenObservations[observation]; seen {
			continue
		}
		seenObservations[observation] = struct{}{}
		result = append(result, item)
	}
	return result
}

// bulletList gives each statement its own line. Slack mrkdwn has no list
// syntax, so the glyph is literal; the point is that three separate findings
// occupy three lines instead of one paragraph the reader has to re-split.
func bulletList(lines []string) string {
	rendered := make([]string, 0, len(lines))
	for _, line := range lines {
		rendered = append(rendered, "\u2022 "+line)
	}
	return strings.Join(rendered, "\n")
}

func healthyTargetSummary(items []core.Evidence) string {
	targets := make([]string, 0, 3)
	for _, item := range items {
		healthEffect := strings.ToLower(strings.TrimSpace(item.HealthEffect))
		if !strings.EqualFold(strings.TrimSpace(item.Relation), "supports") ||
			(healthEffect != "" && healthEffect != "none") {
			continue
		}
		target := strings.TrimSpace(item.Target)
		if target == "" || slices.Contains(targets, target) {
			continue
		}
		targets = append(targets, target)
		if len(targets) == 3 {
			break
		}
	}
	if len(targets) == 0 {
		return ""
	}
	verb := " looks healthy."
	if len(targets) > 1 {
		verb = " look healthy."
	}
	return upperFirst(conjunctionList(targets)) + verb
}

func evidencePriority(item core.Evidence) int {
	switch strings.ToLower(strings.TrimSpace(item.HealthEffect)) {
	case "unhealthy":
		return 0
	case "degraded":
		return 1
	case "none":
		return 2
	case "risk":
		return 3
	default:
		if strings.EqualFold(strings.TrimSpace(item.Relation), "contradicts") {
			return 1
		}
		return 4
	}
}

func humanList(values []string, limit int) string {
	values = slices.Clone(values[:min(len(values), limit)])
	switch len(values) {
	case 0:
		return "the remaining scope"
	case 1:
		return values[0]
	case 2:
		return values[0] + " or " + values[1]
	default:
		return strings.Join(values[:len(values)-1], ", ") + ", or " + values[len(values)-1]
	}
}

func conjunctionList(values []string) string {
	switch len(values) {
	case 0:
		return ""
	case 1:
		return values[0]
	case 2:
		return values[0] + " and " + values[1]
	default:
		return strings.Join(values[:len(values)-1], ", ") + ", and " + values[len(values)-1]
	}
}

func upperFirst(value string) string {
	if value == "" {
		return ""
	}
	runes := []rune(value)
	runes[0] = []rune(strings.ToUpper(string(runes[0])))[0]
	return string(runes)
}

func renderLayer(claimID string) string {
	switch strings.TrimSpace(claimID) {
	case "workload.desired_state", "scheduler.desired_state":
		return "runtime"
	case "application.functional_behavior", "impact.current":
		return "application"
	default:
		return strings.TrimSpace(claimID)
	}
}

func sentence(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value[len(value)-1:], ".!?") {
		return value
	}
	return value + "."
}
