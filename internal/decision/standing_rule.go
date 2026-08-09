package decision

import (
	"regexp"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

var (
	standingRuleAssignmentPattern = regexp.MustCompile(
		`(?i)\b(?:when(?:ever)?\s+you\s+(?:see|receive|notice)|` +
			`for\s+(?:each|every)\s+(?:new\s+)?message|every\s+time|` +
			`(?:in|for)\s+this\s+channel[^\n]{0,240}\balerts\b|` +
			`\balerts\b[^\n]{0,240}(?:in|for)\s+this\s+channel)\b`,
	)
	terraformLifecycleAssignmentPattern = regexp.MustCompile(
		`(?is)\b(?:look\s+at|watch|monitor|follow|review|check)\b[^\n]{0,100}` +
			`\bterraform\b[^\n]{0,100}\b(?:events?|notifications?|runs?|plans?)\b` +
			`[^\n]{0,100}\b(?:in|for)\s+(?:this\s+channel|here)\b`,
	)
)

func StandingRuleAssignment(text string) bool {
	return standingRuleAssignmentPattern.MatchString(text) ||
		TerraformLifecycleAssignment(text)
}

func TerraformLifecycleAssignment(text string) bool {
	return terraformLifecycleAssignmentPattern.MatchString(text)
}

// NormalizeTerraformLifecycleRule compiles natural lifecycle assignments into
// the one typed rule that carries them across future Terraform notifications.
func NormalizeTerraformLifecycleRule(input core.SlackInput, repository string, proposed *core.RuleOffer) (*core.RuleOffer, bool) {
	if !TerraformLifecycleAssignment(input.Text) {
		return proposed, false
	}
	if proposed != nil &&
		(proposed.Trigger != "terraform_plan" || proposed.Action != "review_terraform_plan") &&
		(proposed.Trigger != "terraform_lifecycle" ||
			proposed.Action != "monitor_terraform_lifecycle") {
		return proposed, false
	}
	offer := core.RuleOffer{
		Scope: "channel", Repository: strings.TrimSpace(repository),
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

// NormalizeStandingRule adds conversation facts the host already owns. These
// are not choices for the model to guess and correct through another turn.
func NormalizeStandingRule(input core.SlackInput, repository string, proposed *core.RuleOffer) *core.RuleOffer {
	if proposed == nil {
		return nil
	}
	if offer, ok := NormalizeTerraformLifecycleRule(input, repository, proposed); ok {
		return offer
	}
	offer := *proposed
	offer.Scope = "channel"
	if strings.TrimSpace(offer.Repository) == "" {
		offer.Repository = repository
	}
	return &offer
}
