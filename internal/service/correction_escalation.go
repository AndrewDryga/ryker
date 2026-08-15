package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

// A correction that repeats is a routing decision, not a wording problem.
//
// tenant run_3a615b9db spent nineteen rounds and twenty-two minutes on one alert,
// every round class `incomplete`, and by round fifteen the host was saying
// outright "return decision_ready with the healthy verdict" — the model
// understood and could not do it. Rewording is what the correction text is for
// and it had already been tried; the remaining lever is the ladder. So the
// SECOND time one class fires on one attempt, the retry is delivered no lower
// than the next rung of the session policy's target ladder.
//
// Only the two classes that mean the answer is unusable escalate. `shape` is an
// answer that is right and reads badly — a bigger model writes the same content
// — and `rejected` is a malformed artifact attached to a sound conclusion.
// Neither is a capability problem, and moving them up the ladder would spend the
// expensive rung on a formatting note.
func correctionEscalates(class correctionClass) bool {
	return class == correctionIncomplete || class == correctionUnreadable
}

// escalationFloorForRepeats is the rung a class's nth repeat asks for.
//
// The first correction of a class is the model being told something it has not
// heard yet, so it answers on the rung it is on. From the second, each repeat
// moves up one: repeat two asks for rung 1, repeat three for rung 2.
//
// It is a floor above the rung THIS RUN has been escalated to, not a reading of
// where the session actually sits. Responder cannot see the ladder — Coop
// publishes the session's current `target` string but not the policy's list of
// them, and there is no endpoint that would resolve one against the other — so
// the honest number is the one the host itself asked for and can count. A
// session already higher than the floor does not move, because Coop treats it
// as a floor rather than a seat assignment, and a floor that names no rung is
// refused at admission, which submitTurnAtLadderFloor handles by dropping it.
func escalationFloorForRepeats(repeats int) int {
	if repeats < 2 {
		return 0
	}
	return repeats - 1
}

// escalateRepeatedCorrection counts this correction against its class and, when
// the class has now repeated, records the ladder rung the retry may not be
// answered below. It returns that rung, or zero when nothing escalated.
//
// Bookkeeping must never cost a correction. A run whose envelope cannot be
// edited still gets its retry — the correction is the useful thing, and losing
// it to a failed counter update would trade an answer for a statistic.
func (s *Service) escalateRepeatedCorrection(
	ctx context.Context,
	run core.AgentRun,
	class correctionClass,
) int {
	if !correctionEscalates(class) {
		return 0
	}
	repeats, err := s.store.NoteAgentRunCorrectionClass(ctx, run.ID, string(class))
	if err != nil {
		if s.log != nil && ctx.Err() == nil {
			s.log.Warn(
				"could not count a repeated correction class",
				"run", run.ID, "class", string(class), "error", err,
			)
		}
		return 0
	}
	floor := escalationFloorForRepeats(repeats)
	if floor <= agentRunTargetFloor(run.Context) {
		return 0
	}
	if err := s.store.SetAgentRunTargetFloor(ctx, run.ID, floor); err != nil {
		if s.log != nil && ctx.Err() == nil {
			s.log.Warn(
				"could not raise a run's model ladder floor",
				"run", run.ID, "floor", floor, "error", err,
			)
		}
		return 0
	}
	return floor
}

// escalationAuditNote is the sentence the result.correction audit event carries
// when the retry moved up the ladder, so the episode trace says why the same
// question came back on a different model rather than leaving an operator to
// infer it from the manifest.
func escalationAuditNote(class correctionClass, floor int) string {
	return fmt.Sprintf(
		"\n\n[host] %s twice on this attempt: the retry is delivered no lower "+
			"than policy ladder rung %d.", class, floor,
	)
}

// agentRunTargetFloor reads the ladder rung a run has already escalated to.
//
// Decoded as one field rather than as either whole envelope, because both of
// them carry it under the same key and neither of their shapes is this
// function's business. An envelope that will not decode reads as no floor,
// which is the ordinary turn.
func agentRunTargetFloor(contextJSON []byte) int {
	if len(contextJSON) == 0 {
		return 0
	}
	var envelope struct {
		MinTargetIndex int `json:"min_target_index,omitempty"`
	}
	if json.Unmarshal(contextJSON, &envelope) != nil || envelope.MinTargetIndex < 0 {
		return 0
	}
	return envelope.MinTargetIndex
}

// submitTurnAtLadderFloor submits a turn at or above the rung this run has
// escalated to, and degrades to an ordinary submission when Coop will not honour
// the floor.
//
// Two refusals arrive as the same 400. A Coop that predates the escalation API
// rejects the unknown field — and says only "request body is invalid JSON",
// naming nothing — while a current Coop refuses a rung its policy's ladder does
// not have, which is every single-rung deployment the moment a correction
// repeats. Both mean the same thing to this caller: the floor is not available
// here, the correction still has to be delivered, and the operator should be
// able to see that it was dropped.
//
// The retry reuses the same idempotency key deliberately. Coop resolves the
// floor before it records anything against the key, so a refused submission
// never happened as far as idempotency is concerned, and minting a second key
// for the same turn would be the thing that could double-submit it.
//
// The floor is cleared on refusal rather than kept. A floor Coop has just said
// it cannot honour would otherwise tax every ordinary retry of this run with a
// round trip that is refused again; a later repeat re-raises it, which is right
// if an operator has since added a rung.
func (s *Service) submitTurnAtLadderFloor(
	ctx context.Context,
	run core.AgentRun,
	sessionID string,
	revision int64,
	prompt string,
	artifacts []coop.InputArtifact,
) (coop.Turn, coop.Operation, error) {
	floor := agentRunTargetFloor(run.Context)
	turn, operation, err := s.coop.SubmitTurnAtOrAbove(
		ctx, run.IdempotencyKey, sessionID, revision, prompt, artifacts, floor,
	)
	if floor == 0 || !coopRefusedTargetFloor(err) {
		return turn, operation, err
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: run.IncidentID,
		Kind:       "result.correction",
		ActorID:    "responder",
		ObjectID:   run.ID,
		Outcome:    "escalation_unavailable",
		Detail: fmt.Sprintf(
			"Coop would not deliver this turn at policy ladder rung %d (%v); "+
				"the retry was submitted on the session's own rung.", floor, err,
		),
	})
	if clearErr := s.store.SetAgentRunTargetFloor(ctx, run.ID, 0); clearErr != nil &&
		s.log != nil && ctx.Err() == nil {
		s.log.Warn(
			"could not drop a model ladder floor Coop refused",
			"run", run.ID, "floor", floor, "error", clearErr,
		)
	}
	return s.coop.SubmitTurnAtOrAbove(
		ctx, run.IdempotencyKey, sessionID, revision, prompt, artifacts, 0,
	)
}

// coopRefusedTargetFloor reports the admission refusal of an escalation floor.
//
// Matched on the status and code rather than on the words, because the two
// Coops that produce it word it differently and only one of them names the
// field at all. It is only ever asked about a submission that carried a floor,
// where a 400 has no other plausible cause: a revision that moved is a 409, an
// oversized prompt is a 413, and a session that is gone is a 404.
func coopRefusedTargetFloor(err error) bool {
	var apiErr *coop.APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	return apiErr.Status == 400
}
