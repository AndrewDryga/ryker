package service

import (
	"context"
	"encoding/json"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// replyShapeCorrection applies the host's reply-shape rules and spends their
// budget, reporting the correction to send back and whether it consumed the
// one retry this turn is allowed.
//
// One retry, and then the answer ships whatever shape it is in. A rejected
// reply costs a full extra turn, and an operator who asked a question and
// received nothing is worse off than one who received too many words: a
// quality rule that eats answers is not a quality rule. The second failure is
// recorded instead of enforced, because a rule that quietly stops applying is
// worse than no rule — the rate has to be visible for anyone to know the bound
// is doing anything.
func (s *Service) replyShapeCorrection(
	ctx context.Context,
	run core.AgentRun,
	trigger, lane, action, message string,
	spent int,
) (string, bool) {
	correction := decisionpkg.RuntimeReplyShapeCorrection(trigger, lane, action, message)
	switch {
	case correction == "":
		return "", false
	case spent > 0:
		s.recordUnshapedReply(ctx, run, correction)
		return "", false
	default:
		return correction, true
	}
}

// incidentReplyShapeCorrection is the same one-retry budget for an incident or
// engineering-task turn, whose count lives in the assembled run context rather
// than in the watch turn state.
func (s *Service) incidentReplyShapeCorrection(
	ctx context.Context,
	run core.AgentRun,
	trigger, message string,
) (string, error) {
	assembled, ok := decodeAssembledAgentContext(run.Context)
	if !ok {
		// There is nowhere to write the count, so a correction sent now would
		// be sent again on every attempt. An unbounded rewrite loop costs the
		// operator more than one long answer does.
		return "", nil
	}
	correction, shaped := s.replyShapeCorrection(
		ctx, run, trigger, "incident", "reply", message, assembled.ReplyShapeCorrections,
	)
	if !shaped {
		return "", nil
	}
	assembled.ReplyShapeCorrections++
	contextJSON, err := json.Marshal(assembled)
	if err != nil {
		return "", err
	}
	if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
		return "", err
	}
	return correction, nil
}

// recordUnshapedReply records a reply posted after its correction was spent.
//
// Audited rather than only logged: `result.correction` already makes the
// refusals countable per class, and without its counterpart the two look
// identical from the outside — a bound nobody trips and a bound nobody obeys
// both read as zero corrections.
func (s *Service) recordUnshapedReply(
	ctx context.Context,
	run core.AgentRun,
	correction string,
) {
	s.audit(ctx, core.AuditEvent{
		IncidentID: run.IncidentID,
		Kind:       "result.uncorrected",
		ActorID:    "responder",
		ObjectID:   run.ID,
		Outcome:    string(correctionShape),
		Detail:     s.sanitizeText(decisionpkg.BoundedField(correction, 500)),
	})
	if s.log != nil {
		s.log.Warn(
			"posted a reply that still fails its shape rule after one correction",
			"run", run.ID,
			"detail", correction,
		)
	}
}
