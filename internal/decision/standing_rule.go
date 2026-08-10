package decision

import (
	"regexp"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/standingrule"
)

var (
	standingRuleAssignmentPattern = regexp.MustCompile(
		`(?i)\b(?:when(?:ever)?\s+you\s+(?:see|receive|notice)|` +
			`for\s+(?:each|every)\s+(?:new\s+)?message|every\s+time|` +
			`(?:in|for)\s+this\s+channel[^\n]{0,240}\balerts\b|` +
			`\balerts\b[^\n]{0,240}(?:in|for)\s+this\s+channel)\b`,
	)
)

func StandingRuleAssignment(text string) bool {
	return standingRuleAssignmentPattern.MatchString(text) ||
		TerraformLifecycleAssignment(text)
}

func TerraformLifecycleAssignment(text string) bool {
	return standingrule.TerraformLifecycleAssignment(text)
}

// NormalizeTerraformLifecycleRule compiles natural lifecycle assignments into
// the one typed rule that carries them across future Terraform notifications.
func NormalizeTerraformLifecycleRule(input core.SlackInput, repository string, proposed *core.RuleOffer) (*core.RuleOffer, bool) {
	return standingrule.NormalizeTerraformLifecycleOffer(input, repository, proposed)
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
