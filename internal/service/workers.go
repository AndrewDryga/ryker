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
		signals := signalsForIncident(event.Signals, incident)
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
			ctx, "out_root_"+incident.ID, incident, "root", "",
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
		s.forgetNativeStatus(item.IncidentID)
		if incident, incidentErr := s.store.GetIncident(ctx, item.IncidentID); incidentErr == nil &&
			incident.ActiveTurnID != "" {
			s.setNativeStatus(ctx, incident, "is investigating...")
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
	if err := s.prepareChannel(ctx, incident); err != nil {
		s.retryLater(key)
		_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowHolding, trimError(err))
		return nil
	}
	if err := s.enqueueManualHandoff(ctx, incident); err != nil {
		s.retryLater(key)
		return err
	}
	open, err := s.store.CountOpenSessions(ctx)
	if err != nil {
		return err
	}
	if open >= s.cfg.Limits.MaxActiveIncidents {
		s.retryLater(key)
		_ = s.store.SetIncidentError(
			ctx, incident.ID, core.WorkflowHolding,
			"Responder is at its configured active incident limit; this incident is queued.",
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
	session, _, err := s.coop.CreateSession(
		ctx, "responder:session:"+incident.ID, repository.CoopPolicy, "incident:"+incident.ID,
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
	return nil
}

func (s *Service) prepareChannel(ctx context.Context, incident core.Incident) error {
	if err := s.slack.Invite(ctx, incident.ChannelID, s.inviteUsers()...); err != nil {
		return fmt.Errorf("invite incident responders: %w", err)
	}
	topic := s.sanitizer.Text(fmt.Sprintf(
		"Incident %s | %s | managed by Responder", slackui.ShortID(incident.ID), incident.Title,
	))
	if err := s.slack.SetTopic(ctx, incident.ChannelID, topic); err != nil {
		return fmt.Errorf("set incident topic: %w", err)
	}
	if err := s.slack.Pin(ctx, incident.ChannelID, incident.RootTS); err != nil {
		return fmt.Errorf("pin incident card: %w", err)
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
	prompt, err := initialPrompt(s.cfg.Coop.Instructions, incident, signals)
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
	revision, err := s.store.FreezeTurnRevision(ctx, item.ID, incident.CoopRevision)
	if err != nil {
		return s.store.RetryTurnSubmission(ctx, item.ID, trimError(err), time.Now(), true)
	}
	turn, _, err := s.coop.SubmitTurn(
		ctx, item.IdempotencyKey, incident.CoopSessionID, revision, item.Prompt,
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
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
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
	s.setNativeStatus(ctx, incident, "is investigating...")
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
	case session.State == "closed":
		if incident.Status != core.IncidentClosed {
			return s.store.CloseIncident(ctx, incident.ID)
		}
		workflow = core.WorkflowClosed
	case session.State == "exhausted":
		workflow = core.WorkflowBlocked
	case session.ActiveTurnID != "":
		workflow = core.WorkflowInvestigating
	case session.QueuedTurnCount > 0:
		workflow = core.WorkflowInvestigating
	}
	if session.ActiveTurnID != "" {
		s.setNativeStatus(ctx, incident, "is investigating...")
	}
	if err := s.store.UpdateCoopState(
		ctx, incident.ID, session.Revision, cursor, session.ActiveTurnID, workflow,
	); err != nil {
		return err
	}
	if session.State == "exhausted" &&
		(incident.Workflow != core.WorkflowBlocked || incident.LastError == "") {
		s.clearNativeStatus(ctx, incident)
		return s.store.SetIncidentError(
			ctx, incident.ID, core.WorkflowBlocked,
			"The Coop turn budget is exhausted. Use Extend budget to continue.",
		)
	}
	return nil
}

func (s *Service) completeTurn(ctx context.Context, incident core.Incident, event coop.Event) error {
	turn, err := s.coop.GetTurn(ctx, incident.CoopSessionID, event.TurnID)
	if err != nil {
		return err
	}
	state := strings.TrimPrefix(event.Type, "turn.")
	detail := firstNonempty(turn.ErrorDetail, turn.StopReason)
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
	var message slackui.Message
	if state == "completed" {
		message = slackui.AssistantResponse(turn.AssistantMessage, s.sanitizer)
	} else {
		detail := s.sanitizer.Text(firstNonempty(turn.ErrorDetail, turn.StopReason, state))
		message = slackui.TurnFailureMessage(state, detail)
	}
	if err := s.enqueue(
		ctx, "out_turn_"+item.ID, incident, "assistant", incident.RootTS, message,
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
	return slackui.IncidentCard(
		incident,
		s.repositoryName(incident.Repository),
		signals,
	), nil
}

func (s *Service) enqueueManualHandoff(ctx context.Context, incident core.Incident) error {
	if incident.Route != "manual" {
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
		return s.enqueue(
			ctx,
			"out_manual_ready_"+incident.ID,
			origin,
			"notice",
			threadTS,
			slackui.ManualHandoff(incident.ChannelID),
		)
	}
	return nil
}

func (s *Service) clearNativeStatus(ctx context.Context, incident core.Incident) {
	if s.cfg.Slack.NativeStatus && incident.ChannelID != "" && incident.RootTS != "" {
		_ = s.slack.SetStatus(ctx, incident.ChannelID, incident.RootTS, "")
	}
	s.forgetNativeStatus(incident.ID)
}

func (s *Service) setNativeStatus(ctx context.Context, incident core.Incident, status string) {
	if !s.cfg.Slack.NativeStatus || incident.ChannelID == "" || incident.RootTS == "" {
		return
	}
	previous := s.nativeStatus[incident.ID]
	if previous.text == status && time.Since(previous.at) < 75*time.Second {
		return
	}
	key := "native-status:" + incident.ID
	if !s.canRetry(key) {
		return
	}
	if err := s.slack.SetStatus(ctx, incident.ChannelID, incident.RootTS, status); err != nil {
		s.retryLater(key)
		s.log.Warn("set Slack thread status", "incident", incident.ID, "error", err)
		return
	}
	s.retryDone(key)
	s.nativeStatus[incident.ID] = nativeStatusState{text: status, at: time.Now()}
}

func (s *Service) forgetNativeStatus(incidentID string) {
	delete(s.nativeStatus, incidentID)
	s.retryDone("native-status:" + incidentID)
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
