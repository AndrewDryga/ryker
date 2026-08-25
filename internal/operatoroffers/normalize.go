// Package operatoroffers normalizes the group of confirmable behavior offers
// carried by either Responder result dialect.
package operatoroffers

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/behavioroffer"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/standingrule"
)

// Offers is the operator-confirmable offer set carried by either a watch
// decision or an incident report.
type Offers struct {
	Memory     *core.MemoryOffer
	Preference *core.PreferenceOffer
	Rule       *core.RuleOffer
	Schedule   *core.ScheduleOffer
	Schedules  []*core.ScheduleOffer
}

// Normalize compiles host-owned preference and standing-rule offers once for
// both result dialects. Memory offers keep the model's independent answer;
// preference/rule-only requests use the host-written acknowledgement.
func Normalize(input core.SlackInput, repository string, offers Offers) (Offers, string, bool) {
	if offer, ok := decision.NormalizeTerraformLifecycleRule(input, repository, offers.Rule); ok {
		offers.Rule = offer
	}
	if offer, ok := normalizeOperationalAlertRule(input, repository, offers.Rule); ok {
		offers.Rule = offer
	}
	offer, locationAcknowledgement, locationRequest := behavioroffer.NormalizeLocation(input.Text, offers.Preference)
	if locationRequest {
		offers.Preference = offer
	}
	if !behavioroffer.ExplicitRequest(input.Text) ||
		(offers.Preference == nil && offers.Rule == nil && offers.Memory == nil) {
		return offers, "", false
	}
	if offers.Memory != nil {
		return offers, "", false
	}
	acknowledgement := "I can remember that. Confirm below."
	if offers.Preference != nil && offers.Rule != nil {
		acknowledgement = "I can remember both. Confirm below."
	} else if offers.Rule != nil {
		acknowledgement = "I can monitor that for this channel. Confirm below."
	} else if locationRequest {
		acknowledgement = locationAcknowledgement
	}
	return offers, acknowledgement, true
}

func normalizeOperationalAlertRule(
	input core.SlackInput,
	repository string,
	proposed *core.RuleOffer,
) (*core.RuleOffer, bool) {
	if !decision.StandingRuleAssignment(input.Text) ||
		!standingrule.EventTextMatches("operational_alert", input.Text) {
		return proposed, false
	}
	if proposed != nil && proposed.Workflow == nil &&
		(proposed.Trigger != "operational_alert" || proposed.Action != "triage_alert") {
		return proposed, false
	}
	workflow, _ := core.LegacyStandingWorkflow("operational_alert", "triage_alert")
	if proposed != nil && proposed.Workflow != nil {
		if proposed.Workflow.Trigger.Event != "operational_alert" {
			return proposed, false
		}
		workflow = *proposed.Workflow
	}
	offer := core.RuleOffer{
		Scope: "channel", Repository: strings.TrimSpace(repository),
		Workflow: &workflow,
		Trigger:  "operational_alert", Action: "triage_alert",
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
