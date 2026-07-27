package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

type frozenAction struct {
	SessionID string `json:"session_id"`
	TurnID    string `json:"turn_id,omitempty"`
	Revision  int64  `json:"revision"`
}

func (s *Service) processSlackInput(ctx context.Context) error {
	input, err := s.store.LeaseSlackInput(ctx)
	if err != nil {
		return err
	}
	if input.TeamID != s.cfg.Slack.TeamID {
		return s.store.RetrySlackInput(ctx, input.ID, "wrong Slack workspace", time.Now(), true)
	}
	if !s.cfg.IsOperator(input.UserID) {
		s.denyInput(ctx, input, "This action is restricted to configured incident operators.")
		return s.finishSlackInput(ctx, input)
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return s.retrySlackInput(ctx, input, err)
	}
	if !allowed {
		s.denyInput(ctx, input, "Slack guests, bots, and external workspace members cannot steer Responder.")
		return s.finishSlackInput(ctx, input)
	}

	incident, incidentErr := s.store.FindIncidentByChannel(ctx, input.ChannelID)
	if errors.Is(incidentErr, store.ErrNotFound) && input.Kind == "mention" &&
		s.cfg.IsSummonChannel(input.ChannelID) {
		return s.createManualIncident(ctx, input)
	}
	if errors.Is(incidentErr, store.ErrNotFound) {
		return s.finishSlackInput(ctx, input)
	}
	if incidentErr != nil {
		return s.retrySlackInput(ctx, input, incidentErr)
	}
	if input.Kind == "action" {
		if input.ActionValue != incident.ID || input.MessageTS != incident.RootTS {
			return s.store.RetrySlackInput(ctx, input.ID, "stale or mismatched incident control", time.Now(), true)
		}
		err = s.handleControl(ctx, input, incident, input.ActionID)
	} else {
		if input.ThreadTS != incident.RootTS {
			return s.finishSlackInput(ctx, input)
		}
		text := strings.TrimSpace(input.Text)
		if input.Kind == "mention" {
			text = s.stripBotMention(text)
		}
		if command, ok := exactCommand(text); ok {
			err = s.handleControl(ctx, input, incident, command)
		} else if text == "" {
			err = errors.New("empty Slack message")
		} else {
			_, _, err = s.store.QueueTurn(ctx, core.TurnSubmission{
				IncidentID: incident.ID, SourceKind: "slack", SourceID: input.ID,
				UserID: input.UserID, Prompt: operatorPrompt(input.UserID, text),
			})
		}
	}
	if err != nil {
		return s.retrySlackInput(ctx, input, err)
	}
	return s.finishSlackInput(ctx, input)
}

func (s *Service) createManualIncident(ctx context.Context, input core.SlackInput) error {
	title := s.stripBotMention(input.Text)
	if title == "" {
		title = "Manual incident"
	}
	if len(title) > 200 {
		title = title[:200]
	}
	incident, _, err := s.store.CreateManualIncident(
		ctx, s.cfg.Slack.DefaultRepository, input.EventID, title, input.UserID,
		s.cfg.Limits.MaxOpenIncidents,
	)
	if err != nil {
		if errors.Is(err, store.ErrCapacity) {
			if noticeErr := s.postInputNotice(
				ctx,
				"manual_capacity_"+input.ID,
				input,
				"Responder is at its open incident limit. Close an existing incident or raise "+
					"limits.max_open_incidents, then try again.",
			); noticeErr != nil {
				return s.retrySlackInput(ctx, input, noticeErr)
			}
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "incident.manual", ActorID: input.UserID,
				ObjectID: input.EventID, Outcome: "rejected", Detail: trimError(err),
			})
			return s.finishSlackInput(ctx, input)
		}
		return s.retrySlackInput(ctx, input, err)
	}
	thread := input.ThreadTS
	if thread == "" {
		thread = input.MessageTS
	}
	if err := s.enqueue(
		ctx, "out_manual_ack_"+input.ID, core.Incident{
			ID: incident.ID, ChannelID: input.ChannelID,
		}, "notice", thread,
		slackui.Notice("Incident accepted. I’m creating a dedicated channel and isolated Coop fork now."),
	); err != nil {
		return s.retrySlackInput(ctx, input, err)
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "incident.manual", ActorID: input.UserID,
		ObjectID: input.EventID, Outcome: "accepted", Detail: title,
	})
	return s.finishSlackInput(ctx, input)
}

func (s *Service) postInputNotice(
	ctx context.Context,
	id string,
	input core.SlackInput,
	text string,
) error {
	thread := input.ThreadTS
	if thread == "" {
		thread = input.MessageTS
	}
	if _, err := s.slack.FindOutboxMessage(ctx, input.ChannelID, thread, id); err == nil {
		return nil
	} else if !errors.Is(err, slackui.ErrNotFound) {
		return err
	}
	message := slackui.Notice(text)
	if s.sanitizer != nil {
		message = s.sanitizer.Message(message)
	}
	_, err := s.slack.Post(ctx, id, input.ChannelID, thread, message)
	return err
}

func exactCommand(text string) (string, bool) {
	switch strings.TrimSpace(strings.ToLower(text)) {
	case "!respond status":
		return "status", true
	case "!respond update":
		return slackui.ActionUpdate, true
	case "!respond changes":
		return slackui.ActionChanges, true
	case "!respond review":
		return slackui.ActionReview, true
	case "!respond stop":
		return slackui.ActionStop, true
	case "!respond extend":
		return slackui.ActionExtend, true
	case "!respond close":
		return slackui.ActionResolve, true
	case "!respond help":
		return slackui.ActionHelp, true
	default:
		return "", false
	}
}

func (s *Service) handleControl(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
	control string,
) error {
	switch control {
	case "status":
		return s.enqueue(ctx, "out_status_"+input.ID, incident, "notice", incident.RootTS,
			slackui.Notice(fmt.Sprintf(
				"Incident %s is %s; Responder is %s. %d of %d signals are firing.",
				slackui.ShortID(incident.ID), incident.Status, incident.Workflow,
				incident.FiringCount, incident.SignalCount,
			)))
	case slackui.ActionHelp:
		return s.enqueue(ctx, "out_help_"+input.ID, incident, "notice",
			incident.RootTS, slackui.HelpMessage(incident.ID))
	case slackui.ActionUpdate:
		_, _, err := s.store.QueueTurn(ctx, core.TurnSubmission{
			IncidentID: incident.ID, SourceKind: "control", SourceID: input.ID,
			UserID: input.UserID,
			Prompt: operatorPrompt(input.UserID,
				"Give a concise incident update: verified facts, current hypothesis, code changes, blockers, and next action."),
		})
		return err
	case slackui.ActionChanges:
		if incident.CoopSessionID == "" {
			return s.enqueue(ctx, "out_changes_"+input.ID, incident, "notice",
				incident.RootTS, slackui.Notice("The incident fork is still being prepared."))
		}
		changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
		if err != nil {
			return err
		}
		return s.enqueue(ctx, "out_changes_"+input.ID, incident, "changes",
			incident.RootTS, slackui.ChangesMessage(incident, changesSummary(changes)))
	case slackui.ActionReview:
		return s.reviewFix(ctx, input, incident)
	case slackui.ActionStop:
		return s.stopTurn(ctx, input, incident)
	case slackui.ActionExtend:
		return s.extendSession(ctx, input, incident)
	case slackui.ActionResolve:
		return s.closeIncident(ctx, input, incident)
	default:
		return errors.New("unknown Responder control")
	}
}

func (s *Service) extendSession(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.CoopSessionID == "" {
		return s.enqueue(ctx, "out_extend_"+input.ID, incident, "notice",
			incident.RootTS, slackui.Notice("The incident session is still being prepared."))
	}
	action, err := s.freezeAction(ctx, input, incident, false)
	if err != nil {
		return err
	}
	session, _, err := s.coop.Extend(
		ctx, "responder:extend:"+input.ID, action.SessionID, action.Revision, s.cfg.Coop.ExtendTurns,
	)
	if err != nil {
		return err
	}
	workflow := core.WorkflowParked
	if session.ActiveTurnID != "" || session.QueuedTurnCount > 0 {
		workflow = core.WorkflowInvestigating
	}
	if err := s.store.UpdateCoopState(
		ctx, incident.ID, session.Revision, incident.CoopEventSequence,
		session.ActiveTurnID, workflow,
	); err != nil {
		return err
	}
	if err := s.store.SetIncidentError(ctx, incident.ID, workflow, ""); err != nil {
		return err
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "coop.budget.extend", ActorID: input.UserID,
		ObjectID: incident.CoopSessionID, Outcome: "succeeded",
		Detail: fmt.Sprintf("%d turns", s.cfg.Coop.ExtendTurns),
	})
	return s.enqueue(ctx, "out_extend_"+input.ID, incident, "notice", incident.RootTS,
		slackui.Notice(fmt.Sprintf(
			"Added %d turns to the incident session budget.", s.cfg.Coop.ExtendTurns,
		)))
}

func (s *Service) reviewFix(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.CoopSessionID == "" {
		return s.enqueue(ctx, "out_review_"+input.ID, incident, "notice",
			incident.RootTS, slackui.Notice("The incident fork is still being prepared."))
	}
	if incident.ActiveTurnID != "" {
		return s.enqueue(ctx, "out_review_"+input.ID, incident, "notice",
			incident.RootTS, slackui.Notice("Wait for the active turn to finish or stop it before reviewing."))
	}
	action, err := s.freezeAction(ctx, input, incident, false)
	if err != nil {
		return err
	}
	review, _, err := s.coop.Review(
		ctx, "responder:review:"+input.ID, action.SessionID, action.Revision,
	)
	if err != nil {
		return err
	}
	return s.enqueue(ctx, "out_review_"+input.ID, incident, "review", incident.RootTS,
		slackui.ReviewMessage(incident, reviewSummary(review), review.Publishable))
}

func (s *Service) stopTurn(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.ActiveTurnID == "" {
		return s.enqueue(ctx, "out_stop_"+input.ID, incident, "notice",
			incident.RootTS, slackui.Notice("No agent turn is currently running."))
	}
	action, err := s.freezeAction(ctx, input, incident, true)
	if err != nil {
		return err
	}
	_, _, err = s.coop.Cancel(
		ctx, "responder:stop:"+input.ID, action.SessionID, action.TurnID, action.Revision,
	)
	if err != nil {
		return err
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "coop.turn.cancel", ActorID: input.UserID,
		ObjectID: action.TurnID, Outcome: "requested",
	})
	return s.enqueue(ctx, "out_stop_"+input.ID, incident, "notice",
		incident.RootTS, slackui.Notice("Stop requested. The fork and queued evidence are preserved."))
}

func (s *Service) closeIncident(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.ActiveTurnID != "" {
		return s.enqueue(ctx, "out_close_"+input.ID, incident, "notice",
			incident.RootTS, slackui.Notice("Stop the active turn before closing this incident."))
	}
	if incident.CoopSessionID != "" {
		action, err := s.freezeAction(ctx, input, incident, false)
		if err != nil {
			return err
		}
		if _, _, err := s.coop.Close(
			ctx, "responder:close:"+input.ID, action.SessionID, action.Revision,
		); err != nil {
			return err
		}
	}
	if err := s.store.CloseIncident(ctx, incident.ID); err != nil {
		return err
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "incident.close", ActorID: input.UserID,
		ObjectID: incident.CoopSessionID, Outcome: "succeeded",
	})
	return s.enqueue(ctx, "out_close_"+input.ID, incident, "notice",
		incident.RootTS,
		slackui.Notice("Incident closed. Its Coop fork is preserved for explicit review or cleanup."))
}

func (s *Service) freezeAction(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
	includeTurn bool,
) (frozenAction, error) {
	if len(input.Frozen) > 0 {
		var action frozenAction
		if err := json.Unmarshal(input.Frozen, &action); err != nil {
			return frozenAction{}, err
		}
		return action, nil
	}
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		return frozenAction{}, err
	}
	action := frozenAction{SessionID: session.ID, Revision: session.Revision}
	if includeTurn {
		action.TurnID = session.ActiveTurnID
		if action.TurnID == "" {
			return frozenAction{}, errors.New("the active turn already finished")
		}
	}
	data, err := json.Marshal(action)
	if err != nil {
		return frozenAction{}, err
	}
	data, err = s.store.FreezeSlackInput(ctx, input.ID, data)
	if err != nil {
		return frozenAction{}, err
	}
	if err := json.Unmarshal(data, &action); err != nil {
		return frozenAction{}, err
	}
	return action, nil
}

func (s *Service) retrySlackInput(ctx context.Context, input core.SlackInput, err error) error {
	terminal := terminalAttempt(input.Attempts, s.cfg.Limits.MaxOutboxAttempts)
	var apiErr *coop.APIError
	if errors.As(err, &apiErr) && !apiErr.Retryable() {
		terminal = true
	}
	if terminal {
		if incident, incidentErr := s.store.FindIncidentByChannel(ctx, input.ChannelID); incidentErr == nil {
			_ = s.enqueue(
				ctx, "out_input_error_"+input.ID, incident, "notice", incident.RootTS,
				slackui.Notice("Responder could not complete that request: "+trimError(err)),
			)
		}
	}
	return s.store.RetrySlackInput(ctx, input.ID, trimError(err), queueDelay(input.Attempts), terminal)
}

func (s *Service) finishSlackInput(ctx context.Context, input core.SlackInput) error {
	if err := s.store.FinishSlackInput(ctx, input.ID); err != nil {
		_ = s.store.RetrySlackInput(ctx, input.ID, trimError(err), queueDelay(input.Attempts), false)
		return err
	}
	return nil
}

func (s *Service) denyInput(ctx context.Context, input core.SlackInput, reason string) {
	incident, err := s.store.FindIncidentByChannel(ctx, input.ChannelID)
	if err == nil && (input.ThreadTS == incident.RootTS || input.MessageTS == incident.RootTS) {
		_ = s.enqueue(ctx, "out_denied_"+input.ID, incident, "notice",
			incident.RootTS, slackui.Notice(reason))
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "slack.input", ActorID: input.UserID,
		ObjectID: input.ID, Outcome: "denied", Detail: reason,
	})
}
