package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/store"
)

// unappliableOperation reports whether an operation failed for a reason that
// applying it again cannot change.
//
// Two shapes qualify, and both are pure functions of bytes already stored: the
// operation named something that does not exist, or it carried a timestamp that
// does not parse. The turn is over and its result is durable, so the thousandth
// attempt reads exactly the same bytes as the first — the same reasoning
// permanentPreparationError applies to a prompt that is too large to send.
//
// Everything else propagates. A locked database or a cancelled context is the
// opposite kind of failure: nothing about the result is wrong, and the next
// poll may well succeed. Treating those as permanent would throw away good
// answers over a blip, which is a worse trade than retrying a hopeless one.
func unappliableOperation(err error) bool {
	var parse *time.ParseError
	return errors.Is(err, store.ErrNotFound) || errors.As(err, &parse)
}

// recordResultOperationEvents applies what a finished turn asked the host to
// record.
//
// An operation that cannot be applied is dropped rather than allowed to fail
// the result around it. This is the rule the repository already applies to a
// rejected offer — "the answer was produced and is fine; only something
// attached to it could not be stored" — extended to the rest of the ledger,
// and it exists because the alternative was observed: an engineering task
// finished, committed f804b18c, then closed a goal it had never opened. The
// not-found failed the whole result, and because operations apply in order and
// that dangling close sorted ahead of the complete_episode beside it, the
// completion never applied. The work was done and sound and the Slack card
// read "Investigating" for seventy-nine minutes.
//
// Ordering is the whole hazard: every operation after the failure is collateral
// damage, and the completion is usually last. So the loop below continues past
// what it cannot apply, and says so where an operator can find it.
func (s *Service) recordResultOperationEvents(
	ctx context.Context,
	runID string,
	operations []investigation.ResultOperation,
) error {
	episode, err := s.store.GetWorkEpisodeByRun(ctx, runID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		return err
	}
	for _, operation := range operations {
		err := s.applyResultOperation(ctx, runID, episode, operation)
		switch {
		case err == nil:
		case errors.Is(err, errEpisodeGone):
			// The episode was collected while this result was in flight. There
			// is nothing left to record it against, and nothing to complain
			// about either.
			return nil
		case unappliableOperation(err):
			s.recordDroppedResultOperation(ctx, runID, episode, operation, err)
		default:
			return err
		}
	}
	return nil
}

// errEpisodeGone reports that the episode this result belongs to no longer
// exists, so the remaining operations have nowhere to land.
var errEpisodeGone = errors.New("work episode no longer exists")

// recordDroppedResultOperation leaves a trace of an operation the host refused
// to apply.
//
// A drop that is only a log line is indistinguishable from an operation the
// model never sent, so it also lands on the episode: the reader asking why a
// goal never closed needs the answer in the same timeline as the work.
// Appending is best-effort on purpose — failing to record the drop must not
// re-fail the result the drop exists to protect.
func (s *Service) recordDroppedResultOperation(
	ctx context.Context,
	runID string,
	episode core.WorkEpisode,
	operation investigation.ResultOperation,
	cause error,
) {
	if s.log != nil {
		s.log.Warn(
			"dropped a result operation the host could not apply",
			"run", runID, "episode", episode.ID,
			"operation", operation.ID, "type", operation.Type,
			"error", cause,
		)
	}
	payload, err := json.Marshal(map[string]string{
		"operation": operation.ID,
		"type":      operation.Type,
		"reason":    trimError(cause),
	})
	if err != nil {
		return
	}
	if _, err := s.store.AppendWorkEpisodeEvent(ctx, runID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventOperationDropped, Actor: "host",
		IdempotencyKey: "result-dropped:" + operation.ID,
		Payload:        payload,
	}); err != nil && s.log != nil {
		s.log.Warn(
			"could not record a dropped result operation",
			"run", runID, "operation", operation.ID, "error", err,
		)
	}
}

func (s *Service) applyResultOperation(
	ctx context.Context,
	runID string,
	episode core.WorkEpisode,
	operation investigation.ResultOperation,
) error {
	kind := ""
	var payload any = operation
	switch operation.Type {
	case "record_evidence":
		kind = episodepkg.EventEvidenceRecorded
	case "report_progress":
		kind = episodepkg.EventProgressReported
		var due time.Time
		if operation.Progress.NextDueAt != "" {
			parsed, err := time.Parse(time.RFC3339, operation.Progress.NextDueAt)
			if err != nil {
				return fmt.Errorf("result operation %q has invalid next_due_at: %w", operation.ID, err)
			}
			due = parsed
		}
		payload = episodepkg.Transition{
			Phase: operation.Progress.Phase, Summary: operation.Progress.Summary,
			ProgressDue: due,
		}
	case "plan_goal":
		goal := operation.Goal
		_, err := s.store.CreateEpisodeGoal(ctx, core.EpisodeGoal{
			ID: goal.ID, EpisodeID: episode.ID, Kind: goal.Kind,
			RequestedOutcome:   goal.RequestedOutcome,
			CompletionContract: goal.CompletionContract,
			Required:           goal.Required, PrerequisiteGoalIDs: goal.PrerequisiteGoalIDs,
			WritableRepository:   goal.WritableRepository,
			ReadOnlyRepositories: goal.ReadOnlyRepositories,
			AuthorityRequirement: goal.Authority,
		})
		if err != nil {
			return fmt.Errorf("result operation %q: %w", operation.ID, err)
		}
		return nil
	case "update_goal":
		if err := s.store.SetEpisodeGoalState(
			ctx, operation.GoalState.GoalID, operation.GoalState.State,
			operation.GoalState.Detail,
		); err != nil {
			return fmt.Errorf("result operation %q: %w", operation.ID, err)
		}
		return nil
	case "request_operator_input":
		kind = episodepkg.EventOperatorInputAsked
	case "record_feedback":
		kind = "feedback.recorded"
	case "wait_external":
		wait := operation.ExternalWait
		dueAt, parseErr := parseOptionalOperationTime(wait.DueAt)
		if parseErr != nil {
			return fmt.Errorf("result operation %q due_at: %w", operation.ID, parseErr)
		}
		pollAfter, parseErr := parseOptionalOperationTime(wait.PollAfter)
		if parseErr != nil {
			return fmt.Errorf("result operation %q poll_after: %w", operation.ID, parseErr)
		}
		deadline, parseErr := parseOptionalOperationTime(wait.Deadline)
		if parseErr != nil {
			return fmt.Errorf("result operation %q deadline: %w", operation.ID, parseErr)
		}
		wakeup, err := s.store.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
			ID: wait.ID, EpisodeID: episode.ID, Kind: wait.Kind,
			EventMatcher: wait.EventMatcher, DueAt: dueAt, PollAfter: pollAfter,
			Deadline: deadline,
		})
		if err != nil {
			return fmt.Errorf("result operation %q: %w", operation.ID, err)
		}
		if err := s.enqueueEpisodeWakeup(ctx, wakeup); err != nil {
			return fmt.Errorf("result operation %q scheduler: %w", operation.ID, err)
		}
		return nil
	case "request_approval":
		kind = episodepkg.EventApprovalRequested
	case "offer_task":
		kind = episodepkg.EventTaskOffered
	case "complete_episode":
		kind = episodepkg.EventCompletionSubmitted
	default:
		return nil
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if _, err := s.store.AppendWorkEpisodeEvent(ctx, runID, core.WorkEpisodeEvent{
		Kind: kind, Actor: "agent", IdempotencyKey: "result:" + operation.ID,
		Payload: encoded,
	}); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return errEpisodeGone
		}
		return err
	}
	return nil
}

func (s *Service) enqueueEpisodeWakeup(ctx context.Context, wakeup core.EpisodeWakeup) error {
	availableAt := wakeup.DueAt
	if availableAt.IsZero() ||
		(!wakeup.PollAfter.IsZero() && wakeup.PollAfter.Before(availableAt)) {
		availableAt = wakeup.PollAfter
	}
	return s.store.EnqueueWork(ctx, store.WorkItem{
		Kind: workEpisodeWakeup, SubjectID: schedulerSingletonID,
		Lane: store.WorkLaneBackground, Priority: 44, AvailableAt: availableAt,
	})
}

func parseOptionalOperationTime(value string) (time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, nil
	}
	return time.Parse(time.RFC3339, value)
}
