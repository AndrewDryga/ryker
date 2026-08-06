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
	legacy := *report
	// Operations are the authoritative transport. Models sometimes repeat their
	// final projection in the legacy fields as well; treating that harmless
	// redundancy as a terminal protocol failure loses otherwise valid work.
	report.Message = ""
	report.FollowupMessages = nil
	report.Visuals = nil
	report.Evidence = nil
	report.Coverage = nil
	report.Memory = core.AgentMemory{}
	report.MemoryOffer = nil
	report.PreferenceOffer = nil
	report.RuleOffer = nil
	report.ScheduleOffer = nil
	report.PendingApproval = nil
	report.Proposals = nil
	report.Completion = nil
	err := foldResultOperations(report.Operations, operationTargets{
		message: &report.Message, followups: &report.FollowupMessages, visuals: &report.Visuals,
		evidence: &report.Evidence, coverage: &report.Coverage, memory: &report.Memory,
		memoryOffer: &report.MemoryOffer, preferenceOffer: &report.PreferenceOffer,
		ruleOffer: &report.RuleOffer, scheduleOffer: &report.ScheduleOffer,
		approval: &report.PendingApproval, proposals: &report.Proposals,
		completion: &report.Completion,
	}, &report.AppliedOperations)
	if err != nil && strings.TrimSpace(legacy.Message) != "" {
		*report = legacy
		report.Operations = nil
		report.AppliedOperations = nil
		return nil
	}
	return err
}

func applyWatchResultOperations(decision *watchDecision) error {
	if len(decision.Operations) == 0 {
		return nil
	}
	if decision.Action == "ignore" {
		for _, operation := range decision.Operations {
			if operation.Type == "update_memory" {
				return applySilentWatchMemoryOperation(decision)
			}
		}
	}
	legacy := *decision
	// A complete_episode operation is itself an unambiguous reply decision. The
	// host owns that projection even if the model omitted action or left an old
	// ignore value beside the operation stream.
	decision.Action = "reply"
	decision.Message = ""
	decision.FollowupMessages = nil
	decision.Visuals = nil
	decision.IncidentTitle = ""
	decision.TaskTitle = ""
	decision.TaskRepository = ""
	decision.TaskPrompt = ""
	decision.Evidence = nil
	decision.Coverage = nil
	decision.Memory = core.AgentMemory{}
	decision.MemoryOffer = nil
	decision.PreferenceOffer = nil
	decision.RuleOffer = nil
	decision.ScheduleOffer = nil
	decision.PendingApproval = nil
	decision.AlertAssessment = nil
	decision.Completion = nil
	err := foldResultOperations(decision.Operations, operationTargets{
		message: &decision.Message, followups: &decision.FollowupMessages, visuals: &decision.Visuals,
		evidence: &decision.Evidence, coverage: &decision.Coverage, memory: &decision.Memory,
		memoryOffer: &decision.MemoryOffer, preferenceOffer: &decision.PreferenceOffer,
		ruleOffer: &decision.RuleOffer, scheduleOffer: &decision.ScheduleOffer,
		approval: &decision.PendingApproval, alert: &decision.AlertAssessment,
		completion:    &decision.Completion,
		incidentTitle: &decision.IncidentTitle, taskTitle: &decision.TaskTitle,
		taskRepository: &decision.TaskRepository, taskPrompt: &decision.TaskPrompt,
	}, &decision.AppliedOperations)
	if err == nil {
		decision.Message = appendFeedbackFollowup(decision.Message, decision.AppliedOperations)
	}
	if err != nil && legacyWatchDecisionUsable(legacy) {
		*decision = legacy
		decision.Operations = nil
		decision.AppliedOperations = nil
		return nil
	}
	return err
}

func applySilentWatchMemoryOperation(decision *watchDecision) error {
	if len(decision.Operations) != 1 {
		return errors.New("ignore decision may contain exactly one update_memory operation")
	}
	operation := decision.Operations[0]
	if err := operation.Validate(); err != nil {
		return fmt.Errorf("result operation 1: %w", err)
	}
	if operation.Type != "update_memory" || operation.Memory == nil {
		return errors.New("ignore decision operations may only update conversation memory")
	}
	if strings.TrimSpace(decision.Message) != "" || len(decision.FollowupMessages) != 0 ||
		len(decision.Visuals) != 0 || strings.TrimSpace(decision.IncidentTitle) != "" ||
		strings.TrimSpace(decision.TaskTitle) != "" || len(decision.Evidence) != 0 ||
		len(decision.Coverage) != 0 || decision.MemoryOffer != nil ||
		decision.PreferenceOffer != nil || decision.RuleOffer != nil ||
		decision.ScheduleOffer != nil || decision.PendingApproval != nil ||
		decision.AlertAssessment != nil || decision.Completion != nil ||
		len(decision.PublicationUpdates) != 0 {
		return errors.New("silent memory update cannot include reply content or other result fields")
	}
	decision.Memory = *operation.Memory
	decision.AppliedOperations = []investigation.ResultOperation{operation}
	return nil
}

func appendFeedbackFollowup(message string, operations []investigation.ResultOperation) string {
	for _, operation := range operations {
		if operation.Type != "record_feedback" || operation.Feedback == nil ||
			!operation.Feedback.NeedsFollowup {
			continue
		}
		question := strings.TrimSpace(operation.Feedback.FollowupQuestion)
		if question != "" && !strings.Contains(message, question) {
			message = strings.TrimSpace(message)
			if message == "" {
				return question
			}
			return message + "\n\n" + question
		}
	}
	return message
}

func legacyWatchDecisionUsable(decision watchDecision) bool {
	switch decision.Action {
	case "ignore":
		// An empty legacy ignore beside a malformed operation stream is not a
		// usable fallback. Accepting it would silently discard typed work.
		return len(decision.Operations) == 0
	case "react":
		return strings.TrimSpace(decision.Reaction) != ""
	case "reply":
		return strings.TrimSpace(decision.Message) != ""
	case "escalate":
		return strings.TrimSpace(decision.Reason) != ""
	default:
		return false
	}
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
	memoryUpdated := false
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
		switch operation.Type {
		case "record_evidence":
			if err := investigation.ValidateEvidence(*operation.Evidence); err != nil {
				return fmt.Errorf("result operation %q: %w", operation.ID, err)
			}
			*target.evidence = append(*target.evidence, *operation.Evidence)
		case "record_coverage":
			*target.coverage = append(*target.coverage, *operation.Coverage)
		case "report_progress":
			// Progress is projected from the episode event stream. It is not copied
			// into the final Slack report.
		case "plan_goal", "update_goal", "request_operator_input", "wait_external", "record_feedback":
			// These operations project from the episode event stream rather than
			// becoming fields in the final Slack response.
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
		case "attach_visual":
			*target.visuals = append(*target.visuals, *operation.Visual)
		case "update_memory":
			if memoryUpdated {
				return fmt.Errorf("result operation %q duplicates update_memory", operation.ID)
			}
			memoryUpdated = true
			*target.memory = *operation.Memory
		case "offer_memory":
			if *target.memoryOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_memory", operation.ID)
			}
			*target.memoryOffer = operation.MemoryOffer
		case "offer_preference":
			if *target.preferenceOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_preference", operation.ID)
			}
			*target.preferenceOffer = operation.PreferenceOffer
		case "offer_rule":
			if *target.ruleOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_rule", operation.ID)
			}
			*target.ruleOffer = operation.RuleOffer
		case "offer_schedule":
			if *target.scheduleOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_schedule", operation.ID)
			}
			*target.scheduleOffer = operation.ScheduleOffer
		case "record_alert_assessment":
			if target.alert == nil || *target.alert != nil {
				return fmt.Errorf("result operation %q duplicates or cannot record an alert assessment", operation.ID)
			}
			*target.alert = operation.AlertAssessment
		case "propose_action":
			if target.proposals == nil {
				return fmt.Errorf("result operation %q cannot propose an action", operation.ID)
			}
			*target.proposals = append(*target.proposals, *operation.Proposal)
		case "complete_episode":
			if completed {
				return fmt.Errorf("result operation %q duplicates complete_episode", operation.ID)
			}
			completed = true
			value := operation.Completion
			*target.message = value.Message
			*target.followups = value.FollowupMessages
			*target.visuals = append(*target.visuals, value.Visuals...)
			*target.coverage = append(*target.coverage, value.Coverage...)
			if !memoryUpdated {
				*target.memory = value.Memory
			}
			if *target.memoryOffer == nil {
				*target.memoryOffer = value.MemoryOffer
			}
			if *target.preferenceOffer == nil {
				*target.preferenceOffer = value.PreferenceOffer
			}
			if *target.ruleOffer == nil {
				*target.ruleOffer = value.RuleOffer
			}
			if *target.scheduleOffer == nil {
				*target.scheduleOffer = value.ScheduleOffer
			}
			if target.alert != nil {
				if *target.alert == nil {
					*target.alert = value.AlertAssessment
				}
			}
			*target.completion = value.Completion
			if target.proposals != nil {
				*target.proposals = append(*target.proposals, value.Proposals...)
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
			if err := s.store.SetEpisodeGoalState(
				ctx, operation.GoalState.GoalID, operation.GoalState.State,
				operation.GoalState.Detail,
			); err != nil {
				return fmt.Errorf("result operation %q: %w", operation.ID, err)
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
			if _, err := s.store.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
				ID: wait.ID, EpisodeID: episode.ID, Kind: wait.Kind,
				EventMatcher: wait.EventMatcher, DueAt: dueAt, PollAfter: pollAfter,
				Deadline: deadline,
			}); err != nil {
				return fmt.Errorf("result operation %q: %w", operation.ID, err)
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

func parseOptionalOperationTime(value string) (time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, nil
	}
	return time.Parse(time.RFC3339, value)
}
