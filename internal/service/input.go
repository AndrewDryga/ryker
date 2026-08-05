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
	"time"
	"unicode"

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
	case slackui.ActionChangesPrevious,
		slackui.ActionChangesNext,
		slackui.ActionChangesRefresh:
		cursor, ok := decodeChangesCursor(value)
		return cursor.IncidentID, ok
	default:
		return value, value != ""
	}
}

func (s *Service) processSlackInput(ctx context.Context) error {
	if _, err := s.store.RecoverStaleSlackInputs(
		ctx,
		time.Now().UTC().Add(-s.cfg.Limits.WorkerStallAfter.Duration),
	); err != nil {
		return err
	}
	input, err := s.store.LeaseSlackInput(ctx)
	if err != nil {
		return err
	}
	if input.TeamID != s.cfg.Slack.TeamID {
		return s.store.RetrySlackInput(ctx, input.ID, "wrong Slack workspace", time.Now(), true)
	}
	if input.Kind == "reaction_added" || input.Kind == "reaction_removed" {
		_ = s.store.Audit(ctx, core.AuditEvent{
			Kind:     "slack.reaction",
			ActorID:  input.UserID,
			ObjectID: input.ActionValue,
			Outcome:  strings.TrimPrefix(input.Kind, "reaction_"),
			Detail:   input.ActionID,
		})
		return s.finishSlackInput(ctx, input)
	}
	if input.Kind == "recheck" {
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return nil
	}
	if reason, ignore := deterministicExternalLifecycleIgnore(input); ignore {
		if err := s.completeIgnoredLifecycleInput(ctx, input, reason); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return nil
	}
	// Private verification replays exercise the normal model and tool path, but
	// cannot impersonate a new human turn or enter a delivery-producing handler.
	if isPrivateSlackVerificationReplay(input) {
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return nil
	}
	if input.Kind == "channel_lifecycle" {
		if err := s.processChannelLifecycleInput(ctx, input); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return s.finishSlackInput(ctx, input)
	}
	if input.Kind == "channel_joined" {
		if err := s.startChannelConfiguration(ctx, input); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return nil
	}
	if input.Kind == "slash" {
		if err := s.processSlashInput(ctx, input); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return nil
	}
	if input.Kind == "action" {
		if command, ok := slashTextForCommandAction(input); ok {
			input.Text = command
			if err := s.processSlashInput(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionOpenIncident {
			if err := s.handleWatchIncidentOfferAction(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionStartTask {
			if err := s.handleWatchTaskOfferAction(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionApproveProposal ||
			input.ActionID == slackui.ActionRejectProposal {
			if err := s.handleActionProposal(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionOpenApproval {
			if err := s.handleOpenEmisarApproval(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionRememberMemory {
			if err := s.handleRememberMemory(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionForgetMemory {
			if err := s.handleForgetMemory(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionForgetMemoryRollup {
			if err := s.handleForgetMemoryRollup(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionReviewMemory {
			if err := s.finishMemoryReview(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if input.ActionID == slackui.ActionKeepMemoryReview ||
			input.ActionID == slackui.ActionForgetMemoryReview ||
			input.ActionID == slackui.ActionMergeMemoryReview ||
			input.ActionID == slackui.ActionDismissMemoryReview {
			if err := s.handleMemoryReview(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		switch input.ActionID {
		case slackui.ActionRememberPreference:
			if err := s.handleRememberPreference(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionTogglePreference:
			if err := s.handleTogglePreference(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionEditPreference:
			if err := s.handleEditPreference(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionDeletePreference:
			if err := s.handleDeletePreference(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionRememberRule:
			if err := s.handleRememberRule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionToggleRule:
			if err := s.handleToggleRule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionEditRule:
			if err := s.handleEditRule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionDeleteRule:
			if err := s.handleDeleteRule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionRememberSchedule:
			if err := s.handleRememberSchedule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionToggleSchedule:
			if err := s.handleToggleSchedule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionRunSchedule:
			if err := s.handleRunScheduleNow(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionEditSchedule:
			if err := s.handleEditSchedule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		case slackui.ActionDeleteSchedule:
			if err := s.handleDeleteSchedule(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
		if isChannelSetupAction(input.ActionID) {
			if err := s.handleChannelConfigurationAction(ctx, input); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			return nil
		}
	}
	if input.Kind == "shortcut" {
		allowed, allowedErr := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
		if allowedErr != nil {
			return s.retrySlackInput(ctx, input, allowedErr)
		}
		if !allowed {
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "slack.shortcut", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "ignored", Detail: "requester is not an active full workspace member",
			})
			return s.finishSlackInput(ctx, input)
		}
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return nil
	}

	if input.Kind == "message" || input.Kind == "mention" || input.Kind == "direct" {
		handled, configurationErr := s.processConfigurationReply(ctx, input)
		if configurationErr != nil {
			return s.retrySlackInput(ctx, input, configurationErr)
		}
		if handled {
			return nil
		}
		handled, confirmationErr := s.confirmPendingPreferenceReply(ctx, input)
		if confirmationErr != nil {
			return s.retrySlackInput(ctx, input, confirmationErr)
		}
		if handled {
			return nil
		}
		handled, visualErr := s.retryRetainedGeneratedVisual(ctx, input)
		if visualErr != nil {
			return s.retrySlackInput(ctx, input, visualErr)
		}
		if handled {
			return nil
		}
		text := strings.TrimSpace(s.stripBotMention(input.Text))
		if text == "" && len(input.Attachments) == 0 && input.ThreadTS == "" {
			if input.Kind == "mention" || input.Kind == "direct" {
				if err := s.postInputMessageInSourceThread(
					ctx,
					"mention_prompt_"+input.ID,
					input,
					slackui.ConversationResponse(
						"What should I check?",
						s.sanitizer,
					),
				); err != nil {
					return s.retrySlackInput(ctx, input, err)
				}
			}
			return s.finishSlackInput(ctx, input)
		}
		if input.Kind == "mention" || input.Kind == "direct" ||
			(input.Kind == "message" && s.cfg.IsOperator(input.UserID)) {
			if explicitChannelConfigurationRequest(text) {
				if !s.cfg.IsOperator(input.UserID) {
					return s.finishSlashInput(
						ctx, input,
						"**Only a configured operator can change channel behavior.** No settings were changed.",
					)
				}
				if err := s.startChannelConfiguration(ctx, input); err != nil {
					return s.retrySlackInput(ctx, input, err)
				}
				return nil
			}
			if command, ok := conversationalCommand(text); ok {
				input.Kind = "conversation_command"
				input.Text = command
				if err := s.processSlashInput(ctx, input); err != nil {
					return s.retrySlackInput(ctx, input, err)
				}
				return nil
			}
		}
	}

	var incident core.Incident
	var incidentErr error
	if input.Kind == "action" {
		incident, incidentErr = s.store.GetIncident(ctx, input.ActionValue)
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
	watched := false
	directRequest := errors.Is(incidentErr, store.ErrNotFound) &&
		input.Kind == "direct"
	summoned := errors.Is(incidentErr, store.ErrNotFound) &&
		input.Kind == "mention"
	conversationFollowup := false
	if errors.Is(incidentErr, store.ErrNotFound) && input.Kind == "message" {
		conversationFollowup, err = s.isRecentWatchConversation(ctx, input)
		if err != nil {
			return s.retrySlackInput(ctx, input, err)
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
					return s.retrySlackInput(ctx, input, err)
				}
			}
			if !watched {
				watched, err = s.proactiveEnabled(ctx, input.ChannelID)
			}
			if err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			if !watched {
				rules, ruleErr := s.matchingStandingRules(ctx, input)
				if ruleErr != nil {
					return s.retrySlackInput(ctx, input, ruleErr)
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
				return s.retrySlackInput(ctx, input, allowedErr)
			}
			if !allowed {
				_ = s.store.Audit(ctx, core.AuditEvent{
					Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
					Outcome: "ignored", Detail: "sender is not an active full workspace member",
				})
				return s.finishSlackInput(ctx, input)
			}
		}
		location := requestedConversationLocation(s.stripBotMention(input.Text))
		if locationOnlyRequest(s.stripBotMention(input.Text)) {
			responseThreadTS, _, routeErr := s.resolveConversationRoute(ctx, input)
			if routeErr != nil {
				return s.retrySlackInput(ctx, input, routeErr)
			}
			if err := s.postInputMessageAt(
				ctx,
				"conversation_location_"+input.ID,
				input.ChannelID,
				responseThreadTS,
				slackui.Notice(conversationLocationAcknowledgement(location)),
			); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "slack.conversation.location", ActorID: input.UserID,
				ObjectID: input.ID, Outcome: conversationLocationName(location),
				Detail: input.ChannelID,
			})
			return s.finishSlackInput(ctx, input)
		}
		if summoned &&
			s.cfg.IsOperator(input.UserID) &&
			explicitIncidentRequest(s.stripBotMention(input.Text)) {
			return s.createManualIncident(ctx, input)
		}
		if behaviorRequest && incidentSelfInviteBehaviorRequest(input.Text) {
			if err := s.postInputNotice(
				ctx,
				"incident_invite_policy_"+input.ID,
				input,
				"*You’re already included in every incident room.*\n\n"+
					"Your Slack account is a configured operator. Emisar invites every configured "+
					"operator, plus the users in `slack.invite_users`, whenever it creates an "+
					"incident channel.\n\nNo preference was needed or saved. Incident membership "+
					"is an access setting, not agent memory. No incident was created.",
			); err != nil {
				return s.retrySlackInput(ctx, input, err)
			}
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "slack.behavior", ActorID: input.UserID, ObjectID: input.ID,
				Outcome: "already_configured", Detail: "configured operators are invited to incident rooms",
			})
			return s.finishSlackInput(ctx, input)
		}
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return nil
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
		locationOnlyRequest(s.stripBotMention(input.Text)) {
		location := requestedConversationLocation(s.stripBotMention(input.Text))
		if incident.IsThreadScoped() && location == conversationLocationChannel {
			err = s.enqueue(
				ctx, "conversation_location_"+input.ID, incident, "notice",
				incident.ConversationThreadTS(), slackui.Notice(
					"**This engineering task remains in its source thread.** Its authorization, "+
						"working copy, and review controls are bound to that thread so unrelated "+
						"channel messages cannot enter the task. Continue here, or start a separate "+
						"channel conversation with Emisar.",
				),
			)
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
		_ = s.store.Audit(ctx, core.AuditEvent{
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
				_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
					ID:         "tl_input_" + input.ID,
					IncidentID: incident.ID, ChannelID: incident.ChannelID,
					Kind: "operator.message", ActorID: input.UserID,
					Title:  "Operator requested investigation",
					Detail: boundedField(text, 2000), CreatedAt: input.ReceivedAt,
				})
			}
		}
	}
	if err != nil {
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
	_ = s.store.Audit(ctx, core.AuditEvent{
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
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: approval.IncidentID,
		Kind:       "emisar.approval.opened",
		ActorID:    input.UserID,
		ObjectID:   approval.RequestID,
		Outcome:    "linked",
		Detail:     approval.ActionID + " runner=" + approval.RunnerRef,
	})
	return s.finishSlackInput(ctx, input)
}

func (s *Service) handleActionProposal(ctx context.Context, input core.SlackInput) error {
	proposal, err := s.store.GetActionProposal(ctx, input.ActionValue)
	if errors.Is(err, store.ErrNotFound) {
		return s.finishSlashInput(
			ctx, input,
			"*This action proposal is no longer valid.* The stored proposal cannot be found. "+
				"No operational action was taken.",
		)
	}
	if err != nil {
		return err
	}
	if proposal.ChannelID != input.ChannelID {
		return s.finishSlashInput(
			ctx, input,
			"*This action proposal belongs to another incident room.* Use the controls in the "+
				"original room. No operational action was taken.",
		)
	}
	if !s.cfg.IsOperator(input.UserID) {
		return s.finishSlashInput(
			ctx, input,
			"*This action proposal was not approved.* Only a configured incident operator can "+
				"approve or reject operational work.",
		)
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		return s.finishSlashInput(
			ctx, input,
			"*This action proposal was not approved.* Approval requires an active full member of "+
				"the configured Slack workspace.",
		)
	}
	policy, ok := s.cfg.Actions[proposal.ActionName]
	if !ok || policy.Authority != proposal.Authority {
		return s.finishSlashInput(
			ctx, input,
			"*This action proposal is no longer authorized by configuration.* The configured action "+
				"catalog changed after the proposal was created. No operational action was taken.",
		)
	}
	decision := "approve"
	if input.ActionID == slackui.ActionRejectProposal {
		decision = "reject"
	}
	proposal, err = s.store.DecideActionProposal(
		ctx, proposal.ID, input.UserID, decision, time.Now().UTC(),
	)
	if err != nil {
		return err
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: proposal.IncidentID, Kind: "action.proposal." + decision,
		ActorID: input.UserID, ObjectID: proposal.ID, Outcome: proposal.Status,
		Detail: proposal.ActionName + " target=" + proposal.Target,
	})
	eventTitle := "Approved proposed action"
	if decision == "reject" {
		eventTitle = "Rejected proposed action"
	}
	_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
		ID:         "tl_action_" + proposal.ID + "_" + decision,
		IncidentID: proposal.IncidentID, ChannelID: proposal.ChannelID,
		Kind: "action." + decision, ActorID: input.UserID,
		Title:  eventTitle,
		Detail: proposal.ActionName + " for " + proposal.Target,
	})
	switch proposal.Status {
	case "rejected":
		return s.finishSlashInput(
			ctx, input,
			"*Action proposal rejected.* No operational action ran. The proposal and decision "+
				"remain in the incident timeline and audit history.",
		)
	case "expired":
		return s.finishSlashInput(
			ctx, input,
			"*This action proposal expired before approval.* Ask Responder to re-check current "+
				"evidence and create a new proposal. No operational action ran.",
		)
	case "pending":
		return s.finishSlashInput(
			ctx, input,
			fmt.Sprintf(
				"*Approval recorded: %d of %d.* A different configured operator must approve "+
					"before the request can be submitted. No operational action has run.",
				proposal.ApprovalCount, proposal.Required,
			),
		)
	case "executing", "finished", "failed":
		return s.finishSlashInput(
			ctx, input,
			"*This proposal has already left the approval stage.* Its current state is `"+
				proposal.Status+"`. Check the incident thread and timeline for the result.",
		)
	case "approved":
	default:
		return fmt.Errorf("unsupported action proposal state %q", proposal.Status)
	}
	incident, err := s.store.GetIncident(ctx, proposal.IncidentID)
	if err != nil {
		return err
	}
	if incident.Status == core.IncidentClosed || !incident.ChannelWritable() {
		return s.finishSlashInput(
			ctx, input,
			"*Approval completed, but the action was not submitted.* The incident is closed or its "+
				"Slack room is unavailable. Re-open or rebind operational work explicitly after "+
				"reviewing current evidence.",
		)
	}
	parameters, err := json.Marshal(proposal.Parameters)
	if err != nil {
		return err
	}
	prompt := fmt.Sprintf(
		`Two-stage host validation is complete for stored proposal %s.
Use the policy-authorized Emisar MCP path to request exactly the configured action %q against
target %q with these untrusted parameter values:
<untrusted-action-parameters>%s</untrusted-action-parameters>

Do not substitute another action or expand the target. Emisar authorization and any Emisar approval
remain authoritative; Slack approval does not bypass them. Before requesting execution, re-check
the evidence and stop if it is stale or the action is no longer justified. Report whether Emisar
authorized, rejected, awaited approval, or completed the request. Never claim success without
post-action verification matching this requirement: %s

Blast radius stated at approval: %s
Rollback stated at approval: %s`,
		proposal.ID,
		proposal.ActionName,
		proposal.Target,
		parameters,
		proposal.Verification,
		proposal.BlastRadius,
		proposal.Rollback,
	)
	_, _, err = s.queueIncidentAgentRun(
		ctx, incident, "proposal", proposal.ID, input.UserID, prompt,
	)
	if err != nil {
		return err
	}
	if err := s.store.MarkProposalExecution(
		ctx, proposal.ID, "executing", "", "approved and queued for Coop",
	); err != nil {
		return err
	}
	s.setNativeStatus(ctx, incident, "is re-checking an approved action with Emisar...")
	return s.finishSlashInput(
		ctx, input,
		"*Required approval is complete.* Responder queued the exact stored request for a fresh "+
			"evidence check and Emisar authorization. This does not mean the action is approved by "+
			"Emisar or has succeeded; the incident thread will show the authoritative outcome.",
	)
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
		if _, err := s.store.DeleteConversationMemories(ctx, input.ChannelID); err != nil {
			return err
		}
		if _, err := s.store.DeleteConversationRoutes(ctx, input.ChannelID); err != nil {
			return err
		}
		deleted, err := s.store.DeleteChannelMemoryEntries(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		if deleted > 0 {
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "memory.channel_deleted", ActorID: input.UserID,
				ObjectID: input.ChannelID, Outcome: "deleted",
				Detail: fmt.Sprintf("entries=%d", deleted),
			})
		}
		preferences, rules, err := s.store.DeleteChannelBehavior(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		if preferences+rules > 0 {
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "behavior.channel_deleted", ActorID: input.UserID,
				ObjectID: input.ChannelID, Outcome: "deleted",
				Detail: fmt.Sprintf("preferences=%d rules=%d", preferences, rules),
			})
		}
		schedules, err := s.store.DeleteChannelSchedules(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		if schedules > 0 {
			_ = s.store.Audit(ctx, core.AuditEvent{
				Kind: "schedule.channel_deleted", ActorID: input.UserID,
				ObjectID: input.ChannelID, Outcome: "deleted",
				Detail: fmt.Sprintf("schedules=%d", schedules),
			})
		}
	}
	for _, incident := range incidents {
		s.forgetNativeStatus(incident.ID)
		_ = s.store.Audit(ctx, core.AuditEvent{
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
	if len(title) > 200 {
		title = title[:200]
	}
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
			_ = s.store.Audit(ctx, core.AuditEvent{
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
	return s.postInputMessage(ctx, id, input, slackui.Notice(text))
}

func (s *Service) postInputNoticeInSourceThread(
	ctx context.Context,
	id string,
	input core.SlackInput,
	text string,
) error {
	return s.postInputMessageInSourceThread(
		ctx,
		id,
		input,
		slackui.Notice(text),
	)
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
	if s.sanitizer != nil {
		message = s.sanitizer.Message(message)
	}
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
) error {
	if s.sanitizer != nil {
		message = s.sanitizer.Message(message)
	}
	body, err := slackui.Encode(message)
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: id, Operation: "post", Kind: kind,
		ChannelID: channelID, ThreadTS: threadTS, Body: body,
	})
	return err
}

func conversationLocationName(location conversationLocation) string {
	switch location {
	case conversationLocationChannel:
		return "channel"
	case conversationLocationThread:
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
		return s.enqueue(ctx, "out_repair_review_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(), slackui.Notice(
				"I’m already working in this task. I’ll keep the readiness failure in context; "+
					"wait for this run to finish, then retry the draft PR.",
			))
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
		return s.enqueue(ctx, "out_changes_"+input.ID, incident, "notice",
			threadTS, slackui.Notice(
				"*Code changes are not available yet.* Emisar is still preparing the "+
					"isolated working copy. Wait for the task to show *Waiting for input* "+
					"or *Investigating*, then try again.",
			))
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
	return s.enqueue(ctx, "out_extend_"+input.ID, incident, "notice",
		incident.ConversationThreadTS(),
		slackui.Notice(fmt.Sprintf(
			"*Manual turn allocation is no longer required.* Responder automatically adds "+
				"session capacity when authorized work arrives, up to this channel's safety "+
				"ceiling of %d accepted requests. Tool calls and investigation steps inside a "+
				"request are not counted separately. Use `/responder turn-limit` to inspect or "+
				"change the ceiling.",
			limit,
		)))
}

func (s *Service) reviewFix(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.CoopSessionID == "" {
		return s.enqueue(ctx, "out_review_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(), slackui.Notice(
				"*Fix review is not available yet.* Responder is still preparing the isolated "+
					"working copy. Wait for the pinned card to show *Waiting for input*, then "+
					"run the review again.",
			))
	}
	if incident.ActiveTurnID != "" {
		return s.enqueue(ctx, "out_review_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(), slackui.Notice(
				"*Fix review did not start because an agent turn is still running.* Wait for "+
					"that run to finish, or use *Stop current run*, then request review again. "+
					"The review is read-only and never merges or deploys.",
			))
	}
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		return err
	}
	if !coopChangesPresent(changes) {
		return s.enqueue(ctx, "out_review_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(), slackui.Notice(
				"*There is no proposed code change to review.* Fix readiness checks compare "+
					"the isolated change with the current repository, test whether it can be "+
					"rebased, and run configured validation and policy gates. This incident's "+
					"working copy has no changed files, so no review was started.",
			))
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
	review := publicationReview(rawReview)
	err = s.enqueue(
		ctx, "out_review_"+input.ID, incident, "review", incident.ConversationThreadTS(),
		slackui.ReviewMessage(incident, reviewSummary(rawReview), review.Publishable))
	if err != nil {
		s.clearNativeStatus(ctx, incident)
	}
	return err
}

func (s *Service) stopTurn(ctx context.Context, input core.SlackInput, incident core.Incident) error {
	if incident.ActiveTurnID == "" {
		return s.enqueue(ctx, "out_stop_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(), slackui.Notice(
				"*Nothing was stopped.* No agent turn is currently running. Responder is "+
					"waiting for input; reply with the next request, ask for an update, or close "+
					"the incident.",
			))
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
		return s.enqueue(ctx, "out_close_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(), slackui.Notice(
				"*The "+noun+" was not closed because an agent turn is still running.* Use "+
					"*Stop current run* and wait for it to stop, then close it again. "+
					"No work or evidence was discarded.",
			))
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
			time.Now().UTC().Add(s.cfg.Retention.ClosedSessionGrace.Duration),
		); err != nil {
			return err
		}
	}
	if err := s.store.CloseIncident(ctx, incident.ID); err != nil {
		return err
	}
	auditKind := "incident.close"
	timelineKind := "incident.closed"
	timelineTitle := "Incident closed"
	if incident.IsEngineeringTask() {
		auditKind = "engineering_task.close"
		timelineKind = "engineering_task.closed"
		timelineTitle = "Engineering task closed"
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: auditKind, ActorID: input.UserID,
		ObjectID: incident.CoopSessionID, Outcome: "succeeded",
	})
	_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
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

func (s *Service) retrySlackInput(ctx context.Context, input core.SlackInput, err error) error {
	terminal := terminalAttempt(input.Failures+1, s.cfg.Limits.MaxSlackInputAttempts)
	var apiErr *coop.APIError
	if errors.As(err, &apiErr) && !apiErr.Retryable() {
		terminal = true
	}
	if terminal {
		if incident, incidentErr := s.store.FindIncidentForConversation(
			ctx,
			input.ChannelID,
			slackReplyThread(input),
		); incidentErr == nil {
			_ = s.enqueue(
				ctx,
				"out_input_error_"+input.ID,
				incident,
				"notice",
				incident.ConversationThreadTS(),
				slackui.Notice(
					"*Responder could not complete that request after retrying.*\n\n"+
						"Reason: `"+trimError(err)+"`\n\nThe incident and isolated working copy "+
						"are preserved. Check the pinned card for the current state, then retry "+
						"the command or reply with a different next step.",
				),
			)
		}
	}
	return s.store.RetrySlackInputFailure(
		ctx,
		input.ID,
		trimError(err),
		queueDelay(input.Failures+1),
		terminal,
	)
}

func (s *Service) finishSlackInput(ctx context.Context, input core.SlackInput) error {
	if err := s.store.FinishSlackInput(ctx, input.ID); err != nil {
		_ = s.store.RetrySlackInput(ctx, input.ID, trimError(err), queueDelay(input.Attempts), false)
		return err
	}
	return nil
}

func (s *Service) denyInput(ctx context.Context, input core.SlackInput, reason string) {
	incident, err := s.store.FindIncidentForConversation(
		ctx,
		input.ChannelID,
		slackReplyThread(input),
	)
	if err == nil {
		_ = s.enqueue(ctx, "out_denied_"+input.ID, incident, "notice",
			incident.ConversationThreadTS(), slackui.Notice(reason))
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "slack.input", ActorID: input.UserID,
		ObjectID: input.ID, Outcome: "denied", Detail: reason,
	})
}
