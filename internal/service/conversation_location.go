package service

import (
	"strings"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
)

type conversationLocation int

const (
	conversationLocationFollow conversationLocation = iota
	conversationLocationChannel
	conversationLocationThread
)

func requestedConversationLocation(text string) conversationLocation {
	normalized := normalizeLocationRequest(text)
	for _, phrase := range []string{
		"switch to channel",
		"switch to the channel",
		"continue in channel",
		"continue in the channel",
		"back to channel",
		"back to the channel",
		"reply in channel",
		"reply in the channel",
		"move this to channel",
		"move this to the channel",
	} {
		if strings.Contains(normalized, phrase) {
			return conversationLocationChannel
		}
	}
	for _, phrase := range []string{
		"switch to thread",
		"switch to a thread",
		"continue in thread",
		"continue in the thread",
		"continue in a thread",
		"reply in thread",
		"reply in the thread",
		"move this to thread",
		"move this to a thread",
		"take this to thread",
		"take this to a thread",
		"use a thread",
		"not pollute the channel",
		"not pollute channel",
	} {
		if strings.Contains(normalized, phrase) {
			return conversationLocationThread
		}
	}
	return conversationLocationFollow
}

func conversationalResponseThread(input core.SlackInput) string {
	switch requestedConversationLocation(input.Text) {
	case conversationLocationChannel:
		return ""
	case conversationLocationThread:
		if input.ThreadTS != "" {
			return input.ThreadTS
		}
		return input.MessageTS
	default:
		return input.ThreadTS
	}
}

func locationOnlyRequest(text string) bool {
	normalized := normalizeLocationRequest(text)
	normalized = strings.TrimPrefix(normalized, "lets ")
	normalized = strings.TrimPrefix(normalized, "please ")
	normalized = strings.TrimSuffix(normalized, " please")
	switch normalized {
	case "switch to channel",
		"switch to the channel",
		"continue in channel",
		"continue in the channel",
		"back to channel",
		"back to the channel",
		"reply in channel",
		"reply in the channel",
		"switch to thread",
		"switch to a thread",
		"continue in thread",
		"continue in the thread",
		"continue in a thread",
		"reply in thread",
		"reply in the thread",
		"move this to thread",
		"move this to a thread",
		"take this to thread",
		"take this to a thread",
		"use a thread",
		"switch to thread not to pollute channel",
		"switch to a thread not to pollute the channel",
		"continue in thread not to pollute channel",
		"continue in a thread not to pollute the channel",
		"not pollute the channel",
		"not pollute channel":
		return true
	default:
		return false
	}
}

func normalizeLocationRequest(value string) string {
	value = strings.ToLower(value)
	value = strings.ReplaceAll(value, "let's", "lets")
	value = strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsSpace(r) {
			return r
		}
		return ' '
	}, value)
	return strings.Join(strings.Fields(value), " ")
}

func conversationLocationAcknowledgement(location conversationLocation) string {
	switch location {
	case conversationLocationChannel:
		return "**Continuing in the channel.** Send the next message here. Emisar will keep " +
			"replies in the channel unless you answer in a thread or ask to move."
	case conversationLocationThread:
		return "**Continuing in this thread.** Send the next message here. Emisar will keep " +
			"replies in the thread unless you answer in the channel or ask to move."
	default:
		return ""
	}
}
