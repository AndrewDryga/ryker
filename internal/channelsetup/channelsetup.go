// Package channelsetup reads what an operator is asking for when they talk to
// Responder about a channel's configuration.
//
// It is the smallest and most-exercised interpretation layer in the product:
// which wizard step a control belongs to, and which of the many phrasings
// people use maps to which command. Both are pure text-to-intent decisions, and
// both are the first thing an operator experiences.
//
// The cases that must NOT match matter as much as the ones that must.
// Responder is in these channels to talk, and answering "the proactive approach
// worked well" with a settings dump is exactly the weird behaviour that erodes
// trust on first contact.
package channelsetup

import (
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/slackui"
)

// turnLimitRequestPattern recognizes a request to change a channel's turn
// budget. The three-to-five digit bound keeps it from matching an ordinary
// sentence that happens to contain the word "turns" and a small number.
var turnLimitRequestPattern = regexp.MustCompile(
	`(?i)\b(?:turn(?:-| )?limit|turns?)\s+(?:to\s+)?([0-9]{3,5}|inherit)\b`,
)

func ChannelSetupChoice(actionID string) (string, string, bool) {
	switch actionID {
	case slackui.ActionSetupMentions:
		return "participation", "mentions only", true
	case slackui.ActionSetupProactive:
		return "participation", "proactive", true
	case slackui.ActionSetupShadow:
		return "participation", "shadow", true
	case slackui.ActionSetupDefaultRepo:
		return "repository", "default", true
	case slackui.ActionSetupAlertReply:
		return "alerts", "reply here", true
	case slackui.ActionSetupAlertOffer:
		return "alerts", "offer incident", true
	case slackui.ActionSetupAlertAutomatic:
		return "alerts", "automatic incident", true
	case slackui.ActionSetupOperatorsOnly:
		return "audience", "operators only", true
	case slackui.ActionSetupIncludeMe:
		return "audience", "include me", true
	default:
		if strings.HasPrefix(actionID, slackui.ActionSetupRepository) {
			return "repository", strings.TrimPrefix(actionID, slackui.ActionSetupRepository), true
		}
		return "", "", false
	}
}

func IsChannelSetupAction(actionID string) bool {
	switch actionID {
	case slackui.ActionSaveChannelConfig,
		slackui.ActionRestartChannelSetup,
		slackui.ActionCancelChannelSetup,
		slackui.ActionSetupQuickMentions,
		slackui.ActionSetupQuickProactive,
		slackui.ActionSetupCustomize:
		return true
	default:
		_, _, choice := ChannelSetupChoice(actionID)
		return choice
	}
}

func CaptureSlackIDs(pattern *regexp.Regexp, text string) []string {
	matches := pattern.FindAllStringSubmatch(text, -1)
	result := make([]string, 0, len(matches))
	for _, match := range matches {
		if len(match) == 2 {
			result = append(result, match[1])
		}
	}
	return result
}

func UniqueSorted(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

// ConversationalAliases maps the phrasings people actually use to the command
// they mean.
//
// This is a table rather than a chain of conditions because it is a table: the
// only thing that varies between entries is the words. First match wins, so
// more specific phrasings come first.

// ConversationalAliases maps the phrasings people actually use to the command
// they mean.
//
// This is a table rather than a chain of conditions because it is a table: the
// only thing that varies between entries is the words. First match wins, so
// more specific phrasings come first.
var ConversationalAliases = []struct {
	command  string
	exact    []string
	contains []string
}{
	{command: "help", exact: []string{"help"}, contains: []string{"what can you do"}},
	{command: "status", contains: []string{
		"how are you configured", "show settings", "show status",
	}},
	{command: "incidents open", contains: []string{"open incidents", "active incidents"}},
	{command: "work", contains: []string{
		"what are you working on", "what do you owe", "show commitments", "show active work",
	}},
	{command: "incidents all", contains: []string{"all incidents", "incident history"}},
	{command: "memory", contains: []string{"show memory", "what do you remember"}},
	{command: "preferences", contains: []string{"show preferences"}},
	{command: "rules", contains: []string{"show rules", "show automations"}},
	{command: "schedules", contains: []string{"show schedules", "show reminders"}},
}

// ToggleSubjects are the settings a channel can turn on, off, or inherit from
// the workspace default.

// ToggleSubjects are the settings a channel can turn on, off, or inherit from
// the workspace default.
var ToggleSubjects = []string{"proactive", "shadow"}

// DirectCommands are recognized on their own or behind a "show"/"get".

// DirectCommands are recognized on their own or behind a "show"/"get".
var DirectCommands = []string{
	"timeline", "evidence", "handoff", "update", "changes", "review",
	"publish", "stop", "close",
}

// ToggleState reads which way a toggle request points, or "" if it does not
// point anywhere. The " on" and "on" suffix cases are separate because
// "proactive on" and "turn proactive on" both occur and neither contains "on"
// as a standalone word in a position the other does.

// ToggleState reads which way a toggle request points, or "" if it does not
// point anywhere. The " on" and "on" suffix cases are separate because
// "proactive on" and "turn proactive on" both occur and neither contains "on"
// as a standalone word in a position the other does.
func ToggleState(text string) string {
	switch {
	case strings.Contains(text, "inherit"):
		return "inherit"
	case strings.Contains(text, " on") || strings.HasSuffix(text, "on") ||
		strings.Contains(text, "enable"):
		return "on"
	case strings.Contains(text, " off") || strings.HasSuffix(text, "off") ||
		strings.Contains(text, "disable"):
		return "off"
	default:
		return ""
	}
}

func ConversationalCommand(text string) (string, bool) {
	text = strings.TrimSpace(strings.ToLower(text))
	text = strings.Trim(text, "?.! ")
	for _, alias := range ConversationalAliases {
		if slices.Contains(alias.exact, text) {
			return alias.command, true
		}
		for _, phrase := range alias.contains {
			if strings.Contains(text, phrase) {
				return alias.command, true
			}
		}
	}
	for _, subject := range ToggleSubjects {
		if !strings.Contains(text, subject) {
			continue
		}
		if state := ToggleState(text); state != "" {
			return subject + " " + state, true
		}
	}
	if match := turnLimitRequestPattern.FindStringSubmatch(text); len(match) == 2 {
		return "turn-limit " + match[1], true
	}
	for _, command := range DirectCommands {
		if text == command || text == "show "+command || text == "get "+command {
			return command, true
		}
	}
	return "", false
}

func ExplicitChannelConfigurationRequest(text string) bool {
	text = strings.ToLower(text)
	return strings.Contains(text, "configure this channel") ||
		strings.Contains(text, "reconfigure this channel") ||
		strings.Contains(text, "set up this channel") ||
		strings.Contains(text, "setup this channel")
}
