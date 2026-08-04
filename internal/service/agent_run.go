package service

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
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
	episode := s.episodeForIncident(incident, mode, sourceKind, incident.Title)
	if sourceKind == "slack" {
		input, err := s.store.GetSlackInput(ctx, sourceID)
		if err != nil {
			return core.AgentRun{}, false, err
		}
		if mode == core.AgentRunIncident {
			episode = s.episodeForWatchedInput(
				input,
				watchTurnState{ConversationFollowup: true},
			)
		} else if activity := requestEpisodeActivity(input.Text); activity != core.ActivityInvestigating {
			episode.Activity = activity
		}
	}
	return s.store.QueueAgentRun(ctx, core.AgentRun{
		Mode: mode, IncidentID: incident.ID, ChannelID: incident.ChannelID,
		ThreadTS:        incident.ConversationThreadTS(),
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      sourceKind, SourceID: sourceID, UserID: userID,
		Repository: incident.Repository, Prompt: prompt,
		SessionID:       incident.CoopSessionID,
		CommitmentTitle: incident.Title,
		Episode:         episode,
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
				Episode:         s.episodeForWatchedInput(input, legacy),
			})
			if queueErr != nil {
				return queueErr
			}
			return s.finishInputIfOpen(ctx, input)
		}
		state = legacy
	}
	if input.Kind == "bot_message" && state.AlertPolicy == "" {
		alertPolicy, err := s.channelAlertPolicy(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		state.AlertPolicy = alertPolicy
	}
	if !state.RulesCaptured {
		rules, err := s.matchingStandingRules(ctx, input)
		if err != nil {
			return err
		}
		state.MatchedRules = rules
		state.RulesCaptured = true
	}
	if !state.PublicationsCaptured {
		if input.Kind == "bot_message" {
			publications, err := s.store.ListActivePublicationContexts(
				ctx,
				time.Now().UTC().Add(-s.cfg.GitHub.DeliveryCorrelationWindow.Duration),
				20,
			)
			if err != nil {
				return err
			}
			state.ActivePublications = publications
		}
		state.PublicationsCaptured = true
	}
	if !state.RuleAcknowledged && len(state.MatchedRules) > 0 {
		s.acknowledgeMatchedAlertRule(ctx, input, state.MatchedRules)
		state.RuleAcknowledged = true
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
	readyAt := time.Now().UTC()
	if input.Kind != "scheduled" {
		latestAt, err := s.store.LatestSlackConversationAt(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		readyAt = latestAt.Add(s.cfg.Slack.WatchSettleDelay.Duration)
	}
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
		Episode:         s.episodeForWatchedInput(input, state),
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
	return input.Kind != "recheck" && slackReplyThread(input) != "" &&
		(watchInputTargeted(input, state) ||
			requestedConversationLocation(input.Text) != conversationLocationFollow)
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
	contextChanged := false
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
		contextChanged = true
		run.Repository = assembled.Repository
	}
	if incident.IsEngineeringTask() && assembled.InitialTaskChangesFingerprint == "" {
		changes, changesErr := s.coop.Changes(ctx, incident.CoopSessionID)
		if changesErr != nil {
			assembled.InitialTaskChangesFingerprint = "unavailable"
			s.log.Warn(
				"capture engineering task changes before turn failed",
				"incident", incident.ID,
				"run", run.ID,
				"error", changesErr,
			)
		} else {
			assembled.InitialTaskChangesFingerprint = coopChangesFingerprint(changes)
		}
		contextChanged = true
	}
	if contextChanged {
		contextJSON, marshalErr := json.Marshal(assembled)
		if marshalErr != nil {
			return s.retryIncidentAgentRun(
				ctx, run, incident, marshalErr, false,
			)
		}
		run.Context = contextJSON
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
	episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
	if episodeErr != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, episodeErr, false)
	}
	prompt += "\n\n" + workEpisodePrompt(episode)
	prompt += agentToolTransportPrompt()
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
		prompt+"\n\n"+s.structuredResponsePolicy()+agentRunContinuationPrompt(run),
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
	if value, err := s.store.GetWorkEpisodeByRun(ctx, run.ID); err == nil {
		if status := episodepkg.Project(value).NativeStatus; status != "" {
			return status
		}
	}
	if run.SourceKind == "slack" {
		if input, err := s.store.GetSlackInput(ctx, run.SourceID); err == nil {
			return requestNativeStatus(input.Text)
		}
	}
	return "is investigating..."
}

func requestNativeStatus(text string) string {
	switch requestEpisodeActivity(text) {
	case core.ActivityExplaining:
		return "is explaining the earlier answer..."
	case core.ActivityScheduling:
		return "is scheduling the follow-up..."
	default:
		return "is investigating..."
	}
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
	if input.Kind == "bot_message" && state.AlertPolicy == "" {
		state.AlertPolicy, err = s.channelAlertPolicy(ctx, input.ChannelID)
		if err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
	}
	if input.Kind == "message" && len(state.MatchedRules) == 0 &&
		!state.ApprovalContinuation {
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
				RepositoryPinned: state.RepositoryPinned,
				OperatorID:       input.UserID, SourceInputID: input.ID,
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
		if !isSlackVerificationReplay(input) &&
			repository.ConversationPolicy != "" &&
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
		sessionChannelID := firstNonempty(state.SessionChannelID, input.ChannelID)
		pinnedRepository := ""
		if state.RepositoryPinned {
			pinnedRepository = state.Repository
		}
		memory, investigationSession, investigationErr :=
			s.ensureWatchSessionForRepositoryAtGeneration(
				ctx,
				sessionChannelID,
				pinnedRepository,
				max(state.Generation, 1),
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
	) + "\n\n" + repositorySetPrompt(session)
	prompt += appAlertPolicyPrompt(input.Kind, state.AlertPolicy)
	if state.ApprovalContinuation && strings.TrimSpace(run.Prompt) != "" {
		prompt += "\n\n<emisar-run-continuation>\n" + run.Prompt +
			"\n</emisar-run-continuation>"
	}
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
	prompt += activePublicationPrompt(state.ActivePublications)
	prompt += watchDecisionCorrectionPrompt(state.FailureDetail)
	episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
	if episodeErr != nil {
		return s.retryAgentRun(ctx, run, episodeErr)
	}
	prompt += "\n\n" + workEpisodePrompt(episode)
	prompt += agentToolTransportPrompt()
	prompt += agentRunContinuationPrompt(run)
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
	publish := publishTriageFailure(input, state)
	if publish {
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
		Outcome: triageFailureOutcome(publish), Detail: detail,
	})
	return s.store.RetryAgentRun(ctx, run.ID, detail, time.Now(), true)
}

func (s *Service) pollAgentRuns(ctx context.Context) {
	runs, err := s.store.ListRunningAgentRuns(ctx, 200)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
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
	if err := s.refreshWorkEpisodeProgress(ctx, run); err != nil {
		s.log.Warn("refresh work episode progress", "run", run.ID, "error", err)
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
		if run.Mode == core.AgentRunTriage &&
			replayAgentRunInFreshSession(turn) {
			state, err := decodeWatchRunContext(run)
			if err != nil {
				return err
			}
			state.SessionID = ""
			state.Generation = max(
				state.Generation,
				run.SessionGeneration,
			) + 1
			state.ExpectedRevision = 0
			state.TurnID = ""
			contextJSON, err := json.Marshal(state)
			if err != nil {
				return err
			}
			if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
				return err
			}
		}
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
		if inputErr != nil {
			return inputErr
		}
		if stateErr != nil {
			return stateErr
		}
		if decisionErr != nil {
			correction := "the structured Slack response is invalid: " + trimError(decisionErr)
			if !consumeWatchStructuredCorrection(
				&state, s.cfg.Limits.MaxAgentRunAttempts,
			) {
				state.FailureDetail = correction
				contextJSON, marshalErr := json.Marshal(state)
				if marshalErr != nil {
					return marshalErr
				}
				if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
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
		} else {
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
			correction := watchDecisionCorrection(input, state, decision)
			if correction == "" {
				episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
				if episodeErr != nil {
					return episodeErr
				}
				correction = episodeCompletionCorrection(
					episode,
					decision.Action,
					sanitizeCoverage(decision.Coverage, "", "", ""),
					decision.Completion,
				)
				if correction == "" {
					correction = episodeConclusionLanguageCorrection(
						episode, decision.Action, decision.Message,
					)
				}
				if correction == "" {
					correction = episodeClaimCorrection(
						episode,
						decision.Action,
						sanitizeEvidence(decision.Evidence, "", "", ""),
						sanitizeCoverage(decision.Coverage, "", "", ""),
						decision.Completion,
						time.Now(),
						len(decision.AppliedOperations) > 0,
					)
				}
				if correction == "" {
					correction = episodeDiagnosisCorrection(
						episode,
						decision.Action,
						sanitizeCoverage(decision.Coverage, "", "", ""),
						decision.AlertAssessment,
						decision.Completion,
					)
				}
			}
			if correction != "" {
				if !consumeWatchStructuredCorrection(
					&state, s.cfg.Limits.MaxAgentRunAttempts,
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
			} else if err := s.recordResultOperationEvents(
				ctx, run.ID, decision.AppliedOperations,
			); err != nil {
				return err
			}
		}
	}
	if (run.Mode == core.AgentRunIncident || run.Mode == core.AgentRunEngineeringTask) &&
		terminalState == "completed" {
		report, _, reportErr := parseAgentReport(turn.AssistantMessage)
		if reportErr != nil {
			correction := "the structured agent report is invalid: " + trimError(reportErr)
			if !terminalStructuredCorrection(
				run.Failures+1, s.cfg.Limits.MaxAgentRunAttempts,
			) {
				if err := s.store.RequeueAgentRun(
					ctx, run.ID, correction, cursor, time.Now(),
				); err != nil {
					return err
				}
				return nil
			}
			terminalState = "failed"
			result = nil
			detail = correction
		} else {
			episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
			if episodeErr != nil {
				return episodeErr
			}
			correction := episodeCompletionCorrection(
				episode,
				"reply",
				sanitizeCoverage(report.Coverage, "", "", ""),
				report.Completion,
			)
			if correction == "" {
				correction = episodeConclusionLanguageCorrection(
					episode, "reply", report.Message,
				)
			}
			if correction == "" {
				correction = episodeClaimCorrection(
					episode,
					"reply",
					sanitizeEvidence(report.Evidence, "", "", ""),
					sanitizeCoverage(report.Coverage, "", "", ""),
					report.Completion,
					time.Now(),
					len(report.AppliedOperations) > 0,
				)
			}
			if correction != "" {
				if !terminalStructuredCorrection(
					run.Failures+1, s.cfg.Limits.MaxAgentRunAttempts,
				) {
					if err := s.store.RequeueAgentRun(
						ctx, run.ID, correction, cursor, time.Now(),
					); err != nil {
						return err
					}
					return nil
				}
				terminalState = "failed"
				result = nil
				detail = correction
			} else if err := s.recordResultOperationEvents(
				ctx, run.ID, report.AppliedOperations,
			); err != nil {
				return err
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

func terminalStructuredCorrection(attempt, maximum int) bool {
	const maximumStructuredCorrections = 3

	return terminalAttempt(attempt, min(maximum, maximumStructuredCorrections))
}

func consumeWatchStructuredCorrection(state *watchTurnState, maximum int) bool {
	state.StructuredCorrections++
	return terminalStructuredCorrection(state.StructuredCorrections, maximum)
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
	sessionChannelID := run.ChannelID
	if err == nil {
		sessionChannelID = firstNonempty(state.SessionChannelID, run.ChannelID)
	}
	return s.store.AdvanceChannelEvents(
		ctx, sessionChannelID, run.SessionID, cursor,
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
	if run.Mode == core.AgentRunTriage && transcriptOverflow(turn) {
		return "Coop ACP transcript exceeded its bound; retrying in a fresh read-only session with narrower evidence queries", true
	}
	if run.Failures < 2 &&
		strings.Contains(strings.ToLower(detail), "turn cleanup failed") {
		return "Coop could not clean up the agent turn; retrying in a fresh turn", true
	}
	if terminalACPEnvironmentFailure(turn) {
		return "", false
	}
	if run.Mode == core.AgentRunTriage &&
		turn.ErrorCode == "acp_process_error" &&
		strings.Contains(
			strings.ToLower(detail),
			"acp child closed before its response",
		) && run.Failures < maximumAttempts-1 {
		return "Coop ACP child closed unexpectedly; retrying in a fresh read-only session", true
	}
	return "", false
}

func replayAgentRunInFreshSession(turn coop.Turn) bool {
	if terminalACPEnvironmentFailure(turn) {
		return false
	}
	detail := strings.ToLower(strings.TrimSpace(turn.ErrorDetail))
	return (turn.ErrorCode == "acp_cancelled" && detail == "turn cancelled") ||
		(turn.ErrorCode == "acp_process_error" &&
			strings.Contains(detail, "acp child closed before its response")) ||
		transcriptOverflow(turn)
}

func terminalACPEnvironmentFailure(turn coop.Turn) bool {
	if turn.ErrorCode != "acp_process_error" {
		return false
	}
	detail := strings.ToLower(strings.TrimSpace(turn.ErrorDetail))
	for _, diagnostic := range []string{
		"coop box image is not built",
		"coop runtime storage is full",
		"coop cannot reach the docker runtime",
		"configured coop account is not authenticated",
	} {
		if strings.Contains(detail, diagnostic) {
			return true
		}
	}
	return false
}

func transcriptOverflow(turn coop.Turn) bool {
	return turn.ErrorCode == "acp_protocol_error" && strings.Contains(
		strings.ToLower(strings.TrimSpace(turn.ErrorDetail)),
		"acp transcript exceeded its bound",
	)
}

func agentToolTransportPrompt() string {
	return `

<host-tool-transport>
Keep tool output bounded without reducing investigation quality. Prefer precise filters, narrow time
windows, server-side aggregation, counts or top-N results, and pagination when the tool supports it.
Do not request complete logs, histories, inventories, or source trees when narrower queries can answer
the claim. If a result is truncated or unexpectedly large, refine the next query instead of repeating
the broad call. Maintain a concise working summary of verified facts as you go. Transport limits are
not a reason to stop: continue until the work episode is decision-ready or has an exact external
blocker.
</host-tool-transport>`
}

func agentRunContinuationPrompt(run core.AgentRun) string {
	lower := strings.ToLower(run.LastError)
	if strings.Contains(lower, "acp transcript") {
		return `

<host-transport-recovery>
The previous read-only session exceeded Coop's ACP transcript bound and returned no usable final
answer. This is a fresh authenticated session with the original Slack request and saved Responder
context. Restart the required checks from current authoritative evidence. Avoid the prior failure by
using tightly filtered queries, short time windows, aggregation, top-N results, and pagination rather
than broad raw output. Do not assume that observations from the failed session are valid. Complete the
full effort contract and return the exact structured response requested by the host.
</host-transport-recovery>`
	}
	if strings.Contains(lower, "acp child closed") ||
		strings.Contains(lower, "turn was interrupted") {
		return `

<host-transport-recovery>
The previous read-only agent process ended before returning an answer. This is a fresh authenticated
session with the original Slack request and saved context. Perform the requested work from current
authoritative evidence; do not assume that unreported observations from the interrupted process are
valid. Long task duration is not a reason to stop. Return the exact structured response requested by
the host when the task is complete.
</host-transport-recovery>`
	}
	return ""
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
	threadTS := watchRunStatusThread(input, *state)
	if threadTS == "" {
		return nil
	}
	if err := s.enqueueNativeStatus(
		ctx,
		"",
		input.ChannelID,
		threadTS,
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

func watchRunStatusThread(input core.SlackInput, state watchTurnState) string {
	if state.ApprovalContinuation {
		return state.ResponseThreadTS
	}
	return slackReplyThread(input)
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
		state, _ := decodeWatchRunContext(run)
		publish := publishTriageFailure(input, state)
		if publish {
			if err := s.postInputNotice(
				ctx,
				"watch_finalization_failure_"+run.ID,
				input,
				watchFailureNotice(detail),
			); err != nil {
				return err
			}
		}
		_ = s.store.Audit(ctx, core.AuditEvent{
			Kind: "agent.finalization", ObjectID: run.ID,
			Outcome: triageFailureOutcome(publish), Detail: detail,
		})
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
	if len(state.MatchedRules) > 0 && decision.Action == "incident" {
		alertPolicy, policyErr := s.channelAlertPolicy(ctx, input.ChannelID)
		if policyErr != nil {
			return policyErr
		}
		if alertPolicy != "automatic" {
			decision = standingRuleIncidentAsReply(decision, alertPolicy == "offer")
		}
	}
	if err := s.applyWatchDecision(ctx, input, state, decision); err != nil {
		return err
	}
	if err := s.scheduleEpisodeRechecks(
		ctx, run, input, state, decision.Action, decision.Completion,
	); err != nil {
		return err
	}
	episodeState, phase, status, nextAction := completionEpisodePhase(
		decision.Completion,
		decision.PendingApproval,
	)
	if err := s.store.SetWorkEpisodePhase(
		ctx, run.ID, episodeState, phase, status, nextAction, time.Time{},
	); err != nil {
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
	var pendingApproval *core.EmisarApproval
	var episodeCompletion *completionAssessment
	var reportReplyParts []string
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
				ID:         "tl_agent_failure_" + run.ID,
				IncidentID: incident.ID, ChannelID: incident.ChannelID,
				Kind: "agent.failure", ActorID: "responder",
				Title:  "Agent result could not be rendered",
				Detail: boundedField(trimError(reportErr), 1000),
			})
		} else {
			episodeCompletion = report.Completion
			if conversation && s.cfg.IsOperator(conversationInput.UserID) {
				if offer, ok := normalizeOperationalAlertRule(
					conversationInput,
					firstNonempty(run.Repository, incident.Repository),
					report.RuleOffer,
				); ok {
					report.RuleOffer = offer
				}
				if offer, acknowledgement, ok := normalizeResponseLocationPreference(
					conversationInput, report.PreferenceOffer,
				); ok {
					report.PreferenceOffer = offer
					if report.MemoryOffer == nil && report.RuleOffer == nil && report.ScheduleOffer == nil {
						report.Message = acknowledgement
					} else {
						report.Message = "I split that into separate settings so each part stays clear and reversible. Confirm the reply-location preference and the alert-triage rule below."
					}
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
			reportReplyParts = replySequence(
				report.Message,
				report.FollowupMessages,
			)
			if conversation && suppressConversationReply(report.Message) {
				if err := s.requireNativeStatusClear(ctx, incident, run.ID); err != nil {
					return err
				}
				return s.store.FinishAgentRun(ctx, run.ID)
			}
			if conversation {
				report.Message = reportReplyParts[len(reportReplyParts)-1]
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
				if report.ScheduleOffer != nil {
					if actionValue, task, when, ok := s.prepareScheduleOfferAction(
						ctx, conversationInput, report.ScheduleOffer,
					); ok {
						message = slackui.WithScheduleOffer(message, task, actionValue, when)
					} else {
						message = slackui.ScheduleOfferUnavailable(message)
					}
				}
			} else {
				report.Message = reportReplyParts[len(reportReplyParts)-1]
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
				pendingApproval = report.PendingApproval
			}
			if report.Completion != nil && report.Completion.Status == "blocked" {
				message = slackui.WithBlockedAssessment(
					message,
					report.Completion.Summary,
					report.Completion.MaterialGaps,
					report.Completion.Attempts,
					report.Completion.NextAction,
					s.sanitizer,
				)
			}
			evidenceIDs := make([]string, 0, len(report.Evidence))
			for _, evidence := range report.Evidence {
				evidenceIDs = append(evidenceIDs, evidence.ID)
			}
			_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
				ID:          "tl_agent_finding_" + run.ID,
				IncidentID:  incident.ID,
				ChannelID:   incident.ChannelID,
				Kind:        "agent.finding",
				ActorID:     "responder",
				Title:       "Investigation update",
				Detail:      boundedField(strings.Join(reportReplyParts, "\n\n"), 2000),
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
			ID:         "tl_agent_failure_" + run.ID,
			IncidentID: incident.ID, ChannelID: incident.ChannelID,
			Kind: "agent.failure", ActorID: "responder",
			Title: "Agent turn " + state, Detail: detail,
		})
	}
	if state == "completed" && incident.IsEngineeringTask() {
		if changes, changesErr := s.coop.Changes(
			ctx, incident.CoopSessionID,
		); changesErr == nil {
			assembled, _ := decodeAssembledAgentContext(run.Context)
			if engineeringTaskTurnCreatedChanges(
				assembled.InitialTaskChangesFingerprint,
				changes,
			) {
				message = slackui.WithEngineeringTaskDelivery(
					message,
					incident,
					true,
				)
			}
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
	baseDeliveryID := "out_run_" + run.ID
	if len(reportReplyParts) > 1 {
		for index, part := range reportReplyParts[:len(reportReplyParts)-1] {
			if err := s.enqueue(
				ctx,
				replySequenceDeliveryID(baseDeliveryID, index, len(reportReplyParts)),
				incident,
				"assistant",
				threadTS,
				slackui.ConversationResponse(part, s.sanitizer),
			); err != nil {
				return err
			}
		}
	}
	replyCount := max(1, len(reportReplyParts))
	deliveryID := replySequenceDeliveryID(
		baseDeliveryID,
		replyCount-1,
		replyCount,
	)
	if len(visuals) == 0 {
		if err := s.enqueue(
			ctx,
			deliveryID,
			incident,
			"assistant",
			threadTS,
			message,
		); err != nil {
			return err
		}
	} else if err := s.enqueueGeneratedVisuals(
		ctx, deliveryID, incident.ID, incident.ChannelID, threadTS,
		run.SessionID, run.CoopTurnID, visuals, &message,
	); err != nil {
		return err
	}
	if err := s.bindAndScheduleEmisarApproval(
		ctx,
		pendingApproval,
		deliveryID,
	); err != nil {
		return err
	}
	if err := s.requireNativeStatusClear(ctx, incident, run.ID); err != nil {
		return err
	}
	if state == "completed" {
		episodeState, phase, status, nextAction := completionEpisodePhase(
			episodeCompletion,
			pendingApproval,
		)
		if err := s.store.SetWorkEpisodePhase(
			ctx, run.ID, episodeState, phase, status, nextAction, time.Time{},
		); err != nil {
			return err
		}
	}
	if err := s.store.FinishAgentRun(ctx, run.ID); err != nil {
		return err
	}
	s.forgetNativeStatus(incident.ID)
	return nil
}

type taskChangesFingerprint struct {
	BaseCommit  string        `json:"base_commit"`
	ForkHead    string        `json:"fork_head"`
	ParentHead  string        `json:"parent_head"`
	Committed   []coop.Change `json:"committed,omitempty"`
	Staged      []coop.Change `json:"staged,omitempty"`
	Unstaged    []coop.Change `json:"unstaged,omitempty"`
	Untracked   []coop.Change `json:"untracked,omitempty"`
	Conflicts   []coop.Change `json:"conflicts,omitempty"`
	PatchDigest string        `json:"patch_digest,omitempty"`
	PatchBytes  int64         `json:"patch_bytes"`
}

func coopChangesFingerprint(changes coop.Changes) string {
	data, _ := json.Marshal(taskChangesFingerprint{
		BaseCommit: changes.BaseCommit, ForkHead: changes.ForkHead,
		ParentHead: changes.ParentHead, Committed: changes.Committed,
		Staged: changes.Staged, Unstaged: changes.Unstaged,
		Untracked: changes.Untracked, Conflicts: changes.Conflicts,
		PatchDigest: changes.PatchDigest, PatchBytes: changes.PatchBytes,
	})
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

func engineeringTaskTurnCreatedChanges(
	initialFingerprint string,
	changes coop.Changes,
) bool {
	return initialFingerprint != "" && initialFingerprint != "unavailable" &&
		coopChangesPresent(changes) &&
		initialFingerprint != coopChangesFingerprint(changes)
}

func (s *Service) finishTriageRunFailure(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state watchTurnState,
	detail string,
) error {
	message := slackui.Notice(watchFailureNotice(detail))
	if state.ApprovalContinuation {
		if err := s.postInputMessageAt(
			ctx,
			firstNonempty(state.ReplyDeliveryID, "emisar_approval_failure_"+run.ID),
			input.ChannelID,
			state.ResponseThreadTS,
			message,
		); err != nil {
			return err
		}
		return s.clearWatchPendingStatus(ctx, input, state)
	}
	publish := publishTriageFailure(input, state)
	if publish {
		post := s.postInputMessage
		if input.Kind == "shortcut" || len(state.MatchedRules) > 0 {
			post = s.postInputMessageInSourceThread
		}
		if err := post(ctx, "watch_failure_"+input.ID, input, message); err != nil {
			return err
		}
	}
	if err := s.clearWatchPendingStatus(ctx, input, state); err != nil {
		return err
	}
	if err := s.retireFailedWatchSession(ctx, input, state); err != nil && s.log != nil {
		s.log.Warn("retire failed triage session", "run", run.ID, "error", err)
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
		Outcome: triageFailureOutcome(publish), Detail: detail,
	})
	return nil
}

func publishTriageFailure(input core.SlackInput, state watchTurnState) bool {
	return state.RecheckOriginRunID == "" &&
		(state.ApprovalContinuation || input.Kind != "bot_message")
}

func triageFailureOutcome(published bool) string {
	if published {
		return "failed"
	}
	return "failed_suppressed"
}
