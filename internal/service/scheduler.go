package service

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/responder/internal/retrydelay"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const (
	workSlackInput       = "slack_input"
	workSlackMembership  = "slack_membership"
	workSlackReconcile   = "slack_reconcile"
	workSlackDelivery    = "slack_delivery"
	workWebhook          = "webhook"
	workIncidentDiscover = "incident_discover"
	workIncidentChannel  = "incident_channel"
	workIncidentSession  = "incident_session"
	workAgentRun         = "agent_run"
	workAgentFinalize    = "agent_finalize"
	workEmisarApproval   = "emisar_approval"
	workCoopPoll         = "coop_poll"
	workMaintenance      = "maintenance"
	workScheduledTask    = "scheduled_task"
	workEpisodeWakeup    = "episode_wakeup"
	workPublicationTrack = "publication_followup"
	workEpisodeRecheck   = "episode_recheck"
	workLegacyPause      = "legacy_pause_cleanup"
	workReplayCancel     = "replay_cancel"
	schedulerSingletonID = "drain"
)

type laneHeartbeat struct {
	control     atomic.Int64
	background  atomic.Int64
	maintenance atomic.Int64
}

type scheduledWorkDeferral struct {
	at     time.Time
	reason string
}

func (d scheduledWorkDeferral) Error() string { return d.reason }

func deferScheduledWork(at time.Time, reason string) error {
	return scheduledWorkDeferral{at: at, reason: reason}
}

func (h *laneHeartbeat) mark(lane string, now time.Time) {
	value := now.UTC().UnixNano()
	switch lane {
	case store.WorkLaneControl:
		h.control.Store(value)
	case store.WorkLaneBackground:
		h.background.Store(value)
	case store.WorkLaneMaintenance:
		h.maintenance.Store(value)
	}
}

func (h *laneHeartbeat) time(lane string) time.Time {
	var value int64
	switch lane {
	case store.WorkLaneControl:
		value = h.control.Load()
	case store.WorkLaneBackground:
		value = h.background.Load()
	case store.WorkLaneMaintenance:
		value = h.maintenance.Load()
	}
	if value == 0 {
		return time.Time{}
	}
	return time.Unix(0, value).UTC()
}

func (s *Service) seedScheduledWork(ctx context.Context) error {
	now := s.now().UTC()
	items := []store.WorkItem{
		{Kind: workSlackInput, SubjectID: schedulerSingletonID, Lane: store.WorkLaneControl, Priority: 10},
		{Kind: workSlackReconcile, SubjectID: schedulerSingletonID, Lane: store.WorkLaneControl, Priority: 20},
		{Kind: workSlackDelivery, SubjectID: schedulerSingletonID, Lane: store.WorkLaneControl, Priority: 30},
		{Kind: workSlackMembership, SubjectID: schedulerSingletonID, Lane: store.WorkLaneMaintenance, Priority: 5},
		{Kind: workLegacyPause, SubjectID: schedulerSingletonID, Lane: store.WorkLaneMaintenance, Priority: 6},
		{Kind: workReplayCancel, SubjectID: schedulerSingletonID, Lane: store.WorkLaneMaintenance, Priority: 7},
		{Kind: workWebhook, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 10},
		{Kind: workAgentFinalize, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 20},
		{Kind: workIncidentDiscover, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 25},
		{Kind: workAgentRun, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 50},
		{Kind: workScheduledTask, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 45},
		{Kind: workEpisodeWakeup, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 44},
		{Kind: workPublicationTrack, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 47},
		{Kind: workCoopPoll, SubjectID: schedulerSingletonID, Lane: store.WorkLaneBackground, Priority: 60},
		{Kind: workMaintenance, SubjectID: schedulerSingletonID, Lane: store.WorkLaneMaintenance, Priority: 10},
	}
	// Agent submission and finalization are independently lease-safe. Seed one
	// drain per configured background worker so the configured concurrency is
	// real rather than three workers contending for one singleton work item.
	for shard := 2; shard <= s.cfg.Limits.BackgroundWorkers; shard++ {
		subject := fmt.Sprintf("drain-%d", shard)
		items = append(items,
			store.WorkItem{Kind: workAgentFinalize, SubjectID: subject, Lane: store.WorkLaneBackground, Priority: 20},
			store.WorkItem{Kind: workAgentRun, SubjectID: subject, Lane: store.WorkLaneBackground, Priority: 50},
		)
	}
	for i := range items {
		items[i].AvailableAt = now
		if err := s.store.EnqueueWork(ctx, items[i]); err != nil {
			return fmt.Errorf("seed %s scheduled work: %w", items[i].Kind, err)
		}
	}
	return s.seedEmisarApprovalWork(ctx)
}

func (s *Service) startScheduler(
	ctx context.Context,
	group *sync.WaitGroup,
) {
	for _, lane := range []struct {
		name        string
		concurrency int
	}{
		{store.WorkLaneControl, s.cfg.Limits.ControlWorkers},
		{store.WorkLaneBackground, s.cfg.Limits.BackgroundWorkers},
		{store.WorkLaneMaintenance, s.cfg.Limits.MaintenanceWorkers},
	} {
		for range lane.concurrency {
			group.Add(1)
			go func(laneName string) {
				defer group.Done()
				s.runScheduledLane(ctx, laneName)
			}(lane.name)
		}
	}
}

func (s *Service) runScheduledLane(ctx context.Context, lane string) {
	idle := s.cfg.Limits.WorkerInterval.Duration
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		s.heartbeats.mark(lane, s.now())
		item, err := s.store.LeaseWork(
			ctx,
			lane,
			s.cfg.Limits.WorkLease.Duration,
		)
		switch {
		case errors.Is(err, store.ErrNotFound):
			timer.Reset(idle)
			continue
		case err != nil:
			if ctx.Err() != nil {
				return
			}
			s.log.Error("lease scheduled work", "lane", lane, "error", err)
			timer.Reset(idle)
			continue
		}
		s.heartbeats.mark(lane, s.now())
		s.handleScheduledWork(ctx, item)
		s.heartbeats.mark(lane, s.now())
		timer.Reset(0)
	}
}

func (s *Service) handleScheduledWork(
	ctx context.Context,
	item store.WorkItem,
) {
	timeout := s.cfg.Limits.WorkerStallAfter.Duration
	workCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	err := s.runScheduledWork(workCtx, item)
	if ctx.Err() != nil {
		return
	}
	now := s.now().UTC()
	var deferral scheduledWorkDeferral
	switch {
	case err == nil:
		var completeErr error
		if recurringScheduledWork(item.Kind) {
			completeErr = s.store.DeferWork(ctx, item, now)
		} else {
			completeErr = s.store.CompleteWork(ctx, item)
		}
		if completeErr != nil {
			s.log.Error(
				"complete scheduled work",
				"kind", item.Kind,
				"subject", item.SubjectID,
				"error", completeErr,
			)
		}
	case errors.Is(err, store.ErrNotFound):
		var completeErr error
		if recurringScheduledWork(item.Kind) {
			completeErr = s.store.DeferWork(
				ctx,
				item,
				now.Add(s.scheduledIdleDelay(item.Kind)),
			)
		} else {
			completeErr = s.store.CompleteWork(ctx, item)
		}
		if completeErr != nil {
			s.log.Error(
				"complete idle scheduled work",
				"kind", item.Kind,
				"subject", item.SubjectID,
				"error", completeErr,
			)
		}
	case errors.As(err, &deferral):
		if deferErr := s.store.DeferWork(ctx, item, deferral.at); deferErr != nil {
			s.log.Error(
				"defer scheduled work",
				"kind", item.Kind,
				"subject", item.SubjectID,
				"error", deferErr,
			)
		}
	default:
		now := s.now().UTC()
		retryAfter, rateLimited := slackui.RetryAfter(err)
		next := retrydelay.At(now, item.Failures+1, retryAfter)
		if retryErr := s.store.RetryWork(
			ctx,
			item,
			trimError(err),
			next,
			false,
		); retryErr != nil {
			s.log.Error(
				"retry scheduled work",
				"kind", item.Kind,
				"subject", item.SubjectID,
				"error", retryErr,
			)
		}
		if rateLimited {
			s.log.Warn(
				"scheduled work rate limited",
				"kind", item.Kind,
				"subject", item.SubjectID,
				"retry_after", retryAfter,
			)
		} else {
			s.log.Error(
				"scheduled work failed",
				"kind", item.Kind,
				"subject", item.SubjectID,
				"error", err,
			)
		}
	}
}

func recurringScheduledWork(kind string) bool {
	switch kind {
	case workSlackInput,
		workSlackMembership,
		workSlackReconcile,
		workSlackDelivery,
		workWebhook,
		workIncidentDiscover,
		workAgentRun,
		workAgentFinalize,
		workCoopPoll,
		workMaintenance,
		workScheduledTask,
		workEpisodeWakeup,
		workPublicationTrack,
		workLegacyPause,
		workReplayCancel:
		return true
	default:
		return false
	}
}

func (s *Service) scheduledIdleDelay(kind string) time.Duration {
	switch kind {
	case workCoopPoll:
		return s.cfg.Coop.PollInterval.Duration
	case workSlackMembership:
		return time.Minute
	case workPublicationTrack:
		return s.cfg.GitHub.FollowupInterval.Duration
	case workMaintenance:
		return s.cfg.Retention.MaintenanceInterval.Duration
	case workLegacyPause:
		return time.Minute
	default:
		return s.cfg.Limits.WorkerInterval.Duration
	}
}

func (s *Service) runScheduledWork(
	ctx context.Context,
	item store.WorkItem,
) error {
	switch item.Kind {
	case workSlackInput:
		return s.processSlackInput(ctx)
	case workSlackMembership:
		return s.reconcileSlackChannelMemberships(ctx)
	case workSlackReconcile:
		return s.reconcileSlackDelivery(ctx)
	case workSlackDelivery:
		return s.processSlackWrite(ctx)
	case workWebhook:
		return s.processWebhook(ctx)
	case workIncidentDiscover:
		return s.scheduleIncidentWork(ctx)
	case workIncidentChannel:
		return s.processChannelIncident(ctx, item.SubjectID)
	case workIncidentSession:
		return s.processSessionIncident(ctx, item.SubjectID)
	case workAgentRun:
		return s.processAgentRun(ctx)
	case workAgentFinalize:
		return s.processAgentRunFinalization(ctx)
	case workEmisarApproval:
		return s.processEmisarApproval(ctx, item.SubjectID)
	case workCoopPoll:
		s.pollAgentRuns(ctx)
		s.pollCoop(ctx)
		return store.ErrNotFound
	case workMaintenance:
		s.runMaintenance(ctx)
		return store.ErrNotFound
	case workLegacyPause:
		return s.processLegacyPauseCleanup(ctx)
	case workReplayCancel:
		return s.processReplayCancellation(ctx)
	case workScheduledTask:
		return s.processScheduledTasks(ctx)
	case workEpisodeWakeup:
		return s.processEpisodeWakeup(ctx)
	case workPublicationTrack:
		return s.processPublicationFollowup(ctx)
	case workExternalMessageReconcile:
		return s.reconcileExternalMessage(ctx, item)
	case workEpisodeRecheck:
		return s.processEpisodeRecheck(ctx, item)
	default:
		return fmt.Errorf("unsupported scheduled work kind %q", item.Kind)
	}
}

func (s *Service) scheduleIncidentWork(ctx context.Context) error {
	channelWork, err := s.store.ListChannelWork(ctx, 100)
	if err != nil {
		return err
	}
	rootWork, err := s.store.ListRootWork(ctx, 100)
	if err != nil {
		return err
	}
	sessionWork, err := s.store.ListSessionWork(ctx, 100)
	if err != nil {
		return err
	}
	scheduled := 0
	for _, incident := range append(channelWork, rootWork...) {
		if err := s.store.EnsureWork(ctx, store.WorkItem{
			Kind: workIncidentChannel, SubjectID: incident.ID,
			Lane:            store.WorkLaneBackground,
			ConversationKey: "incident:" + incident.ID,
			Priority:        30,
		}); err != nil {
			return err
		}
		scheduled++
	}
	for _, incident := range sessionWork {
		if err := s.store.EnsureWork(ctx, store.WorkItem{
			Kind: workIncidentSession, SubjectID: incident.ID,
			Lane:            store.WorkLaneBackground,
			ConversationKey: "incident:" + incident.ID,
			Priority:        40,
		}); err != nil {
			return err
		}
		scheduled++
	}
	if scheduled == 0 {
		return store.ErrNotFound
	}
	return nil
}
