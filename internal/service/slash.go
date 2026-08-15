package service

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/AndrewDryga/responder/internal/assignments"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/reportcanvas"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const proactiveSettingName = "proactive"
const shadowSettingName = "shadow"
const turnLimitSettingName = "turn_limit"

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

// processSlashInput runs the emergency kit.
//
// `/responder` used to carry more than twenty subcommands, which made it a
// second product surface: everything Responder could do had a spelling here
// and a conversational path beside it, and the two drifted. Two months of
// audit found the slash surface used for one deliberate `proactive on` per
// deployment and otherwise only for its own failures.
//
// What is left is what has to work when nothing else does — when Coop is down,
// when the model is looping, when a room needs to go quiet now. Those are
// deterministic, reach no model, and answer privately. `assignments` is the one
// verb here that is none of those things; it stays for reading a channel's
// standing grants and taking one back, which is the half of that family an
// operator wants reachable when the conversational path is what is broken.
// Creating one left on 2026-08-15 with `offer_assignment`: the verb that
// GRANTED authority is a confirmation card now, and `create` answers by saying
// so. Everything else is a conversation, a card button, or the App Home, and
// the default branch says so by name rather than printing a usage message for a
// verb that is gone.
func (s *Service) processSlashInput(ctx context.Context, input core.SlackInput) error {
	fields := strings.Fields(strings.ToLower(strings.TrimSpace(input.Text)))
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
	// assignments stays for list, pause, resume and delete. It stayed for
	// `create` too until 2026-08-15, when slash was its only creation surface
	// and deleting the verb would have deleted the feature; `offer_assignment`
	// now carries that, so the one branch of this family that granted authority
	// is a normalized-bounds confirmation card and the typed verb answers with
	// a pointer to it.
	//
	// The raw text, not the lower-cased fields every other subcommand reads:
	// an assignment id is case-sensitive, and so were the repository, globs and
	// signal words the retired `create` took.
	case "assignments", "assignment":
		return s.finishSlashAssignments(ctx, input, strings.Fields(slashArgument(input.Text)))
	case "proactive", "watch":
		return s.configureProactive(ctx, input, fields[1:])
	case "shadow":
		return s.configureShadow(ctx, input, fields[1:])
	default:
		if pointer, ok := retiredSlashSubcommands[fields[0]]; ok {
			return s.refuseSlashInput(
				ctx, input,
				fmt.Sprintf(
					"`/responder %s` is gone. %s\n\n%s",
					fields[0], pointer, slashKit,
				),
			)
		}
		return s.refuseSlashInput(
			ctx, input,
			fmt.Sprintf("Unknown `/responder` subcommand `%s`.\n\n%s", fields[0], slashHelp()),
		)
	}
}

// slashKit is the one line that follows every refusal: whatever you typed, here
// is the whole of what this command still does.
const slashKit = "`/responder` is the emergency kit now: `status`, " +
	"`proactive on|off|inherit`, `shadow on|off|inherit`, `assignments`, and `help`."

// retiredSlashSubcommands names where each removed verb went.
//
// A removed verb answers with its replacement for one release and then stops
// being recognised at all. The alternative — falling through to "unknown
// subcommand" plus a help card — tells an operator who typed a verb that
// worked last week that they typed it wrong, which is both false and useless:
// the thing they wanted still exists, somewhere else. Every alias spelling is
// listed, because an operator who learned `preference` is no better served by
// silence than one who learned `preferences`.
var retiredSlashSubcommands = map[string]string{
	"incidents":   "Open the App Home for what is in flight, or ask in the channel.",
	"work":        "Open the App Home for what is in flight, or ask in the channel.",
	"commitments": "Open the App Home for what is in flight, or ask in the channel.",
	"memory":      "Open the App Home, or ask about what is remembered here.",
	"preferences": "Open the App Home, or say what you want changed and confirm the offer.",
	"preference":  "Open the App Home, or say what you want changed and confirm the offer.",
	"rules":       "Open the App Home, or say what you want changed and confirm the offer.",
	"rule":        "Open the App Home, or say what you want changed and confirm the offer.",
	"schedules":   "Open the App Home, or ask for the schedule you want and confirm it.",
	"schedule":    "Open the App Home, or ask for the schedule you want and confirm it.",
	"reminders":   "Open the App Home, or ask for the schedule you want and confirm it.",
	"feedback":    "Just say it here. Feedback is recorded from the conversation.",
	"timeline":    "Use the buttons on the pinned card, or ask for it in the incident room.",
	"evidence":    "Use the buttons on the pinned card, or ask for it in the incident room.",
	"handoff":     "Use the buttons on the pinned card, or ask for it in the incident room.",
	"postmortem":  "Use the buttons on the pinned card, or ask for it in the incident room.",
	"update":      "Use the buttons on the pinned card, or ask in the thread.",
	"changes":     "Use the buttons on the pinned card, or ask in the thread.",
	"review":      "Use the buttons on the pinned card, or ask in the thread.",
	"publish":     "Use the buttons on the pinned card, or ask in the thread.",
	"stop":        "Use the buttons on the pinned card, or ask in the thread.",
	"extend":      "Responder allocates capacity automatically; nothing needed extending.",
	"close":       "Use the buttons on the pinned card, or ask in the thread.",
	"turn-limit":  "The ceiling is `coop.turn_limit` in responder.yaml; operators never estimate turns.",
	"turns":       "The ceiling is `coop.turn_limit` in responder.yaml; operators never estimate turns.",
}

// recordControlCommands maps the four record buttons to the report each one
// renders. The button carries the work it belongs to in its value, which is how
// a task thread can ask for its own handoff — the slash spelling these replace
// resolved an incident by channel and could not name a thread at all.
var recordControlCommands = map[string]string{
	slackui.ActionRecordTimeline:   "timeline",
	slackui.ActionRecordEvidence:   "evidence",
	slackui.ActionRecordHandoff:    "handoff",
	slackui.ActionRecordPostmortem: "postmortem",
}

func (s *Service) handleRecordControl(ctx context.Context, input core.SlackInput) error {
	command, ok := recordControlCommands[slackui.BaseActionID(input.ActionID)]
	if !ok {
		return fmt.Errorf("unknown record control %q", input.ActionID)
	}
	return s.finishIncidentIntelligence(ctx, input, command)
}

// finishSlashAssignments runs what is left of the standing-assignment family:
// reading them, and pausing, resuming or deleting one.
//
// Operator-only, by the check every slash command already passed above, and
// that gate is the whole authorization story here. Creation is no longer in it
// — `offer_assignment` and its confirmation card own that — so every branch
// reachable from this method now either reads a grant or takes one away, which
// is the class of thing an emergency kit is allowed to hold.
//
// The rendering is here rather than in internal/assignments because that
// package is imported by the operation contract and may not reach Slack.
func (s *Service) finishSlashAssignments(
	ctx context.Context, input core.SlackInput, args []string,
) error {
	result, err := assignments.Run(ctx, s.store.StandingAssignments, args, input)
	if err != nil {
		return s.refuseSlashInput(ctx, input, err.Error())
	}
	if result.Audit.Kind != "" {
		s.audit(ctx, result.Audit)
	}
	message := slackui.AssignmentDirectoryMessage(result.Directory, result.Tallies)
	if result.Verb != "" {
		message = slackui.AssignmentChangedMessage(result.Changed, result.Verb)
	}
	return s.finishSlashMessage(ctx, input, message)
}

func (s *Service) finishIncidentIntelligence(
	ctx context.Context,
	input core.SlackInput,
	command string,
) error {
	if id := strings.TrimSpace(input.ActionValue); id != "" {
		incident, err := s.store.GetIncident(ctx, id)
		if err == nil {
			return s.publishIncidentRecord(ctx, input, incident, command)
		}
		if !errors.Is(err, store.ErrNotFound) {
			return err
		}
	}
	incident, err := s.store.FindLatestIncidentByChannel(ctx, input.ChannelID)
	if errors.Is(err, store.ErrNotFound) {
		return s.refuseSlashInput(
			ctx, input,
			"*There is no incident attached to this channel.* The timeline, evidence, "+
				"handoff, and postmortem records read the durable record for the latest "+
				"incident room. Open the App Home to find one.",
		)
	}
	if err != nil {
		return err
	}
	return s.publishIncidentRecord(ctx, input, incident, command)
}

func (s *Service) publishIncidentRecord(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
	command string,
) error {
	record, err := s.store.LoadRemediationRecord(ctx, incident.ID)
	if err != nil {
		return err
	}
	report, ok := reportcanvas.For(command, record)
	if !ok {
		return errors.New("unknown incident record")
	}
	return s.finishSlashMessage(ctx, input, reportcanvas.Publish(
		ctx, s.slack, s.log, input.ChannelID, report,
	))
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

// slashTextForCommandAction routes the help card's one remaining button.
//
// It used to route four: the incident directory's open, all, previous and next
// pages were clicks that re-entered the subcommand router as text. The
// directory is the App Home's job now, so the paging round trip went with it
// and what is left is the button that answers the same question `status` does.
func slashTextForCommandAction(input core.SlackInput) (string, bool) {
	if input.ActionID == slackui.ActionCommandStatus && input.ActionValue == "status" {
		return "status", true
	}
	return "", false
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
	return s.finishSlashMessage(ctx, input, message)
}

// refuseSlashInput turns a command down to the person who ran it.
//
// It is a thin wrapper now, and it is kept as its own name because the reason
// it exists is not visible at the call sites. Every refusal on this path — you
// are not in `slack.operators`, this account is a guest, mistyped usage, a verb
// that no longer exists — names one Slack account and nothing else, and nobody
// else in the room can act on reading it. A slash command answers privately
// because Slack makes slash replies private; when a second spelling of these
// commands existed it did not, and the identical sentence about the identical
// person became a public callout depending only on which spelling they used.
// The second spelling is gone. The name stays so the next surface that reaches
// for this path inherits the rule rather than rediscovering it.
func (s *Service) refuseSlashInput(
	ctx context.Context,
	input core.SlackInput,
	text string,
	threadTS ...string,
) error {
	return s.finishSlashInput(ctx, input, text, threadTS...)
}

// privateReplyThread decides which thread a private answer belongs in.
//
// The default mirrors postInputMessage exactly: the same input answered out
// loud and answered privately must land in the same place. An explicit override
// exists for the incident-scoped controls, whose public answers are threaded on
// the task rather than on the click — see controlReplyThread.
func privateReplyThread(input core.SlackInput, override []string) string {
	if len(override) > 0 {
		return override[0]
	}
	return conversationalResponseThread(input)
}

func (s *Service) finishSlashInput(
	ctx context.Context,
	input core.SlackInput,
	text string,
	threadTS ...string,
) error {
	return s.finishSlashMessage(ctx, input, slackui.Notice(text), threadTS...)
}

func (s *Service) finishSlashMessage(
	ctx context.Context,
	input core.SlackInput,
	message slackui.Message,
	threadTS ...string,
) error {
	message = s.sanitizeMessage(message)
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
	if err := s.slack.PostEphemeral(
		ctx,
		input.ChannelID,
		input.UserID,
		privateReplyThread(input, threadTS),
		message,
	); err != nil {
		// A direct message is already private, so the reason to prefer an
		// ephemeral message there does not apply — and when Slack rejects the
		// ephemeral post, retrying replays the same rejection until the input
		// gives up, which is how a valid command answered nobody at all. Post
		// it as an ordinary message in the same conversation instead.
		if strings.HasPrefix(input.ChannelID, "D") {
			if postErr := s.postInputMessage(
				ctx, "slash_"+input.ID, input, message,
			); postErr == nil {
				return s.store.FinishSlackInput(ctx, input.ID)
			}
		}
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

// slashArgument returns everything after the subcommand, untouched. Only
// `assignments` still needs it: its bounds are case-sensitive, so it reads the
// raw text rather than the lower-cased fields the kill switches parse.
func slashArgument(text string) string {
	text = strings.TrimSpace(text)
	if index := strings.IndexAny(text, " \t\r\n"); index >= 0 {
		return strings.TrimSpace(text[index+1:])
	}
	return ""
}

func slashHelp() string {
	return strings.Join(slashHelpSections(), "\n\n")
}

// slashHelpSections is the whole command guide, and it is the emergency kit.
//
// It used to be six sections and about thirty spellings, which is what a
// command surface looks like when everything the product does has to have one.
// Help that long is not read; it is scrolled past by somebody who already knows
// what they want. What is here is what `/responder` still does, and one line
// naming where the rest went, so an operator who came looking for `incidents`
// leaves knowing to open the App Home rather than believing it broke.
func slashHelpSections() []string {
	return []string{
		"*The emergency kit*\n" +
			"`/responder status` - what Responder is doing in this channel and why\n" +
			"`/responder proactive on|off|inherit` - change what this channel is read for\n" +
			"`/responder proactive global on|off|inherit` - change the workspace default\n" +
			"`/responder shadow on|off|inherit` - evaluate without posting or opening incidents\n" +
			"`inherit` removes the Slack override and follows the next configured default.",
		// assignments is listed because taking a grant back is the emergency
		// half of it, and an operator looking for that will look here. Creating
		// one is named in the same breath and pointed elsewhere: it is the only
		// thing this kit ever did that handed out authority, and the sentence
		// that replaces it has to reach the operator who learned the command.
		"*Standing assignments*\n" +
			"`/responder assignments` - read this channel's grants, and `pause`, `resume` " +
			"or `delete` one\n" +
			"Creating one is a conversation now: say what you want watched and Responder " +
			"shows you the exact bounds to confirm.",
		"*Why so little*\nThese work when nothing else does: no model runs, no Coop " +
			"session is needed, and the answer is private to you. Everything else is a " +
			"conversation with Responder, a button on a pinned card, or the App Home — " +
			"which can reach a task thread, and a command typed into the channel " +
			"composer cannot.",
		"Ask for what you want in your own words and Responder will show you exactly " +
			"what it is about to save, change, or start before it does it.",
	}
}

func slashHelpMessage() slackui.Message {
	return slackui.Message{
		Text:     "Responder command guide: status, proactive, shadow, help.",
		Header:   "Responder command guide",
		Sections: slashHelpSections(),
		Actions: []slackui.Action{
			{
				ID: slackui.ActionCommandStatus, Label: "Status here",
				Value: "status", Style: "primary",
			},
		},
		Context: []string{
			"This button is read-only. Configuration and lifecycle changes require explicit text or pinned-card confirmation.",
		},
	}
}

func slashUsage(command string) string {
	switch command {
	case "proactive":
		return "*Choose what Responder should read.*\n\n" +
			"`/responder proactive on|off|inherit` changes only this channel. " +
			"`/responder proactive global on|off|inherit` changes the workspace default.\n\n" +
			"`on` reads and triages new messages, `off` ignores ordinary messages, and " +
			"`inherit` removes that Slack override so the next default applies. Use " +
			"`/responder status` to preview the current effective behavior."
	case "assignments":
		return assignments.Usage()
	case "shadow":
		return "*Evaluate Responder without channel output.*\n\n" +
			"`/responder shadow on|off|inherit` changes this channel. " +
			"`/responder shadow global on|off|inherit` changes the workspace default. " +
			"Shadow mode still runs read-only classification and records its decision, evidence, " +
			"and coverage, but it never posts, offers, or creates an incident."
	default:
		return "Run `/responder " + command + "` without additional text. " + slashKit
	}
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
					"proactive triage is off. The App Home lists the exact entries.",
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
		"*What you can do now*\nReply normally anywhere in this incident channel to collaborate, "+
			"or ask for an update, the diff, or the record. The pinned card carries the "+
			"controls as buttons.",
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
