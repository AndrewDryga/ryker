// Package taskofferrejection separates an optional writable transition from
// the read-only investigation that proposed it.
package taskofferrejection

import (
	"errors"
	"slices"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/taskoffercarry"
	"github.com/AndrewDryga/responder/internal/taskofferclaims"
)

type Check struct {
	Kind     string
	Rejected error
	Clear    func()
}

func Correction(decision decisionpkg.WatchDecision, now time.Time) string {
	if decision.TaskPrompt == "" {
		return ""
	}
	if !decisionpkg.ValidSuggestedEngineeringTaskBoundary(decision) {
		return "suggested engineering task requires a decision-ready result or an exact tool-failure blocker"
	}
	evidence := decisionpkg.SanitizeEvidence(decision.Evidence, "", "", "", now)
	if !decisionpkg.WatchDecisionHasEvidenceSource(evidence, "repository") {
		return "suggested engineering task requires repository evidence"
	}
	return taskofferclaims.RepositoryCorrection(evidence, decision.TaskRepository)
}

func Append(checks []Check, decision *decisionpkg.WatchDecision, now time.Time) []Check {
	if correction := Correction(*decision, now); correction != "" {
		checks = append(checks, Check{
			Kind: "engineering task", Rejected: errors.New(correction),
			Clear: func() { Drop(decision) },
		})
	}
	return checks
}

func WatchCorrection(
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	decision decisionpkg.WatchDecision,
	now time.Time,
	correlate decisionpkg.Correlator,
) (string, bool) {
	if correction := Correction(decision, now); correction != "" {
		return correction, true
	}
	return decisionpkg.WatchDecisionCorrectionAt(input, state, decision, now, correlate), false
}

func Drop(decision *decisionpkg.WatchDecision) {
	decision.TaskTitle, decision.TaskRepository = "", ""
	decision.TaskPrompt, decision.TaskPullRequest = "", ""
	decision.Operations = dropOperations(decision.Operations)
	decision.AppliedOperations = dropOperations(decision.AppliedOperations)
}

// DropReport removes the same optional engineering transition from a deep-lane
// report. Reports carry task offers only in their operation stream.
func DropReport(report *decisionpkg.AgentReport) {
	report.Operations = dropOperations(report.Operations)
	report.AppliedOperations = dropOperations(report.AppliedOperations)
}

func dropOperations(operations []investigation.ResultOperation) []investigation.ResultOperation {
	drop := func(operation investigation.ResultOperation) bool {
		return operation.Type == "offer_task" && operation.Task != nil &&
			operation.Task.Kind == "engineering"
	}
	return slices.DeleteFunc(operations, drop)
}

func ForgetCarried(carried **taskoffercarry.Offer, rejected bool) {
	if rejected {
		*carried = nil
	}
}

func CorrectionClass(rejected bool, otherwise string) string {
	if rejected {
		return "rejected"
	}
	return otherwise
}
