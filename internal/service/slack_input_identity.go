package service

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// canonicalSlackMessageInputID identifies one visible version of a Slack message.
// Socket Mode subscriptions and history reconciliation use different transport
// event IDs and kinds for the same content, so transport identity cannot safely
// drive model-work idempotency.
func canonicalSlackMessageInputID(input core.SlackInput) string {
	if input.ChannelID == "" || input.MessageTS == "" || !slackMessageInputKind(input.Kind) {
		return ""
	}
	digest := sha256.Sum256([]byte(strings.Join([]string{
		input.TeamID,
		input.ChannelID,
		input.MessageTS,
		input.UserID,
		input.Text,
		externalMessageFingerprint("", input.Attachments),
	}, "\x00")))
	return "slack_message_" + hex.EncodeToString(digest[:16])
}

func bindCanonicalSlackMessageInputID(input *core.SlackInput) {
	if input == nil || input.ID != "" {
		return
	}
	input.ID = canonicalSlackMessageInputID(*input)
}

func slackMessageInputKind(kind string) bool {
	switch kind {
	case "message", "mention", "direct", "bot_message":
		return true
	default:
		return false
	}
}
