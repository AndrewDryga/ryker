package service

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/taskpr"
)

const cleanupRetryLimit = 12

func (s *Service) maintainLifecycle(ctx context.Context) {
	now := s.now().UTC()
	if err := s.maintainMemory(ctx, now); err != nil && ctx.Err() == nil {
		s.log.Warn("memory consolidation failed", "error", err)
	}
	grace := s.cfg.Retention.ClosedSessionGrace.Duration
	if err := s.reconcileOrphanedResponderSessions(ctx, now.Add(-grace), now); err != nil &&
		ctx.Err() == nil {
		s.log.Warn("orphaned Coop session reconciliation failed", "error", err)
	}
	s.surfaceOverdueEpisodes(ctx, now)
	if _, err := s.store.ScheduleExpiredChannelMemoryCleanup(
		ctx,
		now.Add(-s.cfg.Coop.WatchSessionAge.Duration),
		now,
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
	// Lapsing a correction is an event, so it is said out loud.
	//
	// ExpireFixtureCandidates had exactly one caller and it was its own test,
	// so the 'expired' status was unreachable in production and three surfaces
	// disagreed about what was pending: Slack filtered on expiry and hid a
	// fourteen-day-old candidate, the dashboard did not filter and showed it
	// forever, and the Prometheus gauge filtered and therefore disagreed with
	// the dashboard's badge. Running it here makes the row say what all three
	// already implied.
	//
	// It logs at info even for one, because a lapsed correction is a lesson
	// nobody got round to keeping. Fifteen of them expiring in silence is how
	// two weeks of real corrections would have been lost without a line
	// anywhere saying so.
	if expired, err := s.store.ExpireFixtureCandidates(ctx, now); err != nil && ctx.Err() == nil {
		s.log.Warn("expire unreviewed corrections failed", "error", err)
	} else if expired > 0 {
		s.log.Info(
			"corrections lapsed unreviewed; the lesson each carried is not kept",
			"records", expired,
		)
	}
	const cleanupBatch = 128
	for range cleanupBatch {
		err := s.processCleanup(ctx, now)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			if ctx.Err() == nil {
				s.log.Warn("Coop cleanup failed", "error", err)
			}
			continue
		}
	}
	repositories := s.cfg.RepositoryContextKeys()
	if pruned, err := s.store.Memory.PruneOrphanMemoryEntries(ctx, repositories); err != nil &&
		ctx.Err() == nil {
		s.log.Warn("orphaned operational memory pruning failed", "error", err)
	} else if pruned > 0 {
		s.log.Info("pruned orphaned operational memory", "records", pruned)
	}
	if preferences, rules, err := s.store.Behavior.PruneOrphanBehavior(ctx, repositories); err != nil &&
		ctx.Err() == nil {
		s.log.Warn("orphaned Responder behavior pruning failed", "error", err)
	} else if preferences+rules > 0 {
		s.log.Info(
			"pruned orphaned Responder behavior",
			"preferences", preferences,
			"rules", rules,
		)
	}
	if schedules, err := s.store.Schedules.PruneOrphanSchedules(ctx, repositories); err != nil && ctx.Err() == nil {
		s.log.Warn("orphaned scheduled task pruning failed", "error", err)
	} else if schedules > 0 {
		s.log.Info("pruned orphaned scheduled tasks", "records", schedules)
	}
	result, err := s.store.Prune(
		ctx,
		now.Add(-s.cfg.Retention.OperationalData.Duration),
		now.Add(-s.cfg.Retention.ConversationMemory.Duration),
		now.Add(-s.cfg.Retention.ClosedWork.Duration),
		now.Add(-s.cfg.Retention.EpisodeHistory.Duration),
		now.Add(-s.cfg.Retention.AuditData.Duration),
	)
	if err != nil {
		if ctx.Err() == nil {
			s.log.Warn("Responder state pruning failed", "error", err)
		}
		return
	}
	if pruneResultWorthLogging(result) {
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
			"emisar_approvals", result.EmisarApprovals,
			"configuration_sessions", result.ConfigurationSessions,
			"closed_work", result.ClosedIncidents,
			"episodes", result.Episodes,
			"agent_run_contexts", result.AgentRunContexts,
			"audit", result.AuditEvents,
			"retention", result.Retention,
		)
	}
}

func pruneResultWorthLogging(result core.PruneResult) bool {
	if result.Total() >= 25 {
		return true
	}
	// Episodes and emptied contexts are always worth a line even one at a time.
	// Episode history is the record the replay corpus is built from, so a pass
	// that expires any of it should be visible without waiting for two dozen
	// rows of queue churn to make the threshold; and AgentRunContexts is not in
	// Total at all, so without naming it here a pass that reclaimed megabytes
	// could log nothing.
	return result.MemoryEntries+result.MemoryRollups+result.MemoryReviews+
		result.MemorySupersessions+result.Preferences+result.StandingRules+
		result.ScheduledTasks+result.ClosedIncidents+
		result.Episodes+result.AgentRunContexts > 0
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
		if session.State == "discarded" {
			cleanup, err := s.store.GetCoopCleanup(ctx, session.ID)
			if errors.Is(err, store.ErrNotFound) {
				continue
			}
			if err != nil {
				return err
			}
			if cleanup.State != "done" {
				if err := s.store.SetCleanupState(
					ctx, session.ID, "done", cleanup.PlanOperationID, "", eligibleAt,
				); err != nil {
					return err
				}
				s.log.Info(
					"reconciled discarded Coop session cleanup",
					"session_id", session.ID,
					"prior_state", cleanup.State,
				)
			}
			continue
		}
		if session.UpdatedAt.After(staleBefore) ||
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
		if coopSessionNotFound(err) {
			return s.store.SetCleanupState(ctx, item.SessionID, "done", "", "", now)
		}
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
		fmt.Sprintf(
			"responder:gc-plan:%s:%d:%d",
			item.SessionID, session.Revision, item.Attempts,
		),
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
	cleanBaseline := taskpr.SessionHead(session)
	if plan.Plan.Workspace.Unmerged {
		cleanAtBase := !plan.Plan.Workspace.Dirty && cleanBaseline != "" &&
			plan.Plan.Workspace.Head == cleanBaseline
		if !item.AllowUnmerged && !cleanAtBase {
			return s.store.SetCleanupState(
				ctx, item.SessionID, "blocked", plan.OperationID,
				"workspace has unpublished committed changes; publish or explicitly discard them",
				now,
			)
		}
		if item.AllowUnmerged {
			if err := s.verifyPublishedCleanupTree(ctx, item, plan); err != nil {
				return s.store.SetCleanupState(
					ctx, item.SessionID, "blocked", plan.OperationID,
					trimError(err), now,
				)
			}
		}
		plan, _, err = s.coop.PlanDiscard(
			ctx, fmt.Sprintf(
				"responder:gc-plan-accept-unmerged:%s:%d:%d",
				item.SessionID, session.Revision, item.Attempts,
			),
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
		if item.AllowUnmerged {
			if err := s.verifyPublishedCleanupTree(ctx, item, plan); err != nil {
				return s.store.SetCleanupState(
					ctx, item.SessionID, "blocked", plan.OperationID,
					trimError(err), now,
				)
			}
		} else if cleanBaseline == "" || plan.Plan.Workspace.Head != cleanBaseline {
			return s.store.SetCleanupState(
				ctx, item.SessionID, "blocked", plan.OperationID,
				"workspace changed while cleanup was being planned", now,
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
	resolver, ok := s.publisher.(treeResolverAPI)
	if !ok {
		return errors.New("publication tree resolver is unavailable")
	}
	tree, err := resolver.ResolveTree(ctx, repository.Path, plan.Plan.Workspace.Head)
	if err != nil {
		return fmt.Errorf("resolve closed fork tree: %w", err)
	}
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
		return s.refuseControl(ctx, input, incident,
			"*Retained work was not discarded.* This control is available only for a "+
				"closed engineering task. Close the task first so no agent turn can race "+
				"with destructive cleanup.")
	}
	// A session Coop has already discarded, or has forgotten entirely, still
	// leaves a cleanup row behind. Nothing is needed of Coop; the row itself is
	// the remaining work, and closing it out is the action.
	//
	// It says nothing in Slack, because there is nothing to say. Both sentences
	// it used to post — "already discarded, no further action was needed" and
	// "already gone, the cleanup record has been closed" — announce that
	// nothing happened, in a room full of people who did not ask. Six of them
	// went out in two minutes when the workspaces were cleared from the
	// dashboard, which is the whole case against them: an operator working on
	// one surface generated a burst of notifications on another, and not one
	// carried news.
	//
	// The audit row is the record. It always was; the post was decoration on
	// top of it.
	closeOut := func(detail string) error {
		if err := s.store.SetCleanupState(
			ctx, incident.CoopSessionID, "done", "", "", s.now().UTC(),
		); err != nil {
			return err
		}
		s.audit(ctx, core.AuditEvent{
			IncidentID: incident.ID, Kind: "engineering_task.discard",
			ActorID: input.UserID, ObjectID: incident.CoopSessionID,
			Outcome: "succeeded", Detail: detail,
		})
		return nil
	}
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
	var apiErr *coop.APIError
	if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
		return closeOut("Coop no longer knows this session; the cleanup record was the last reference to a fork that is already gone.")
	}
	if err != nil {
		return err
	}
	if session.State == "discarded" {
		return closeOut("Coop had already discarded this session; only the cleanup record was still open.")
	}
	if session.State != "closed" || session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		return s.refuseControl(ctx, input, incident,
			"*Retained work was not discarded because the Coop session is not closed and "+
				"idle.* No files or commits were deleted.")
	}
	plan, _, err := s.coop.PlanDiscard(
		ctx, "responder:discard-plan:"+input.ID,
		session.ID, session.Revision, false, false,
	)
	if err != nil {
		return err
	}
	if plan.Plan.Workspace.Dirty {
		return s.refuseControl(ctx, input, incident,
			"*Retained work was not discarded because the workspace has uncommitted "+
				"changes.* Automatic and operator cleanup never deletes dirty work. Inspect "+
				"the fork directly and decide how to preserve those files.")
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
		false, s.now().UTC(),
	); err != nil {
		return err
	}
	if err := s.store.SetCleanupState(
		ctx, session.ID, "done", plan.OperationID, "", s.now().UTC(),
	); err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
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
	if (!coop.Retryable(cause) && item.Attempts >= 2) ||
		item.Attempts+1 >= cleanupRetryLimit {
		state = "blocked"
	}
	if err := s.store.SetCleanupState(
		ctx, item.SessionID, state, item.PlanOperationID,
		trimError(cause), s.now().UTC().Add(delay),
	); err != nil {
		return err
	}
	if state == "blocked" {
		return nil
	}
	return cause
}

func coopSessionNotFound(err error) bool {
	var apiErr *coop.APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	return apiErr.Status == 404 || apiErr.Code == "not_found" ||
		apiErr.Code == "session_not_found"
}
