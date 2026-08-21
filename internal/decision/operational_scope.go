package decision

import (
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/operationalreply"
	"github.com/AndrewDryga/responder/internal/operationalscope"
)

type OperationalTargetUniverse = operationalscope.TargetUniverse

func OperationalScopeCorrection(assessment *AlertAssessment, evidence []core.Evidence) string {
	return operationalscope.Correction(assessment, evidence)
}

func OperationalScopeCorrectionWithUniverse(
	assessment *AlertAssessment,
	evidence []core.Evidence,
	universe *OperationalTargetUniverse,
) string {
	return operationalscope.CorrectionWithUniverse(assessment, evidence, universe)
}

// RenderOperationalAlertDecision replaces arbitrary completion prose with the
// host rendering derived from validated structured scope.
func RenderOperationalAlertDecision(
	decision WatchDecision,
	evidence []core.Evidence,
	universe ...*OperationalTargetUniverse,
) (WatchDecision, string) {
	if decision.Action != "reply" {
		return decision, ""
	}
	var attestation *OperationalTargetUniverse
	if len(universe) > 0 {
		attestation = universe[0]
	}
	if correction := OperationalScopeCorrectionWithUniverse(
		decision.AlertAssessment, evidence, attestation,
	); correction != "" {
		return decision, correction
	}
	message, ok := operationalreply.Render(decision.AlertAssessment, evidence)
	if !ok {
		return decision, "the operational alert assessment could not be rendered from validated structured scope"
	}
	setDecisionReply(&decision, message, nil)
	return decision, ""
}

func RenderOperationalAlertReport(
	report AgentReport,
	evidence []core.Evidence,
	universe ...*OperationalTargetUniverse,
) (AgentReport, string) {
	var attestation *OperationalTargetUniverse
	if len(universe) > 0 {
		attestation = universe[0]
	}
	if correction := OperationalScopeCorrectionWithUniverse(
		report.AlertAssessment, evidence, attestation,
	); correction != "" {
		return report, correction
	}
	message, ok := operationalreply.Render(report.AlertAssessment, evidence)
	if !ok {
		return report, "the operational alert assessment could not be rendered from validated structured scope"
	}
	report.Message = message
	report.FollowupMessages = nil
	for index := range report.Operations {
		operation := &report.Operations[index]
		if operation.Type == "complete_episode" && operation.Completion != nil {
			operation.Completion.Message = message
			operation.Completion.FollowupMessages = nil
		}
	}
	return report, ""
}

// setDecisionReply updates both the folded projection and the canonical
// operations envelope. Without the second write, persistence reparses the
// model's original complete_episode and silently discards host rendering.
func setDecisionReply(decision *WatchDecision, message string, followups []string) {
	decision.Message = message
	decision.FollowupMessages = followups
	for index := range decision.Operations {
		operation := &decision.Operations[index]
		if operation.Type != "complete_episode" || operation.Completion == nil {
			continue
		}
		operation.Completion.Message = message
		operation.Completion.FollowupMessages = followups
	}
}
