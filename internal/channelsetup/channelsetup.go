// Package channelsetup reads which wizard control an operator clicked, and the
// one sentence that asks to start the wizard at all.
//
// It used to do more. A keyword table mapped "the phrasings people actually
// use" onto slash subcommands and ran on every plain channel message an
// operator sent, so "shadow traffic is on the new cluster, ignore it" turned
// the channel silent and "hey bob what are you working on?" posted the
// commitment card at the room. That table is gone rather than tightened:
// substring matching on free text cannot be made safe, because the words a
// setting is named after are the words people use to discuss it. Intent now
// comes from the model, which classifies, and the host, which executes.
//
// What is left is a text decision only because it must survive the model being
// unavailable: an operator asking in so many words to set this channel up.
package channelsetup

import (
	"regexp"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/slackui"
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

// ExplicitChannelConfigurationRequest reports whether somebody asked, in so
// many words, to configure the channel they are standing in.
//
// The addressed argument is not a convenience for the caller. It is the guard
// that keeps this from becoming the keyword table it replaced: an operator can
// say "we should reconfigure this channel next sprint" to a colleague, and a
// sentence aimed at the room must never open a settings wizard on the strength
// of the words in it. Only a mention or a direct message is aimed at
// Responder, so only those may match, and a caller has to say which it has.
func ExplicitChannelConfigurationRequest(text string, addressed bool) bool {
	if !addressed {
		return false
	}
	text = strings.ToLower(text)
	return strings.Contains(text, "configure this channel") ||
		strings.Contains(text, "reconfigure this channel") ||
		strings.Contains(text, "set up this channel") ||
		strings.Contains(text, "setup this channel")
}
