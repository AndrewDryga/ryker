package service

import (
	"context"
	"errors"
	"strings"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
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
		"back to that thread",
		"reply in that thread",
		"post back to that thread",
		"post it back to that thread",
		"post hi back to that thread",
		"not pollute the channel",
		"not pollute channel",
	} {
		if strings.Contains(normalized, phrase) {
			return conversationLocationThread
		}
	}
	return conversationLocationFollow
}

func referencesPreviousThread(text string) bool {
	normalized := normalizeLocationRequest(text)
	return strings.Contains(normalized, "that thread") ||
		strings.Contains(normalized, "previous thread") ||
		strings.Contains(normalized, "prior thread")
}

func (s *Service) resolveConversationRoute(
	ctx context.Context,
	input core.SlackInput,
) (string, string, error) {
	if input.ChannelID == "" || input.UserID == "" {
		threadTS := conversationalResponseThread(input)
		return threadTS, "", nil
	}
	route, err := s.store.GetConversationRoute(ctx, input.ChannelID, input.UserID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return "", "", err
	}
	route.ChannelID = input.ChannelID
	route.UserID = input.UserID
	location := requestedConversationLocation(input.Text)
	responseThreadTS := ""
	referencedThreadTS := ""
	switch location {
	case conversationLocationChannel:
		if input.ThreadTS != "" {
			route.PreviousThreadTS = input.ThreadTS
		} else if route.ActiveThreadTS != "" {
			route.PreviousThreadTS = route.ActiveThreadTS
		}
		route.ActiveThreadTS = ""
		route.Explicit = true
		responseThreadTS = ""
	case conversationLocationThread:
		switch {
		case referencesPreviousThread(input.Text) && route.PreviousThreadTS != "":
			responseThreadTS = route.PreviousThreadTS
		case input.ThreadTS != "":
			responseThreadTS = input.ThreadTS
		case route.ActiveThreadTS != "":
			responseThreadTS = route.ActiveThreadTS
		default:
			responseThreadTS = input.MessageTS
		}
		referencedThreadTS = responseThreadTS
		if route.ActiveThreadTS != "" && route.ActiveThreadTS != responseThreadTS {
			route.PreviousThreadTS = route.ActiveThreadTS
		}
		route.ActiveThreadTS = responseThreadTS
		route.Explicit = true
	default:
		switch {
		case input.ThreadTS != "" &&
			route.Explicit &&
			route.ActiveThreadTS == "" &&
			route.PreviousThreadTS == input.ThreadTS:
			responseThreadTS = ""
			referencedThreadTS = input.ThreadTS
		case input.ThreadTS != "":
			responseThreadTS = input.ThreadTS
			if route.ActiveThreadTS != "" && route.ActiveThreadTS != input.ThreadTS {
				route.PreviousThreadTS = route.ActiveThreadTS
			}
			route.ActiveThreadTS = input.ThreadTS
			route.Explicit = false
		default:
			responseThreadTS = ""
			if route.ActiveThreadTS != "" {
				route.PreviousThreadTS = route.ActiveThreadTS
			}
			route.ActiveThreadTS = ""
			route.Explicit = false
		}
	}
	if err := s.store.PutConversationRoute(ctx, route); err != nil {
		return "", "", err
	}
	return responseThreadTS, referencedThreadTS, nil
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
		return "Continuing in the channel."
	case conversationLocationThread:
		return "Continuing in this thread."
	default:
		return ""
	}
}
