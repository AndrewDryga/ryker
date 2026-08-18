// Package taskcontract derives durable host-owned completion requirements from
// trusted operator requests and correlation ancestry.
package taskcontract

import (
	"slices"
	"strings"
	"unicode"

	"github.com/AndrewDryga/responder/internal/completionpolicy"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

type ArtifactOutcome string

const (
	ArtifactOutcomeDraft               ArtifactOutcome = "draft"
	ArtifactOutcomePublishedAndAdopted ArtifactOutcome = "published_and_adopted"
)

// RequestedArtifactOutcome classifies operator input once, before it can be
// influenced by model output. The durable episode stores the resulting stable
// completion token; validators never search generated prose.
func RequestedArtifactOutcome(text string) ArtifactOutcome {
	if !investigation.ReusableArtifactAuthoring(text) {
		return ArtifactOutcomeDraft
	}
	words := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	lifecycle := func(word string) bool {
		switch word {
		case "publish", "published", "publishing", "ship", "shipped", "activate", "activated", "adopt", "adopted", "default":
			return true
		default:
			return false
		}
	}
	for index, word := range words {
		if !lifecycle(word) {
			continue
		}
		for prior := max(0, index-3); prior < index; prior++ {
			if words[prior] == "not" || words[prior] == "never" || words[prior] == "without" {
				return ArtifactOutcomeDraft
			}
		}
	}
	for _, word := range words {
		if lifecycle(word) {
			return ArtifactOutcomePublishedAndAdopted
		}
	}
	return ArtifactOutcomeDraft
}

// ApplyReusableArtifact marks operator-authored future-use artifacts with the
// publication outcome the host must later validate.
func ApplyReusableArtifact(value *core.WorkEpisode, text string) {
	if value == nil || !slices.Contains(value.RequiredCoverage, "task") ||
		RequestedArtifactOutcome(text) != ArtifactOutcomePublishedAndAdopted {
		return
	}
	value.Activity = core.ActivityEngineering
	if !slices.Contains(value.CompletionCriteria, completionpolicy.PublishedArtifactCriterion) {
		value.CompletionCriteria = append(value.CompletionCriteria, completionpolicy.PublishedArtifactCriterion)
	}
}

// ApplyScheduledResult marks broad scheduled assessments whose successful
// channel result must omit the reusable workflow identity used to gather it.
func ApplyScheduledResult(value *core.WorkEpisode, inputKind string) {
	if value == nil || inputKind != "scheduled" || value.Effort != core.EffortOperationalAssessment ||
		slices.Contains(value.CompletionCriteria, completionpolicy.ScheduledOutcomeOnlyCriterion) {
		return
	}
	value.CompletionCriteria = append(value.CompletionCriteria, completionpolicy.ScheduledOutcomeOnlyCriterion)
}

// ScheduledResultCorrection applies the durable episode policy to one model
// decision without making the service re-derive completion state.
func ScheduledResultCorrection(
	episode core.WorkEpisode,
	input core.SlackInput,
	decision decisionpkg.WatchDecision,
) string {
	status := ""
	if decision.Completion != nil {
		status = decision.Completion.Status
	}
	return completionpolicy.ScheduledResultCorrection(
		episode.CompletionCriteria, input.Text, decision.Action, decision.Message,
		status, decision.PendingApproval != nil,
	)
}

// InheritParent keeps a follow-up episode bound to the requested task outcome
// without reinterpreting the parent's prose.
func InheritParent(child *core.WorkEpisode, parent core.WorkEpisode) {
	if child == nil || !slices.Contains(parent.RequiredCoverage, "task") {
		return
	}
	if !slices.Contains(child.RequiredCoverage, "task") {
		child.RequiredCoverage = append(child.RequiredCoverage, "task")
	}
	if child.Effort == core.EffortConversational {
		child.Effort = core.EffortFocusedCheck
	}
	if parent.Activity == core.ActivityEngineering {
		child.Activity = core.ActivityEngineering
	}
	if slices.Contains(parent.CompletionCriteria, completionpolicy.PublishedArtifactCriterion) &&
		!slices.Contains(child.CompletionCriteria, completionpolicy.PublishedArtifactCriterion) {
		child.CompletionCriteria = append(
			child.CompletionCriteria,
			completionpolicy.PublishedArtifactCriterion,
		)
	}
}
