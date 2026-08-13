package service

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	schedulepkg "github.com/AndrewDryga/responder/internal/schedule"
)

// offerCheck is one offer the host will not accept, paired with the reason and
// the ability to take it off the reply.
type offerCheck struct {
	kind     string
	rejected error
	clear    func()
}

// rejectedOffers reports which of the offers on a reply the host will not
// accept, in the order the persistence path considers them.
//
// Both callers read from this one list on purpose. The correction path names
// what to fix; the drop path removes what was never fixed. If those two ever
// disagreed about which offers count, a turn could be corrected for an offer
// that is never dropped — requeueing until it runs out of attempts — or an
// offer could be dropped that the model was never told about. One traversal
// makes that disagreement impossible to write.
//
// Only offers the host would actually try to store are considered. An offer is
// also refused when the requester is not an operator, never asked for one, or
// is sending a kind of message that cannot carry one, and none of that is the
// model's to fix. A schedule_offer, for instance, rides along with the
// activation of an established schedule, where the host never reads it as a
// new schedule at all.
func (s *Service) rejectedOffers(
	ctx context.Context,
	input core.SlackInput,
	decision *decisionpkg.WatchDecision,
) []offerCheck {
	// Matching the persistence path's clock exactly: these validators compare
	// against it to reject a lifetime that ends before it starts.
	now := s.now().UTC()
	rejected := make([]offerCheck, 0, 4)
	if offer := decision.RuleOffer; offer != nil && s.ruleOfferInScope(input) {
		repository := s.cfg.Slack.DefaultRepository
		if s.store != nil {
			resolved, err := s.effectiveRepository(
				ctx, input.ChannelID, input.UserID, repository,
			)
			if err == nil {
				repository = resolved
			}
		}
		decision.RuleOffer = decisionpkg.NormalizeStandingRule(input, repository, offer)
		offer = decision.RuleOffer
		if _, _, err := s.standingRuleFromOffer(input, *offer, now); err != nil {
			rejected = append(rejected, offerCheck{
				kind: "standing rule", rejected: err,
				clear: func() { decision.RuleOffer = nil },
			})
		}
	}
	if offer := decision.PreferenceOffer; offer != nil && s.preferenceOfferInScope(input) {
		if _, _, err := s.preferenceFromOffer(input, *offer, now); err != nil {
			rejected = append(rejected, offerCheck{
				kind: "preference", rejected: err,
				clear: func() { decision.PreferenceOffer = nil },
			})
		}
	}
	if offer := decision.MemoryOffer; offer != nil && s.memoryOfferInScope(input) {
		if _, _, err := s.memoryEntryFromOffer(input, *offer, now); err != nil {
			rejected = append(rejected, offerCheck{
				kind: "memory", rejected: err,
				clear: func() { decision.MemoryOffer = nil },
			})
		}
	}
	if offers := OrderedScheduleOffers(decision.ScheduleOffer, decision.ScheduleOffers); len(offers) != 0 && s.scheduleOfferInScope(input) {
		if err := s.scheduleBatchMatchesRequest(ctx, input, offers, now); err != nil {
			rejected = append(rejected, offerCheck{
				kind: "scheduled task batch", rejected: err,
				clear: func() {
					decision.ScheduleOffer = nil
					decision.ScheduleOffers = nil
				},
			})
			return rejected
		}
		for _, offer := range offers {
			if _, err := s.scheduledTaskFromOffer(ctx, input, *offer, now); err == nil {
				continue
			} else {
				rejected = append(rejected, offerCheck{
					kind: "scheduled task batch", rejected: err,
					clear: func() {
						decision.ScheduleOffer = nil
						decision.ScheduleOffers = nil
					},
				})
				break
			}
		}
	}
	return rejected
}

// scheduleBatchMatchesRequest checks the proposed occurrences against the ones
// the operator actually named.
//
// "Check tomorrow and in 3 days" came back as three checks at one, two and four
// days out, and every host validation passed: each offer was a well-formed
// future one-time schedule and the batch was inside its size limit. Nothing
// compared the batch with the request, so a schedule nobody asked for only had
// to be syntactically valid to be confirmed.
//
// Only requests with unambiguous relative days are checked. Anything else is
// left to the per-offer validation that was already there.
func (s *Service) scheduleBatchMatchesRequest(
	ctx context.Context,
	input core.SlackInput,
	offers []*core.ScheduleOffer,
	now time.Time,
) error {
	wanted := schedulepkg.RequestedDayOffsets(input.Text)
	if len(wanted) == 0 {
		return nil
	}
	proposed := map[int]bool{}
	for _, offer := range offers {
		task, err := s.scheduledTaskFromOffer(ctx, input, *offer, now)
		if err != nil || task.Recurrence != "once" {
			// A recurring offer answers a different shape of request, and a
			// malformed one is already reported by the per-offer check.
			return nil
		}
		location := schedulepkg.MustLocation(task.Timezone)
		asked := now.In(location)
		days := int(task.NextRunAt.In(location).Truncate(24*time.Hour).
			Sub(asked.Truncate(24*time.Hour)).Hours() / 24)
		proposed[days] = true
	}
	if len(proposed) == len(wanted) {
		matched := true
		for _, day := range wanted {
			matched = matched && proposed[day]
		}
		if matched {
			return nil
		}
	}
	return fmt.Errorf(
		"the request named %d check(s), at %s from now, and the batch proposes %d at %s; "+
			"return exactly the occurrences that were asked for, at a consistent local time",
		len(wanted), dayList(wanted), len(offers), dayList(sortedDays(proposed)),
	)
}

func sortedDays(days map[int]bool) []int {
	out := make([]int, 0, len(days))
	for day := range days {
		out = append(out, day)
	}
	sort.Ints(out)
	return out
}

func dayList(days []int) string {
	parts := make([]string, 0, len(days))
	for _, day := range days {
		parts = append(parts, strconv.Itoa(day)+"d")
	}
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, ", ")
}

// offerRejectionCorrection tells the model what is wrong with an offer it
// attached to its reply, in the words it needs to fix it.
//
// Every offer is validated by the host before it is stored. Until now a
// rejected offer was dropped where it was found and the reply went out anyway:
// the user was told a rule had been captured, and no rule had been captured.
// The model never learned it had built something malformed, so it built the
// same malformed thing the next time.
//
// This runs one turn earlier — before anything is written and before the reply
// is sent — so a rejection becomes another pass rather than a silent hole.
//
// The two ways out are both spelled out, because the right move is often the
// second one: an offer that cannot be stated correctly should be dropped, not
// forced. Without that sentence the model rewrites a malformed offer until it
// passes rather than asking whether the offer belonged in the reply at all.
func (s *Service) offerRejectionCorrection(
	ctx context.Context,
	input core.SlackInput,
	decision decisionpkg.WatchDecision,
) string {
	rejected := s.rejectedOffers(ctx, input, &decision)
	if len(rejected) == 0 {
		return ""
	}
	return "the " + rejected[0].kind + " you offered was rejected: " +
		trimError(rejected[0].rejected) +
		". Fix the offer and send the reply again, or send the reply without" +
		" the offer if it cannot be stated correctly — but do not tell the" +
		" user something was saved when it was not."
}

// dropRejectedOffers takes the offers the host will not accept off the reply,
// once the model has had its retries and still could not state one correctly.
//
// Only the offers that actually fail are removed: a turn can carry a good
// memory and a bad rule, and dropping both would lose something the user asked
// for. The reply itself is untouched, because it was never the problem.
//
// The operator is told, at warning level with the run attached. This is the
// one path where the product knowingly does less than the reply implies, and
// it should be visible when it happens rather than inferred later from a
// missing rule.
func (s *Service) dropRejectedOffers(
	ctx context.Context,
	input core.SlackInput,
	decision *decisionpkg.WatchDecision,
	run core.AgentRun,
) {
	rejected := s.rejectedOffers(ctx, input, decision)
	if len(rejected) == 0 {
		return
	}
	kinds := make([]string, 0, len(rejected))
	for _, offer := range rejected {
		offer.clear()
		kinds = append(kinds, offer.kind)
	}
	if s.log != nil {
		s.log.Warn(
			"dropped offers the model could not state correctly",
			"run", run.ID,
			"channel", input.ChannelID,
			"dropped", strings.Join(kinds, ", "),
		)
	}
}

// The four gates below decide whether the host would even try to store an
// offer: they are the conditions under which the model is expected to get one
// right.
//
// They are named predicates because two callers need the same answer. The
// persistence path uses them to decide whether to store; the correction path
// uses them to decide whether a rejection is the model's to fix. When these
// lived inline in the persistence path only, the correction path re-derived
// them — and got the schedule case wrong, correcting the model for a
// schedule_offer that arrives with an activation.

func (s *Service) ruleOfferInScope(input core.SlackInput) bool {
	return s.cfg.IsOperator(input.UserID) &&
		decisionpkg.StandingRuleAssignment(input.Text)
}

func (s *Service) preferenceOfferInScope(input core.SlackInput) bool {
	return s.cfg.IsOperator(input.UserID) &&
		explicitPreferenceRequestPattern.MatchString(input.Text)
}

func (s *Service) memoryOfferInScope(input core.SlackInput) bool {
	return s.cfg.IsOperator(input.UserID) &&
		explicitMemoryRequestPattern.MatchString(input.Text)
}

func (s *Service) scheduleOfferInScope(input core.SlackInput) bool {
	return input.Kind != "scheduled" && s.cfg.IsOperator(input.UserID) &&
		schedulepkg.ExplicitScheduleRequest(input.Text)
}
