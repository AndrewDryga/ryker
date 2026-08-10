package standingrule

import (
	"encoding/json"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

func EvaluationEligible(input core.SlackInput) bool {
	if input.ChannelID == "" || strings.HasPrefix(input.ChannelID, "D") {
		return false
	}
	return input.Kind == "message" || input.Kind == "mention" || input.Kind == "bot_message"
}

func Acknowledgement(rules []core.StandingRule) string {
	for _, rule := range rules {
		workflow, _, _, err := core.NormalizeStandingWorkflow(rule.Workflow, rule.Trigger, rule.Action)
		if err == nil && workflow.Delivery.Acknowledge != "" &&
			workflow.Delivery.Acknowledge != "none" {
			return workflow.Delivery.Acknowledge
		}
	}
	return ""
}

func EvaluationAuditEvent(
	input core.SlackInput,
	evaluation core.StandingRuleEvaluationAudit,
) (core.AuditEvent, error) {
	detail, err := json.Marshal(evaluation)
	if err != nil {
		return core.AuditEvent{}, err
	}
	outcome := "not_matched"
	if evaluation.Matched > 0 {
		outcome = "matched"
	}
	return core.AuditEvent{
		Kind: "standing_rules.evaluated", ActorID: "responder", ObjectID: input.ID,
		Outcome: outcome, Detail: string(detail), CompleteDetail: true,
	}, nil
}
