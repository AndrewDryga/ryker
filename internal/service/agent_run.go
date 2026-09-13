package service

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/ryker/internal/agentcontext"
	"github.com/AndrewDryga/ryker/internal/agentpreparation"
	"github.com/AndrewDryga/ryker/internal/agentprompt"
	"github.com/AndrewDryga/ryker/internal/alertstream"
	attentionpkg "github.com/AndrewDryga/ryker/internal/attention"
	"github.com/AndrewDryga/ryker/internal/behaviorrequired"
	"github.com/AndrewDryga/ryker/internal/changeledger"
	"github.com/AndrewDryga/ryker/internal/channelparticipation"
	"github.com/AndrewDryga/ryker/internal/completionpolicy"
	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	episodepkg "github.com/AndrewDryga/ryker/internal/episode"
	"github.com/AndrewDryga/ryker/internal/fanout"
	"github.com/AndrewDryga/ryker/internal/incidentrun"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/lifecycle"
	"github.com/AndrewDryga/ryker/internal/liveturn"
	memorypkg "github.com/AndrewDryga/ryker/internal/memory"
	"github.com/AndrewDryga/ryker/internal/mentioncontext"
	"github.com/AndrewDryga/ryker/internal/openquestions"
	"github.com/AndrewDryga/ryker/internal/operatorchoice"
	operatorofferspkg "github.com/AndrewDryga/ryker/internal/operatoroffers"
	"github.com/AndrewDryga/ryker/internal/preparationnotice"
	"github.com/AndrewDryga/ryker/internal/promptbudget"
	"github.com/AndrewDryga/ryker/internal/provider"
	"github.com/AndrewDryga/ryker/internal/publicationcontext"
	"github.com/AndrewDryga/ryker/internal/recall"
	"github.com/AndrewDryga/ryker/internal/recheckorigin"
	"github.com/AndrewDryga/ryker/internal/remediation"
	"github.com/AndrewDryga/ryker/internal/repositorycapability"
	"github.com/AndrewDryga/ryker/internal/resultrecovery"
	"github.com/AndrewDryga/ryker/internal/resultwire"
	"github.com/AndrewDryga/ryker/internal/retrydelay"
	"github.com/AndrewDryga/ryker/internal/runreplay"
	schedulepkg "github.com/AndrewDryga/ryker/internal/schedule"
	"github.com/AndrewDryga/ryker/internal/schedulecontext"
	scheduleofferpkg "github.com/AndrewDryga/ryker/internal/scheduleoffer"
	"github.com/AndrewDryga/ryker/internal/semanticvalidation"
	"github.com/AndrewDryga/ryker/internal/sessionauthority"
	"github.com/AndrewDryga/ryker/internal/sessioncreate"
	"github.com/AndrewDryga/ryker/internal/slackfile"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/standingrule"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/AndrewDryga/ryker/internal/taskcard"
	"github.com/AndrewDryga/ryker/internal/taskcompletion"
	"github.com/AndrewDryga/ryker/internal/taskcontract"
	"github.com/AndrewDryga/ryker/internal/taskofferrejection"
	"github.com/AndrewDryga/ryker/internal/taskpr"
	"github.com/AndrewDryga/ryker/internal/taskpublication"
	"github.com/AndrewDryga/ryker/internal/terraformwakeup"
	"github.com/AndrewDryga/ryker/internal/triageoutcome"
	"github.com/AndrewDryga/ryker/internal/turncapacity"
	"github.com/AndrewDryga/ryker/internal/turndelta"
	"github.com/AndrewDryga/ryker/internal/watchpresence"
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

func prefixedPrompt(value string) string {
	if strings.TrimSpace(value) == "" {
		return ""
	}
	return "\n\n" + value
}

func (s *Service) queueWatchedInput(ctx context.Context, input core.SlackInput) error {
	state, resumed, err := s.resumeLegacyWatchedTurn(ctx, input)
	if err != nil || resumed {
		return err
	}
	if mentioncontext.IsBareMention(input, s.identity.BotUserID) {
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
					"",
					input.ChannelID,
					slackReplyThread(input),
					watchPendingStatus,
					slackui.WatchProgressSteps(),
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
		if input.ThreadTS == "" {
			resolved, found, err := mentioncontext.Resolve(
				ctx, input, s.identity.BotUserID, s.cfg.Slack.WatchContext, s.recentMessages,
			)
			if err != nil {
				return fmt.Errorf("resolve the request before a bare mention: %w", err)
			}
			// A bare mention the carry cannot resolve still queues a model run:
			// the triage run reads the recent channel messages, so the model
			// decides what the mention meant. On 2026-08-13 an operator answered
			// the bot's own "reply in this thread to try again" notice with a
			// bare @Emisar twelve minutes later; the carry cannot bind a bot
			// message or reach past five minutes, and the host replied "What
			// should I check?" beneath the notice that already said what to check.
			if found {
				state.ResolvedMentionRequest = &resolved
				input = mentioncontext.Apply(input, state.ResolvedMentionRequest)
				s.audit(ctx, core.AuditEvent{
					Kind: "slack.input", ActorID: input.UserID, ObjectID: input.ID,
					Outcome: "resolved_previous_message",
					Detail:  "bare mention applied to the immediately preceding message " + resolved.MessageTS,
				})
			}
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
	if !state.ReferenceCaptured {
		if err := s.captureSlackPermalinkReference(ctx, input, &state); err != nil {
			return fmt.Errorf("capture linked Slack context: %w", err)
		}
		state.ReferenceCaptured = true
	}
	readyAt, err := s.watchRunReadyAt(ctx, input)
	if err != nil {
		return err
	}
	conversationKey, episode, resumeEpisode, err := recheckorigin.ResolveOrCorrelate(
		ctx, s.store, &state, input, watchConversationKey(input), s.correlateWatchEpisode,
	)
	if state.SessionChannelID == "" {
		state.SessionChannelID = operationalWatchSessionChannelID(
			input, conversationKey, s.cfg.Limits.BackgroundWorkers,
		)
	}
	if err != nil {
		return err
	}
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return err
	}
	candidate := core.AgentRun{
		Mode:            core.AgentRunTriage,
		ChannelID:       input.ChannelID,
		ThreadTS:        state.ResponseThreadTS,
		ConversationKey: conversationKey,
		SourceKind:      "watch",
		SourceID:        input.ID,
		UserID:          input.UserID,
		Context:         contextJSON,
		NextAttemptAt:   readyAt,
		CommitmentTitle: episodepkg.ObjectiveForSlackInput(input),
		Episode:         episode,
	}
	var run core.AgentRun
	var created bool
	if resumeEpisode {
		run, created, err = s.store.QueueEpisodeAttempt(ctx, episode.ID, candidate)
	} else {
		run, created, err = s.store.QueueAgentRun(ctx, candidate)
	}
	if err != nil {
		return fmt.Errorf("queue watched agent run: %w", err)
	}
	if created && watchInputWantsPendingStatus(input, state) && s.cfg.Slack.NativeStatus {
		if err := s.ensureWatchRunPendingStatus(ctx, run, input, &state); err != nil {
			s.log.Warn("set queued watched Slack status", "input", input.ID, "episode", run.EpisodeID, "error", err)
		}
		contextJSON, err = json.Marshal(state)
		if err != nil {
			return err
		}
	}
	// QueueAgentRun is idempotent by Slack input. Persist facts captured before
	// queueing even when this input already had a run, otherwise a retry can
	// evaluate the same standing rules and add the acknowledgement twice.
	if len(run.Context) > 0 && string(run.Context) != string(contextJSON) {
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
			memory, memoryErr := s.store.Intelligence.GetChannelMemory(
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
				CommitmentTitle: episodepkg.ObjectiveForSlackInput(input),
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
// is responding to partway through, which reads to an operator as Ryker
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
			publications, err := s.store.PublicationFollowups.ListActiveContexts(
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
	if !state.ScheduledTasksCaptured && schedulepkg.ExplicitScheduleRequest(input.Text) {
		tasks, err := schedulecontext.Capture(
			ctx, s.store.Schedules, input, s.cfg.IsOperator(input.UserID), true,
		)
		if err != nil {
			return fmt.Errorf("list existing scheduled tasks for watched input: %w", err)
		}
		state.ScheduledTasks = tasks
		state.ScheduledTasksCaptured = true
	}
	if !isPrivateSlackVerificationReplay(input) &&
		!state.RuleEvaluationCaptured && standingrule.EvaluationEligible(input) {
		shadow, err := s.watchDecisionShadowed(ctx, input, *state)
		if err != nil {
			return err
		}
		acknowledgement, err := s.recordStandingRuleEvaluation(
			ctx, input, state.MatchedRules, !shadow,
		)
		if err != nil {
			return err
		}
		state.RuleAcknowledgement = acknowledgement
		state.RuleAcknowledged = state.RuleAcknowledgement != ""
		state.RuleEvaluationCaptured = true
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
// delay lets a person finish a thought before Ryker answers half of it.
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

func (s *Service) correlateWatchEpisode(
	ctx context.Context,
	input core.SlackInput,
	conversationKey string,
	state *decisionpkg.WatchTurnState,
) (*core.WorkEpisode, bool, error) {
	operationalLifecycle := input.Kind == "bot_message" &&
		strings.HasPrefix(conversationKey, "operation:")
	if operationalLifecycle {
		// Bind the episode before the model finishes. A recovery can arrive while
		// the firing investigation is still running; without an early binding the
		// only durable destination is the later recovery notification's thread.
		state.ResponseThreadTS = slackReplyThread(input)
	}
	episode := s.episodeForWatchedInput(input, *state)
	preferredWaitingThread := episodepkg.PreferredWaitingThread(input, state.ResponseThreadTS, operationalLifecycle)
	if previous, previousErr := s.store.GetLatestWorkEpisodeByConversationKey(
		ctx, conversationKey, preferredWaitingThread,
	); previousErr == nil {
		if operationalLifecycle && !strings.HasPrefix(input.EnvelopeID, "replay-public:") {
			expiredRecovery, err := s.store.AlertStream.RecoveredCycleExpired(ctx, conversationKey, input, s.cfg.Slack.AlertStreamOpenWindow.Duration)
			if err != nil {
				return nil, false, err
			}
			// Updates share an active unit of work. Once that unit is terminal, the
			// next alert is new accepted work linked to the prior investigation;
			// attaching it to the old episode makes the lifecycle guard cancel it.
			if episodepkg.Terminal(previous.State) || expiredRecovery {
				episode.ParentEpisodeID = previous.ID
				episode.Conversation = core.ConversationRef{
					Platform: "slack", ChannelID: input.ChannelID,
					ThreadTS: slackReplyThread(input), AnchorTS: input.ID,
					Visibility: "channel",
				}
				// A terminal row can still be the recent firing/recovery stream.
				// Keep that stream in its accepted thread through the hold window;
				// after the window, the new card becomes the new destination while
				// the parent link preserves history.
				withinHold := !expiredRecovery && (previous.CompletedAt.IsZero() ||
					input.ReceivedAt.Before(previous.CompletedAt.Add(
						s.cfg.Slack.AlertStreamOpenWindow.Duration,
					)))
				if withinHold && !isSlackVerificationReplay(input) && previous.Destination.ChannelID == input.ChannelID &&
					previous.Destination.ThreadTS != "" {
					episode.Destination = previous.Destination
					state.ResponseThreadTS = previous.Destination.ThreadTS
				}
			} else {
				episode.ID = previous.ID
				if previous.Destination.ChannelID == input.ChannelID &&
					previous.Destination.ThreadTS != "" {
					state.ResponseThreadTS = previous.Destination.ThreadTS
				}
			}
			// What this stream already told the channel, so the next card can be
			// judged against it instead of arriving as if it were the first.
			if !expiredRecovery {
				if err := s.captureAnsweredStream(ctx, previous, state); err != nil {
					return nil, false, err
				}
			}
		} else {
			if episodepkg.AcceptsOperatorAnswer(
				previous, input, state.ResponseThreadTS, state.ConversationFollowup,
			) {
				state.ConversationFollowup = true
				episode = &previous
				if previous.Destination.ThreadTS != "" {
					state.ResponseThreadTS = previous.Destination.ThreadTS
				}
				return episode, true, nil
			}
			episode.ParentEpisodeID = previous.ID
			taskcontract.InheritParent(episode, previous)
		}
	} else if !errors.Is(previousErr, store.ErrNotFound) {
		return nil, false, previousErr
	} else if input.Kind == "bot_message" {
		previous, operationalErr := s.store.GetLatestOperationalWorkEpisode(
			ctx, input.ChannelID, input.UserID, input.ReceivedAt.Add(-30*time.Minute),
		)
		if operationalErr == nil {
			episode.ParentEpisodeID = previous.ID
		} else if !errors.Is(operationalErr, store.ErrNotFound) {
			return nil, false, operationalErr
		}
	}
	return episode, false, nil
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
		if _, err := s.store.Behavior.RecordStandingRuleRun(
			ctx, rule.ID, input.ID, input.EventID, "ignore",
		); err != nil {
			return err
		}
	}
	if !isPrivateSlackVerificationReplay(input) {
		shadow, err := s.shadowEnabled(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		visible, err := channelparticipation.LifecyclePresenceVisible(
			ctx, s.store, watchConversationKey(input), shadow,
		)
		if err != nil {
			return err
		}
		phase := externalMessageLifecyclePhase(input.Text)
		acknowledgement, err := s.recordStandingRuleEvaluation(
			ctx,
			input,
			rules,
			visible && (phase == externalLifecycleCreated || phase == externalLifecyclePlanning),
		)
		if err != nil {
			return err
		}
		if visible {
			if err := watchpresence.FinishHandled(
				ctx, unpacedSlack(s.slack), input.ChannelID, input.MessageTS, acknowledgement,
			); err != nil && s.log != nil {
				s.log.Warn("mark handled external lifecycle card", "input", input.ID, "error", err)
			}
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
		CommitmentTitle: episodepkg.ObjectiveForSlackInput(input),
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
func watchInputWantsPendingStatus(
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
) bool {
	return !isPrivateSlackVerificationReplay(input) &&
		input.Kind != "recheck" && slackReplyThread(input) != "" &&
		(decisionpkg.WatchInputTargeted(input, state) ||
			decisionpkg.RequestedConversationLocation(input.Text) != decisionpkg.ConversationLocationFollow)
}

func watchConversationKey(input core.SlackInput) string {
	if input.Kind == "bot_message" {
		if key := OperationalCorrelationKey(input); key != "" {
			return "operation:" + input.ChannelID + ":" + key
		}
	}
	return "channel:" + input.ChannelID
}

// operationalWatchSessionChannelID gives each independent alert stream its
// own model conversation. The worker pool still bounds execution concurrency;
// sharing a conversation is not required to enforce that limit.
//
// FIRING and RESOLVED for one occurrence retain the same conversation key.
// Another incident receives another key and cannot inherit the first one's
// unstructured model history, even when both came from one generic alert rule.
func operationalWatchSessionChannelID(
	input core.SlackInput,
	conversationKey string,
	_ int,
) string {
	if input.Kind != "bot_message" ||
		!strings.HasPrefix(conversationKey, "operation:") {
		return ""
	}
	sum := sha256.Sum256([]byte(conversationKey))
	return fmt.Sprintf("watch-shard:%s:%x", input.ChannelID, sum[:8])
}

func watchDecisionResponseThread(
	conversationKey string,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	episodeID string,
) string {
	if input.Kind == "bot_message" &&
		operationalLifecycleConversationKey(conversationKey) &&
		episodeID != "" && state.ResponseThreadTS != "" {
		// Correlated lifecycle events keep the destination chosen by the first
		// event. This makes FIRING -> RESOLVED read as one investigation instead
		// of leaving the answer under the recovery notification.
		return state.ResponseThreadTS
	}
	if input.Kind == "bot_message" || input.Kind == "shortcut" ||
		len(state.MatchedRules) > 0 {
		return slackReplyThread(input)
	}
	return state.ResponseThreadTS
}

func operationalLifecycleConversationKey(conversationKey string) bool {
	return strings.HasPrefix(conversationKey, "operation:") &&
		(strings.Contains(conversationKey, ":alert:") ||
			strings.Contains(conversationKey, ":alert-link:") ||
			strings.Contains(conversationKey, ":lifecycle:link:"))
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
	if err := agentpreparation.Recover(
		ctx, s.store, s.now(), s.cfg.Limits.WorkerStallAfter.Duration, s.log,
	); err != nil {
		return err
	}
	run, err := s.store.LeaseAgentRun(ctx)
	if err != nil {
		return err
	}
	runCtx, release := ctx, func() {}
	if s.runCancels != nil {
		runCtx, release = s.runCancels.Track(ctx, run.ID, run.IdempotencyKey)
	}
	defer release()
	current, err := s.store.GetAgentRun(runCtx, run.ID)
	if err != nil {
		if errors.Is(err, context.Canceled) && s.agentRunCancellationApplied(ctx, run.ID) {
			return nil
		}
		return err
	}
	if current.State == core.AgentRunCancelled {
		return nil
	}
	var processErr error
	switch run.Mode {
	case core.AgentRunTriage:
		processErr = s.prepareTriageAgentRun(runCtx, run)
	case core.AgentRunIncident, core.AgentRunEngineeringTask:
		processErr = s.prepareIncidentAgentRun(runCtx, run)
	default:
		_, err := s.store.RetryAgentRunIfOwned(runCtx, run.ID,
			"unsupported agent run mode "+string(run.Mode), s.now(), true)
		processErr = err
	}
	if errors.Is(runCtx.Err(), context.Canceled) && s.agentRunCancellationApplied(ctx, run.ID) {
		return nil
	}
	return processErr
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
	// Before the session is read and any turn is submitted. An engineering task
	// that forks a fortnight-old checkout writes its patch against code that
	// has moved, and the reviewer finds out at rebase time.
	s.refreshRepositoryForTurn(ctx, incident.Repository)
	// A branch investigates in a fork of its own. The incident's session and its
	// single active turn belong to the lead, and a branch that borrowed them
	// would share one transcript with every sibling. The lead lane still guards
	// the empty binding before Coop is asked anything: LeaseAgentRun will not
	// hand out a run whose incident has no session, so reaching here without
	// one means the binding went away between the lease and this read — and the
	// previous shape fell straight into GetSession(""), an opaque transport
	// error that sent whoever read the log to debug a service that was never
	// asked anything.
	session, sessionGeneration, rotated, err := incidentrun.ResolveSession(
		ctx, run, incident, s.coop, s.branches, s.store.IncidentSessions, s.now(),
	)
	if err != nil {
		branchPreparation := fanout.IsBranch(run.ConversationKey) &&
			(coop.Retryable(err) || errors.Is(err, sessioncreate.ErrReadOnlyAuthority) ||
				errors.Is(err, sessioncreate.ErrHistoricalCreateKeys) ||
				errors.Is(err, sessionauthority.ErrConvergence))
		if branchPreparation {
			detail := sessioncreate.Status(incident.Repository, err)
			retryAt := s.now().Add(30 * time.Second)
			if errors.Is(err, sessioncreate.ErrReadOnlyAuthority) ||
				errors.Is(err, sessioncreate.ErrHistoricalCreateKeys) {
				detail = trimError(err)
				retryAt = s.now().Add(30 * time.Minute)
			}
			return s.store.DeferAgentRun(ctx, run.ID, detail, retryAt, true)
		}
		if coop.Retryable(err) || errors.Is(err, sessionauthority.ErrConvergence) {
			detail := sessioncreate.Status(incident.Repository, err)
			s.setIncidentError(ctx, incident.ID, core.WorkflowHolding, detail)
			return s.store.DeferAgentRun(
				ctx, run.ID, detail, s.now().Add(30*time.Second),
			)
		}
		terminal := !coop.Retryable(err) &&
			!errors.Is(err, sessioncreate.ErrReadOnlyAuthority) &&
			!errors.Is(err, sessioncreate.ErrHistoricalCreateKeys) &&
			!errors.Is(err, sessionauthority.ErrConvergence)
		return s.retryIncidentAgentRun(ctx, run, incident, err, terminal)
	}
	if rotated {
		return s.store.DeferAgentRun(
			ctx, run.ID,
			incidentrun.RotationStatus(incident, session),
			s.now(),
		)
	}
	session, err = s.ensureTurnCapacity(
		ctx, incident.ChannelID, incident.ID, session,
	)
	if err != nil {
		var limitErr *turncapacity.LimitError
		if errors.As(err, &limitErr) {
			detail := turncapacity.Message(limitErr.Limit)
			s.setIncidentError(ctx, incident.ID, core.WorkflowBlocked, detail)
			return s.store.DeferAgentRun(
				ctx, run.ID, detail, s.now().Add(30*time.Second),
			)
		}
		detail := "Ryker could not allocate additional automatic session capacity: " +
			trimError(err) + ". The pending request and Coop session are preserved; " +
			"Ryker will retry after the Coop limit or service error is corrected."
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
	run.Repository = incident.Repository
	contextChanged := false
	if agentcontext.NeedsCapture(captured, assembled.Repository, incident.Repository) {
		// The firing alerts, for their labels. An alert that names its service
		// is the difference between the change ledger recalling that service's
		// deploys and recalling everything the repository ever shipped. A failed
		// read costs the scope its sharpest term and nothing else.
		signals, _ := s.store.ListSignals(ctx, incident.ID)
		assembled, err = s.assembleAgentContext(
			ctx,
			agentContextRequest{
				ChannelID: incident.ChannelID, Repository: incident.Repository,
				RepositoryPinned: true, AlertSignals: signals,
				OperatorID: run.UserID, SourceInputID: run.SourceID,
				// An escalated incident has no Slack message of its own to
				// recall against — the run is filed under the webhook event —
				// so its title and the alert's stable group key are what the
				// symptom is. An engineering task is deliberately left out:
				// past outages do not inform a code change.
				Effort:           incidentEffort(incident),
				AlertGroupKey:    incident.SourceIncidentID,
				RecallText:       incident.Title,
				ExcludeEpisodeID: run.EpisodeID,
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
			return s.retryIncidentAgentRun(ctx, run, incident,
				fmt.Errorf("capture engineering task changes before turn: %w", changesErr), false)
		} else {
			assembled.InitialTaskChangesFingerprint = taskcard.ChangesFingerprint(changes)
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
		sessionGeneration,
		incident.Repository,
		incident.CoopEventSequence,
		run.Context,
	); err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, false)
	}
	run.SessionID = session.ID
	run.CoopEventSequence = incident.CoopEventSequence
	promptSections := []promptbudget.Section{
		// First in the list is first to be dropped. Recalled history is the
		// only layer here that is about a different incident.
		{Name: similarPastEpisodesLayer, Text: prefixedPrompt(similarPastEpisodesPrompt(assembled.SimilarPastEpisodes)), Reason: droppedSimilarPastEpisodes},
		// Next out. Also about work other than this turn's, but it goes after
		// recalled history because an open task holding a committed change is
		// the one piece of history that can replace the work being planned.
		{Name: relatedTasksLayer, Text: prefixedPrompt(relatedTasksPrompt(assembled.RelatedTasks)), Reason: droppedRelatedTasks},
		// Second out, and for the same reason recalled history is first: this is
		// the only other layer that is not about the conversation being answered.
		// It goes before the channel transcript because a deploy an operator can
		// still look up themselves costs less to lose than the message the turn
		// is replying to.
		{Name: changeledger.Layer, Text: prefixedPrompt(changeledger.Prompt(assembled.RecentChanges)), Reason: changeledger.DroppedReason},
		{Name: "prior_operational_context", Text: prefixedPrompt(operationalMemoryPrompt(assembled.Prior)), Reason: "older operational memory was omitted to fit the turn"},
		{Name: "channel_situation", Text: prefixedPrompt(agentcontext.SituationPrompt(assembled.Situation)), Reason: "the compact channel situation was omitted to fit the turn"},
		{Name: "related_situations", Text: prefixedPrompt(relatedSituationsPrompt(assembled.RelatedSituations)), Reason: "related conversation summaries were omitted to fit the turn"},
	}
	episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
	if episodeErr != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, episodeErr, false)
	}
	requiredContext := prefixedPrompt(
		repositorySetPrompt(session, s.repositoryContentsForPrompt(ctx)),
	) + "\n\n" +
		WorkEpisodePrompt(episode) + s.episodeContinuityPrompt(ctx, episode) +
		agentprompt.ToolTransport()
	revision, err := s.store.FreezeAgentRunRevision(ctx, run.ID, session.Revision)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, true)
	}
	artifacts, unreadable, err := s.agentRunArtifacts(ctx, run)
	if err != nil {
		return s.retryIncidentAgentRun(
			ctx, run, incident, err, slackfile.PermanentInputError(err),
		)
	}
	// In the required tail, because a file the host refused is the one piece of
	// context that explains a gap in the answer, and a budget that dropped it
	// would leave the model reasoning about a screenshot it never received.
	requiredContext += unreadableAttachmentsPrompt(unreadable)
	provisionalPrompt := run.Prompt
	for _, section := range promptSections {
		provisionalPrompt += section.Text
	}
	provisionalPrompt += requiredContext + "\n\n" + StructuredResponseInstructions() +
		agentprompt.Continuation(run)
	artifacts, err = s.augmentAgentRunArtifacts(
		ctx,
		provisionalPrompt+"\n"+string(run.Context),
		artifacts,
	)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, false)
	}
	requiredTail := requiredContext + "\n\n" + StructuredResponseInstructions() +
		agentprompt.Continuation(run) + taskpr.ArtifactsPrompt(artifacts)
	submissionPrompt, omissions, err := assemblePrompt(
		coop.MaxPromptBytes, run.Prompt, requiredTail, promptSections...,
	)
	if err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident,
			fmt.Errorf("assemble complete engineering prompt: %w", err), true)
	}
	// Addressed by construction: an incident room and an engineering task are
	// work somebody opened, never a message Ryker noticed going past.
	if _, err := s.ensureAttemptContextManifest(
		ctx, run, session, config.SessionProfileFor(episode.Effort, episode.Authority, true),
		submissionPrompt, artifacts, omissions,
	); err != nil {
		return s.retryIncidentAgentRun(ctx, run, incident, err, false)
	}
	turn, _, err := s.submitTurnAtLadderFloor(
		ctx,
		run,
		session.ID,
		revision,
		submissionPrompt,
		artifacts,
	)
	if err != nil {
		// A revision conflict accepted no turn. Release the stale binding so the
		// accepted work retries with the shared session's current revision.
		if sessioncreate.RevisionConflict(err) {
			if releaseErr := s.store.ReleaseAgentRunRevision(ctx, run.ID); releaseErr != nil {
				return s.retryIncidentAgentRun(
					ctx, run, incident,
					fmt.Errorf("release stale Coop revision after conflict: %w", releaseErr),
					false,
				)
			}
			return s.store.DeferAgentRun(ctx, run.ID, trimError(err), s.now().Add(time.Second))
		}
		return s.retryIncidentAgentRun(ctx, run, incident, err, !coop.Retryable(err))
	}
	session, err = s.coop.GetSession(ctx, session.ID)
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

// agentRunNativeStatus is what the thread says Emisar is doing.
//
// The recorded stream answers first. Everything below it is a sentence about
// the kind of work rather than about this work — "is gathering and reconciling
// evidence…", refreshed every two minutes to say it again while 596 tool calls
// went past underneath — and the stream that would have said which call is the
// same one the card's window already reads.
//
// This is the only funnel: every driver that sets a running turn's status goes
// through here, so deriving at this one point changes what the status says
// without changing when it is written. The throttle, the coalescing and the
// generation are untouched, and no new caller was added.
func (s *Service) agentRunNativeStatus(ctx context.Context, run core.AgentRun) string {
	if tail, ok := s.turnActivityTail(ctx, run); ok {
		if status, derived := liveturn.Status(tail); derived {
			return status
		}
	}
	return s.agentRunPlannedStatus(ctx, run)
}

// turnActivityTail reads what a turn has narrated, for the two things the host
// says about a running turn: the thread status and its own checkin row.
//
// A failed read is not an error worth propagating. Both callers are composing a
// sentence they can already write without this, so the fallback is the sentence
// they would have written anyway — and a status write abandoned because the
// activity table was busy would be a worse outcome than a general one.
func (s *Service) turnActivityTail(
	ctx context.Context,
	run core.AgentRun,
) (core.AgentActivityTail, bool) {
	if run.EpisodeID == "" || s.store.Activity == nil {
		return core.AgentActivityTail{}, false
	}
	tail, err := s.store.Activity.TailForEpisode(ctx, run.EpisodeID, liveturn.WindowLines)
	if err != nil {
		s.log.Warn(
			"read the turn's interior for what the host says about it",
			"run", run.ID, "episode", run.EpisodeID, "error", trimError(err),
		)
		return core.AgentActivityTail{}, false
	}
	return tail, true
}

// agentRunPlannedStatus is the status from what the work is, for a turn that
// has not yet said what it is doing.
func (s *Service) agentRunPlannedStatus(ctx context.Context, run core.AgentRun) string {
	if value, err := s.store.GetWorkEpisodeByRun(ctx, run.ID); err == nil {
		if status := episodepkg.Project(value).NativeStatus; status != "" {
			return status
		}
	}
	if run.SourceKind == "slack" {
		if input, err := s.store.GetSlackInput(ctx, run.SourceID); err == nil {
			return episodepkg.ActivityNativeStatus(requestEpisodeActivity(input.Text))
		}
	}
	return "is investigating..."
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
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if errors.Is(cause, context.Canceled) {
		return s.store.DeferAgentRun(ctx, run.ID, trimError(cause), s.now().Add(time.Second))
	}
	if requeued, err := s.requeueIfRateLimited(ctx, run, cause); requeued {
		return err
	}
	if !terminal {
		terminal = retrydelay.Exhausted(
			run.Failures+1,
			s.cfg.Limits.MaxAgentRunAttempts,
		)
	}
	next := s.queueDelay(run.Failures + 1)
	if terminal {
		next = s.now()
	}
	applied, err := s.store.RetryAgentRunIfOwned(ctx, run.ID, trimError(cause), next, terminal)
	if err != nil {
		return err
	}
	if applied && terminal && incident.ID != "" {
		s.setIncidentError(
			ctx, incident.ID, core.WorkflowParked, trimError(cause),
		)
		s.clearNativeStatus(ctx, incident)
	}
	return nil
}

// freezeTriageContext captures the Slack context, continuity, and matched
// standing rules for a triage run exactly once. The capture flags make it
// idempotent, so a run that is retried after a restart reuses the context it
// was prepared with rather than silently re-reading a channel that has moved
// on.
func (s *Service) freezeTriageContext(
	ctx context.Context,
	run core.AgentRun,
	state *decisionpkg.WatchTurnState,
	input core.SlackInput,
) error {
	if !state.ContextCaptured || !state.PriorCaptured {
		// The episode's own effort contract, read rather than re-derived: it is
		// what decides whether this turn is entitled to recall past outcomes,
		// and admission already committed to one.
		episode, err := s.store.GetWorkEpisodeByRun(ctx, run.ID)
		if err != nil {
			return err
		}
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
				TargetInput:         &input,
				ReferencedChannelID: state.ReferencedChannelID,
				ReferencedThreadTS:  state.ReferencedThreadTS,
				ReferencedMessageTS: state.ReferencedMessageTS,
				IncludeRecent:       true,
				Effort:              episode.Effort,
				ExcludeEpisodeID:    episode.ID,
			},
		)
		if err != nil {
			return err
		}
		state.RecentMessages = assembled.RecentMessages
		state.RemoveResolvedMentionDuplicate()
		state.ChannelAroundRoot = assembled.ChannelAroundRoot
		state.Memory = assembled.Situation
		state.RelatedSituations = assembled.RelatedSituations
		state.ReferencedThread = assembled.ReferencedThread
		state.Prior = assembled.Prior
		state.SimilarPastEpisodes = assembled.SimilarPastEpisodes
		state.RelatedTasks = assembled.RelatedTasks
		state.RecentChanges = assembled.RecentChanges
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

// dependencyWaitDelay is how long a run waits before looking again to see
// whether the previous turn in its Slack channel has finished.
//
// It used to be one second flat, which meant a run queued behind a long turn
// ran a three-statement transaction every second for as long as that turn
// lasted. Fixing the idempotency key stopped each of those polls appending an
// episode event, but the polls themselves stayed, and they are what fills the
// write-ahead logs: 4.2 MB on both deployments, which on emisar is a WAL the
// size of the entire database. The 4,632 waiting events recorded inside one
// hour are the same loop counted a different way.
//
// The delay is an eighth of the time already spent waiting. Below eight seconds
// that is the one-second floor, so the common case — a turn about to finish —
// keeps exactly the handoff it had and the queue feels no different. Above it
// the interval grows only for waits that are already long, where a few more
// seconds are a rounding error on the wait itself. Stated as a promise: a run
// resumes within an eighth of the time it has already been waiting.
//
// Fifteen seconds is the ceiling, so fifteen seconds is the worst case this
// adds to any handoff, and it is only reached after two minutes of waiting. A
// Coop turn runs for seconds to minutes, so a run that has waited two minutes
// is queued behind something long and will not notice. At the ceiling the
// transaction rate falls from 3,600 an hour to 240.
//
// Measured from when the run was queued, which is also true of a run put back
// by an operator retry or a recovery: those keep their original created_at, so
// they start at the ceiling rather than ramping up to it. That is the right
// answer for them — a retry of an old run is not the latency anyone is
// watching — and it is a consequence worth naming rather than discovering.
func (s *Service) prepareTriageAgentRun(ctx context.Context, run core.AgentRun) error {
	if isSessionHandoffRun(run) {
		return s.prepareSessionHandoffTurn(ctx, run)
	}
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
	input = mentioncontext.Apply(input, state.ResolvedMentionRequest)
	if state.SessionChannelID == "" {
		state.SessionChannelID = operationalWatchSessionChannelID(
			input, run.ConversationKey, s.cfg.Limits.BackgroundWorkers,
		)
	}
	if decided, err := s.admitTriageRun(ctx, run, input, &state); decided {
		return err
	}
	if err := s.freezeTriageContext(ctx, run, &state, input); err != nil {
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
	if state.SessionChannelID != "" && state.SessionChannelID != input.ChannelID {
		if err := s.store.Intelligence.EnsureChannelMemory(
			ctx, input.ChannelID,
			core.FirstNonempty(state.Repository, s.cfg.Slack.DefaultRepository),
		); err != nil {
			return s.retryAgentRun(ctx, run, err)
		}
	}
	if state.Lane == "" {
		state.Lane = triageoutcome.Lane(
			input, state, repository.ConversationPolicy != "", isSlackVerificationReplay(input),
			repositorycapability.AccessQuestion(input.Text),
		)
	}
	// Before the session, because a session forks the repository as it stands
	// at that moment. Bounded and non-blocking: a fetch that cannot finish
	// leaves the turn running against what is on disk, with the age recorded.
	s.refreshRepositoryForTurn(
		ctx, core.FirstNonempty(state.Repository, s.cfg.Slack.DefaultRepository),
	)
	resolved, err := s.resolveTriageSession(ctx, run, input, &state, repository)
	if err != nil {
		return err
	}
	session, repositoryKey := resolved.session, resolved.repositoryKey
	generation, eventSequence := resolved.generation, resolved.eventSequence
	if session.ActiveTurnID != "" {
		now := s.now()
		return s.store.DeferAgentRun(
			ctx,
			run.ID,
			"waiting for the previous agent run in this Slack channel",
			now.Add(retrydelay.DependencyWait(now.Sub(run.CreatedAt))),
		)
	}
	switch session.State {
	case "exhausted":
		session, err = s.ensureTurnCapacity(ctx, input.ChannelID, "", session)
		if err != nil {
			var limitErr *turncapacity.LimitError
			if errors.As(err, &limitErr) {
				return s.retryAtNextSessionGeneration(
					ctx, run, &state, generation, err,
				)
			}
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
	// Before the bind below overwrites run.SessionID and run.CoopEventSequence
	// with the projection's values, which is what makes the run's own cursor a
	// statement about a turn it delivered rather than a copy of where the
	// channel already was.
	standing := s.standingBriefing(ctx, run, session, generation, eventSequence, state)
	state.SessionID = session.ID
	state.Repository = repositoryKey
	state.Generation = generation
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	sessionChannelID := input.ChannelID
	if state.Lane != "conversation" {
		sessionChannelID = core.FirstNonempty(state.SessionChannelID, input.ChannelID)
	}
	if err := s.store.BindTriageAgentRunSession(
		ctx,
		run.ID,
		sessionChannelID,
		session.ID,
		generation,
		state.Lane == "conversation",
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
	artifacts, unreadable, err := s.agentRunArtifacts(ctx, run)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	// Assemble what follows the conversation context before the context itself,
	// so the context is budgeted against what actually remains rather than a
	// fixed guess. early is dropped when the conversation lane replaces the
	// head, exactly as before; late always survives.
	var early, late strings.Builder
	early.WriteString("\n\n" + repositorySetPrompt(session, s.repositoryContentsForPrompt(ctx)))
	if input.Kind == "bot_message" {
		early.WriteString("\n\n<operational-burst>\nThis is the newest app update in a bounded " +
			"operational burst. Reconcile every material app notice in the supplied recent " +
			"context before replying. Group notices only when evidence connects them; preserve " +
			"separate conclusions for unrelated services. Do not silently omit an older failure " +
			"merely because this update arrived later. Publish one concise, decision-useful update " +
			"for the burst rather than narrating each notification.\n</operational-burst>")
	}
	early.WriteString(appAlertPolicyPrompt(input.Kind, state.AlertPolicy))
	if state.ApprovalContinuation && strings.TrimSpace(run.Prompt) != "" {
		early.WriteString("\n\n<emisar-run-continuation>\n" + run.Prompt +
			"\n</emisar-run-continuation>")
	}
	if state.Lane != "conversation" {
		late.WriteString(turndelta.Escalation(boundedOperatorText(state.EscalationReason)))
	}
	late.WriteString("\n\n" + repositorycapability.Prompt(repositorycapability.Build(s.cfg, repositoryKey, session, repositorycapability.PinnedReadOnly)))
	late.WriteString(publicationcontext.ActivePrompt(state.ActivePublications))
	late.WriteString(schedulecontext.Prompt(state.ScheduledTasks))
	late.WriteString(includeWhen(input.Kind == "recheck" && strings.TrimSpace(state.FailureDetail) == "", hostRecheckPolicyText))
	late.WriteString(watchDecisionCorrectionPrompt(state.FailureDetail))
	// late, never early: early is what the conversation lane drops, and the
	// reason the answer cannot describe the screenshot has to survive that.
	late.WriteString(unreadableAttachmentsPrompt(unreadable))
	late.WriteString(alertstream.AnsweredPrompt(state))
	episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
	if episodeErr != nil {
		return s.retryAgentRun(ctx, run, episodeErr)
	}
	late.WriteString("\n\n" + WorkEpisodePrompt(episode))
	// The continuity block rides the triage path too, not just the incident
	// lane. A Slack follow-up creates a child episode here, and until this
	// line the parent's recorded evidence never reached it — the model
	// re-derived its own findings from a ten-row channel slice while the
	// ledger built to carry them went unread. The budget call below already
	// counts late, so the head shrinks to make room rather than overflowing.
	late.WriteString(s.episodeContinuityPrompt(ctx, episode))
	late.WriteString(agentprompt.ToolTransport())
	late.WriteString(agentprompt.Continuation(run))

	var prompt string
	var omissions []core.ContextOmission
	if state.Lane == "conversation" {
		prompt = s.conversationPrompt(
			input,
			s.identity.BotUserID,
			state.ConversationFollowup,
			state.RecentMessages,
			state.Memory,
			state.RelatedSituations,
			state.ReferencedThread,
			state.Prior,
			repositoryKey,
		) + late.String()
	} else {
		prompt, _ = s.watchPrompt(
			input,
			s.identity.BotUserID,
			state.ConversationFollowup,
			state.RecentMessages,
			state.ChannelAroundRoot,
			state.Memory,
			state.RelatedSituations,
			state.ReferencedThread,
			state.Prior,
			state.SimilarPastEpisodes,
			state.RelatedTasks,
			state.RecentChanges,
			core.FirstNonempty(repositoryKey, s.cfg.Slack.DefaultRepository),
			state.MatchedRules,
			WatchPromptBudget(early.Len()+late.Len()),
		)
		prompt += early.String() + late.String()
	}
	artifacts, err = s.augmentAgentRunArtifacts(
		ctx,
		prompt+"\n"+string(run.Context),
		artifacts,
	)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	artifactPrompt := taskpr.ArtifactsPrompt(artifacts)
	if state.Lane == "conversation" {
		prompt, omissions, err = s.boundedConversationPrompt(
			input, s.identity.BotUserID, state.ConversationFollowup,
			state.RecentMessages, state.Memory, state.RelatedSituations,
			state.ReferencedThread, state.Prior, repositoryKey,
			coop.MaxPromptBytes-len(late.String())-len(artifactPrompt),
		)
		if err != nil {
			return s.retryAgentRun(ctx, run, fmt.Errorf("assemble complete conversation prompt: %w", err))
		}
		prompt += late.String()
	} else {
		prompt, omissions = s.watchPrompt(
			input, s.identity.BotUserID, state.ConversationFollowup,
			state.RecentMessages, state.ChannelAroundRoot,
			state.Memory, state.RelatedSituations,
			state.ReferencedThread, state.Prior, state.SimilarPastEpisodes, state.RelatedTasks,
			state.RecentChanges,
			core.FirstNonempty(repositoryKey, s.cfg.Slack.DefaultRepository),
			state.MatchedRules,
			WatchPromptBudget(early.Len()+late.Len()+len(artifactPrompt)),
		)
		prompt += early.String() + late.String()
	}
	// The swap comes after the full prompt is assembled, so that every doubt in
	// standingBriefing lands on the prompt this function has always built,
	// byte for byte. It comes BEFORE the artifact check below because a delta
	// leaves room a briefing did not: measuring artifacts against a prompt that
	// is no longer being sent would drop a PR diff that fits, and tell the model
	// it was dropped to fit.
	if standing.Delta {
		prompt = s.deltaTurnPrompt(ctx, run, input, state, episode, standing)
		// Replaced, not appended. The omissions above describe layers the budget
		// loop trimmed out of a prompt that is no longer being sent, and
		// recording "the channel transcript was cut to fit the turn" against a
		// twelve-kilobyte message would send whoever reads that manifest looking
		// for a budget problem this turn never had. What this prompt actually
		// left out is the briefing, and it says which one.
		omissions = []core.ContextOmission{standingBriefingOmission(standing)}
	}
	// Artifacts are dropped as one unit rather than trimmed. A PR diff is the
	// only unbounded thing in the suffix, and half a diff is worse than none:
	// the model reads it as the whole change and reasons about the part it was
	// given. WatchPromptBudget already reserved room for it, but the reservation
	// floors at minimumWatchPromptBytes, so a suffix larger than the budget can
	// still push the assembled prompt past the ceiling.
	if len(prompt)+len(artifactPrompt) > coop.MaxPromptBytes && artifactPrompt != "" {
		omissions = append(omissions, core.DroppedContextLayer(
			"task_artifacts",
			"the attached artifacts were omitted to fit the turn",
		))
		artifacts, artifactPrompt = nil, ""
	}
	prompt += artifactPrompt
	if len(prompt) > coop.MaxPromptBytes {
		return s.retryAgentRun(ctx, run, errRequiredPromptTooLarge)
	}
	// Whether anyone addressed Ryker is the same question the conversation
	// lane was chosen on, asked again here because it is half the routing key:
	// an unaddressed turn is the watch lane, whichever lane record carries it.
	profile := config.SessionProfileFor(
		episode.Effort, episode.Authority, decisionpkg.WatchInputTargeted(input, state),
	)
	if _, err := s.ensureAttemptContextManifest(
		ctx, run, session, profile, prompt, artifacts, omissions,
	); err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	turn, _, err := s.submitTurnAtLadderFloor(
		ctx,
		run,
		session.ID,
		revision,
		prompt,
		artifacts,
	)
	if err != nil {
		recovered, bound := s.turnBoundToRunKey(ctx, run, session, err)
		if !bound {
			// A revision conflict says the session moved on while this run held
			// a number, and no turn was accepted. Replaying the same frozen
			// revision fails for the same reason every time, so the attempt
			// budget was spent proving that twenty times over. Release it and
			// let the next attempt read the session it is actually racing.
			if sessioncreate.RevisionConflict(err) {
				if releaseErr := s.store.ReleaseAgentRunRevision(ctx, run.ID); releaseErr != nil {
					s.log.Warn("release frozen Coop revision",
						"run", run.ID, "error", releaseErr)
				} else {
					return s.store.DeferAgentRun(ctx, run.ID, trimError(err), s.now().Add(time.Second))
				}
			}
			return s.retryAgentRun(ctx, run, err)
		}
		turn = recovered
	}
	if turn.ID == "" {
		return s.retryAgentRun(ctx, run, errors.New("Coop returned an empty agent turn ID"))
	}
	session, err = s.coop.GetSession(ctx, session.ID)
	if err != nil {
		return s.retryAgentRun(ctx, run, err)
	}
	if err := s.store.MarkTriageAgentRunSubmitted(
		ctx,
		run.ID,
		turn.ID,
		session.Revision,
		run.CoopEventSequence,
		state.Lane,
		preparationnotice.Prefix(run),
	); err != nil {
		return err
	}
	return nil
}

// turnBoundToRunKey resolves an idempotency conflict on turn submission by
// asking Coop what that key already owns.
//
// A 409 is not retryable, and Ryker read "not retryable" as "this work is
// finished" — it retired the session and failed the run without ever asking
// what the conflict referred to. But an idempotency conflict on a key the run
// owns has one likely cause: the submission reached Coop and its response did
// not reach us. The turn is running. Abandoning the run drops an alert whose
// investigation is at that moment underway.
//
// Only a conflict that resolves to this session's own submitted turn is
// recovered. An absent, failed, or mismatched operation falls through to the
// original error, because those are the cases where the key means something
// Ryker does not understand and guessing would bind the run to a stranger's
// turn.
func (s *Service) turnBoundToRunKey(
	ctx context.Context,
	run core.AgentRun,
	session coop.Session,
	cause error,
) (coop.Turn, bool) {
	if !sessioncreate.IdempotencyConflict(cause) {
		return coop.Turn{}, false
	}
	operation, err := s.coop.OperationByKey(ctx, run.IdempotencyKey)
	if err != nil || operation.Method != "SubmitTurn" ||
		operation.State != "succeeded" || operation.ResourceType != "turn" ||
		operation.ResourceID == "" {
		return coop.Turn{}, false
	}
	// Fetched through the session it must belong to, so a key that somehow
	// names a turn in another session cannot be adopted here.
	turn, err := s.coop.GetTurn(ctx, session.ID, operation.ResourceID)
	if err != nil || turn.ID == "" {
		return coop.Turn{}, false
	}
	s.log.Info(
		"recovered the Coop turn already bound to this run's idempotency key",
		"run", run.ID, "session", session.ID, "turn", turn.ID,
	)
	return turn, true
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
	if input.Kind == "message" && !isPrivateSlackVerificationReplay(input) &&
		len(state.MatchedRules) == 0 &&
		!state.ApprovalContinuation {
		// Only while this run has done nothing yet. Superseding rests on the
		// premise that a newer nearby message will carry the conversation, and
		// that premise holds for a run which has not started: nothing is lost
		// because nothing was produced.
		//
		// It fails for a run that has already attempted. A retry or a host
		// correction puts work back into pending, so an investigation into a
		// human-reported production failure — mid-retry, carrying everything it
		// had established — met the supersession check on its next lease and
		// was dropped for a follow-up like "this started around 3pm". The
		// successor inherits no obligation and is free to ignore, so the
		// failure went uninvestigated and nobody was told.
		//
		// The guard covers BOTH supersession branches. It was added to the
		// newer-pending-run branch below and never to this one, and on
		// 2026-08-14 the uncovered branch did exactly what the covered one used
		// to: an operator's "Give me link to it (and always do when you do
		// that)" — five provider-rate-limit attempts in — was superseded
		// because another person's unrelated chatter had been classified. The
		// operator got silence, then nudged with a bare mention and was asked
		// "What would you like me to check?"
		// Corrections count here even though they no longer count as failures.
		// This guard asks "has this run produced anything yet", and a run that
		// has been corrected has: it answered, and the host sent the answer
		// back. Reading failure_count alone once corrections left it would have
		// re-opened the exact hole the comment above describes, for the loop
		// that generates the most requeues of any kind.
		attempted := run.Failures > 0 || state.StructuredCorrections > 0
		alreadyClassified := false
		if !attempted {
			alreadyClassified, err = s.store.HasNewerWatchDecision(
				ctx, input.ChannelID, input.MessageTS,
			)
			if err != nil {
				return true, s.retryAgentRun(ctx, run, err)
			}
		}
		if alreadyClassified {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "superseded",
				Detail:  "a newer channel message was already classified",
			})
			if err := s.retireWatchRunPresence(ctx, run, input, state); err != nil {
				s.log.Warn("retire a superseded triage run's presence",
					"run", run.ID, "input", input.ID, "error", err)
			}
			return true, s.store.SupersedeAgentRun(
				ctx, run.ID, "a newer channel message was already classified",
			)
		}
		newer := false
		if !attempted {
			newer, err = s.store.HasNewerSubstantivePendingAgentRun(
				ctx, run, s.identity.BotUserID,
			)
			if err != nil {
				return true, s.retryAgentRun(ctx, run, err)
			}
		}
		if newer {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "superseded",
				Detail:  "a newer nearby channel message will carry the conversation context",
			})
			if err := s.retireWatchRunPresence(ctx, run, input, state); err != nil {
				s.log.Warn("retire a superseded triage run's presence",
					"run", run.ID, "input", input.ID, "error", err)
			}
			return true, s.store.SupersedeAgentRun(
				ctx,
				run.ID,
				"superseded by a newer nearby channel message",
			)
		}
	}
	if input.Kind == "bot_message" && !isPrivateSlackVerificationReplay(input) {
		// Asked before the session is resolved and the turn is built, because
		// the whole point is not to spend one. A card the stream has already
		// answered keeps the ✅ that says so — it was handled, and a card with
		// no mark at all reads as unseen from the channel.
		folded, why, err := s.foldedIntoAnsweredStream(ctx, run, input)
		if err != nil {
			return true, s.retryAgentRun(ctx, run, err)
		}
		if folded {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "answered_by_the_stream", Detail: why,
			})
			if err := s.retireWatchRunPresence(ctx, run, input, state); err != nil {
				s.log.Warn("retire a folded triage run's presence",
					"run", run.ID, "input", input.ID, "error", err)
			}
			s.markWatchInputAnswered(ctx, input)
			return true, s.store.SupersedeAgentRun(ctx, run.ID, why)
		}
		// The same guard the human branch above carries, for the same reason,
		// on the branch it was never applied to.
		//
		// Coalescing rests on "nothing is lost", and that premise holds only
		// for a run which has not started. A started run has spent tool calls
		// and correction rounds establishing what is wrong, and the newer card
		// is one more update about the same thing, not a reason to throw that
		// away — the successor starts from an empty briefing and inherits no
		// obligation to reach the same place.
		//
		// On 2026-08-16 Grafana posted seven cards for one Traefik memory alert
		// in ninety minutes. run_0404d3 was dropped at minute 15 for the
		// RESOLVED card with 47 tool calls and 5 correction rounds behind it,
		// and run_2376d1 at minute 7 for FIRING:3. The stream was investigated
		// for over an hour and never finished an investigation once.
		//
		// StartedAt is the boundary because it is set exactly at the transition
		// into running, when the turn is submitted, and is never cleared — the
		// same durable fact scripts/watchdog.sh reads to see a stalled run.
		attempted := run.Failures > 0 || state.StructuredCorrections > 0 ||
			!run.StartedAt.IsZero()
		newer := false
		if !attempted {
			var err error
			newer, err = s.store.HasNewerPendingAgentRun(ctx, run)
			if err != nil {
				return true, s.retryAgentRun(ctx, run, err)
			}
			if !newer && broadOperationalBurstCoalescingAllowed(input) {
				newer, err = s.store.HasNewerOperationalAgentRun(
					ctx, run, operationalBurstWindow, true,
				)
				if err != nil {
					return true, s.retryAgentRun(ctx, run, err)
				}
			}
		}
		if newer {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "coalesced",
				Detail:  "a newer update for the same operational stream will be investigated",
			})
			if err := s.retireWatchRunPresence(ctx, run, input, state); err != nil {
				s.log.Warn("retire a coalesced triage run's presence",
					"run", run.ID, "input", input.ID, "error", err)
			}
			return true, s.store.SupersedeAgentRun(
				ctx, run.ID, "coalesced into a newer operational update",
			)
		}
	}
	return false, nil
}

// retryAtNextSessionGeneration retries a run whose session could not be
// obtained, first recording the generation that failure implies. Without the
// bump the next attempt asks for the same session and fails the same way, so a
// broken session would retry until the run exhausted its budget.
//
// The generation only ever moves forward, and it is persisted before the retry:
// a crash between the two must not lose the fact that this generation is spent.
func (s *Service) retryAtNextSessionGeneration(
	ctx context.Context,
	run core.AgentRun,
	state *decisionpkg.WatchTurnState,
	observedGeneration int,
	cause error,
) error {
	contextJSON, generationAdvanced, limitReached, err := agentpreparation.AdvanceContext(
		state, observedGeneration, cause,
	)
	if err != nil {
		return err
	}
	// Session creation is preparation, not a model attempt. A retryable Coop
	// outage must not consume the ceiling and discard already-accepted work.
	if errors.Is(cause, sessioncreate.ErrReadOnlyAuthority) ||
		errors.Is(cause, sessioncreate.ErrHistoricalCreateKeys) {
		delay := 30 * time.Minute
		if errors.Is(cause, sessioncreate.ErrHistoricalCreateKeys) {
			delay = sessioncreate.HistoricalCreateKeysRetryDelay
		}
		if err := agentpreparation.DeferAndNotify(
			ctx, s.store, s.log, run.ID, contextJSON, trimError(cause),
			s.now().Add(delay), true,
			func(noticeCtx context.Context) error {
				return s.notifyRepositoryPreparationBlocked(noticeCtx, run, cause)
			},
		); err != nil {
			return err
		}
		s.parkWatchedStatus(ctx, run, "clear watched Slack status while workspace authority is repaired")
		return nil
	}
	if limitReached {
		return agentpreparation.Defer(
			ctx, s.store, run.ID, contextJSON,
			"opening a fresh model session after reaching the automatic request ceiling",
			s.now().Add(time.Second), false,
		)
	}
	if errors.Is(cause, sessionauthority.ErrConvergence) {
		now := s.now()
		return agentpreparation.Defer(
			ctx, s.store, run.ID, contextJSON, trimError(cause),
			now.Add(retrydelay.DependencyWait(now.Sub(run.CreatedAt))), true,
		)
	}
	if coop.Retryable(cause) {
		receiptCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		if requeued, err := s.requeueIfRateLimited(receiptCtx, run, cause); requeued {
			cancel()
			return err
		}
		cancel()
		return agentpreparation.DeferAndNotify(
			ctx, s.store, s.log, run.ID, contextJSON, trimError(cause),
			s.now().Add(agentpreparation.RetryDelay(cause)), true,
			func(noticeCtx context.Context) error {
				return s.notifyRepositoryPreparationBlocked(noticeCtx, run, cause)
			},
		)
	}
	if generationAdvanced {
		if err := agentpreparation.Persist(ctx, s.store, run.ID, contextJSON); err != nil {
			return err
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
		if err := s.store.Intelligence.EnsureChannelMemory(
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
				repository.SessionProfilePolicy(
					config.ProfileChat, repository.ConversationPolicy,
				),
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
		if !agentcontext.MemoryPresent(state.Memory) {
			state.Memory = memory.State
		}
	}
	return triageSessionBinding{session, repositoryKey, generation, eventSequence}, nil
}

// requeueIfRateLimited puts a run the provider refused back in the queue and
// reports whether it handled the failure.
//
// A refusal is the provider saying "not now", not the work being wrong. The
// answer is still coming, just later, so the run waits without spending an
// attempt and without anything being said in Slack — an error message for work
// that was never wrong is worse than a wait.
//
// This covers a spent quota as well as a rate limit. That distinction looked
// principled when only rate limits waited — a quota "does not recover on its
// own" — but the provider disagreed in practice: on 2026-08-07 codex reported
// "You have hit your usage limit ... try again at Aug 11th", which is a wait,
// not a failure. Every hour of that would otherwise have been an error message
// in Slack for work that was fine.
//
// Shared by both retry paths on purpose. Written twice it would eventually be
// true in one and not the other, and the symptom would be that rate limits are
// silent for conversations and noisy for incidents, which is the kind of
// inconsistency nobody reports as a bug.
// providerBackoff is how long to wait for each way a provider can refuse work,
// and being absent from it is what makes a failure real.
//
// A quota waits far longer than a rate limit because it recovers on a billing
// boundary rather than in a burst window; retrying every five minutes for days
// would be pointless load. Neither spends an attempt.
var providerBackoff = map[string]time.Duration{
	provider.KindRateLimit:  provider.RateLimitRetryDelay,
	provider.KindUsageLimit: provider.UsageLimitRetryDelay,
	// An unexplained refusal polls at the rate-limit interval: it is the
	// shortest of the causes it might be, and guessing long would delay
	// recovery from the one that clears fastest.
	provider.KindProviderRefused: provider.RateLimitRetryDelay,
}

func (s *Service) requeueIfRateLimited(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) (bool, error) {
	detail := trimError(cause)
	kind := provider.Classify(detail).Kind
	delay, waits := providerBackoff[kind]
	if !waits {
		return false, nil
	}
	limitedFloor, exhaustedAboveFloor := coopLadderExhaustedFloor(detail)
	degradedFallback := limitedFloor > 0 && exhaustedAboveFloor &&
		!agentRunDegradedFallbackPending(run.Context)
	// An exhausted Coop ladder stamps the soonest rung reset into its detail;
	// waiting for that instant beats polling on the generic interval. The one
	// exception is a newly armed below-floor fallback: another configured rung
	// is usable now, so waiting for the preferred rung defeats the fallback.
	if degradedFallback {
		delay = 0
	} else if kind == provider.KindRateLimit {
		if reset := provider.LadderRetryDelay(detail, s.now()); reset > delay {
			delay = reset
		}
	}
	// A wait this long should not sit behind a "working on it" status. The
	// pause is cosmetic and the queue is the guarantee, exactly as with the
	// paused-message reaction.
	s.parkWatchedStatus(ctx, run, "clear watched Slack status while the provider refuses work")
	next := s.now().Add(delay)
	if s.log != nil {
		s.log.Warn(
			"the AI provider is refusing work; it stays queued rather than failing",
			"run", run.ID,
			"mode", run.Mode,
			"kind", kind,
			"retry_at", next.UTC().Format(time.RFC3339),
			"detail", detail,
		)
	}
	return true, s.store.RequeueRateLimitedAgentRun(
		ctx, run.ID, detail, next, degradedFallback,
	)
}

func (s *Service) retryAgentRun(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	var pending *coop.OperationPendingError
	if errors.Is(cause, context.Canceled) || errors.As(cause, &pending) {
		return s.store.DeferAgentRun(ctx, run.ID, trimError(cause), s.now().Add(time.Second))
	}
	if requeued, err := s.requeueIfRateLimited(ctx, run, cause); requeued {
		return err
	}
	terminal := retrydelay.Exhausted(run.Failures+1, s.cfg.Limits.MaxAgentRunAttempts)
	var apiErr *coop.APIError
	// "Do not replay this request" is not "do not do this work", and treating
	// them as the same thing abandoned a watched Terraform failure before its
	// turn ever started. A revision conflict says the session moved on and
	// nothing was accepted; with the frozen revision released, the next attempt
	// is a genuinely different request rather than the same one again.
	if errors.As(cause, &apiErr) && !apiErr.Retryable() && !sessioncreate.RevisionConflict(cause) {
		terminal = true
	}
	if slackfile.PermanentInputError(cause) || permanentPreparationError(cause) {
		terminal = true
	}
	if run.Mode == core.AgentRunTriage && terminal {
		input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
		state, stateErr := decodeWatchRunContext(run)
		if inputErr == nil && stateErr == nil {
			return s.failPreparingTriageRun(ctx, run, input, state, trimError(cause))
		}
	}
	_, err := s.store.RetryAgentRunIfOwned(ctx, run.ID, trimError(cause),
		s.queueDelay(run.Failures+1), terminal)
	return err
}

// permanentPreparationError reports a failure that assembling the same run
// again cannot fix.
//
// A run's inputs are frozen in its context when it is admitted, so preparation
// is a pure function of them. When it produces a prompt too large for the
// transport, the twentieth attempt produces exactly the same prompt as the
// first — and it did: one alert spent 65 minutes and twenty attempts arriving
// at the identical byte count before giving up. Retrying is for failures that
// something outside the run might resolve. This is not one.
func permanentPreparationError(cause error) bool {
	return errors.Is(cause, errRequiredPromptTooLarge)
}

func (s *Service) failPreparingTriageRun(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	detail string,
) error {
	return s.finishTriageRunFailure(ctx, run, input, state, detail)
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

// silentTurnDeadline is how long a running turn may say nothing before the
// host asks Coop to cancel it. Real investigations speak — tool activity
// advances the event cursor and touches the run row — so total silence past
// the deadline is a dead transport, not a thinking model.
//
// It was fifteen minutes for one evening, and the first rate-limit storm showed
// the gap in that number: a turn crawling through provider 429 backoff inside
// Coop was also silent, and cancelling it bought a fresh session that inherited
// the same throttle — a cancel-replay loop that burned the attempt budget and
// answered nothing. Forty-five minutes was the stopgap, and it cost a
// restart-orphaned zombie three quarters of an hour of its channel instead of
// a quarter.
//
// Fifteen again, because the premise the stopgap was priced against is gone.
// Coop narrates both halves of a throttle now: provider.backoff when its own
// ladder acts on a proven limit, and provider.alive — the frame-level pulse, at
// most one a minute — when a provider CLI is retrying 429s inside itself and
// nothing else about the turn is moving. Either one advances the event cursor,
// and the advance stamps the poll clock this deadline measures against, so a
// throttled turn is no longer a silent one. Both halves had to exist: the
// backoff event alone left a single-rung or internally-retrying turn quiet
// between rotations, which is why the restore waited for the second.
//
// Restoring the number without both is how the cancel-replays come back, and
// TestASilentTurnDiesInFifteenMinutesOnceThrottleIsAudible holds that shut from
// both sides.
const silentTurnDeadline = 15 * time.Minute

// pollAgentRun advances one running turn, holding a failing run off the poll
// until its backoff expires.
//
// The backoff is the whole point of the wrapper. A poll that fails leaves the
// run running and its event cursor unadvanced, so the next tick reads the same
// events and fails the same way — the loop has no failure counter, no terminal,
// and nothing that slows it down. A dangling goal reference in one finished
// result rode that loop about three times a second for seventy-nine minutes,
// 23,030 identical warnings, while every health signal read green.
//
// It wraps rather than sits in pollAgentRuns because this is not the only
// caller: pollIncident polls the same run through the incident's active turn,
// which is why that outage produced two warnings per pass, not one. A guard in
// either caller alone would have throttled half of it.
func (s *Service) pollAgentRun(ctx context.Context, run core.AgentRun) error {
	if run.NextAttemptAt.After(s.now()) {
		return nil
	}
	err := s.pollAgentRunOnce(ctx, run)
	switch {
	case ctx.Err() != nil:
	case err != nil:
		s.holdOffFailingPoll(ctx, run, err)
	case run.LastError != "":
		// The poll recovered, so the failure it recorded is history. Leaving it
		// on the row would be worse than never writing it: stalledRunDetail
		// reads exactly this field to tell an operator why work stopped, and a
		// resolved error offered as the cause of a later silence is a confident
		// wrong answer. Only a run carrying one pays for this write.
		if clearErr := s.store.HoldOffAgentRunPoll(
			ctx, run.ID, "", s.now(),
		); clearErr != nil && s.log != nil {
			s.log.Warn("could not clear a recovered poll failure", "run", run.ID, "error", clearErr)
		}
	}
	return err
}

// holdOffFailingPoll spaces out the retries of a poll that keeps failing and
// records why, so a wedged run is answerable from its own row.
//
// The delay grows with how long the run has been going nowhere, measured from
// when it started rather than from its last write — a backoff that resets its
// own clock every time it fires does not back off. It reaches the fifteen
// second ceiling DependencyWait already defines and stops there, because a
// transient failure resolves on its own and a permanent one is the overdue
// path's problem, not this one's.
//
// Recording is best-effort. Failing to write down a failure must not become a
// second failure.
func (s *Service) holdOffFailingPoll(ctx context.Context, run core.AgentRun, cause error) {
	now := s.now()
	since := run.StartedAt
	if since.IsZero() {
		since = run.CreatedAt
	}
	next := now.Add(retrydelay.DependencyWait(now.Sub(since)))
	if err := s.store.HoldOffAgentRunPoll(ctx, run.ID, trimError(cause), next); err != nil &&
		ctx.Err() == nil && s.log != nil {
		s.log.Warn("could not hold off a failing poll", "run", run.ID, "error", err)
	}
}

func (s *Service) pollAgentRunOnce(ctx context.Context, run core.AgentRun) error {
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
		// Recorded before the terminal switch below, which returns. Coop
		// sequences a turn's narration under its terminal event precisely so
		// that a page containing both delivers the work before the verdict.
		if coop.IsActivity(event.Type) {
			// The card is a window onto this stream, so a moment that was
			// stored is a card that is now out of date. Only a new moment
			// earns the refresh — a rewound cursor redelivers ones already on
			// the card.
			if s.recordAgentActivity(ctx, run, event) {
				s.refreshCardForActivity(ctx, run)
			}
			continue
		}
		switch event.Type {
		// session.target_rotated needs no handling: Coop rotated the ladder
		// mid-turn and re-delivered the prompt itself, and every Ryker
		// prompt restates its own durable context, so the run depends on
		// nothing the hop dropped. Coop logs it and the event is durable.
		case "turn.awaiting_validation":
			turn, err := s.coop.GetTurn(ctx, run.SessionID, run.CoopTurnID)
			if err != nil {
				return err
			}
			if err := s.validateSemanticCandidate(ctx, run, turn, cursor); err != nil {
				return err
			}
		case "turn.completed", "turn.failed", "turn.cancelled", "turn.interrupted":
			turn, err := s.coop.GetTurn(ctx, run.SessionID, run.CoopTurnID)
			if err != nil {
				return err
			}
			turn = runreplay.TerminalTurnWithEventDetail(turn, event.Payload)
			// An interruption is Coop's daemon restarting under the turn — a
			// terminal of its own, which the switch above did not name, so
			// the event was skipped and the run stayed running on a turn that
			// would never speak again: three blitz runs sat that way from
			// 00:23Z to 05:54Z on 2026-08-15, past the reach of the silent-turn
			// deadline because their sessions were already discarded. It is
			// staged as a failure, which is what the replay path understands.
			return s.stagePolledAgentRunTerminal(ctx, run, interruptedAsFailed(event.Type), turn, cursor)
		}
	}
	if len(events) == 0 && session.ID != "" &&
		session.ActiveTurnID != run.CoopTurnID {
		turn, turnErr := s.coop.GetTurn(ctx, run.SessionID, run.CoopTurnID)
		if turnErr != nil {
			return turnErr
		}
		if turn.State == "completed" || turn.State == "failed" ||
			turn.State == "cancelled" || turn.State == "interrupted" {
			return s.stagePolledAgentRunTerminal(
				ctx, run, interruptedAsFailed("turn."+turn.State), turn,
				max(cursor, session.LastEventSequence),
			)
		}
	}
	// A turn that is neither terminal nor speaking is not necessarily alive.
	// A restart of supervised Coop orphans whatever was mid-turn, and the
	// rehydrated state reports those turns as running forever: no events, no
	// terminal, nothing for this poll to write. Four such zombies from the
	// 2026-08-15 restarts held their channels for half an hour each — the
	// pending queue aged 56 minutes behind them while every poll visited them,
	// found nothing to do, and left without a trace. A real long investigation
	// speaks — tool activity advances the cursor and touches the run — so a
	// run nothing has touched for the deadline is asked to die through Coop's
	// own state machine. The cancel produces the acp_cancelled terminal that
	// the replay path already treats as an interruption, which requeues triage
	// work in a fresh session, bounded by the ordinary attempt budget.
	if len(events) == 0 && run.CoopTurnID != "" &&
		s.now().Sub(run.NextAttemptAt) >= silentTurnDeadline {
		s.log.Warn(
			"cancelling a turn that has been silent past the deadline",
			"run", run.ID, "session", run.SessionID, "turn", run.CoopTurnID,
			"silent_for", s.now().Sub(run.NextAttemptAt).Round(time.Second),
		)
		turn, _, cancelErr := s.coop.Cancel(
			ctx, "silent-turn-cancel:"+run.ID+":"+run.CoopTurnID,
			run.SessionID, run.CoopTurnID, 0,
		)
		if cancelErr != nil {
			return fmt.Errorf("cancel a silent turn: %w", cancelErr)
		}
		if turn.State == "completed" {
			return s.stagePolledAgentRunTerminal(ctx, run, "turn.completed", turn, cursor)
		}
		if turn.State == "failed" || turn.State == "cancelled" {
			// Staged as a failure regardless of which terminal the cancel
			// reached, because that is what this is: the host interrupted a
			// dead transport. The failure form is what the replay path
			// classifies as an interruption, which requeues triage work in a
			// fresh session instead of burying the answer with the zombie.
			return s.stagePolledAgentRunTerminal(ctx, run, "turn.failed", turn, cursor)
		}
		return nil
	}
	if cursor > run.CoopEventSequence {
		if err := s.store.AdvanceAgentRunEvents(ctx, run.ID, cursor); err != nil {
			return err
		}
		// The advance is also the turn's proof of life, stamped where only
		// real poll outcomes write. The deadline first keyed on updated_at,
		// and updated_at turned out to be touched by cosmetic writes — card
		// refreshes, episode progress — every minute: run_dba732ef sat with
		// an 87-minute-old poll stamp and a 70-second-old updated_at, shielded
		// from the exact deadline built for it.
		if err := s.store.HoldOffAgentRunPoll(ctx, run.ID, "", s.now()); err != nil &&
			ctx.Err() == nil && s.log != nil {
			s.log.Warn("could not stamp turn liveness", "run", run.ID, "error", err)
		}
		if run.Mode == core.AgentRunTriage {
			if err := s.advanceTriageSessionEvents(ctx, run, cursor); err != nil {
				return err
			}
		}
	}
	if run.Mode == core.AgentRunTriage && !isSessionHandoffRun(run) {
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

func (s *Service) validateSemanticCandidate(
	ctx context.Context,
	run core.AgentRun,
	turn coop.Turn,
	cursor int64,
) error {
	return semanticvalidation.Resolve(ctx, s.coop, semanticvalidation.Request{
		RunID: run.ID, SessionID: run.SessionID, TurnID: run.CoopTurnID, Turn: turn,
	}, func(candidateTurn coop.Turn) (string, error) {
		staged := stagedTurn{result: []byte(candidateTurn.AssistantMessage)}
		var err error
		switch run.Mode {
		case core.AgentRunTriage:
			_, err = s.stageTriageTerminal(ctx, run, candidateTurn, cursor, &staged, true)
		case core.AgentRunIncident, core.AgentRunEngineeringTask:
			_, err = s.stageIncidentTerminal(ctx, run, candidateTurn, cursor, &staged, true)
		default:
			return "", fmt.Errorf("semantic validation is unavailable for agent run mode %q", run.Mode)
		}
		var violation *semanticCandidateViolation
		if errors.As(err, &violation) {
			return violation.detail, nil
		}
		return "", err
	}, func(detail string) {
		s.audit(ctx, core.AuditEvent{
			IncidentID: run.IncidentID, Kind: "result.correction", ActorID: "responder",
			ObjectID: run.ID, Outcome: string(correctionIncomplete), Detail: s.sanitizeText(detail),
		})
	})
}

// stagedTurn is what a completed turn contributes to the staged agent-run
// result: the payload to persist and the operator-facing failure detail. The
// per-mode validators below own both, so the outer function does not have to
// thread two mutable locals through several hundred lines.
type stagedTurn struct {
	result []byte
	detail string
}

func (s *stagedTurn) setResult(result []byte, err error) error {
	if err == nil {
		s.result, s.detail = result, ""
	}
	return err
}

// stageTriageTerminal validates a completed triage turn and applies its watch decision.
// A true first result means the turn is fully handled and the caller
// should return the accompanying error, which may be nil.
// correctionClass names why the host sent a result back to the model.
//
// The class matters more than the text. Correction text quotes model output and
// is unbounded prose; the class is a small vocabulary you can count, which is
// what turns corrections from noise into the one signal that says whether
// Ryker is getting better.
type correctionClass string

type semanticCandidateViolation struct{ detail string }

func (e *semanticCandidateViolation) Error() string { return e.detail }

const (
	// correctionUnreadable: the result could not be parsed at all.
	correctionUnreadable correctionClass = "unreadable"
	// correctionIncomplete: the result parsed but the host refused it — a
	// missing verdict, unexplained coverage, an unsupported claim, an offer
	// combined with work.
	//
	// Two classes, not three. A "policy" class was drafted and removed because
	// its boundary against this one could not be stated crisply, and a class
	// whose boundary is unclear makes the count ambiguous — which defeats the
	// only reason the class exists.
	correctionIncomplete correctionClass = "incomplete"
	// correctionRejected: the conclusion was fine but an artifact attached to
	// it — an offer the model built — could not be accepted.
	//
	// Distinct from incomplete on a line that can be stated: incomplete is
	// about the answer, rejected is about something attached to it. A turn can
	// be perfectly correct and still offer a malformed button.
	correctionRejected correctionClass = "rejected"
	// correctionShape: everything the answer says is right and it says it
	// wrong — too many words for the message it answers, or a closing sentence
	// that hands the question back.
	//
	// The boundary against incomplete is the one line that matters: incomplete
	// means the answer cannot be used, shape means it can and should not be
	// read. That difference is why this class alone posts on the second
	// attempt rather than blocking the turn.
	correctionShape correctionClass = "shape"
)

// CorrectionClasses lists every class a turn can be corrected under, so a
// reader of the correction rate covers all of them.
//
// A hand-written list in the reporting command drifts the moment a class is
// added here: the new class is emitted, counted by nobody, and the totals
// quietly understate. Deriving the report from this keeps the two in step.
func CorrectionClasses() []string {
	return []string{
		string(correctionUnreadable),
		string(correctionIncomplete),
		string(correctionRejected),
		string(correctionShape),
	}
}

// requeueWithCorrection sends a result back to the model and records that it
// happened.
//
// The two are one operation on purpose. A correction that is requeued without
// being recorded is invisible, and every one of these was invisible until now:
// the text went into the retry and nothing counted it. Splitting them again
// would let the recording drift away from the retry it describes.
func (s *Service) requeueWithCorrection(
	ctx context.Context,
	run core.AgentRun,
	class correctionClass,
	correction string,
	cursor int64,
) error {
	// Not an attempt. The model answered and the host refused the answer; the
	// correction budget in the run's context envelope is what bounds this, and
	// failure_count is left to mean provider attrition alone.
	if err := s.store.RequeueAgentRun(ctx, run.ID, correction, cursor, s.now(), false); err != nil {
		return err
	}
	// Counted and escalated before the audit, so the trace line can say which
	// rung the retry is going to rather than leaving the rung transition to be
	// inferred from the next attempt's context manifest.
	escalation := s.escalateRepeatedCorrection(ctx, run, class)
	s.audit(ctx, core.AuditEvent{
		IncidentID: run.IncidentID,
		Kind:       "result.correction",
		ActorID:    "responder",
		ObjectID:   run.ID,
		Outcome:    string(class),
		// 2000, up from 500: the episode page renders this as "Correction sent
		// to the model", and at 500 a live contradiction correction displayed
		// amputated mid-word — an operator debugging retries was reading a
		// different text than the model received. The full text also lives on
		// the fixture candidate; this bound only decides how much of it the
		// trace shows inline.
		Detail: s.sanitizeText(decisionpkg.BoundedField(correction, 2000)) + escalation,
	})
	// Queue the correction for review as a regression fixture. This is the
	// whole self-improving loop in one line: the host already decided the model
	// was wrong and said why, so the label is free — all it needs is a person
	// deciding the lesson is worth keeping.
	//
	// A failure here must not fail the retry. The correction is the useful
	// thing; capturing it for later is a bonus, and losing the bonus is not a
	// reason to lose the turn.
	candidate := core.NewFixtureCandidate(run, string(class), s.sanitizeText(correction))
	if err := s.store.RecordFixtureCandidate(ctx, candidate); err != nil && s.log != nil {
		s.log.Warn(
			"could not queue a correction for review",
			"run", run.ID,
			"error", err,
		)
	}
	return nil
}

// supersededByNewerLifecycle reports whether a newer update for this exact
// operational stream is already queued, which is the same question
// finalization asks before applying a result — asked earlier here, because some
// of what a result carries cannot be taken back.
func (s *Service) supersededByNewerLifecycle(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
) (bool, error) {
	if input.Kind != "bot_message" || isPrivateSlackVerificationReplay(input) ||
		!strings.HasPrefix(run.ConversationKey, "operation:") {
		return false, nil
	}
	return s.hasNewerOperationalInput(ctx, run, input)
}

// appendAlertStreamWait keeps an answered but still-active alert stream open as
// one episode, by adding the host's own bounded external wait to the result.
//
// An alert stream is one operational situation, and each card is an update to
// it. Every episode used to complete the instant its reply posted, so the next
// card found a terminal predecessor and opened a fresh episode with a fresh
// briefing: on 2026-08-16 one Traefik memory alert cost five episodes and about
// fifteen dollars re-establishing what the previous one had just learned, with
// no shared ledger between them.
//
// The wait is appended only when the alert is still a live problem and the turn
// concluded. A recovery, a not_issue verdict, or a turn that already left a wait
// of its own behind says the opposite, and the episode closes or continues on
// its own terms. It goes on both Operations and AppliedOperations because the
// former is the persisted shape finalization reparses and the latter is what
// this turn records.
func (s *Service) appendAlertStreamWait(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	decision *decisionpkg.WatchDecision,
) error {
	if input.Kind != "bot_message" || isPrivateSlackVerificationReplay(input) ||
		!strings.HasPrefix(run.ConversationKey, "operation:") ||
		decision.Action != "reply" || decision.Completion == nil ||
		decision.Completion.Status != "decision_ready" ||
		decision.AlertAssessment == nil ||
		leavesAWaitBehind(*decision) {
		return nil
	}
	window := s.cfg.Slack.AlertStreamOpenWindow.Duration
	if window <= 0 {
		return nil
	}
	// A recovery ends a firing, not the conversation about it.
	//
	// The episode used to close the moment a reply said the condition had
	// cleared, so a re-fire minutes later opened a new one with a fresh
	// briefing, an empty ledger and no sight of the offer the earlier episode
	// had already made — the same defect the stream wait exists to remove,
	// arriving one card later. On 2026-08-16 va1-nomad-oom-risk cleared at
	// 19:11Z and fired again at 19:24Z, thirteen minutes apart.
	//
	// So a stream that WAS live is held open for one more window after it
	// recovers. Only a stream that was live: a RESOLVED card for something
	// Ryker never investigated is the end of a conversation it was not
	// having, and holding an episode open for it would keep a wakeup, a session
	// and an episode alive for six hours over a card that said nothing is wrong.
	hold := false
	switch alertstream.WaitFor(input, *decision) {
	case alertstream.WaitActive:
	case alertstream.WaitRecovered:
		live, err := s.streamWasLive(ctx, run.EpisodeID)
		if err != nil {
			return err
		}
		if !live {
			return nil
		}
		hold = true
	default:
		return nil
	}
	now := s.now().UTC()
	matcher, err := json.Marshal(map[string]string{
		"conversation_key": run.ConversationKey,
		"reason":           "this alert stream is still one unit of work; the next card continues this episode",
	})
	if err != nil {
		return err
	}
	// One timer per stream, and the operation on every answer.
	//
	// The id names the EPISODE, so a later card's wait resolves to the row the
	// first one created: CreateEpisodeWakeup is INSERT OR IGNORE on the id, and
	// the scheduler item behind it is a singleton keeping the earliest due time,
	// so the duplicate schedules nothing. That is why the operation itself is
	// unconditional — which it has to be. Skipping it to avoid a second timer,
	// as the first version did, staged a decision with nothing pending in it:
	// the 2026-08-16 va1-nomad-oom-risk stream answered its second card at
	// 19:29Z, completionEpisodePhase read a finished turn, and the episode
	// closed with the alert still firing.
	//
	// A run with no episode leaves the id bare, and harmlessly: the operation is
	// applied against the episode resolved from that same agent_runs.episode_id,
	// so a run without one creates no wakeup for the id to collide with.
	id := "host-stream-open-" + run.EpisodeID
	deadline := now.Add(2 * window)
	if hold {
		// The hold carries the RUN, not the episode, and that is the whole
		// difference. The episode-scoped id is idempotent by design, which is
		// what stops a second firing arming a second timer — but it also means
		// a hold arriving after the first timer has fired would insert nothing
		// and leave the episode open with no clock. One timer per recovery is
		// the bound instead: a recovery ends a firing, and its own deadline is
		// one window rather than two, because nothing is running any more.
		id = "host-stream-hold-" + run.ID
		deadline = now.Add(window)
	}
	wait := investigation.ResultOperation{
		ID: id, Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: id, Kind: alertStreamWaitKind, EventMatcher: matcher,
			PollAfter: now.Add(window).Format(time.RFC3339),
			DueAt:     now.Add(window).Format(time.RFC3339),
			Deadline:  deadline.Format(time.RFC3339),
		},
	}
	decision.Operations = append(decision.Operations, wait)
	decision.AppliedOperations = append(decision.AppliedOperations, wait)
	return nil
}

// leavesAWaitBehind reports whether the turn scheduled something that outlives
// it: an external wait of any kind, or a recheck on its completion. Those are
// the only two things that keep an episode open past this turn on their own, so
// they are the only two the host's stream wait would duplicate.
//
// Narrower than decisionpkg.ContinuesThisEpisode, which also counts a planned
// goal. An open goal does hold the episode open through the goal machinery, but
// a goal planned and closed in the same turn leaves nothing running at all —
// and the first live alert stream after this feature deployed did exactly that:
// run_0c2e0f1f2ea28371cac5ef8a1aa603c4 answered the 19:01Z card on 2026-08-16
// with three plan_goal operations and three update_goal closures. Read as "the
// turn continues", the wait was skipped, the episode completed, and the 19:11Z
// card opened a new one with a fresh briefing. ContinuesThisEpisode keeps its
// meaning for the corrections that depend on it; only this question changed. A
// goal that does stay open is harmless here: the wait beside it costs one row.
func leavesAWaitBehind(decision decisionpkg.WatchDecision) bool {
	if decision.Completion != nil && decision.Completion.Recheck != nil {
		return true
	}
	for _, operation := range decision.AppliedOperations {
		if operation.Type == "wait_external" {
			return true
		}
	}
	return false
}

func (s *Service) stageTriageTerminal(
	ctx context.Context,
	run core.AgentRun,
	turn coop.Turn,
	cursor int64,
	staged *stagedTurn,
	validationOnly ...bool,
) (bool, error) {
	preflight := len(validationOnly) > 0 && validationOnly[0]
	if isSessionHandoffRun(run) {
		if preflight {
			return false, nil
		}
		return s.handoffTurnResult(ctx, run, turn, staged)
	}
	input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
	state, stateErr := decodeWatchRunContext(run)
	decision, decisionErr := decisionpkg.ParseWatchDecision(turn.AssistantMessage, s.now())
	schemaErr := decisionErr
	// Asked against the model's own result, before the host enforcement below
	// rewrites its fields: what is being rejected is what the model sent, and a
	// message policy applied afterwards is not the model answering in the
	// retired dialect. It is a decode failure rather than a ladder step because
	// there is one result dialect now — an envelope carrying its result in
	// top-level fields is unreadable, not merely unfashionable.
	if decisionErr == nil {
		if unreadable := decisionpkg.UnreadableEnvelopeResult(decision); unreadable != "" {
			decisionErr = errors.New(unreadable)
		}
	}
	if inputErr != nil {
		return true, inputErr
	}
	if stateErr != nil {
		return true, stateErr
	}
	// The corrections this episode has already spent, read once: both correction
	// branches below bound themselves against the same number, and it does not
	// move while this turn is being staged.
	episodeCorrections, correctionsErr := s.episodeStructuredCorrections(ctx, run)
	if correctionsErr != nil {
		return true, correctionsErr
	}
	input = mentioncontext.Apply(input, state.ResolvedMentionRequest)
	if decisionErr != nil {
		invalid := trimError(decisionErr)
		correction := "the structured Slack response is invalid: " + invalid +
			investigation.SchemaFragmentForCorrection(string(correctionUnreadable), invalid)
		if preflight {
			return true, &semanticCandidateViolation{detail: correction}
		}
		// The complete stream is still rejected, but independently valid
		// evidence, coverage and findings before an unrelated malformed offer
		// remain this run's records. The correction contract explicitly tells
		// the model the host holds them; make that true before persisting the
		// next round's context.
		recovered := resultrecovery.Watch(turn.AssistantMessage, resultrecovery.Records{
			Evidence: state.CarriedEvidence, Coverage: state.CarriedCoverage,
			Findings: state.CarriedFindings,
		}, s.now())
		state.CarriedEvidence, state.CarriedCoverage, state.CarriedFindings =
			recovered.Evidence, recovered.Coverage, recovered.Findings
		correctionLimit := s.cfg.Limits.MaxAgentRunAttempts
		if schemaErr != nil {
			correctionLimit = min(correctionLimit, resultrecovery.UnreadableAttemptLimit)
		}
		if !resultrecovery.ConsumeWatchCorrection(&state, episodeCorrections, correctionLimit) {
			state.FailureDetail = correction
			contextJSON, marshalErr := json.Marshal(state)
			if marshalErr != nil {
				return true, marshalErr
			}
			if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
				return true, err
			}
			if err := s.requeueWithCorrection(
				ctx, run, correctionUnreadable, correction, cursor,
			); err != nil {
				return true, err
			}
			_ = s.advanceTriageSessionEvents(ctx, run, cursor)
			return true, nil
		}
		if reply, ok := resultrecovery.CompletionReply(turn.AssistantMessage, true); schemaErr != nil && ok {
			decision = resultrecovery.ReplyOnlyWatch(run, input, state, correction, reply)
			s.audit(ctx, resultrecovery.ReplyFallbackAudit(run, "schema_invalid",
				"Rejected invalid operations and delivered the single bounded completion reply."))
		} else {
			decision = resultrecovery.BlockedWatch(run, input, state, correction, nil)
		}
		if decisionErr = staged.setResult(decisionpkg.MarshalWatchDecisionResult(decision)); decisionErr != nil {
			return true, decisionErr
		}
	} else {
		if state.Lane == "conversation" && decision.Action == "escalate" {
			if preflight {
				return false, nil
			}
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
		episodeRecords, episodeEvidenceErr := resultrecovery.EpisodeRecords(ctx, s.store.Intelligence, episode.ID)
		if episodeEvidenceErr != nil {
			return true, episodeEvidenceErr
		}
		// Before anything else reads this result. A correction round returns
		// only the records it is changing, and every reader below — the
		// lifecycle policy that decides whether the reply adds anything, the
		// validators, the delivery, the ledger — is entitled to the whole
		// investigation. Asked of the fragment instead, a round that returned
		// its completion and nothing else was suppressed as adding no fresh
		// evidence, and the answer the operator was waiting for went nowhere.
		if decision.Action == "reply" {
			decisionpkg.RestoreCarriedRecords(
				decision.Operations,
				state.CarriedEvidence, state.CarriedCoverage, state.CarriedFindings,
			).ApplyTo(&decision)
			state.ReconcileCarriedTaskOffer(&decision)
		}
		decisionpkg.NormalizeAppAlertCompletion(input, &decision)
		lifecycleInput := terraformwakeup.RestoreSourceLink(ctx, s.store, episode, input)
		lifecycleContinuationCorrection := TerraformLifecycleContinuationCorrection(
			lifecycleInput, state, decision,
		)
		originalAction := decision.Action
		// Kept because suppression erases them and the completion is persisted
		// either way. Silencing a reply decides what Slack hears; it does not
		// decide whether the model's own result was coherent, and completion
		// validation skips anything that is not a reply — so a suppressed
		// result went to the episode unchecked. One claimed a succeeded change
		// review over change coverage it had marked unknown, and finalized
		// silently, because policy had removed the evidence of its own
		// invalidity before anything looked at it.
		originalCompletion := decision.Completion
		originalPublicationUpdates := len(decision.PublicationUpdates)
		originalMessage := decision.Message
		decision = EnforceExternalLifecycleCommunication(input, decision)
		var lifecycleEvidenceAdjusted bool
		decision, lifecycleEvidenceAdjusted = EnforceExternalLifecycleEvidence(
			input, episode, decision,
		)
		if lifecycleEvidenceAdjusted || decision.Action != originalAction ||
			len(decision.PublicationUpdates) != originalPublicationUpdates ||
			decision.Message != originalMessage {
			if err := staged.setResult(decisionpkg.MarshalWatchDecisionResult(decision)); err != nil {
				return true, err
			}
		}
		// Validation reads the investigation, not this round's fragment of it.
		// A correction round returns only the records it is changing, so
		// `validated` carries the rest forward; see decision.CarryEvidence for
		// the loop this closes. The restore above has already put those records
		// back into `decision` itself, so this fold is over a stream that
		// mostly repeats what it holds — carryForward keys on the record
		// identity, so a row folded onto itself stays one row — and the rows it
		// adds here are the ones the host wrote in this turn's enforcement.
		state.CarriedEvidence = decisionpkg.CarryEvidence(state.CarriedEvidence,
			decisionpkg.SanitizeEvidence(decision.Evidence, "", "", "", s.now()))
		state.CarriedCoverage = decisionpkg.CarryCoverage(state.CarriedCoverage,
			completionpolicy.CurrentCoverage(decisionpkg.SanitizeCoverage(decision.Coverage, "", "", "", s.now()), s.now()))
		state.CarriedFindings = decisionpkg.CarryFindings(
			state.CarriedFindings, decisionpkg.SanitizeFindings(decision.Findings),
		)
		// Correlation ancestry informs rendering and contradiction checks, but it
		// is not this run's observation. Current-state, scope and completion claims
		// must be supported by evidence gathered by this run.
		currentEvidence, coverage := state.CarriedEvidence, state.CarriedCoverage
		evidence := decisionpkg.CarryEvidence(episodeRecords.Evidence, currentEvidence)
		validated := decision
		validated.Evidence, validated.Coverage = currentEvidence, coverage
		validated.Findings = state.CarriedFindings
		correction := lifecycleContinuationCorrection
		// The default class; a rejected artifact overrides it below.
		correctionKind := correctionIncomplete
		taskOfferRejected := false
		// First, because everything below asks what the result says and this
		// asks whether it said anything. A correction round may return only
		// what it changes; it may not return nothing and inherit an answer.
		if correction == "" {
			correction = decisionpkg.PartialRoundCorrection(input, state, decision)
		}
		if correction == "" {
			needsScheduleOffer, scheduleErr := s.scheduleActivationNeedsOffer(
				ctx, input, decision.ScheduleOffer,
			)
			if scheduleErr != nil {
				return true, scheduleErr
			}
			if needsScheduleOffer {
				correction = scheduleActivationOfferCorrection()
			}
		}
		if correction == "" {
			correction, taskOfferRejected = taskofferrejection.WatchCorrection(
				input, state, validated, s.now(), OperationalCorrelationKey,
			)
			correctionKind = correctionClass(taskofferrejection.CorrectionClass(taskOfferRejected, string(correctionKind)))
		}
		// Render only governed alerts; ordinary conversations keep their answer.
		if correction == "" {
			beforeHostRender := decision.Message
			renderOperational := alertstream.GovernedOperationalAlert(input, state)
			if renderOperational {
				decision, correction = decisionpkg.RenderOperationalAlertDecision(decision, evidence)
			}
			if correction == "" {
				var recoveryLinkAdjusted bool
				decision, recoveryLinkAdjusted = decisionpkg.EnforceRecoveredAlertLink(
					input, decision, alertstream.PriorFiringMessageLink(input, state.RecentMessages),
				)
				decision = EnrichExternalLifecycleReply(lifecycleInput, decision)
				validated.Message = decision.Message
				validated.FollowupMessages = decision.FollowupMessages
				if decision.Message != beforeHostRender || recoveryLinkAdjusted {
					if err := staged.setResult(decisionpkg.MarshalWatchDecisionResult(decision)); err != nil {
						return true, err
					}
				}
			}
		}
		// Before the completion rules below, because all three of these ask
		// whether there is anything left to do and those ask whether the
		// completion is well formed. Asked the other way round, a perfectly
		// shaped completion of unfinished work goes straight through — which is
		// exactly what the 12:16 Zot triage was on 2026-08-11: decision_ready,
		// verdict succeeded, and a rollback it had discovered sitting in the
		// prose where nothing could read it.
		if correction == "" {
			correction = decisionpkg.FindingCorrection(episode, validated, validated.Findings)
		}
		// Beside it, and for the same reason: a bounded cause is an open
		// question, and an episode that closes on one has stopped rather than
		// finished.
		if correction == "" {
			correction = decisionpkg.BoundedCauseCorrection(episode, validated)
		}
		if correction == "" {
			// A terminal claim is checked against what the model produced, not
			// against what policy left of it. Only a terminal one: a turn that
			// parks on a wait is not concluding anything, and holding its
			// in-progress completion to the episode's completion contract
			// would correct a result behaving exactly as intended. The
			// message-shaped checks below stay on the suppressed decision,
			// because correcting the wording of something nobody will read is
			// work for its own sake.
			checkedAction, checkedCompletion := decision.Action, decision.Completion
			if originalCompletion != nil && originalCompletion.Verdict != "in_progress" {
				checkedAction, checkedCompletion = originalAction, originalCompletion
			}
			correction = investigation.CompletionCorrection(
				episode,
				checkedAction,
				coverage,
				checkedCompletion,
			)
			if correction == "" && checkedCompletion != nil {
				// Asked here rather than left to the kernel's completion
				// guard: that guard fires at finalization, after the result
				// is accepted, and its refusal reached nobody — run_dab83e5b
				// retried finalization forty times over three hours against
				// a required goal one of its own turns had planned.
				goals, goalsErr := s.store.Goals.ListForEpisode(ctx, episode.ID, 200)
				if goalsErr != nil {
					return true, goalsErr
				}
				correction = investigation.OpenRequiredGoalCorrection(
					goals, decision.AppliedOperations, checkedCompletion,
				)
			}
			if correction == "" {
				correction, episodeErr = s.episodeClaimCorrectionWithHistory(
					ctx,
					episode,
					decision.Action,
					currentEvidence,
					coverage,
					decision.Completion,
					s.now(),
					run.StartedAt,
					decision.AppliedOperations,
					&taskOfferRejected,
				)
				if episodeErr != nil {
					return true, episodeErr
				}
				if taskOfferRejected {
					correctionKind = correctionRejected
				}
			}
			if correction == "" {
				correction = taskcontract.ScheduledResultCorrection(episode, input, decision)
			}
			if correction == "" {
				correction = behaviorrequired.Correction(
					s.cfg.IsOperator(input.UserID), input, state.Repository, decision,
				)
			}
			if correction == "" {
				if rejected := s.offerRejectionCorrection(ctx, input, decision); rejected != "" {
					correction, correctionKind = rejected, correctionRejected
				}
			}
			if correction == "" {
				correction = decisionpkg.EpisodeDiagnosisCorrection(
					episode, decision.Action, currentEvidence, coverage,
					decision.AlertAssessment,
					decision.Completion,
				)
			}
		}
		// Last, because everything above says the answer cannot be used and
		// this says only that it reads badly. There is no point spending the
		// turn on length when the content is going back anyway.
		if correction == "" {
			var shaped bool
			correction, shaped = s.replyShapeCorrection(
				ctx, run, input.Text, state.Lane, decision.Action, decision.Message,
				state.ReplyShapeCorrections,
			)
			if shaped {
				state.ReplyShapeCorrections++
				correctionKind = correctionShape
			}
		}
		if correction != "" {
			if preflight {
				return true, &semanticCandidateViolation{detail: correction}
			}
			if !resultrecovery.ConsumeWatchCorrection(
				&state, episodeCorrections,
				min(s.cfg.Limits.MaxAgentRunAttempts, resultrecovery.SemanticAttemptLimit),
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
				if err := s.requeueWithCorrection(
					ctx, run, correctionKind, correction, cursor,
				); err != nil {
					return true, err
				}
				_ = s.advanceTriageSessionEvents(ctx, run, cursor)
				return true, nil
			}
			// A rejected offer is not a failed turn. The answer was
			// produced and is fine; only something attached to it could not
			// be stored. Blocking here would replace a good reply with "I
			// couldn't finish this check safely yet" — untrue, and it throws
			// away work the user is waiting on over a malformed button.
			// Drop the offer that failed, keep the answer, and tell the
			// operator what was dropped.
			switch correctionKind {
			case correctionRejected:
				if taskOfferRejected {
					taskofferrejection.Drop(&decision)
				}
				s.dropRejectedOffers(ctx, input, &decision, run)
				taskofferrejection.ForgetCarried(&state.CarriedTaskOffer, taskOfferRejected)
			case correctionShape:
				// Same reasoning, one step further: the answer is not merely
				// salvageable, it is correct. Replacing it with "I couldn't
				// finish this check safely yet" over its word count would be
				// the rule eating the answer it exists to improve.
				s.recordUnshapedReply(ctx, run, correction)
			default:
				var delivered bool
				decision, delivered = resultrecovery.SemanticWatch(
					run, input, state, correction, decision,
				)
				if delivered {
					s.audit(ctx, resultrecovery.ReplyFallbackAudit(run, "semantic_invalid",
						"Rejected unsafe structured claims and delivered the bounded completion reply."))
				}
			}
			if err := staged.setResult(decisionpkg.MarshalWatchDecisionResult(decision)); err != nil {
				return true, err
			}
		} else {
			if preflight {
				return false, nil
			}
			superseded := false
			// A reply is the investigation, and its evidence, findings and
			// waits are what the next attempt on this stream reads instead of
			// starting over. Only a turn with nothing to lose — an ignore or a
			// react — is worth discarding because a newer card arrived; asking
			// this of a reply is what made five separate episodes investigate
			// one alert on 2026-08-16 and share nothing between them.
			if decision.Action != "reply" {
				var err error
				if superseded, err = s.supersededByNewerLifecycle(ctx, run, input); err != nil {
					return true, err
				}
			}
			if !superseded {
				if err := s.appendAlertStreamWait(ctx, run, input, &decision); err != nil {
					return true, err
				}
				// Recorded only once nothing newer is queued for this lifecycle.
				// These operations are durable: a wait_external schedules a wakeup
				// that outlives the turn, so staging one from a result finalization
				// was about to discard left a timer behind that later fired a
				// recheck for an update already answered.
				if err := s.recordResultOperationEvents(
					ctx, run.ID, decision.AppliedOperations,
				); err != nil {
					return true, err
				}
			}
		}
	}
	if err := staged.setResult(decisionpkg.MarshalWatchDecisionResult(decision)); err != nil {
		return true, err
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
	validationOnly ...bool,
) (bool, error) {
	preflight := len(validationOnly) > 0 && validationOnly[0]
	report, _, reportErr := decisionpkg.ParseAgentReport(turn.AssistantMessage)
	schemaErr := reportErr
	if reportErr != nil {
		invalid := trimError(reportErr)
		correction := "the structured agent report is invalid: " + invalid +
			investigation.SchemaFragmentForCorrection(string(correctionUnreadable), invalid)
		if preflight {
			return true, &semanticCandidateViolation{detail: correction}
		}
		// The full report is unreadable, but an unrelated bad offer must not
		// erase valid ledger records that preceded it. The next correction round
		// is promised those records are still held, just like the watch lane.
		recovered := resultrecovery.AgentReport(turn.AssistantMessage, s.now())
		correctionLimit := s.cfg.Limits.MaxAgentRunAttempts
		if schemaErr != nil {
			correctionLimit = min(correctionLimit, resultrecovery.UnreadableAttemptLimit)
		}
		spent, spendErr := s.spendStructuredCorrectionWithin(
			ctx, run, recovered.Evidence, recovered.Coverage, recovered.Findings,
			correctionLimit,
		)
		if spendErr != nil {
			return true, spendErr
		}
		if !spent {
			if err := s.requeueWithCorrection(
				ctx, run, correctionUnreadable, correction, cursor,
			); err != nil {
				return true, err
			}
			return true, nil
		}
		if reply, ok := resultrecovery.CompletionReply(turn.AssistantMessage, false); schemaErr != nil && ok {
			report = resultrecovery.ReplyOnlyAgent(correction, reply)
			s.audit(ctx, resultrecovery.ReplyFallbackAudit(run, "schema_invalid",
				"Rejected invalid operations and delivered the single bounded completion reply."))
		} else {
			report = resultrecovery.BlockedAgent(correction, nil)
		}
		if reportErr = staged.setResult(resultwire.AgentReport(report)); reportErr != nil {
			return true, reportErr
		}
	} else {
		episode, episodeErr := s.store.GetWorkEpisodeByRun(ctx, run.ID)
		if episodeErr != nil {
			return true, episodeErr
		}
		episodeRecords, episodeEvidenceErr := resultrecovery.EpisodeRecords(ctx, s.store.Intelligence, episode.ID)
		if episodeEvidenceErr != nil {
			return true, episodeEvidenceErr
		}
		correction := ""
		correctionKind := correctionIncomplete
		taskOfferRejected := false
		trigger := ""
		// The same accumulation the watch path does above: an incident
		// correction round returns only the records it is changing, and
		// validating its stream alone refuses it for what this run already
		// established. The restore puts those records back into the report
		// first, so the report that is staged, delivered and stored is the
		// whole investigation rather than the fragment of it this round typed.
		carried, _ := decodeAssembledAgentContext(run.Context)
		decisionpkg.RestoreCarriedRecords(
			report.Operations,
			carried.CarriedEvidence, carried.CarriedCoverage, carried.CarriedFindings,
		).ApplyToReport(&report)
		currentEvidence := decisionpkg.CarryEvidence(carried.CarriedEvidence,
			decisionpkg.SanitizeEvidence(report.Evidence, "", "", "", s.now()))
		evidence := decisionpkg.CarryEvidence(episodeRecords.Evidence, currentEvidence)
		coverage := decisionpkg.CarryCoverage(carried.CarriedCoverage,
			completionpolicy.CurrentCoverage(decisionpkg.SanitizeCoverage(report.Coverage, "", "", "", s.now()), s.now()))
		findings := decisionpkg.CarryFindings(
			carried.CarriedFindings, decisionpkg.SanitizeFindings(report.Findings),
		)
		// Kept past the block below because the offer rules need it twice: once
		// to build the correction and once, when the retries are spent, to drop
		// what the model never managed to state.
		offerInput := core.SlackInput{}
		if run.SourceKind == "slack" {
			input, inputErr := s.store.GetSlackInput(ctx, run.SourceID)
			if inputErr != nil {
				return true, inputErr
			}
			offerInput = input
			trigger = input.Text
			needsScheduleOffer, scheduleErr := s.scheduleActivationNeedsOffer(
				ctx, input, report.ScheduleOffer,
			)
			if scheduleErr != nil {
				return true, scheduleErr
			}
			if needsScheduleOffer {
				correction = scheduleActivationOfferCorrection()
			}
		}
		// Same order as the watch path, and the same reason: a well-formed
		// completion of unfinished work is the failure this rule exists for. The
		// deep lanes run here, so this is the only place the adversarial-residue
		// rule is reachable at all.
		if correction == "" {
			// Evidence travels with it because the residue rules read the words
			// of the observation a finding cites, not just its id.
			reported := decisionpkg.WatchDecision{
				Action: "reply", Message: report.Message,
				FollowupMessages: report.FollowupMessages, Completion: report.Completion,
				AppliedOperations: report.AppliedOperations, Findings: findings,
				Evidence: currentEvidence, Coverage: coverage, AlertAssessment: report.AlertAssessment,
			}
			correction = decisionpkg.FindingCorrection(episode, reported, findings)
			if correction == "" {
				correction = decisionpkg.BoundedCauseCorrection(episode, reported)
			}
			if correction == "" {
				correction = decisionpkg.EpisodeDiagnosisCorrection(
					episode, "reply", currentEvidence, coverage,
					report.AlertAssessment, report.Completion,
				)
			}
			if correction == "" && report.AlertAssessment != nil &&
				(episode.Effort == core.EffortOperationalAssessment ||
					episode.Effort == core.EffortIncidentInvestigation) {
				beforeHostRender := report.Message
				report, correction = decisionpkg.RenderOperationalAlertReport(report, currentEvidence)
				if correction == "" && report.Message != beforeHostRender {
					if reportErr = staged.setResult(resultwire.AgentReport(report)); reportErr != nil {
						return true, reportErr
					}
				}
			}
		}
		if correction == "" {
			correction = investigation.CompletionCorrection(
				episode, "reply", coverage, report.Completion,
			)
		}
		if correction == "" {
			correction, episodeErr = s.episodeClaimCorrectionWithHistory(
				ctx,
				episode,
				"reply",
				currentEvidence,
				coverage,
				report.Completion,
				s.now(),
				run.StartedAt,
				report.AppliedOperations,
				&taskOfferRejected,
			)
			if episodeErr != nil {
				return true, episodeErr
			}
			if taskOfferRejected {
				correctionKind = correctionRejected
			}
		}
		if correction == "" && run.Mode == core.AgentRunEngineeringTask &&
			report.Completion != nil && report.Completion.Status == "decision_ready" &&
			!taskcompletion.RequestsOperatorInput(report.AppliedOperations) {
			correction, episodeErr = s.engineeringWorkspaceCompletionCorrection(ctx, run)
			if episodeErr != nil {
				return true, episodeErr
			}
		}
		// After everything about the answer, before anything about how it reads:
		// the same position and the same reason as the watch lane. An offer is
		// an artifact attached to a conclusion, so there is no point spending a
		// turn on the button while the content is going back anyway.
		//
		// This lane had no such check at all. A malformed offer was dropped
		// where it was found — prepareMemoryOfferAction returning false and
		// nothing else happening — so the reply went out without the button the
		// answer had just promised, and the model, never told which field it
		// got wrong, proposed the same thing next time.
		if correction == "" && offerInput.ID != "" {
			if rejected := s.reportOfferRejectionCorrection(
				ctx, offerInput, report,
			); rejected != "" {
				correction, correctionKind = rejected, correctionRejected
			}
		}
		if correction == "" && trigger != "" {
			shape, shapeErr := s.incidentReplyShapeCorrection(ctx, run, trigger, report.Message)
			if shapeErr != nil {
				return true, shapeErr
			}
			if shape != "" {
				correction, correctionKind = shape, correctionShape
			}
		}
		if correction != "" {
			if preflight {
				return true, &semanticCandidateViolation{detail: correction}
			}
			spent, spendErr := s.spendStructuredCorrectionWithin(
				ctx, run, evidence, coverage, findings,
				min(s.cfg.Limits.MaxAgentRunAttempts, resultrecovery.SemanticAttemptLimit),
			)
			if spendErr != nil {
				return true, spendErr
			}
			if !spent {
				if err := s.requeueWithCorrection(
					ctx, run, correctionKind, correction, cursor,
				); err != nil {
					return true, err
				}
				return true, nil
			}
			switch correctionKind {
			case correctionRejected:
				// A rejected offer is not a failed turn. Blocking here would
				// replace a correct answer with "I couldn't finish this check
				// safely yet" over a malformed button — worse than the silence
				// this correction replaced, not better. Drop the offer that
				// failed, keep the answer and the offers that were fine, and
				// tell the operator what was dropped.
				if taskOfferRejected {
					taskofferrejection.DropReport(&report)
				}
				s.dropRejectedReportOffers(ctx, offerInput, &report, run)
			case correctionShape:
				// An answer refused only for its shape still gets posted; see
				// replyShapeCorrection for why the alternative is worse.
				s.recordUnshapedReply(ctx, run, correction)
			default:
				report = resultrecovery.SemanticAgent(correction, report)
				s.audit(ctx, resultrecovery.ReplyFallbackAudit(run, "semantic_invalid",
					"Rejected unsafe structured claims and delivered the bounded completion reply."))
			}
			if reportErr = staged.setResult(resultwire.AgentReport(report)); reportErr != nil {
				return true, reportErr
			}
		} else if preflight {
			return false, nil
		} else if err := s.recordResultOperationEvents(
			ctx, run.ID, report.AppliedOperations,
		); err != nil {
			return true, err
		} else if err := s.branches.Open(
			ctx, run, report.AppliedOperations,
		); err != nil {
			// After the operations are applied, never before: the ambiguity a
			// branch is funded against is measured from the ledger this turn
			// just finished writing into.
			return true, err
		}
	}
	if err := staged.setResult(resultwire.AgentReport(report)); err != nil {
		return true, err
	}
	return false, nil
}

func (s *Service) engineeringWorkspaceCompletionCorrection(
	ctx context.Context,
	run core.AgentRun,
) (string, error) {
	assembled, _ := decodeAssembledAgentContext(run.Context)
	changes, err := s.coop.Changes(ctx, run.SessionID)
	if err != nil {
		return "", fmt.Errorf("inspect engineering workspace before completion: %w", err)
	}
	return taskcompletion.WorkspaceCorrection(
		assembled.InitialTaskChangesFingerprint, changes,
	), nil
}

// recordTurnCost keeps what a finished Coop turn cost — provider-reported
// money, tokens and wall-clock — on the attempt's context manifest.
//
// It returns nothing. Accounting is not worth failing a turn over: the answer
// the operator is waiting for is already computed, and dropping it because a
// statistic could not be written would trade the product for the statistic.
//
// s.now() is the fourth timestamp and it is the host's own. Coop reports when
// the turn was queued, started and finished; only Ryker knows when it got
// round to noticing, and that gap is the part of a slow reply this repository
// can actually do something about.
//
// The tokens are passed even when the provider reported none. The store drops a
// write with nothing in it, and gating here on usage would have thrown away the
// timings too — which is the entire measurement, since Coop's ACP path reports
// no usage at all today.
func (s *Service) recordTurnCost(ctx context.Context, run core.AgentRun, turn coop.Turn) {
	if run.AttemptID == "" || turn.ID == "" {
		return
	}
	if err := s.store.RecordAttemptTurnCost(ctx, run.AttemptID, turn.ID, core.ContextUsage{
		InputTokens:       turn.Usage.InputTokens,
		CachedInputTokens: turn.Usage.CachedInputTokens,
		OutputTokens:      turn.Usage.OutputTokens,
		ReasoningTokens:   turn.Usage.ReasoningTokens,
		CostUSD:           turn.Usage.CostUSD,
		CostedTurns:       turn.Usage.CostedTurns(),
	}, core.NewContextLatency(
		turn.QueuedAt, turn.StartedAt, turn.FinishedAt, s.now(),
	)); err != nil && s.log != nil {
		s.log.Warn(
			"could not record what a finished turn cost",
			"run", run.ID, "attempt", run.AttemptID, "error", err,
		)
	}
}

func (s *Service) stagePolledAgentRunTerminal(
	ctx context.Context,
	run core.AgentRun,
	eventType string,
	turn coop.Turn,
	cursor int64,
) error {
	// Record what the turn spent before deciding what to do with it. Every
	// branch below can leave: a correction requeues the run, a rotated session
	// replays it, a missing image defers it. Those are the turns an attempt
	// takes on the way to an answer, and they cost tokens and minutes like any
	// other, so waiting until the run reaches its final result would bill an
	// attempt for its last turn only and lose every turn it took to get there.
	s.recordTurnCost(ctx, run, turn)
	detail := strings.TrimSpace(
		core.FirstNonempty(turn.ErrorDetail, turn.ErrorCode, turn.StopReason),
	)
	if eventType == "turn.failed" {
		continued, err := resultrecovery.ContinueSemanticContractRepair(
			ctx, s.store, run, turn.ErrorCode, turn.ValidationError, cursor,
			func(ctx context.Context, run core.AgentRun, correction string, cursor int64) error {
				return s.requeueWithCorrection(ctx, run, correctionIncomplete, correction, cursor)
			},
		)
		if err != nil || continued {
			return err
		}
	}
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
			delay := max(30*time.Second, retrydelay.Duration(run.Failures+1))
			s.parkWatchedStatus(ctx, run, "clear watched Slack status while Coop is unavailable")
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
	if reason, replay := runreplay.Decide(
		run, eventType, turn, s.cfg.Limits.MaxAgentRunAttempts,
	); replay {
		contextJSON, changed, err := runreplay.MarkReplayed(run.Context, turn)
		if err != nil {
			return err
		}
		if changed {
			if err := s.store.SetAgentRunContext(ctx, run.ID, contextJSON); err != nil {
				return err
			}
			run.Context = contextJSON
		}
		if run.Mode == core.AgentRunTriage &&
			runreplay.FreshSession(turn) {
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
		// Transport recovery is not a model correction and must not inflate its rate.
		if err := s.store.RequeueAgentRun(
			ctx, run.ID, reason, cursor, s.now(), true,
		); err != nil {
			return err
		}
		if run.Mode == core.AgentRunTriage {
			_ = s.advanceTriageSessionEvents(ctx, run, cursor)
		}
		return nil
	}
	terminalState := strings.TrimPrefix(eventType, "turn.")
	// A turn the provider refused is not a turn that failed. This is the path
	// a refusal actually takes — Coop reports turn.failed and the result is
	// staged as terminal without any retry function seeing it, which is why a
	// refused run ended as 'failed' with failure_count 0 while three other
	// guards were in place.
	if terminalState == "failed" {
		if requeued, err := s.requeueIfRateLimited(ctx, run, errors.New(detail)); requeued {
			return err
		}
	}
	if terminalState == "completed" && turn.ValidationAttempt > 0 && turn.ValidationReceipt == "" {
		return errors.New("Coop completed a semantic candidate without an acceptance receipt")
	}
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
	// A parked run is no longer the run that will answer, so it hands back the
	// acknowledgement as well as the status. Zeroing the acknowledgement in the
	// context without unreacting would strand the mark on the card forever.
	return s.retireWatchRunPresence(ctx, run, input, &state)
}

// retryMalformedIncidentReport sends an unreadable result back to the model
// with a description of what was wrong, and reports whether it did.
//
// It returns false only once the correction budget is spent, which is the point
// at which a person has to be told something. Until then the operator sees
// nothing: they asked a question, and Ryker failing to parse its own
// model's answer is not news to them.
func (s *Service) retryMalformedIncidentReport(
	ctx context.Context,
	run core.AgentRun,
	reportErr error,
) (bool, error) {
	spent, err := s.spendStructuredCorrection(ctx, run, nil, nil, nil)
	if err != nil || spent {
		return false, err
	}
	invalid := trimError(reportErr)
	correction := "the structured response is invalid: " + invalid +
		"\n\nReturn the same result in the documented structured format. " +
		"Keep the evidence and conclusions you already have; only the envelope was wrong." +
		investigation.SchemaFragmentForCorrection(string(correctionUnreadable), invalid)
	if err := s.requeueWithCorrection(
		ctx, run, correctionUnreadable, correction, run.CoopEventSequence,
	); err != nil {
		return false, err
	}
	return true, nil
}

// spendStructuredCorrection records one correction round against this run and
// reports whether the budget is now spent.
//
// The count lives in the run's own context envelope because failure_count no
// longer carries it: a correction is not a failed attempt, and the two numbers
// stopped being the same number. Every incident and engineering-task
// correction has to come through here, or the loop is unbounded — that budget
// used to ride on failure_count, and removing corrections from failure_count
// without this would have turned a nineteen-round loop into an endless one.
//
// A context that will not decode is treated as spent rather than rewritten.
// There is nowhere to record the correction, and writing a fresh envelope
// would replace the run's assembled context — repository, captured situations,
// and the task-changes fingerprint the publication staleness check depends on
// — with zeros. Better to stop and tell the operator than to silently destroy
// the turn's context in order to keep looping.
func (s *Service) spendStructuredCorrection(
	ctx context.Context,
	run core.AgentRun,
	evidence []core.Evidence,
	coverage []core.Coverage,
	findings []investigation.FindingOperation,
) (bool, error) {
	return s.spendStructuredCorrectionWithin(
		ctx, run, evidence, coverage, findings, s.cfg.Limits.MaxAgentRunAttempts,
	)
}

func (s *Service) spendStructuredCorrectionWithin(
	ctx context.Context,
	run core.AgentRun,
	evidence []core.Evidence,
	coverage []core.Coverage,
	findings []investigation.FindingOperation,
	maximum int,
) (bool, error) {
	assembled, ok := decodeAssembledAgentContext(run.Context)
	if !ok {
		return true, nil
	}
	assembled.StructuredCorrections++
	assembled.CarriedEvidence = decisionpkg.CarryEvidence(assembled.CarriedEvidence, evidence)
	assembled.CarriedCoverage = decisionpkg.CarryCoverage(assembled.CarriedCoverage, coverage)
	assembled.CarriedFindings = decisionpkg.CarryFindings(assembled.CarriedFindings, findings)
	episodeCorrections, err := s.episodeStructuredCorrections(ctx, run)
	if err != nil {
		return true, err
	}
	if resultrecovery.CorrectionSpent(
		assembled.StructuredCorrections, episodeCorrections, maximum,
	) {
		return true, nil
	}
	contextJSON, err := json.Marshal(assembled)
	if err != nil {
		return true, err
	}
	return false, s.store.SetAgentRunContext(ctx, run.ID, contextJSON)
}

// episodeStructuredCorrections is how many host corrections this run's episode
// has already spent, across every run it contains. A run with no episode is its
// own whole episode, so its own counter is the total.
func (s *Service) episodeStructuredCorrections(
	ctx context.Context,
	run core.AgentRun,
) (int, error) {
	if run.EpisodeID == "" {
		return 0, nil
	}
	return s.store.SumEpisodeStructuredCorrections(ctx, run.EpisodeID)
}

func (s *Service) advanceTriageSessionEvents(
	ctx context.Context,
	run core.AgentRun,
	cursor int64,
) error {
	// A handoff runs in a session the channel projection has already unbound,
	// so there is no row for this pair to advance and asking for one fails the
	// poll that asked.
	if isSessionHandoffRun(run) {
		return nil
	}
	state, err := decodeWatchRunContext(run)
	if err == nil && state.Lane == "conversation" {
		return benignlyUnboundSessionCursor(s.store.AdvanceConversationSessionEvents(
			ctx, run.ChannelID, run.SessionID, cursor,
		))
	}
	sessionChannelID := run.ChannelID
	if err == nil {
		sessionChannelID = core.FirstNonempty(state.SessionChannelID, run.ChannelID)
	}
	return benignlyUnboundSessionCursor(s.store.Intelligence.AdvanceChannelEvents(
		ctx, sessionChannelID, run.SessionID, cursor,
	))
}

// benignlyUnboundSessionCursor treats "no row for this channel and session" as
// the bookkeeping no-op it is.
//
// The channel projection can rotate to a new session while a turn from the old
// one is still running — session handoff retires sessions on exactly that
// schedule. The cursor row belongs to the channel's CURRENT session; once the
// channel has moved on there is nothing left for the old run to advance, and
// the run's own cursor in agent_runs was already written by the caller. Before
// this, the miss failed the whole poll: run_68972d3 looped "advance channel
// Coop events: conflict" every backoff interval on the evening the handoff
// landed, holding its channel's queue behind a bookkeeping write aimed at a
// row that no longer existed.
func benignlyUnboundSessionCursor(err error) error {
	if errors.Is(err, store.ErrConflict) || errors.Is(err, store.ErrNotFound) {
		return nil
	}
	return err
}

// interruptedAsFailed folds Coop's interrupted terminal into the failed one
// the staging path already knows: an interruption is a turn that will not
// finish, and the replay decision reads the turn's own error code to say why.
func interruptedAsFailed(eventType string) string {
	if eventType == "turn.interrupted" {
		return "turn.failed"
	}
	return eventType
}

// parkWatchedStatus clears a watched channel's pending Slack status when a run
// is about to wait rather than answer, so the channel does not sit showing work
// in progress. Failing to clear it is cosmetic and never blocks the wait.
func (s *Service) parkWatchedStatus(ctx context.Context, run core.AgentRun, why string) {
	if run.Mode != core.AgentRunTriage || isSessionHandoffRun(run) {
		return
	}
	if err := s.parkWatchRunPendingStatus(ctx, run); err != nil {
		s.log.Warn(why, "run", run.ID, "error", err)
	}
}

func missingCoopImageFailure(turn coop.Turn) bool {
	return turn.ErrorCode == "acp_process_error" && strings.Contains(
		strings.ToLower(strings.TrimSpace(turn.ErrorDetail)),
		"coop box image is not built",
	)
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
		run.EpisodeID,
		input.ChannelID,
		threadTS,
		watchPendingStatus,
		slackui.WatchProgressSteps(),
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
	runCtx, release := ctx, func() {}
	if s.runCancels != nil {
		runCtx, release = s.runCancels.Track(ctx, run.ID, run.IdempotencyKey)
	}
	defer release()
	if s.agentRunCancellationApplied(runCtx, run.ID) {
		return nil
	}
	var finalizeErr error
	switch run.Mode {
	case core.AgentRunTriage:
		if err := s.finalizeTriageAgentRun(runCtx, run); err != nil {
			finalizeErr = s.retryAgentRunFinalization(runCtx, run, err)
		}
	case core.AgentRunIncident, core.AgentRunEngineeringTask:
		if err := s.finalizeIncidentAgentRun(runCtx, run); err != nil {
			finalizeErr = s.retryAgentRunFinalization(runCtx, run, err)
		}
	default:
		detail := "unsupported agent run finalization mode " + string(run.Mode)
		_, _, finalizeErr = s.store.FinishAgentRunFailure(
			runCtx, run.ID, detail, nil, store.AgentRunFailureEffects{},
		)
	}
	if errors.Is(runCtx.Err(), context.Canceled) && s.agentRunCancellationApplied(ctx, run.ID) {
		return nil
	}
	return finalizeErr
}

// requeueRefusedFinalization is requeueIfRateLimited for the finalization lane.
func (s *Service) requeueRefusedFinalization(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) (bool, error) {
	detail := trimError(cause)
	delay, waits := providerBackoff[provider.Classify(detail).Kind]
	if !waits {
		return false, nil
	}
	next := s.now().Add(delay)
	if s.log != nil {
		s.log.Warn(
			"the AI provider refused this finalization; it stays queued rather than failing",
			"run", run.ID, "retry_at", next.UTC().Format(time.RFC3339), "detail", detail,
		)
	}
	return true, s.store.RequeueRateLimitedFinalization(ctx, run.ID, detail, next)
}

func (s *Service) retryAgentRunFinalization(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) error {
	// The third path a provider refusal can arrive on, after retryAgentRun and
	// retryIncidentAgentRun. It was missed when the first two were guarded, and
	// the symptom was that refusals still reached Slack — from finalization
	// rather than preparation. Anything added later that fails a run needs this
	// too.
	if requeued, err := s.requeueRefusedFinalization(ctx, run, cause); requeued {
		return err
	}
	// A completion the kernel refuses over an open required goal is not a
	// finalization that will succeed later; it is an answer the model has to
	// change. Staging asks the same question first (see OpenRequiredGoalCorrection
	// in stageTriageTerminal), so this branch is reached when the plan moved
	// between staging and finalization, or for a result staged before that
	// check existed: run_dab83e5b, forty-three finalization attempts on
	// 2026-08-15 against a goal nobody had told it about.
	if errors.Is(cause, store.ErrEpisodeGoalsOpen) && run.Mode == core.AgentRunTriage {
		goals, goalsErr := s.store.Goals.ListForEpisode(ctx, run.EpisodeID, 200)
		if goalsErr != nil {
			return goalsErr
		}
		correction := investigation.OpenRequiredGoalCorrection(
			goals, nil, &investigation.CompletionAssessment{Status: "decision_ready"},
		)
		if correction == "" {
			correction = trimError(cause)
		}
		return s.requeueWithCorrection(ctx, run, correctionIncomplete, correction, run.CoopEventSequence)
	}
	attempt := run.Failures + 1
	if attempt >= s.cfg.Limits.MaxAgentRunAttempts {
		if err := s.stageTerminalFinalizationFailure(ctx, run, cause); err == nil {
			return nil
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
	detail := "Ryker could not finalize this agent result after the configured retry limit. " +
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
		state, stateErr := decodeWatchRunContext(run)
		if stateErr != nil {
			state = decisionpkg.WatchTurnState{}
		}
		_, err = s.finishTriageRunFailureIfOwned(ctx, run, input, state, detail)
		if err != nil {
			return err
		}
		return nil
	case core.AgentRunIncident, core.AgentRunEngineeringTask:
		incident, err := s.store.GetIncident(ctx, run.IncidentID)
		if err != nil {
			return err
		}
		body, err := slackui.Encode(s.sanitizeMessage(
			slackui.TurnFailureMessage(incident, "failed", detail),
		))
		if err != nil {
			return err
		}
		delivery := &core.SlackDelivery{
			ID: executionDeliveryID("out_run_finalization_failure_"+run.ID, run.IdempotencyKey), IncidentID: incident.ID,
			EpisodeID: run.EpisodeID, AgentRunID: run.ID, Operation: "post", Kind: "assistant",
			ChannelID: incident.ChannelID, ThreadTS: incident.ConversationThreadTS(),
			Body: body, ResponseRoot: true,
		}
		effects := store.AgentRunFailureEffects{}
		if s.cfg.Slack.NativeStatus {
			effects.StatusChannelID = incident.ChannelID
			effects.StatusThreadTS = incident.ConversationThreadTS()
		}
		_, applied, err := s.store.FinishAgentRunFailure(ctx, run.ID, detail, delivery, effects)
		if err != nil {
			return err
		}
		if !applied {
			return nil
		}
		return nil
	default:
		return nil
	}
}

func (s *Service) finalizeTriageAgentRun(ctx context.Context, run core.AgentRun) error {
	if isSessionHandoffRun(run) {
		return s.finalizeSessionHandoffTurn(ctx, run)
	}
	input, err := s.store.GetSlackInput(ctx, run.SourceID)
	if err != nil {
		return err
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		return err
	}
	input = mentioncontext.Apply(input, state.ResolvedMentionRequest)
	state.SessionID = run.SessionID
	state.Repository = run.Repository
	state.Generation = run.SessionGeneration
	state.TurnID = run.CoopTurnID
	if run.TerminalState != "completed" {
		detail := strings.TrimSpace(core.FirstNonempty(run.LastError, run.TerminalState))
		return s.finishTriageRunFailure(ctx, run, input, state, detail)
	}
	if stale, staleErr := s.supersedeStaleHumanTriageResult(ctx, run, input, state); staleErr != nil || stale {
		return staleErr
	}
	// Parsed before the staleness question, not after, because the answer to
	// that question depends on what this result is. A finished reply is the
	// investigation the operator is waiting for; a newer card on the same
	// stream is the next update to it, and suppressing the reply for that
	// reason is how four answers were thrown away on 2026-08-16 — one of them
	// after fifteen minutes and forty-seven tool calls.
	decision, err := decisionpkg.ParseWatchDecision(string(run.Result), s.now())
	if err != nil {
		detail := "malformed watch decision: " + trimError(err)
		return s.finishTriageRunFailure(
			ctx, run, input, state, detail,
		)
	}
	if decision.Action != "reply" && input.Kind == "bot_message" &&
		!isPrivateSlackVerificationReplay(input) &&
		strings.HasPrefix(run.ConversationKey, "operation:") {
		newer, newerErr := s.hasNewerOperationalInput(ctx, run, input)
		if newerErr != nil {
			return newerErr
		}
		if newer {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "coalesced",
				Detail:  "suppressed a stale result because a newer operational update is queued",
			})
			if err := s.retireWatchRunPresence(ctx, run, input, &state); err != nil {
				s.log.Warn("retire a coalesced triage run's presence",
					"run", run.ID, "input", input.ID, "error", err)
			}
			return s.store.SupersedeAgentRun(
				ctx, run.ID, "superseded by a newer operational update",
			)
		}
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
		decision = attentionpkg.EnforcePrivateReplay(input, state, decision,
			s.cfg.Slack.ReplyAttention, s.cfg.Slack.ReactionAttention)
		privateDecision := attentionpkg.PrivateReplayDecision(run.EpisodeID, input, decision)
		privateDecision.AgentRunID, privateDecision.AgentRunKey = run.ID, run.IdempotencyKey
		if _, err := s.store.Intelligence.RecordEvaluationDecision(ctx,
			privateDecision); err != nil {
			return fmt.Errorf("record private replay decision: %w", err)
		}
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
		return fmt.Errorf("record triage feedback operations: %w", err)
	}
	// Before applyWatchDecision, so a repository description is saved on the
	// same terms as the rest of the turn's durable output rather than only when
	// the turn also had something to say in Slack. A silenced turn still read
	// the repository.
	if err := s.applyRepositoryContents(ctx, run, decision); err != nil {
		return fmt.Errorf("apply triage repository contents: %w", err)
	}
	if err := s.applyWatchDecision(ctx, input, state, decision, run); err != nil {
		return fmt.Errorf("apply triage watch decision: %w", err)
	}
	if err := s.scheduleEpisodeRechecks(
		ctx, run, input, state, decision.Action, decision.Completion,
	); err != nil {
		return fmt.Errorf("schedule triage episode rechecks: %w", err)
	}
	episodeState, phase, status, nextAction := lifecycle.CompletionEpisodePhase(
		decision.Completion,
		decision.PendingApproval != nil,
		decision.AppliedOperations,
		alertStreamWaitKind,
	)
	if err := s.store.SetWorkEpisodePhase(
		ctx, run.ID, episodeState, phase, status, nextAction, time.Time{},
	); err != nil {
		return fmt.Errorf("set triage episode phase: %w", err)
	}
	if err := s.store.FinishAgentRun(ctx, run.ID); err != nil {
		return fmt.Errorf("finish triage agent run: %w", err)
	}
	return nil
}

func (s *Service) hasNewerOperationalInput(
	ctx context.Context,
	run core.AgentRun,
	source core.SlackInput,
) (bool, error) {
	inputs, err := s.store.SlackInputs.NewerBotMessages(ctx, source.ID)
	if err != nil {
		return false, err
	}
	for _, input := range inputs {
		if watchConversationKey(input) == run.ConversationKey {
			return true, nil
		}
		if broadOperationalBurstCoalescingAllowed(source) &&
			broadOperationalBurstCoalescingAllowed(input) &&
			!input.ReceivedAt.After(source.ReceivedAt.Add(operationalBurstWindow)) {
			return true, nil
		}
	}
	return false, nil
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
	existing, err := s.store.Intelligence.GetConversationMemory(ctx, input.ChannelID, input.ThreadTS)
	if err == nil {
		merged = memorypkg.MergeAgentMemories([]core.AgentMemory{existing.State, merged})
	} else if !errors.Is(err, store.ErrNotFound) {
		return err
	}
	return s.store.Intelligence.UpsertConversationMemoryState(ctx, core.ConversationMemory{
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
	message := slackui.AgentReportFailureMessage(incident)
	if !decisionpkg.StructuredResultFailure(detail) {
		failure := provider.Classify(detail)
		message = slackui.TurnFailureMessage(
			incident,
			state,
			// provider.Classify already turned the provider's error into
			// something an operator can act on. Appending the raw detail after
			// it undoes that work — the classification exists precisely because
			// the raw text is not actionable. It stays in the log and the audit
			// event, where whoever is debugging Ryker will look for it.
			failure.Summary+"\n\n"+failure.OperatorFix,
		)
	}
	s.recordTimeline(ctx, core.TimelineEvent{
		ID:         executionDeliveryID("tl_agent_failure_"+run.ID, run.IdempotencyKey),
		IncidentID: incident.ID, ChannelID: incident.ChannelID,
		Kind: "agent.failure", ActorID: "responder",
		Title: "Agent turn " + state, Detail: detail,
	})
	return message
}

// withEngineeringTaskChanges marks an engineering task's published diff stale
// when this turn actually changed the working tree, and says so in the message.
//
// It compares against the fingerprint taken before the turn rather than asking
// whether the turn claimed to change anything: a model that says it edited
// nothing while leaving a dirty tree would otherwise leave a published diff
// that no longer matches the branch, which is the worst kind of wrong — it
// looks reviewed.
type engineeringTaskChanges struct {
	Message     slackui.Message
	Changed     bool
	Publication core.Publication
}

func (s *Service) withEngineeringTaskChanges(
	ctx context.Context,
	run core.AgentRun,
	incident core.Incident,
	state string,
	message slackui.Message,
) engineeringTaskChanges {
	result := engineeringTaskChanges{Message: message}
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		s.log.Warn(
			"inspect completed engineering task changes failed",
			"incident", incident.ID,
			"error", err,
		)
		return result
	}
	// The one fetch per turn that holds the whole patch rather than a page, so
	// the one place the stat can be computed honestly without asking Coop
	// again. Written unconditionally — including as "" — because a turn that
	// removed the changes has to take the old count down with it, and a stat
	// left over from two turns ago is worse than none.
	//
	// This is also what keeps the number fresh: recomputing at the end of every
	// turn is the same guarantee as clearing at the end of every turn, without
	// the window where the card knows less than it did a second ago.
	if statErr := s.store.Incidents.SetChangesStat(
		ctx, incident.ID, taskcard.ChangesStat(changes),
	); statErr != nil {
		s.log.Warn("record engineering task change stat",
			"incident", incident.ID, "error", trimError(statErr))
	}
	assembled, _ := decodeAssembledAgentContext(run.Context)
	if !taskcard.TurnCreatedChanges(assembled.InitialTaskChangesFingerprint, changes) {
		return result
	}
	result.Changed = true
	publication, publicationErr := s.markTaskPublicationStale(ctx, incident)
	result.Publication = publication
	if publicationErr != nil {
		s.log.Error(
			"mark changed engineering task publication stale",
			"incident", incident.ID,
			"error", publicationErr,
		)
	}
	if state != "completed" {
		return result
	}
	var followup core.PublicationFollowup
	followup, followupErr := s.store.PublicationFollowups.Get(ctx, incident.ID)
	if followupErr != nil && !errors.Is(followupErr, core.ErrNotFound) {
		s.log.Warn(
			"load publication follow-up for engineering delivery",
			"incident", incident.ID, "error", followupErr,
		)
	}
	result.Message = slackui.WithEngineeringTaskDelivery(
		message, incident, true, publication, followup,
	)
	return result
}

func (s *Service) finalizeIncidentAgentRun(
	ctx context.Context,
	run core.AgentRun,
) error {
	if fanout.IsBranch(run.ConversationKey) {
		return s.branches.Finish(ctx, run)
	}
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
	var episodeCompletion *CompletionAssessment
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
			// Tell the model, not the operator. A result Ryker cannot read
			// is Ryker's problem: the person asked a question and a schema
			// mismatch is not an answer to it. The watch path has always
			// corrected and retried here; this one used to post the parse error
			// to Slack and stop.
			retried, retryErr := s.retryMalformedIncidentReport(ctx, run, reportErr)
			if retryErr != nil {
				return retryErr
			}
			if retried {
				return nil
			}
			// Out of corrections. Say so in the operator's terms — what was
			// lost, what survived, and what they can do — without the parse
			// error, which means nothing to them.
			message = slackui.AgentReportFailureMessage(incident)
			s.recordTimeline(ctx, core.TimelineEvent{
				ID:         executionDeliveryID("tl_agent_failure_"+run.ID, run.IdempotencyKey),
				IncidentID: incident.ID, ChannelID: incident.ChannelID,
				Kind: "agent.failure", ActorID: "responder",
				Title:  "Agent result could not be rendered",
				Detail: decisionpkg.BoundedField(trimError(reportErr), 1000),
			})
		} else {
			episodeCompletion = report.Completion
			episodeOperations = report.AppliedOperations
			// A model may propose that an action earned the next rung. It is a
			// proposal and nothing else: the host recomputes the count from its
			// own outcomes, refuses anything it cannot reproduce, fills the whole
			// trigger class itself, and still ends at a card only an operator can
			// press. Logged rather than returned, because a promotion offer is an
			// addition to a report that has already been produced.
			if offer := report.GrantOffer; offer != nil {
				if err := s.offerGrantPromotion(
					ctx, incident.ID, run.EpisodeID, incident.ChannelID, "grant_offer_"+run.ID,
					remediation.ActionRef{
						ActionID: offer.ActionID, PackRef: offer.PackRef, RunnerRef: offer.RunnerRef,
					},
					remediation.Rung(offer.Rung), offer.VerifiedSuccesses, offer.Rationale,
				); err != nil && ctx.Err() == nil {
					s.log.Warn("offer remediation grant promotion", "run", run.ID, "error", err)
				}
			}
			// The same shape one line up, for the other thing a verified fix
			// can become. Read from the operations rather than a folded field:
			// an episode may propose a runbook AND a card, and they are two
			// decisions rather than one.
			s.offerEpisodeKnowledge(
				ctx, run, incident.ID, incident.ChannelID, episodeOperations,
			)
			// And once more for the offer that asks for the most: standing
			// authority to open pull requests for a recurring signal without
			// anyone clicking again. Same shape, same silence when the bounds
			// cannot be normalized, and the same rule that nothing exists
			// before the operator's click.
			s.offerStandingAssignment(
				ctx, run, incident.ID, incident.ChannelID, episodeOperations,
			)
			if conversation && s.cfg.IsOperator(conversationInput.UserID) {
				offers, acknowledgement, replaced := operatorofferspkg.Normalize(
					conversationInput,
					core.FirstNonempty(run.Repository, incident.Repository),
					operatorofferspkg.Offers{
						Memory:     report.MemoryOffer,
						Preference: report.PreferenceOffer,
						Rule:       report.RuleOffer,
						Schedule:   report.ScheduleOffer,
						Schedules:  report.ScheduleOffers,
					},
				)
				report.MemoryOffer, report.PreferenceOffer = offers.Memory, offers.Preference
				report.RuleOffer, report.ScheduleOffer = offers.Rule, offers.Schedule
				report.ScheduleOffers = offers.Schedules
				if replaced {
					report.Message = acknowledgement
					report.FollowupMessages = nil
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
				run.EpisodeID,
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
					s.sanitizer,
				)
				if actionValue, permanent, scope, expires, ok := s.prepareMemoryOfferAction(
					conversationInput,
					report.MemoryOffer,
				); ok {
					message = slackui.WithMemoryOffer(
						message, *report.MemoryOffer, actionValue, permanent, scope, expires,
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
				scheduleOffers := OrderedScheduleOffers(report.ScheduleOffer, report.ScheduleOffers)
				if len(scheduleOffers) != 0 {
					if actionValue, tasks, whens, ok := s.prepareScheduleOffersAction(
						ctx, conversationInput, scheduleOffers,
					); ok {
						if schedulepkg.ExplicitScheduleConfirmation(
							s.stripBotMention(conversationInput.Text),
						) && agentReportCanActivateSchedule(report) {
							proposalIDs, _, err := scheduleofferpkg.DecodeAction(actionValue)
							if err != nil {
								return err
							}
							acceptedTasks, err := s.acceptScheduleProposals(
								ctx, conversationInput, proposalIDs,
							)
							if err != nil {
								return err
							}
							for _, acceptedTask := range acceptedTasks {
								s.audit(ctx, core.AuditEvent{
									Kind: "schedule.created", ActorID: conversationInput.UserID,
									ObjectID: acceptedTask.ID, Outcome: "enabled", Detail: acceptedTask.Title,
								})
							}
							message = slackui.SchedulesSavedMessage(acceptedTasks)
						} else {
							message = slackui.WithScheduleOffers(message, tasks, actionValue, whens)
						}
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
			// The same line for the deep lanes' own replies. Structured alert
			// assessment now survives escalation, so the open cause boundary and
			// the next check stay attached to the host-rendered bounded scope.
			open := openquestions.ForPublicReply(decisionpkg.WatchDecision{
				Completion: report.Completion, Findings: report.Findings,
				AlertAssessment:   report.AlertAssessment,
				AppliedOperations: episodeOperations,
			})
			message = slackui.WithOpenQuestions(
				message, open.CauseStatus, open.Cause, open.MaterialGaps,
				open.Unexplained, open.NextCheck, s.sanitizer,
			)
			// The questions carry controls, which is also what keeps an
			// engineering task's ask off the durable card and on a message of
			// its own: standaloneTaskResult below reads HasControls, and the
			// card discards everything but the reply text.
			if questions := operatorchoice.Questions(episodeOperations); len(questions) > 0 {
				message = slackui.WithOperatorQuestions(
					message,
					run.EpisodeID,
					core.FirstNonempty(conversationInput.UserID, run.UserID),
					questions,
					s.sanitizer,
				)
			}
			evidenceIDs := make([]string, 0, len(report.Evidence))
			for _, evidence := range report.Evidence {
				evidenceIDs = append(evidenceIDs, evidence.ID)
			}
			s.recordTimeline(ctx, core.TimelineEvent{
				ID:          executionDeliveryID("tl_agent_finding_"+run.ID, run.IdempotencyKey),
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
	// A task result normally belongs on the durable task card. An explicit
	// confirmation or approval keeps its own message because its controls must
	// remain attached to the exact proposal the operator is accepting.
	standaloneTaskResult := incident.IsEngineeringTask() &&
		(pendingApproval != nil || message.HasControls())
	var automaticPublication *core.SlackInput
	if incident.IsEngineeringTask() {
		changes := s.withEngineeringTaskChanges(ctx, run, incident, state, message)
		message = changes.Message
		if state == "completed" && changes.Changed && !standaloneTaskResult {
			input, err := taskpublication.AutomaticPublication(
				ctx, s.cfg, s.store, incident, changes.Publication,
				inputTaskPublication, run.ID, run.UserID, s.now().UTC())
			if err != nil {
				s.log.Warn("resolve task authority for automatic draft PR",
					"incident", incident.ID, "error", trimError(err))
			}
			automaticPublication = input
		}
	}
	baseDeliveryID := executionDeliveryID("out_run_"+run.ID, run.IdempotencyKey)
	if incident.IsEngineeringTask() && !standaloneTaskResult {
		if err := s.updateEngineeringTaskCard(ctx, run.ID, incident, message, reportReplyParts); err != nil {
			return err
		}
	} else if len(reportReplyParts) > 1 {
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
	if incident.IsEngineeringTask() && !standaloneTaskResult {
		if len(visuals) > 0 {
			if err := s.enqueueGeneratedVisuals(
				ctx, deliveryID, incident.ID, run.EpisodeID, run.SourceID, incident.ChannelID, threadTS,
				run.SessionID, run.CoopTurnID, visuals, nil,
			); err != nil {
				return err
			}
		}
	} else if len(visuals) == 0 {
		if err := s.enqueueEpisode(
			ctx,
			deliveryID,
			run.EpisodeID,
			incident,
			"assistant",
			threadTS,
			message,
			true,
		); err != nil {
			return err
		}
	} else if err := s.enqueueGeneratedVisuals(
		ctx, deliveryID, incident.ID, run.EpisodeID, run.SourceID, incident.ChannelID, threadTS,
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
		episodeState, phase, status, nextAction := lifecycle.CompletionEpisodePhase(
			episodeCompletion,
			pendingApproval != nil,
			episodeOperations,
			alertStreamWaitKind,
		)
		if err := s.store.SetWorkEpisodePhase(
			ctx, run.ID, episodeState, phase, status, nextAction, time.Time{},
		); err != nil {
			return fmt.Errorf("set incident episode phase: %w", err)
		}
	}
	var finishErr error
	if automaticPublication == nil {
		finishErr = s.store.FinishAgentRun(ctx, run.ID)
	} else {
		finishErr = s.store.FinishAgentRun(ctx, run.ID, *automaticPublication)
	}
	if finishErr != nil {
		return fmt.Errorf("finish incident agent run: %w", finishErr)
	}
	s.forgetNativeStatus(incident.ID)
	return nil
}

func agentReportCanActivateSchedule(report decisionpkg.AgentReport) bool {
	return len(OrderedScheduleOffers(report.ScheduleOffer, report.ScheduleOffers)) != 0 && report.MemoryOffer == nil &&
		report.PreferenceOffer == nil && report.RuleOffer == nil &&
		report.PendingApproval == nil && len(report.Visuals) == 0
}

func (s *Service) finishTriageRunFailure(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	detail string,
) error {
	_, err := s.finishTriageRunFailureIfOwned(ctx, run, input, state, detail)
	return err
}

func (s *Service) finishTriageRunFailureIfOwned(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	detail string,
) (bool, error) {
	var delivery *core.SlackDelivery
	var err error
	message := slackui.TriageFailureMessage(run.CoopTurnID != "")
	if state.ApprovalContinuation {
		message = slackui.ApprovalVerificationFailureMessage()
	}
	delivery, err = s.terminalTriageFailureDelivery(run, input, state, message)
	if err != nil {
		return false, err
	}
	effects := store.AgentRunFailureEffects{}
	if s.cfg.Slack.NativeStatus && !isPrivateSlackVerificationReplay(input) {
		effects.StatusChannelID = input.ChannelID
		effects.StatusThreadTS = watchRunStatusThread(input, state)
	}
	if !state.ApprovalContinuation && state.SessionID != "" {
		effects.SessionID = state.SessionID
		effects.SessionChannelID = core.FirstNonempty(state.SessionChannelID, input.ChannelID)
		effects.SessionGeneration = state.Generation
		effects.ConversationSession = state.Lane == "conversation"
	}
	finalState, applied, err := s.store.FinishAgentRunFailure(
		ctx, run.ID, detail, delivery, effects,
	)
	if err != nil {
		return false, err
	}
	if !applied {
		return false, nil
	}
	if finalState == core.AgentRunCompleted {
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
			Outcome: "completed", Detail: "preserved the already-staged reply",
		})
		return true, nil
	}
	if err := s.clearWatchAcknowledgement(ctx, input, state); err != nil && s.log != nil {
		s.log.Warn("clear terminal triage acknowledgement", "run", run.ID, "error", err)
	}
	s.clearInputPaused(ctx, input)
	outcome := "failed_silent"
	if delivery != nil {
		outcome = "failed_notified"
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
		Outcome: outcome, Detail: detail,
	})
	return true, nil
}
