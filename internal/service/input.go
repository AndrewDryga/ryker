package service

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode"

	"github.com/AndrewDryga/responder/internal/channelsetup"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	publicationreview "github.com/AndrewDryga/responder/internal/publicationreview"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/publicationstore"
)

type frozenAction struct {
	SessionID string `json:"session_id"`
	TurnID    string `json:"turn_id,omitempty"`
	Revision  int64  `json:"revision"`
}

const changesPatchPageBytes = 7000

type changesCursor struct {
	IncidentID string `json:"i"`
	Offset     int64  `json:"o"`
	Digest     string `json:"d,omitempty"`
}

type coopChangesPager interface {
	ChangesPage(context.Context, string, int64, int) (coop.Changes, error)
}

func encodeChangesCursor(cursor changesCursor) string {
	data, err := json.Marshal(cursor)
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(data)
}

func decodeChangesCursor(value string) (changesCursor, bool) {
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(data) > 1024 {
		return changesCursor{}, false
	}
	var cursor changesCursor
	if err := json.Unmarshal(data, &cursor); err != nil ||
		cursor.IncidentID == "" || cursor.Offset < 0 ||
		(cursor.Digest != "" && len(cursor.Digest) != sha256.Size*2) {
		return changesCursor{}, false
	}
	return cursor, true
}

func changesActionIncidentID(actionID string, value string) (string, bool) {
	switch actionID {
	case slackui.ActionChanges:
		return value, value != ""
	case slackui.ActionPublishPR:
		incidentID, _, _ := slackui.DecodePublicationActionValue(value)
		return incidentID, incidentID != ""
	case slackui.ActionChangesPrevious,
		slackui.ActionChangesNext,
		slackui.ActionChangesRefresh:
		cursor, ok := decodeChangesCursor(value)
		return cursor.IncidentID, ok
	default:
		return value, value != ""
	}
}

// inputAppHome is a Slack surface refresh. It carries no operator instruction:
// it only repaints the App Home, so it is admitted like any other input and
// performed by the control lane rather than on the socket consumer.
const inputAppHome = "app_home"

// slackActionRoutes maps a host-owned Slack button to the handler that owns it.
// Routing is a table rather than a branch chain so the full set of interactive
// controls is greppable in one place and adding a control cannot accidentally
// skip the shared retry policy applied by processSlackInput.
//
// Controls that are not a single fixed action ID stay out of the table:
// deterministic slash-command buttons, channel-setup actions with a structured
// ID, and incident-scoped controls all need their own predicate.
var slackActionRoutes = map[string]func(*Service, context.Context, core.SlackInput) error{
	slackui.ActionOpenIncident:            (*Service).handleWatchIncidentOfferAction,
	slackui.ActionStartTask:               (*Service).handleWatchTaskOfferAction,
	slackui.ActionReviewPullRequest:       (*Service).handlePullRequestReviewAction,
	slackui.ActionOpenApproval:            (*Service).handleOpenEmisarApproval,
	slackui.ActionOpenWorkThread:          (*Service).acknowledgeLinkAction,
	slackui.ActionRememberMemory:          (*Service).handleRememberMemory,
	slackui.ActionForgetMemory:            (*Service).handleForgetMemory,
	slackui.ActionForgetMemoryRollup:      (*Service).handleForgetMemoryRollup,
	slackui.ActionDismissFeedback:         (*Service).handleDismissFeedback,
	slackui.ActionConvertFeedback:         (*Service).handleConvertFeedback,
	slackui.ActionConvertFeedbackBrief:    (*Service).handleConvertFeedbackToBriefer,
	slackui.ActionKeepFixtureCandidate:    (*Service).handleKeepFixtureCandidate,
	slackui.ActionDiscardFixtureCandidate: (*Service).handleDiscardFixtureCandidate,
	slackui.ActionReviewMemory:            (*Service).finishMemoryReview,
	slackui.ActionKeepMemoryReview:        (*Service).handleMemoryReview,
	slackui.ActionForgetMemoryReview:      (*Service).handleMemoryReview,
	slackui.ActionMergeMemoryReview:       (*Service).handleMemoryReview,
	slackui.ActionDismissMemoryReview:     (*Service).handleMemoryReview,
	slackui.ActionRememberPreference:      (*Service).handleRememberPreference,
	slackui.ActionTogglePreference:        (*Service).handleTogglePreference,
	slackui.ActionEditPreference:          (*Service).handleEditPreference,
	slackui.ActionDeletePreference:        (*Service).handleDeletePreference,
	slackui.ActionRememberRule:            (*Service).handleRememberRule,
	slackui.ActionToggleRule:              (*Service).handleToggleRule,
	slackui.ActionEditRule:                (*Service).handleEditRule,
	slackui.ActionDeleteRule:              (*Service).handleDeleteRule,
	slackui.ActionRememberSchedule:        (*Service).handleRememberSchedule,
	slackui.ActionToggleSchedule:          (*Service).handleToggleSchedule,
	slackui.ActionRunSchedule:             (*Service).handleRunScheduleNow,
	slackui.ActionEditSchedule:            (*Service).handleEditSchedule,
	slackui.ActionDeleteSchedule:          (*Service).handleDeleteSchedule,
}

// acknowledgeLinkAction completes a button whose entire job is its URL.
//
// Slack opens the link in the client and still delivers a block_actions
// payload, which has to be accepted or the button reports a failure to the
// person who clicked it. There is no server-side work to do and nothing to
// reply with.
//
// Saying so explicitly matters because the alternative is not "nothing
// happens". The Open button on the App Home fell through to the incident
// controls, which looked its commitment ID up as an incident, did not find one,
// and tried to explain that in an ephemeral message — in the App Home, which is
// not a channel. Slack answered channel_not_found twelve times over twenty-one
// minutes for a button that had already done its job.
func (s *Service) acknowledgeLinkAction(ctx context.Context, input core.SlackInput) error {
	return s.finishSlackInput(ctx, input)
}

// routeSlackInputKind handles every Slack input whose destination is decided by
// its kind or its action ID alone. It reports whether the input was consumed;
// anything it does not consume needs conversation and incident context.
func (s *Service) routeSlackInputKind(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if input.Kind == "reaction_added" || input.Kind == "reaction_removed" {
		s.audit(ctx, core.AuditEvent{
			Kind:     "slack.reaction",
			ActorID:  input.UserID,
			ObjectID: input.ActionValue,
			Outcome:  strings.TrimPrefix(input.Kind, "reaction_"),
			Detail:   input.ActionID,
		})
		if err := s.recordReactionFeedback(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, s.finishSlackInput(ctx, input)
	}
	if input.Kind == inputAppHome {
		if err := s.publishOperationsHome(ctx, input.UserID); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, s.finishSlackInput(ctx, input)
	}
	if input.Kind == "recheck" {
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, nil
	}
	if reason, ignore := deterministicExternalLifecycleIgnore(input); ignore {
		inspect, err := s.shouldInspectPendingExternalLifecycle(ctx, input)
		if err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		if inspect {
			if err := s.queueWatchedInput(ctx, input); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			return true, nil
		}
		if err := s.completeIgnoredLifecycleInput(ctx, input, reason); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, nil
	}
	// Private verification replays exercise the normal model and tool path, but
	// cannot impersonate a new human turn or enter a delivery-producing handler.
	if isPrivateSlackVerificationReplay(input) {
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, nil
	}
	if input.Kind == "channel_lifecycle" {
		if err := s.processChannelLifecycleInput(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, s.finishSlackInput(ctx, input)
	}
	if input.Kind == "channel_joined" {
		if err := s.startChannelConfiguration(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, nil
	}
	if input.Kind == "slash" {
		if err := s.processSlashInput(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, nil
	}
	if input.Kind == "action" {
		if command, ok := slashTextForCommandAction(input); ok {
			input.Text = command
			if err := s.processSlashInput(ctx, input); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			return true, nil
		}
		// A list surface repeats one action across its rows, and Slack requires
		// distinct action_ids, so Blocks suffixes the copies. Route on the action
		// itself; which copy was clicked is already carried in ActionValue.
		input.ActionID = slackui.BaseActionID(input.ActionID)
		if handler, ok := slackActionRoutes[input.ActionID]; ok {
			if err := handler(s, ctx, input); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			return true, nil
		}
		if channelsetup.IsChannelSetupAction(input.ActionID) {
			if err := s.handleChannelConfigurationAction(ctx, input); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			return true, nil
		}
	}
	if input.Kind == "shortcut" {
		allowed, allowedErr := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
		if allowedErr != nil {
			return true, s.retrySlackInput(ctx, input, allowedErr)
		}
		if !allowed {
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.shortcut", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "ignored", Detail: "requester is not an active full workspace member",
			})
			return true, s.finishSlackInput(ctx, input)
		}
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, nil
	}

	return false, nil
}

// handleConversationPrefix answers the parts of an ordinary message that are
// resolved before any incident lookup: an in-flight configuration or preference
// reply, a retained visual retry, an empty mention, and the deterministic
// channel-setup and conversational commands. It reports whether the input was
// consumed.
func (s *Service) handleConversationPrefix(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if input.Kind != "message" && input.Kind != "mention" && input.Kind != "direct" {
		return false, nil
	}
	handled, configurationErr := s.processConfigurationReply(ctx, input)
	if configurationErr != nil {
		return true, s.retrySlackInput(ctx, input, configurationErr)
	}
	if handled {
		return true, nil
	}
	handled, scheduleConfirmationErr := s.confirmPendingScheduleReply(ctx, input)
	if scheduleConfirmationErr != nil {
		return true, s.retrySlackInput(ctx, input, scheduleConfirmationErr)
	}
	if handled {
		return true, nil
	}
	handled, confirmationErr := s.confirmPendingPreferenceReply(ctx, input)
	if confirmationErr != nil {
		return true, s.retrySlackInput(ctx, input, confirmationErr)
	}
	if handled {
		return true, nil
	}
	handled, visualErr := s.retryRetainedGeneratedVisual(ctx, input)
	if visualErr != nil {
		return true, s.retrySlackInput(ctx, input, visualErr)
	}
	if handled {
		return true, nil
	}
	text := strings.TrimSpace(s.stripBotMention(input.Text))
	if text == "" && len(input.Attachments) == 0 && input.ThreadTS == "" {
		if input.Kind == "direct" {
			if err := s.postInputMessageInSourceThread(
				ctx,
				"mention_prompt_"+input.ID,
				input,
				slackui.ConversationResponse(
					"What should I check?",
					s.sanitizer,
				),
			); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
		}
		if input.Kind != "mention" {
			return true, s.finishSlackInput(ctx, input)
		}
	}
	if input.Kind == "mention" || input.Kind == "direct" ||
		(input.Kind == "message" && s.cfg.IsOperator(input.UserID)) {
		if channelsetup.ExplicitChannelConfigurationRequest(text) {
			if !s.cfg.IsOperator(input.UserID) {
				return true, s.finishSlashInput(
					ctx, input,
					"**Only a configured operator can change channel behavior.** No settings were changed.",
				)
			}
			if err := s.startChannelConfiguration(ctx, input); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			return true, nil
		}
		if command, ok := channelsetup.ConversationalCommand(text); ok {
			input.Kind = "conversation_command"
			input.Text = command
			if err := s.processSlashInput(ctx, input); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			return true, nil
		}
	}
	return false, nil
}

// handleUnboundConversation decides whether a message with no incident behind
// it should still start work, and answers the requests that are complete on
// their own. Admission is deliberately explicit: a proactive channel, a
// standing rule, a direct message, a live follow-up window, a summon, or an
// operator behavior request. It reports whether the input was consumed.
func (s *Service) handleUnboundConversation(
	ctx context.Context,
	input core.SlackInput,
	incidentErr error,
) (bool, error) {
	var err error
	watched := false
	directRequest := errors.Is(incidentErr, store.ErrNotFound) &&
		input.Kind == "direct"
	summoned := errors.Is(incidentErr, store.ErrNotFound) &&
		input.Kind == "mention"
	conversationFollowup := false
	if errors.Is(incidentErr, store.ErrNotFound) && input.Kind == "message" {
		conversationFollowup, err = s.isRecentWatchConversation(ctx, input)
		if err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
	}
	behaviorRequest := errors.Is(incidentErr, store.ErrNotFound) &&
		input.Kind == "mention" &&
		s.cfg.IsOperator(input.UserID) &&
		explicitBehaviorRequest(input.Text)
	if errors.Is(incidentErr, store.ErrNotFound) {
		if directRequest || conversationFollowup {
			watched = true
		} else {
			if input.Kind == "bot_message" {
				watched, err = s.inputReferencesActivePublication(ctx, input)
				if err != nil {
					return true, s.retrySlackInput(ctx, input, err)
				}
			}
			if !watched {
				watched, err = s.proactiveEnabled(ctx, input.ChannelID)
			}
			if err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			if !watched {
				rules, ruleErr := s.matchingStandingRules(ctx, input)
				if ruleErr != nil {
					return true, s.retrySlackInput(ctx, input, ruleErr)
				}
				watched = len(rules) > 0
			}
		}
	}
	if errors.Is(incidentErr, store.ErrNotFound) &&
		(watched || summoned || behaviorRequest) {
		if input.Kind != "bot_message" {
			allowed, allowedErr := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
			if allowedErr != nil {
				return true, s.retrySlackInput(ctx, input, allowedErr)
			}
			if !allowed {
				s.audit(ctx, core.AuditEvent{
					Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
					Outcome: "ignored", Detail: "sender is not an active full workspace member",
				})
				return true, s.finishSlackInput(ctx, input)
			}
		}
		location := decisionpkg.RequestedConversationLocation(s.stripBotMention(input.Text))
		if decisionpkg.LocationOnlyRequest(s.stripBotMention(input.Text)) {
			responseThreadTS, _, routeErr := s.resolveConversationRoute(ctx, input)
			if routeErr != nil {
				return true, s.retrySlackInput(ctx, input, routeErr)
			}
			if err := s.postInputMessageAt(
				ctx,
				"conversation_location_"+input.ID,
				input.ChannelID,
				responseThreadTS,
				slackui.Notice(conversationLocationAcknowledgement(location)),
			); err != nil {
				return true, s.retrySlackInput(ctx, input, err)
			}
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.conversation.location", ActorID: input.UserID,
				ObjectID: input.ID, Outcome: conversationLocationName(location),
				Detail: input.ChannelID,
			})
			return true, s.finishSlackInput(ctx, input)
		}
		if summoned &&
			s.cfg.IsOperator(input.UserID) &&
			explicitIncidentRequest(s.stripBotMention(input.Text)) {
			return true, s.createManualIncident(ctx, input)
		}
		if behaviorRequest && incidentSelfInviteBehaviorRequest(input.Text) {
			// One operator asked to be invited to incident rooms and already is.
			// Nothing was saved and nothing was created, so this is an answer to
			// them rather than an announcement: a channel post here told a room
			// full of people about one person's settings, and told them that
			// nothing had changed.
			s.audit(ctx, core.AuditEvent{
				Kind: "slack.behavior", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "already_configured", Detail: "configured operators are invited to incident rooms",
			})
			return true, s.finishSlashInput(
				ctx,
				input,
				"*You’re already included in every incident room.*\n\n"+
					"Your Slack account is a configured operator. Emisar invites every configured "+
					"operator, plus the users in `slack.invite_users`, whenever it creates an "+
					"incident channel.\n\nNo preference was needed or saved. Incident membership "+
					"is an access setting, not agent memory. No incident was created.",
			)
		}
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return true, s.retrySlackInput(ctx, input, err)
		}
		return true, nil
	}
	return false, nil
}

func (s *Service) processSlackInput(ctx context.Context) error {
	if _, err := s.store.RecoverStaleSlackInputs(
		ctx,
		s.now().UTC().Add(-s.cfg.Limits.WorkerStallAfter.Duration),
	); err != nil {
		return err
	}
	input, err := s.store.LeaseSlackInput(ctx)
	if err != nil {
		return err
	}
	if input.TeamID != s.cfg.Slack.TeamID {
		return s.store.RetrySlackInput(ctx, input.ID, "wrong Slack workspace", s.now(), true)
	}
	if handled, err := s.routeSlackInputKind(ctx, input); handled {
		return err
	}
	if handled, err := s.handleConversationPrefix(ctx, input); handled {
		return err
	}

	var incident core.Incident
	var incidentErr error
	if input.Kind == "action" {
		incidentID := input.ActionValue
		if input.ActionID == slackui.ActionPublishPR {
			incidentID, _, _ = slackui.DecodePublicationActionValue(input.ActionValue)
		}
		incident, incidentErr = s.store.GetIncident(ctx, incidentID)
	} else {
		incident, incidentErr = s.store.FindIncidentForConversation(
			ctx,
			input.ChannelID,
			slackReplyThread(input),
		)
	}
	if incidentErr != nil && !errors.Is(incidentErr, store.ErrNotFound) {
		return s.retrySlackInput(ctx, input, incidentErr)
	}
	if input.Kind == "action" && errors.Is(incidentErr, store.ErrNotFound) {
		return s.finishSlashInput(
			ctx,
			input,
			"*This incident control is no longer valid.* The incident record or button target "+
				"cannot be found. Refresh the channel and use the controls on the current pinned "+
				"incident card. No action was taken.",
		)
	}
	if handled, err := s.handleUnboundConversation(ctx, input, incidentErr); handled {
		return err
	}
	if errors.Is(incidentErr, store.ErrNotFound) && input.Kind != "mention" {
		return s.finishSlackInput(ctx, input)
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

	if errors.Is(incidentErr, store.ErrNotFound) {
		return s.finishSlackInput(ctx, input)
	}
	if incidentErr != nil {
		return s.retrySlackInput(ctx, input, incidentErr)
	}
	if input.Kind != "action" &&
		decisionpkg.LocationOnlyRequest(s.stripBotMention(input.Text)) {
		location := decisionpkg.RequestedConversationLocation(s.stripBotMention(input.Text))
		if incident.IsThreadScoped() && location == decisionpkg.ConversationLocationChannel {
			// One person asked to move a thread-bound task into the channel and
			// cannot: the task's authorization is bound to the thread. Nobody
			// else in the room asked, and nobody else can grant it.
			err = s.refuseControl(ctx, input, incident,
				"**This engineering task remains in its source thread.** Its authorization, "+
					"working copy, and review controls are bound to that thread so unrelated "+
					"channel messages cannot enter the task. Continue here, or start a separate "+
					"channel conversation with Emisar.")
			if errors.Is(err, errControlRefused) {
				err = nil
			}
		} else {
			var responseThreadTS string
			responseThreadTS, _, err = s.resolveConversationRoute(ctx, input)
			if err == nil {
				err = s.postInputMessageAt(
					ctx,
					"conversation_location_"+input.ID,
					input.ChannelID,
					responseThreadTS,
					slackui.Notice(conversationLocationAcknowledgement(location)),
				)
			}
		}
		if err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		s.audit(ctx, core.AuditEvent{
			IncidentID: incident.ID, Kind: "slack.conversation.location",
			ActorID: input.UserID, ObjectID: input.ID,
			Outcome: conversationLocationName(location), Detail: input.ChannelID,
		})
		return s.finishSlackInput(ctx, input)
	}
	if input.Kind == "action" {
		current, currentErr := s.incidentControlMatchesMessage(
			ctx,
			input,
			incident,
		)
		if currentErr != nil {
			return s.retrySlackInput(ctx, input, currentErr)
		}
		if !current {
			noun := "incident"
			if incident.IsEngineeringTask() {
				noun = "task"
			}
			return s.finishSlashInput(
				ctx,
				input,
				"*That button is no longer current.* Use a control on the latest "+noun+
					" card or result message. Nothing was changed.",
			)
		}
		if incident.Status == core.IncidentClosed &&
			input.ActionID != slackui.ActionChanges &&
			input.ActionID != slackui.ActionChangesPrevious &&
			input.ActionID != slackui.ActionChangesNext &&
			input.ActionID != slackui.ActionChangesRefresh &&
			input.ActionID != slackui.ActionReview &&
			input.ActionID != slackui.ActionRepairReview &&
			input.ActionID != slackui.ActionViewPR &&
			input.ActionID != slackui.ActionCheckDelivery &&
			input.ActionID != slackui.ActionDiscardWork {
			return s.finishSlashInput(
				ctx,
				input,
				"*This incident is already closed.* Closed incidents allow only read-only "+
					"inspection of an existing code change. No action was taken.",
			)
		}
		err = s.handleControl(ctx, input, incident, input.ActionID)
	} else {
		text := strings.TrimSpace(input.Text)
		hasMention := strings.Contains(text, fmt.Sprintf("<@%s>", s.identity.BotUserID))
		direct := input.Kind == "mention" || hasMention ||
			input.ThreadTS == incident.ConversationThreadTS()
		if input.Kind == "mention" || hasMention {
			text = s.stripBotMention(text)
		}
		if command, ok := exactCommand(text); ok {
			err = s.handleControl(ctx, input, incident, command)
		} else {
			if text == "" {
				text = "Please inspect the attached file."
			}
			prompt := conversationPrompt(input.UserID, text, direct)
			_, _, err = s.queueIncidentAgentRun(
				ctx, incident, "slack", input.ID, input.UserID, prompt,
			)
			if err == nil && direct {
				s.setNativeStatusForThread(
					ctx,
					incident,
					slackReplyThread(input),
					requestNativeStatus(text),
				)
			}
			if err == nil {
				s.recordTimeline(ctx, core.TimelineEvent{
					ID:         "tl_input_" + input.ID,
					IncidentID: incident.ID, ChannelID: incident.ChannelID,
					Kind: "operator.message", ActorID: input.UserID,
					Title:  "Operator requested investigation",
					Detail: decisionpkg.BoundedField(text, 2000), CreatedAt: input.ReceivedAt,
				})
			}
		}
	}
	if err != nil && !errors.Is(err, errControlRefused) {
		return s.retrySlackInput(ctx, input, err)
	}
	return s.finishSlackInput(ctx, input)
}

func (s *Service) retryRetainedGeneratedVisual(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if !generatedVisualRetryRequest(s.stripBotMention(input.Text)) {
		return false, nil
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return false, err
	}
	if !allowed {
		return false, nil
	}
	delivery, err := s.store.RetryLatestGeneratedVisual(
		ctx,
		input.ChannelID,
		conversationalResponseThread(input),
	)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	s.audit(ctx, core.AuditEvent{
		Kind:     "slack.visual.retry",
		ActorID:  input.UserID,
		ObjectID: delivery.ID,
		Outcome:  "queued",
		Detail:   input.ChannelID + ":" + delivery.ThreadTS,
	})
	return true, s.finishSlackInput(ctx, input)
}

func generatedVisualRetryRequest(text string) bool {
	text = strings.ToLower(strings.TrimSpace(text))
	if text == "" {
		return false
	}
	words := strings.FieldsFunc(text, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	present := make(map[string]bool, len(words))
	for _, word := range words {
		present[word] = true
	}
	hasVisual := false
	for _, noun := range []string{
		"image", "picture", "chart", "graph", "plot", "figure", "visual", "attachment",
	} {
		if present[noun] {
			hasVisual = true
			break
		}
	}
	if !hasVisual {
		return false
	}
	for _, verb := range []string{
		"show", "send", "post", "upload", "attach", "retry", "resend",
	} {
		if present[verb] {
			return true
		}
	}
	return present["try"] && present["again"]
}

func (s *Service) handleOpenEmisarApproval(
	ctx context.Context,
	input core.SlackInput,
) error {
	approval, err := s.store.GetEmisarApproval(ctx, input.ActionValue)
	if errors.Is(err, store.ErrNotFound) {
		return s.finishSlackInput(ctx, input)
	}
	if err != nil {
		return err
	}
	if approval.ChannelID != input.ChannelID {
		return s.finishSlackInput(ctx, input)
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: approval.IncidentID,
		Kind:       "emisar.approval.opened",
		ActorID:    input.UserID,
		ObjectID:   approval.RequestID,
		Outcome:    "linked",
		Detail:     approval.ActionID + " runner=" + approval.RunnerRef,
	})
	return s.finishSlackInput(ctx, input)
}

func (s *Service) processChannelLifecycleInput(
	ctx context.Context,
	input core.SlackInput,
) error {
	state := core.ChannelState(input.ActionID)
	incidents, err := s.store.SetIncidentChannelState(
		ctx, input.ChannelID, state, input.ReceivedAt,
	)
	if err != nil {
		return err
	}
	if state == core.ChannelDeleted {
		if _, err := s.store.DeleteSlackChannelSettings(ctx, input.ChannelID); err != nil {
			return err
		}
		if _, err := s.store.DeleteChannelConfigurationState(ctx, input.ChannelID); err != nil {
			return err
		}
		if _, err := s.store.Memory.DeleteConversationMemories(ctx, input.ChannelID); err != nil {
			return err
		}
		if _, err := s.store.DeleteConversationRoutes(ctx, input.ChannelID); err != nil {
			return err
		}
		deleted, err := s.store.Memory.DeleteChannelMemoryEntries(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		if deleted > 0 {
			s.audit(ctx, core.AuditEvent{
				Kind: "memory.channel_deleted", ActorID: input.UserID,
				ObjectID: input.ChannelID, Outcome: "deleted",
				Detail: fmt.Sprintf("entries=%d", deleted),
			})
		}
		preferences, rules, err := s.store.Behavior.DeleteChannelBehavior(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		if preferences+rules > 0 {
			s.audit(ctx, core.AuditEvent{
				Kind: "behavior.channel_deleted", ActorID: input.UserID,
				ObjectID: input.ChannelID, Outcome: "deleted",
				Detail: fmt.Sprintf("preferences=%d rules=%d", preferences, rules),
			})
		}
		schedules, err := s.store.Schedules.DeleteChannelSchedules(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		if schedules > 0 {
			s.audit(ctx, core.AuditEvent{
				Kind: "schedule.channel_deleted", ActorID: input.UserID,
				ObjectID: input.ChannelID, Outcome: "deleted",
				Detail: fmt.Sprintf("schedules=%d", schedules),
			})
		}
	}
	for _, incident := range incidents {
		s.forgetNativeStatus(incident.ID)
		s.audit(ctx, core.AuditEvent{
			IncidentID: incident.ID,
			Kind:       "slack.channel.lifecycle",
			ActorID:    input.UserID,
			ObjectID:   input.ChannelID,
			Outcome:    "observed",
			Detail:     input.ActionValue + ": " + string(state),
		})
	}
	return nil
}

func slackReplyThread(input core.SlackInput) string {
	if input.ThreadTS != "" {
		return input.ThreadTS
	}
	return input.MessageTS
}

func (s *Service) createManualIncident(ctx context.Context, input core.SlackInput) error {
	title := s.stripBotMention(input.Text)
	if title == "" {
		title = "Manual incident"
	}
	title = core.TruncateUTF8(title, 200)
	thread := input.ThreadTS
	if thread == "" {
		thread = input.MessageTS
	}
	repository, err := s.effectiveRepository(
		ctx, input.ChannelID, input.UserID, s.cfg.Slack.DefaultRepository,
	)
	if err != nil {
		return err
	}
	incident, _, err := s.store.CreateManualIncident(
		ctx, repository, input.EventID, title, title, input.UserID,
		input.ChannelID, thread,
		s.cfg.Limits.MaxOpenIncidents,
	)
	if err != nil {
		if errors.Is(err, store.ErrCapacity) {
			if noticeErr := s.postInputMessageInSourceThread(
				ctx,
				"manual_capacity_"+input.ID,
				input,
				slackui.Notice(
					"*Responder did not create an incident.* The configured open incident limit has "+
						"been reached, so no channel, agent session, or working copy was created. "+
						"Close an existing incident, or ask an administrator to raise "+
						"`limits.max_open_incidents`, then send the request again.",
				),
			); noticeErr != nil {
				return s.retrySlackInput(ctx, input, noticeErr)
			}
			s.audit(ctx, core.AuditEvent{
				Kind: "incident.manual", ActorID: input.UserID,
				ObjectID: input.EventID, Outcome: "rejected", Detail: trimError(err),
			})
			return s.finishSlackInput(ctx, input)
		}
		return s.retrySlackInput(ctx, input, err)
	}
	if err := s.enqueue(
		ctx, "out_manual_ack_"+input.ID, core.Incident{
			ID: incident.ID, ChannelID: input.ChannelID,
		}, "notice", thread,
		slackui.Notice(
			"*Incident accepted.* I’m creating a dedicated Slack channel and an isolated "+
				"working copy now. I’ll post the channel link in this thread when it is ready. "+
				"No merge, push, deployment, or infrastructure change has occurred.",
		),
	); err != nil {
		return s.retrySlackInput(ctx, input, err)
	}
	s.audit(ctx, core.AuditEvent{
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
	return s.postInputMessage(ctx, id, input, slackui.Notice(text))
}

func (s *Service) postInputMessage(
	ctx context.Context,
	id string,
	input core.SlackInput,
	message slackui.Message,
) error {
	return s.postInputMessageAt(
		ctx, id, input.ChannelID, conversationalResponseThread(input), message,
	)
}

func (s *Service) postInputMessageInSourceThread(
	ctx context.Context,
	id string,
	input core.SlackInput,
	message slackui.Message,
) error {
	return s.postInputMessageAt(
		ctx, id, input.ChannelID, slackReplyThread(input), message,
	)
}

func (s *Service) postInputMessageAt(
	ctx context.Context,
	id string,
	channelID string,
	threadTS string,
	message slackui.Message,
) error {
	return s.postInputMessageDelivery(
		ctx,
		id,
		"notice",
		channelID,
		threadTS,
		message,
	)
}

func (s *Service) postInputMessageAtEpisode(
	ctx context.Context,
	id string,
	episodeID string,
	channelID string,
	threadTS string,
	message slackui.Message,
) error {
	if _, err := s.bindEpisodeDestination(
		ctx,
		episodeID,
		channelID,
		threadTS,
		"communication_policy",
	); err != nil {
		return err
	}
	message = s.sanitizeMessage(message)
	body, err := slackui.Encode(message)
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: id, EpisodeID: episodeID, Operation: "post", Kind: "notice",
		ChannelID: channelID, ThreadTS: threadTS, Body: body,
	})
	return err
}

func (s *Service) bindEpisodeDestination(
	ctx context.Context,
	episodeID string,
	channelID string,
	threadTS string,
	reason string,
) (core.WorkEpisode, error) {
	episode, err := s.store.GetWorkEpisode(ctx, episodeID)
	if err != nil {
		return core.WorkEpisode{}, err
	}
	if episode.Destination.ChannelID == channelID &&
		episode.Destination.ThreadTS == threadTS {
		return episode, nil
	}
	return s.store.ChangeEpisodeDestination(
		ctx,
		episodeID,
		core.BoundDestination{ChannelID: channelID, ThreadTS: threadTS},
		reason,
	)
}

func (s *Service) postInputMessageDelivery(
	ctx context.Context,
	id string,
	kind string,
	channelID string,
	threadTS string,
	message slackui.Message,
	messageTS ...string,
) error {
	message = s.sanitizeMessage(message)
	body, err := slackui.Encode(message)
	if err != nil {
		return err
	}
	operation, targetTS := "post", ""
	if len(messageTS) > 0 {
		operation, targetTS = "update", messageTS[0]
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: id, Operation: operation, Kind: kind,
		ChannelID: channelID, ThreadTS: threadTS, MessageTS: targetTS, Body: body,
	})
	return err
}

func conversationLocationName(location decisionpkg.ConversationLocation) string {
	switch location {
	case decisionpkg.ConversationLocationChannel:
		return "channel"
	case decisionpkg.ConversationLocationThread:
		return "thread"
	default:
		return "follow"
	}
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
	case "!respond publish":
		return slackui.ActionPublishPR, true
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
	threadTS := incident.ConversationThreadTS()
	switch control {
	case "status":
		return s.enqueue(ctx, "out_status_"+input.ID, incident, "notice", threadTS,
			slackui.IncidentStatusMessage(incident))
	case slackui.ActionHelp:
		return s.enqueue(ctx, "out_help_"+input.ID, incident, "notice",
			threadTS, slackui.HelpMessage(incident))
	case slackui.ActionUpdate:
		request := "Give a concise incident update: verified facts, current hypothesis, code changes, blockers, and next action."
		if incident.IsEngineeringTask() {
			request = "Give a concise engineering task update: completed work, verification, code changes, blockers, and next action."
		}
		_, _, err := s.queueIncidentAgentRun(
			ctx,
			incident,
			"control",
			input.ID,
			input.UserID,
			operatorPrompt(input.UserID, request),
		)
		if err == nil {
			s.setNativeStatus(ctx, incident, "is preparing an incident update...")
		}
		return err
	case slackui.ActionChanges,
		slackui.ActionChangesPrevious,
		slackui.ActionChangesNext,
		slackui.ActionChangesRefresh:
		return s.showChanges(ctx, input, incident)
	case slackui.ActionReview:
		return s.reviewFix(ctx, input, incident)
	case slackui.ActionRepairReview:
		return s.repairReview(ctx, input, incident)
	case slackui.ActionPublishPR:
		return s.publishDraftPR(ctx, input, incident)
	case slackui.ActionViewPR:
		return nil
	case slackui.ActionCheckDelivery:
		return s.checkPublicationFollowup(ctx, input, incident)
	case slackui.ActionDiscardWork:
		return s.discardRetainedWork(ctx, input, incident)
	case slackui.ActionStop:
		return s.stopTurn(ctx, input, incident)
	case slackui.ActionExtend:
		return s.explainAutomaticCapacity(ctx, input, incident)
	case slackui.ActionResolve:
		return s.closeIncident(ctx, input, incident)
	default:
		return errors.New("unknown Responder control")
	}
}

func (s *Service) repairReview(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	if !incident.IsEngineeringTask() {
		return errors.New("review repair is only available for engineering tasks")
	}
	if incident.ActiveTurnID != "" {
		return s.refuseControl(ctx, input, incident,
			"I’m already working in this task. I’ll keep the readiness failure in context; "+
				"wait for this run to finish, then retry the draft PR.")
	}
	request := "The latest draft-PR readiness review failed. Inspect the current task diff and " +
		"repository gate, identify the exact failing check and every tracked file validation changed, " +
		"fix task-owned or repository-owned causes, and rerun the appropriate validation. If the " +
		"failure is only a missing tool or broken execution environment, report the exact command, " +
		"error, and required environment fix instead of changing product code to hide it. Do not push, " +
		"merge, deploy, or mutate infrastructure."
	_, _, err := s.queueIncidentAgentRun(
		ctx, incident, "control", input.ID, input.UserID,
		operatorPrompt(input.UserID, request),
	)
	if err == nil {
		s.setNativeStatus(ctx, incident, "is diagnosing the failed readiness checks...")
	}
	return err
}

func (s *Service) showChanges(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	threadTS := incident.ConversationThreadTS()
	if incident.CoopSessionID == "" {
		return s.refuseControl(ctx, input, incident,
			"*Code changes are not available yet.* Emisar is still preparing the "+
				"isolated working copy. Wait for the task to show *Waiting for input* "+
				"or *Investigating*, then try again.")
	}

	requestedOffset := int64(0)
	expectedDigest := ""
	if input.ActionID != slackui.ActionChanges {
		cursor, ok := decodeChangesCursor(input.ActionValue)
		if !ok || cursor.IncidentID != incident.ID {
			return errors.New("invalid diff page cursor")
		}
		requestedOffset = cursor.Offset
		expectedDigest = cursor.Digest
	}

	s.setNativeStatus(ctx, incident, "is checking the isolated fork...")
	changes, err := s.changesPage(
		ctx,
		incident.CoopSessionID,
		requestedOffset,
		changesPatchPageBytes,
	)
	if err != nil && requestedOffset > 0 {
		changes, err = s.changesPage(
			ctx,
			incident.CoopSessionID,
			0,
			changesPatchPageBytes,
		)
		requestedOffset = 0
	}
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	diffChanged := expectedDigest != "" && changes.PatchDigest != expectedDigest
	if diffChanged && changes.PatchOffset != 0 {
		changes, err = s.changesPage(
			ctx,
			incident.CoopSessionID,
			0,
			changesPatchPageBytes,
		)
		if err != nil {
			s.clearNativeStatus(ctx, incident)
			return err
		}
	}

	summary := changesSummary(changes)
	if diffChanged {
		summary = "_The fork changed while you were browsing. Showing the newest diff._\n\n" +
			summary
	}
	message := slackui.ChangesMessage(
		incident,
		summary,
		changes.Patch,
		changesNavigation(incident.ID, changes),
	)
	if input.Kind == "action" && input.ActionID != slackui.ActionChanges &&
		input.MessageTS != "" {
		err = s.enqueueMessageUpdate(
			ctx,
			"out_changes_page_"+input.ID,
			incident,
			"changes",
			input.MessageTS,
			message,
		)
	} else {
		err = s.enqueue(
			ctx,
			"out_changes_"+input.ID,
			incident,
			"changes",
			threadTS,
			message,
		)
	}
	if err != nil {
		s.clearNativeStatus(ctx, incident)
	}
	return err
}

func (s *Service) changesPage(
	ctx context.Context,
	sessionID string,
	offset int64,
	limit int,
) (coop.Changes, error) {
	if pager, ok := s.coop.(coopChangesPager); ok {
		return pager.ChangesPage(ctx, sessionID, offset, limit)
	}
	changes, err := s.coop.Changes(ctx, sessionID)
	if err != nil {
		return coop.Changes{}, err
	}
	full := changes.Patch
	if changes.PatchBytes == 0 {
		changes.PatchBytes = int64(len(full))
	}
	if changes.PatchDigest == "" && !changes.Truncated {
		sum := sha256.Sum256(full)
		changes.PatchDigest = hex.EncodeToString(sum[:])
	}
	if offset > int64(len(full)) {
		return coop.Changes{}, errors.New("diff page starts beyond the available patch")
	}
	end := min(offset+int64(limit), int64(len(full)))
	changes.Patch = append([]byte(nil), full[offset:end]...)
	changes.PatchOffset = offset
	changes.PatchNextOffset = end
	changes.PatchHasMore = end < changes.PatchBytes
	changes.Truncated = offset > 0 || changes.PatchHasMore
	return changes, nil
}

func changesNavigation(
	incidentID string,
	changes coop.Changes,
) slackui.ChangesNavigation {
	total := changes.PatchBytes
	pages := 1
	page := 1
	if total > 0 {
		pages = int((total + changesPatchPageBytes - 1) / changesPatchPageBytes)
		page = int(changes.PatchOffset/changesPatchPageBytes) + 1
	}
	navigation := slackui.ChangesNavigation{
		Page: page, Pages: pages,
		FirstByte: changes.PatchOffset, LastByte: changes.PatchNextOffset,
		TotalBytes: total, Digest: changes.PatchDigest,
		RefreshValue: encodeChangesCursor(changesCursor{
			IncidentID: incidentID,
			Offset:     0,
			Digest:     changes.PatchDigest,
		}),
	}
	if changes.PatchOffset > 0 {
		previous := max(int64(0), changes.PatchOffset-changesPatchPageBytes)
		navigation.PreviousValue = encodeChangesCursor(changesCursor{
			IncidentID: incidentID,
			Offset:     previous,
			Digest:     changes.PatchDigest,
		})
	}
	if changes.PatchHasMore {
		navigation.NextValue = encodeChangesCursor(changesCursor{
			IncidentID: incidentID,
			Offset:     changes.PatchNextOffset,
			Digest:     changes.PatchDigest,
		})
	}
	return navigation
}

func (s *Service) explainAutomaticCapacity(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	limit, err := s.effectiveTurnLimit(ctx, incident.ChannelID)
	if err != nil {
		return err
	}
	return s.refuseControl(ctx, input, incident, fmt.Sprintf(
		"*Manual turn allocation is no longer required.* Responder automatically adds "+
			"session capacity when authorized work arrives, up to this channel's safety "+
			"ceiling of %d accepted requests. Tool calls and investigation steps inside a "+
			"request are not counted separately. Use `/responder turn-limit` to inspect or "+
			"change the ceiling.",
		limit,
	))
}

func (s *Service) reviewFix(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.CoopSessionID == "" {
		return s.refuseControl(ctx, input, incident,
			"*Fix review is not available yet.* Responder is still preparing the isolated "+
				"working copy. Wait for the pinned card to show *Waiting for input*, then "+
				"run the review again.")
	}
	if incident.ActiveTurnID != "" {
		return s.refuseControl(ctx, input, incident,
			"*Fix review did not start because an agent turn is still running.* Wait for "+
				"that run to finish, or use *Stop current run*, then request review again. "+
				"The review is read-only and never merges or deploys.")
	}
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		return err
	}
	if !coopChangesPresent(changes) {
		return s.refuseControl(ctx, input, incident,
			"*There is no proposed code change to review.* Fix readiness checks compare "+
				"the isolated change with the current repository, test whether it can be "+
				"rebased, and run configured validation and policy gates. This incident's "+
				"working copy has no changed files, so no review was started.")
	}
	s.setNativeStatus(ctx, incident, "is reviewing the proposed fix...")
	action, err := s.freezeAction(ctx, input, incident, false)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	rawReview, _, err := s.coop.Review(
		ctx, "responder:review:"+input.ID, action.SessionID, action.Revision,
	)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	review := publicationreview.NormalizeReview(rawReview)
	err = s.updateEngineeringTaskCard(
		ctx,
		incident,
		slackui.ReviewMessage(incident, publicationreview.ReviewSummary(rawReview), review.Publishable),
		nil,
	)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
	}
	return err
}

func (s *Service) stopTurn(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.ActiveTurnID == "" {
		return s.refuseControl(ctx, input, incident,
			"*Nothing was stopped.* No agent turn is currently running. Responder is "+
				"waiting for input; reply with the next request, ask for an update, or close "+
				"the incident.")
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
	s.audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "coop.turn.cancel", ActorID: input.UserID,
		ObjectID: action.TurnID, Outcome: "requested",
	})
	return s.enqueue(ctx, "out_stop_"+input.ID, incident, "notice",
		incident.ConversationThreadTS(), slackui.Notice(
			"*Stop requested for the active agent turn.* Responder will stop starting new work "+
				"for that turn. The isolated working copy, collected evidence, and queued "+
				"incident context are preserved so an operator can inspect or continue later.",
		))
}

func (s *Service) closeIncident(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	noun := "incident"
	if incident.IsEngineeringTask() {
		noun = "engineering task"
	}
	if incident.ActiveTurnID != "" {
		return s.refuseControl(ctx, input, incident,
			"*The "+noun+" was not closed because an agent turn is still running.* Use "+
				"*Stop current run* and wait for it to stop, then close it again. "+
				"No work or evidence was discarded.")
	}
	previousWorkflow, err := s.store.Publications.BeginClose(ctx, incident.ID)
	if errors.Is(err, publicationstore.ErrCloseConflict) {
		return s.refuseControl(ctx, input, incident,
			"*The "+noun+" was not closed because draft PR work is still active.* "+
				"Wait for the task card to show success, retry, or terminal failure, then close it.")
	}
	if err != nil {
		return err
	}
	closing := true
	defer func() {
		if closing {
			if restoreErr := s.store.Publications.RestoreClose(
				context.WithoutCancel(ctx), incident.ID, previousWorkflow,
			); restoreErr != nil {
				s.log.Error("restore failed incident close", "incident", incident.ID, "error", restoreErr)
			}
		}
	}()
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
		publication, publicationErr := s.store.GetPublication(ctx, incident.ID)
		if publicationErr != nil && !errors.Is(publicationErr, store.ErrNotFound) {
			return publicationErr
		}
		if err := s.store.ScheduleCleanup(
			ctx,
			incident.CoopSessionID,
			incident.ID,
			"closed "+noun,
			publication.Published(),
			s.now().UTC().Add(s.cfg.Retention.ClosedSessionGrace.Duration),
		); err != nil {
			return err
		}
	}
	if err := s.store.CloseIncident(ctx, incident.ID); err != nil {
		return err
	}
	closing = false
	auditKind := "incident.close"
	timelineKind := "incident.closed"
	timelineTitle := "Incident closed"
	if incident.IsEngineeringTask() {
		auditKind = "engineering_task.close"
		timelineKind = "engineering_task.closed"
		timelineTitle = "Engineering task closed"
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: auditKind, ActorID: input.UserID,
		ObjectID: incident.CoopSessionID, Outcome: "succeeded",
	})
	s.recordTimeline(ctx, core.TimelineEvent{
		ID:         "tl_close_" + incident.ID,
		IncidentID: incident.ID, ChannelID: incident.ChannelID,
		Kind: timelineKind, ActorID: input.UserID,
		Title: timelineTitle,
		Detail: "The Coop session was closed. Responder will reclaim zero-change or " +
			"published workspace state after the configured grace period; unpublished " +
			"changes are retained for operator action.",
	})
	closeMessage := "*Incident closed.* Responder will not start more investigation turns for this " +
		"incident. Zero-change workspace state is reclaimed after the retention grace period; " +
		"unpublished changes are retained for operator action. Closing did not merge, push, " +
		"sign, or deploy anything."
	if incident.IsEngineeringTask() {
		closeMessage = "*Engineering task closed.* Responder will not start more turns for this " +
			"task. Published or zero-change workspace state is reclaimed after the retention " +
			"grace period; unpublished changes are retained. Closing did not merge, push, sign, " +
			"deploy, or change infrastructure."
	}
	if err := s.enqueue(
		ctx, "out_close_"+input.ID, incident, "notice", incident.ConversationThreadTS(),
		slackui.Notice(closeMessage),
	); err != nil {
		return err
	}
	if incident.IsEngineeringTask() {
		return nil
	}
	record, err := s.store.LoadRemediationRecord(ctx, incident.ID)
	if err != nil {
		return err
	}
	return s.enqueue(
		ctx,
		"out_postmortem_"+incident.ID,
		incident,
		"postmortem",
		incident.ConversationThreadTS(),
		slackui.PostmortemDraft(record),
	)
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
	// A control-plane action has no row to freeze against, and needs none.
	//
	// Freezing pins the session and revision onto the stored Slack input so
	// that a redelivered event acts on the same turn it first resolved. The
	// dashboard's input is synthetic: it is never admitted to slack_inputs and
	// never redelivered, so the SELECT behind FreezeSlackInput matched nothing
	// and the whole action failed with a bare "sql: no rows in result set".
	// Close was broken that way for every incident holding a Coop session —
	// the button existed, was offered, and could not work.
	if input.Kind == controlPlaneInput {
		return action, nil
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

func (s *Service) incidentControlMatchesMessage(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) (bool, error) {
	actionIncidentID, actionValueOK := changesActionIncidentID(
		input.ActionID,
		input.ActionValue,
	)
	if !actionValueOK || actionIncidentID != incident.ID ||
		input.ChannelID != incident.ChannelID ||
		input.MessageTS == "" {
		return false, nil
	}
	if input.ActionID == slackui.ActionPublishPR {
		matches, err := s.publicationControlGenerationMatches(
			ctx, input.ID, input.ActionValue, incident.ID,
		)
		if err != nil || !matches {
			return matches, err
		}
	}
	if input.MessageTS == incident.RootTS {
		return true, nil
	}
	delivery, err := s.store.GetLatestSentSlackMessageDelivery(
		ctx,
		incident.ID,
		input.ChannelID,
		input.MessageTS,
	)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	message, err := slackui.Decode(delivery.Body)
	if err != nil {
		return false, fmt.Errorf(
			"decode Slack control delivery %q: %w",
			delivery.ID,
			err,
		)
	}
	for _, action := range message.Actions {
		if action.ID == input.ActionID && action.Value == input.ActionValue {
			return true, nil
		}
	}
	return false, nil
}

func (s *Service) publicationControlGenerationMatches(
	ctx context.Context,
	inputID string,
	value string,
	incidentID string,
) (bool, error) {
	actionIncidentID, generation, versioned := slackui.DecodePublicationActionValue(value)
	if actionIncidentID != incidentID {
		return false, nil
	}
	publication, err := s.store.GetPublication(ctx, incidentID)
	if errors.Is(err, store.ErrNotFound) {
		return !versioned || generation == 0, nil
	}
	if err != nil {
		return false, err
	}
	if !versioned {
		return publication.AttemptInputID == inputID && publication.InProgress(), nil
	}
	return publication.Generation == generation, nil
}

// retrySlackInput records a failed attempt at a Slack input and decides whether
// to try again.
//
// It also says so. This used to be entirely silent: the only operator-visible
// output was a thread notice, and that notice is only posted when the input
// belongs to a conversation that already has an incident. A failing App Home
// refresh, a failing surface repaint, or any failure in a DM therefore produced
// no log line, no audit row, and no message anywhere — just a row in
// slack_inputs that nobody reads. Two deployments burned twelve Slack API
// attempts per App Home open for months on a call that has never once
// succeeded, and nothing told anyone. A retry that gives up is a fact about the
// product, so it is now logged every attempt and audited when it stops.
func (s *Service) retrySlackInput(ctx context.Context, input core.SlackInput, err error) error {
	attempt := input.Failures + 1
	terminal := s.slackInputFailureIsTerminal(input, err, attempt)
	persistCtx, cancel := publicationPersistenceContext(ctx)
	defer cancel()
	if stored, loadErr := s.store.GetSlackInput(persistCtx, input.ID); loadErr == nil {
		input.ActionID = stored.ActionID
		input.ActionValue = stored.ActionValue
	}
	detail := trimError(err)
	if slackui.BaseActionID(input.ActionID) == slackui.ActionPublishPR {
		detail = safePublicationError(s, err)
		state := core.PublicationRetrying
		if terminal {
			state = core.PublicationFailed
		}
		if transitionErr := s.recordPublicationAttemptFailure(
			persistCtx, input.ActionValue, input.ID, state, err,
		); transitionErr != nil {
			s.log.Error(
				"record draft PR attempt failure",
				"input", input.ID,
				"incident", input.ActionValue,
				"state", state,
				"error", trimError(transitionErr),
			)
		}
	}
	record := s.log.Warn
	if terminal {
		record = s.log.Error
	}
	record(
		"Slack input attempt failed",
		"input", input.ID,
		"kind", input.Kind,
		"channel", input.ChannelID,
		"action", input.ActionID,
		"user", input.UserID,
		"attempt", attempt,
		"gave_up", terminal,
		"error", detail,
	)
	if updateErr := s.store.RetrySlackInputFailure(
		persistCtx,
		input.ID,
		detail,
		s.queueDelay(attempt),
		terminal,
	); updateErr != nil {
		return updateErr
	}
	if terminal {
		s.audit(persistCtx, core.AuditEvent{
			Kind: "slack.input", ActorID: input.UserID, ObjectID: input.ID,
			Outcome: "abandoned", Detail: input.Kind + ": " + detail,
		})
		s.reportAbandonedInput(persistCtx, input, err)
	}
	return nil
}

func (s *Service) slackInputFailureIsTerminal(
	input core.SlackInput,
	err error,
	attempt int,
) bool {
	terminal := terminalAttempt(attempt, s.cfg.Limits.MaxSlackInputAttempts)
	var apiErr *coop.APIError
	if errors.As(err, &apiErr) && !apiErr.Retryable() {
		terminal = true
	}
	// Slack has already given its final answer for these. Retrying a missing
	// channel eleven more times cannot find it, and the only thing the attempts
	// buy is a longer audit trail of the same rejection.
	if permanentSlackInputError(err) {
		terminal = true
	}
	// A cosmetic surface repaint is worth a couple of attempts, not the full
	// budget reserved for work an operator asked for. Nobody loses an answer
	// when suggested prompts fail to refresh.
	if surfaceRefreshInput(input.Kind) && terminalAttempt(attempt, surfaceRefreshAttempts) {
		terminal = true
	}
	return terminal
}

// reportAbandonedInput tells whoever asked that their request will not happen.
//
// The message is "Responder could not complete that request after retrying",
// the reason Slack gave, and an invitation to try the command again. Only the
// person who typed the command can do that. To everyone else in the room it is
// a stack trace addressed to nobody: it names no work, changes nothing they
// can see, and arrives after twelve silent attempts they never knew about.
//
// So it goes to that person, ephemerally, where they interacted. It is not
// dropped when there is nobody to address — an alert or a bot message has no
// author, and the failure of work in an incident room is on-topic for the room
// — so that case keeps the channel post it always had. Either way the audit
// event above records the abandonment, which is the durable half.
func (s *Service) reportAbandonedInput(
	ctx context.Context,
	input core.SlackInput,
	cause error,
) {
	message := slackui.Notice(
		"*Responder could not complete that request after retrying.*\n\n" +
			"Reason: `" + trimError(cause) + "`\n\nThe incident and isolated working copy " +
			"are preserved. Check the pinned card for the current state, then retry " +
			"the command or reply with a different next step.",
	)
	if input.ChannelID != "" && input.UserID != "" {
		if err := s.slack.PostEphemeral(
			ctx, input.ChannelID, input.UserID, s.sanitizeMessage(message),
		); err != nil {
			s.log.Warn(
				"tell an operator their Slack request was abandoned",
				"input", input.ID,
				"channel", input.ChannelID,
				"user", input.UserID,
				"error", trimError(err),
			)
		}
		return
	}
	incident, incidentErr := s.store.FindIncidentForConversation(
		ctx,
		input.ChannelID,
		slackReplyThread(input),
	)
	if incidentErr != nil {
		return
	}
	_ = s.enqueue(
		ctx,
		"out_input_error_"+input.ID,
		incident,
		"notice",
		incident.ConversationThreadTS(),
		message,
	)
}

// surfaceRefreshAttempts caps retries of a Slack surface repaint.
//
// A repaint carries no operator instruction, so a failure costs presentation,
// never an answer. The general budget is twelve because losing a command an
// operator typed is expensive; spending twelve Slack API calls to fail at
// redrawing a dashboard is not the same trade.
const surfaceRefreshAttempts = 3

func surfaceRefreshInput(kind string) bool {
	return kind == inputAppHome
}

// permanentSlackInputError reports whether Slack's answer will be the same
// next time.
//
// These fall in two families. Addressing errors mean the target does not exist
// or cannot be reached from this token — a retry re-asks a question Slack has
// already answered. Installation errors mean the app itself needs a scope
// change or a reinstall, which no amount of waiting performs.
func permanentSlackInputError(err error) bool {
	detail := strings.ToLower(trimError(err))
	if detail == "" {
		return false
	}
	for _, marker := range []string{
		"channel_not_found", "user_not_found", "users_not_found",
		"message_not_found", "is_archived",
		"invalid_auth", "not_authed", "account_inactive", "token_revoked",
		"missing_scope", "not_allowed_token_type",
	} {
		if strings.Contains(detail, marker) {
			return true
		}
	}
	return false
}

func (s *Service) finishSlackInput(ctx context.Context, input core.SlackInput) error {
	if err := s.store.FinishSlackInput(ctx, input.ID); err != nil {
		_ = s.store.RetrySlackInput(ctx, input.ID, trimError(err), s.queueDelay(input.Attempts), false)
		return err
	}
	return nil
}

// denyInput tells the person who was refused, and only them.
//
// Both reasons name one Slack account and nothing else: this person is not a
// configured operator, or this person is a guest the workspace does not let
// steer Responder. Nobody else in the room can grant either, so nobody else
// can act on reading it — which is the test, not whether it is an error.
//
// It was a channel post, so a colleague who typed one sentence in an incident
// room was refused in public, once per message they sent, in front of everyone
// working the incident. The refusal is between Responder and them.
//
// Ephemeral needs a channel and a user. A channelless interaction has neither
// a place to put it nor, by then, anything to say that the App Home does not
// already show, so the audit row below carries it instead — it is written
// whether or not the message reaches Slack, and it is written in both shapes.
// controlPlaneInput is the Kind the local dashboard's synthetic input carries.
//
// The web control plane runs the identical handlers the Slack buttons call, so
// those handlers have to be able to tell the two entrances apart. They cannot
// do it by looking for an empty ChannelID: an App Home click has no channel
// either, and answering the dashboard the way an App Home click is answered
// would repaint a Slack surface for somebody who is looking at a browser.
//
// Naming the origin is the honest version. The dashboard is the only caller
// that sets it, and it is set where the input is built rather than inferred
// three functions later from what happens to be missing.
const controlPlaneInput = "control_plane"

// errControlRefused says the control answered its own requester and there is
// nothing further to send.
//
// Without it, "/responder stop" on an idle incident told the operator both
// "Nothing was stopped" and "Request submitted for incident abc — this command
// will cancel the active agent turn", because the slash path appends a receipt
// to whatever handleControl did. The second sentence describes work that was
// just declined. Refusing and then reporting the refusal as submitted is the
// exact failure this sweep exists to remove, so the receipt is skipped instead.
var errControlRefused = errors.New("the control was refused and its requester told")

// refuseControl tells whoever asked that their control did nothing, and tells
// nobody else.
//
// Every sentence these carry is about one request: this task is not closed yet,
// there is nothing to publish, no agent turn is running, the workspace has
// uncommitted changes. They were channel posts, so a button press that changed
// nothing put an explanation in front of a room that did not press it — and
// when the press came from the dashboard, six of them arrived in two minutes
// while the operator who caused them was looking at a different screen.
//
// Where the answer goes follows who asked:
//
//   - Slack: ephemeral, in the channel they pressed in. They are waiting on an
//     answer and they are the only person who can act on it.
//   - The dashboard: an error, which the control plane renders on its own
//     refusal page. This is the half that was actually broken — these handlers
//     returned nil after enqueuing a refusal, so the dashboard reported "done"
//     for work it had just been told could not happen.
//   - Neither: the audit row below, which is written on every path anyway.
//
// A refusal Slack rejects is logged and audited rather than retried. The
// ordinary input retry would re-run the whole control, and publishing is one of
// these: re-reviewing and re-pushing a branch because an ephemeral did not
// render is a worse failure than the one it would be papering over.
func (s *Service) refuseControl(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
	text string,
) error {
	s.audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "slack.control", ActorID: input.UserID,
		ObjectID: input.ID, Outcome: "refused", Detail: text,
	})
	if input.Kind == controlPlaneInput {
		return errors.New(strings.ReplaceAll(text, "*", ""))
	}
	if input.ChannelID == "" || input.UserID == "" {
		return errControlRefused
	}
	if err := s.slack.PostEphemeral(
		ctx, input.ChannelID, input.UserID, s.sanitizeMessage(slackui.Notice(text)),
	); err != nil {
		s.log.Warn(
			"tell an operator their control changed nothing",
			"input", input.ID,
			"channel", input.ChannelID,
			"user", input.UserID,
			"error", trimError(err),
		)
	}
	return errControlRefused
}

func (s *Service) denyInput(ctx context.Context, input core.SlackInput, reason string) {
	incident, _ := s.store.FindIncidentForConversation(
		ctx,
		input.ChannelID,
		slackReplyThread(input),
	)
	if input.ChannelID != "" && input.UserID != "" {
		if err := s.slack.PostEphemeral(
			ctx, input.ChannelID, input.UserID, s.sanitizeMessage(slackui.Notice(reason)),
		); err != nil {
			s.log.Warn(
				"tell a refused Slack user why",
				"input", input.ID,
				"channel", input.ChannelID,
				"user", input.UserID,
				"error", trimError(err),
			)
		}
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "slack.input", ActorID: input.UserID,
		ObjectID: input.ID, Outcome: "denied", Detail: reason,
	})
}
