package service

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func (s *Service) processWebhook(ctx context.Context) error {
	event, err := s.store.LeaseWebhook(ctx)
	if err != nil {
		return err
	}
	route, ok := s.cfg.Webhooks[event.Route]
	if !ok {
		return s.store.RetryWebhook(ctx, event.ID, "webhook route was removed from configuration", time.Now(), true)
	}
	var incidents []core.Incident
	var applyErr error
	if event.Applied {
		for _, incidentID := range event.IncidentIDs {
			incident, err := s.store.GetIncident(ctx, incidentID)
			if err != nil {
				return s.store.RetryWebhook(ctx, event.ID, trimError(err), queueDelay(event.Attempts), false)
			}
			incidents = append(incidents, incident)
		}
	} else {
		incidents, applyErr = s.store.ApplySignals(
			ctx, event, route.CorrelationWindow.Duration, route.ResolveAfter.Duration,
			s.cfg.Limits.MaxOpenIncidents,
		)
		if applyErr != nil && len(incidents) == 0 {
			terminal := terminalAttempt(event.Attempts, s.cfg.Limits.MaxOutboxAttempts)
			return s.store.RetryWebhook(
				ctx, event.ID, trimError(applyErr), queueDelay(event.Attempts), terminal,
			)
		}
	}
	for _, incident := range incidents {
		if incident.Status == core.IncidentClosed || incident.Workflow == core.WorkflowClosed {
			continue
		}
		if !incident.ChannelWritable() && incident.ChannelID != "" {
			continue
		}
		signals := signalsForIncident(event.Signals, incident)
		for _, signal := range signals {
			_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
				ID:         "tl_alert_" + event.ID + "_" + signal.SourceID,
				IncidentID: incident.ID, ChannelID: incident.ChannelID,
				Kind: "alert." + string(signal.Status), ActorID: signal.Route,
				Title:     signal.Title,
				Detail:    signal.Summary,
				CreatedAt: signal.ReceivedAt,
			})
		}
		if incident.InitialTurnQueued {
			prompt, err := signalPrompt(signals)
			if err != nil {
				if errors.Is(err, errEvidenceTooLarge) {
					_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowBlocked, trimError(err))
				}
				return s.store.RetryWebhook(ctx, event.ID, trimError(err), time.Now(), true)
			}
			if _, _, err := s.store.QueueTurn(ctx, core.TurnSubmission{
				IncidentID: incident.ID, SourceKind: "webhook",
				SourceID: event.ID + ":" + incident.ID, Prompt: prompt,
			}); err != nil {
				return s.store.RetryWebhook(ctx, event.ID, trimError(err), queueDelay(event.Attempts), false)
			}
		}
	}
	if applyErr != nil {
		terminal := terminalAttempt(event.Attempts, s.cfg.Limits.MaxOutboxAttempts)
		return s.store.RetryWebhook(
			ctx, event.ID, trimError(applyErr), queueDelay(event.Attempts), terminal,
		)
	}
	if err := s.store.FinishWebhook(ctx, event.ID); err != nil {
		_ = s.store.RetryWebhook(ctx, event.ID, trimError(err), queueDelay(event.Attempts), false)
		return err
	}
	return nil
}

func (s *Service) processChannel(ctx context.Context) error {
	incidents, err := s.store.ListChannelWork(ctx, 1)
	if err != nil {
		return err
	}
	if len(incidents) == 0 {
		incidents, err = s.store.ListRootWork(ctx, 1)
		if err != nil || len(incidents) == 0 {
			if err == nil {
				return store.ErrNotFound
			}
			return err
		}
		incident := incidents[0]
		body, err := s.incidentCard(ctx, incident)
		if err != nil {
			return err
		}
		if err := s.enqueue(
			ctx, "out_root_"+incident.ID, incident, "root",
			incident.ConversationThreadTS(),
			body,
		); err != nil {
			return err
		}
		return nil
	}
	incident := incidents[0]
	key := "channel:" + incident.ID
	if !s.canRetry(key) {
		return nil
	}
	if incident.IsThreadScoped() {
		if err := s.store.BindThreadWork(ctx, incident.ID); err != nil {
			s.retryLater(key)
			return err
		}
		incident.ChannelID = incident.OriginChannelID
		incident.ChannelState = core.ChannelActive
		body, err := s.incidentCard(ctx, incident)
		if err != nil {
			s.retryLater(key)
			return err
		}
		if err := s.enqueue(
			ctx,
			"out_root_"+incident.ID,
			incident,
			"root",
			incident.ConversationThreadTS(),
			body,
		); err != nil {
			s.retryLater(key)
			return err
		}
		s.retryDone(key)
		_ = s.store.Audit(ctx, core.AuditEvent{
			IncidentID: incident.ID, Kind: "slack.thread.bound",
			ObjectID: incident.OriginChannelID + ":" + incident.OriginThreadTS,
			Outcome:  "succeeded",
			Detail:   "engineering task remains in its source thread",
		})
		_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
			IncidentID: incident.ID, ChannelID: incident.ChannelID,
			Kind: "slack.thread.bound", ActorID: "responder",
			Title:  "Engineering task started in source thread",
			Detail: incident.OriginThreadTS,
		})
		return nil
	}
	name := slackui.ChannelName(s.cfg.Slack.ChannelPrefix, incident)
	channel, err := s.slack.CreateChannel(ctx, name, s.cfg.Slack.PrivateChannels, s.cfg.Slack.TeamID)
	if err != nil {
		channel, err = s.adoptChannel(ctx, incident, name, err)
	}
	if err != nil {
		s.retryLater(key)
		_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowProvisioningChannel, trimError(err))
		return nil
	}
	if err := s.store.SetChannel(ctx, incident.ID, channel.ID, channel.Name); err != nil {
		s.retryLater(key)
		return err
	}
	incident.ChannelID = channel.ID
	incident.ChannelName = channel.Name
	body, err := s.incidentCard(ctx, incident)
	if err != nil {
		s.retryLater(key)
		return err
	}
	if err := s.enqueue(ctx, "out_root_"+incident.ID, incident, "root", "", body); err != nil {
		s.retryLater(key)
		return err
	}
	s.retryDone(key)
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "slack.channel.created", ObjectID: channel.ID,
		Outcome: "succeeded", Detail: channel.Name,
	})
	_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
		IncidentID: incident.ID, ChannelID: channel.ID,
		Kind: "slack.channel.created", ActorID: "responder",
		Title: map[bool]string{
			true: "Engineering room created", false: "Incident room created",
		}[incident.IsEngineeringTask()],
		Detail: channel.Name,
	})
	return nil
}

func (s *Service) adoptChannel(
	ctx context.Context,
	incident core.Incident,
	name string,
	createErr error,
) (slackui.Channel, error) {
	channel, findErr := s.slack.FindChannelByName(ctx, name, s.cfg.Slack.TeamID)
	if findErr != nil {
		return slackui.Channel{}, createErr
	}
	earliest := incident.CreatedAt.Add(-2 * time.Minute)
	if channel.Creator != s.identity.BotUserID || channel.Created.IsZero() ||
		channel.Created.Before(earliest) || channel.Shared ||
		channel.Private != s.cfg.Slack.PrivateChannels {
		return slackui.Channel{}, fmt.Errorf("Slack channel %q exists but cannot be safely adopted", name)
	}
	return channel, nil
}

func (s *Service) processSlackWrite(ctx context.Context) error {
	if time.Since(s.lastPost) < 1100*time.Millisecond {
		return nil
	}
	first, second := s.processOutbox, s.processCard
	if s.preferCard {
		first, second = second, first
	}
	err := first(ctx)
	if errors.Is(err, store.ErrNotFound) {
		err = second(ctx)
	}
	if !errors.Is(err, store.ErrNotFound) {
		s.preferCard = !s.preferCard
	}
	return err
}

func (s *Service) processOutbox(ctx context.Context) error {
	item, err := s.store.LeaseOutbox(ctx)
	if err != nil {
		return err
	}
	incident, incidentErr := s.store.GetIncident(ctx, item.IncidentID)
	if incidentErr != nil {
		return s.store.RetryOutbox(
			ctx, item.ID, trimError(incidentErr), time.Now(), false, true,
		)
	}
	if item.ChannelID == incident.ChannelID && !incident.ChannelWritable() {
		return s.store.RetryOutbox(
			ctx,
			item.ID,
			"Slack delivery suppressed because the work conversation is "+string(incident.ChannelState),
			time.Now(),
			false,
			true,
		)
	}
	message, err := slackui.Decode(item.Body)
	if err != nil {
		retryErr := s.store.RetryOutbox(ctx, item.ID, trimError(err), time.Now(), false, true)
		if incident, incidentErr := s.store.GetIncident(ctx, item.IncidentID); incidentErr == nil {
			_ = s.store.SetIncidentError(ctx, incident.ID, incident.Workflow, trimError(err))
		}
		return retryErr
	}
	timestamp, err := s.slack.Post(ctx, item.ID, item.ChannelID, item.ThreadTS, message)
	s.lastPost = time.Now()
	if err != nil {
		terminal := terminalAttempt(item.Attempts, s.cfg.Limits.MaxOutboxAttempts)
		return s.store.RetryOutbox(ctx, item.ID, trimError(err), queueDelay(item.Attempts), true, terminal)
	}
	if err := s.store.FinishOutbox(ctx, item.ID, timestamp); err != nil {
		_ = s.store.RetryOutbox(
			ctx, item.ID, "Slack accepted the message but local confirmation failed",
			queueDelay(item.Attempts), true, false,
		)
		return err
	}
	if item.ThreadTS != "" {
		s.retryDone("native-status:" + item.IncidentID + "@" + item.ThreadTS)
		s.forgetNativeStatus(item.IncidentID)
		if incident, incidentErr := s.store.GetIncident(ctx, item.IncidentID); incidentErr == nil &&
			incident.ActiveTurnID != "" {
			s.setNativeStatus(
				ctx,
				s.turnStatusIncident(ctx, incident, incident.ActiveTurnID),
				"is investigating...",
			)
		}
	}
	return nil
}

func (s *Service) reconcileOutbox(ctx context.Context) error {
	items, err := s.store.ListUncertainOutbox(ctx, 1)
	if err != nil || len(items) == 0 {
		if err == nil {
			return store.ErrNotFound
		}
		return err
	}
	item := items[0]
	incident, incidentErr := s.store.GetIncident(ctx, item.IncidentID)
	if incidentErr != nil {
		return incidentErr
	}
	if item.ChannelID == incident.ChannelID && !incident.ChannelWritable() {
		return s.store.RetryUncertainOutbox(
			ctx,
			item.ID,
			"Slack reconciliation suppressed because the work conversation is "+
				string(incident.ChannelState),
			time.Now(),
			true,
		)
	}
	key := "outbox-reconcile:" + item.ID
	if !s.canRetry(key) {
		return nil
	}
	timestamp, err := s.slack.FindOutboxMessage(ctx, item.ChannelID, item.ThreadTS, item.ID)
	switch {
	case err == nil:
		s.retryDone(key)
		return s.store.ResolveUncertainOutbox(ctx, item.ID, timestamp)
	case errors.Is(err, slackui.ErrNotFound):
		s.retryDone(key)
		terminal := terminalAttempt(item.Attempts, s.cfg.Limits.MaxOutboxAttempts)
		retryErr := s.store.RetryUncertainOutbox(
			ctx, item.ID, "Slack history confirmed the message was not posted",
			queueDelay(item.Attempts), terminal,
		)
		if terminal {
			if incident, incidentErr := s.store.GetIncident(ctx, item.IncidentID); incidentErr == nil {
				_ = s.store.SetIncidentError(
					ctx, incident.ID, incident.Workflow,
					"Slack delivery failed after the configured retry limit.",
				)
			}
		}
		return retryErr
	default:
		s.retryLater(key)
		return nil
	}
}

func (s *Service) processSession(ctx context.Context) error {
	incidents, err := s.store.ListSessionWork(ctx, 1)
	if err != nil || len(incidents) == 0 {
		if err == nil {
			return store.ErrNotFound
		}
		return err
	}
	incident := incidents[0]
	key := "session:" + incident.ID
	if !s.canRetry(key) {
		return nil
	}
	if !incident.IsThreadScoped() {
		if err := s.prepareChannel(ctx, incident); err != nil {
			s.retryLater(key)
			_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowHolding, trimError(err))
			return nil
		}
		if err := s.enqueueManualHandoff(ctx, incident); err != nil {
			s.retryLater(key)
			return err
		}
	}
	open, err := s.store.CountOpenSessions(ctx)
	if err != nil {
		return err
	}
	if open >= s.cfg.Limits.MaxActiveIncidents {
		s.retryLater(key)
		detail := "Responder is at its configured active incident limit; this incident is queued."
		if incident.IsEngineeringTask() {
			detail = "Responder is at its configured active work limit; this engineering task is queued."
		}
		_ = s.store.SetIncidentError(
			ctx, incident.ID, core.WorkflowHolding,
			detail,
		)
		return nil
	}
	repository, ok := s.cfg.Repositories[incident.Repository]
	if !ok {
		return s.store.SetIncidentError(ctx, incident.ID, core.WorkflowBlocked, "repository binding was removed")
	}
	if err := s.queueInitialTurn(ctx, incident); err != nil {
		if errors.Is(err, errEvidenceTooLarge) {
			_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowBlocked, trimError(err))
			s.retryDone(key)
			return nil
		}
		s.retryLater(key)
		return err
	}
	sessionLabel := "incident:" + incident.ID
	if incident.IsEngineeringTask() {
		sessionLabel = "engineering-task:" + incident.ID
	}
	session, _, err := s.coop.CreateSession(
		ctx, "responder:session:"+incident.ID, repository.CoopPolicy, sessionLabel,
	)
	if err != nil {
		s.retryLater(key)
		workflow := core.WorkflowHolding
		if !coop.Retryable(err) {
			workflow = core.WorkflowBlocked
		}
		_ = s.store.SetIncidentError(ctx, incident.ID, workflow, trimError(err))
		return nil
	}
	if err := s.store.SetCoopSession(ctx, incident.ID, session.ID, session.ForkName, session.Revision); err != nil {
		s.retryLater(key)
		return err
	}
	incident.CoopSessionID = session.ID
	incident.CoopForkName = session.ForkName
	incident.CoopRevision = session.Revision
	s.retryDone(key)
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "coop.session.created", ObjectID: session.ID,
		Outcome: "succeeded", Detail: repository.CoopPolicy,
	})
	timelineTitle := "Isolated investigation started"
	if incident.IsEngineeringTask() {
		timelineTitle = "Isolated engineering task started"
	}
	_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
		IncidentID: incident.ID, ChannelID: incident.ChannelID,
		Kind: "coop.session.created", ActorID: "responder",
		Title:  timelineTitle,
		Detail: "Coop session " + session.ID + " using policy " + repository.CoopPolicy,
	})
	return nil
}

func (s *Service) prepareChannel(ctx context.Context, incident core.Incident) error {
	if err := s.slack.Invite(ctx, incident.ChannelID, s.inviteUsers()...); err != nil {
		return fmt.Errorf("invite responders: %w", err)
	}
	workLabel := "Incident"
	if incident.IsEngineeringTask() {
		workLabel = "Engineering task"
	}
	topic := s.sanitizer.Text(fmt.Sprintf(
		"%s %s | %s | managed by Responder",
		workLabel, slackui.ShortID(incident.ID), incident.Title,
	))
	if err := s.slack.SetTopic(ctx, incident.ChannelID, topic); err != nil {
		return fmt.Errorf("set working room topic: %w", err)
	}
	if err := s.slack.Pin(ctx, incident.ChannelID, incident.RootTS); err != nil {
		return fmt.Errorf("pin work card: %w", err)
	}
	return nil
}

func (s *Service) inviteUsers() []string {
	seen := make(map[string]bool, len(s.cfg.Slack.Operators)+len(s.cfg.Slack.InviteUsers))
	users := make([]string, 0, len(s.cfg.Slack.Operators)+len(s.cfg.Slack.InviteUsers))
	for _, user := range append(append([]string(nil), s.cfg.Slack.Operators...), s.cfg.Slack.InviteUsers...) {
		if !seen[user] {
			seen[user] = true
			users = append(users, user)
		}
	}
	return users
}

func (s *Service) queueInitialTurn(ctx context.Context, incident core.Incident) error {
	signals, err := s.store.ListSignals(ctx, incident.ID)
	if err != nil {
		return err
	}
	prior, err := s.loadOperationalMemoryContext(
		ctx,
		incident.ChannelID,
		incident.Repository,
		"",
		incident.ID,
	)
	if err != nil {
		return err
	}
	prompt, err := initialPrompt(
		s.cfg.Coop.Instructions,
		incident,
		signals,
		operationalMemoryPrompt(prior),
	)
	if err != nil {
		return err
	}
	if _, _, err := s.store.QueueTurn(ctx, core.TurnSubmission{
		IncidentID: incident.ID, SourceKind: "initial", SourceID: incident.ID, Prompt: prompt,
	}); err != nil {
		return err
	}
	if incident.InitialTurnQueued {
		return nil
	}
	err = s.store.MarkInitialTurnQueued(ctx, incident.ID)
	if errors.Is(err, store.ErrConflict) {
		return nil
	}
	return err
}

func (s *Service) processTurn(ctx context.Context) error {
	item, err := s.store.LeaseTurnSubmission(ctx)
	if err != nil {
		return err
	}
	key := "turn:" + item.ID
	if !s.canRetry(key) {
		return s.store.RetryTurnSubmission(ctx, item.ID, "waiting to retry Coop", queueDelay(item.Attempts), false)
	}
	incident, err := s.store.GetIncident(ctx, item.IncidentID)
	if err != nil {
		return s.store.RetryTurnSubmission(ctx, item.ID, trimError(err), time.Now(), true)
	}
	if !incident.ChannelWritable() {
		return s.store.RetryTurnSubmission(
			ctx,
			item.ID,
			"agent turn suppressed because the Slack work conversation is "+
				string(incident.ChannelState),
			time.Now(),
			true,
		)
	}
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		return s.store.RetryTurnSubmission(
			ctx, item.ID, trimError(err), queueDelay(item.Attempts), !coop.Retryable(err),
		)
	}
	if session.State == "closed" {
		return s.store.RetryTurnSubmission(
			ctx, item.ID, "the Coop session is closed", time.Now(), true,
		)
	}
	session, err = s.ensureTurnCapacity(
		ctx, incident.ChannelID, incident.ID, session,
	)
	if err != nil {
		var limitErr *automaticTurnLimitError
		if errors.As(err, &limitErr) {
			detail := turnLimitReachedMessage(limitErr.Limit)
			_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowBlocked, detail)
			return s.store.RetryTurnSubmission(
				ctx, item.ID, detail, time.Now().Add(30*time.Second), false,
			)
		}
		detail := "Responder could not allocate additional automatic session capacity: " +
			trimError(err) + ". The pending request and Coop session are preserved; " +
			"Responder will retry after the Coop limit or service error is corrected."
		_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowParked, detail)
		return s.store.RetryTurnSubmission(
			ctx, item.ID, detail, queueDelay(item.Attempts), false,
		)
	}
	if session.State != "open" {
		return s.store.RetryTurnSubmission(
			ctx,
			item.ID,
			fmt.Sprintf("Coop session has unsupported state %q", session.State),
			time.Now(),
			true,
		)
	}
	revision, err := s.store.FreezeTurnRevision(ctx, item.ID, session.Revision)
	if err != nil {
		return s.store.RetryTurnSubmission(ctx, item.ID, trimError(err), time.Now(), true)
	}
	turn, _, err := s.coop.SubmitTurn(
		ctx,
		item.IdempotencyKey,
		incident.CoopSessionID,
		revision,
		item.Prompt+"\n\n"+s.structuredResponsePolicy(),
	)
	if err != nil {
		s.retryLater(key)
		terminal := !coop.Retryable(err)
		retryErr := s.store.RetryTurnSubmission(
			ctx, item.ID, trimError(err), queueDelay(item.Attempts), terminal,
		)
		if terminal {
			_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowParked, trimError(err))
			s.clearNativeStatus(ctx, incident)
		}
		return retryErr
	}
	session, err = s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		s.retryLater(key)
		return s.store.RetryTurnSubmission(ctx, item.ID, trimError(err), queueDelay(item.Attempts), false)
	}
	if err := s.store.MarkTurnSubmitted(ctx, item.ID, turn.ID, session.Revision); err != nil {
		s.retryLater(key)
		_ = s.store.RetryTurnSubmission(ctx, item.ID, trimError(err), queueDelay(item.Attempts), false)
		return err
	}
	s.retryDone(key)
	s.setNativeStatus(ctx, s.turnSubmissionStatusIncident(ctx, incident, item), "is investigating...")
	return nil
}

func (s *Service) pollCoop(ctx context.Context) {
	incidents, err := s.store.ListBoundIncidents(ctx, 100)
	if err != nil {
		s.log.Error("list Coop sessions", "error", err)
		return
	}
	for _, incident := range incidents {
		if err := s.pollIncident(ctx, incident); err != nil && ctx.Err() == nil {
			s.log.Warn("poll Coop incident", "incident", incident.ID, "error", err)
		}
	}
}

func (s *Service) pollIncident(ctx context.Context, incident core.Incident) error {
	events, err := s.coop.Events(ctx, incident.CoopSessionID, incident.CoopEventSequence, 100)
	if err != nil {
		return err
	}
	cursor := incident.CoopEventSequence
	for _, event := range events {
		if event.Sequence > cursor {
			cursor = event.Sequence
		}
		switch event.Type {
		case "turn.completed", "turn.failed", "turn.cancelled":
			if err := s.completeTurn(ctx, incident, event); err != nil {
				return err
			}
		}
	}
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		return err
	}
	workflow := core.WorkflowParked
	switch {
	case session.State == "closed" && !incident.ChannelWritable():
		workflow = core.WorkflowBlocked
	case session.State == "closed":
		if incident.Status != core.IncidentClosed {
			return s.store.CloseIncident(ctx, incident.ID)
		}
		workflow = core.WorkflowClosed
	case session.State == "exhausted":
		limit, limitErr := s.effectiveTurnLimit(ctx, incident.ChannelID)
		if limitErr != nil {
			return limitErr
		}
		if session.MaxTurns >= limit {
			workflow = core.WorkflowBlocked
		}
	case session.ActiveTurnID != "":
		workflow = core.WorkflowInvestigating
	case session.QueuedTurnCount > 0:
		workflow = core.WorkflowInvestigating
	}
	if session.ActiveTurnID != "" {
		s.setNativeStatus(
			ctx,
			s.turnStatusIncident(ctx, incident, session.ActiveTurnID),
			"is investigating...",
		)
	}
	if !incident.ChannelWritable() && incident.Status != core.IncidentClosed {
		workflow = core.WorkflowBlocked
	}
	if err := s.store.UpdateCoopState(
		ctx, incident.ID, session.Revision, cursor, session.ActiveTurnID, workflow,
	); err != nil {
		return err
	}
	if !incident.ChannelWritable() && incident.Status != core.IncidentClosed {
		return s.store.SetIncidentError(
			ctx, incident.ID, core.WorkflowBlocked, incidentChannelStateError(incident),
		)
	}
	if session.State == "exhausted" {
		limit, err := s.effectiveTurnLimit(ctx, incident.ChannelID)
		if err != nil {
			return err
		}
		detail := ""
		if session.MaxTurns >= limit {
			detail = turnLimitReachedMessage(limit)
		}
		if incident.Workflow == workflow && incident.LastError == detail {
			return nil
		}
		s.clearNativeStatus(ctx, incident)
		return s.store.SetIncidentError(
			ctx, incident.ID, workflow, detail,
		)
	}
	return nil
}

func incidentChannelStateError(incident core.Incident) string {
	if incident.IsThreadScoped() {
		switch incident.ChannelState {
		case core.ChannelArchived:
			return "The Slack channel containing this task thread was archived. The Coop session and isolated fork are preserved; unarchive the channel to continue."
		case core.ChannelDeleted:
			return "The Slack channel containing this task thread was deleted. The Coop session and isolated fork are preserved, but this thread can no longer continue."
		default:
			return "The Slack channel containing this task thread is unavailable to Responder. Restore channel access to continue; the Coop session and isolated fork are preserved."
		}
	}
	switch incident.ChannelState {
	case core.ChannelArchived:
		return "Slack incident room was archived. The Coop session and isolated fork are preserved; unarchive the room to continue."
	case core.ChannelDeleted:
		return "Slack incident room was deleted. The Coop session and isolated fork are preserved; create or rebind a room before continuing."
	default:
		return "Slack incident room is unavailable to Responder. The room may be inaccessible or deleted; restore access or rebind a room before continuing."
	}
}

func (s *Service) completeTurn(ctx context.Context, incident core.Incident, event coop.Event) error {
	turn, err := s.coop.GetTurn(ctx, incident.CoopSessionID, event.TurnID)
	if err != nil {
		return err
	}
	state := strings.TrimPrefix(event.Type, "turn.")
	detail := firstNonempty(turn.ErrorDetail, turn.StopReason)
	if s.sanitizer != nil {
		detail = s.sanitizer.Text(detail)
	}
	item, err := s.store.CompleteTurnSubmission(ctx, turn.ID, state, detail)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			return err
		}
		item.ID = event.ID
		_ = s.store.Audit(ctx, core.AuditEvent{
			IncidentID: incident.ID, Kind: "coop.turn.external", ObjectID: turn.ID,
			Outcome: "observed", Detail: state,
		})
	}
	threadTS := incident.ConversationThreadTS()
	conversation := item.SourceKind == "slack"
	var conversationInput core.SlackInput
	if conversation {
		input, inputErr := s.store.GetSlackInput(ctx, item.SourceID)
		if inputErr != nil {
			return inputErr
		}
		conversationInput = input
		threadTS = slackReplyThread(input)
	}
	var message slackui.Message
	if state == "completed" {
		report, structured, reportErr := parseAgentReport(turn.AssistantMessage)
		if reportErr != nil {
			s.log.Warn(
				"agent returned malformed structured response",
				"incident", incident.ID,
				"turn", turn.ID,
				"error", reportErr,
			)
			_ = s.store.Audit(ctx, core.AuditEvent{
				IncidentID: incident.ID, Kind: "agent.report", ObjectID: turn.ID,
				Outcome: "malformed", Detail: trimError(reportErr),
			})
			reportDetail := trimError(reportErr)
			if s.sanitizer != nil {
				reportDetail = s.sanitizer.Text(reportDetail)
			}
			message = slackui.AgentReportFailureMessage(reportDetail)
			_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
				IncidentID: incident.ID, ChannelID: incident.ChannelID,
				Kind: "agent.failure", ActorID: "responder",
				Title:  "Agent result could not be rendered",
				Detail: boundedField(trimError(reportErr), 1000),
			})
		} else {
			if !structured {
				_ = s.store.Audit(ctx, core.AuditEvent{
					IncidentID: incident.ID, Kind: "agent.report", ObjectID: turn.ID,
					Outcome: "legacy", Detail: "response had no structured evidence envelope",
				})
			}
			report, err = s.persistAgentReport(
				ctx, report, incident, incident.ChannelID, item.ID, item.UserID,
			)
			if err != nil {
				return err
			}
			if conversation && suppressConversationReply(report.Message) {
				s.clearNativeStatus(ctx, incident)
				return nil
			}
			if conversation {
				message = slackui.ConciseEvidenceResponse(
					report.Message,
					report.Evidence,
					report.Coverage,
					report.Proposals,
					s.sanitizer,
				)
				if actionValue, scope, expires, ok := s.prepareMemoryOfferAction(
					conversationInput,
					report.MemoryOffer,
				); ok {
					message = slackui.WithMemoryOffer(
						message, *report.MemoryOffer, actionValue, scope, expires,
					)
				}
				if actionValue, preference, expires, ok := s.preparePreferenceOfferAction(
					conversationInput,
					report.PreferenceOffer,
				); ok {
					message = slackui.WithPreferenceOffer(
						message,
						*report.PreferenceOffer,
						preference,
						actionValue,
						expires,
					)
				}
				if actionValue, rule, expires, ok := s.prepareRuleOfferAction(
					conversationInput,
					report.RuleOffer,
				); ok {
					message = slackui.WithRuleOffer(
						message,
						*report.RuleOffer,
						rule,
						actionValue,
						expires,
					)
				}
			} else {
				message = slackui.IncidentEvidenceResponse(
					report.Message,
					report.Evidence,
					report.Coverage,
					report.Proposals,
					s.sanitizer,
				)
			}
			if report.PendingApproval != nil {
				message = slackui.WithEmisarApproval(message, *report.PendingApproval)
			}
			evidenceIDs := make([]string, 0, len(report.Evidence))
			for _, item := range report.Evidence {
				evidenceIDs = append(evidenceIDs, item.ID)
			}
			_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
				IncidentID:  incident.ID,
				ChannelID:   incident.ChannelID,
				Kind:        "agent.finding",
				ActorID:     "responder",
				Title:       "Investigation update",
				Detail:      boundedField(report.Message, 2000),
				EvidenceIDs: evidenceIDs,
			})
		}
	} else {
		detail := s.sanitizer.Text(firstNonempty(turn.ErrorDetail, turn.StopReason, state))
		failure := classifyProviderFailure(detail)
		message = slackui.TurnFailureMessage(
			state,
			failure.Summary+"\n\nReported detail: `"+detail+"`\n\n"+failure.OperatorFix,
		)
		_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
			IncidentID: incident.ID, ChannelID: incident.ChannelID,
			Kind: "agent.failure", ActorID: "responder",
			Title: "Agent turn " + state, Detail: detail,
		})
	}
	if state == "completed" && incident.IsEngineeringTask() {
		if changes, changesErr := s.coop.Changes(ctx, incident.CoopSessionID); changesErr == nil {
			message = slackui.WithEngineeringTaskDelivery(
				message,
				incident,
				coopChangesPresent(changes),
			)
		} else {
			s.log.Warn(
				"inspect completed engineering task changes failed",
				"incident", incident.ID,
				"error", changesErr,
			)
		}
	}
	if item.SourceKind == "proposal" {
		proposalState := "failed"
		if state == "completed" {
			proposalState = "finished"
		}
		proposalResult := firstNonempty(turn.AssistantMessage, detail)
		if s.sanitizer != nil {
			proposalResult = s.sanitizer.Text(proposalResult)
		}
		_ = s.store.MarkProposalExecution(
			ctx, item.SourceID, proposalState, turn.ID,
			proposalResult,
		)
	}
	if err := s.enqueue(
		ctx, "out_turn_"+item.ID, incident, "assistant", threadTS, message,
	); err != nil {
		return err
	}
	s.forgetNativeStatus(incident.ID)
	return nil
}

func (s *Service) processCard(ctx context.Context) error {
	incidents, err := s.store.ListDirtyCards(ctx, 1000)
	if err != nil || len(incidents) == 0 {
		if err == nil {
			return store.ErrNotFound
		}
		return err
	}
	var incident core.Incident
	for _, candidate := range incidents {
		if s.canRetry("card:" + candidate.ID) {
			incident = candidate
			break
		}
	}
	if incident.ID == "" {
		return store.ErrNotFound
	}
	message, err := s.incidentCard(ctx, incident)
	if err != nil {
		s.retryLater("card:" + incident.ID)
		return err
	}
	message = s.sanitizer.Message(message)
	err = s.slack.Update(ctx, incident.ChannelID, incident.RootTS, message)
	s.lastPost = time.Now()
	if err != nil {
		s.retryLater("card:" + incident.ID)
		return err
	}
	if err := s.store.MarkCardRendered(ctx, incident.ID, incident.CardVersion); err != nil {
		return err
	}
	s.retryDone("card:" + incident.ID)
	return nil
}

func (s *Service) incidentCard(ctx context.Context, incident core.Incident) (slackui.Message, error) {
	signals, err := s.store.ListSignals(ctx, incident.ID)
	if err != nil {
		return slackui.Message{}, err
	}
	hasCodeChanges := false
	publication, publicationErr := s.store.GetPublication(ctx, incident.ID)
	if publicationErr != nil && !errors.Is(publicationErr, store.ErrNotFound) {
		return slackui.Message{}, publicationErr
	}
	if incident.CoopSessionID != "" {
		changes, changesErr := s.coop.Changes(ctx, incident.CoopSessionID)
		if changesErr != nil {
			s.log.Warn(
				"inspect Coop changes for incident controls",
				"incident", incident.ID,
				"session", incident.CoopSessionID,
				"error", changesErr,
			)
		} else {
			hasCodeChanges = coopChangesPresent(changes)
		}
	}
	return slackui.IncidentCardWithPublication(
		incident,
		s.repositoryName(incident.Repository),
		signals,
		hasCodeChanges,
		publication,
	), nil
}

func (s *Service) enqueueManualHandoff(ctx context.Context, incident core.Incident) error {
	if incident.Route != "manual" || incident.IsThreadScoped() {
		return nil
	}
	signals, err := s.store.ListSignals(ctx, incident.ID)
	if err != nil {
		return err
	}
	for _, signal := range signals {
		channelID := signal.Labels["slack_origin_channel"]
		threadTS := signal.Labels["slack_origin_thread"]
		if channelID == "" || threadTS == "" {
			continue
		}
		origin := incident
		origin.ChannelID = channelID
		message := slackui.ManualHandoff(incident.ChannelID)
		if incident.IsEngineeringTask() {
			message = slackui.EngineeringTaskHandoff(incident.ChannelID)
		}
		return s.enqueue(
			ctx,
			"out_manual_ready_"+incident.ID,
			origin,
			"notice",
			threadTS,
			message,
		)
	}
	return nil
}

func (s *Service) clearNativeStatus(ctx context.Context, incident core.Incident) {
	if s.cfg.Slack.NativeStatus && incident.ChannelWritable() &&
		incident.ChannelID != "" && incident.ConversationThreadTS() != "" {
		_ = s.slack.SetStatus(ctx, incident.ChannelID, incident.ConversationThreadTS(), "")
		s.retryDone(
			"native-status:" + incident.ID + "@" + incident.ConversationThreadTS(),
		)
	}
	s.forgetNativeStatus(incident.ID)
}

func (s *Service) setNativeStatus(ctx context.Context, incident core.Incident, status string) {
	if !s.cfg.Slack.NativeStatus || !incident.ChannelWritable() ||
		incident.ChannelID == "" || incident.ConversationThreadTS() == "" {
		return
	}
	statusKey := incident.ID + "@" + incident.ConversationThreadTS()
	previous := s.nativeStatus[statusKey]
	if previous.text == status && time.Since(previous.at) < 75*time.Second {
		return
	}
	key := "native-status:" + statusKey
	if !s.canRetry(key) {
		return
	}
	if err := s.slack.SetProgress(
		ctx,
		incident.ChannelID,
		incident.ConversationThreadTS(),
		status,
		progressMilestones(status),
	); err != nil {
		s.retryLater(key)
		s.log.Warn("set Slack thread status", "incident", incident.ID, "error", err)
		return
	}
	s.retryDone(key)
	s.nativeStatus[statusKey] = nativeStatusState{text: status, at: time.Now()}
}

func (s *Service) setNativeStatusForThread(
	ctx context.Context,
	incident core.Incident,
	threadTS string,
	status string,
) {
	if threadTS != "" && !incident.IsThreadScoped() {
		incident.RootTS = threadTS
	}
	s.setNativeStatus(ctx, incident, status)
}

func (s *Service) turnStatusIncident(
	ctx context.Context,
	incident core.Incident,
	coopTurnID string,
) core.Incident {
	submission, err := s.store.GetTurnSubmissionByCoopTurn(ctx, coopTurnID)
	if err != nil {
		return incident
	}
	return s.turnSubmissionStatusIncident(ctx, incident, submission)
}

func (s *Service) turnSubmissionStatusIncident(
	ctx context.Context,
	incident core.Incident,
	submission core.TurnSubmission,
) core.Incident {
	if submission.SourceKind != "slack" {
		return incident
	}
	input, err := s.store.GetSlackInput(ctx, submission.SourceID)
	if err != nil {
		return incident
	}
	if !incident.IsThreadScoped() {
		incident.RootTS = slackReplyThread(input)
	}
	return incident
}

func progressMilestones(status string) []string {
	switch {
	case strings.Contains(status, "approved action"):
		return []string{
			"Re-checking whether the evidence is still current",
			"Validating the exact target and blast radius",
			"Requesting policy authorization from Emisar",
			"Waiting for authoritative verification",
		}
	case strings.Contains(status, "review"):
		return []string{
			"Inspecting the isolated code change",
			"Checking current repository divergence",
			"Running configured validation and policy gates",
			"Preparing fix-readiness findings",
		}
	default:
		return []string{
			"Mapping declared topology from the repository",
			"Checking current infrastructure state with Emisar",
			"Reconciling expected and observed entities",
			"Assessing coverage and unresolved gaps",
			"Preparing an evidence-backed response",
		}
	}
}

func (s *Service) forgetNativeStatus(incidentID string) {
	prefix := incidentID + "@"
	for key := range s.nativeStatus {
		if strings.HasPrefix(key, prefix) {
			delete(s.nativeStatus, key)
			s.retryDone("native-status:" + key)
		}
	}
}

func (s *Service) enqueue(
	ctx context.Context,
	id string,
	incident core.Incident,
	kind string,
	threadTS string,
	message slackui.Message,
) error {
	body, err := slackui.Encode(s.sanitizer.Message(message))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueOutbox(ctx, core.OutboxMessage{
		ID: id, IncidentID: incident.ID, Kind: kind,
		ChannelID: incident.ChannelID, ThreadTS: threadTS, Body: body,
	})
	return err
}

func (s *Service) repositoryName(name string) string {
	repository, ok := s.cfg.Repositories[name]
	if !ok || repository.DisplayName == "" {
		return name
	}
	return repository.DisplayName
}

func changesSummary(changes coop.Changes) string {
	groups := []struct {
		name  string
		items []coop.Change
	}{
		{"Committed", changes.Committed},
		{"Staged", changes.Staged},
		{"Unstaged", changes.Unstaged},
		{"Untracked", changes.Untracked},
		{"Conflicts", changes.Conflicts},
	}
	var lines []string
	for _, group := range groups {
		if len(group.items) == 0 {
			continue
		}
		lines = append(lines, fmt.Sprintf("*%s (%d)*", group.name, len(group.items)))
		for _, item := range group.items[:min(len(group.items), 12)] {
			path := item.Path
			if path == "" {
				path = fmt.Sprintf("%x", item.PathBytes)
			}
			lines = append(lines, fmt.Sprintf("`%s` %s", path, item.Status))
		}
	}
	if len(lines) == 0 {
		return "The incident fork has no changes."
	}
	if changes.ParentDivergence.Diverged {
		lines = append(lines, fmt.Sprintf(
			"Parent divergence: %d ahead, %d behind.",
			changes.ParentDivergence.Ahead, changes.ParentDivergence.Behind,
		))
	}
	if changes.Truncated {
		lines = append(lines, "The detailed patch exceeded the configured response limit.")
	}
	return strings.Join(lines, "\n")
}

func coopChangesPresent(changes coop.Changes) bool {
	return len(changes.Committed) > 0 ||
		len(changes.Staged) > 0 ||
		len(changes.Unstaged) > 0 ||
		len(changes.Untracked) > 0 ||
		len(changes.Conflicts) > 0
}

func reviewSummary(review coop.Review) string {
	lines := []string{
		fmt.Sprintf("*Gate:* %s", displayOr(review.Gate, "not run")),
		fmt.Sprintf("*Rebase:* %s", displayOr(review.Rebase, "not run")),
	}
	reasons := append([]string(nil), review.NotPublishableReasons...)
	reasons = append(reasons, review.PolicyFindings...)
	sort.Strings(reasons)
	for _, reason := range reasons[:min(len(reasons), 12)] {
		lines = append(lines, "• "+reason)
	}
	return strings.Join(lines, "\n")
}

func firstNonempty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func displayOr(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func signalsForIncident(signals []core.Signal, incident core.Incident) []core.Signal {
	result := make([]core.Signal, 0, len(signals))
	for _, signal := range signals {
		if signal.Route == incident.Route && signal.Repository == incident.Repository &&
			signal.CorrelationKey == incident.CorrelationKey {
			result = append(result, signal)
		}
	}
	return result
}
