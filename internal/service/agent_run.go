package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func (s *Service) queueIncidentAgentRun(
	ctx context.Context,
	incident core.Incident,
	sourceKind string,
	sourceID string,
	userID string,
	prompt string,
) (core.AgentRun, bool, error) {
	mode := core.AgentRunIncident
	if incident.IsEngineeringTask() {
		mode = core.AgentRunEngineeringTask
	}
	return s.store.QueueAgentRun(ctx, core.AgentRun{
		Mode: mode, IncidentID: incident.ID, ChannelID: incident.ChannelID,
		ThreadTS:        incident.ConversationThreadTS(),
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      sourceKind, SourceID: sourceID, UserID: userID,
		Repository: incident.Repository, Prompt: prompt,
		SessionID:       incident.CoopSessionID,
		CommitmentTitle: incident.Title,
	})
}

func (s *Service) queueWatchedInput(ctx context.Context, input core.SlackInput) error {
	state := watchTurnState{}
	if len(input.Frozen) > 0 {
		legacy, err := decodeWatchState(input.Frozen)
		if err != nil {
			return fmt.Errorf("migrate legacy watched input state: %w", err)
		}
		if legacy.TurnID != "" {
			memory, memoryErr := s.store.GetChannelMemory(
				ctx, input.ChannelID,
			)
			if memoryErr != nil && !errors.Is(memoryErr, store.ErrNotFound) {
				return memoryErr
			}
			contextJSON, marshalErr := json.Marshal(legacy)
			if marshalErr != nil {
				return marshalErr
			}
			_, _, queueErr := s.store.QueueAgentRun(ctx, core.AgentRun{
				Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
				ThreadTS:        conversationalResponseThread(input),
				ConversationKey: watchConversationKey(input),
				SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
				Repository: legacy.Repository,
				IdempotencyKey: watchTurnIdempotencyKey(
					input.ID, legacy.Generation,
				),
				SessionID: legacy.SessionID, SessionGeneration: legacy.Generation,
				ExpectedRevision:  legacy.ExpectedRevision,
				CoopTurnID:        legacy.TurnID,
				CoopEventSequence: memory.CoopEventSequence,
				Context:           contextJSON, State: core.AgentRunRunning,
				StartedAt:       time.Now().UTC(),
				CommitmentTitle: commitmentTitleForInput(input),
			})
			if queueErr != nil {
				return queueErr
			}
			return s.finishInputIfOpen(ctx, input)
		}
		state = legacy
	}
	if !state.RulesCaptured {
		rules, err := s.matchingStandingRules(ctx, input)
		if err != nil {
			return err
		}
		state.MatchedRules = rules
		state.RulesCaptured = true
	}
	if watchInputTargeted(input, state) && s.cfg.Slack.NativeStatus {
		if err := s.enqueueNativeStatus(
			ctx,
			"",
			input.ChannelID,
			slackReplyThread(input),
			watchPendingStatus,
			watchProgressSteps(),
		); err != nil {
			s.log.Warn(
				"set queued watched Slack status",
				"channel", input.ChannelID,
				"thread", slackReplyThread(input),
				"input", input.ID,
				"error", err,
			)
		} else {
			state.PendingStatusSet = true
			state.PendingStatusAt = time.Now().Unix()
		}
	}
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return err
	}
	latestAt, err := s.store.LatestSlackConversationAt(ctx, input.ChannelID)
	if err != nil {
		return err
	}
	readyAt := latestAt.Add(s.cfg.Slack.WatchSettleDelay.Duration)
	run, _, err := s.store.QueueAgentRun(ctx, core.AgentRun{
		Mode:            core.AgentRunTriage,
		ChannelID:       input.ChannelID,
		ThreadTS:        conversationalResponseThread(input),
		ConversationKey: watchConversationKey(input),
		SourceKind:      "watch",
		SourceID:        input.ID,
		UserID:          input.UserID,
		Context:         contextJSON,
		NextAttemptAt:   readyAt,
		CommitmentTitle: commitmentTitleForInput(input),
	})
	if err != nil {
		return err
	}
	if state.PendingStatusSet && len(run.Context) > 0 &&
		string(run.Context) != string(contextJSON) {
		if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
			return err
		}
	}
	return s.finishSlackInput(ctx, input)
}

func commitmentTitleForInput(input core.SlackInput) string {
	text := strings.TrimSpace(boundedOperatorText(input.Text))
	if text == "" {
		switch input.Kind {
		case "bot_message":
			return "Review an app notification"
		case "shortcut":
			return "Investigate a selected Slack message"
		default:
			return "Answer a Slack request"
		}
	}
	text = strings.Join(strings.Fields(text), " ")
	if len(text) > 180 {
		text = text[:180]
		for len(text) > 0 && !utf8.ValidString(text) {
			text = text[:len(text)-1]
		}
		text = strings.TrimSpace(text) + "..."
	}
	return text
}

func watchInputTargeted(input core.SlackInput, state watchTurnState) bool {
	return input.Kind == "direct" || input.Kind == "mention" ||
		input.Kind == "shortcut" || len(state.MatchedRules) > 0
}

func watchConversationKey(input core.SlackInput) string {
	switch input.Kind {
	case "message", "bot_message", "direct":
		return "channel:" + input.ChannelID
	default:
		return "thread:" + input.ChannelID + ":" + slackReplyThread(input)
	}
}

func watchProgressSteps() []string {
	return []string{
		"Reading the latest channel context",
		"Mapping declared topology from the repository",
		"Checking live infrastructure state with Emisar",
		"Reconciling identities, freshness, and coverage",
		"Preparing a concise response",
	}
}

func decodeWatchRunContext(run core.AgentRun) (watchTurnState, error) {
	if len(run.Context) == 0 {
		return watchTurnState{}, nil
	}
	var state watchTurnState
	if err := decodeStrictJSON(run.Context, &state); err != nil {
		return watchTurnState{}, err
	}
	return state, nil
}

func (s *Service) processAgentRun(ctx context.Context) error {
	run, err := s.store.LeaseAgentRun(ctx)
	if err != nil {
		return err
	}
	switch run.Mode {
	case core.AgentRunTriage:
		return s.prepareTriageAgentRun(ctx, run)
	case core.AgentRunIncident, core.AgentRunEngineeringTask:
		return s.prepareIncidentAgentRun(ctx, run)
	default:
		return s.store.RetryAgentRun(
			ctx, run.ID, "unsupported agent run mode "+string(run.Mode), time.Now(), true,
		)
	}
}

func (s *Service) prepareIncidentAgentRun(
	ctx context.Context,
	run core.AgentRun,
) error {
	incident, err := s.store.GetIncident(ctx, run.IncidentID)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, core.Incident{}, err, true)
	}
	if !incident.ChannelWritable() {
		return s.retryIncidentAgentRun(
			ctx,
			run,
			incident,
			fmt.Errorf(
				"agent run suppressed because the Slack work conversation is %s",
				incident.ChannelState,
			),
			true,
		)
	}
	session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, !coop.Retryable(err))
	}
	if session.State == "closed" {
		return s.retryIncidentAgentRun(
			ctx, run, incident, errors.New("the Coop session is closed"), true,
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
			return s.store.DeferAgentRun(
				ctx, run.ID, detail, time.Now().Add(30*time.Second),
			)
		}
		detail := "Responder could not allocate additional automatic session capacity: " +
			trimError(err) + ". The pending request and Coop session are preserved; " +
			"Responder will retry after the Coop limit or service error is corrected."
		_ = s.store.SetIncidentError(ctx, incident.ID, core.WorkflowParked, detail)
		return s.store.DeferAgentRun(
			ctx, run.ID, detail, queueDelay(run.Failures),
		)
	}
	if session.State != "open" {
		return s.retryIncidentAgentRun(
			ctx,
			run,
			incident,
			fmt.Errorf("Coop session has unsupported state %q", session.State),
			true,
		)
	}
	assembled, captured := decodeAssembledAgentContext(run.Context)
	if !captured {
		assembled, err = s.assembleAgentContext(
			ctx,
			agentContextRequest{
				ChannelID: incident.ChannelID, Repository: incident.Repository,
				OperatorID: run.UserID, SourceInputID: run.SourceID,
			},
		)
		if err != nil {
			return s.retryIncidentAgentRun(ctx, run, incident, err, false)
		}
		contextJSON, marshalErr := json.Marshal(assembled)
		if marshalErr != nil {
			return s.retryIncidentAgentRun(
				ctx, run, incident, marshalErr, false,
			)
		}
		run.Context = contextJSON
		run.Repository = assembled.Repository
	}
	if err := s.store.BindAgentRunSession(
		ctx,
		run.ID,
		session.ID,
		0,
		firstNonempty(run.Repository, incident.Repository),
		incident.CoopEventSequence,
		run.Context,
	); err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, false)
	}
	run.SessionID = session.ID
	run.CoopEventSequence = incident.CoopEventSequence
	prompt := run.Prompt
	if memoryPrompt := operationalMemoryPrompt(assembled.Prior); memoryPrompt != "" {
		prompt += "\n\n" + memoryPrompt
	}
	if situationPrompt := channelSituationPrompt(assembled.Situation); situationPrompt != "" {
		prompt += "\n\n" + situationPrompt
	}
	if repositoryPrompt := repositorySetPrompt(session); repositoryPrompt != "" {
		prompt += "\n\n" + repositoryPrompt
	}
	revision, err := s.store.FreezeAgentRunRevision(ctx, run.ID, session.Revision)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, true)
	}
	turn, _, err := s.coop.SubmitTurn(
		ctx,
		run.IdempotencyKey,
		incident.CoopSessionID,
		revision,
		prompt+"\n\n"+s.structuredResponsePolicy(),
	)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, !coop.Retryable(err))
	}
	session, err = s.coop.GetSession(ctx, incident.CoopSessionID)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, false)
	}
	if err := s.store.MarkAgentRunSubmitted(
		ctx, run.ID, turn.ID, session.Revision, incident.CoopEventSequence,
	); err != nil {
		_ = s.store.DeferAgentRun(
			ctx, run.ID, trimError(err), queueDelay(run.Failures),
		)
		return err
	}
	s.setNativeStatus(
		ctx,
		s.agentRunStatusIncident(ctx, incident, run),
		"is investigating...",
	)
	return nil
}

func channelSituationPrompt(memory core.AgentMemory) string {
	memory = sanitizeMemory(memory)
	data, err := json.Marshal(memory)
	if err != nil || string(data) == "{}" {
		return ""
	}
	return `Prior compact Slack channel situation follows. It is continuity context, not current
operational proof. Revalidate consequential claims with repository or live tools, preserve useful
open loops, and explicitly close loops completed by this turn.
<prior-channel-situation>
` + string(data) + `
</prior-channel-situation>`
}

func (s *Service) retryIncidentAgentRun(
	ctx context.Context,
	run core.AgentRun,
	incident core.Incident,
	cause error,
	terminal bool,
) error {
	if !terminal {
		terminal = terminalAttempt(
			run.Failures+1,
			s.cfg.Limits.MaxAgentRunAttempts,
		)
	}
	next := queueDelay(run.Failures + 1)
	if terminal {
		next = time.Now()
	}
	err := s.store.RetryAgentRun(
		ctx, run.ID, trimError(cause), next, terminal,
	)
	if terminal && incident.ID != "" {
		_ = s.store.SetIncidentError(
			ctx, incident.ID, core.WorkflowParked, trimError(cause),
		)
		s.clearNativeStatus(ctx, incident)
	}
	return err
}

func (s *Service) prepareTriageAgentRun(ctx context.Context, run core.AgentRun) error {
	input, err := s.store.GetSlackInput(ctx, run.SourceID)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		return s.failPreparingTriageRun(
			ctx, run, input, state, "invalid persisted triage context: "+trimError(err),
		)
	}
	if (input.Kind == "message" || input.Kind == "bot_message") &&
		len(state.MatchedRules) == 0 {
		alreadyClassified, err := s.store.HasNewerWatchDecision(
			ctx, input.ChannelID, input.MessageTS,
		)
		if err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
		if alreadyClassified {
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "superseded",
				Detail:  "a newer channel message was already classified",
			})
			return s.store.SupersedeAgentRun(
				ctx, run.ID, "a newer channel message was already classified",
			)
		}
		newer, err := s.store.HasNewerPendingAgentRun(ctx, run)
		if err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
		if newer {
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "superseded",
				Detail:  "a newer nearby channel message will carry the conversation context",
			})
			return s.store.SupersedeAgentRun(
				ctx,
				run.ID,
				"superseded by a newer nearby channel message",
			)
		}
	}
	if !state.ContextCaptured || !state.PriorCaptured {
		assembled, err := s.assembleAgentContext(
			ctx,
			agentContextRequest{
				ChannelID: input.ChannelID,
				Repository: firstNonempty(
					state.Repository,
					s.cfg.Slack.DefaultRepository,
				),
				OperatorID: input.UserID, SourceInputID: input.ID,
				TargetInput: &input, IncludeRecent: true,
			},
		)
		if err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
		state.RecentMessages = assembled.RecentMessages
		state.Prior = assembled.Prior
		state.ContextCaptured = true
		state.PriorCaptured = true
	}
	if !state.RulesCaptured {
		state.MatchedRules, err = s.matchingStandingRules(ctx, input)
		if err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
		state.RulesCaptured = true
	}
	memory, session, err := s.ensureWatchSession(ctx, input.ChannelID)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	if session.ActiveTurnID != "" {
		return s.store.DeferAgentRun(
			ctx,
			run.ID,
			"waiting for the previous agent run in this Slack channel",
			time.Now().Add(time.Second),
		)
	}
	switch session.State {
	case "exhausted":
		session, err = s.ensureTurnCapacity(ctx, input.ChannelID, "", session)
		if err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
	case "open":
	default:
		return s.retryAgentRun(
			ctx,
			run,
			fmt.Errorf("watch channel Coop session has unsupported state %q", session.State),
		)
	}
	state.SessionID = session.ID
	state.Repository = memory.Repository
	state.Generation = memory.Generation
	state.Memory = memory.State
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	if err := s.store.BindAgentRunSession(
		ctx,
		run.ID,
		session.ID,
		memory.Generation,
		memory.Repository,
		memory.CoopEventSequence,
		contextJSON,
	); err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	run.SessionID = session.ID
	run.SessionGeneration = memory.Generation
	run.Repository = memory.Repository
	run.Context = contextJSON
	run.CoopEventSequence = memory.CoopEventSequence
	revision, err := s.store.FreezeAgentRunRevision(ctx, run.ID, session.Revision)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	turn, _, err := s.coop.SubmitTurn(
		ctx,
		run.IdempotencyKey,
		session.ID,
		revision,
		s.watchPrompt(
			input,
			s.identity.BotUserID,
			state.RecentMessages,
			state.Memory,
			state.Prior,
			firstNonempty(memory.Repository, s.cfg.Slack.DefaultRepository),
			state.MatchedRules,
		)+"\n\n"+repositorySetPrompt(session),
	)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	if turn.ID == "" {
		return s.retryAgentRun(ctx, run, errors.New("Coop returned an empty agent turn ID"))
	}
	session, err = s.coop.GetSession(ctx, session.ID)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	return s.store.MarkAgentRunSubmitted(
		ctx,
		run.ID,
		turn.ID,
		session.Revision,
		run.CoopEventSequence,
	)
}

func (s *Service) retryAgentRun(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) error {
	terminal := terminalAttempt(run.Failures+1, s.cfg.Limits.MaxAgentRunAttempts)
	var apiErr *coop.APIError
	if errors.As(cause, &apiErr) && !apiErr.Retryable() {
		terminal = true
	}
	if run.Mode == core.AgentRunTriage && terminal {
		input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
		state, stateErr := decodeWatchRunContext(run)
		if inputErr == nil && stateErr == nil {
			return s.failPreparingTriageRun(ctx, run, input, state, trimError(cause))
		}
	}
	return s.store.RetryAgentRun(
		ctx,
		run.ID,
		trimError(cause),
		queueDelay(run.Failures+1),
		terminal,
	)
}

func (s *Service) failPreparingTriageRun(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state watchTurnState,
	detail string,
) error {
	if err := s.postInputNotice(
		ctx,
		"watch_failure_"+input.ID,
		input,
		watchFailureNotice(detail),
	); err != nil {
		return s.store.RetryAgentRun(
			ctx,
			run.ID,
			"deliver terminal triage failure: "+trimError(err),
			queueDelay(run.Failures+1),
			false,
		)
	}
	if err := s.clearWatchPendingStatus(ctx, input, state); err != nil {
		return s.store.RetryAgentRun(
			ctx,
			run.ID,
			"clear terminal triage status: "+trimError(err),
			queueDelay(run.Failures+1),
			false,
		)
	}
	_ = s.retireFailedWatchSession(ctx, input, state)
	_ = s.store.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
		Outcome: "failed", Detail: detail,
	})
	return s.store.RetryAgentRun(ctx, run.ID, detail, time.Now(), true)
}

func (s *Service) pollAgentRuns(ctx context.Context) {
	runs, err := s.store.ListRunningAgentRuns(ctx, 200)
	if err != nil {
		s.log.Error("list running agent runs", "error", err)
		return
	}
	for _, run := range runs {
		if err := s.pollAgentRun(ctx, run); err != nil && ctx.Err() == nil {
			s.log.Warn(
				"poll agent run",
				"run", run.ID,
				"session", run.SessionID,
				"turn", run.CoopTurnID,
				"error", err,
			)
		}
	}
}

func (s *Service) pollAgentRun(ctx context.Context, run core.AgentRun) error {
	events, err := s.coop.Events(ctx, run.SessionID, run.CoopEventSequence, 100)
	if err != nil {
		return err
	}
	cursor := run.CoopEventSequence
	for _, event := range events {
		if event.Sequence > cursor {
			cursor = event.Sequence
		}
		if event.TurnID != run.CoopTurnID {
			continue
		}
		switch event.Type {
		case "turn.completed", "turn.failed", "turn.cancelled":
			turn, err := s.coop.GetTurn(ctx, run.SessionID, run.CoopTurnID)
			if err != nil {
				return err
			}
			detail := strings.TrimSpace(
				firstNonempty(turn.ErrorDetail, turn.ErrorCode, turn.StopReason),
			)
			if reason, replay := replayAgentRunFailure(
				run,
				event.Type,
				turn,
				s.cfg.Limits.MaxAgentRunAttempts,
			); replay {
				if err := s.store.RequeueInterruptedAgentRun(
					ctx,
					run.ID,
					reason,
					cursor,
					time.Now(),
				); err != nil {
					return err
				}
				if run.Mode == core.AgentRunTriage {
					_ = s.store.AdvanceChannelEvents(
						ctx, run.ChannelID, run.SessionID, cursor,
					)
				}
				return nil
			}
			if err := s.store.StageAgentRunResult(
				ctx,
				run.ID,
				strings.TrimPrefix(event.Type, "turn."),
				[]byte(turn.AssistantMessage),
				detail,
				cursor,
			); err != nil {
				return err
			}
			if run.Mode == core.AgentRunTriage {
				_ = s.store.AdvanceChannelEvents(
					ctx, run.ChannelID, run.SessionID, cursor,
				)
			}
			return nil
		}
	}
	if cursor > run.CoopEventSequence {
		if err := s.store.AdvanceAgentRunEvents(ctx, run.ID, cursor); err != nil {
			return err
		}
		if run.Mode == core.AgentRunTriage {
			if err := s.store.AdvanceChannelEvents(
				ctx, run.ChannelID, run.SessionID, cursor,
			); err != nil {
				return err
			}
		}
	}
	if run.Mode == core.AgentRunTriage {
		input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
		state, stateErr := decodeWatchRunContext(run)
		if inputErr == nil && stateErr == nil && watchInputTargeted(input, state) {
			if err := s.ensureWatchRunPendingStatus(ctx, run, input, &state); err != nil {
				s.log.Warn("refresh watched run status", "run", run.ID, "error", err)
			}
		}
	}
	return nil
}

func replayAgentRunFailure(
	run core.AgentRun,
	eventType string,
	turn coop.Turn,
	maximumAttempts int,
) (string, bool) {
	if eventType != "turn.failed" ||
		terminalAttempt(run.Failures+1, maximumAttempts) {
		return "", false
	}
	detail := strings.TrimSpace(turn.ErrorDetail)
	if turn.ErrorCode == "acp_cancelled" && detail == "turn cancelled" {
		return "Coop turn was interrupted while Responder was stopping", true
	}
	if run.Failures == 0 &&
		turn.ErrorCode == "acp_protocol_error" &&
		strings.Contains(detail, "ACP frame exceeded its bound") {
		return "Coop returned an oversized ACP frame; retrying the turn once", true
	}
	return "", false
}

func (s *Service) ensureWatchRunPendingStatus(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state *watchTurnState,
) error {
	if !s.cfg.Slack.NativeStatus {
		return nil
	}
	statusAt := time.Unix(state.PendingStatusAt, 0)
	if state.PendingStatusSet && time.Since(statusAt) < watchPendingStatusRefresh {
		return nil
	}
	if err := s.enqueueNativeStatus(
		ctx,
		"",
		input.ChannelID,
		slackReplyThread(input),
		watchPendingStatus,
		watchProgressSteps(),
	); err != nil {
		return err
	}
	state.PendingStatusSet = true
	state.PendingStatusAt = time.Now().Unix()
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return s.store.SetAgentRunContext(ctx, run.ID, contextJSON)
}

func (s *Service) processAgentRunFinalization(ctx context.Context) error {
	run, err := s.store.LeaseAgentRunFinalization(ctx)
	if err != nil {
		return err
	}
	switch run.Mode {
	case core.AgentRunTriage:
		if err := s.finalizeTriageAgentRun(ctx, run); err != nil {
			return s.retryAgentRunFinalization(ctx, run, err)
		}
		return nil
	case core.AgentRunIncident, core.AgentRunEngineeringTask:
		if err := s.finalizeIncidentAgentRun(ctx, run); err != nil {
			return s.retryAgentRunFinalization(ctx, run, err)
		}
		return nil
	default:
		detail := "unsupported agent run finalization mode " + string(run.Mode)
		if err := s.store.FailAgentRunFinalization(ctx, run.ID, detail); err != nil {
			return err
		}
		return s.store.FinishAgentRun(ctx, run.ID)
	}
}

func (s *Service) retryAgentRunFinalization(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) error {
	attempt := run.Failures + 1
	if attempt >= s.cfg.Limits.MaxAgentRunAttempts {
		if err := s.stageTerminalFinalizationFailure(ctx, run, cause); err == nil {
			if err := s.store.FailAgentRunFinalization(
				ctx,
				run.ID,
				"finalization failed after the configured retry limit: "+trimError(cause),
			); err != nil {
				cause = err
			} else {
				return s.store.FinishAgentRun(ctx, run.ID)
			}
		} else {
			cause = fmt.Errorf(
				"stage terminal finalization failure: %w; original failure: %v",
				err,
				cause,
			)
		}
	}
	if err := s.store.RetryAgentRunFinalization(
		ctx,
		run.ID,
		trimError(cause),
		queueDelay(attempt),
	); err != nil {
		return err
	}
	s.log.Warn(
		"agent run finalization deferred",
		"run", run.ID,
		"attempt", attempt,
		"error", cause,
	)
	return nil
}

func (s *Service) stageTerminalFinalizationFailure(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) error {
	detail := "Responder could not finalize this agent result after repeated attempts. " +
		"The run and collected state are preserved for operator inspection.\n\n" +
		"Reported detail: `" + boundedField(trimError(cause), 1200) + "`"
	switch run.Mode {
	case core.AgentRunTriage:
		input, err := s.store.GetSlackInput(ctx, run.SourceID)
		if err != nil {
			input = core.SlackInput{
				ChannelID: run.ChannelID,
				ThreadTS:  run.ThreadTS,
				MessageTS: run.ThreadTS,
			}
		}
		if input.ChannelID == "" || slackReplyThread(input) == "" {
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "agent.finalization", ObjectID: run.ID,
				Outcome: "failed",
				Detail:  "terminal triage run has no Slack destination",
			})
			return nil
		}
		if err := s.postInputNotice(
			ctx,
			"watch_finalization_failure_"+run.ID,
			input,
			watchFailureNotice(detail),
		); err != nil {
			return err
		}
		if !s.cfg.Slack.NativeStatus {
			return nil
		}
		return s.enqueueNativeStatus(
			ctx,
			"",
			input.ChannelID,
			slackReplyThread(input),
			"",
			nil,
		)
	case core.AgentRunIncident, core.AgentRunEngineeringTask:
		incident, err := s.store.GetIncident(ctx, run.IncidentID)
		if err != nil {
			return err
		}
		if err := s.enqueue(
			ctx,
			"out_run_finalization_failure_"+run.ID,
			incident,
			"assistant",
			incident.ConversationThreadTS(),
			slackui.TurnFailureMessage("failed", detail),
		); err != nil {
			return err
		}
		return s.requireNativeStatusClear(ctx, incident, run.ID)
	default:
		return nil
	}
}

func (s *Service) finalizeTriageAgentRun(ctx context.Context, run core.AgentRun) error {
	input, err := s.store.GetSlackInput(ctx, run.SourceID)
	if err != nil {
		return err
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		return err
	}
	state.SessionID = run.SessionID
	state.Repository = run.Repository
	state.Generation = run.SessionGeneration
	state.TurnID = run.CoopTurnID
	if run.TerminalState != "completed" {
		detail := strings.TrimSpace(firstNonempty(run.LastError, run.TerminalState))
		if err := s.finishTriageRunFailure(ctx, run, input, state, detail); err != nil {
			return err
		}
		return s.store.FinishAgentRun(ctx, run.ID)
	}
	decision, err := parseWatchDecision(string(run.Result))
	if err != nil {
		detail := "malformed watch decision: " + trimError(err)
		if failErr := s.finishTriageRunFailure(
			ctx, run, input, state, detail,
		); failErr != nil {
			return failErr
		}
		if err := s.store.FailAgentRunFinalization(ctx, run.ID, detail); err != nil {
			return err
		}
		return s.store.FinishAgentRun(ctx, run.ID)
	}
	if len(state.MatchedRules) > 0 && decision.Action != "reply" {
		detail := "standing rule result must be a read-only threaded reply"
		if failErr := s.finishTriageRunFailure(
			ctx, run, input, state, detail,
		); failErr != nil {
			return failErr
		}
		if err := s.store.FailAgentRunFinalization(ctx, run.ID, detail); err != nil {
			return err
		}
		return s.store.FinishAgentRun(ctx, run.ID)
	}
	if err := s.applyWatchDecision(ctx, input, state, decision); err != nil {
		return err
	}
	return s.store.FinishAgentRun(ctx, run.ID)
}

func (s *Service) finalizeIncidentAgentRun(
	ctx context.Context,
	run core.AgentRun,
) error {
	incident, err := s.store.GetIncident(ctx, run.IncidentID)
	if err != nil {
		return err
	}
	state := run.TerminalState
	detail := strings.TrimSpace(firstNonempty(run.LastError, state))
	if s.sanitizer != nil {
		detail = s.sanitizer.Text(detail)
	}
	threadTS := incident.ConversationThreadTS()
	conversation := run.SourceKind == "slack"
	var conversationInput core.SlackInput
	if conversation {
		conversationInput, err = s.store.GetSlackInput(ctx, run.SourceID)
		if err != nil {
			return err
		}
		threadTS = conversationalResponseThread(conversationInput)
	}
	var message slackui.Message
	if state == "completed" {
		report, structured, reportErr := parseAgentReport(string(run.Result))
		if reportErr != nil {
			s.log.Warn(
				"agent returned malformed structured response",
				"incident", incident.ID,
				"run", run.ID,
				"turn", run.CoopTurnID,
				"error", reportErr,
			)
			_ = s.store.Audit(ctx, core.AuditEvent{
				IncidentID: incident.ID, Kind: "agent.report",
				ObjectID: run.CoopTurnID, Outcome: "malformed",
				Detail: trimError(reportErr),
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
					IncidentID: incident.ID, Kind: "agent.report",
					ObjectID: run.CoopTurnID, Outcome: "legacy",
					Detail: "response had no structured evidence envelope",
				})
			}
			report, err = s.persistAgentReport(
				ctx,
				report,
				incident,
				incident.ChannelID,
				run.ID,
				run.UserID,
			)
			if err != nil {
				return err
			}
			if conversation && suppressConversationReply(report.Message) {
				if err := s.requireNativeStatusClear(ctx, incident, run.ID); err != nil {
					return err
				}
				return s.store.FinishAgentRun(ctx, run.ID)
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
			for _, evidence := range report.Evidence {
				evidenceIDs = append(evidenceIDs, evidence.ID)
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
		if changes, changesErr := s.coop.Changes(
			ctx, incident.CoopSessionID,
		); changesErr == nil {
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
	if run.SourceKind == "proposal" {
		proposalState := "failed"
		if state == "completed" {
			proposalState = "finished"
		}
		proposalResult := firstNonempty(string(run.Result), detail)
		if s.sanitizer != nil {
			proposalResult = s.sanitizer.Text(proposalResult)
		}
		_ = s.store.MarkProposalExecution(
			ctx,
			run.SourceID,
			proposalState,
			run.CoopTurnID,
			proposalResult,
		)
	}
	if err := s.enqueue(
		ctx,
		"out_run_"+run.ID,
		incident,
		"assistant",
		threadTS,
		message,
	); err != nil {
		return err
	}
	if err := s.requireNativeStatusClear(ctx, incident, run.ID); err != nil {
		return err
	}
	if err := s.store.FinishAgentRun(ctx, run.ID); err != nil {
		return err
	}
	s.forgetNativeStatus(incident.ID)
	return nil
}

func (s *Service) finishTriageRunFailure(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state watchTurnState,
	detail string,
) error {
	message := slackui.Notice(watchFailureNotice(detail))
	post := s.postInputMessage
	if input.Kind == "bot_message" || input.Kind == "shortcut" ||
		len(state.MatchedRules) > 0 {
		post = s.postInputMessageInSourceThread
	}
	if err := post(ctx, "watch_failure_"+input.ID, input, message); err != nil {
		return err
	}
	if err := s.clearWatchPendingStatus(ctx, input, state); err != nil {
		return err
	}
	if err := s.retireFailedWatchSession(ctx, input, state); err != nil && s.log != nil {
		s.log.Warn("retire failed triage session", "run", run.ID, "error", err)
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
		Outcome: "failed", Detail: detail,
	})
	return nil
}
