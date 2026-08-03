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

const maxResultOperations = 100

func applyAgentResultOperations(report *agentReport) error {
	if len(report.Operations) == 0 {
		return nil
	}
	if report.Message != "" || len(report.FollowupMessages) != 0 || len(report.Visuals) != 0 ||
		len(report.Evidence) != 0 || len(report.Coverage) != 0 || report.MemoryOffer != nil ||
		report.PreferenceOffer != nil || report.RuleOffer != nil || report.ScheduleOffer != nil ||
		report.PendingApproval != nil || len(report.Proposals) != 0 || report.Completion != nil {
		return errors.New("typed result operations cannot be combined with legacy result fields")
	}
	return foldResultOperations(report.Operations, operationTargets{
		message: &report.Message, followups: &report.FollowupMessages, visuals: &report.Visuals,
		evidence: &report.Evidence, coverage: &report.Coverage, memory: &report.Memory,
		memoryOffer: &report.MemoryOffer, preferenceOffer: &report.PreferenceOffer,
		ruleOffer: &report.RuleOffer, scheduleOffer: &report.ScheduleOffer,
		approval: &report.PendingApproval, proposals: &report.Proposals,
		completion: &report.Completion,
	}, &report.AppliedOperations)
}

func applyWatchResultOperations(decision *watchDecision) error {
	if len(decision.Operations) == 0 {
		return nil
	}
	if decision.Action != "reply" {
		return errors.New("typed result operations are only valid for a reply decision")
	}
	if decision.Message != "" || len(decision.FollowupMessages) != 0 || len(decision.Visuals) != 0 ||
		decision.IncidentTitle != "" || decision.TaskTitle != "" || decision.TaskRepository != "" ||
		decision.TaskPrompt != "" || len(decision.Evidence) != 0 || len(decision.Coverage) != 0 ||
		decision.MemoryOffer != nil || decision.PreferenceOffer != nil || decision.RuleOffer != nil ||
		decision.ScheduleOffer != nil || decision.PendingApproval != nil ||
		decision.AlertAssessment != nil || decision.Completion != nil {
		return errors.New("typed result operations cannot be combined with legacy reply fields")
	}
	return foldResultOperations(decision.Operations, operationTargets{
		message: &decision.Message, followups: &decision.FollowupMessages, visuals: &decision.Visuals,
		evidence: &decision.Evidence, coverage: &decision.Coverage, memory: &decision.Memory,
		memoryOffer: &decision.MemoryOffer, preferenceOffer: &decision.PreferenceOffer,
		ruleOffer: &decision.RuleOffer, scheduleOffer: &decision.ScheduleOffer,
		approval: &decision.PendingApproval, alert: &decision.AlertAssessment,
		completion:    &decision.Completion,
		incidentTitle: &decision.IncidentTitle, taskTitle: &decision.TaskTitle,
		taskRepository: &decision.TaskRepository, taskPrompt: &decision.TaskPrompt,
	}, &decision.AppliedOperations)
}

type operationTargets struct {
	message         *string
	followups       *[]string
	visuals         *[]core.GeneratedVisual
	evidence        *[]core.Evidence
	coverage        *[]core.Coverage
	memory          *core.AgentMemory
	memoryOffer     **core.MemoryOffer
	preferenceOffer **core.PreferenceOffer
	ruleOffer       **core.RuleOffer
	scheduleOffer   **core.ScheduleOffer
	approval        **core.EmisarApproval
	alert           **alertAssessment
	completion      **completionAssessment
	proposals       *[]core.ActionProposal
	incidentTitle   *string
	taskTitle       *string
	taskRepository  *string
	taskPrompt      *string
}

func foldResultOperations(
	operations []investigation.ResultOperation,
	target operationTargets,
	applied *[]investigation.ResultOperation,
) error {
	if len(operations) > maxResultOperations {
		return fmt.Errorf("result contains more than %d operations", maxResultOperations)
	}
	seen := make(map[string]struct{}, len(operations))
	completed := false
	for index, operation := range operations {
		operation.ID = strings.TrimSpace(operation.ID)
		operation.Type = strings.TrimSpace(operation.Type)
		if _, duplicate := seen[operation.ID]; duplicate {
			return fmt.Errorf("result operation %d has duplicate id %q", index+1, operation.ID)
		}
		seen[operation.ID] = struct{}{}
		if err := operation.Validate(); err != nil {
			return fmt.Errorf("result operation %d: %w", index+1, err)
		}
		if completed {
			return fmt.Errorf("result operation %q appears after complete_episode", operation.ID)
		}
		switch operation.Type {
		case "record_evidence":
			if err := investigation.ValidateEvidence(*operation.Evidence); err != nil {
				return fmt.Errorf("result operation %q: %w", operation.ID, err)
			}
			*target.evidence = append(*target.evidence, *operation.Evidence)
		case "report_progress":
			// Progress is projected from the episode event stream. It is not copied
			// into the final Slack report.
		case "request_approval":
			if *target.approval != nil {
				return fmt.Errorf("result operation %q duplicates request_approval", operation.ID)
			}
			*target.approval = operation.Approval
		case "offer_task":
			if operation.Task.Kind == "incident" {
				if target.incidentTitle == nil || *target.incidentTitle != "" {
					return fmt.Errorf("result operation %q duplicates or cannot offer an incident", operation.ID)
				}
				*target.incidentTitle = operation.Task.Title
			} else {
				if target.taskTitle == nil || *target.taskTitle != "" {
					return fmt.Errorf("result operation %q duplicates or cannot offer engineering work", operation.ID)
				}
				*target.taskTitle = operation.Task.Title
				*target.taskRepository = operation.Task.Repository
				*target.taskPrompt = operation.Task.Prompt
			}
		case "complete_episode":
			completed = true
			value := operation.Completion
			*target.message = value.Message
			*target.followups = value.FollowupMessages
			*target.visuals = value.Visuals
			*target.coverage = value.Coverage
			*target.memory = value.Memory
			*target.memoryOffer = value.MemoryOffer
			*target.preferenceOffer = value.PreferenceOffer
			*target.ruleOffer = value.RuleOffer
			*target.scheduleOffer = value.ScheduleOffer
			if target.alert != nil {
				*target.alert = value.AlertAssessment
			}
			*target.completion = value.Completion
			if target.proposals != nil {
				*target.proposals = value.Proposals
			}
		}
		*applied = append(*applied, operation)
	}
	if !completed {
		return errors.New("typed result operations require exactly one complete_episode")
	}
	return nil
}

func (s *Service) recordResultOperationEvents(
	ctx context.Context,
	runID string,
	operations []investigation.ResultOperation,
) error {
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
