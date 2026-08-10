package core

import (
	"errors"
	"fmt"
	"slices"
	"strings"
)

const StandingWorkflowVersion = 1

// StandingWorkflow is the operator-confirmed, read-only program behind a
// standing rule. The model may propose this document, but the host validates
// every trigger, step, and delivery condition before it can be saved or run.
type StandingWorkflow struct {
	Version  int                      `json:"version"`
	Name     string                   `json:"name"`
	Trigger  StandingWorkflowTrigger  `json:"trigger"`
	Steps    []string                 `json:"steps"`
	Delivery StandingWorkflowDelivery `json:"delivery"`
}

type StandingWorkflowTrigger struct {
	Event  string   `json:"event"`
	States []string `json:"states,omitempty"`
}

type StandingWorkflowDelivery struct {
	Location            string   `json:"location"`
	ReplyWhen           []string `json:"reply_when,omitempty"`
	MentionOperatorWhen []string `json:"mention_operator_when,omitempty"`
	QuietWhen           []string `json:"quiet_when,omitempty"`
	Acknowledge         string   `json:"acknowledge,omitempty"`
}

// StandingRuleEvaluationAudit is the operator-facing explanation of one rule
// matching pass. It deliberately stores plain-language reasons and effects so
// the execution trace does not need to reverse-engineer behavior from internal
// rule IDs later.
type StandingRuleEvaluationAudit struct {
	Checked      int                      `json:"checked"`
	Matched      int                      `json:"matched"`
	Acknowledged string                   `json:"acknowledged,omitempty"`
	Rules        []StandingRuleEvaluation `json:"rules"`
}

type StandingRuleEvaluation struct {
	RuleID   string `json:"rule_id"`
	Name     string `json:"name"`
	Matched  bool   `json:"matched"`
	Trigger  string `json:"trigger"`
	Why      string `json:"why"`
	Work     string `json:"work"`
	Delivery string `json:"delivery"`
}

// LegacyStandingWorkflow maps every rule saved before workflow documents were
// introduced to the same behavior it already had. It is also the source of
// defaults for terse model proposals.
func LegacyStandingWorkflow(trigger string, action string) (StandingWorkflow, error) {
	switch trigger + "/" + action {
	case "terraform_plan/review_terraform_plan":
		return StandingWorkflow{
			Version: StandingWorkflowVersion, Name: "Review Terraform plans",
			Trigger: StandingWorkflowTrigger{Event: "terraform_run"},
			Steps:   []string{"review_terraform_plan"},
			Delivery: StandingWorkflowDelivery{
				Location: "source_thread", Acknowledge: "eyes",
				ReplyWhen: []string{"useful_finding", "approval_ready", "blocked"},
				QuietWhen: []string{"intermediate", "duplicate", "no_material_change"},
			},
		}, nil
	case "terraform_lifecycle/monitor_terraform_lifecycle":
		return StandingWorkflow{
			Version: StandingWorkflowVersion, Name: "Follow Terraform runs",
			Trigger: StandingWorkflowTrigger{Event: "terraform_run"},
			Steps: []string{
				"review_terraform_plan", "follow_terraform_run",
				"verify_post_apply_health", "diagnose_terraform_failure",
			},
			Delivery: StandingWorkflowDelivery{
				Location: "source_thread", Acknowledge: "eyes",
				ReplyWhen: []string{
					"useful_finding", "approval_ready", "terminal_failure", "terminal_success", "blocked",
				},
				MentionOperatorWhen: []string{"failure", "approval_required"},
				QuietWhen:           []string{"intermediate", "duplicate", "no_material_change"},
			},
		}, nil
	case "deployment/verify_deployment":
		return StandingWorkflow{
			Version: StandingWorkflowVersion, Name: "Verify deployments",
			Trigger: StandingWorkflowTrigger{Event: "deployment"},
			Steps:   []string{"verify_deployment"},
			Delivery: StandingWorkflowDelivery{
				Location:            "source_thread",
				ReplyWhen:           []string{"useful_finding", "terminal_failure", "terminal_success", "blocked"},
				MentionOperatorWhen: []string{"failure"},
				QuietWhen:           []string{"intermediate", "duplicate", "no_material_change"},
			},
		}, nil
	case "operational_alert/triage_alert":
		return StandingWorkflow{
			Version: StandingWorkflowVersion, Name: "Investigate operational alerts",
			Trigger: StandingWorkflowTrigger{Event: "operational_alert"},
			Steps:   []string{"triage_alert", "suggest_remediation"},
			Delivery: StandingWorkflowDelivery{
				Location: "source_thread", Acknowledge: "eyes",
				ReplyWhen:           []string{"useful_finding", "confirmed_issue", "disproved", "blocked"},
				MentionOperatorWhen: []string{"critical"},
				QuietWhen:           []string{"duplicate", "resolved_without_impact"},
			},
		}, nil
	default:
		return StandingWorkflow{}, fmt.Errorf("standing rule pair %q/%q is invalid", trigger, action)
	}
}

// StandingWorkflowEffect explains the observable behavior of a confirmed
// workflow. It is shared by Slack configuration cards and execution traces so
// operators see the same contract before and after enabling it.
func StandingWorkflowEffect(workflow StandingWorkflow) string {
	work := StandingWorkflowWork(workflow)
	delivery := StandingWorkflowDeliveryEffect(workflow)
	if delivery == "" {
		return work
	}
	return strings.TrimSuffix(work, ".") + ". " + delivery
}

// StandingWorkflowTriggerEffect describes the typed event filter without
// exposing the legacy trigger/action identifiers used by storage.
func StandingWorkflowTriggerEffect(workflow StandingWorkflow, sourceKind string) string {
	source := standingWorkflowSource(sourceKind)
	event := standingWorkflowEvent(workflow.Trigger.Event)
	result := source + " about " + event
	if len(workflow.Trigger.States) > 0 {
		states := make([]string, 0, len(workflow.Trigger.States))
		for _, state := range workflow.Trigger.States {
			states = append(states, standingWorkflowCondition(state))
		}
		result += " when the state is " + joinNatural(states)
	}
	return sentenceCase(result) + "."
}

// StandingWorkflowWork describes only the checks which a match starts. Keeping
// it separate from delivery makes rule traces answer "what runs" and "what is
// posted" independently.
func StandingWorkflowWork(workflow StandingWorkflow) string {
	actions := make([]string, 0, len(workflow.Steps))
	for _, step := range workflow.Steps {
		switch step {
		case "review_terraform_plan":
			actions = append(actions, "reviews the saved plan and checks the Terraform changes for red flags")
		case "follow_terraform_run":
			actions = append(actions, "follows the run to a final result")
		case "verify_post_apply_health":
			actions = append(actions, "checks the affected systems after apply")
		case "diagnose_terraform_failure":
			actions = append(actions, "investigates failed applies")
		case "verify_deployment":
			actions = append(actions, "checks the deployed revision and service health")
		case "triage_alert":
			actions = append(actions, "checks current evidence to decide whether the alert is a real issue")
		case "suggest_remediation":
			actions = append(actions, "suggests the safest immediate step for critical alerts and focused fixes for the underlying problem")
		}
	}
	effect := joinNatural(actions)
	if effect == "" {
		effect = "performs its configured read-only checks"
	}
	return sentenceCase(effect) + "."
}

// StandingWorkflowDeliveryEffect describes the visible consequences of a
// match. Conditions remain typed internally but are presented as normal Slack
// language here and on configuration cards.
func StandingWorkflowDeliveryEffect(workflow StandingWorkflow) string {
	parts := make([]string, 0, 4)
	if workflow.Delivery.Acknowledge != "" && workflow.Delivery.Acknowledge != "none" {
		parts = append(parts, "adds "+standingWorkflowReaction(workflow.Delivery.Acknowledge)+" while it checks")
	}
	if workflow.Delivery.Location == "source_thread" {
		parts = append(parts, standingWorkflowReplyEffect(workflow.Delivery.ReplyWhen))
	} else if workflow.Delivery.Location == "follow_context" {
		parts = append(parts, "replies where the conversation is already happening")
	}
	if len(workflow.Delivery.QuietWhen) > 0 {
		conditions := make([]string, 0, len(workflow.Delivery.QuietWhen))
		for _, condition := range workflow.Delivery.QuietWhen {
			conditions = append(conditions, standingWorkflowCondition(condition))
		}
		parts = append(parts, "stays quiet for "+joinNatural(conditions))
	}
	if len(workflow.Delivery.MentionOperatorWhen) > 0 {
		conditions := make([]string, 0, len(workflow.Delivery.MentionOperatorWhen))
		for _, condition := range workflow.Delivery.MentionOperatorWhen {
			conditions = append(conditions, standingWorkflowCondition(condition))
		}
		parts = append(parts, "tags the rule owner for "+joinNatural(conditions))
	}
	if len(parts) == 0 {
		return ""
	}
	result := joinNatural(parts)
	return sentenceCase(result) + "."
}

func sentenceCase(value string) string {
	runes := []rune(value)
	if len(runes) == 0 {
		return ""
	}
	return strings.ToUpper(string(runes[0])) + string(runes[1:])
}

func standingWorkflowReplyEffect(conditions []string) string {
	if len(conditions) == 0 {
		return "replies in the source message's thread when it has a useful result"
	}
	values := make([]string, 0, len(conditions))
	for _, condition := range conditions {
		values = append(values, standingWorkflowCondition(condition))
	}
	return "replies in the source message's thread for " + joinNatural(values)
}

func standingWorkflowSource(sourceKind string) string {
	switch sourceKind {
	case "app":
		return "app messages"
	case "human":
		return "messages from people"
	default:
		return "messages from people or apps"
	}
}

func standingWorkflowEvent(event string) string {
	switch event {
	case "terraform_run":
		return "Terraform runs"
	case "deployment":
		return "deployments"
	case "operational_alert":
		return "operational alerts"
	default:
		return "supported events"
	}
}

func standingWorkflowCondition(condition string) string {
	if label := map[string]string{
		"useful_finding":          "a useful finding",
		"approval_ready":          "a plan ready for approval",
		"terminal_failure":        "a final failure",
		"terminal_success":        "a final success",
		"confirmed_issue":         "a confirmed issue",
		"disproved":               "a disproved alert",
		"blocked":                 "a blocker",
		"failure":                 "a failure",
		"critical":                "a critical issue",
		"approval_required":       "an approval",
		"intermediate":            "progress-only updates",
		"duplicate":               "duplicates",
		"no_material_change":      "updates with no material change",
		"resolved_without_impact": "alerts that resolved without impact",
	}[condition]; label != "" {
		return label
	}
	return strings.ReplaceAll(condition, "_", " ")
}

func standingWorkflowReaction(name string) string {
	if emoji := map[string]string{
		"eyes":             "👀",
		"white_check_mark": "✅",
		"heavy_check_mark": "✔️",
	}[name]; emoji != "" {
		return emoji
	}
	return ":" + name + ":"
}

func joinNatural(values []string) string {
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

// NormalizeStandingWorkflow fills harmless presentation and delivery defaults,
// then derives the legacy trigger/action identity still used by existing
// lifecycle code. It never widens the allowed read-only capability catalog.
func NormalizeStandingWorkflow(
	workflow StandingWorkflow,
	legacyTrigger string,
	legacyAction string,
) (StandingWorkflow, string, string, error) {
	legacyTrigger = strings.ToLower(strings.TrimSpace(legacyTrigger))
	legacyAction = strings.ToLower(strings.TrimSpace(legacyAction))
	if workflow.Trigger.Event == "" {
		compiled, err := LegacyStandingWorkflow(legacyTrigger, legacyAction)
		return compiled, legacyTrigger, legacyAction, err
	}
	workflow.Version = StandingWorkflowVersion
	workflow.Name = strings.TrimSpace(workflow.Name)
	workflow.Trigger.Event = strings.ToLower(strings.TrimSpace(workflow.Trigger.Event))
	workflow.Trigger.States = normalizedList(workflow.Trigger.States)
	workflow.Steps = normalizedList(workflow.Steps)
	workflow.Delivery.Location = strings.ToLower(strings.TrimSpace(workflow.Delivery.Location))
	workflow.Delivery.ReplyWhen = normalizedList(workflow.Delivery.ReplyWhen)
	workflow.Delivery.MentionOperatorWhen = normalizedList(workflow.Delivery.MentionOperatorWhen)
	workflow.Delivery.QuietWhen = normalizedList(workflow.Delivery.QuietWhen)
	workflow.Delivery.Acknowledge = strings.Trim(
		strings.ToLower(strings.TrimSpace(workflow.Delivery.Acknowledge)), ":",
	)

	trigger, action := primaryLegacyRule(workflow)
	if trigger == "" {
		return StandingWorkflow{}, "", "", errors.New("standing workflow has no supported primary action")
	}
	defaults, err := LegacyStandingWorkflow(trigger, action)
	if err != nil {
		return StandingWorkflow{}, "", "", err
	}
	if workflow.Name == "" {
		workflow.Name = defaults.Name
	}
	if workflow.Delivery.Location == "" {
		workflow.Delivery.Location = defaults.Delivery.Location
	}
	if len(workflow.Delivery.ReplyWhen) == 0 {
		workflow.Delivery.ReplyWhen = defaults.Delivery.ReplyWhen
	}
	if len(workflow.Delivery.QuietWhen) == 0 {
		workflow.Delivery.QuietWhen = defaults.Delivery.QuietWhen
	}
	if workflow.Delivery.Acknowledge == "" {
		workflow.Delivery.Acknowledge = defaults.Delivery.Acknowledge
	}
	if err := ValidateStandingWorkflow(workflow); err != nil {
		return StandingWorkflow{}, "", "", err
	}
	return workflow, trigger, action, nil
}

func ValidateStandingWorkflow(workflow StandingWorkflow) error {
	if workflow.Version != StandingWorkflowVersion {
		return fmt.Errorf("standing workflow version %d is unsupported", workflow.Version)
	}
	if workflow.Name == "" || len(workflow.Name) > 80 {
		return errors.New("standing workflow name must be between 1 and 80 characters")
	}
	var allowedStates map[string]bool
	var allowedSteps map[string]bool
	switch workflow.Trigger.Event {
	case "terraform_run":
		allowedStates = stringSet("planning", "planned", "applying", "applied", "errored", "discarded")
		allowedSteps = stringSet(
			"review_terraform_plan", "follow_terraform_run",
			"verify_post_apply_health", "diagnose_terraform_failure",
		)
	case "deployment":
		allowedStates = stringSet("started", "completed", "failed")
		allowedSteps = stringSet("verify_deployment")
	case "operational_alert":
		allowedStates = stringSet("firing", "resolved")
		allowedSteps = stringSet("triage_alert", "suggest_remediation")
	default:
		return fmt.Errorf("standing workflow event %q is unsupported", workflow.Trigger.Event)
	}
	if err := validateValues("trigger state", workflow.Trigger.States, allowedStates); err != nil {
		return err
	}
	if len(workflow.Steps) == 0 || len(workflow.Steps) > 8 {
		return errors.New("standing workflow must contain between 1 and 8 steps")
	}
	if err := validateValues("step", workflow.Steps, allowedSteps); err != nil {
		return err
	}
	if workflow.Delivery.Location != "source_thread" && workflow.Delivery.Location != "follow_context" {
		return fmt.Errorf("standing workflow delivery location %q is unsupported", workflow.Delivery.Location)
	}
	if err := validateValues("reply condition", workflow.Delivery.ReplyWhen, stringSet(
		"useful_finding", "approval_ready", "terminal_failure", "terminal_success",
		"confirmed_issue", "disproved", "blocked",
	)); err != nil {
		return err
	}
	if err := validateValues("mention condition", workflow.Delivery.MentionOperatorWhen, stringSet(
		"failure", "critical", "approval_required",
	)); err != nil {
		return err
	}
	if err := validateValues("quiet condition", workflow.Delivery.QuietWhen, stringSet(
		"intermediate", "duplicate", "no_material_change", "resolved_without_impact",
	)); err != nil {
		return err
	}
	if workflow.Delivery.Acknowledge != "" && len(workflow.Delivery.Acknowledge) > 64 {
		return errors.New("standing workflow acknowledgement is too long")
	}
	return nil
}

func primaryLegacyRule(workflow StandingWorkflow) (string, string) {
	switch workflow.Trigger.Event {
	case "terraform_run":
		if slices.Contains(workflow.Steps, "follow_terraform_run") ||
			slices.Contains(workflow.Steps, "verify_post_apply_health") ||
			slices.Contains(workflow.Steps, "diagnose_terraform_failure") {
			return "terraform_lifecycle", "monitor_terraform_lifecycle"
		}
		if slices.Contains(workflow.Steps, "review_terraform_plan") {
			return "terraform_plan", "review_terraform_plan"
		}
	case "deployment":
		if slices.Contains(workflow.Steps, "verify_deployment") {
			return "deployment", "verify_deployment"
		}
	case "operational_alert":
		if slices.Contains(workflow.Steps, "triage_alert") {
			return "operational_alert", "triage_alert"
		}
	}
	return "", ""
}

func normalizedList(values []string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		value = strings.ToLower(strings.TrimSpace(value))
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

func stringSet(values ...string) map[string]bool {
	result := make(map[string]bool, len(values))
	for _, value := range values {
		result[value] = true
	}
	return result
}

func validateValues(name string, values []string, allowed map[string]bool) error {
	for _, value := range values {
		if !allowed[value] {
			return fmt.Errorf("standing workflow %s %q is unsupported", name, value)
		}
	}
	return nil
}
