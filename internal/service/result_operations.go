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
			continue
		case "update_goal":
			// Closing a goal the episode never planned is not a host failure.
			// The goal ledger is the agent's own bookkeeping, so an update
			// naming an id nothing created has nothing to update — the same
			// reading this function already gives a missing episode above and
			// a missing run below.
			//
			// Returning the error instead cost a finished engineering task
			// twenty-one minutes and counting. The agent committed its work,
			// then closed a goal it had never opened. The not-found propagated
			// out through the terminal poll, which has no failure counter and
			// no backoff, so the same terminal event replayed about three
			// times a second — six thousand times. Because operations apply in
			// order and this one sorted ahead of the complete_episode beside
			// it, the completion never applied at all: the work was done, the
			// commit was sound, and the Slack card read "Investigating" until
			// a person went looking. A slip in the model's bookkeeping must
			// not be able to withhold the answer it is bookkeeping about.
			if err := s.store.SetEpisodeGoalState(
				ctx, operation.GoalState.GoalID, operation.GoalState.State,
				operation.GoalState.Detail,
			); err != nil {
				if !errors.Is(err, store.ErrNotFound) {
					return fmt.Errorf("result operation %q: %w", operation.ID, err)
				}
				if s.log != nil {
					s.log.Warn(
						"result operation closes a goal the episode never planned",
						"run", runID, "operation", operation.ID,
						"goal", operation.GoalState.GoalID,
					)
				}
			}
			continue
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
			continue
		case "request_approval":
			kind = episodepkg.EventApprovalRequested
		case "offer_task":
			kind = episodepkg.EventTaskOffered
		case "complete_episode":
			kind = episodepkg.EventCompletionSubmitted
		default:
			continue
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
				return nil
			}
			return err
		}
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
