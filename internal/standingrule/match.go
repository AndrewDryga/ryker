package standingrule

import (
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

var (
	terraformPattern = regexp.MustCompile(
		`(?is)\bterraform(?:\s+\w+){0,3}\s+plan\b|` +
			`\b(?:review|check|inspect)\b[^\n.]{0,80}\b(?:terraform\s+)?plan\b|` +
			`\brun\s+(?:planning|planned(?:\s+and\s+saved)?|applying|applied|` +
			`errored|failed|discarded|canceled|cancelled)\b|` +
			`\bapp\.terraform\.io\b.*\brun\s+(?:planning|planned(?:\s+and\s+saved)?|` +
			`applying|applied|errored|failed|discarded|canceled|cancelled)\b|` +
			`\brun\s+notification\b.*\brun\s+(?:planning|planned(?:\s+and\s+saved)?|` +
			`applying|applied|errored|failed|discarded|canceled|cancelled)\b|` +
			`\bplan:\s*\d+\s+to\s+add,\s*\d+\s+to\s+change,\s*\d+\s+to\s+destroy\b|` +
			`\bno\s+changes\.\s+your\s+infrastructure\s+matches\b`,
	)
	deploymentPattern          = regexp.MustCompile(`(?i)\b(?:deploy(?:ed|ing|ment)?|rollout|release)\b`)
	alertPattern               = regexp.MustCompile(`(?i)\b(?:alert|firing|critical|degraded|unhealthy|incident)\b`)
	lifecycleAssignmentPattern = regexp.MustCompile(
		`(?is)\b(?:look\s+at|watch|monitor|follow|review|check)\b[^\n]{0,100}` +
			`\bterraform\b[^\n]{0,100}\b(?:events?|notifications?|runs?|plans?)\b` +
			`[^\n]{0,100}\b(?:in|for)\s+(?:this\s+channel|here)\b`,
	)
)

// EventTextMatches identifies only the typed event families supported by
// standing workflows. It does not decide whether Responder should speak.
func EventTextMatches(event string, text string) bool {
	switch event {
	case "terraform_run":
		return terraformPattern.MatchString(text)
	case "deployment":
		return deploymentPattern.MatchString(text)
	case "operational_alert":
		return alertPattern.MatchString(text)
	default:
		return false
	}
}

func TerraformLifecycleAssignment(text string) bool {
	return lifecycleAssignmentPattern.MatchString(text)
}

// NormalizeTerraformLifecycleOffer compiles a natural standing assignment
// into one typed workflow while preserving compatible model customization.
func NormalizeTerraformLifecycleOffer(
	input core.SlackInput,
	repository string,
	proposed *core.RuleOffer,
) (*core.RuleOffer, bool) {
	if !TerraformLifecycleAssignment(input.Text) {
		return proposed, false
	}
	if proposed != nil && proposed.Workflow == nil &&
		(proposed.Trigger != "terraform_plan" || proposed.Action != "review_terraform_plan") &&
		(proposed.Trigger != "terraform_lifecycle" || proposed.Action != "monitor_terraform_lifecycle") {
		return proposed, false
	}
	workflow, _ := core.LegacyStandingWorkflow("terraform_lifecycle", "monitor_terraform_lifecycle")
	if proposed != nil && proposed.Workflow != nil {
		if proposed.Workflow.Trigger.Event != "terraform_run" {
			return proposed, false
		}
		workflow = *proposed.Workflow
	}
	offer := core.RuleOffer{
		Scope: "channel", Repository: strings.TrimSpace(repository), Workflow: &workflow,
		Trigger: "terraform_lifecycle", Action: "monitor_terraform_lifecycle",
		SourceKind: "app", ExpiresIn: "90d",
	}
	if proposed != nil {
		if candidate := strings.TrimSpace(proposed.Repository); candidate != "" {
			offer.Repository = candidate
		}
		if candidate := strings.TrimSpace(proposed.SourceKind); candidate != "" {
			offer.SourceKind = candidate
		}
		if candidate := strings.TrimSpace(proposed.ExpiresIn); candidate != "" {
			offer.ExpiresIn = candidate
		}
	}
	return &offer, true
}

// Match returns both the deterministic decision and its operator-facing
// explanation. The same function drives admission and the episode trace.
func Match(rule core.StandingRule, input core.SlackInput) (bool, string) {
	workflow, _, _, err := core.NormalizeStandingWorkflow(rule.Workflow, rule.Trigger, rule.Action)
	if err != nil {
		return false, "Skipped because this saved rule is no longer valid."
	}
	if !SourceMatches(rule.SourceKind, input.Kind) {
		return false, fmt.Sprintf(
			"Skipped because it watches %s, but this came from %s.",
			sourceLabel(rule.SourceKind), inputSourceLabel(input.Kind),
		)
	}
	if !EventTextMatches(workflow.Trigger.Event, input.Text) {
		return false, fmt.Sprintf(
			"Skipped because it watches %s, not this kind of message.",
			eventLabel(workflow.Trigger.Event),
		)
	}
	state := State(workflow.Trigger.Event, input.Text)
	if len(workflow.Trigger.States) > 0 && !slices.Contains(workflow.Trigger.States, state) {
		if state == "" {
			return false, fmt.Sprintf(
				"Skipped because it only handles %s, and this message has no matching state.",
				statesLabel(workflow.Trigger.States),
			)
		}
		return false, fmt.Sprintf(
			"Skipped because it only handles %s; this update is %s.",
			statesLabel(workflow.Trigger.States), strings.ReplaceAll(state, "_", " "),
		)
	}
	reason := fmt.Sprintf(
		"Matched because this is %s about %s.",
		inputSourceLabel(input.Kind), eventLabel(workflow.Trigger.Event),
	)
	if state != "" {
		reason = fmt.Sprintf(
			"Matched because this is %s about %s that is %s.",
			inputSourceLabel(input.Kind), eventLabel(workflow.Trigger.Event),
			strings.ReplaceAll(state, "_", " "),
		)
	}
	return true, reason
}

func State(event string, text string) string {
	text = strings.ToLower(text)
	switch event {
	case "terraform_run":
		for _, candidate := range []struct{ state, phrase string }{
			{"errored", "run errored"}, {"errored", "run failed"},
			{"discarded", "run discarded"}, {"discarded", "run canceled"},
			{"discarded", "run cancelled"}, {"applied", "run applied"},
			{"applying", "run applying"}, {"planned", "run planned"},
			{"planning", "run planning"},
		} {
			if strings.Contains(text, candidate.phrase) {
				return candidate.state
			}
		}
		if terraformPattern.MatchString(text) {
			return "planned"
		}
	case "deployment":
		if strings.Contains(text, "failed") || strings.Contains(text, "errored") {
			return "failed"
		}
		if strings.Contains(text, "completed") || strings.Contains(text, "deployed") ||
			strings.Contains(text, "succeeded") {
			return "completed"
		}
		if strings.Contains(text, "started") || strings.Contains(text, "deploying") ||
			strings.Contains(text, "rollout") {
			return "started"
		}
	case "operational_alert":
		if strings.Contains(text, "resolved") || strings.Contains(text, "alert closed") ||
			strings.Contains(text, "returned to normal") {
			return "resolved"
		}
		if strings.Contains(text, "firing") || strings.Contains(text, "alert open") ||
			strings.Contains(text, "critical") || strings.Contains(text, "unhealthy") {
			return "firing"
		}
	}
	return ""
}

func SourceMatches(sourceKind string, inputKind string) bool {
	switch sourceKind {
	case "any":
		return inputKind == "message" || inputKind == "mention" ||
			inputKind == "bot_message"
	case "human":
		return inputKind == "message" || inputKind == "mention"
	case "app":
		return inputKind == "bot_message"
	default:
		return false
	}
}

func LegacyTextMatches(trigger string, text string) bool {
	switch trigger {
	case "terraform_plan", "terraform_lifecycle":
		return EventTextMatches("terraform_run", text)
	case "deployment":
		return EventTextMatches("deployment", text)
	case "operational_alert":
		return EventTextMatches("operational_alert", text)
	default:
		return false
	}
}

// Evaluate explains every active rule, including rules skipped for source,
// event, or lifecycle state. matchedRules is the admission result; root is the
// optional thread starter used by thread-aware matching.
func Evaluate(
	rules []core.StandingRule,
	matchedRules []core.StandingRule,
	input core.SlackInput,
	root core.SlackInput,
) core.StandingRuleEvaluationAudit {
	matchedIDs := make(map[string]bool, len(matchedRules))
	for _, rule := range matchedRules {
		matchedIDs[rule.ID] = true
	}
	result := core.StandingRuleEvaluationAudit{Checked: len(rules)}
	for _, rule := range rules {
		workflow, _, _, normalizeErr := core.NormalizeStandingWorkflow(rule.Workflow, rule.Trigger, rule.Action)
		name := rule.WorkflowName
		if name == "" && normalizeErr == nil {
			name = workflow.Name
		}
		matched, why := Match(rule, input)
		if matchedIDs[rule.ID] && !matched && root.ID != "" {
			if rootMatched, rootWhy := Match(rule, root); rootMatched {
				matched, why = true, "Matched the thread starter. "+rootWhy
			}
		}
		if matchedIDs[rule.ID] {
			if !matched {
				why = "Matched the saved channel rule."
			}
			matched = true
		}
		trigger, work, delivery := "This saved rule is invalid.", "Nothing runs.", "Nothing is posted."
		if normalizeErr == nil {
			trigger = core.StandingWorkflowTriggerEffect(workflow, rule.SourceKind)
			work = core.StandingWorkflowWork(workflow)
			delivery = core.StandingWorkflowDeliveryEffect(workflow)
		}
		if matched {
			result.Matched++
		}
		result.Rules = append(result.Rules, core.StandingRuleEvaluation{
			RuleID: rule.ID, Name: name, Matched: matched, Trigger: trigger,
			Why: why, Work: work, Delivery: delivery,
		})
	}
	return result
}

func sourceLabel(sourceKind string) string {
	switch sourceKind {
	case "app":
		return "app messages"
	case "human":
		return "messages from people"
	default:
		return "messages from people or apps"
	}
}

func inputSourceLabel(inputKind string) string {
	if inputKind == "bot_message" {
		return "an app message"
	}
	return "a message from a person"
}

func eventLabel(event string) string {
	switch event {
	case "terraform_run":
		return "Terraform run updates"
	case "deployment":
		return "deployment updates"
	case "operational_alert":
		return "operational alerts"
	default:
		return "a supported event"
	}
}

func statesLabel(states []string) string {
	values := make([]string, len(states))
	for index, state := range states {
		values[index] = strings.ReplaceAll(state, "_", " ")
	}
	return strings.Join(values, " or ")
}
