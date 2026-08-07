package service

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/provider"
	"github.com/AndrewDryga/responder/internal/recall"
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
				decisionpkg.WatchTurnState{ConversationFollowup: true},
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
	state, resumed, err := s.resumeLegacyWatchedTurn(ctx, input)
	if err != nil || resumed {
		return err
	}
	if s.mentionOnlyNudge(input) {
		nudged, err := s.store.NudgeLatestAgentRun(
			ctx,
			input.ChannelID,
			conversationalResponseThread(input),
		)
		if err != nil {
			return fmt.Errorf("nudge active Slack work: %w", err)
		}
		if nudged {
			if s.cfg.Slack.NativeStatus {
				if err := s.enqueueNativeStatus(
					ctx,
					"",
					input.ChannelID,
					slackReplyThread(input),
					watchPendingStatus,
					watchProgressSteps(),
				); err != nil {
					s.log.Warn(
						"refresh Slack status for mention-only nudge",
						"channel", input.ChannelID,
						"thread", slackReplyThread(input),
						"input", input.ID,
						"error", err,
					)
				}
			}
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.input", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "nudged_existing_work",
				Detail:  "mention-only follow-up resumed the active conversation work",
			})
			return s.finishInputIfOpen(ctx, input)
		}
	}
	if err := s.captureWatchTurnState(ctx, input, &state); err != nil {
		return err
	}
	if s.obviousHumanDialogue(input, state) {
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.input", ActorID: input.UserID, ObjectID: input.ID,
			Outcome: "ignored_human_dialogue",
			Detail:  "message explicitly addresses another Slack member",
		})
		return s.finishInputIfOpen(ctx, input)
	}
	if !state.RouteCaptured {
		responseThreadTS, referencedThreadTS, err := s.resolveConversationRoute(
			ctx, input,
		)
		if err != nil {
			return fmt.Errorf("resolve watched input conversation route: %w", err)
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
			state.PendingStatusAt = s.now().Unix()
		}
	}
	readyAt, err := s.watchRunReadyAt(ctx, input)
	if err != nil {
		return err
	}
	conversationKey := watchConversationKey(input)
	episode, err := s.correlateWatchEpisode(ctx, input, conversationKey, &state)
	if err != nil {
		return err
	}
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return err
	}
	run, _, err := s.store.QueueAgentRun(ctx, core.AgentRun{
		Mode:            core.AgentRunTriage,
		ChannelID:       input.ChannelID,
		ThreadTS:        state.ResponseThreadTS,
		ConversationKey: conversationKey,
		SourceKind:      "watch",
		SourceID:        input.ID,
		UserID:          input.UserID,
		Context:         contextJSON,
		NextAttemptAt:   readyAt,
		CommitmentTitle: commitmentTitleForInput(input),
		Episode:         episode,
	})
	if err != nil {
		return fmt.Errorf("queue watched agent run: %w", err)
	}
	if state.PendingStatusSet && len(run.Context) > 0 &&
		string(run.Context) != string(contextJSON) {
		if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
			return err
		}
	}
	if err := s.finishSlackInput(ctx, input); err != nil {
		return fmt.Errorf("finish watched Slack input: %w", err)
	}
	return nil
}

// resumeLegacyWatchedTurn re-queues a watched input that was frozen mid-turn by
// an older build, and reports whether it handled the input entirely.
//
// This exists so a restart across an upgrade does not strand a turn that Coop
// is already running: the run is re-queued in the running state bound to the
// existing Coop turn, rather than started again from the beginning.
func (s *Service) resumeLegacyWatchedTurn(
	ctx context.Context,
	input core.SlackInput,
) (decisionpkg.WatchTurnState, bool, error) {
	if len(input.Frozen) > 0 {
		legacy, err := decisionpkg.DecodeWatchState(input.Frozen)
		if err != nil {
			return decisionpkg.WatchTurnState{}, true, fmt.Errorf("migrate legacy watched input state: %w", err)
		}
		if legacy.TurnID != "" {
			memory, memoryErr := s.store.GetChannelMemory(
				ctx, input.ChannelID,
			)
			if memoryErr != nil && !errors.Is(memoryErr, store.ErrNotFound) {
				return decisionpkg.WatchTurnState{}, true, memoryErr
			}
			contextJSON, marshalErr := json.Marshal(legacy)
			if marshalErr != nil {
				return decisionpkg.WatchTurnState{}, true, marshalErr
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
				StartedAt:       s.now().UTC(),
				CommitmentTitle: commitmentTitleForInput(input),
				Episode:         s.episodeForWatchedInput(input, legacy),
			})
			if queueErr != nil {
				return decisionpkg.WatchTurnState{}, true, queueErr
			}
			return decisionpkg.WatchTurnState{}, true, s.finishInputIfOpen(ctx, input)
		}
		return legacy, false, nil
	}
	return decisionpkg.WatchTurnState{}, false, nil
}

// captureWatchTurnState resolves the facts a turn must decide once and then
// keep, even across retries: the channel's alert policy, which standing rules
// matched, which publications were in flight, and whether this continues a
// recent conversation.
//
// They are captured rather than recomputed because a retry minutes later sees a
// different channel. Recomputing would let a run change its mind about what it
// is responding to partway through, which reads to an operator as Responder
// contradicting itself.
func (s *Service) captureWatchTurnState(
	ctx context.Context,
	input core.SlackInput,
	state *decisionpkg.WatchTurnState,
) error {
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
			return fmt.Errorf("match standing rules for watched input: %w", err)
		}
		state.MatchedRules = rules
		state.RulesCaptured = true
	}
	if !state.PublicationsCaptured {
		if input.Kind == "bot_message" {
			publications, err := s.store.ListActivePublicationContexts(
				ctx,
				s.now().UTC().Add(-s.cfg.GitHub.DeliveryCorrelationWindow.Duration),
				20,
			)
			if err != nil {
				return err
			}
			state.ActivePublications = publications
		}
		state.PublicationsCaptured = true
	}
	if !isPrivateSlackVerificationReplay(input) &&
		!state.RuleAcknowledged && len(state.MatchedRules) > 0 {
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
	return nil
}

// watchRunReadyAt returns when this run should first be attempted. The settle
// delay lets a person finish a thought before Responder answers half of it.
func (s *Service) watchRunReadyAt(
	ctx context.Context,
	input core.SlackInput,
) (time.Time, error) {
	readyAt := s.now().UTC()
	if input.Kind != "scheduled" && input.Kind != "recheck" &&
		s.cfg.Slack.WatchSettleDelay.Duration > 0 {
		// App notifications are independent operational streams. Basing their
		// settle time on the latest message in a busy channel can leave a failed
		// alert queued for tens of minutes while unrelated chat continues.
		if input.Kind == "bot_message" {
			readyAt = input.ReceivedAt.Add(s.cfg.Slack.WatchSettleDelay.Duration)
		} else {
			latestAt, err := s.store.LatestSlackConversationAt(ctx, input.ChannelID)
			if err != nil {
				return time.Time{}, err
			}
			readyAt = latestAt.Add(s.cfg.Slack.WatchSettleDelay.Duration)
		}
	}
	return readyAt, nil
}

// correlateWatchEpisode decides whether this input continues an existing unit
// of work or starts a new one, and binds it to the same Slack destination when
// it continues.
//
// The distinction matters to an operator: a deployment's success notification
// belongs in the thread where its failure was discussed, not in a fresh one
// that has lost the context of why anyone cared.
func (s *Service) correlateWatchEpisode(
	ctx context.Context,
	input core.SlackInput,
	conversationKey string,
	state *decisionpkg.WatchTurnState,
) (*core.WorkEpisode, error) {
	episode := s.episodeForWatchedInput(input, *state)
	if previous, previousErr := s.store.GetLatestWorkEpisodeByConversationKey(
		ctx, conversationKey,
	); previousErr == nil {
		if input.Kind == "bot_message" && strings.HasPrefix(conversationKey, "operation:") {
			// A lifecycle update is another attempt in the same unit of work, not a
			// new episode. Reuse both the episode and its bound Slack destination.
			episode.ID = previous.ID
			if previous.Destination.ChannelID == input.ChannelID &&
				previous.Destination.ThreadTS != "" {
				state.ResponseThreadTS = previous.Destination.ThreadTS
			}
		} else {
			episode.ParentEpisodeID = previous.ID
		}
	} else if !errors.Is(previousErr, store.ErrNotFound) {
		return nil, previousErr
	} else if input.Kind == "bot_message" {
		previous, operationalErr := s.store.GetLatestOperationalWorkEpisode(
			ctx, input.ChannelID, input.UserID, input.ReceivedAt.Add(-30*time.Minute),
		)
		if operationalErr == nil {
			episode.ParentEpisodeID = previous.ID
			if previous.Destination.ChannelID == input.ChannelID &&
				previous.Destination.ThreadTS != "" {
				state.ResponseThreadTS = previous.Destination.ThreadTS
			}
		} else if !errors.Is(operationalErr, store.ErrNotFound) {
			return nil, operationalErr
		}
	}
	return episode, nil
}

func (s *Service) completeIgnoredLifecycleInput(
	ctx context.Context,
	input core.SlackInput,
	reason string,
) error {
	rules, err := s.matchingStandingRules(ctx, input)
	if err != nil {
		return err
	}
	for _, rule := range rules {
		if _, err := s.store.RecordStandingRuleRun(
			ctx, rule.ID, input.ID, input.EventID, "ignore",
		); err != nil {
			return err
		}
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.external_lifecycle", ActorID: input.UserID,
		ObjectID: input.ID, Outcome: "ignored", Detail: reason,
	})
	if !isPrivateSlackVerificationReplay(input) {
		return s.finishSlackInput(ctx, input)
	}
	result, err := json.Marshal(decisionpkg.WatchDecision{Action: "ignore", Reason: reason})
	if err != nil {
		return err
	}
	run, _, err := s.store.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ThreadTS:        conversationalResponseThread(input),
		ConversationKey: watchConversationKey(input),
		SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
		State: core.AgentRunRunning, StartedAt: s.now().UTC(),
		CommitmentTitle: commitmentTitleForInput(input),
		Episode:         s.episodeForWatchedInput(input, decisionpkg.WatchTurnState{}),
	})
	if err != nil {
		return err
	}
	if err := s.store.StageAgentRunResult(
		ctx, run.ID, "completed", result, reason, 0,
	); err != nil {
		return err
	}
	if _, err := s.store.BeginAgentRunFinalization(ctx, run.ID); err != nil {
		return err
	}
	if err := s.store.FinishAgentRun(ctx, run.ID); err != nil {
		return err
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
	return core.TruncateUTF8WithSuffix(text, 180, "...")
}

func watchInputWantsPendingStatus(
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
) bool {
	return !isPrivateSlackVerificationReplay(input) &&
		input.Kind != "recheck" && slackReplyThread(input) != "" &&
		(decisionpkg.WatchInputTargeted(input, state) ||
			decisionpkg.RequestedConversationLocation(input.Text) != decisionpkg.ConversationLocationFollow)
}

func (s *Service) mentionOnlyNudge(input core.SlackInput) bool {
	return input.Kind == "mention" && s.identity.BotUserID != "" &&
		strings.TrimSpace(s.stripBotMention(input.Text)) == "" &&
		len(input.Attachments) == 0
}

func watchConversationKey(input core.SlackInput) string {
	if input.Kind == "bot_message" {
		if key := operationalCorrelationKey(input); key != "" {
			return "operation:" + input.ChannelID + ":" + key
		}
	}
	return "channel:" + input.ChannelID
}

func watchProgressSteps() []string {
	return []string{
		"Reading the conversation",
		"Checking the repository setup",
		"Checking live systems",
		"Comparing expected and current state",
		"Checking whether the result is complete",
	}
}

func decodeWatchRunContext(run core.AgentRun) (decisionpkg.WatchTurnState, error) {
	if len(run.Context) == 0 {
		return decisionpkg.WatchTurnState{}, nil
	}
	var state decisionpkg.WatchTurnState
	if err := decisionpkg.DecodeStrictJSON(run.Context, &state); err != nil {
		return decisionpkg.WatchTurnState{}, err
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
			ctx, run.ID, "unsupported agent run mode "+string(run.Mode), s.now(), true,
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
			s.setIncidentError(ctx, incident.ID, core.WorkflowBlocked, detail)
			return s.store.DeferAgentRun(
				ctx, run.ID, detail, s.now().Add(30*time.Second),
			)
		}
		detail := "Responder could not allocate additional automatic session capacity: " +
			trimError(err) + ". The pending request and Coop session are preserved; " +
			"Responder will retry after the Coop limit or service error is corrected."
		s.setIncidentError(ctx, incident.ID, core.WorkflowParked, detail)
		return s.store.DeferAgentRun(
			ctx, run.ID, detail, s.queueDelay(run.Failures),
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
		core.FirstNonempty(run.Repository, incident.Repository),
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
	prompt += s.episodeContinuityPrompt(ctx, episode)
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
	submissionPrompt := prompt + "\n\n" + s.structuredResponsePolicy() +
		agentRunContinuationPrompt(run)
	artifacts, err = s.augmentAgentRunArtifacts(
		ctx,
		submissionPrompt+"\n"+string(run.Context),
		artifacts,
	)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, false)
	}
	submissionPrompt += agentInputArtifactsPrompt(artifacts)
	if _, err := s.ensureAttemptContextManifest(
		ctx, run, session, submissionPrompt, artifacts,
	); err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, false)
	}
	turn, _, err := s.coop.SubmitTurnWithArtifacts(
		ctx,
		run.IdempotencyKey,
		incident.CoopSessionID,
		revision,
		submissionPrompt,
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
			ctx, run.ID, trimError(err), s.queueDelay(run.Failures),
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
	memory = memorypkg.SanitizeMemory(memory)
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
		len(memory.EvidenceRefs) != 0 ||
		len(memory.Knowledge) != 0
}

func relatedSituationsPrompt(situations []decisionpkg.ConversationSituationContext) string {
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
	next := s.queueDelay(run.Failures + 1)
	if terminal {
		next = s.now()
	}
	err := s.store.RetryAgentRun(
		ctx, run.ID, trimError(cause), next, terminal,
	)
	if terminal && incident.ID != "" {
		s.setIncidentError(
			ctx, incident.ID, core.WorkflowParked, trimError(cause),
		)
		s.clearNativeStatus(ctx, incident)
	}
	return err
}

// freezeTriageContext captures the Slack context, continuity, and matched
// standing rules for a triage run exactly once. The capture flags make it
// idempotent, so a run that is retried after a restart reuses the context it
// was prepared with rather than silently re-reading a channel that has moved
// on.
func (s *Service) freezeTriageContext(
	ctx context.Context,
	state *decisionpkg.WatchTurnState,
	input core.SlackInput,
) error {
	if !state.ContextCaptured || !state.PriorCaptured {
		assembled, err := s.assembleAgentContext(
			ctx,
			agentContextRequest{
				ChannelID: input.ChannelID,
				Repository: core.FirstNonempty(
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
			return err
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
		matched, err := s.matchingStandingRules(ctx, input)
		if err != nil {
			return err
		}
		state.MatchedRules = matched
		state.RulesCaptured = true
	}
	return nil
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
	if decided, err := s.admitTriageRun(ctx, run, input, &state); decided {
		return err
	}
	if err := s.freezeTriageContext(ctx, &state, input); err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	repository, ok := s.cfg.RepositoryContext(
		core.FirstNonempty(state.Repository, s.cfg.Slack.DefaultRepository),
	)
	if !ok {
		return s.retryAgentRun(
			ctx,
			run,
			fmt.Errorf("repository context %q is not configured", state.Repository),
		)
	}
	if state.Lane == "" {
		state.Lane = triageLane(state, input, repository)
	}
	resolved, err := s.resolveTriageSession(ctx, run, input, &state, repository)
	if err != nil {
		return err
	}
	session, repositoryKey := resolved.session, resolved.repositoryKey
	generation, eventSequence := resolved.generation, resolved.eventSequence
	if session.ActiveTurnID != "" {
		return s.store.DeferAgentRun(
			ctx,
			run.ID,
			"waiting for the previous agent run in this Slack channel",
			s.now().Add(time.Second),
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
		core.FirstNonempty(repositoryKey, s.cfg.Slack.DefaultRepository),
		state.MatchedRules,
	) + "\n\n" + repositorySetPrompt(session)
	if input.Kind == "bot_message" {
		prompt += "\n\n<operational-burst>\nThis is the newest app update in a bounded " +
			"operational burst. Reconcile every material app notice in the supplied recent " +
			"context before replying. Group notices only when evidence connects them; preserve " +
			"separate conclusions for unrelated services. Do not silently omit an older failure " +
			"merely because this update arrived later. Publish one concise, decision-useful update " +
			"for the burst rather than narrating each notification.\n</operational-burst>"
	}
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
	artifacts, err = s.augmentAgentRunArtifacts(
		ctx,
		prompt+"\n"+string(run.Context),
		artifacts,
	)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	prompt += agentInputArtifactsPrompt(artifacts)
	if _, err := s.ensureAttemptContextManifest(
		ctx, run, session, prompt, artifacts,
	); err != nil {
		return s.retryAgentRun(ctx, run, err)
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

// admitTriageRun applies the checks that can end a run before any work is
// frozen: a newer classification of the same message, a newer nearby message
// that will carry the conversation, or a newer update on the same operational
// stream. It reports whether the run's fate is already decided.
//
// They are grouped because they share the property worth keeping visible —
// each one ends the run rather than shaping it, so nothing downstream has to
// wonder whether the run is still alive.
func (s *Service) admitTriageRun(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state *decisionpkg.WatchTurnState,
) (bool, error) {
	var err error
	if input.Kind == "bot_message" && state.AlertPolicy == "" {
		state.AlertPolicy, err = s.channelAlertPolicy(ctx, input.ChannelID)
		if err != nil {
			return true, s.retryAgentRun(ctx, run, err)
		}
	}
	if input.Kind == "message" && len(state.MatchedRules) == 0 &&
		!state.ApprovalContinuation {
		alreadyClassified, err := s.store.HasNewerWatchDecision(
			ctx, input.ChannelID, input.MessageTS,
		)
		if err != nil {
			return true, s.retryAgentRun(ctx, run, err)
		}
		if alreadyClassified {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "superseded",
				Detail:  "a newer channel message was already classified",
			})
			return true, s.store.SupersedeAgentRun(
				ctx, run.ID, "a newer channel message was already classified",
			)
		}
		newer, err := s.store.HasNewerSubstantivePendingAgentRun(
			ctx, run, s.identity.BotUserID,
		)
		if err != nil {
			return true, s.retryAgentRun(ctx, run, err)
		}
		if newer {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "superseded",
				Detail:  "a newer nearby channel message will carry the conversation context",
			})
			return true, s.store.SupersedeAgentRun(
				ctx,
				run.ID,
				"superseded by a newer nearby channel message",
			)
		}
	}
	if input.Kind == "bot_message" {
		newer, err := s.store.HasNewerPendingAgentRun(ctx, run)
		if err != nil {
			return true, s.retryAgentRun(ctx, run, err)
		}
		if !newer {
			newer, err = s.store.HasNewerOperationalAgentRun(
				ctx, run, operationalBurstWindow, true,
			)
			if err != nil {
				return true, s.retryAgentRun(ctx, run, err)
			}
		}
		if newer {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "coalesced",
				Detail:  "a newer update for the same operational stream will be investigated",
			})
			return true, s.store.SupersedeAgentRun(
				ctx, run.ID, "coalesced into a newer operational update",
			)
		}
	}
	return false, nil
}

// triageLane decides which lane a run belongs to when nothing upstream has
// already pinned one. Conversation is the narrower case: it needs a channel
// policy, a plain message aimed at Responder, and the absence of anything —
// attachments, matched alert rules, a verification replay — that implies a
// real investigation.
func triageLane(
	state decisionpkg.WatchTurnState,
	input core.SlackInput,
	repository config.Repository,
) string {
	lane := "investigation"
	if !isSlackVerificationReplay(input) &&
		repository.ConversationPolicy != "" &&
		len(input.Attachments) == 0 &&
		len(state.MatchedRules) == 0 &&
		(input.Kind == "message" || input.Kind == "mention" ||
			input.Kind == "direct") &&
		decisionpkg.WatchInputTargeted(input, state) {
		lane = "conversation"
	}
	return lane
}

// retryAtNextSessionGeneration retries a run whose session could not be
// obtained, first recording the generation that failure implies. Without the
// bump the next attempt asks for the same session and fails the same way, so a
// broken session would retry until the run exhausted its budget.
//
// The generation only ever moves forward, and it is persisted before the retry:
// a crash between the two must not lose the fact that this generation is spent.
// nextSessionGeneration returns the generation the next attempt should ask
// for. An ordinary transient failure keeps the current one — the session is
// fine, the moment was not. A failure that says the session itself is unusable
// advances past it, because asking for it again produces the same failure.
func nextSessionGeneration(current, observed int, cause error) int {
	next := max(current, observed)
	if advanceFailedSessionGeneration(cause) && observed > 0 {
		next = max(next, observed+1)
	}
	return next
}

func (s *Service) retryAtNextSessionGeneration(
	ctx context.Context,
	run core.AgentRun,
	state *decisionpkg.WatchTurnState,
	observedGeneration int,
	cause error,
) error {
	next := nextSessionGeneration(state.Generation, observedGeneration, cause)
	if next > state.Generation {
		state.Generation = next
		if err := s.persistTriageRunState(ctx, run.ID, *state); err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
	}
	return s.retryAgentRun(ctx, run, cause)
}

// triageSessionBinding is what session resolution produced. It is a struct
// rather than four return values because the four always travel together, and
// two of them are numbers that would be easy to transpose at a call site.
type triageSessionBinding struct {
	session       coop.Session
	repositoryKey string
	generation    int
	eventSequence int64
}

// resolveTriageSession obtains the Coop session this run will execute in. The
// conversation and investigation lanes resolve against different memory, but
// they fail identically: record the generation the failure implies so the next
// attempt asks for a fresh session rather than the one that just failed.
func (s *Service) resolveTriageSession(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state *decisionpkg.WatchTurnState,
	repository config.Repository,
) (triageSessionBinding, error) {
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
			return triageSessionBinding{}, s.retryAgentRun(ctx, run, err)
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
			return triageSessionBinding{}, s.retryAtNextSessionGeneration(
				ctx, run, state, conversation.Generation, conversationErr,
			)
		}
		session = conversationSession
		repositoryKey = conversation.Repository
		generation = conversation.Generation
		eventSequence = conversation.CoopEventSequence
	} else {
		sessionChannelID := core.FirstNonempty(state.SessionChannelID, input.ChannelID)
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
			return triageSessionBinding{}, s.retryAtNextSessionGeneration(
				ctx, run, state, memory.Generation, investigationErr,
			)
		}
		session = investigationSession
		repositoryKey = memory.Repository
		generation = memory.Generation
		eventSequence = memory.CoopEventSequence
		if !agentMemoryPresent(state.Memory) {
			state.Memory = memory.State
		}
	}
	return triageSessionBinding{session, repositoryKey, generation, eventSequence}, nil
}

func (s *Service) persistTriageRunState(
	ctx context.Context,
	runID string,
	state decisionpkg.WatchTurnState,
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
		s.queueDelay(run.Failures+1),
		terminal,
	)
}

func (s *Service) failPreparingTriageRun(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
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
				s.queueDelay(run.Failures+1),
				false,
			)
		}
	}
	if err := s.clearWatchPendingStatus(ctx, input, state); err != nil {
		return s.store.RetryAgentRun(
			ctx,
			run.ID,
			"clear terminal triage status: "+trimError(err),
			s.queueDelay(run.Failures+1),
			false,
		)
	}
	_ = s.retireFailedWatchSession(ctx, input, state)
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
		Outcome: triageFailureOutcome(publish), Detail: detail,
	})
	return s.store.RetryAgentRun(ctx, run.ID, detail, s.now(), true)
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

// stagedTurn is what a completed turn contributes to the staged agent-run
// result: the payload to persist and the operator-facing failure detail. The
// per-mode validators below own both, so the outer function does not have to
// thread two mutable locals through several hundred lines.
type stagedTurn struct {
	result []byte
	detail string
}

// stageTriageTerminal validates a completed triage turn and applies its watch
// decision. A true first result means the turn is fully handled and the caller
// should return the accompanying error, which may be nil.
func (s *Service) stageTriageTerminal(
	ctx context.Context,
	run core.AgentRun,
	turn coop.Turn,
	cursor int64,
	staged *stagedTurn,
) (bool, error) {
	input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
	state, stateErr := decodeWatchRunContext(run)
	decision, decisionErr := decisionpkg.ParseWatchDecision(turn.AssistantMessage, s.now())
	if decisionErr == nil {
		s.recordResultProtocol(
			ctx, run.ID, decision.LegacyShape)
	}
	if inputErr != nil {
		return true, inputErr
	}
	if stateErr != nil {
		return true, stateErr
	}
	if decisionErr != nil {
		correction := "the structured Slack response is invalid: " + trimError(decisionErr)
		if !consumeWatchStructuredCorrection(
			&state, s.cfg.Limits.MaxAgentRunAttempts,
		) {
			state.FailureDetail = correction
			contextJSON, marshalErr := json.Marshal(state)
			if marshalErr != nil {
				return true, marshalErr
			}
			if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
				return true, err
			}
			if err := s.store.RequeueAgentRun(
				ctx, run.ID, correction, cursor, s.now(),
			); err != nil {
				return true, err
			}
			_ = s.advanceTriageSessionEvents(ctx, run, cursor)
			return true, nil
		}
		decision = blockedWatchContinuation(run, input, state, correction, nil)
		staged.result, decisionErr = decisionpkg.MarshalWatchDecisionResult(decision)
		if decisionErr != nil {
			return true, decisionErr
		}
		staged.detail = ""
	} else {
		if state.Lane == "conversation" && decision.Action == "escalate" {
			if err := s.store.AdvanceConversationSessionEvents(
				ctx, run.ChannelID, run.SessionID, cursor,
			); err != nil {
				return true, err
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
				return true, marshalErr
			}
			return true, s.store.EscalateAgentRun(
				ctx,
				run.ID,
				"continuing in the full investigation lane: "+decision.Reason,
				contextJSON,
				s.now(),
			)
		}
		episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
		if episodeErr != nil {
			return true, episodeErr
		}
		decisionpkg.NormalizeAppAlertCompletion(input, &decision)
		originalAction := decision.Action
		originalPublicationUpdates := len(decision.PublicationUpdates)
		decision = enforceExternalLifecycleCommunication(input, decision)
		var lifecycleEvidenceAdjusted bool
		decision, lifecycleEvidenceAdjusted = enforceExternalLifecycleEvidence(
			input, episode, decision,
		)
		var recoveryLinkAdjusted bool
		decision, recoveryLinkAdjusted = decisionpkg.EnforceRecoveredAlertLink(input, state, decision)
		if lifecycleEvidenceAdjusted || decision.Action != originalAction ||
			len(decision.PublicationUpdates) != originalPublicationUpdates ||
			recoveryLinkAdjusted {
			marshaledResult, marshalErr := decisionpkg.MarshalWatchDecisionResult(decision)
			if marshalErr != nil {
				return true, marshalErr
			}
			staged.result = marshaledResult
		}
		correction := decisionpkg.WatchDecisionCorrection(input, state, decision, operationalCorrelationKey)
		if correction == "" {
			correction = decisionpkg.AlertReplyLanguageCorrectionWithContext(input, state, decision)
		}
		if correction == "" {
			correction = externalLifecycleReplyLanguageCorrection(input, decision)
		}
		if correction == "" {
			correction = investigation.CompletionCorrection(
				episode,
				decision.Action,
				decisionpkg.SanitizeCoverage(decision.Coverage, "", "", "", s.now()),
				decision.Completion,
			)
			if correction == "" {
				correction = investigation.ConclusionLanguageCorrection(
					episode, decision.Action, decision.Message,
				)
			}
			if correction == "" {
				correction = unsupportedOperationalClaimCorrection(
					decision.Action, decision.Message,
					decisionpkg.SanitizeEvidence(decision.Evidence, "", "", "", s.now()),
				)
			}
			if correction == "" {
				correction, episodeErr = s.episodeClaimCorrectionWithHistory(
					ctx,
					episode,
					decision.Action,
					decisionpkg.SanitizeEvidence(decision.Evidence, "", "", "", s.now()),
					decisionpkg.SanitizeCoverage(decision.Coverage, "", "", "", s.now()),
					decision.Completion,
					s.now(),
					len(decision.AppliedOperations) > 0,
				)
				if episodeErr != nil {
					return true, episodeErr
				}
			}
			if correction == "" {
				correction = decisionpkg.EpisodeDiagnosisCorrection(
					episode,
					decision.Action,
					decisionpkg.SanitizeCoverage(decision.Coverage, "", "", "", s.now()),
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
					return true, marshalErr
				}
				if err := s.store.SetAgentRunContext(
					ctx, run.ID, contextJSON,
				); err != nil {
					return true, err
				}
				if err := s.store.RequeueAgentRun(
					ctx, run.ID, correction, cursor, s.now(),
				); err != nil {
					return true, err
				}
				_ = s.advanceTriageSessionEvents(ctx, run, cursor)
				return true, nil
			}
			decision = blockedWatchContinuation(run, input, state, correction, &decision)
			marshaledResult, marshalErr := decisionpkg.MarshalWatchDecisionResult(decision)
			if marshalErr != nil {
				return true, marshalErr
			}
			staged.result = marshaledResult
			staged.detail = ""
		} else if err := s.recordResultOperationEvents(
			ctx, run.ID, decision.AppliedOperations,
		); err != nil {
			return true, err
		}
	}
	return false, nil
}

// stageIncidentTerminal validates a completed incident or engineering-task
// turn from its structured agent report, with the same contract.
func (s *Service) stageIncidentTerminal(
	ctx context.Context,
	run core.AgentRun,
	turn coop.Turn,
	cursor int64,
	staged *stagedTurn,
) (bool, error) {
	report, _, reportErr := decisionpkg.ParseAgentReport(turn.AssistantMessage)
	if reportErr == nil {
		s.recordResultProtocol(
			ctx, run.ID, report.LegacyShape)
	}
	if reportErr != nil {
		correction := "the structured agent report is invalid: " + trimError(reportErr)
		if !terminalStructuredCorrection(
			run.Failures+1, s.cfg.Limits.MaxAgentRunAttempts,
		) {
			if err := s.store.RequeueAgentRun(
				ctx, run.ID, correction, cursor, s.now(),
			); err != nil {
				return true, err
			}
			return true, nil
		}
		report = blockedAgentContinuation(correction, nil)
		staged.result, reportErr = json.Marshal(report)
		if reportErr != nil {
			return true, reportErr
		}
		staged.detail = ""
	} else {
		episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
		if episodeErr != nil {
			return true, episodeErr
		}
		correction := investigation.CompletionCorrection(
			episode,
			"reply",
			decisionpkg.SanitizeCoverage(report.Coverage, "", "", "", s.now()),
			report.Completion,
		)
		if correction == "" {
			correction = investigation.ConclusionLanguageCorrection(
				episode, "reply", report.Message,
			)
		}
		if correction == "" {
			correction = unsupportedOperationalClaimCorrection(
				"reply", report.Message,
				decisionpkg.SanitizeEvidence(report.Evidence, "", "", "", s.now()),
			)
		}
		if correction == "" {
			correction, episodeErr = s.episodeClaimCorrectionWithHistory(
				ctx,
				episode,
				"reply",
				decisionpkg.SanitizeEvidence(report.Evidence, "", "", "", s.now()),
				decisionpkg.SanitizeCoverage(report.Coverage, "", "", "", s.now()),
				report.Completion,
				s.now(),
				len(report.AppliedOperations) > 0,
			)
			if episodeErr != nil {
				return true, episodeErr
			}
		}
		if correction != "" {
			if !terminalStructuredCorrection(
				run.Failures+1, s.cfg.Limits.MaxAgentRunAttempts,
			) {
				if err := s.store.RequeueAgentRun(
					ctx, run.ID, correction, cursor, s.now(),
				); err != nil {
					return true, err
				}
				return true, nil
			}
			report = blockedAgentContinuation(correction, &report)
			staged.result, reportErr = json.Marshal(report)
			if reportErr != nil {
				return true, reportErr
			}
			staged.detail = ""
		} else if err := s.recordResultOperationEvents(
			ctx, run.ID, report.AppliedOperations,
		); err != nil {
			return true, err
		}
	}
	return false, nil
}

func (s *Service) stagePolledAgentRunTerminal(
	ctx context.Context,
	run core.AgentRun,
	eventType string,
	turn coop.Turn,
	cursor int64,
) error {
	detail := strings.TrimSpace(
		core.FirstNonempty(turn.ErrorDetail, turn.ErrorCode, turn.StopReason),
	)
	if missingCoopImageFailure(turn) &&
		s.repairCoopRuntime != nil {
		if err := s.repairCoopRuntime(ctx); err == nil {
			const reason = "Coop execution image rebuilt; retrying the same work episode"
			if err := s.store.DeferRunningAgentRun(
				ctx, run.ID, reason, cursor, s.now(),
			); err != nil {
				return err
			}
			if run.Mode == core.AgentRunTriage {
				_ = s.advanceTriageSessionEvents(ctx, run, cursor)
			}
			s.log.Info("rebuilt missing Coop execution image", "run", run.ID)
			return nil
		} else {
			reason := "waiting for the managed Coop execution image: " + trimError(err)
			delay := max(30*time.Second, queueDelayDuration(run.Failures+1))
			if run.Mode == core.AgentRunTriage {
				if clearErr := s.parkWatchRunPendingStatus(ctx, run); clearErr != nil {
					s.log.Warn(
						"clear watched Slack status while Coop is unavailable",
						"run", run.ID, "error", clearErr,
					)
				}
			}
			if err := s.store.DeferRunningAgentRun(
				ctx, run.ID, reason, cursor, s.now().Add(delay),
			); err != nil {
				return err
			}
			if run.Mode == core.AgentRunTriage {
				_ = s.advanceTriageSessionEvents(ctx, run, cursor)
			}
			s.log.Warn(
				"managed Coop execution image unavailable; work remains queued",
				"run", run.ID, "retry_in", delay, "error", err,
			)
			return nil
		}
	}
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
			ctx, run.ID, reason, cursor, s.now(),
		); err != nil {
			return err
		}
		if run.Mode == core.AgentRunTriage {
			_ = s.advanceTriageSessionEvents(ctx, run, cursor)
		}
		return nil
	}
	terminalState := strings.TrimPrefix(eventType, "turn.")
	staged := stagedTurn{result: []byte(turn.AssistantMessage), detail: detail}
	if run.Mode == core.AgentRunTriage && terminalState == "completed" {
		if handled, err := s.stageTriageTerminal(ctx, run, turn, cursor, &staged); handled {
			return err
		}
	}
	if (run.Mode == core.AgentRunIncident || run.Mode == core.AgentRunEngineeringTask) &&
		terminalState == "completed" {
		if handled, err := s.stageIncidentTerminal(ctx, run, turn, cursor, &staged); handled {
			return err
		}
	}
	if err := s.store.StageAgentRunResult(
		ctx, run.ID, terminalState, staged.result, staged.detail, cursor,
	); err != nil {
		return err
	}
	if run.Mode == core.AgentRunTriage {
		_ = s.advanceTriageSessionEvents(ctx, run, cursor)
	}
	return nil
}

func (s *Service) parkWatchRunPendingStatus(
	ctx context.Context,
	run core.AgentRun,
) error {
	input, err := s.store.GetSlackInput(ctx, run.SourceID)
	if err != nil {
		return err
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		return err
	}
	if err := s.clearWatchPendingStatus(ctx, input, state); err != nil {
		return err
	}
	state.PendingStatusSet = false
	state.PendingStatusAt = 0
	state.RuleAcknowledged = false
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return s.store.SetAgentRunContext(ctx, run.ID, contextJSON)
}

func terminalStructuredCorrection(attempt, maximum int) bool {
	return terminalAttempt(attempt, maximum)
}

func consumeWatchStructuredCorrection(state *decisionpkg.WatchTurnState, maximum int) bool {
	state.StructuredCorrections++
	return terminalStructuredCorrection(state.StructuredCorrections, maximum)
}

func blockedWatchContinuation(
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	reason string,
	prior *decisionpkg.WatchDecision,
) decisionpkg.WatchDecision {
	decision := decisionpkg.WatchDecision{}
	if prior != nil {
		decision.Evidence = prior.Evidence
		decision.Coverage = prior.Coverage
		decision.Memory = prior.Memory
	}
	finalAttempt := state.RecheckAttempt >= 2
	if input.Kind == "bot_message" && !finalAttempt {
		decision.Action = "ignore"
	} else {
		decision.Action = "reply"
		decision.Message = "I couldn't finish this check safely yet. I saved the evidence and kept the investigation open for a clean retry."
	}
	completion := &completionAssessment{
		Status:       "blocked",
		Summary:      "The host could not validate the final structured result.",
		MaterialGaps: []string{decisionpkg.BoundedField(reason, 500)},
		BlockerKind:  "tool_failure",
		Attempts:     []string{"Responder validated the result and requested a corrected completion."},
		NextAction:   "Retry the same investigation from its saved evidence.",
	}
	if !finalAttempt {
		completion.Recheck = &investigation.RecheckDirective{
			Key: "structured:" + run.ID, Reason: "Retry structured completion after host validation.",
			AfterSeconds: 60, AdditionalAttempts: 2,
		}
	}
	decision.Completion = completion
	return decision
}

func blockedAgentContinuation(reason string, prior *decisionpkg.AgentReport) decisionpkg.AgentReport {
	report := decisionpkg.AgentReport{
		Message: "I couldn't finish this check safely yet. The evidence is saved in this task, so it can continue without starting over.",
		Completion: &completionAssessment{
			Status:       "blocked",
			Summary:      "The host could not validate the final structured result.",
			MaterialGaps: []string{decisionpkg.BoundedField(reason, 500)},
			BlockerKind:  "tool_failure",
			Attempts:     []string{"Responder validated the result and requested a corrected completion."},
			NextAction:   "Continue the same task from its saved evidence.",
		},
	}
	if prior != nil {
		report.Evidence = prior.Evidence
		report.Coverage = prior.Coverage
		report.Memory = prior.Memory
	}
	return report
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
		sessionChannelID = core.FirstNonempty(state.SessionChannelID, run.ChannelID)
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

func missingCoopImageFailure(turn coop.Turn) bool {
	return turn.ErrorCode == "acp_process_error" && strings.Contains(
		strings.ToLower(strings.TrimSpace(turn.ErrorDetail)),
		"coop box image is not built",
	)
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
	if decisionpkg.StructuredResultFailure(run.LastError) {
		return `

<host-structured-correction>
The previous turn completed its work, but Responder rejected only its final structured report.
Preserve the work and verified result. Return a corrected report that fixes this exact host validation
error: ` + decisionpkg.BoundedField(trimError(errors.New(run.LastError)), 1200) + `
Do not repeat the investigation or drop completed work merely to repair the response envelope.
</host-structured-correction>`
	}
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
	state *decisionpkg.WatchTurnState,
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
	state.PendingStatusAt = s.now().Unix()
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return s.store.SetAgentRunContext(ctx, run.ID, contextJSON)
}

func watchRunStatusThread(input core.SlackInput, state decisionpkg.WatchTurnState) string {
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
		s.queueDelay(attempt),
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
		"Reported detail: `" + decisionpkg.BoundedField(trimError(cause), 1200) + "`"
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
			s.audit(ctx, core.AuditEvent{
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
		s.audit(ctx, core.AuditEvent{
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
		detail := strings.TrimSpace(core.FirstNonempty(run.LastError, run.TerminalState))
		if err := s.finishTriageRunFailure(ctx, run, input, state, detail); err != nil {
			return err
		}
		return s.store.FinishAgentRun(ctx, run.ID)
	}
	if input.Kind == "bot_message" && strings.HasPrefix(run.ConversationKey, "operation:") {
		newer, newerErr := s.store.HasNewerAgentRun(ctx, run)
		if newerErr != nil {
			return newerErr
		}
		if !newer {
			newer, newerErr = s.store.HasNewerOperationalAgentRun(
				ctx, run, operationalBurstWindow, false,
			)
			if newerErr != nil {
				return newerErr
			}
		}
		if newer {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "coalesced",
				Detail:  "suppressed a stale result because a newer operational update is queued",
			})
			if err := s.store.SetWorkEpisodePhase(
				ctx, run.ID, core.EpisodeSuperseded, "finished",
				"Superseded by a newer operational update", "", time.Time{},
			); err != nil {
				return err
			}
			return s.store.FinishAgentRun(ctx, run.ID)
		}
	}
	decision, err := decisionpkg.ParseWatchDecision(string(run.Result), s.now())
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
			decision = decisionpkg.StandingRuleIncidentAsReply(decision, alertPolicy == "offer")
		}
	}
	if isPrivateSlackVerificationReplay(input) {
		if err := s.persistPrivateReplayKnowledge(ctx, input, state, decision.Memory); err != nil {
			return err
		}
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.replay", ActorID: input.UserID, ObjectID: input.ID,
			Outcome: "verified_private", Detail: decision.Action,
		})
		if err := s.store.SetWorkEpisodePhase(
			ctx, run.ID, core.EpisodeCompleted, "finished", "Verified privately", "", time.Time{},
		); err != nil {
			return err
		}
		return s.store.FinishAgentRun(ctx, run.ID)
	}
	if err := s.recordFeedbackOperations(
		ctx, run, input, state, decision.AppliedOperations,
	); err != nil {
		return err
	}
	if err := s.applyWatchDecision(ctx, input, state, decision, run.EpisodeID); err != nil {
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
		decision.AppliedOperations,
	)
	if err := s.store.SetWorkEpisodePhase(
		ctx, run.ID, episodeState, phase, status, nextAction, time.Time{},
	); err != nil {
		return err
	}
	return s.store.FinishAgentRun(ctx, run.ID)
}

func (s *Service) persistPrivateReplayKnowledge(
	ctx context.Context,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	memory core.AgentMemory,
) error {
	knowledge := recall.SanitizeKnowledge(memory.Knowledge)
	if len(knowledge) == 0 {
		return nil
	}
	merged := core.AgentMemory{Knowledge: knowledge}
	existing, err := s.store.GetConversationMemory(ctx, input.ChannelID, input.ThreadTS)
	if err == nil {
		merged = memorypkg.MergeAgentMemories([]core.AgentMemory{existing.State, merged})
	} else if !errors.Is(err, store.ErrNotFound) {
		return err
	}
	return s.store.UpsertConversationMemoryState(ctx, core.ConversationMemory{
		ChannelID:   input.ChannelID,
		ThreadTS:    input.ThreadTS,
		Repository:  state.Repository,
		LastMessage: input.MessageTS,
		State:       merged,
	})
}

// reportTurnFailure builds the message an operator sees when a turn did not
// complete, and records it on the incident timeline.
//
// A structured failure is reported verbatim because the model already phrased
// it for a person. Anything else goes through provider.Classify, which turns a
// transport or quota error into what the operator can actually do about it —
// the raw text is almost never actionable on its own.
func (s *Service) reportTurnFailure(
	ctx context.Context,
	run core.AgentRun,
	incident core.Incident,
	state string,
	detail string,
) slackui.Message {
	message := slackui.AgentReportFailureMessage(detail)
	if !decisionpkg.StructuredResultFailure(detail) {
		failure := provider.Classify(detail)
		message = slackui.TurnFailureMessage(
			state,
			failure.Summary+"\n\nReported detail: `"+detail+"`\n\n"+failure.OperatorFix,
		)
	}
	s.recordTimeline(ctx, core.TimelineEvent{
		ID:         "tl_agent_failure_" + run.ID,
		IncidentID: incident.ID, ChannelID: incident.ChannelID,
		Kind: "agent.failure", ActorID: "responder",
		Title: "Agent turn " + state, Detail: detail,
	})
	return message
}

// recordProposalExecution closes out the proposal this run was executing. The
// error is deliberately ignored: the run itself already succeeded or failed,
// and refusing to finalize it because a bookkeeping write failed would leave
// the operator with no answer at all.
func (s *Service) recordProposalExecution(
	ctx context.Context,
	run core.AgentRun,
	state string,
	detail string,
) {
	proposalState := "failed"
	if state == "completed" {
		proposalState = "finished"
	}
	result := s.sanitizeText(core.FirstNonempty(string(run.Result), detail))
	_ = s.store.MarkProposalExecution(ctx, run.SourceID, proposalState, run.CoopTurnID, result)
}

// withEngineeringTaskChanges marks an engineering task's published diff stale
// when this turn actually changed the working tree, and says so in the message.
//
// It compares against the fingerprint taken before the turn rather than asking
// whether the turn claimed to change anything: a model that says it edited
// nothing while leaving a dirty tree would otherwise leave a published diff
// that no longer matches the branch, which is the worst kind of wrong — it
// looks reviewed.
func (s *Service) withEngineeringTaskChanges(
	ctx context.Context,
	run core.AgentRun,
	incident core.Incident,
	state string,
	message slackui.Message,
) slackui.Message {
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		s.log.Warn(
			"inspect completed engineering task changes failed",
			"incident", incident.ID,
			"error", err,
		)
		return message
	}
	assembled, _ := decodeAssembledAgentContext(run.Context)
	if !engineeringTaskTurnCreatedChanges(assembled.InitialTaskChangesFingerprint, changes) {
		return message
	}
	publication, publicationErr := s.markTaskPublicationStale(ctx, incident)
	if publicationErr != nil {
		s.log.Error(
			"mark changed engineering task publication stale",
			"incident", incident.ID,
			"error", publicationErr,
		)
	}
	if state != "completed" {
		return message
	}
	return slackui.WithEngineeringTaskDelivery(message, incident, true, publication)
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
	detail := strings.TrimSpace(core.FirstNonempty(run.LastError, state))
	detail = s.sanitizeText(detail)
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
	var episodeOperations []investigation.ResultOperation
	var reportReplyParts []string
	if state == "completed" {
		report, structured, reportErr := decisionpkg.ParseAgentReport(string(run.Result))
		if reportErr != nil {
			s.log.Warn(
				"agent returned malformed structured response",
				"incident", incident.ID,
				"run", run.ID,
				"turn", run.CoopTurnID,
				"error", reportErr,
			)
			s.audit(ctx, core.AuditEvent{
				IncidentID: incident.ID, Kind: "agent.report",
				ObjectID: run.CoopTurnID, Outcome: "malformed",
				Detail: trimError(reportErr),
			})
			reportDetail := trimError(reportErr)
			reportDetail = s.sanitizeText(reportDetail)
			message = slackui.AgentReportFailureMessage(reportDetail)
			s.recordTimeline(ctx, core.TimelineEvent{
				ID:         "tl_agent_failure_" + run.ID,
				IncidentID: incident.ID, ChannelID: incident.ChannelID,
				Kind: "agent.failure", ActorID: "responder",
				Title:  "Agent result could not be rendered",
				Detail: decisionpkg.BoundedField(trimError(reportErr), 1000),
			})
		} else {
			episodeCompletion = report.Completion
			episodeOperations = report.AppliedOperations
			if conversation && s.cfg.IsOperator(conversationInput.UserID) {
				offers, acknowledgement, replaced := normalizedOffers(
					conversationInput,
					core.FirstNonempty(run.Repository, incident.Repository),
					operatorOffers{
						Memory:     report.MemoryOffer,
						Preference: report.PreferenceOffer,
						Rule:       report.RuleOffer,
						Schedule:   report.ScheduleOffer,
					},
				)
				report.MemoryOffer, report.PreferenceOffer = offers.Memory, offers.Preference
				report.RuleOffer, report.ScheduleOffer = offers.Rule, offers.Schedule
				if replaced {
					report.Message = acknowledgement
					report.Evidence = nil
					report.Coverage = nil
				}
			}
			if !structured {
				s.audit(ctx, core.AuditEvent{
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
			reportReplyParts = decisionpkg.ReplySequence(
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
			s.recordTimeline(ctx, core.TimelineEvent{
				ID:          "tl_agent_finding_" + run.ID,
				IncidentID:  incident.ID,
				ChannelID:   incident.ChannelID,
				Kind:        "agent.finding",
				ActorID:     "responder",
				Title:       "Investigation update",
				Detail:      decisionpkg.BoundedField(strings.Join(reportReplyParts, "\n\n"), 2000),
				EvidenceIDs: evidenceIDs,
			})
		}
	} else {
		message = s.reportTurnFailure(ctx, run, incident, state, detail)
	}
	if incident.IsEngineeringTask() {
		message = s.withEngineeringTaskChanges(ctx, run, incident, state, message)
	}
	if run.SourceKind == "proposal" {
		s.recordProposalExecution(ctx, run, state, detail)
	}
	baseDeliveryID := "out_run_" + run.ID
	if len(reportReplyParts) > 1 {
		for index, part := range reportReplyParts[:len(reportReplyParts)-1] {
			if err := s.enqueueEpisode(
				ctx,
				replySequenceDeliveryID(baseDeliveryID, index, len(reportReplyParts)),
				run.EpisodeID,
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
		if err := s.enqueueEpisode(
			ctx,
			deliveryID,
			run.EpisodeID,
			incident,
			"assistant",
			threadTS,
			message,
		); err != nil {
			return err
		}
	} else if err := s.enqueueGeneratedVisuals(
		ctx, deliveryID, incident.ID, run.EpisodeID, incident.ChannelID, threadTS,
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
			episodeOperations,
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
	state decisionpkg.WatchTurnState,
	detail string,
) error {
	message := slackui.Notice(watchFailureNotice(detail))
	if state.ApprovalContinuation {
		if err := s.postInputMessageAt(
			ctx,
			core.FirstNonempty(state.ReplyDeliveryID, "emisar_approval_failure_"+run.ID),
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
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
		Outcome: triageFailureOutcome(publish), Detail: detail,
	})
	return nil
}

func publishTriageFailure(input core.SlackInput, state decisionpkg.WatchTurnState) bool {
	return !isPrivateSlackVerificationReplay(input) && state.RecheckOriginRunID == "" &&
		(state.ApprovalContinuation || input.Kind != "bot_message")
}

func triageFailureOutcome(published bool) string {
	if published {
		return "failed"
	}
	return "failed_suppressed"
}
