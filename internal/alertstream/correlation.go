package alertstream

import (
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/operationalkey"
)

// PriorFiringMessageLink returns the latest firing card from the same
// operational stream as input, even when unrelated alerts share the channel.
func PriorFiringMessageLink(input core.SlackInput, messages []decisionpkg.WatchContextMessage) string {
	key := operationalkey.Key(input)
	for index := len(messages) - 1; key != "" && index >= 0; index-- {
		message := messages[index]
		if message.Target || message.SenderType != "external_app" || message.MessageLink == "" ||
			!decisionpkg.OperationalAlertEvent(message.Text) || decisionpkg.OperationalAlertResolvedEvent(message.Text) {
			continue
		}
		candidate := core.SlackInput{Kind: "bot_message", UserID: message.SenderID, Text: message.Text}
		if operationalkey.Key(candidate) == key {
			return message.MessageLink
		}
	}
	return ""
}

func GovernedOperationalAlert(input core.SlackInput, state decisionpkg.WatchTurnState) bool {
	return decisionpkg.MatchedOperationalAlertRule(state.MatchedRules) ||
		((input.Kind == "bot_message" || input.Kind == "recheck") && state.AlertPolicy != "" && decisionpkg.OperationalAlertEvent(input.Text) && !decisionpkg.ExternalCoordinationOnlyEvent(input.Text))
}
