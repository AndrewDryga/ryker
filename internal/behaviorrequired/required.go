// Package behaviorrequired rejects durable-sounding acknowledgements that do
// not carry a confirmable typed offer.
package behaviorrequired

import (
	"github.com/AndrewDryga/responder/internal/behavioroffer"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/operatoroffers"
)

// Correction covers guidance, preferences and standing rules. New schedules
// intentionally do not use cadence-word matching: "why is the daily runbook
// broken?" describes an existing task and must not manufacture a duplicate.
func Correction(
	operator bool,
	input core.SlackInput,
	repository string,
	result decision.WatchDecision,
) string {
	if !operator || (!behavioroffer.PreferenceRequest(input.Text) &&
		!behavioroffer.MemoryRequest(input.Text) &&
		!decision.StandingRuleAssignment(input.Text)) {
		return ""
	}
	offers, _, _ := operatoroffers.Normalize(input, repository, operatoroffers.Offers{
		Memory: result.MemoryOffer, Preference: result.PreferenceOffer,
		Rule: result.RuleOffer, Schedule: result.ScheduleOffer,
		Schedules: result.ScheduleOffers,
	})
	if offers.Memory != nil || offers.Preference != nil || offers.Rule != nil ||
		offers.Schedule != nil || len(offers.Schedules) > 0 {
		return ""
	}
	return "the operator explicitly requested lasting behavior, but the result contains no " +
		"typed memory, preference, or standing-rule offer they can confirm; return the " +
		"answer with the appropriate typed offer, or explain why this request cannot be saved"
}
