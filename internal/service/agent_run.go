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
	if input.Kind == "message" && !state.ConversationFollowup {
		followup, err := s.isRecentWatchConversation(ctx, input)
		if err != nil {
			return err
		}
		state.ConversationFollowup = followup
	}
	if !state.RouteCaptured {
		responseThreadTS, referencedThreadTS, err := s.resolveConversationRoute(
			ctx, input,
		)
		if err != nil {
			return err
		}
		state.ResponseThreadTS = responseThreadTS
		state.ReferencedThreadTS = referencedThreadTS
		state.RouteCaptured = true
	}
	if watchInputWantsPendingStatus(input, state) && s.cfg.Slack.NativeStatus {
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
		ThreadTS:        state.ResponseThreadTS,
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
		if len(input.Attachments) > 0 {
			if len(input.Attachments) == 1 {
				return "Inspect an attached file"
			}
			return fmt.Sprintf("Inspect %d attached files", len(input.Attachments))
		}
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
	return watchInputExplicitlyTargeted(input, state) || state.ConversationFollowup
}

func watchInputWantsPendingStatus(
	input core.SlackInput,
	state watchTurnState,
) bool {
	return watchInputTargeted(input, state) ||
		requestedConversationLocation(input.Text) != conversationLocationFollow
}

func watchInputExplicitlyTargeted(input core.SlackInput, state watchTurnState) bool {
	return input.Kind == "direct" || input.Kind == "mention" ||
		input.Kind == "shortcut" || len(state.MatchedRules) > 0 ||
		requestedConversationLocation(input.Text) != conversationLocationFollow
}

func watchConversationKey(input core.SlackInput) string {
	return "channel:" + input.ChannelID
}

func watchProgressSteps() []string {
	return []string{
		"Reading the conversation",
		"Checking the repository setup",
		"Checking live systems",
		"Comparing expected and current state",
		"Writing the answer",
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
	if relatedPrompt := relatedSituationsPrompt(assembled.RelatedSituations); relatedPrompt != "" {
		prompt += "\n\n" + relatedPrompt
	}
	if repositoryPrompt := repositorySetPrompt(session); repositoryPrompt != "" {
		prompt += "\n\n" + repositoryPrompt
	}
	revision, err := s.store.FreezeAgentRunRevision(ctx, run.ID, session.Revision)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, true)
	}
	artifacts, err := s.agentRunArtifacts(ctx, run)
	if err != nil {
		return s.retryIncidentAgentRun(
			ctx, run, incident, err, permanentSlackAttachmentError(err),
		)
	}
	turn, _, err := s.coop.SubmitTurnWithArtifacts(
		ctx,
		run.IdempotencyKey,
		incident.CoopSessionID,
		revision,
		prompt+"\n\n"+s.structuredResponsePolicy(),
		artifacts,
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
		s.agentRunNativeStatus(ctx, run),
	)
	return nil
}

func (s *Service) agentRunNativeStatus(ctx context.Context, run core.AgentRun) string {
	if run.SourceKind == "slack" {
		if input, err := s.store.GetSlackInput(ctx, run.SourceID); err == nil &&
			simpleExplanationRequest(input.Text) {
			return "is explaining the earlier answer..."
		}
	}
	return "is investigating..."
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

func agentMemoryPresent(memory core.AgentMemory) bool {
	return memory.Goal != "" ||
		memory.ChannelPurpose != "" ||
		memory.SituationSummary != "" ||
		len(memory.ActiveTopics) != 0 ||
		len(memory.OpenLoops) != 0 ||
		len(memory.Topology) != 0 ||
		len(memory.Decisions) != 0 ||
		len(memory.UnresolvedQuestions) != 0 ||
		len(memory.EvidenceRefs) != 0
}

func relatedSituationsPrompt(situations []conversationSituationContext) string {
	if len(situations) == 0 {
		return ""
	}
	data, err := json.Marshal(situations)
	if err != nil {
		return ""
	}
	return `Recent compact situations from related Slack conversations follow. They are continuity
context, not current operational proof. Revalidate consequential claims, use only relevant entries,
and do not reveal a source channel or thread unless the requesting user already supplied it.
<related-workspace-situations>
` + string(data) + `
</related-workspace-situations>`
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
	if input.Kind == "message" && len(state.MatchedRules) == 0 {
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
				TargetInput:        &input,
				ReferencedThreadTS: state.ReferencedThreadTS,
				IncludeRecent:      true,
			},
		)
		if err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
		state.RecentMessages = assembled.RecentMessages
		state.Memory = assembled.Situation
		state.RelatedSituations = assembled.RelatedSituations
		state.ReferencedThread = assembled.ReferencedThread
		state.Prior = assembled.Prior
		state.Repository = assembled.Repository
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
	repository, ok := s.cfg.RepositoryContext(
		firstNonempty(state.Repository, s.cfg.Slack.DefaultRepository),
	)
	if !ok {
		return s.retryAgentRun(
			ctx,
			run,
			fmt.Errorf("repository context %q is not configured", state.Repository),
		)
	}
	if state.Lane == "" {
		state.Lane = "investigation"
		if repository.ConversationPolicy != "" &&
			len(input.Attachments) == 0 &&
			len(state.MatchedRules) == 0 &&
			(input.Kind == "message" || input.Kind == "mention" ||
				input.Kind == "direct") &&
			watchInputTargeted(input, state) {
			state.Lane = "conversation"
		}
	}
	var (
		session       coop.Session
		repositoryKey string
		generation    int
		eventSequence int64
	)
	if state.Lane == "conversation" {
		if err := s.store.EnsureChannelMemory(
			ctx,
			input.ChannelID,
			state.Repository,
		); err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
		conversation, conversationSession, conversationErr :=
			s.ensureConversationSessionAtGeneration(
				ctx,
				input.ChannelID,
				state.Repository,
				repository.ConversationPolicy,
				max(state.Generation, 1),
			)
		if conversationErr != nil {
			if advanceFailedSessionGeneration(conversationErr) &&
				conversation.Generation > 0 {
				state.Generation = conversation.Generation + 1
				if err := s.persistTriageRunState(ctx, run.ID, state); err != nil {
					return s.retryAgentRun(ctx, run, err)
				}
			}
			return s.retryAgentRun(ctx, run, conversationErr)
		}
		session = conversationSession
		repositoryKey = conversation.Repository
		generation = conversation.Generation
		eventSequence = conversation.CoopEventSequence
	} else {
		memory, investigationSession, investigationErr :=
			s.ensureWatchSessionAtGeneration(
				ctx, input.ChannelID, max(state.Generation, 1),
			)
		if investigationErr != nil {
			if advanceFailedSessionGeneration(investigationErr) &&
				memory.Generation > 0 {
				state.Generation = memory.Generation + 1
				if err := s.persistTriageRunState(ctx, run.ID, state); err != nil {
					return s.retryAgentRun(ctx, run, err)
				}
			}
			return s.retryAgentRun(ctx, run, investigationErr)
		}
		session = investigationSession
		repositoryKey = memory.Repository
		generation = memory.Generation
		eventSequence = memory.CoopEventSequence
		if !agentMemoryPresent(state.Memory) {
			state.Memory = memory.State
		}
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
	state.Repository = repositoryKey
	state.Generation = generation
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	if err := s.store.BindAgentRunSession(
		ctx,
		run.ID,
		session.ID,
		generation,
		repositoryKey,
		eventSequence,
		contextJSON,
	); err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	run.SessionID = session.ID
	run.SessionGeneration = generation
	run.Repository = repositoryKey
	run.Context = contextJSON
	run.CoopEventSequence = eventSequence
	revision, err := s.store.FreezeAgentRunRevision(ctx, run.ID, session.Revision)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	artifacts, err := s.agentRunArtifacts(ctx, run)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	prompt := s.watchPrompt(
		input,
		s.identity.BotUserID,
		state.ConversationFollowup,
		state.RecentMessages,
		state.Memory,
		state.RelatedSituations,
		state.ReferencedThread,
		state.Prior,
		firstNonempty(repositoryKey, s.cfg.Slack.DefaultRepository),
		state.MatchedRules,
	) + "\n\n" + repositorySetPrompt(session) +
		watchDecisionCorrectionPrompt(state.FailureDetail)
	if state.Lane == "conversation" {
		prompt = s.conversationPrompt(
			input,
			s.identity.BotUserID,
			state.ConversationFollowup,
			state.RecentMessages,
			state.Memory,
			state.ReferencedThread,
			repositoryKey,
		)
	} else if state.EscalationReason != "" {
		prompt += "\n\n<host-escalation>\nThe bounded conversation lane escalated this " +
			"request because: " + boundedOperatorText(state.EscalationReason) +
			". Perform the full evidence-backed work now.\n</host-escalation>"
	}
	turn, _, err := s.coop.SubmitTurnWithArtifacts(
		ctx,
		run.IdempotencyKey,
		session.ID,
		revision,
		prompt,
		artifacts,
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
	return s.store.MarkTriageAgentRunSubmitted(
		ctx,
		run.ID,
		turn.ID,
		session.Revision,
		run.CoopEventSequence,
		state.Lane,
	)
}

func (s *Service) persistTriageRunState(
	ctx context.Context,
	runID string,
	state watchTurnState,
) error {
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return s.store.SetAgentRunContext(ctx, runID, contextJSON)
}

func advanceFailedSessionGeneration(err error) bool {
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) &&
		apiErr.Status >= 500 &&
		apiErr.Code == "internal_error"
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
	if permanentSlackAttachmentError(cause) {
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
	var session coop.Session
	if len(events) == 0 {
		session, err = s.coop.GetSession(ctx, run.SessionID)
		if err != nil {
			return err
		}
		if cursor > session.LastEventSequence {
			conversationLane := false
			if run.Mode == core.AgentRunTriage {
				state, stateErr := decodeWatchRunContext(run)
				conversationLane = stateErr == nil && state.Lane == "conversation"
			}
			if err := s.store.RepairAgentRunEventCursor(
				ctx, run.ID, run.SessionID, conversationLane,
			); err != nil {
				return err
			}
			run.CoopEventSequence = 0
			cursor = 0
			events, err = s.coop.Events(ctx, run.SessionID, 0, 100)
			if err != nil {
				return err
			}
		}
	}
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
			return s.stagePolledAgentRunTerminal(ctx, run, event.Type, turn, cursor)
		}
	}
	if len(events) == 0 && session.ID != "" &&
		session.ActiveTurnID != run.CoopTurnID {
		turn, turnErr := s.coop.GetTurn(ctx, run.SessionID, run.CoopTurnID)
		if turnErr != nil {
			return turnErr
		}
		if turn.State == "completed" || turn.State == "failed" ||
			turn.State == "cancelled" {
			return s.stagePolledAgentRunTerminal(
				ctx, run, "turn."+turn.State, turn,
				max(cursor, session.LastEventSequence),
			)
		}
	}
	if cursor > run.CoopEventSequence {
		if err := s.store.AdvanceAgentRunEvents(ctx, run.ID, cursor); err != nil {
			return err
		}
		if run.Mode == core.AgentRunTriage {
			if err := s.advanceTriageSessionEvents(ctx, run, cursor); err != nil {
				return err
			}
		}
	}
	if run.Mode == core.AgentRunTriage {
		input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
		state, stateErr := decodeWatchRunContext(run)
		if inputErr == nil && stateErr == nil &&
			watchInputWantsPendingStatus(input, state) {
			if err := s.ensureWatchRunPendingStatus(ctx, run, input, &state); err != nil {
				s.log.Warn("refresh watched run status", "run", run.ID, "error", err)
			}
		}
	}
	return nil
}

func (s *Service) stagePolledAgentRunTerminal(
	ctx context.Context,
	run core.AgentRun,
	eventType string,
	turn coop.Turn,
	cursor int64,
) error {
	detail := strings.TrimSpace(
		firstNonempty(turn.ErrorDetail, turn.ErrorCode, turn.StopReason),
	)
	if reason, replay := replayAgentRunFailure(
		run, eventType, turn, s.cfg.Limits.MaxAgentRunAttempts,
	); replay {
		if err := s.store.RequeueAgentRun(
			ctx, run.ID, reason, cursor, time.Now(),
		); err != nil {
			return err
		}
		if run.Mode == core.AgentRunTriage {
			_ = s.advanceTriageSessionEvents(ctx, run, cursor)
		}
		return nil
	}
	terminalState := strings.TrimPrefix(eventType, "turn.")
	result := []byte(turn.AssistantMessage)
	if run.Mode == core.AgentRunTriage && terminalState == "completed" {
		input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
		state, stateErr := decodeWatchRunContext(run)
		decision, decisionErr := parseWatchDecision(turn.AssistantMessage)
		if inputErr == nil && stateErr == nil && decisionErr == nil {
			if state.Lane == "conversation" && decision.Action == "escalate" {
				if err := s.store.AdvanceConversationSessionEvents(
					ctx, run.ChannelID, run.SessionID, cursor,
				); err != nil {
					return err
				}
				state.Lane = "investigation"
				state.EscalationReason = decision.Reason
				state.SessionID = ""
				state.Generation = 0
				state.ExpectedRevision = 0
				state.TurnID = ""
				state.FailureDetail = ""
				contextJSON, marshalErr := json.Marshal(state)
				if marshalErr != nil {
					return marshalErr
				}
				return s.store.EscalateAgentRun(
					ctx,
					run.ID,
					"continuing in the full investigation lane: "+decision.Reason,
					contextJSON,
					time.Now(),
				)
			}
			if correction := watchDecisionCorrection(input, state, decision); correction != "" {
				if !terminalAttempt(
					run.Failures+1, s.cfg.Limits.MaxAgentRunAttempts,
				) {
					state.FailureDetail = correction
					contextJSON, marshalErr := json.Marshal(state)
					if marshalErr != nil {
						return marshalErr
					}
					if err := s.store.SetAgentRunContext(
						ctx, run.ID, contextJSON,
					); err != nil {
						return err
					}
					if err := s.store.RequeueAgentRun(
						ctx, run.ID, correction, cursor, time.Now(),
					); err != nil {
						return err
					}
					_ = s.advanceTriageSessionEvents(ctx, run, cursor)
					return nil
				}
				terminalState = "failed"
				result = nil
				detail = correction
			}
		}
	}
	if err := s.store.StageAgentRunResult(
		ctx, run.ID, terminalState, result, detail, cursor,
	); err != nil {
		return err
	}
	if run.Mode == core.AgentRunTriage {
		_ = s.advanceTriageSessionEvents(ctx, run, cursor)
	}
	return nil
}

func (s *Service) advanceTriageSessionEvents(
	ctx context.Context,
	run core.AgentRun,
	cursor int64,
) error {
	state, err := decodeWatchRunContext(run)
	if err == nil && state.Lane == "conversation" {
		return s.store.AdvanceConversationSessionEvents(
			ctx, run.ChannelID, run.SessionID, cursor,
		)
	}
	return s.store.AdvanceChannelEvents(
		ctx, run.ChannelID, run.SessionID, cursor,
	)
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
	if run.Failures < 2 &&
		strings.Contains(strings.ToLower(detail), "turn cleanup failed") {
		return "Coop could not clean up the agent turn; retrying in a fresh turn", true
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
	if len(state.MatchedRules) > 0 &&
		decision.Action != "ignore" && decision.Action != "react" && decision.Action != "reply" {
		decision = suppressWatchDecision(
			decision,
			"host standing-rule policy suppressed an outcome outside ignore, react, or reply",
		)
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
	var visuals []core.GeneratedVisual
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
			if conversation && s.cfg.IsOperator(conversationInput.UserID) {
				if offer, acknowledgement, ok := normalizeResponseLocationPreference(
					conversationInput, report.PreferenceOffer,
				); ok {
					report.Message = acknowledgement
					report.MemoryOffer = nil
					report.PreferenceOffer = offer
					report.RuleOffer = nil
					report.Evidence = nil
					report.Coverage = nil
				}
			}
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
			visuals = report.Visuals
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
	if err := s.enqueueGeneratedVisuals(
		ctx, "out_run_"+run.ID, incident.ID, incident.ChannelID, threadTS,
		run.SessionID, run.CoopTurnID, visuals,
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
