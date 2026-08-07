package service

import (
	"context"
	"errors"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/store"
)

func referencesPreviousThread(text string) bool {
	normalized := decisionpkg.NormalizeLocationRequest(text)
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
	location := decisionpkg.RequestedConversationLocation(input.Text)
	preferred := decisionpkg.ConversationLocationFollow
	if location == decisionpkg.ConversationLocationFollow {
		preferred, err = s.preferredConversationLocation(ctx, input)
		if err != nil {
			return "", "", err
		}
	}
	responseThreadTS := ""
	referencedThreadTS := ""
	switch location {
	case decisionpkg.ConversationLocationChannel:
		if input.ThreadTS != "" {
			route.PreviousThreadTS = input.ThreadTS
		} else if route.ActiveThreadTS != "" {
			route.PreviousThreadTS = route.ActiveThreadTS
		}
		route.ActiveThreadTS = ""
		route.Explicit = true
		responseThreadTS = ""
	case decisionpkg.ConversationLocationThread:
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
			if preferred == decisionpkg.ConversationLocationChannel {
				responseThreadTS = ""
				referencedThreadTS = input.ThreadTS
				route.PreviousThreadTS = input.ThreadTS
				route.ActiveThreadTS = ""
			} else {
				responseThreadTS = input.ThreadTS
				if route.ActiveThreadTS != "" && route.ActiveThreadTS != input.ThreadTS {
					route.PreviousThreadTS = route.ActiveThreadTS
				}
				route.ActiveThreadTS = input.ThreadTS
			}
			route.Explicit = false
		default:
			if preferred == decisionpkg.ConversationLocationThread && input.MessageTS != "" {
				responseThreadTS = input.MessageTS
				if route.ActiveThreadTS != "" && route.ActiveThreadTS != input.MessageTS {
					route.PreviousThreadTS = route.ActiveThreadTS
				}
				route.ActiveThreadTS = input.MessageTS
			} else {
				responseThreadTS = ""
				if route.ActiveThreadTS != "" {
					route.PreviousThreadTS = route.ActiveThreadTS
				}
				route.ActiveThreadTS = ""
			}
			route.Explicit = false
		}
	}
	if err := s.store.PutConversationRoute(ctx, route); err != nil {
		return "", "", err
	}
	return responseThreadTS, referencedThreadTS, nil
}

func (s *Service) preferredConversationLocation(
	ctx context.Context,
	input core.SlackInput,
) (decisionpkg.ConversationLocation, error) {
	repository, err := s.effectiveRepository(
		ctx, input.ChannelID, input.UserID, s.cfg.Slack.DefaultRepository,
	)
	if err != nil {
		return decisionpkg.ConversationLocationFollow, err
	}
	preferences, err := s.loadEffectivePreferences(
		ctx, input.ChannelID, repository, input.UserID,
	)
	if err != nil {
		return decisionpkg.ConversationLocationFollow, err
	}
	for _, preference := range preferences {
		if preference.Name != "response_location" {
			continue
		}
		switch preference.Value {
		case "prefer_thread":
			return decisionpkg.ConversationLocationThread, nil
		case "prefer_channel":
			return decisionpkg.ConversationLocationChannel, nil
		default:
			return decisionpkg.ConversationLocationFollow, nil
		}
	}
	return decisionpkg.ConversationLocationFollow, nil
}

func conversationalResponseThread(input core.SlackInput) string {
	switch decisionpkg.RequestedConversationLocation(input.Text) {
	case decisionpkg.ConversationLocationChannel:
		return ""
	case decisionpkg.ConversationLocationThread:
		if input.ThreadTS != "" {
			return input.ThreadTS
		}
		return input.MessageTS
	default:
		return input.ThreadTS
	}
}

func conversationLocationAcknowledgement(location decisionpkg.ConversationLocation) string {
	switch location {
	case decisionpkg.ConversationLocationChannel:
		return "Continuing in the channel."
	case decisionpkg.ConversationLocationThread:
		return "Continuing in this thread."
	default:
		return ""
	}
}
