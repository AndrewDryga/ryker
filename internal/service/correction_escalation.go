package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
)

// A correction that repeats is a routing decision, not a wording problem.
//
// blitz run_3a615b9db spent nineteen rounds and twenty-two minutes on one alert,
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
// where the session actually sits. Ryker cannot see the ladder — Coop
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
// answered below. It returns the sentence the correction's audit event should
// carry, which is empty when there is nothing to say about the ladder.
//
// Bookkeeping must never cost a correction. A run whose envelope cannot be
// edited still gets its retry — the correction is the useful thing, and losing
// it to a failed counter update would trade an answer for a statistic.
func (s *Service) escalateRepeatedCorrection(
	ctx context.Context,
	run core.AgentRun,
	class correctionClass,
) string {
	if !correctionEscalates(class) {
		return ""
	}
	repeats, err := s.store.NoteAgentRunCorrectionClass(ctx, run.ID, string(class))
	if err != nil {
		if s.log != nil && ctx.Err() == nil {
			s.log.Warn(
				"could not count a repeated correction class",
				"run", run.ID, "class", string(class), "error", err,
			)
		}
		return ""
	}
	current, refused := agentRunLadderFloors(run.Context)
	floor := escalationFloorForRepeats(repeats)
	if floor <= current {
		return ""
	}
	// The ladder has a top and this is the only place the host can learn where
	// it is: Coop publishes the session's current target, never the policy's
	// list of them, so a floor was computed as repeats-1 and asked for however
	// high the repeat count went. run_532f8d62871320dc9d0696cb334d3503 was
	// corrected thirteen times on blitz on 2026-08-16 and asked for rungs 10,
	// 11 and 12 in turn; each one cost a refused SubmitTurn, an audit line and a
	// second round trip to deliver the correction the ordinary way, and the next
	// round asked for a rung one higher than the one that had just been refused.
	//
	// Not clamped to the rung below the refusal. The run has already been told
	// what is wrong on every rung up to here, and the honest reading of a
	// refused floor is that the ladder is exhausted, not that there is one more
	// seat somewhere below the one Coop would not sell.
	if refused > 0 && floor >= refused {
		return ladderTopAuditNote(class, refused, current)
	}
	if err := s.store.SetAgentRunTargetFloor(ctx, run.ID, floor, 0); err != nil {
		if s.log != nil && ctx.Err() == nil {
			s.log.Warn(
				"could not raise a run's model ladder floor",
				"run", run.ID, "floor", floor, "error", err,
			)
		}
		return ""
	}
	// The rung that answers next is a different model, and turndelta hands it
	// the whole briefing again for that reason. It has not yet failed to read
	// anything, so the previous rung's unreadable tally is not its debt: on
	// blitz on 2026-08-16 an escalated model spent its first two rounds
	// answering `unknown field "completion_contract"` and `unknown field
	// "record_evidence"` about a schema it had never been shown, against a
	// counter that was already spent.
	//
	// Only this class, and never the run-wide budget. `incomplete` is a claim
	// about the WORK rather than about one model's reading — a bigger model
	// that still cannot finish the investigation should keep climbing — and
	// spendStructuredCorrection stays the hard bound on the whole argument.
	if err := s.store.ClearAgentRunCorrectionClass(
		ctx, run.ID, string(correctionUnreadable),
	); err != nil && s.log != nil && ctx.Err() == nil {
		s.log.Warn(
			"could not clear a re-briefed run's unreadable count",
			"run", run.ID, "error", err,
		)
	}
	return escalationAuditNote(class, floor)
}

// escalationAuditNote is the sentence the result.correction audit event carries
// when the retry moved up the ladder, so the episode trace says why the same
// question came back on a different model rather than leaving an operator to
// infer it from the manifest.
//
// It names the re-briefing too. A rung is a different model and that model is
// handed the whole briefing again, so the retry's prompt jumps from a
// twelve-kilobyte delta back to a hundred and forty kilobytes; without this
// sentence the trace shows that jump with nothing beside it, and the first
// guess a reader makes is a delta-turn regression.
func escalationAuditNote(class correctionClass, floor int) string {
	return fmt.Sprintf(
		"\n\n[host] %s twice on this attempt: the retry is delivered no lower "+
			"than policy ladder rung %d. The retry carries the full briefing again.",
		class, floor,
	)
}

// ladderTopAuditNote is its sibling for the round after the ladder runs out.
//
// Without it the trace shows a class repeating for the fourth time with no
// escalation beside it and no reason given, which reads as the escalation being
// broken. The sentence names the refused rung, so the answer to "why is the same
// model answering again" is in the correction the operator is already reading
// rather than in a `model.escalation` audit line three rounds back.
func ladderTopAuditNote(class correctionClass, refused, floor int) string {
	return fmt.Sprintf(
		"\n\n[host] %s again on this attempt, and this is the ladder top: rung %d "+
			"was refused by Coop; the retry stays at rung %d.",
		class, refused, floor,
	)
}

// agentRunLadderFloors reads where a run stands on the ladder: the rung it has
// already escalated to, and the lowest rung Coop has refused to deliver — zero
// when it has refused none, which is every run until it asks past the top.
//
// Decoded as two fields rather than as either whole envelope, because both of
// them carry these under the same keys and neither of their shapes is this
// function's business. An envelope that will not decode reads as no floor and
// no ceiling, which is the ordinary turn.
func agentRunLadderFloors(contextJSON []byte) (floor, refused int) {
	if len(contextJSON) == 0 {
		return 0, 0
	}
	var envelope struct {
		MinTargetIndex     int `json:"min_target_index,omitempty"`
		RefusedTargetFloor int `json:"refused_target_floor,omitempty"`
	}
	if json.Unmarshal(contextJSON, &envelope) != nil {
		return 0, 0
	}
	return max(envelope.MinTargetIndex, 0), max(envelope.RefusedTargetFloor, 0)
}

// agentRunTargetFloor is the rung alone, which is what the delta-turn decision
// and the submission path ask for.
func agentRunTargetFloor(contextJSON []byte) int {
	floor, _ := agentRunLadderFloors(contextJSON)
	return floor
}

func agentRunDegradedFallbackPending(contextJSON []byte) bool {
	if len(contextJSON) == 0 {
		return false
	}
	var envelope struct {
		Pending bool `json:"degraded_target_fallback_pending,omitempty"`
	}
	return json.Unmarshal(contextJSON, &envelope) == nil && envelope.Pending
}

// submissionTargetFloor is the floor this one Coop admission carries. The
// desired floor remains in the run envelope: it is history about why the run
// prefers a stronger model, not a reason to leave the work stuck when every
// target at or above that floor has reported a provider limit.
//
// A successful submission clears both LastError and the pending fallback flag,
// so this is naturally one degraded admission. The next ordinary escalated
// turn asks for the desired floor again.
func submissionTargetFloor(run core.AgentRun) int {
	floor := agentRunTargetFloor(run.Context)
	if floor > 0 && (agentRunDegradedFallbackPending(run.Context) ||
		coopLadderExhaustedDetail(run.LastError)) {
		return 0
	}
	return floor
}

func submissionRewindsTarget(run core.AgentRun) bool {
	return agentRunDegradedFallbackPending(run.Context) ||
		coopLadderExhaustedDetail(run.LastError)
}

// coopLadderExhaustedDetail recognises only Coop's complete-ladder refusal,
// not an arbitrary provider message containing "rate limited". A single
// preferred provider being limited is Coop's job to rotate around; this host
// relaxes an escalation floor only after Coop says that floor excluded every
// target it could currently use.
func coopLadderExhaustedDetail(detail string) bool {
	_, exhausted := coopLadderExhaustedFloor(detail)
	return exhausted
}

func coopLadderExhaustedFloor(detail string) (int, bool) {
	const prefix = "every target at or above policy ladder rung "
	const limited = " is rate limited"
	detail = strings.TrimSpace(detail)
	rest, found := strings.CutPrefix(detail, prefix)
	if !found {
		return 0, false
	}
	rung, suffix, found := strings.Cut(rest, limited)
	if !found {
		return 0, false
	}
	index, err := strconv.Atoi(rung)
	if err != nil {
		return 0, false
	}
	if suffix == "" {
		return index, true
	}
	const until = " until "
	reset, found := strings.CutPrefix(suffix, until)
	if !found {
		return 0, false
	}
	_, err = time.Parse(time.RFC3339, reset)
	return index, err == nil
}

// submitTurnAtLadderFloor submits a turn at or above the rung this run has
// escalated to. It temporarily admits a complete-ladder retry at rung zero, and
// degrades to an ordinary submission when Coop will not honour the floor.
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
// round trip that is refused again.
//
// The refused rung is remembered in the same write, and that is the half this
// path was missing. Clearing alone left the next repeat to compute a rung one
// higher from a repeat count that had gone up, ask for it, and be refused
// again: rungs 10, 11 and 12 in three consecutive rounds on 2026-08-16, each
// costing a refused submit and an audit line on a thirteen-round loop. A
// refusal is the only reading of the ladder's length this host ever gets, so it
// has to survive the requeue rather than being re-learned every round.
func (s *Service) submitTurnAtLadderFloor(
	ctx context.Context,
	run core.AgentRun,
	sessionID string,
	revision int64,
	prompt string,
	artifacts []coop.InputArtifact,
) (coop.Turn, coop.Operation, error) {
	floor := submissionTargetFloor(run)
	if submissionRewindsTarget(run) {
		return s.coop.SubmitTurnRewound(
			ctx, run.IdempotencyKey, sessionID, revision, prompt, artifacts,
		)
	}
	turn, operation, err := s.coop.SubmitTurnAtOrAbove(
		ctx, run.IdempotencyKey, sessionID, revision, prompt, artifacts, floor,
	)
	if floor == 0 || !coopRefusedTargetFloor(err) {
		return turn, operation, err
	}
	// Its own kind, not result.correction. Everything that counts corrections
	// counts rows of that kind — the audition lane's correction rate, the
	// weekly self-report, the episode's rejection list — and this is not the
	// host refusing a model's result. Filing it there would charge the model
	// for a rung its deployment does not have, in exactly the number the
	// routing flywheel reads to decide which model deserves which lane.
	s.audit(ctx, core.AuditEvent{
		IncidentID: run.IncidentID,
		Kind:       "model.escalation",
		ActorID:    "responder",
		ObjectID:   run.ID,
		Outcome:    "unavailable",
		Detail: fmt.Sprintf(
			"Coop would not deliver this turn at policy ladder rung %d (%v); "+
				"the retry was submitted on the session's own rung.", floor, err,
		),
	})
	if clearErr := s.store.SetAgentRunTargetFloor(ctx, run.ID, 0, floor); clearErr != nil &&
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
