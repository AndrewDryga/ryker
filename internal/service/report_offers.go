package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// The conversation lane's offers, read through the traversal the watch lane
// uses.
//
// Both lanes validate the same four offers with the same rules, and until now
// only one of them said so. A malformed offer in the incident-conversation lane
// was dropped where it was found — `prepareMemoryOfferAction` returning false
// and nothing else happening — so the model was never told which field it got
// wrong and proposed the same thing next time. That is the defect the watch
// lane's offerRejectionCorrection fixed on 2026-08-16 and this lane did not get.
//
// A view rather than a second traversal, deliberately. rejectedOffers is the
// single list both the correction path and the drop path read, and its own
// comment says why: if those two ever disagreed about which offers count, a
// turn could be corrected for an offer that is never dropped — requeueing until
// it runs out of attempts. A second copy of that logic for reports would be
// exactly the disagreement it warns about, so a report borrows the decision's.

// offerView projects a report's offers into the shape rejectedOffers reads.
func offerView(report decisionpkg.AgentReport) decisionpkg.WatchDecision {
	return decisionpkg.WatchDecision{
		Action:          "reply",
		MemoryOffer:     report.MemoryOffer,
		PreferenceOffer: report.PreferenceOffer,
		RuleOffer:       report.RuleOffer,
		ScheduleOffer:   report.ScheduleOffer,
		ScheduleOffers:  report.ScheduleOffers,
	}
}

// applyOfferView copies the view's offers back, which is how a drop takes
// effect: clear() nils the field on the view, and this carries that to the
// report. It also carries the rule normalization rejectedOffers performs, so
// the offer the host validated is the offer the host then renders.
func applyOfferView(view decisionpkg.WatchDecision, report *decisionpkg.AgentReport) {
	report.MemoryOffer = view.MemoryOffer
	report.PreferenceOffer = view.PreferenceOffer
	report.RuleOffer = view.RuleOffer
	report.ScheduleOffer = view.ScheduleOffer
	report.ScheduleOffers = view.ScheduleOffers
}

// reportOfferRejectionCorrection tells the model what is wrong with an offer it
// attached to a conversational reply.
func (s *Service) reportOfferRejectionCorrection(
	ctx context.Context,
	input core.SlackInput,
	report decisionpkg.AgentReport,
) string {
	return s.offerRejectionCorrection(ctx, input, offerView(report))
}

// dropRejectedReportOffers takes the offers the host will not accept off a
// conversational reply, once the model has had its retries.
//
// The reply itself is untouched. This lane blocked on every correction class
// but shape, and blocking here would replace a correct answer with "I couldn't
// finish this check safely yet" over a malformed button — worse than the
// silence this change replaces, not better.
func (s *Service) dropRejectedReportOffers(
	ctx context.Context,
	input core.SlackInput,
	report *decisionpkg.AgentReport,
	run core.AgentRun,
) {
	view := offerView(*report)
	s.dropRejectedOffers(ctx, input, &view, run)
	applyOfferView(view, report)
}
