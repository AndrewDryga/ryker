package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"os/exec"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func (s *Service) maintainLifecycle(ctx context.Context) {
	now := time.Now().UTC()
	if err := s.maintainMemory(ctx, now); err != nil && ctx.Err() == nil {
		s.log.Warn("memory consolidation failed", "error", err)
	}
	grace := s.cfg.Retention.ClosedSessionGrace.Duration
	if err := s.reconcileOrphanedResponderSessions(ctx, now.Add(-grace), now); err != nil &&
		ctx.Err() == nil {
		s.log.Warn("orphaned Coop session reconciliation failed", "error", err)
	}
	if _, err := s.store.ScheduleExpiredChannelMemoryCleanup(
		ctx,
		now.Add(-s.cfg.Coop.WatchSessionAge.Duration),
		now.Add(grace),
	); err != nil && ctx.Err() == nil {
		s.log.Warn("schedule expired Slack channel memory cleanup failed", "error", err)
	}
	if retired, err := s.store.RetireResolvedDeletedWork(
		ctx,
		now.Add(-grace),
	); err != nil && ctx.Err() == nil {
		s.log.Warn("retire resolved work with deleted Slack channels failed", "error", err)
	} else if retired > 0 {
		s.log.Info(
			"retired resolved work with deleted Slack channels",
			"records",
			retired,
		)
	}
	if _, err := s.store.BackfillClosedSessionCleanup(ctx, now.Add(-grace)); err != nil &&
		ctx.Err() == nil {
		s.log.Warn("backfill closed Coop cleanup failed", "error", err)
	}
	if retired, err := s.store.RetireActionProposals(ctx, now); err != nil && ctx.Err() == nil {
		s.log.Warn("retire disabled action proposals failed", "error", err)
	} else if retired > 0 {
		s.log.Info("retired disabled action proposals", "records", retired)
	}
	const cleanupBatch = 16
	for range cleanupBatch {
		err := s.processCleanup(ctx, now)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			if ctx.Err() == nil {
				s.log.Warn("Coop cleanup failed", "error", err)
			}
			break
		}
	}
	repositories := s.cfg.RepositoryContextKeys()
	if pruned, err := s.store.PruneOrphanMemoryEntries(ctx, repositories); err != nil &&
		ctx.Err() == nil {
		s.log.Warn("orphaned operational memory pruning failed", "error", err)
	} else if pruned > 0 {
		s.log.Info("pruned orphaned operational memory", "records", pruned)
	}
	if preferences, rules, err := s.store.PruneOrphanBehavior(ctx, repositories); err != nil &&
		ctx.Err() == nil {
		s.log.Warn("orphaned Responder behavior pruning failed", "error", err)
	} else if preferences+rules > 0 {
		s.log.Info(
			"pruned orphaned Responder behavior",
			"preferences", preferences,
			"rules", rules,
		)
	}
	if schedules, err := s.store.PruneOrphanSchedules(ctx, repositories); err != nil && ctx.Err() == nil {
		s.log.Warn("orphaned scheduled task pruning failed", "error", err)
	} else if schedules > 0 {
		s.log.Info("pruned orphaned scheduled tasks", "records", schedules)
	}
	result, err := s.store.Prune(
		ctx,
		now.Add(-s.cfg.Retention.OperationalData.Duration),
		now.Add(-s.cfg.Retention.ConversationMemory.Duration),
		now.Add(-s.cfg.Retention.ClosedWork.Duration),
		now.Add(-s.cfg.Retention.AuditData.Duration),
	)
	if err != nil {
		if ctx.Err() == nil {
			s.log.Warn("Responder state pruning failed", "error", err)
		}
		return
	}
	if result.Total() > 0 {
		s.log.Info(
			"pruned expired Responder state",
			"records", result.Total(),
			"slack_inputs", result.SlackInputs,
			"webhooks", result.WebhookEvents,
			"slack_deliveries", result.SlackDeliveries,
			"agent_runs", result.AgentRuns,
			"evaluations", result.EvaluationDecisions,
			"channel_intelligence", result.ChannelIntelligence,
			"conversation_memories", result.ConversationMemories,
			"memory_entries", result.MemoryEntries,
			"memory_rollups", result.MemoryRollups,
			"memory_reviews", result.MemoryReviews,
			"memory_supersessions", result.MemorySupersessions,
			"preferences", result.Preferences,
			"standing_rules", result.StandingRules,
			"standing_rule_runs", result.StandingRuleRuns,
			"scheduled_tasks", result.ScheduledTasks,
			"scheduled_task_runs", result.ScheduledTaskRuns,
			"action_proposals", result.ActionProposals,
			"emisar_approvals", result.EmisarApprovals,
			"configuration_sessions", result.ConfigurationSessions,
			"closed_work", result.ClosedIncidents,
			"audit", result.AuditEvents,
		)
	}
}

func (s *Service) reconcileOrphanedResponderSessions(
	ctx context.Context,
	staleBefore time.Time,
	eligibleAt time.Time,
) error {
	sessions, err := s.coop.ListSessions(ctx, 1000)
	if err != nil {
		return err
	}
	for _, session := range sessions {
		if session.State == "discarded" || session.UpdatedAt.After(staleBefore) ||
			!isResponderManagedSession(session) {
			continue
		}
		known, err := s.store.ResponderSessionKnown(ctx, session.ID)
		if err != nil {
			return err
		}
		if known {
			continue
		}
		if err := s.store.ScheduleCleanup(
			ctx,
			session.ID,
			"",
			"orphaned Responder session",
			false,
			eligibleAt,
		); err != nil {
			return err
		}
		s.log.Info(
			"scheduled orphaned Responder session cleanup",
			"session_id", session.ID,
			"fork", session.ForkName,
			"updated_at", session.UpdatedAt,
		)
	}
	return nil
}

func isResponderManagedSession(session coop.Session) bool {
	return strings.HasPrefix(session.ExternalRef, "incident:") ||
		strings.HasPrefix(session.ExternalRef, "engineering-task:") ||
		strings.HasPrefix(session.ExternalRef, "Slack operations channel ") ||
		strings.HasPrefix(session.ExternalRef, "Slack alert triage channel ")
}

func (s *Service) processCleanup(ctx context.Context, now time.Time) error {
	item, err := s.store.NextCleanup(ctx, now)
	if err != nil {
		return err
	}
	session, err := s.coop.GetSession(ctx, item.SessionID)
	if err != nil {
		return s.retryCleanup(ctx, item, err)
	}
	if session.State == "discarded" {
		return s.store.SetCleanupState(ctx, item.SessionID, "done", "", "", now)
	}
	if session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		return s.retryCleanup(ctx, item, errors.New("session still has active or queued work"))
	}
	if session.State != "closed" {
		session, _, err = s.coop.Close(
			ctx,
			"responder:gc-close:"+item.SessionID,
			item.SessionID,
			session.Revision,
		)
		if err != nil {
			return s.retryCleanup(ctx, item, err)
		}
	}
	plan, _, err := s.coop.PlanDiscard(
		ctx,
		"responder:gc-plan:"+item.SessionID+":"+fmt.Sprint(session.Revision),
		item.SessionID,
		session.Revision,
		false,
		false,
	)
	if err != nil {
		return s.retryCleanup(ctx, item, err)
	}
	if plan.Plan.Workspace.Dirty {
		return s.store.SetCleanupState(
			ctx, item.SessionID, "blocked", plan.OperationID,
			"workspace has uncommitted changes; automatic cleanup never accepts dirty work",
			now,
		)
	}
	if plan.Plan.Workspace.Unmerged && !item.AllowUnmerged {
		return s.store.SetCleanupState(
			ctx, item.SessionID, "blocked", plan.OperationID,
			"workspace has unpublished committed changes; publish or explicitly discard them",
			now,
		)
	}
	if plan.Plan.Workspace.Unmerged {
		if err := s.verifyPublishedCleanupTree(ctx, item, plan); err != nil {
			return s.store.SetCleanupState(
				ctx, item.SessionID, "blocked", plan.OperationID,
				trimError(err), now,
			)
		}
		plan, _, err = s.coop.PlanDiscard(
			ctx,
			"responder:gc-plan-published:"+item.SessionID+":"+fmt.Sprint(session.Revision),
			item.SessionID,
			session.Revision,
			false,
			true,
		)
		if err != nil {
			return s.retryCleanup(ctx, item, err)
		}
		if plan.Plan.Workspace.Dirty || !plan.Plan.Workspace.AcceptedUnmerged {
			return s.store.SetCleanupState(
				ctx, item.SessionID, "blocked", plan.OperationID,
				"published workspace changed while cleanup was being planned", now,
			)
		}
	}
	_, _, err = s.coop.Discard(
		ctx,
		"responder:gc-discard:"+item.SessionID+":"+plan.OperationID,
		item.SessionID,
		plan.OperationID,
	)
	if err != nil {
		return s.retryCleanup(ctx, item, err)
	}
	return s.store.SetCleanupState(ctx, item.SessionID, "done", plan.OperationID, "", now)
}

func (s *Service) verifyPublishedCleanupTree(
	ctx context.Context,
	item core.CoopCleanup,
	plan coop.DiscardPlan,
) error {
	if item.IncidentID == "" {
		return errors.New("unmerged cleanup has no Responder work record")
	}
	incident, err := s.store.GetIncident(ctx, item.IncidentID)
	if err != nil {
		return fmt.Errorf("load cleanup work record: %w", err)
	}
	publication, err := s.store.GetPublication(ctx, item.IncidentID)
	if err != nil || !publication.Published() {
		if err == nil {
			err = errors.New("draft PR is not published")
		}
		return fmt.Errorf("verify durable publication: %w", err)
	}
	if s.publisher == nil {
		return errors.New("GitHub publication verifier is unavailable")
	}
	if err := s.publisher.VerifyPublication(ctx, publication); err != nil {
		return fmt.Errorf("verify current GitHub publication: %w", err)
	}
	repository, ok := s.cfg.RepositoryContext(incident.Repository)
	if !ok || repository.Path == "" {
		return errors.New("publication repository checkout is unavailable")
	}
	command := exec.CommandContext(
		ctx,
		"git", "-C", repository.Path, "rev-parse",
		plan.Plan.Workspace.Head+"^{tree}",
	)
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Run(); err != nil {
		return fmt.Errorf("resolve closed fork tree: %s", strings.TrimSpace(output.String()))
	}
	tree := strings.TrimSpace(output.String())
	if tree != publication.CandidateTree {
		return fmt.Errorf(
			"closed fork tree %s is not the published reviewed tree %s; retaining newer work",
			tree, publication.CandidateTree,
		)
	}
	return nil
}

func (s *Service) discardRetainedWork(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	if incident.Status != core.IncidentClosed || !incident.IsEngineeringTask() {
		return s.enqueue(
			ctx, "out_discard_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(),
			slackui.Notice(
				"*Retained work was not discarded.* This control is available only for a "+
					"closed engineering task. Close the task first so no agent turn can race "+
					"with destructive cleanup.",
			),
		)
	}
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		return err
	}
	if session.State == "discarded" {
		return s.enqueue(
			ctx, "out_discard_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(),
			slackui.Notice("*Retained work is already discarded.* No further action was needed."),
		)
	}
	if session.State != "closed" || session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		return s.enqueue(
			ctx, "out_discard_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(),
			slackui.Notice(
				"*Retained work was not discarded because the Coop session is not closed and "+
					"idle.* No files or commits were deleted.",
			),
		)
	}
	plan, _, err := s.coop.PlanDiscard(
		ctx, "responder:discard-plan:"+input.ID,
		session.ID, session.Revision, false, false,
	)
	if err != nil {
		return err
	}
	if plan.Plan.Workspace.Dirty {
		return s.enqueue(
			ctx, "out_discard_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(),
			slackui.Notice(
				"*Retained work was not discarded because the workspace has uncommitted "+
					"changes.* Automatic and operator cleanup never deletes dirty work. Inspect "+
					"the fork directly and decide how to preserve those files.",
			),
		)
	}
	if plan.Plan.Workspace.Unmerged {
		plan, _, err = s.coop.PlanDiscard(
			ctx, "responder:discard-plan-unpublished:"+input.ID,
			session.ID, session.Revision, false, true,
		)
		if err != nil {
			return err
		}
		if plan.Plan.Workspace.Dirty || !plan.Plan.Workspace.AcceptedUnmerged {
			return errors.New("Coop did not return the exact acknowledged unpublished-work discard plan")
		}
	}
	if _, _, err := s.coop.Discard(
		ctx, "responder:discard:"+input.ID, session.ID, plan.OperationID,
	); err != nil {
		return err
	}
	if err := s.store.ScheduleCleanup(
		ctx, session.ID, incident.ID, "operator discarded retained work",
		false, time.Now().UTC(),
	); err != nil {
		return err
	}
	if err := s.store.SetCleanupState(
		ctx, session.ID, "done", plan.OperationID, "", time.Now().UTC(),
	); err != nil {
		return err
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "engineering_task.discard",
		ActorID: input.UserID, ObjectID: session.ID, Outcome: "succeeded",
		Detail: "Operator explicitly discarded clean retained unpublished work.",
	})
	return s.enqueue(
		ctx, "out_discard_"+input.ID, incident, "notice",
		incident.ConversationThreadTS(),
		slackui.Notice(
			"*Retained task work discarded.* Coop verified the exact closed workspace state "+
				"before deleting its fork and private agent state. No GitHub branch, pull "+
				"request, merge, deployment, or infrastructure was changed.",
		),
	)
}

func (s *Service) retryCleanup(
	ctx context.Context,
	item core.CoopCleanup,
	cause error,
) error {
	attempt := min(item.Attempts+1, 10)
	delay := time.Duration(math.Pow(2, float64(attempt))) * time.Minute
	if delay > 6*time.Hour {
		delay = 6 * time.Hour
	}
	state := "retry"
	if !coop.Retryable(cause) && item.Attempts >= 2 {
		state = "blocked"
	}
	if err := s.store.SetCleanupState(
		ctx, item.SessionID, state, item.PlanOperationID,
		trimError(cause), time.Now().UTC().Add(delay),
	); err != nil {
		return err
	}
	if state == "blocked" {
		return nil
	}
	return cause
}
