package service

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/channelsetup"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const (
	channelRepositorySettingName = "repository"
	defaultAlertPolicy           = "automatic"
	channelConfigurationLease    = 30 * time.Minute
)

var (
	slackUserMentionPattern  = regexp.MustCompile(`<@([A-Z0-9]+)>`)
	slackGroupMentionPattern = regexp.MustCompile(`<!subteam\^([A-Z0-9]+)(?:\|[^>]+)?>`)
)

func (s *Service) startChannelConfiguration(
	ctx context.Context,
	input core.SlackInput,
) error {
	channel, err := s.slack.GetChannel(ctx, input.ChannelID)
	if err != nil {
		return err
	}
	if !channel.Member || channel.Archived {
		return s.finishSlackInput(ctx, input)
	}
	session, resumed, err := s.openConfigurationSession(ctx, input)
	if err != nil {
		return err
	}
	message := slackui.ChannelSetupQuestion(
		channel.Name, session, s.setupRepositoryChoices(),
	)
	cardTS := ""
	if resumed {
		cardTS, _, err = s.placeConfigurationCard(ctx, session, "", message)
	} else {
		cardTS, err = s.postConfigurationMessage(
			ctx, configurationCardDeliveryID(session.ID), input.ChannelID, "", message,
		)
	}
	if err != nil {
		return err
	}
	if err := s.store.BindConfigurationThread(ctx, session.ID, cardTS); err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.configuration.started", ActorID: input.UserID,
		ObjectID: session.ID, Outcome: "asking", Detail: input.ChannelID,
	})
	return s.finishSlackInput(ctx, input)
}

// openConfigurationSession returns the session this request should drive, and
// whether it was already under way.
//
// Starting a setup replaces whatever is live in the channel, which is right when
// an operator asks to reconfigure it and wrong when the previous attempt merely
// failed to record the card it had already posted. A session holding no card was
// never shown to anybody, so there is nothing to replace: it is an unfinished
// start, and finishing it adopts the card that is already in the channel rather
// than cancelling the session that owns it and posting a second one beside it.
func (s *Service) openConfigurationSession(
	ctx context.Context,
	input core.SlackInput,
) (core.ConfigurationSession, bool, error) {
	existing, err := s.store.GetActiveConfigurationSession(ctx, input.ChannelID)
	switch {
	case err == nil && existing.CardTS == "" && existing.ThreadTS == "" &&
		existing.ExpiresAt.After(s.now().UTC()):
		return existing, true, nil
	case err == nil:
		if err := s.store.FinishConfigurationSession(
			ctx, existing.ID, existing.Revision, "cancelled",
		); err != nil && !errors.Is(err, store.ErrConflict) {
			return core.ConfigurationSession{}, false, err
		}
	case !errors.Is(err, store.ErrNotFound):
		return core.ConfigurationSession{}, false, err
	}
	initiator := ""
	if s.cfg.IsOperator(input.UserID) {
		allowed, allowedErr := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
		if allowedErr != nil {
			return core.ConfigurationSession{}, false, allowedErr
		}
		if allowed {
			initiator = input.UserID
		}
	}
	draft := core.ChannelConfiguration{
		ChannelID: input.ChannelID, Participation: "mentions",
		Repository: s.cfg.Slack.DefaultRepository, AlertPolicy: "reply",
	}
	if confirmed, confirmedErr := s.store.GetChannelConfiguration(
		ctx, input.ChannelID,
	); confirmedErr == nil {
		draft = confirmed
		draft.ActorID = ""
	} else if !errors.Is(confirmedErr, store.ErrNotFound) {
		return core.ConfigurationSession{}, false, confirmedErr
	}
	session, err := s.store.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: input.TeamID, ChannelID: input.ChannelID, Initiator: initiator,
		Step: "participation", Status: "asking",
		Draft:     draft,
		ExpiresAt: s.now().UTC().Add(channelConfigurationLease),
	})
	return session, false, err
}

func (s *Service) shouldAdmitConfigurationMessage(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	session, err := s.configurationSessionForReply(ctx, input.ChannelID)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !s.cfg.IsOperator(input.UserID) {
		return false, nil
	}
	if session.Status == "expired" && input.ThreadTS == "" {
		return false, nil
	}
	if input.ThreadTS != "" {
		for _, root := range session.ThreadRoots {
			if input.ThreadTS == root {
				return true, nil
			}
		}
		return false, nil
	}
	if session.Initiator != "" && input.UserID != session.Initiator {
		return false, nil
	}
	return true, nil
}

func (s *Service) processConfigurationReply(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	session, err := s.configurationSessionForReply(ctx, input.ChannelID)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	admit, err := s.shouldAdmitConfigurationMessage(ctx, input)
	if err != nil || !admit {
		return false, err
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return true, err
	}
	if !allowed {
		return true, s.finishSlackInput(ctx, input)
	}
	renewed := false
	if !session.ExpiresAt.After(s.now().UTC()) {
		session, err = s.renewConfigurationSession(ctx, session, input.UserID)
		if err != nil {
			return true, err
		}
		renewed = true
	}
	text := strings.TrimSpace(s.stripBotMention(input.Text))
	responseThreadTS := conversationalResponseThread(input)
	command := decisionpkg.NormalizeLocationRequest(text)
	if command == "cancel" || command == "cancel setup" {
		if err := s.store.FinishConfigurationSession(
			ctx, session.ID, session.Revision, "cancelled",
		); err != nil {
			return true, err
		}
		if err := s.closeConfigurationCard(
			ctx, session, responseThreadTS, slackui.ChannelSetupCancelled(),
		); err != nil {
			return true, err
		}
		return true, s.finishSlackInput(ctx, input)
	}
	next, status, answerErr := s.applyConfigurationAnswer(ctx, &session, input.UserID, text)
	if answerErr != nil {
		// An operator who asked to move the conversation gets the question
		// again, where they asked for it. Everyone else mistyped an answer, and
		// that is between Responder and them.
		//
		// It used to be a channel post. So one person fumbling a setup answer
		// put "I could not map that answer to a safe typed setting" in front of
		// everyone in the room, repeated once per attempt — a message with
		// exactly one useful reader and an audience of dozens. Nobody else can
		// act on it, and a channel that learns Responder posts its errors there
		// is a channel that starts tuning Responder out.
		//
		// Ephemeral needs no bookkeeping — it has no timestamp of its own to
		// record — but it does need to land where the question did, which is
		// what responseThreadTS already decided for the setup card. Setup run
		// in the channel resolves that to "" and stays at channel level.
		if decisionpkg.RequestedConversationLocation(text) == decisionpkg.ConversationLocationFollow {
			message := slackui.Notice(
				"**I could not map that answer to a safe typed setting.**\n\n" +
					answerErr.Error() + "\n\nNothing was saved. Reply again, or say `cancel setup`.",
			)
			if renewed {
				message.Context = append(
					[]string{"The previous setup expired, so I renewed it. Nothing is saved yet."},
					message.Context...,
				)
			}
			if err := s.slack.PostEphemeral(
				ctx,
				session.ChannelID,
				input.UserID,
				responseThreadTS,
				s.sanitizeMessage(message),
			); err != nil {
				return true, err
			}
			return true, s.finishSlackInput(ctx, input)
		}
		channel, channelErr := s.slack.GetChannel(ctx, session.ChannelID)
		if channelErr != nil {
			return true, channelErr
		}
		message := slackui.ChannelSetupQuestion(channel.Name, session, s.setupRepositoryChoices())
		if renewed {
			message.Context = append(
				[]string{"The previous setup expired, so I renewed it. Nothing is saved yet."},
				message.Context...,
			)
		}
		if err := s.showConfigurationCard(
			ctx, session, responseThreadTS, message,
		); err != nil {
			return true, err
		}
		return true, s.finishSlackInput(ctx, input)
	}
	session, err = s.store.AdvanceConfigurationSession(
		ctx, session.ID, session.Revision, next, status, session.Draft,
	)
	if err != nil {
		return true, err
	}
	channel, err := s.slack.GetChannel(ctx, session.ChannelID)
	if err != nil {
		return true, err
	}
	var message slackui.Message
	if session.Step == "confirm" {
		message = slackui.ChannelSetupConfirmation(
			channel.Name, session, s.repositoryChoice(session.Draft.Repository),
		)
	} else {
		message = slackui.ChannelSetupQuestion(
			channel.Name, session, s.setupRepositoryChoices(),
		)
	}
	if renewed {
		message.Context = append(
			[]string{
				"The previous setup expired, so I renewed it and applied your answer. Nothing is saved yet.",
			},
			message.Context...,
		)
	}
	if err := s.showConfigurationCard(ctx, session, responseThreadTS, message); err != nil {
		return true, err
	}
	return true, s.finishSlackInput(ctx, input)
}

func (s *Service) configurationSessionForReply(
	ctx context.Context,
	channelID string,
) (core.ConfigurationSession, error) {
	session, err := s.store.GetActiveConfigurationSession(ctx, channelID)
	if !errors.Is(err, store.ErrNotFound) {
		return session, err
	}
	session, err = s.store.GetLatestConfigurationSession(ctx, channelID)
	if err != nil {
		return core.ConfigurationSession{}, err
	}
	if session.Status != "expired" {
		return core.ConfigurationSession{}, store.ErrNotFound
	}
	return session, nil
}

func (s *Service) renewConfigurationSession(
	ctx context.Context,
	expired core.ConfigurationSession,
	actorID string,
) (core.ConfigurationSession, error) {
	if expired.Status != "expired" {
		if err := s.store.FinishConfigurationSession(
			ctx, expired.ID, expired.Revision, "expired",
		); err != nil {
			if errors.Is(err, store.ErrConflict) {
				return s.store.GetActiveConfigurationSession(ctx, expired.ChannelID)
			}
			return core.ConfigurationSession{}, err
		}
	}
	replacement := expired
	replacement.ID = ""
	replacement.Initiator = actorID
	replacement.Status = "asking"
	if replacement.Step == "confirm" {
		replacement.Status = "confirming"
	}
	replacement.ExpiresAt = s.now().UTC().Add(channelConfigurationLease)
	replacement.CreatedAt = time.Time{}
	replacement.UpdatedAt = time.Time{}
	replacement.Revision = 0
	replacement, err := s.store.CreateConfigurationSession(ctx, replacement)
	if err != nil {
		if errors.Is(err, store.ErrConflict) {
			return s.store.GetActiveConfigurationSession(ctx, expired.ChannelID)
		}
		return core.ConfigurationSession{}, err
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.configuration.renewed", ActorID: actorID,
		ObjectID: replacement.ID, Outcome: replacement.Status, Detail: expired.ID,
	})
	return replacement, nil
}

func (s *Service) applyConfigurationAnswer(
	ctx context.Context,
	session *core.ConfigurationSession,
	actorID string,
	text string,
) (string, string, error) {
	normalized := strings.ToLower(strings.TrimSpace(text))
	switch session.Step {
	case "participation":
		switch {
		case strings.Contains(normalized, "shadow"):
			session.Draft.Participation = "shadow"
		case strings.Contains(normalized, "proactive") ||
			strings.Contains(normalized, "read everything") ||
			strings.Contains(normalized, "human would"):
			session.Draft.Participation = "proactive"
		case strings.Contains(normalized, "mention") ||
			normalized == "off" || normalized == "default":
			session.Draft.Participation = "mentions"
		default:
			return "", "", errors.New("Choose `mentions only`, `proactive`, or `shadow`.")
		}
		return "repository", "asking", nil
	case "repository":
		repository, ok := s.resolveConfigurationRepository(normalized)
		if !ok {
			return "", "", fmt.Errorf(
				"Name one configured repository or repository set: `%s`, or reply `default`.",
				strings.Join(s.repositoryKeys(), "`, `"),
			)
		}
		session.Draft.Repository = repository
		return "alerts", "asking", nil
	case "alerts":
		switch {
		case strings.Contains(normalized, "automatic") ||
			strings.Contains(normalized, "auto incident"):
			session.Draft.AlertPolicy = "automatic"
		case strings.Contains(normalized, "offer") ||
			strings.Contains(normalized, "button") ||
			strings.Contains(normalized, "ask"):
			session.Draft.AlertPolicy = "offer"
		case strings.Contains(normalized, "reply") ||
			strings.Contains(normalized, "no incident") ||
			strings.Contains(normalized, "in place"):
			session.Draft.AlertPolicy = "reply"
		default:
			return "", "", errors.New(
				"Choose `reply here`, `offer incident`, or `automatic incident`.",
			)
		}
		return "audience", "asking", nil
	case "audience":
		users, groups, err := s.resolveConfigurationAudience(ctx, actorID, text)
		if err != nil {
			return "", "", err
		}
		session.Draft.InviteUsers = users
		session.Draft.InviteUserGroups = groups
		session.Draft.ActorID = actorID
		return "confirm", "confirming", nil
	default:
		return "", "", errors.New("this setup is waiting for confirmation, not another answer")
	}
}

func (s *Service) resolveConfigurationAudience(
	ctx context.Context,
	actorID string,
	text string,
) ([]string, []string, error) {
	normalized := strings.ToLower(strings.TrimSpace(text))
	users := channelsetup.CaptureSlackIDs(slackUserMentionPattern, text)
	groups := channelsetup.CaptureSlackIDs(slackGroupMentionPattern, text)
	if strings.Contains(normalized, "include me") || normalized == "me" {
		users = append(users, actorID)
	}
	if (strings.Contains(normalized, "no additional invitees") ||
		strings.Contains(normalized, "no one else") ||
		strings.Contains(normalized, "operators only") ||
		normalized == "operators") &&
		len(users) == 0 && len(groups) == 0 {
		return nil, nil, nil
	}
	users = channelsetup.UniqueSorted(users)
	groups = channelsetup.UniqueSorted(groups)
	if len(users) == 0 && len(groups) == 0 {
		return nil, nil, errors.New(
			"Choose `no additional invitees`, or mention at least one active Slack member or user group.",
		)
	}
	for _, user := range users {
		allowed, err := s.slack.UserAllowed(ctx, user, s.cfg.Slack.TeamID)
		if err != nil {
			return nil, nil, fmt.Errorf("Slack could not validate <@%s>: %w", user, err)
		}
		if !allowed {
			return nil, nil, fmt.Errorf(
				"<@%s> is not eligible for incident-room invitations; choose an active full "+
					"human workspace member, not a Slack app, guest, external member, or deactivated account",
				user,
			)
		}
	}
	for _, group := range groups {
		members, err := s.slack.UserGroupMembers(ctx, group, s.cfg.Slack.TeamID)
		if err != nil {
			return nil, nil, fmt.Errorf("Slack could not validate user group %s: %w", group, err)
		}
		if err := s.validateUserGroupMembers(ctx, group, members); err != nil {
			return nil, nil, err
		}
	}
	return users, groups, nil
}

// renewedConfigurationSession extends an expired setup session when the person
// pressing a control is clearly still working on it, and reports whether the
// session is worth acting on at all.
//
// Setup controls stay in the channel after they expire, so a stale button is
// normal rather than exceptional. Renewing rather than refusing is the kinder
// behaviour: someone who walks away mid-setup and comes back should be able to
// continue, not be told to start over. The exception is a session that has
// already been superseded by a newer one — acting on that would apply an
// answer to a conversation that has moved on.
func (s *Service) renewedConfigurationSession(
	ctx context.Context,
	input core.SlackInput,
	session core.ConfigurationSession,
) (core.ConfigurationSession, bool, error) {
	if session.ExpiresAt.After(s.now().UTC()) {
		return session, true, nil
	}
	if session.Status == "expired" {
		latest, err := s.store.GetLatestConfigurationSession(ctx, session.ChannelID)
		if err != nil {
			return session, false, err
		}
		if latest.ID != session.ID {
			return session, false, nil
		}
	} else if session.Status != "asking" && session.Status != "confirming" {
		return session, false, nil
	}
	renewed, err := s.renewConfigurationSession(ctx, session, input.UserID)
	if err != nil {
		return session, false, err
	}
	return renewed, true, nil
}

func (s *Service) handleChannelConfigurationAction(
	ctx context.Context,
	input core.SlackInput,
) error {
	session, err := s.store.GetConfigurationSession(ctx, input.ActionValue)
	if errors.Is(err, store.ErrNotFound) {
		return s.finishSlashInput(
			ctx, input,
			"**This channel setup no longer exists.** No settings were changed. Ask `@Emisar reconfigure this channel` to start again.",
		)
	}
	if err != nil {
		return err
	}
	if session.ChannelID != input.ChannelID {
		return s.finishSlashInput(
			ctx, input,
			"**This setup control belongs to another conversation.** No settings were changed.",
		)
	}
	if !s.cfg.IsOperator(input.UserID) {
		return s.finishSlashInput(
			ctx, input,
			"**Only a configured operator can save channel behavior.** No settings were changed.",
		)
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		return s.finishSlackInput(ctx, input)
	}
	quickSetup := session.Initiator == "" && session.Draft.ActorID == ""
	session, live, err := s.renewedConfigurationSession(ctx, input, session)
	if err != nil {
		return err
	}
	if !live {
		return s.finishSlackInput(ctx, input)
	}
	responseThreadTS := conversationalResponseThread(input)
	switch input.ActionID {
	case slackui.ActionSetupQuickMentions, slackui.ActionSetupQuickProactive:
		return s.saveQuickChannelSetup(ctx, input, session, quickSetup, responseThreadTS)
	case slackui.ActionSetupCustomize:
		return s.startCustomChannelSetup(ctx, input, session, quickSetup, responseThreadTS)
	}
	if expectedStep, answer, choice := channelsetup.ChannelSetupChoice(input.ActionID); choice {
		return s.answerChannelSetupQuestion(
			ctx, input, session, expectedStep, answer, responseThreadTS,
		)
	}
	switch input.ActionID {
	case slackui.ActionCancelChannelSetup:
		if err := s.store.FinishConfigurationSession(
			ctx, session.ID, session.Revision, "cancelled",
		); err != nil {
			return err
		}
		err = s.closeConfigurationCard(
			ctx, session, responseThreadTS, slackui.ChannelSetupCancelled(),
		)
	case slackui.ActionRestartChannelSetup:
		session.Draft = core.ChannelConfiguration{
			ChannelID: session.ChannelID, Participation: "mentions",
			Repository: s.cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		}
		session, err = s.store.AdvanceConfigurationSession(
			ctx, session.ID, session.Revision, "participation", "asking", session.Draft,
		)
		if err == nil {
			channel, channelErr := s.slack.GetChannel(ctx, session.ChannelID)
			if channelErr != nil {
				return channelErr
			}
			err = s.showConfigurationCard(
				ctx, session, responseThreadTS,
				slackui.ChannelSetupQuestion(
					channel.Name, session, s.setupRepositoryChoices(),
				),
			)
		}
	case slackui.ActionSaveChannelConfig:
		if session.Status != "confirming" || session.Step != "confirm" ||
			!session.ExpiresAt.After(s.now().UTC()) {
			return s.finishSlashInput(
				ctx, input,
				"**This setup is not ready to save or has expired.** No settings were changed. Start the setup again.",
			)
		}
		session.Draft.ActorID = input.UserID
		configuration, saveErr := s.store.SaveChannelConfiguration(ctx, session.Draft)
		if saveErr != nil {
			return saveErr
		}
		if err := s.store.FinishConfigurationSession(
			ctx, session.ID, session.Revision, "saved",
		); err != nil {
			return err
		}
		channel, channelErr := s.slack.GetChannel(ctx, session.ChannelID)
		if channelErr != nil {
			return channelErr
		}
		err = s.closeConfigurationCard(
			ctx, session, responseThreadTS, slackui.ChannelSetupSaved(
				channel.Name, configuration, s.repositoryChoice(configuration.Repository),
			),
		)
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.configuration.saved", ActorID: input.UserID,
			ObjectID: session.ID, Outcome: "saved",
			Detail: fmt.Sprintf(
				"channel=%s participation=%s repository=%s alerts=%s",
				session.ChannelID, configuration.Participation,
				configuration.Repository, configuration.AlertPolicy,
			),
		})
	default:
		return errors.New("unknown channel configuration action")
	}
	if err != nil {
		return err
	}
	return s.finishSlackInput(ctx, input)
}

// saveQuickChannelSetup applies one of the two one-click participation choices
// and finishes the session immediately.
//
// It re-checks that the session is still on the participation step and still
// unclaimed, because these buttons live in a message that stays in the channel.
// Someone can press one minutes after another person already finished the
// setup, and applying it then would silently overwrite their choice.
func (s *Service) saveQuickChannelSetup(
	ctx context.Context,
	input core.SlackInput,
	session core.ConfigurationSession,
	quickSetup bool,
	responseThreadTS string,
) error {
	if session.Status != "asking" || session.Step != "participation" ||
		!quickSetup || session.Draft.ActorID != "" ||
		!session.ExpiresAt.After(s.now().UTC()) {
		return s.finishSlashInput(
			ctx, input,
			"**That quick setup choice is no longer current.** Nothing was changed. Use the latest setup controls.",
		)
	}
	session.Draft.Participation = "mentions"
	if input.ActionID == slackui.ActionSetupQuickProactive {
		session.Draft.Participation = "proactive"
	}
	session.Draft.ActorID = input.UserID
	configuration, saveErr := s.store.SaveChannelConfiguration(ctx, session.Draft)
	if saveErr != nil {
		return saveErr
	}
	if err := s.store.FinishConfigurationSession(
		ctx, session.ID, session.Revision, "saved",
	); err != nil {
		return err
	}
	channel, channelErr := s.slack.GetChannel(ctx, session.ChannelID)
	if channelErr != nil {
		return channelErr
	}
	if err := s.closeConfigurationCard(
		ctx,
		session,
		responseThreadTS,
		slackui.ChannelSetupSaved(
			channel.Name, configuration, s.repositoryChoice(configuration.Repository),
		),
	); err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.configuration.saved", ActorID: input.UserID,
		ObjectID: session.ID, Outcome: "quick_saved",
		Detail: fmt.Sprintf(
			"channel=%s participation=%s repository=%s alerts=%s",
			session.ChannelID, configuration.Participation,
			configuration.Repository, configuration.AlertPolicy,
		),
	})
	return s.finishSlackInput(ctx, input)
}

// startCustomChannelSetup moves a session from the quick choice into the full
// wizard, replacing the controls in place so the ones just pressed cannot be
// pressed again.
func (s *Service) startCustomChannelSetup(
	ctx context.Context,
	input core.SlackInput,
	session core.ConfigurationSession,
	quickSetup bool,
	responseThreadTS string,
) error {
	var err error
	if session.Status != "asking" || session.Step != "participation" ||
		!quickSetup || session.Draft.ActorID != "" ||
		!session.ExpiresAt.After(s.now().UTC()) {
		return s.finishSlashInput(
			ctx, input,
			"**That setup control is no longer current.** Nothing was changed. Use the latest setup controls.",
		)
	}
	session.Draft.ActorID = input.UserID
	session, err = s.store.AdvanceConfigurationSession(
		ctx,
		session.ID,
		session.Revision,
		"participation",
		"asking",
		session.Draft,
	)
	if err != nil {
		return err
	}
	channel, channelErr := s.slack.GetChannel(ctx, session.ChannelID)
	if channelErr != nil {
		return channelErr
	}
	if err := s.showConfigurationCard(
		ctx,
		session,
		responseThreadTS,
		slackui.ChannelSetupQuestion(
			channel.Name, session, s.setupRepositoryChoices(),
		),
	); err != nil {
		return err
	}
	return s.finishSlackInput(ctx, input)
}

// answerChannelSetupQuestion records one wizard answer and asks the next
// question, or moves to confirmation when the answer was the last one.
func (s *Service) answerChannelSetupQuestion(
	ctx context.Context,
	input core.SlackInput,
	session core.ConfigurationSession,
	expectedStep string,
	answer string,
	responseThreadTS string,
) error {
	var err error
	if session.Status != "asking" || session.Step != expectedStep ||
		!session.ExpiresAt.After(s.now().UTC()) {
		return s.finishSlashInput(
			ctx, input,
			"**That setup choice is no longer current.** Nothing was changed. Use the controls on the latest setup question.",
		)
	}
	next, status, answerErr := s.applyConfigurationAnswer(
		ctx, &session, input.UserID, answer,
	)
	if answerErr != nil {
		return answerErr
	}
	session, err = s.store.AdvanceConfigurationSession(
		ctx, session.ID, session.Revision, next, status, session.Draft,
	)
	if err != nil {
		return err
	}
	channel, channelErr := s.slack.GetChannel(ctx, session.ChannelID)
	if channelErr != nil {
		return channelErr
	}
	var message slackui.Message
	if session.Step == "confirm" {
		message = slackui.ChannelSetupConfirmation(
			channel.Name, session, s.repositoryChoice(session.Draft.Repository),
		)
	} else {
		message = slackui.ChannelSetupQuestion(
			channel.Name, session, s.setupRepositoryChoices(),
		)
	}
	if err := s.showConfigurationCard(ctx, session, responseThreadTS, message); err != nil {
		return err
	}
	return s.finishSlackInput(ctx, input)
}

func (s *Service) postConfigurationMessage(
	ctx context.Context,
	deliveryID string,
	channelID string,
	threadTS string,
	message slackui.Message,
) (string, error) {
	message = s.sanitizeMessage(message)
	messageTS, err := s.slack.Post(ctx, deliveryID, channelID, threadTS, message)
	if err == nil {
		return messageTS, nil
	}
	recovered, recoveryErr := s.slack.FindDeliveryMessage(
		ctx, channelID, threadTS, deliveryID,
	)
	if recoveryErr == nil && recovered != "" {
		return recovered, nil
	}
	return "", err
}

// configurationCardDeliveryID names the one card a setup session owns.
//
// It is stable for the life of the session, and that is the whole point. When a
// post succeeds and the write recording its timestamp does not, the card is
// still in the channel carrying this name, so the next step finds it. The name
// used to carry the step and the revision, which made every orphan unfindable
// and left posting a second card as the only thing the code could do.
func configurationCardDeliveryID(sessionID string) string {
	return "channel_setup_card_" + sessionID
}

// configurationCardIsHere reports whether the session's card is already in the
// conversation the operator is speaking in, so the next step can edit it.
//
// Replying in a thread rooted at the card is not a move. The card is the first
// message of that thread, sitting directly above the reply, so editing it puts
// the next question exactly where the operator is looking — which is why the
// card's own timestamp counts as a location as much as the thread it lives in.
func configurationCardIsHere(session core.ConfigurationSession, threadTS string) bool {
	return session.CardTS != "" &&
		(threadTS == session.ResponseThreadTS || threadTS == session.CardTS)
}

// placeConfigurationCard puts a setup message in front of the operator as the
// one card the session owns, and reports whether that card's location is new
// and so has to be written down.
//
// Editing is the normal path. Posting happens three ways and no others: the
// opening card, a card the operator has walked away from, and a card whose
// timestamp was lost between the post and the write that records it. The last
// one searches for the orphan first, because a session with no recorded card is
// not the same thing as a channel with no card in it.
//
// A recovery that finds nothing posts. That is the honest outcome: either the
// post never landed, or it landed somewhere this search cannot see — the
// operator moved conversations in the same breath, and Slack's history for the
// conversation they are in now does not contain a message posted in the one they
// left. The session then owns the new card and the orphan stays where it is,
// carrying a superseded session's buttons that every staleness check refuses.
func (s *Service) placeConfigurationCard(
	ctx context.Context,
	session core.ConfigurationSession,
	threadTS string,
	message slackui.Message,
) (string, bool, error) {
	if configurationCardIsHere(session, threadTS) {
		return session.CardTS, false, s.slack.Update(
			ctx, session.ChannelID, session.CardTS, s.sanitizeMessage(message),
		)
	}
	deliveryID := configurationCardDeliveryID(session.ID)
	if session.CardTS != "" {
		// Following the operator costs a second message whatever we do. What it
		// must not cost is a second set of live buttons, so the card being left
		// behind loses its question before the new one exists.
		if err := s.slack.Update(
			ctx, session.ChannelID, session.CardTS,
			s.sanitizeMessage(slackui.ChannelSetupMoved(threadTS != "")),
		); err != nil {
			return "", false, err
		}
	} else if recovered, err := s.slack.FindDeliveryMessage(
		ctx, session.ChannelID, threadTS, deliveryID,
	); err == nil && recovered != "" {
		return recovered, true, s.slack.Update(
			ctx, session.ChannelID, recovered, s.sanitizeMessage(message),
		)
	}
	card, err := s.postConfigurationMessage(
		ctx, deliveryID, session.ChannelID, threadTS, message,
	)
	if err != nil {
		return "", false, err
	}
	return card, true, nil
}

// showConfigurationCard renders the next step of a live session onto its card.
func (s *Service) showConfigurationCard(
	ctx context.Context,
	session core.ConfigurationSession,
	threadTS string,
	message slackui.Message,
) error {
	card, relocated, err := s.placeConfigurationCard(ctx, session, threadTS, message)
	if err != nil || !relocated {
		return err
	}
	return s.store.RecordConfigurationMessage(ctx, session.ID, card, threadTS)
}

// closeConfigurationCard ends the card as the record of what happened.
//
// Saved and cancelled cards carry no actions, so the question stops being
// clickable the moment it stops being true. Nothing is written down: the session
// is already terminal, RecordConfigurationMessage only writes to one that is
// still asking or confirming, and no later step will read a location again.
func (s *Service) closeConfigurationCard(
	ctx context.Context,
	session core.ConfigurationSession,
	threadTS string,
	message slackui.Message,
) error {
	_, _, err := s.placeConfigurationCard(ctx, session, threadTS, message)
	return err
}

func (s *Service) repositoryKeys() []string {
	return s.cfg.RepositoryContextKeys()
}

func (s *Service) setupRepositoryChoices() []slackui.RepositoryChoice {
	choices := make([]slackui.RepositoryChoice, 0,
		len(s.cfg.Repositories)+len(s.cfg.RepositorySets))
	for key, set := range s.cfg.RepositorySets {
		primary := s.cfg.Repositories[set.Primary]
		choices = append(choices, slackui.RepositoryChoice{
			Key: key, DisplayName: set.DisplayName,
			PrimaryDisplayName: primary.DisplayName,
			Set:                true, Default: key == s.cfg.Slack.DefaultRepository,
		})
	}
	for key, repository := range s.cfg.Repositories {
		choices = append(choices, slackui.RepositoryChoice{
			Key: key, DisplayName: repository.DisplayName,
			Default: key == s.cfg.Slack.DefaultRepository,
		})
	}
	return choices
}

func (s *Service) repositoryChoice(key string) slackui.RepositoryChoice {
	for _, choice := range s.setupRepositoryChoices() {
		if choice.Key == key {
			return choice
		}
	}
	return slackui.RepositoryChoice{Key: key, DisplayName: key}
}

func (s *Service) resolveConfigurationRepository(value string) (string, bool) {
	if value == "default" || value == "deployment default" {
		return s.cfg.Slack.DefaultRepository, true
	}
	for _, key := range s.cfg.RepositoryContextKeys() {
		repository, _ := s.cfg.RepositoryContext(key)
		if strings.EqualFold(value, key) ||
			(repository.DisplayName != "" && strings.EqualFold(value, repository.DisplayName)) {
			return key, true
		}
	}
	return "", false
}

func (s *Service) channelAlertPolicy(ctx context.Context, channelID string) (string, error) {
	configuration, err := s.store.GetChannelConfiguration(ctx, channelID)
	if errors.Is(err, store.ErrNotFound) {
		return defaultAlertPolicy, nil
	}
	return configuration.AlertPolicy, err
}

func (s *Service) configuredIncidentInviteUsers(
	ctx context.Context,
	originChannelID string,
) ([]string, error) {
	users := append([]string(nil), s.inviteUsers()...)
	configuration, err := s.store.GetChannelConfiguration(ctx, originChannelID)
	if errors.Is(err, store.ErrNotFound) || originChannelID == "" {
		return channelsetup.UniqueSorted(users), nil
	}
	if err != nil {
		return nil, err
	}
	users = append(users, configuration.InviteUsers...)
	for _, group := range configuration.InviteUserGroups {
		members, err := s.slack.UserGroupMembers(ctx, group, s.cfg.Slack.TeamID)
		if err != nil {
			return nil, fmt.Errorf("expand configured incident user group %s: %w", group, err)
		}
		if err := s.validateUserGroupMembers(ctx, group, members); err != nil {
			return nil, err
		}
		users = append(users, members...)
	}
	return channelsetup.UniqueSorted(users), nil
}

func (s *Service) validateUserGroupMembers(
	ctx context.Context,
	groupID string,
	members []string,
) error {
	if len(members) == 0 {
		return fmt.Errorf("Slack user group %s has no active members", groupID)
	}
	for _, member := range members {
		allowed, err := s.slack.UserAllowed(ctx, member, s.cfg.Slack.TeamID)
		if err != nil {
			return fmt.Errorf("validate member %s of Slack user group %s: %w", member, groupID, err)
		}
		if !allowed {
			return fmt.Errorf(
				"Slack user group %s includes %s, which is not an active full workspace member",
				groupID, member,
			)
		}
	}
	return nil
}
