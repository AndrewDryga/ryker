package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/incidentauthority"
	"github.com/AndrewDryga/responder/internal/incidentprovision"
	"github.com/AndrewDryga/responder/internal/liveturn"
	"github.com/AndrewDryga/responder/internal/retrydelay"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
	"github.com/AndrewDryga/responder/internal/slackfile"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/taskaccess"
	"github.com/AndrewDryga/responder/internal/taskpr"
)

func (s *Service) processWebhook(ctx context.Context) error {
	event, err := s.store.LeaseWebhook(ctx)
	if err != nil {
		return err
	}
	route, ok := s.cfg.Webhooks[event.Route]
	if !ok {
		return s.store.RetryWebhook(ctx, event.ID, "webhook route was removed from configuration", s.now(), true)
	}
	var incidents []core.Incident
	var applyErr error
	if event.Applied {
		for _, incidentID := range event.IncidentIDs {
			incident, err := s.store.GetIncident(ctx, incidentID)
			if err != nil {
				return s.store.RetryWebhook(ctx, event.ID, trimError(err), s.queueDelay(event.Attempts), false)
			}
			incidents = append(incidents, incident)
		}
	} else {
		incidents, applyErr = s.store.ApplySignals(
			ctx, event, route.CorrelationWindow.Duration, route.ResolveAfter.Duration,
			s.cfg.Limits.MaxOpenIncidents,
		)
		if applyErr != nil && len(incidents) == 0 {
			terminal := retrydelay.Exhausted(event.Attempts, s.cfg.Limits.MaxWebhookAttempts)
			return s.store.RetryWebhook(
				ctx, event.ID, trimError(applyErr), s.queueDelay(event.Attempts), terminal,
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
			s.recordTimeline(ctx, core.TimelineEvent{
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
					s.setIncidentError(ctx, incident.ID, core.WorkflowBlocked, trimError(err))
				}
				return s.store.RetryWebhook(ctx, event.ID, trimError(err), s.now(), true)
			}
			if _, _, err := s.queueIncidentAgentRun(
				ctx,
				incident,
				"webhook",
				event.ID+":"+incident.ID,
				"",
				prompt,
			); err != nil {
				return s.store.RetryWebhook(ctx, event.ID, trimError(err), s.queueDelay(event.Attempts), false)
			}
		}
	}
	if applyErr != nil {
		terminal := retrydelay.Exhausted(event.Attempts, s.cfg.Limits.MaxWebhookAttempts)
		return s.store.RetryWebhook(
			ctx, event.ID, trimError(applyErr), s.queueDelay(event.Attempts), terminal,
		)
	}
	if err := s.store.FinishWebhook(ctx, event.ID); err != nil {
		_ = s.store.RetryWebhook(ctx, event.ID, trimError(err), s.queueDelay(event.Attempts), false)
		return err
	}
	return nil
}

func (s *Service) processChannelIncident(ctx context.Context, incidentID string) error {
	incident, err := s.store.GetIncident(ctx, incidentID)
	if err != nil {
		return err
	}
	if incident.ChannelID != "" {
		if !incident.ChannelWritable() || incident.RootTS != "" ||
			incident.Workflow != core.WorkflowProvisioningChannel {
			return store.ErrNotFound
		}
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
	if incident.Workflow != core.WorkflowProvisioningChannel {
		return store.ErrNotFound
	}
	if incident.IsThreadScoped() {
		if err := s.store.BindThreadWork(ctx, incident.ID); err != nil {
			return err
		}
		incident.ChannelID = incident.OriginChannelID
		incident.ChannelState = core.ChannelActive
		body, err := s.incidentCard(ctx, incident)
		if err != nil {
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
			return err
		}
		s.audit(ctx, core.AuditEvent{
			IncidentID: incident.ID, Kind: "slack.thread.bound",
			ObjectID: incident.OriginChannelID + ":" + incident.OriginThreadTS,
			Outcome:  "succeeded",
			Detail:   "engineering task remains in its source thread",
		})
		s.recordTimeline(ctx, core.TimelineEvent{
			ID:         "tl_thread_" + incident.ID,
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
		workflow := core.WorkflowProvisioningChannel
		if permanentSlackInputError(err) {
			workflow = core.WorkflowBlocked
		}
		s.setIncidentError(ctx, incident.ID, workflow, trimError(err))
		return err
	}
	if err := s.store.SetChannel(ctx, incident.ID, channel.ID, channel.Name); err != nil {
		return err
	}
	incident.ChannelID = channel.ID
	incident.ChannelName = channel.Name
	body, err := s.incidentCard(ctx, incident)
	if err != nil {
		return err
	}
	if err := s.enqueue(ctx, "out_root_"+incident.ID, incident, "root", "", body); err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "slack.channel.created", ObjectID: channel.ID,
		Outcome: "succeeded", Detail: channel.Name,
	})
	s.recordTimeline(ctx, core.TimelineEvent{
		ID:         "tl_channel_" + incident.ID,
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
	// Refreshing a card only enqueues a delivery; it performs no Slack write.
	// It does call Coop for change inspection, so it deliberately runs outside
	// the write slot: holding a Slack write slot across a Coop round trip would
	// stall every queued reply behind it.
	if err := s.processCard(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		return err
	}
	// Slack rate-limits chat.postMessage per channel, so a busy incident room
	// must not hold up an answer somewhere unrelated. Skip the channels that
	// are still cooling and take work for another one; only when every ready
	// delivery belongs to a cooling channel is there anything to wait for.
	now := s.now()
	cooling := s.channelWrites.Cooling(now)
	err := s.processSlackDelivery(ctx, cooling)
	if errors.Is(err, store.ErrNotFound) && len(cooling) > 0 {
		if wait := s.channelWrites.NextReopen(now); wait > 0 {
			return deferScheduledWork(now.Add(wait), "every ready Slack write is cooling down")
		}
	}
	return err
}

func (s *Service) processSlackDelivery(ctx context.Context, cooling []string) error {
	item, err := s.store.LeaseSlackDelivery(ctx, cooling)
	if err != nil {
		return err
	}
	// An operational answer is withdrawn on one criterion only: a newer reply
	// for this thread has already been posted, so this one would arrive under
	// it contradicting what the channel has already read.
	//
	// The criterion used to be that a newer input on the same stream had been
	// ADMITTED, which is a question nobody has answered yet rather than a
	// reason to withdraw the answer to the last one. On 2026-08-16 that dropped
	// four finished Grafana answers, one of them fifteen minutes and
	// forty-seven tool calls old.
	//
	// A reply with no thread is the one that CREATES the thread, so there is no
	// thread to have been answered ahead of it and nothing to ask.
	if item.SourceInputID != "" && item.Operation == "post" &&
		item.ResponseRoot && item.ThreadTS != "" {
		source, sourceErr := s.store.GetSlackInput(ctx, item.SourceInputID)
		if sourceErr != nil && !errors.Is(sourceErr, store.ErrNotFound) {
			return s.store.RetrySlackDelivery(ctx, item.ID, trimError(sourceErr), s.now(), false, false)
		}
		if sourceErr == nil && source.Kind == "bot_message" {
			newer, newerErr := s.store.HasNewerSentReplyInThread(
				ctx, item.ChannelID, item.ThreadTS, item.SourceInputID, item.CreatedAt,
			)
			if newerErr != nil {
				return s.store.RetrySlackDelivery(ctx, item.ID, trimError(newerErr), s.now(), false, false)
			}
			if newer {
				return s.store.SupersedeLeasedSlackDelivery(
					ctx, item.ID, "a newer reply for this thread was already sent",
				)
			}
		}
	}
	var incident core.Incident
	if item.IncidentID != "" {
		incident, err = s.store.GetIncident(ctx, item.IncidentID)
		if err != nil {
			return s.store.RetrySlackDelivery(
				ctx, item.ID, trimError(err), s.now(), false, true,
			)
		}
	}
	if incident.ID != "" && item.ChannelID == incident.ChannelID &&
		!incident.ChannelWritable() {
		return s.store.RetrySlackDelivery(
			ctx,
			item.ID,
			"Slack delivery suppressed because the work conversation is "+string(incident.ChannelState),
			s.now(),
			false,
			true,
		)
	}
	var timestamp string
	var fileDelivery *slackfile.Delivery
	switch item.Operation {
	case "post", "update":
		message, decodeErr := slackui.Decode(item.Body)
		if decodeErr != nil {
			retryErr := s.store.RetrySlackDelivery(
				ctx, item.ID, trimError(decodeErr), s.now(), false, true,
			)
			if incident.ID != "" {
				s.setIncidentError(
					ctx, incident.ID, incident.Workflow, trimError(decodeErr),
				)
			}
			return retryErr
		}
		if item.Operation == "post" {
			if item.Kind == "broadcast" {
				timestamp, err = s.slack.PostBroadcast(
					ctx, item.ID, item.ChannelID, item.ThreadTS, message,
				)
			} else {
				timestamp, err = s.slack.Post(
					ctx, item.ID, item.ChannelID, item.ThreadTS, message,
				)
			}
		} else {
			timestamp = item.MessageTS
			err = s.slack.Update(
				ctx, item.ChannelID, item.MessageTS, message,
			)
		}
	case "status":
		err = s.slack.SetProgress(
			ctx,
			item.ChannelID,
			item.ThreadTS,
			item.Status,
			item.Steps,
		)
	case "reaction":
		timestamp = item.MessageTS
		client, ok := unpacedSlack(s.slack).(interface {
			React(context.Context, string, string, string) error
			Unreact(context.Context, string, string, string) error
		})
		if !ok {
			err = errors.New("Slack client does not support reactions")
			break
		}
		switch item.Kind {
		case "failure_marker_add":
			err = client.React(ctx, item.ChannelID, item.MessageTS, item.Status)
		case "failure_marker_remove":
			err = client.Unreact(ctx, item.ChannelID, item.MessageTS, item.Status)
		default:
			err = fmt.Errorf("unsupported Slack reaction action %q", item.Kind)
		}
	case "file":
		file, decodeErr := slackfile.DecodeDelivery(item.Body)
		if decodeErr != nil {
			err = decodeErr
			break
		}
		fileDelivery = &file
		result, uploadErr := s.slack.UploadFile(ctx, item.ChannelID, item.ThreadTS, slackui.FileUpload{
			Filename: file.Filename, Title: file.Title, AltText: file.AltText,
			Data: file.Data, Message: file.Message,
		})
		timestamp, err = result.MessageTS, uploadErr
	default:
		err = fmt.Errorf("unsupported Slack delivery operation %q", item.Operation)
	}
	// The write recorded its own spend against the channel, delivered or not:
	// the Slack client is paced. See localstate.PaceChannelWrites. Recording
	// here as well would be harmless — the slot keeps the latest timestamp — but
	// it would also record the two branches above that never reached Slack at
	// all, cooling a channel for a body this process could not decode.
	if err != nil {
		terminal := retrydelay.Exhausted(item.Attempts, s.cfg.Limits.MaxDeliveryAttempts)
		uncertain := item.Operation == "post" || item.Operation == "file"
		if item.Operation == "file" && slackfile.PermanentDeliveryError(err) {
			terminal = true
			uncertain = false
		}
		if retryErr := s.store.RetrySlackDelivery(
			ctx,
			item.ID,
			trimError(err),
			s.queueDelay(item.Attempts),
			uncertain,
			terminal,
		); retryErr != nil {
			return retryErr
		}
		if terminal && fileDelivery != nil {
			return s.enqueueGeneratedVisualFailure(
				ctx, item, *fileDelivery, trimError(err),
			)
		}
		return nil
	}
	if err := s.store.FinishSlackDelivery(
		ctx, item.ID, timestamp, "sending",
	); err != nil {
		_ = s.store.RetrySlackDelivery(
			ctx, item.ID, "Slack accepted the message but local confirmation failed",
			s.queueDelay(item.Attempts), item.Operation == "post" || item.Operation == "file", false,
		)
		return err
	}
	if item.Operation == "post" && item.ThreadTS != "" && incident.ID != "" {
		s.forgetNativeStatus(item.IncidentID)
		if incident, incidentErr := s.store.GetIncident(
			ctx, item.IncidentID,
		); incidentErr == nil &&
			incident.ActiveTurnID != "" {
			statusIncident, status := s.turnNativeStatus(
				ctx, incident, incident.ActiveTurnID,
			)
			s.setNativeStatus(
				ctx,
				statusIncident,
				status,
			)
		}
	}
	return nil
}

func (s *Service) reconcileSlackDelivery(ctx context.Context) error {
	items, err := s.store.ListUncertainSlackDeliveries(ctx, 1)
	if err != nil || len(items) == 0 {
		if err == nil {
			return store.ErrNotFound
		}
		return err
	}
	item := items[0]
	var incident core.Incident
	if item.IncidentID != "" {
		incident, err = s.store.GetIncident(ctx, item.IncidentID)
		if err != nil {
			return err
		}
	}
	if incident.ID != "" && item.ChannelID == incident.ChannelID &&
		!incident.ChannelWritable() {
		return s.store.RetryUncertainSlackDelivery(
			ctx,
			item.ID,
			"Slack reconciliation suppressed because the work conversation is "+
				string(incident.ChannelState),
			s.now(),
			true,
		)
	}
	var timestamp string
	var fileDelivery *slackfile.Delivery
	if item.Operation == "file" {
		file, decodeErr := slackfile.DecodeDelivery(item.Body)
		if decodeErr != nil {
			return s.store.RetryUncertainSlackDelivery(ctx, item.ID, trimError(decodeErr), s.now(), true)
		}
		fileDelivery = &file
		if slackfile.PermanentDeliveryError(errors.New(item.LastError)) {
			if retryErr := s.store.RetryUncertainSlackDelivery(
				ctx, item.ID, item.LastError, s.now(), true,
			); retryErr != nil {
				return retryErr
			}
			return s.enqueueGeneratedVisualFailure(
				ctx, item, file, item.LastError,
			)
		}
		result, findErr := s.slack.FindDeliveryFile(ctx, item.ChannelID, item.ThreadTS, file.Filename)
		timestamp, err = result.MessageTS, findErr
	} else {
		timestamp, err = s.slack.FindDeliveryMessage(ctx, item.ChannelID, item.ThreadTS, item.ID)
	}
	switch {
	case err == nil:
		return s.store.FinishSlackDelivery(
			ctx, item.ID, timestamp, "uncertain",
		)
	case errors.Is(err, slackui.ErrNotFound):
		terminal := retrydelay.Exhausted(item.Attempts, s.cfg.Limits.MaxDeliveryAttempts)
		retryErr := s.store.RetryUncertainSlackDelivery(
			ctx, item.ID, "Slack history confirmed the message was not posted",
			s.queueDelay(item.Attempts), terminal,
		)
		if terminal {
			if incident.ID != "" {
				s.setIncidentError(
					ctx, incident.ID, incident.Workflow,
					"Slack delivery failed after the configured retry limit.",
				)
			}
			if fileDelivery != nil && retryErr == nil {
				return s.enqueueGeneratedVisualFailure(
					ctx, item, *fileDelivery, item.LastError,
				)
			}
		}
		return retryErr
	default:
		return s.store.RetryUncertainSlackDelivery(
			ctx,
			item.ID,
			trimError(err),
			s.queueDelay(item.Attempts),
			retrydelay.Exhausted(item.Attempts, s.cfg.Limits.MaxDeliveryAttempts),
		)
	}
}

func (s *Service) processSessionIncident(ctx context.Context, incidentID string) error {
	incident, err := s.store.GetIncident(ctx, incidentID)
	if err != nil {
		return err
	}
	// The conversation, not the card. Thread-scoped work speaks in the
	// operator's own thread, which is bound before the card is enqueued, so
	// waiting on root_ts made a card that could not post kill the task silently.
	if incident.ConversationThreadTS() == "" || !incident.ChannelWritable() ||
		incident.CoopSessionID != "" ||
		(incident.Workflow != core.WorkflowProvisioningSession &&
			incident.Workflow != core.WorkflowHolding &&
			!(incident.IsThreadScoped() &&
				incident.Workflow == core.WorkflowProvisioningChannel)) {
		return store.ErrNotFound
	}
	if !incident.IsThreadScoped() {
		if err := s.prepareChannel(ctx, incident); err != nil {
			s.setIncidentError(ctx, incident.ID, core.WorkflowHolding, trimError(err))
			return err
		}
		if err := s.enqueueManualHandoff(ctx, incident); err != nil {
			return err
		}
	}
	open, err := s.store.CountOpenSessions(ctx)
	if err != nil {
		return err
	}
	if open >= s.cfg.Limits.MaxActiveIncidents {
		detail := "Responder is at its configured active incident limit; this incident is queued."
		if incident.IsEngineeringTask() {
			detail = "Responder is at its configured active work limit; this engineering task is queued."
		}
		s.setIncidentError(
			ctx, incident.ID, core.WorkflowHolding,
			detail,
		)
		return errors.New(detail)
	}
	repository, ok := s.cfg.RepositoryContext(incident.Repository)
	if !ok {
		return s.store.SetIncidentError(ctx, incident.ID, core.WorkflowBlocked, "repository binding was removed")
	}
	sessionPolicy, contributorTask, err := taskaccess.SessionPolicy(
		ctx, s.cfg, s.store, incident, repository,
	)
	if err != nil {
		return err
	}
	if contributorTask && sessionPolicy == "" {
		return s.store.SetIncidentError(
			ctx, incident.ID, core.WorkflowBlocked,
			"repository contributor policy is not configured",
		)
	}
	// After the contributor check, never before it: a profile chooses which
	// rung answers, and it must not be able to supply a writable policy for a
	// repository whose contributor lane an operator never configured.
	sessionProfile := config.ProfileInvestigate
	if incident.IsEngineeringTask() {
		sessionProfile = config.ProfileEngineer
	}
	sessionPolicy = repository.SessionProfilePolicy(sessionProfile, sessionPolicy)
	var sessionSources []coop.SessionSource
	client, _ := s.publisher.(taskpr.Inspector)
	resolver := s.taskPullRequestResolver(client)
	if source, targetErr := resolver.SessionSource(ctx, incident, repository); targetErr != nil {
		var permanent *taskpr.PermanentError
		if errors.As(targetErr, &permanent) {
			s.setIncidentError(ctx, incident.ID, core.WorkflowBlocked, trimError(targetErr))
			return nil
		}
		return targetErr
	} else if source.PullRequestNumber > 0 {
		sessionSources = append(sessionSources, source)
	}
	if err := s.queueInitialTurn(ctx, incident); err != nil {
		if errors.Is(err, errEvidenceTooLarge) {
			s.setIncidentError(ctx, incident.ID, core.WorkflowBlocked, trimError(err))
			return nil
		}
		return err
	}
	sessionLabel := "incident:" + incident.ID
	if incident.IsEngineeringTask() {
		sessionLabel = "engineering-task:" + incident.ID
	}
	session, generation, err := incidentprovision.Resolve(
		ctx, s.coop, s.store, s.store.Incidents, incident,
		sessionPolicy, sessionLabel, sessionSources, s.now(),
	)
	if err != nil {
		if errors.Is(err, sessioncreate.ErrReadOnlyAuthority) ||
			errors.Is(err, sessioncreate.ErrWritableAuthority) ||
			errors.Is(err, sessioncreate.ErrHistoricalCreateKeys) {
			detail := trimError(err)
			s.setIncidentError(ctx, incident.ID, core.WorkflowHolding, detail)
			return deferScheduledWork(s.now().Add(30*time.Minute), detail)
		}
		workflow, detail, failureErr := sessioncreate.IncidentFailure(
			ctx, s.store.Incidents, incident.ID, generation,
			s.repositoryName(incident.Repository), err,
		)
		if failureErr != nil {
			return failureErr
		}
		s.setIncidentError(ctx, incident.ID, workflow, detail)
		if workflow == core.WorkflowBlocked {
			return nil
		}
		return err
	}
	if err := s.store.SetCoopSession(ctx, incident.ID, session.ID, session.ForkName, session.Revision); err != nil {
		return err
	}
	incident.CoopSessionID = session.ID
	incident.CoopForkName = session.ForkName
	incident.CoopRevision = session.Revision
	s.audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "coop.session.created", ObjectID: session.ID,
		Outcome: "succeeded", Detail: sessionPolicy,
	})
	timelineTitle := "Isolated investigation started"
	if incident.IsEngineeringTask() {
		timelineTitle = "Isolated engineering task started"
	}
	s.recordTimeline(ctx, core.TimelineEvent{
		ID:         "tl_session_" + incident.ID,
		IncidentID: incident.ID, ChannelID: incident.ChannelID,
		Kind: "coop.session.created", ActorID: "responder",
		Title:  timelineTitle,
		Detail: "Coop session " + session.ID + " using policy " + sessionPolicy,
	})
	return nil
}

func (s *Service) prepareChannel(ctx context.Context, incident core.Incident) error {
	users, err := s.configuredIncidentInviteUsers(ctx, incident.OriginChannelID)
	if err != nil {
		return fmt.Errorf("resolve incident audience: %w", err)
	}
	if err := s.slack.Invite(ctx, incident.ChannelID, users...); err != nil {
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
	if incident.InitialTurnQueued {
		return nil
	}
	return s.queueInitialTurnWithSource(ctx, incident, "initial", incident.ID, "")
}

func (s *Service) queueInitialTurnFromSlack(
	ctx context.Context,
	incident core.Incident,
	source core.SlackInput,
	userID string,
) error {
	if incident.InitialTurnQueued {
		return nil
	}
	return s.queueInitialTurnWithSource(ctx, incident, "slack", source.ID, userID)
}

func (s *Service) queueInitialTurnWithSource(
	ctx context.Context,
	incident core.Incident,
	sourceKind string,
	sourceID string,
	userID string,
) error {
	contributorTask, err := taskaccess.InitialContributor(
		ctx, s.cfg, s.store, incident, userID,
	)
	if err != nil {
		return err
	}
	signals, err := s.store.ListSignals(ctx, incident.ID)
	if err != nil {
		return err
	}
	prompt, err := initialPrompt(
		s.cfg.Coop.Instructions,
		incident,
		signals,
		"",
		contributorTask,
	)
	if err != nil {
		return err
	}
	repository, configured := s.cfg.RepositoryContext(incident.Repository)
	client, _ := s.publisher.(taskpr.Inspector)
	resolver := s.taskPullRequestResolver(client)
	if addition, targetErr := resolver.InitialPrompt(ctx, incident, repository); targetErr != nil {
		return targetErr
	} else if configured {
		prompt += addition
	}
	if _, _, err := s.queueIncidentAgentRun(
		ctx, incident, sourceKind, sourceID, userID, prompt,
	); err != nil {
		return err
	}
	err = s.store.MarkInitialTurnQueued(ctx, incident.ID)
	if errors.Is(err, store.ErrConflict) {
		return nil
	}
	return err
}

func (s *Service) pollCoop(ctx context.Context) {
	incidents, err := s.store.ListBoundIncidents(ctx, 100)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
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
	if incident.ActiveTurnID != "" {
		run, err := s.store.GetAgentRunByCoopTurn(ctx, incident.ActiveTurnID)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return err
		}
		if err == nil {
			if run.State == core.AgentRunRunning {
				if err := s.pollAgentRun(ctx, run); err != nil {
					return err
				}
			}
		}
	}
	events, err := s.coop.Events(ctx, incident.CoopSessionID, incident.CoopEventSequence, 100)
	if err != nil {
		return err
	}
	cursor := incident.CoopEventSequence
	for _, event := range events {
		if event.Sequence > cursor {
			cursor = event.Sequence
		}
	}
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		return err
	}
	if handled, authorityErr := incidentauthority.Reconcile(
		ctx, s.coop, s.store, s.store.IncidentSessions,
		incident, session, cursor, s.now(),
	); handled {
		return authorityErr
	}
	workflow := core.WorkflowParked
	switch {
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
		statusIncident, status := s.turnNativeStatus(
			ctx, incident, session.ActiveTurnID,
		)
		s.setNativeStatus(
			ctx,
			statusIncident,
			status,
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

func (s *Service) processCard(ctx context.Context) error {
	incidents, err := s.store.ListDirtyCards(ctx, 1000)
	if err != nil || len(incidents) == 0 {
		if err == nil {
			return store.ErrNotFound
		}
		return err
	}
	incident := incidents[0]
	message, err := s.incidentCard(ctx, incident)
	if err != nil {
		return err
	}
	body, err := slackui.Encode(s.sanitizer.Message(message))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID:          fmt.Sprintf("delivery_card_%s_%d", incident.ID, incident.CardVersion),
		IncidentID:  incident.ID,
		Operation:   "update",
		Kind:        "card",
		ChannelID:   incident.ChannelID,
		MessageTS:   incident.RootTS,
		Body:        body,
		CoalesceKey: "card:" + incident.ID,
		CardVersion: incident.CardVersion,
		AgentRunID:  incident.LatestUpdateRunID,
		AgentRunKey: incident.LatestUpdateRunKey,
	})
	if err != nil {
		return err
	}
	return nil
}

func (s *Service) incidentCard(
	ctx context.Context,
	incident core.Incident,
) (slackui.Message, error) {
	signals, err := s.store.ListSignals(ctx, incident.ID)
	if err != nil {
		return slackui.Message{}, err
	}
	hasCodeChanges := false
	codeChangesKnown := false
	publication, publicationErr := s.store.GetPublication(ctx, incident.ID)
	if publicationErr != nil && !errors.Is(publicationErr, store.ErrNotFound) {
		return slackui.Message{}, publicationErr
	}
	repository, _ := s.cfg.RepositoryContext(incident.Repository)
	client, _ := s.publisher.(taskpr.Inspector)
	missing := errors.Is(publicationErr, store.ErrNotFound)
	storedPublication := publication
	publication, changeBaseline, targetErr := s.taskPullRequestResolver(client).CardPublication(
		ctx, incident, repository, publication, missing, s.coop.GetSession,
	)
	if targetErr != nil {
		s.log.Warn(
			"resolve engineering task pull request for card",
			"incident", incident.ID, "error", trimError(targetErr),
		)
	}
	bindingFailureChanged := missing ||
		storedPublication.State != core.PublicationFailed ||
		storedPublication.FailureCode != core.PublicationFailureSessionBinding ||
		storedPublication.LastError != publication.LastError
	if publication.FailureCode == core.PublicationFailureSessionBinding &&
		bindingFailureChanged &&
		!storedPublication.InProgress() && !storedPublication.Published() &&
		storedPublication.State != core.PublicationStale {
		if missing {
			storedPublication = publication
		} else {
			storedPublication.State = core.PublicationFailed
			storedPublication.FailureCode = core.PublicationFailureSessionBinding
			storedPublication.LastError = publication.LastError
		}
		if saveErr := s.store.SavePublication(ctx, storedPublication); saveErr != nil {
			return slackui.Message{}, saveErr
		}
	} else if storedPublication.InProgress() {
		publication = storedPublication
	}
	if publication.FailureCode == core.PublicationFailureNoChanges {
		codeChangesKnown = true
	}
	var followup core.PublicationFollowup
	followup, followupErr := s.store.PublicationFollowups.Get(ctx, incident.ID)
	if followupErr != nil && !errors.Is(followupErr, core.ErrNotFound) {
		return slackui.Message{}, followupErr
	}
	var lifecycle core.PublicationLifecycleEvent
	lifecycle, lifecycleErr := s.store.PublicationFollowups.LatestLifecycleEvent(ctx, incident.ID)
	if lifecycleErr != nil && !errors.Is(lifecycleErr, core.ErrNotFound) {
		return slackui.Message{}, lifecycleErr
	}
	if incident.CoopSessionID != "" && !publication.InProgress() &&
		!followup.Terminal() &&
		publication.State != core.PublicationFailed && !publication.Published() &&
		!publication.NeedsUpdate() {
		changes, changesErr := s.coop.Changes(ctx, incident.CoopSessionID)
		if changesErr != nil {
			s.log.Warn(
				"inspect Coop changes for incident controls",
				"incident", incident.ID,
				"session", incident.CoopSessionID,
				"error", changesErr,
			)
		} else {
			hasCodeChanges = taskpr.ChangesPresent(changes, changeBaseline)
			codeChangesKnown = true
		}
	}
	// The window onto the running turn. A read that fails costs the card its
	// activity strip and nothing else, so it is logged rather than returned:
	// the operator needs the card far more than it needs the detail.
	turn, turnErr := liveturn.Fetch(
		ctx, s.store.Activity, s.store.Intelligence, s.store.Goals, incident,
	)
	if turnErr != nil {
		s.log.Warn("read the turn's interior for the card",
			"incident", incident.ID, "error", trimError(turnErr))
	}
	queuedBranches, branchErr := s.store.IncidentSessions.CountRetryingBranches(ctx, incident.ID)
	if branchErr != nil {
		s.log.Warn("count queued investigation branches for card",
			"incident", incident.ID, "error", trimError(branchErr))
	} else {
		turn.QueuedBranches = queuedBranches
	}
	return slackui.IncidentCardWithPublication(
		incident,
		s.repositoryName(incident.Repository),
		signals,
		hasCodeChanges,
		codeChangesKnown,
		publication,
		followup,
		lifecycle,
		turn,
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
	if err := s.requireNativeStatusClear(
		ctx,
		incident,
		fmt.Sprintf("incident_%d", incident.CardVersion),
	); err != nil {
		s.log.Warn(
			"queue Slack thread status clear",
			"incident", incident.ID,
			"error", err,
		)
		return
	}
	s.forgetNativeStatus(incident.ID)
}

func (s *Service) requireNativeStatusClear(
	ctx context.Context,
	incident core.Incident,
	causeID string,
) error {
	if !s.cfg.Slack.NativeStatus || !incident.ChannelWritable() ||
		incident.ChannelID == "" || incident.ConversationThreadTS() == "" {
		return nil
	}
	generation, err := s.store.NextSlackStatusGeneration(
		ctx,
		incident.ChannelID,
		incident.ConversationThreadTS(),
	)
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "delivery_status_clear_" + causeID + "_" +
			fmt.Sprintf("%d", generation),
		IncidentID: incident.ID, Operation: "status", Kind: "status",
		ChannelID:   incident.ChannelID,
		ThreadTS:    incident.ConversationThreadTS(),
		CoalesceKey: "status:" + incident.ChannelID + ":" + incident.ConversationThreadTS(),
		CardVersion: generation,
	})
	return err
}

func (s *Service) setNativeStatus(ctx context.Context, incident core.Incident, status string) {
	if !s.cfg.Slack.NativeStatus || !incident.ChannelWritable() ||
		incident.ChannelID == "" || incident.ConversationThreadTS() == "" {
		return
	}
	statusKey := incident.ID + "@" + incident.ConversationThreadTS()
	if !s.nativeStatus.ShouldWrite(statusKey, status, s.now()) {
		return
	}
	if err := s.enqueueNativeStatus(
		ctx,
		incident.ID,
		"",
		incident.ChannelID,
		incident.ConversationThreadTS(),
		status,
		slackui.ProgressMilestones(status),
	); err != nil {
		s.log.Warn("set Slack thread status", "incident", incident.ID, "error", err)
		return
	}
	s.nativeStatus.Record(statusKey, status, s.now())
}

func (s *Service) enqueueNativeStatus(
	ctx context.Context,
	incidentID string,
	episodeID string,
	channelID string,
	threadTS string,
	status string,
	steps []string,
) error {
	generation, err := s.store.NextSlackStatusGeneration(
		ctx,
		channelID,
		threadTS,
	)
	if err != nil {
		return err
	}
	id, err := core.NewID("delivery")
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: id, IncidentID: incidentID, EpisodeID: episodeID,
		Operation: "status", Kind: "status",
		ChannelID: channelID, ThreadTS: threadTS, Status: status, Steps: steps,
		CoalesceKey: "status:" + channelID + ":" + threadTS,
		CardVersion: generation,
	})
	return err
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

func (s *Service) turnNativeStatus(
	ctx context.Context,
	incident core.Incident,
	coopTurnID string,
) (core.Incident, string) {
	run, err := s.store.GetAgentRunByCoopTurn(ctx, coopTurnID)
	if err != nil {
		return incident, "is investigating..."
	}
	return s.agentRunStatusIncident(ctx, incident, run), s.agentRunNativeStatus(ctx, run)
}

func (s *Service) agentRunStatusIncident(
	ctx context.Context,
	incident core.Incident,
	run core.AgentRun,
) core.Incident {
	if run.SourceKind != "slack" {
		return incident
	}
	input, err := s.store.GetSlackInput(ctx, run.SourceID)
	if err != nil {
		return incident
	}
	if !incident.IsThreadScoped() {
		incident.RootTS = slackReplyThread(input)
	}
	return incident
}

func (s *Service) forgetNativeStatus(incidentID string) {
	s.nativeStatus.ForgetIncident(incidentID)
	// The activity throttle is keyed by the same incident and goes with it.
	// Left behind it would both grow without bound in a long-lived process and
	// charge a future turn on this card for the last one's final moment.
	s.cardActivity.Forget(incidentID)
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
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: id, IncidentID: incident.ID, Kind: kind,
		ChannelID: incident.ChannelID, ThreadTS: threadTS, Body: body,
	})
	return err
}

func (s *Service) enqueueEpisode(
	ctx context.Context,
	id string,
	episodeID string,
	incident core.Incident,
	kind string,
	threadTS string,
	message slackui.Message,
	responseRoot ...bool,
) error {
	episode, err := s.bindEpisodeDestination(
		ctx,
		episodeID,
		incident.ChannelID,
		threadTS,
		"response_location",
	)
	if err != nil {
		return err
	}
	threadTS = episode.Destination.ThreadTS
	body, err := slackui.Encode(s.sanitizer.Message(message))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: id, IncidentID: incident.ID, EpisodeID: episodeID, Kind: kind,
		ChannelID: incident.ChannelID, ThreadTS: threadTS, Body: body,
		ResponseRoot: len(responseRoot) > 0 && responseRoot[0],
	})
	return err
}

func (s *Service) enqueueMessageUpdate(
	ctx context.Context,
	id string,
	incident core.Incident,
	kind string,
	messageTS string,
	message slackui.Message,
) error {
	body, err := slackui.Encode(s.sanitizer.Message(message))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: id, IncidentID: incident.ID, Operation: "update", Kind: kind,
		ChannelID: incident.ChannelID, ThreadTS: incident.ConversationThreadTS(),
		MessageTS: messageTS, Body: body,
	})
	return err
}

func (s *Service) repositoryName(name string) string {
	repository, ok := s.cfg.RepositoryContext(name)
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
		visible := min(len(group.items), 12)
		for _, item := range group.items[:visible] {
			path := item.Path
			if path == "" {
				path = fmt.Sprintf("%x", item.PathBytes)
			}
			lines = append(lines, fmt.Sprintf("`%s` %s", path, item.Status))
		}
		if remaining := len(group.items) - visible; remaining > 0 {
			lines = append(lines, fmt.Sprintf("_…and %d more %s files._", remaining, strings.ToLower(group.name)))
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
	return strings.Join(lines, "\n")
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
