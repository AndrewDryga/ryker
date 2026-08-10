package service

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const proactiveSettingName = "proactive"
const shadowSettingName = "shadow"
const turnLimitSettingName = "turn_limit"
const incidentPageSize = 8

type proactiveStatus struct {
	Enabled           bool
	EffectiveSource   string
	ChannelOverride   string
	GlobalOverride    string
	ConfiguredDefault string
	ConfigDefault     bool
}

type shadowStatus struct {
	Enabled           bool
	EffectiveSource   string
	ChannelOverride   string
	GlobalOverride    string
	ConfiguredDefault string
	ConfigDefault     bool
}

type turnLimitStatus struct {
	Limit           int
	EffectiveSource string
	ChannelOverride string
	GlobalOverride  string
	ConfigDefault   int
}

func (s *Service) proactiveEnabled(ctx context.Context, channelID string) (bool, error) {
	status, err := s.proactiveStatus(ctx, channelID)
	return status.Enabled, err
}

func (s *Service) shadowEnabled(ctx context.Context, channelID string) (bool, error) {
	status, err := s.shadowStatus(ctx, channelID)
	return status.Enabled, err
}

func (s *Service) shadowStatus(
	ctx context.Context,
	channelID string,
) (shadowStatus, error) {
	status := shadowStatus{
		ChannelOverride:   "inherit",
		GlobalOverride:    "inherit",
		ConfiguredDefault: "inherit",
		ConfigDefault:     s.cfg.IsShadowChannel(channelID),
	}
	channel, err := s.store.GetSlackSetting(ctx, "channel", channelID, shadowSettingName)
	if err == nil {
		status.ChannelOverride = channel.Value
	} else if !errors.Is(err, store.ErrNotFound) {
		return shadowStatus{}, err
	}
	global, err := s.store.GetSlackSetting(ctx, "global", "", shadowSettingName)
	if err == nil {
		status.GlobalOverride = global.Value
	} else if !errors.Is(err, store.ErrNotFound) {
		return shadowStatus{}, err
	}
	if configured, configuredErr := s.store.GetChannelConfiguration(ctx, channelID); configuredErr == nil {
		status.ConfiguredDefault = "off"
		if configured.Participation == "shadow" {
			status.ConfiguredDefault = "on"
		}
	} else if !errors.Is(configuredErr, store.ErrNotFound) {
		return shadowStatus{}, configuredErr
	}
	err = nil
	switch {
	case status.ChannelOverride != "inherit":
		status.Enabled, err = parseOnOff(status.ChannelOverride)
		status.EffectiveSource = "channel override"
	case status.ConfiguredDefault != "inherit":
		status.Enabled, err = parseOnOff(status.ConfiguredDefault)
		status.EffectiveSource = "channel setup"
	case status.GlobalOverride != "inherit":
		status.Enabled, err = parseOnOff(status.GlobalOverride)
		status.EffectiveSource = "workspace override"
	default:
		status.Enabled = status.ConfigDefault
		status.EffectiveSource = "deployment configuration"
	}
	return status, err
}

func (s *Service) proactiveStatus(
	ctx context.Context,
	channelID string,
) (proactiveStatus, error) {
	status := proactiveStatus{
		ChannelOverride:   "inherit",
		GlobalOverride:    "inherit",
		ConfiguredDefault: "inherit",
		ConfigDefault:     s.cfg.IsWatchChannel(channelID),
	}
	channel, err := s.store.GetSlackSetting(
		ctx, "channel", channelID, proactiveSettingName,
	)
	if err == nil {
		status.ChannelOverride = channel.Value
	} else if !errors.Is(err, store.ErrNotFound) {
		return proactiveStatus{}, err
	}
	global, err := s.store.GetSlackSetting(
		ctx, "global", "", proactiveSettingName,
	)
	if err == nil {
		status.GlobalOverride = global.Value
	} else if !errors.Is(err, store.ErrNotFound) {
		return proactiveStatus{}, err
	}
	if status.ChannelOverride != "inherit" {
		status.Enabled, err = parseOnOff(status.ChannelOverride)
		status.EffectiveSource = "channel override"
		return status, err
	}
	if configured, configuredErr := s.store.GetChannelConfiguration(ctx, channelID); configuredErr == nil {
		status.ConfiguredDefault = "off"
		if configured.Participation == "proactive" ||
			configured.Participation == "shadow" {
			status.ConfiguredDefault = "on"
		}
	} else if !errors.Is(configuredErr, store.ErrNotFound) {
		return proactiveStatus{}, configuredErr
	}
	if status.ConfiguredDefault != "inherit" {
		status.Enabled, err = parseOnOff(status.ConfiguredDefault)
		status.EffectiveSource = "channel setup"
		return status, err
	}
	if status.GlobalOverride != "inherit" {
		status.Enabled, err = parseOnOff(status.GlobalOverride)
		status.EffectiveSource = "workspace override"
		return status, err
	}
	status.Enabled = status.ConfigDefault
	status.EffectiveSource = "responder.yaml"
	return status, nil
}

func parseOnOff(value string) (bool, error) {
	switch value {
	case "on":
		return true, nil
	case "off":
		return false, nil
	default:
		return false, fmt.Errorf("invalid proactive setting %q", value)
	}
}

func (s *Service) effectiveTurnLimit(ctx context.Context, channelID string) (int, error) {
	status, err := s.turnLimitStatus(ctx, channelID)
	return status.Limit, err
}

func (s *Service) turnLimitStatus(
	ctx context.Context,
	channelID string,
) (turnLimitStatus, error) {
	status := turnLimitStatus{
		EffectiveSource: "responder.yaml",
		ConfigDefault:   s.cfg.Coop.TurnLimit,
	}
	channel, err := s.store.GetSlackSetting(
		ctx, "channel", channelID, turnLimitSettingName,
	)
	if err == nil {
		status.ChannelOverride = channel.Value
	} else if !errors.Is(err, store.ErrNotFound) {
		return turnLimitStatus{}, err
	}
	global, err := s.store.GetSlackSetting(
		ctx, "global", "", turnLimitSettingName,
	)
	if err == nil {
		status.GlobalOverride = global.Value
	} else if !errors.Is(err, store.ErrNotFound) {
		return turnLimitStatus{}, err
	}
	err = nil
	switch {
	case status.ChannelOverride != "":
		status.Limit, err = parseTurnLimit(status.ChannelOverride)
		status.EffectiveSource = "channel override"
	case status.GlobalOverride != "":
		status.Limit, err = parseTurnLimit(status.GlobalOverride)
		status.EffectiveSource = "workspace override"
	default:
		status.Limit = status.ConfigDefault
	}
	return status, err
}

func parseTurnLimit(value string) (int, error) {
	limit, err := strconv.Atoi(value)
	if err != nil || limit < 100 || limit > 10000 {
		return 0, errors.New("turn limit must be between 100 and 10000")
	}
	return limit, nil
}

func (s *Service) processSlashInput(ctx context.Context, input core.SlackInput) error {
	fields := strings.Fields(strings.ToLower(strings.TrimSpace(input.Text)))
	if len(fields) > 0 && fields[0] == "feedback" && slashArgument(input.Text) != "" {
		allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
		if err != nil {
			return err
		}
		if !allowed {
			return s.refuseSlashInput(
				ctx, input,
				"Only active full members of this Slack workspace can submit feedback.",
			)
		}
		return s.finishSlashFeedback(ctx, input, slashArgument(input.Text))
	}
	if !s.cfg.IsOperator(input.UserID) {
		return s.refuseSlashInput(
			ctx, input,
			"*You cannot run Responder commands yet.*\n\n"+
				"Your Slack account is not listed in `slack.operators`. An administrator must "+
				"add your Slack user ID to that setting and restart Responder. Commands can "+
				"change incident state and workspace listening behavior, so ordinary channel "+
				"members cannot run them.",
		)
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		return s.refuseSlashInput(
			ctx, input,
			"*This Slack account cannot run Responder commands.*\n\n"+
				"Commands require an active, full member of Responder's configured workspace. "+
				"Guest, bot, deactivated, and external Slack Connect accounts are denied even "+
				"when their user ID appears in `slack.operators`.",
		)
	}
	if len(fields) == 0 || fields[0] == "help" {
		return s.finishSlashMessage(ctx, input, slashHelpMessage())
	}
	switch fields[0] {
	case "status", "settings", "config":
		if len(fields) != 1 {
			return s.refuseSlashInput(ctx, input, slashUsage("status"))
		}
		return s.finishSlashStatus(ctx, input)
	case "incidents":
		return s.finishSlashIncidents(ctx, input, fields[1:])
	case "work", "commitments":
		if len(fields) != 1 {
			return s.refuseSlashInput(ctx, input, slashUsage("work"))
		}
		return s.finishSlashCommitments(ctx, input)
	case "feedback":
		return s.finishSlashFeedback(ctx, input, slashArgument(input.Text))
	case "memory":
		if len(fields) > 2 || (len(fields) == 2 && fields[1] != "review") {
			return s.refuseSlashInput(ctx, input, slashUsage("memory"))
		}
		if len(fields) == 2 {
			return s.finishMemoryReview(ctx, input)
		}
		return s.finishSlashMemory(ctx, input)
	case "preferences", "preference":
		if len(fields) != 1 {
			return s.refuseSlashInput(ctx, input, slashUsage("preferences"))
		}
		return s.finishSlashPreferences(ctx, input)
	case "rules", "rule":
		if len(fields) != 1 {
			return s.refuseSlashInput(ctx, input, slashUsage("rules"))
		}
		return s.finishSlashRules(ctx, input)
	case "schedules", "schedule", "reminders":
		if len(fields) != 1 {
			return s.refuseSlashInput(ctx, input, slashUsage("schedules"))
		}
		return s.finishSlashSchedules(ctx, input)
	case "proactive", "watch":
		return s.configureProactive(ctx, input, fields[1:])
	case "shadow":
		return s.configureShadow(ctx, input, fields[1:])
	case "turn-limit", "turns":
		return s.configureTurnLimit(ctx, input, fields[1:])
	case "timeline", "evidence", "handoff", "postmortem":
		if len(fields) != 1 {
			return s.refuseSlashInput(ctx, input, slashUsage(fields[0]))
		}
		return s.finishIncidentIntelligence(ctx, input, fields[0])
	case "update", "changes", "review", "publish", "stop", "extend", "close":
		if len(fields) != 1 {
			return s.refuseSlashInput(ctx, input, slashUsage(fields[0]))
		}
		return s.runSlashIncidentControl(ctx, input, fields[0])
	default:
		return s.refuseSlashInput(
			ctx, input,
			fmt.Sprintf("Unknown `/responder` subcommand `%s`.\n\n%s", fields[0], slashHelp()),
		)
	}
}

func (s *Service) finishSlashCommitments(
	ctx context.Context,
	input core.SlackInput,
) error {
	items, err := s.store.ListActiveCommitments(ctx, 20)
	if err != nil {
		return err
	}
	return s.finishSlashMessage(
		ctx,
		input,
		slackui.CommitmentDirectoryMessage(items),
	)
}

func (s *Service) finishSlashMemory(
	ctx context.Context,
	input core.SlackInput,
) error {
	repository, err := s.effectiveRepository(
		ctx, input.ChannelID, input.UserID, s.cfg.Slack.DefaultRepository,
	)
	if err != nil {
		return err
	}
	entries, err := s.store.Memory.ListMemoryForContext(
		ctx,
		s.cfg.Slack.TeamID,
		input.ChannelID,
		repository,
		input.UserID,
		20,
	)
	if err != nil {
		return err
	}
	health, err := s.store.Memory.MemoryHealth(ctx)
	if err != nil {
		return err
	}
	rollups, err := s.store.Memory.ListMemoryRollupsForContext(
		ctx, input.ChannelID, repository, 4,
	)
	if err != nil {
		return err
	}
	return s.finishSlashMessage(
		ctx, input, slackui.MemoryHealthMessage(entries, rollups, health),
	)
}

func (s *Service) finishSlashPreferences(
	ctx context.Context,
	input core.SlackInput,
) error {
	repository, err := s.effectiveRepository(
		ctx, input.ChannelID, input.UserID, s.cfg.Slack.DefaultRepository,
	)
	if err != nil {
		return err
	}
	preferences, err := s.store.Behavior.ListPreferencesForContext(
		ctx,
		s.cfg.Slack.TeamID,
		input.ChannelID,
		repository,
		input.UserID,
		false,
		20,
	)
	if err != nil {
		return err
	}
	return s.finishSlashMessage(
		ctx, input, slackui.PreferenceDirectoryMessage(preferences),
	)
}

func (s *Service) finishSlashRules(
	ctx context.Context,
	input core.SlackInput,
) error {
	rules, err := s.store.Behavior.ListStandingRulesForChannel(
		ctx, input.ChannelID, false, 20,
	)
	if err != nil {
		return err
	}
	return s.finishSlashMessage(ctx, input, slackui.RuleDirectoryMessage(rules))
}

func (s *Service) finishSlashSchedules(
	ctx context.Context,
	input core.SlackInput,
) error {
	tasks, err := s.store.Schedules.ListScheduledTasksForChannel(ctx, input.ChannelID, 20)
	if err != nil {
		return err
	}
	return s.finishSlashMessage(ctx, input, slackui.ScheduleDirectoryMessage(tasks))
}

func (s *Service) finishIncidentIntelligence(
	ctx context.Context,
	input core.SlackInput,
	command string,
) error {
	incident, err := s.store.FindLatestIncidentByChannel(ctx, input.ChannelID)
	if errors.Is(err, store.ErrNotFound) {
		return s.refuseSlashInput(
			ctx, input,
			"*There is no incident attached to this channel.* `timeline`, `evidence`, "+
				"`handoff`, and `postmortem` read the durable record for the latest incident room. Use "+
				"`/responder incidents` to find one.",
		)
	}
	if err != nil {
		return err
	}
	record, err := s.store.LoadRemediationRecord(ctx, incident.ID)
	if err != nil {
		return err
	}
	switch command {
	case "timeline":
		return s.finishSlashMessage(ctx, input, slackui.TimelineMessage(record))
	case "postmortem":
		return s.finishSlashMessage(ctx, input, slackui.PostmortemDraft(record))
	case "evidence", "handoff":
	default:
		return errors.New("unknown incident intelligence command")
	}
	if command == "evidence" {
		return s.finishSlashMessage(
			ctx, input,
			slackui.EvidenceDirectoryMessage(incident, record.Evidence, record.Coverage),
		)
	}
	return s.finishSlashMessage(
		ctx, input, slackui.HandoffMessage(record),
	)
}

func (s *Service) configureShadow(
	ctx context.Context,
	input core.SlackInput,
	args []string,
) error {
	scope := "channel"
	channelID := input.ChannelID
	value := ""
	switch {
	case len(args) == 0:
		enabled, err := s.shadowEnabled(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		state := "off"
		if enabled {
			state = "on"
		}
		return s.finishSlashInput(
			ctx,
			input,
			"*Shadow evaluation is "+state+".*\n\nWhen shadow mode is on, Responder still "+
				"classifies new messages and records evidence and coverage, but it does not post "+
				"a reply, offer an incident, or create one. Use `/responder shadow on|off|inherit` "+
				"for this channel or add `global` before the value for the workspace default.",
		)
	case len(args) == 1:
		value = args[0]
	case len(args) == 2 && args[0] == "global":
		scope = "global"
		channelID = ""
		value = args[1]
	default:
		return s.refuseSlashInput(ctx, input, slashUsage("shadow"))
	}
	if value != "on" && value != "off" && value != "inherit" {
		return s.refuseSlashInput(ctx, input, slashUsage("shadow"))
	}
	if value == "inherit" {
		if err := s.store.DeleteSlackSetting(
			ctx, scope, channelID, shadowSettingName,
		); err != nil {
			return err
		}
	} else if err := s.store.SetSlackSetting(
		ctx, scope, channelID, shadowSettingName, value, input.UserID,
	); err != nil {
		return err
	}
	enabled, err := s.shadowEnabled(ctx, input.ChannelID)
	if err != nil {
		return err
	}
	effective := "off"
	if enabled {
		effective = "on"
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.settings", ActorID: input.UserID,
		ObjectID: scope + ":" + core.FirstNonempty(channelID, "workspace"),
		Outcome:  "updated", Detail: "shadow=" + value,
	})
	return s.finishSlashInput(
		ctx,
		input,
		"*Shadow evaluation updated.*\n\nThe requested "+scope+" value is `"+value+
			"`. Shadow mode is now effectively *"+effective+"* in this channel. When enabled, "+
			"model decisions are retained for evaluation but remain invisible to the channel.",
	)
}

func (s *Service) configureTurnLimit(
	ctx context.Context,
	input core.SlackInput,
	args []string,
) error {
	if len(args) == 0 {
		status, err := s.turnLimitStatus(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		return s.finishSlashMessage(ctx, input, turnLimitStatusMessage(status))
	}
	scope := "channel"
	channelID := input.ChannelID
	value := ""
	switch {
	case len(args) == 1:
		value = args[0]
	case len(args) == 2 && args[0] == "global":
		scope = "global"
		channelID = ""
		value = args[1]
	default:
		return s.refuseSlashInput(ctx, input, slashUsage("turn-limit"))
	}
	if value != "inherit" {
		limit, err := parseTurnLimit(value)
		if err != nil {
			return s.refuseSlashInput(ctx, input, slashUsage("turn-limit"))
		}
		value = strconv.Itoa(limit)
	}
	if value == "inherit" {
		if err := s.store.DeleteSlackSetting(
			ctx, scope, channelID, turnLimitSettingName,
		); err != nil {
			return err
		}
	} else if err := s.store.SetSlackSetting(
		ctx, scope, channelID, turnLimitSettingName, value, input.UserID,
	); err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.settings", ActorID: input.UserID,
		ObjectID: scope + ":" + core.FirstNonempty(channelID, "workspace"),
		Outcome:  "updated", Detail: "turn_limit=" + value,
	})
	status, err := s.turnLimitStatus(ctx, input.ChannelID)
	if err != nil {
		return err
	}
	if err := s.resumeTurnLimitBlockedIncidents(ctx, scope, channelID); err != nil {
		return err
	}
	return s.finishSlashMessage(
		ctx, input, turnLimitChangeMessage(scope, value, status),
	)
}

func slashTextForCommandAction(input core.SlackInput) (string, bool) {
	switch {
	case input.ActionID == slackui.ActionCommandStatus && input.ActionValue == "status":
		return "status", true
	case input.ActionID == slackui.ActionCommandOpenIncidents && input.ActionValue == "open":
		return "incidents open", true
	case input.ActionID == slackui.ActionCommandAllIncidents && input.ActionValue == "all":
		return "incidents all", true
	case input.ActionID == slackui.ActionCommandPreviousIncidents ||
		input.ActionID == slackui.ActionCommandNextIncidents:
		fields := strings.Split(input.ActionValue, ":")
		if len(fields) != 2 || (fields[0] != "open" && fields[0] != "all") {
			return "", false
		}
		page, err := strconv.Atoi(fields[1])
		if err != nil || page < 1 {
			return "", false
		}
		return fmt.Sprintf("incidents %s %d", fields[0], page), true
	default:
		return "", false
	}
}

func (s *Service) configureProactive(
	ctx context.Context,
	input core.SlackInput,
	args []string,
) error {
	scope := "channel"
	channelID := input.ChannelID
	value := ""
	switch {
	case len(args) == 1:
		value = args[0]
	case len(args) == 2 && args[0] == "global":
		scope = "global"
		channelID = ""
		value = args[1]
	default:
		return s.refuseSlashInput(ctx, input, slashUsage("proactive"))
	}
	if value != "on" && value != "off" && value != "inherit" {
		return s.refuseSlashInput(ctx, input, slashUsage("proactive"))
	}
	if scope == "channel" && value == "on" {
		channel, err := s.slack.GetChannel(ctx, input.ChannelID)
		if err != nil {
			return err
		}
		if !channel.Member {
			return s.refuseSlashInput(
				ctx, input,
				"*Responder cannot listen to this channel yet.*\n\n"+
					"Invite `@Emisar` to this channel so Slack will deliver its messages, "+
					"then run `/responder proactive on` again. No setting was changed.",
			)
		}
	}
	if value == "inherit" {
		if err := s.store.DeleteSlackSetting(
			ctx, scope, channelID, proactiveSettingName,
		); err != nil {
			return err
		}
	} else if err := s.store.SetSlackSetting(
		ctx, scope, channelID, proactiveSettingName, value, input.UserID,
	); err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.settings", ActorID: input.UserID,
		ObjectID: scope + ":" + core.FirstNonempty(channelID, "workspace"),
		Outcome:  "updated", Detail: "proactive=" + value,
	})
	status, err := s.proactiveStatus(ctx, input.ChannelID)
	if err != nil {
		return err
	}
	return s.finishSlashMessage(
		ctx, input, proactiveChangeMessage(scope, value, status),
	)
}

func (s *Service) finishSlashIncidents(
	ctx context.Context,
	input core.SlackInput,
	args []string,
) error {
	openOnly, page, ok := parseIncidentListArgs(args)
	if !ok {
		return s.refuseSlashInput(ctx, input, slashUsage("incidents"))
	}
	incidents, total, err := s.store.ListIncidentPage(
		ctx,
		openOnly,
		incidentPageSize,
		(page-1)*incidentPageSize,
	)
	if err != nil {
		return err
	}
	return s.finishSlashMessage(
		ctx,
		input,
		incidentDirectoryMessage(
			incidents, total, page, openOnly,
		),
	)
}

func (s *Service) finishSlashStatus(ctx context.Context, input core.SlackInput) error {
	status, err := s.proactiveStatus(ctx, input.ChannelID)
	if err != nil {
		return err
	}
	shadow, err := s.shadowStatus(ctx, input.ChannelID)
	if err != nil {
		return err
	}
	var incident *core.Incident
	if storedIncident, err := s.store.FindIncidentByChannel(ctx, input.ChannelID); err == nil {
		incident = &storedIncident
	} else if !errors.Is(err, store.ErrNotFound) {
		return err
	}
	repository, err := s.effectiveRepository(
		ctx, input.ChannelID, input.UserID, s.cfg.Slack.DefaultRepository,
	)
	if err != nil {
		return err
	}
	preferences, err := s.store.Behavior.ListPreferencesForContext(
		ctx,
		s.cfg.Slack.TeamID,
		input.ChannelID,
		repository,
		input.UserID,
		true,
		100,
	)
	if err != nil {
		return err
	}
	rules, err := s.store.Behavior.ListStandingRulesForChannel(
		ctx, input.ChannelID, true, 100,
	)
	if err != nil {
		return err
	}
	message := slashStatusMessage(
		status,
		shadow,
		s.cfg.IsSummonChannel(input.ChannelID),
		repository,
		len(preferences),
		len(rules),
		incident,
	)
	if configured, configuredErr := s.store.GetChannelConfiguration(
		ctx, input.ChannelID,
	); configuredErr == nil {
		audience := "configured operators"
		if len(configured.InviteUsers) > 0 {
			audience += fmt.Sprintf(" plus %d selected member(s)", len(configured.InviteUsers))
		}
		if len(configured.InviteUserGroups) > 0 {
			audience += fmt.Sprintf(
				" and %d Slack user group(s)",
				len(configured.InviteUserGroups),
			)
		}
		message.Sections = append(
			[]string{
				fmt.Sprintf(
					"*Confirmed channel setup*\nParticipation: *%s*. App alerts: *%s*. "+
						"New incident audience: %s. Repository: `%s`.",
					configured.Participation,
					configured.AlertPolicy,
					audience,
					configured.Repository,
				),
			},
			message.Sections...,
		)
	} else if !errors.Is(configuredErr, store.ErrNotFound) {
		return configuredErr
	}
	if input.Kind == "conversation_command" {
		message.Context = []string{
			"This is the effective channel configuration. Setting changes are durable and audited.",
		}
	}
	return s.finishSlashMessage(ctx, input, message)
}

func (s *Service) runSlashIncidentControl(
	ctx context.Context,
	input core.SlackInput,
	command string,
) error {
	incident, err := s.store.FindIncidentByChannel(ctx, input.ChannelID)
	if errors.Is(err, store.ErrNotFound) {
		return s.refuseSlashInput(
			ctx, input,
			"*There is no incident to control in this channel.*\n\n"+
				"`update`, `changes`, `review`, `publish`, `stop`, and `close` operate on the "+
				"incident attached to the current channel. To create one, explicitly ask "+
				"`@Emisar open an incident for <summary>` in a mention-enabled channel. "+
				"Use `/responder status` there to check how mentions are handled.",
		)
	}
	if err != nil {
		return err
	}
	control := map[string]string{
		"update":  slackui.ActionUpdate,
		"changes": slackui.ActionChanges,
		"review":  slackui.ActionReview,
		"publish": slackui.ActionPublishPR,
		"stop":    slackui.ActionStop,
		"extend":  slackui.ActionExtend,
		"close":   slackui.ActionResolve,
	}[command]
	if err := s.handleControl(ctx, input, incident, control); err != nil {
		// A refused control already answered this operator, and the receipt
		// below would contradict it: "this command will cancel the active agent
		// turn" reads as confirmation of work that was just declined.
		if errors.Is(err, errControlRefused) {
			return s.finishSlackInput(ctx, input)
		}
		return err
	}
	return s.finishSlashInput(
		ctx,
		input,
		slashControlReceipt(command, slackui.ShortID(incident.ID)),
	)
}

// refuseSlashInput turns a command down to the person who ran it.
//
// The permission refusals it was written for name one Slack account and nothing
// else: you are not in `slack.operators`, this account is a guest or a bot, only
// full members may leave feedback. Nobody else in the room can add anyone to
// that setting, so nobody else can act on reading it.
//
// A real slash command already refuses privately, because Slack makes those
// answers private and finishSlashMessage follows. The same refusal typed as
// "@Emisar status" arrives as a conversation_command, and that branch posts to
// the channel — so the identical sentence about the identical person became a
// public callout depending only on which spelling they used, once per attempt.
// The rule was already the private one; this makes it survive both spellings.
//
// Every other refusal on this path now comes through here too: mistyped usage,
// an unknown subcommand, no incident attached to this channel, a channel the
// bot has not been invited to. The line is whether the message carries the
// thing that was asked for. An answer does — status, help, the incident
// directory, a timeline — and stays public, because it was asked in the open.
// A refusal carries only "no", addressed to one person, and typing
// "@Emisar frobnicate" should not put a usage message in front of a room.
func (s *Service) refuseSlashInput(
	ctx context.Context,
	input core.SlackInput,
	text string,
) error {
	if input.Kind != "conversation_command" ||
		input.ChannelID == "" || input.UserID == "" {
		return s.finishSlashInput(ctx, input, text)
	}
	if err := s.slack.PostEphemeral(
		ctx, input.ChannelID, input.UserID, s.sanitizeMessage(slackui.Notice(text)),
	); err != nil {
		return s.retrySlackInput(ctx, input, err)
	}
	return s.store.FinishSlackInput(ctx, input.ID)
}

func (s *Service) finishSlashInput(
	ctx context.Context,
	input core.SlackInput,
	text string,
) error {
	return s.finishSlashMessage(ctx, input, slackui.Notice(text))
}

func (s *Service) finishSlashMessage(
	ctx context.Context,
	input core.SlackInput,
	message slackui.Message,
) error {
	message = s.sanitizeMessage(message)
	if input.Kind == "conversation_command" {
		if err := s.postInputMessage(
			ctx, "conversation_command_"+input.ID, input, message,
		); err != nil {
			return err
		}
		return s.store.FinishSlackInput(ctx, input.ID)
	}
	// An App Home interaction has no channel — its container is a view, so
	// Slack sends neither container.channel_id nor channel.id — and an
	// ephemeral message has nowhere to go without one. Repainting the App Home
	// is the surface that click came from, so the reply lands where the person
	// is looking instead of being addressed to the empty string and rejected.
	if strings.TrimSpace(input.ChannelID) == "" {
		s.log.Warn(
			"Slack interaction has no channel to reply in; repainting the App Home instead",
			"input", input.ID,
			"kind", input.Kind,
			"action", input.ActionID,
			"user", input.UserID,
		)
		if input.UserID == "" {
			return s.finishSlackInput(ctx, input)
		}
		if err := s.publishOperationsHome(ctx, input.UserID); err != nil {
			return s.retrySlackInput(ctx, input, err)
		}
		return s.store.FinishSlackInput(ctx, input.ID)
	}
	if err := s.slack.PostEphemeral(ctx, input.ChannelID, input.UserID, message); err != nil {
		s.log.Warn(
			"post Slack slash command result",
			"channel", input.ChannelID,
			"user", input.UserID,
			"error", err,
		)
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.command.feedback", ActorID: input.UserID,
			ObjectID: input.ID, Outcome: "failed", Detail: trimError(err),
		})
		return s.retrySlackInput(ctx, input, err)
	}
	return s.store.FinishSlackInput(ctx, input.ID)
}

func slashHelp() string {
	return strings.Join(slashHelpSections(), "\n\n")
}

func slashHelpSections() []string {
	return []string{
		"*Find work*\n" +
			"`/responder status` - explain Responder's behavior in this channel\n" +
			"`/responder work` - show what Emisar owes the team\n" +
			"`/responder incidents` - show open incidents and engineering tasks\n" +
			"`/responder incidents all [page]` - include closed work history\n" +
			"`/responder memory` - inspect saved memory and consolidation health\n" +
			"`/responder memory review` - review stale or redundant saved memory\n" +
			"`/responder preferences` - manage investigation and response defaults\n" +
			"`/responder rules` - manage typed read-only channel automations\n" +
			"`/responder schedules` - manage recurring and one-time tasks in this channel",
		"*Improve Responder*\n" +
			"`/responder feedback <what should change>` - save feedback with nearby conversation context\n" +
			"`/responder feedback` - list the 20 newest open feedback items",
		"*Control listening*\n" +
			"`/responder proactive on|off|inherit` - change this channel\n" +
			"`/responder proactive global on|off|inherit` - change the workspace default\n" +
			"`/responder shadow on|off|inherit` - evaluate without posting or opening incidents\n" +
			"`inherit` removes the Slack override and follows the next configured default.",
		"*Automatic work capacity*\n" +
			"`/responder turn-limit` - explain this channel's safety ceiling\n" +
			"`/responder turn-limit 100..10000|inherit` - change this channel\n" +
			"`/responder turn-limit global 100..10000|inherit` - change the workspace default\n" +
			"Responder extends sessions automatically; operators never estimate turns for a task.",
		"*Control active work*\n" +
			"`/responder timeline` reads the durable event history; `/responder evidence` shows " +
			"cited observations and coverage; `/responder handoff` prepares a current shift " +
			"summary; `/responder postmortem` generates the current evidence-grounded draft. " +
			"`/responder update` starts an evidence-based agent update; " +
			"`/responder changes` reads the isolated diff; `/responder review` compares a proposed " +
			"change with the current repository and runs rebase, validation, and policy checks; " +
			"`/responder stop` preserves and stops the active turn; `/responder close` preserves " +
			"the working copy and closes the session. Incident closure also posts an evidence-grounded postmortem draft.",
		"An explicit repository-change request in shared-channel triage can offer a concise *Start task* button. A configured operator must confirm it before Responder creates a writable isolated fork in that same thread. Incident rooms and attached task threads remain conversational even when proactive triage is off. Slash commands " +
			"run from the channel composer and cannot select a task thread; use that thread's task-card buttons instead.",
	}
}

func slashHelpMessage() slackui.Message {
	return slackui.Message{
		Text:     "Responder command guide. Use status, incidents, proactive settings, or incident controls.",
		Header:   "Responder command guide",
		Sections: slashHelpSections(),
		Actions: []slackui.Action{
			{
				ID: slackui.ActionCommandStatus, Label: "Status here",
				Value: "status", Style: "primary",
			},
			{
				ID: slackui.ActionCommandOpenIncidents, Label: "Open incidents",
				Value: "open",
			},
			{
				ID: slackui.ActionCommandAllIncidents, Label: "All incidents",
				Value: "all",
			},
		},
		Context: []string{
			"These buttons are read-only. Configuration and lifecycle commands require explicit text or pinned-card confirmation.",
		},
	}
}

func slashUsage(command string) string {
	switch command {
	case "work":
		return "*Inspect unfinished Emisar commitments.*\n\n" +
			"`/responder work` shows queued, active, finishing, and blocked agent work. " +
			"Each item identifies its originating channel, current state, and next action."
	case "feedback":
		return "*Send product feedback with useful context.*\n\n" +
			"`/responder feedback <what should change>` saves your suggestion with a bounded copy " +
			"of the nearby Slack conversation. `/responder feedback` lists open feedback."
	case "incidents":
		return "*Browse the incident directory.*\n\n" +
			"`/responder incidents` lists currently open incidents. " +
			"`/responder incidents open [page]` selects another open-incident page. " +
			"`/responder incidents all [page]` includes closed history. Pages start at 1, and " +
			"each incident includes a clickable Slack channel link when its room is ready."
	case "timeline", "evidence", "handoff", "postmortem":
		return "*Read the current incident record.*\n\n" +
			"`/responder timeline` shows alert, agent-run, approval, action, and publication history. " +
			"`/responder evidence` shows cited observations and coverage gaps. " +
			"`/responder handoff` prepares a concise shift summary. " +
			"`/responder postmortem` generates an evidence-grounded draft from recorded actions."
	case "memory":
		return "*Inspect operational memory visible here.*\n\n" +
			"`/responder memory` lists active operator-confirmed hints matching this channel, " +
			"its configured repository, workspace visibility, or your operator visibility. " +
			"It also reports conversation-summary and continuity-rollup health. " +
			"`/responder memory review` opens one stale or duplicate review at a time; Responder " +
			"does not rewrite confirmed memory automatically. Each entry has an explicit forget " +
			"control. Saved memory never establishes current " +
			"health or authorizes a change; live evidence and current repository state win."
	case "preferences":
		return "*Manage durable Responder preferences.*\n\n" +
			"`/responder preferences` lists enabled and disabled preferences that match this " +
			"operator, channel, repository, or workspace. Use the buttons to enable, disable, " +
			"replace, or permanently delete them.\n\n" +
			"Preferences change investigation depth or presentation only. Ask Responder in " +
			"natural language for a lasting behavior; it will show the exact normalized value, " +
			"scope, and expiry before saving."
	case "rules":
		return "*Manage standing rules for this channel.*\n\n" +
			"`/responder rules` lists typed read-only subscriptions and their run counts. Use " +
			"the buttons to enable, disable, replace, or permanently delete them.\n\n" +
			"An enabled rule can read only its matching messages even when broad proactive " +
			"triage is off. It replies in the source thread and cannot create incidents, edit " +
			"files, deploy, approve, or mutate infrastructure."
	case "schedules":
		return "*Manage scheduled tasks for this channel.*\n\n" +
			"`/responder schedules` lists one-time and recurring tasks with run-now, pause, " +
			"replace, and delete controls. Create one conversationally, for example: " +
			"`@Emisar every Monday at 09:00 UTC, summarize production health`.\n\n" +
			"Nothing is saved until a configured operator confirms the normalized schedule. " +
			"Every occurrence rechecks current Coop, repository, tool, and Emisar policy."
	case "proactive":
		return "*Choose what Responder should read.*\n\n" +
			"`/responder proactive on|off|inherit` changes only this channel. " +
			"`/responder proactive global on|off|inherit` changes the workspace default.\n\n" +
			"`on` reads and triages new messages, `off` ignores ordinary messages, and " +
			"`inherit` removes that Slack override so the next default applies. Use " +
			"`/responder status` to preview the current effective behavior."
	case "turn-limit":
		return "*Set an automatic session safety ceiling.*\n\n" +
			"`/responder turn-limit` shows the effective value for this channel. " +
			"`/responder turn-limit 1000` changes only this channel. " +
			"`/responder turn-limit global 1000` changes the workspace default. " +
			"Use a value between `100` and `10000`, or use `inherit` instead of a number " +
			"to remove that override.\n\n" +
			"The value is the maximum number of accepted agent requests over a session's " +
			"lifetime. It does not limit tool calls or investigation steps inside one request. " +
			"Responder allocates capacity automatically until this ceiling."
	case "shadow":
		return "*Evaluate Responder without channel output.*\n\n" +
			"`/responder shadow on|off|inherit` changes this channel. " +
			"`/responder shadow global on|off|inherit` changes the workspace default. " +
			"Shadow mode still runs read-only classification and records its decision, evidence, " +
			"and coverage, but it never posts, offers, or creates an incident."
	default:
		return "Run `/responder " + command + "` without additional text. Use " +
			"`/responder help` to see what this command does before running it."
	}
}

func slashArgument(text string) string {
	text = strings.TrimSpace(text)
	if index := strings.IndexAny(text, " \t\r\n"); index >= 0 {
		return strings.TrimSpace(text[index+1:])
	}
	return ""
}

func parseIncidentListArgs(args []string) (bool, int, bool) {
	openOnly := true
	page := 1
	if len(args) == 0 {
		return openOnly, page, true
	}
	if len(args) > 2 || (args[0] != "open" && args[0] != "all") {
		return false, 0, false
	}
	openOnly = args[0] == "open"
	if len(args) == 2 {
		parsed, err := strconv.Atoi(args[1])
		if err != nil || parsed < 1 {
			return false, 0, false
		}
		page = parsed
	}
	return openOnly, page, true
}

func incidentDirectoryMessage(
	incidents []core.Incident,
	total int,
	page int,
	openOnly bool,
) slackui.Message {
	scope := "open"
	if !openOnly {
		scope = "all"
	}
	if total == 0 {
		if openOnly {
			return slackui.Message{
				Text:   "There are no open incidents.",
				Header: "No open incidents",
				Sections: []string{
					"Responder has no active, recovery-monitoring, or resolved-but-not-closed " +
						"incidents. Use `/responder incidents all` to browse closed history.",
				},
				Context: []string{"Only you can see this incident directory."},
			}
		}
		return slackui.Message{
			Text:   "Responder has not recorded any incidents.",
			Header: "No incidents recorded",
			Sections: []string{
				"The incident database is empty. New alert-driven or Slack-created incidents " +
					"will appear here after Responder accepts them.",
			},
			Context: []string{"Only you can see this incident directory."},
		}
	}
	pageCount := (total + incidentPageSize - 1) / incidentPageSize
	if page > pageCount {
		return slackui.Message{
			Text: fmt.Sprintf(
				"Incident page %d does not exist. There are %d pages.",
				page, pageCount,
			),
			Header: "Incident page not found",
			Sections: []string{
				fmt.Sprintf(
					"`/responder incidents %s %d` opens the last available page.",
					scope, pageCount,
				),
			},
			Context: []string{"No incident state was changed."},
		}
	}
	first := (page-1)*incidentPageSize + 1
	last := first + len(incidents) - 1
	header := fmt.Sprintf(
		"%s incidents (%d)",
		upperFirst(scope),
		total,
	)
	if pageCount > 1 {
		header += fmt.Sprintf(" - page %d of %d", page, pageCount)
	}
	message := slackui.Message{
		Text: fmt.Sprintf(
			"Showing %d-%d of %d %s incidents.",
			first, last, total, scope,
		),
		Header: header,
		Context: []string{
			"Newest first. Only you can see this directory.",
		},
	}
	for _, incident := range incidents {
		message.Sections = append(
			message.Sections,
			incidentDirectoryEntry(incident),
		)
	}
	if page > 1 {
		message.Actions = append(message.Actions, slackui.Action{
			ID: slackui.ActionCommandPreviousIncidents, Label: "Previous page",
			Value: fmt.Sprintf("%s:%d", scope, page-1),
		})
	}
	if page < pageCount {
		message.Actions = append(message.Actions, slackui.Action{
			ID: slackui.ActionCommandNextIncidents, Label: "Next page",
			Value: fmt.Sprintf("%s:%d", scope, page+1),
		})
	}
	if openOnly {
		message.Actions = append(message.Actions, slackui.Action{
			ID: slackui.ActionCommandAllIncidents, Label: "Closed history", Value: "all",
		})
	} else {
		message.Actions = append(message.Actions, slackui.Action{
			ID: slackui.ActionCommandOpenIncidents, Label: "Open incidents", Value: "open",
		})
	}
	return message
}

func incidentDirectoryEntry(incident core.Incident) string {
	title := strings.Join(strings.Fields(incident.Title), " ")
	runes := []rune(title)
	if len(runes) > 180 {
		title = string(runes[:177]) + "..."
	}
	fallbackTitle := "Untitled incident"
	channel := "Incident room is being prepared"
	workKind := ""
	if incident.IsEngineeringTask() {
		fallbackTitle = "Untitled engineering task"
		if incident.IsThreadScoped() {
			channel = "Task thread is being prepared"
		} else {
			channel = "Engineering room is being prepared"
		}
		workKind = "`engineering task` | "
	}
	title = escapeSlackDirectoryText(core.FirstNonempty(title, fallbackTitle))
	repository := escapeSlackDirectoryText(incident.Repository)
	if incident.ChannelID != "" {
		switch incident.ChannelState {
		case core.ChannelArchived:
			if incident.IsThreadScoped() {
				channel = "Source Slack channel archived"
			} else {
				channel = "#" + escapeSlackDirectoryText(incident.ChannelName) + " (archived)"
			}
		case core.ChannelDeleted:
			if incident.IsThreadScoped() {
				channel = "Source Slack channel deleted"
			} else {
				channel = "#" + escapeSlackDirectoryText(incident.ChannelName) + " (Slack room deleted)"
			}
		case core.ChannelUnreachable:
			if incident.IsThreadScoped() {
				channel = "Source Slack channel unavailable"
			} else {
				channel = "#" + escapeSlackDirectoryText(incident.ChannelName) + " (room unavailable)"
			}
		default:
			channel = "<#" + incident.ChannelID + ">"
		}
	}
	metadata := fmt.Sprintf(
		"`%s` | `%s` | started %s",
		slackui.ShortID(incident.ID),
		repository,
		incident.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
	)
	if incident.Severity != "" {
		metadata += " | " + escapeSlackDirectoryText(incident.Severity)
	}
	return fmt.Sprintf(
		"*%s*\n%s | %s | %s\n%s",
		title, channel, incidentDirectoryState(incident),
		workKind+incidentSignalSummary(incident), metadata,
	)
}

func incidentDirectoryState(incident core.Incident) string {
	switch incident.Status {
	case core.IncidentMonitoring:
		return "Monitoring recovery"
	case core.IncidentResolved:
		return "Resolved"
	case core.IncidentClosed:
		return "Closed"
	}
	return incidentDirectoryActivity(incident.Workflow)
}

func incidentDirectoryActivity(workflow core.WorkflowState) string {
	switch workflow {
	case core.WorkflowProvisioningChannel:
		return "Creating room"
	case core.WorkflowProvisioningSession:
		return "Preparing workspace"
	case core.WorkflowHolding:
		return "Queued for capacity"
	case core.WorkflowInvestigating:
		return "Investigating"
	case core.WorkflowParked:
		return "Waiting for input"
	case core.WorkflowBlocked:
		return "Needs operator action"
	case core.WorkflowClosed:
		return "Session closed"
	default:
		return "Unknown activity"
	}
}

func incidentSignalSummary(incident core.Incident) string {
	if incident.IsEngineeringTask() {
		return "repository work"
	}
	if incident.FiringCount == 0 {
		return "no alerts firing"
	}
	if incident.SignalCount == 1 {
		return "1 alert firing"
	}
	return fmt.Sprintf(
		"%d of %d alerts firing",
		incident.FiringCount,
		incident.SignalCount,
	)
}

func escapeSlackDirectoryText(value string) string {
	return strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
	).Replace(value)
}

func onOff(value bool) string {
	if value {
		return "on"
	}
	return "off"
}

func proactiveChangeMessage(
	scope string,
	value string,
	status proactiveStatus,
) slackui.Message {
	target := "this channel"
	scopeEffect := "This setting takes priority over the workspace and deployment defaults."
	undo := "`/responder proactive inherit`"
	if scope == "global" {
		target = "the workspace default"
		scopeEffect = "This becomes the default in every channel Responder has joined. A channel-specific setting still takes priority."
		undo = "`/responder proactive global inherit`"
	}

	change := ""
	switch value {
	case "on":
		change = "Enabled proactive triage for " + target + "."
	case "off":
		change = "Disabled proactive triage for " + target + "."
	case "inherit":
		change = "Removed the Slack override for " + target + "."
	}

	return slackui.Message{
		Text: fmt.Sprintf(
			"%s Proactive triage is now %s in this channel.",
			change, onOff(status.Enabled),
		),
		Header: change,
		Sections: []string{
			proactiveBehavior(status.Enabled, false),
			"*Scope and precedence*\n" + scopeEffect + " " +
				"Responder is currently *" + onOff(status.Enabled) + "* in this channel because " +
				effectiveReason(status) + ".",
			"*Undo or inspect*\nUse " + undo + " to remove this setting, or " +
				"`/responder status` for the complete effective configuration.",
		},
		Context: []string{
			"Incident rooms remain interactive regardless of proactive triage. Coop and Emisar policy still control all infrastructure access.",
		},
	}
}

func turnLimitStatusMessage(status turnLimitStatus) slackui.Message {
	return slackui.Message{
		Text: fmt.Sprintf(
			"Responder automatically manages session capacity up to %d agent requests in this channel.",
			status.Limit,
		),
		Header: fmt.Sprintf("Automatic turn ceiling: %d", status.Limit),
		Sections: []string{
			"*What this means*\nResponder extends a Coop session automatically when more " +
				"authorized work arrives. Operators do not choose how many turns an " +
				"investigation needs. One turn is one accepted request; tool calls and " +
				"investigation steps inside that request are not counted separately.",
			"*Why this value applies*\n" + turnLimitReason(status) + ". The ceiling prevents " +
				"an accidentally unbounded session; Coop policy and service-wide limits can " +
				"still enforce a lower hard maximum.",
			"*Change or reset it*\nUse `/responder turn-limit 1000` for this channel, " +
				"`/responder turn-limit global 1000` for the workspace default, or replace " +
				"the number with `inherit` to remove that Slack override.",
		},
		Context: []string{
			"Changing this ceiling does not revoke capacity already allocated to an existing Coop session.",
		},
	}
}

func turnLimitChangeMessage(
	scope string,
	value string,
	status turnLimitStatus,
) slackui.Message {
	target := "this channel"
	if scope == "global" {
		target = "the workspace default"
	}
	change := "Removed the automatic turn-ceiling override for " + target + "."
	if value != "inherit" {
		change = fmt.Sprintf("Set the automatic turn ceiling for %s to %s.", target, value)
	}
	message := turnLimitStatusMessage(status)
	message.Header = change
	message.Text = fmt.Sprintf(
		"%s The effective ceiling in this channel is now %d agent requests.",
		change, status.Limit,
	)
	message.Sections[1] = "*Effective result*\n" + turnLimitReason(status) +
		fmt.Sprintf(". Responder will allocate capacity automatically up to %d requests.", status.Limit)
	return message
}

func turnLimitReason(status turnLimitStatus) string {
	switch status.EffectiveSource {
	case "channel override":
		return fmt.Sprintf("A channel-specific Slack setting sets the ceiling to %d", status.Limit)
	case "workspace override":
		return fmt.Sprintf(
			"No channel override is present, so the Slack workspace default sets the ceiling to %d",
			status.Limit,
		)
	default:
		return fmt.Sprintf(
			"No Slack override is present, so the deployment default sets the ceiling to %d",
			status.Limit,
		)
	}
}

func slashStatusMessage(
	status proactiveStatus,
	shadow shadowStatus,
	summon bool,
	repository string,
	preferenceCount int,
	ruleCount int,
	incident *core.Incident,
) slackui.Message {
	state := "passive"
	if status.Enabled {
		state = "proactive"
	}
	message := slackui.Message{
		Text: fmt.Sprintf(
			"Responder is %s in this channel. Proactive triage is %s because %s.",
			state, onOff(status.Enabled), effectiveReason(status),
		),
		Header: "Responder is " + state + " in this channel",
		Sections: []string{
			proactiveBehavior(status.Enabled, incident != nil),
			shadowBehavior(shadow),
			"*Why this is the effective setting*\n" + effectiveReason(status) + ". " +
				"Priority is: channel override, channel setup, workspace override, then deployment configuration.",
			mentionBehavior(summon),
			fmt.Sprintf(
				"*Durable behavior*\n%d enabled preference%s affect investigation method or "+
					"presentation. %d enabled standing rule%s can admit only their typed "+
					"matching messages and run read-only threaded checks, even when broad "+
					"proactive triage is off. Use `/responder preferences` or "+
					"`/responder rules` to inspect exact entries.",
				preferenceCount,
				map[bool]string{true: "", false: "s"}[preferenceCount == 1],
				ruleCount,
				map[bool]string{true: "", false: "s"}[ruleCount == 1],
			),
		},
		Fields: []slackui.Field{
			{Label: "This channel", Value: channelSettingDescription(status.ChannelOverride)},
			{Label: "Workspace default", Value: workspaceSettingDescription(status.GlobalOverride)},
			{Label: "Deployment default", Value: deploymentSettingDescription(status.ConfigDefault)},
			{
				Label: "New incident repository",
				Value: "`" + repository + "` - new Slack incidents use this repository and its configured policies",
			},
		},
		Context: []string{
			"Only you can see this status. Slack settings are durable and audited.",
		},
	}
	if incident == nil {
		message.Sections = append(message.Sections, normalChannelNextStep(status.Enabled, summon))
		return message
	}
	message.Sections = append(
		message.Sections,
		incidentStatusDescription(*incident),
		"*What you can do now*\nReply normally anywhere in this incident channel to collaborate. "+
			"Use `/responder update` for a fresh evidence-based summary, `/responder changes` "+
			"for the isolated diff, or `/responder help` for every control.",
	)
	return message
}

func proactiveBehavior(enabled bool, incidentRoom bool) string {
	behavior := "*Proactive triage is off.* In a normal channel, Responder ignores ordinary human " +
		"and app messages. Slash commands still work."
	if enabled {
		behavior = "*Proactive triage is on.* In a normal channel, Responder reads new human and " +
			"app messages. It may stay silent for noise or reply in the source thread. A credible " +
			"unresolved external-app alert may open an incident automatically; a human message " +
			"opens one only after an explicit request or button confirmation."
	}
	if incidentRoom {
		behavior += "\n\n*This channel already has an incident.* Incident collaboration remains " +
			"active regardless of proactive triage, so configured operators can talk to " +
			"Responder here without an `@mention`."
	}
	return behavior
}

func shadowBehavior(status shadowStatus) string {
	if status.Enabled {
		return "*Shadow evaluation is on.* Responder classifies new messages and records its " +
			"decision, evidence, and coverage, but it does not post replies, offer incidents, or " +
			"create incident rooms. Effective source: " + status.EffectiveSource + "."
	}
	return "*Shadow evaluation is off.* Eligible proactive or direct requests may produce a " +
		"visible reply. Effective source: " + status.EffectiveSource + "."
}

func effectiveReason(status proactiveStatus) string {
	switch status.EffectiveSource {
	case "channel override":
		return "a channel-specific Slack setting explicitly turns it " + onOff(status.Enabled)
	case "workspace override":
		return "no channel setting is present and the Slack workspace default turns it " +
			onOff(status.Enabled)
	case "channel setup":
		return "the confirmed setup for this channel turns it " + onOff(status.Enabled)
	default:
		if status.ConfigDefault {
			return "no Slack override is present and the deployment configuration includes this channel"
		}
		return "no Slack override is present and the deployment configuration does not include this channel"
	}
}

func channelSettingDescription(value string) string {
	switch value {
	case "on":
		return "On - force proactive triage in this channel"
	case "off":
		return "Off - force passive behavior in this channel"
	default:
		return "Not set - follow the workspace or deployment default"
	}
}

func workspaceSettingDescription(value string) string {
	switch value {
	case "on":
		return "On - proactive by default in every joined channel"
	case "off":
		return "Off - passive by default in every joined channel"
	default:
		return "Not set - each channel falls back to deployment configuration"
	}
}

func deploymentSettingDescription(enabled bool) string {
	if enabled {
		return "On - this channel is listed in `slack.watch_channels`"
	}
	return "Off - this channel is not listed in `slack.watch_channels`"
}

func mentionBehavior(enabled bool) string {
	if enabled {
		return "*Mention handling is enabled.* `@Emisar <question>` investigates and replies in " +
			"the source thread. Use `@Emisar open an incident for <summary>` when a dedicated " +
			"room and isolated working copy are actually required."
	}
	return "*Mention handling is disabled for new work.* An `@Emisar` mention does not start a " +
		"request from this channel. This does not affect conversation inside an existing incident room."
}

func normalChannelNextStep(enabled, summon bool) string {
	if enabled {
		return "*What you can do now*\nPost normally and Responder will triage the message. Use " +
			"`/responder proactive off` to make this channel passive, or `/responder help` for " +
			"the complete command guide."
	}
	if summon {
		return "*What you can do now*\nUse `@Emisar <question>` for a thread reply, or explicitly " +
			"ask `@Emisar open an incident for <summary>` for a dedicated room. Use " +
			"`/responder proactive on` to let Responder triage every new message."
	}
	return "*What you can do now*\nUse `/responder proactive on` to let Responder triage new " +
		"messages here. Use `/responder help` to see channel and workspace options."
}

func incidentStatusDescription(incident core.Incident) string {
	status := "open"
	switch incident.Status {
	case core.IncidentMonitoring:
		status = "monitoring recovery"
	case core.IncidentResolved:
		status = "resolved"
	case core.IncidentClosed:
		status = "closed"
	}
	activity := "Responder's current activity is unknown."
	switch incident.Workflow {
	case core.WorkflowProvisioningChannel:
		activity = "Responder is creating the dedicated incident room."
	case core.WorkflowProvisioningSession:
		activity = "Responder is preparing the isolated Coop workspace."
	case core.WorkflowHolding:
		activity = "The investigation is queued until agent capacity is available."
	case core.WorkflowInvestigating:
		activity = "An agent turn is running or queued."
	case core.WorkflowParked:
		activity = "Responder is waiting for a message; no agent turn is currently running."
	case core.WorkflowBlocked:
		activity = "Responder needs operator action before it can continue."
	case core.WorkflowClosed:
		activity = "The Coop session is closed and its isolated fork is preserved."
	}
	return fmt.Sprintf(
		"*Attached incident `%s` is %s.* %s",
		slackui.ShortID(incident.ID), status, activity,
	)
}

func slashControlReceipt(command, incidentID string) string {
	effect := map[string]string{
		"update":  "ask the agent to inspect current evidence and post a concise update",
		"changes": "inspect the isolated fork and post its current code diff. This is read-only and does not merge, sign, push, or deploy",
		"review":  "run Coop's read-only fix review against the isolated fork. A passing review is evidence, not permission to merge or deploy",
		"publish": "run a fresh readiness review and create or update a lease-protected draft PR containing the exact approved tree. Responder cannot merge or deploy it",
		"stop":    "cancel the active agent turn while preserving the fork, collected evidence, and queued work",
		"extend":  "explain the automatic session capacity policy. Manual turn allocation is no longer required",
		"close":   "close the incident session while preserving its isolated fork for later review or cleanup",
	}[command]
	return fmt.Sprintf(
		"*Request submitted for incident `%s`.*\n\nThis command will %s. "+
			"The pinned incident thread will show the authoritative result because the incident "+
			"state may have changed while this command was being processed.",
		incidentID, effect,
	)
}

// upperFirst capitalises the first rune of a label. Slicing the first byte
// would be correct only while every label is ASCII, which is not a property
// worth relying on for display text.
func upperFirst(value string) string {
	if value == "" {
		return value
	}
	first, size := utf8.DecodeRuneInString(value)
	return string(unicode.ToUpper(first)) + value[size:]
}
