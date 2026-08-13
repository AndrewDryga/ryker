package service

import (
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/operationalkey"
)

const operationalBurstWindow = 90 * time.Second

// OperationalCorrelationKey derives the key that groups operationally
// related inputs into one burst.
var OperationalCorrelationKey = operationalkey.Key
var broadOperationalBurstCoalescingAllowed = operationalkey.BroadBurstCoalescingAllowed

func (s *Service) obviousHumanDialogue(input core.SlackInput, state decisionpkg.WatchTurnState) bool {
	if input.Kind != "message" || state.ConversationFollowup ||
		len(state.MatchedRules) > 0 || len(input.Attachments) > 0 {
		return false
	}
	mentionedAnotherHuman := false
	for _, match := range slackUserMentionPattern.FindAllStringSubmatch(input.Text, -1) {
		if len(match) < 2 {
			continue
		}
		if match[1] == s.identity.BotUserID {
			return false
		}
		mentionedAnotherHuman = true
	}
	return mentionedAnotherHuman
}
