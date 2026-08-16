package service

import (
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/operationalkey"
)

const operationalBurstWindow = 90 * time.Second

// alertStreamWaitKind names the host's own external wait: an alert that was
// answered while it was still active, whose stream is expected to produce more
// cards. It is never emitted by a model — the host appends it — so it is the
// one wait kind that does not mean "the model is waiting on something", and the
// answered card keeps its check mark.
const alertStreamWaitKind = "alert_stream"

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
