package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

type agentContextRequest struct {
	ChannelID          string
	Repository         string
	OperatorID         string
	SourceInputID      string
	TargetInput        *core.SlackInput
	ReferencedThreadTS string
	IncludeRecent      bool
}

type assembledAgentContext struct {
	Repository        string                         `json:"repository"`
	Prior             operationalMemoryContext       `json:"prior_operational_context,omitempty"`
	Situation         core.AgentMemory               `json:"conversation_situation,omitempty"`
	RelatedSituations []conversationSituationContext `json:"related_situations,omitempty"`
	RecentMessages    []watchContextMessage          `json:"recent_messages_around_target,omitempty"`
	ReferencedThread  *referencedThreadContext       `json:"referenced_thread,omitempty"`
	CapturedAt        time.Time                      `json:"captured_at"`
}

type referencedThreadContext struct {
	ThreadTS       string                `json:"thread_ts"`
	LastMessageTS  string                `json:"last_message_ts,omitempty"`
	Summary        core.AgentMemory      `json:"summary,omitempty"`
	RecentMessages []watchContextMessage `json:"recent_messages,omitempty"`
}

type conversationSituationContext struct {
	ChannelID    string           `json:"channel_id"`
	ChannelName  string           `json:"channel_name,omitempty"`
	ThreadTS     string           `json:"thread_ts,omitempty"`
	Repository   string           `json:"repository"`
	Relationship string           `json:"relationship"`
	Summary      core.AgentMemory `json:"summary"`
	UpdatedAt    string           `json:"updated_at"`
}

func (s *Service) assembleAgentContext(
	ctx context.Context,
	request agentContextRequest,
) (assembledAgentContext, error) {
	repository, err := s.effectiveRepository(
		ctx,
		request.ChannelID,
		request.OperatorID,
		request.Repository,
	)
	if err != nil {
		return assembledAgentContext{}, err
	}
	prior, err := s.loadOperationalMemoryContext(
		ctx,
		request.ChannelID,
		repository,
		request.OperatorID,
		request.SourceInputID,
	)
	if err != nil {
		return assembledAgentContext{}, err
	}
	result := assembledAgentContext{
		Repository: repository,
		Prior:      prior,
		CapturedAt: time.Now().UTC(),
	}
	sinceTS := ""
	if request.ChannelID != "" {
		memory, memoryErr := s.store.GetChannelMemory(ctx, request.ChannelID)
		if memoryErr == nil {
			result.Situation = memory.State
		} else if !errors.Is(memoryErr, store.ErrNotFound) {
			return assembledAgentContext{}, memoryErr
		}
		threadTS := ""
		if request.TargetInput != nil {
			threadTS = request.TargetInput.ThreadTS
			conversation, conversationErr := s.store.GetConversationMemory(
				ctx,
				request.ChannelID,
				threadTS,
			)
			if conversationErr == nil {
				result.Situation = conversation.State
				sinceTS = conversation.LastMessage
				if err := s.store.MarkConversationMemoriesRecalled(
					ctx, []core.ConversationMemory{conversation},
				); err != nil {
					return assembledAgentContext{}, err
				}
			} else if !errors.Is(conversationErr, store.ErrNotFound) {
				return assembledAgentContext{}, conversationErr
			} else if threadTS != "" {
				result.Situation = core.AgentMemory{}
			}
		}
		related, relatedErr := s.store.ListRelatedConversationMemories(
			ctx,
			request.ChannelID,
			threadTS,
			repository,
			8,
		)
		if relatedErr != nil {
			return assembledAgentContext{}, relatedErr
		}
		if err := s.store.MarkConversationMemoriesRecalled(ctx, related); err != nil {
			return assembledAgentContext{}, err
		}
		result.RelatedSituations = make(
			[]conversationSituationContext,
			0,
			len(related),
		)
		for _, item := range related {
			relationship := "workspace"
			if item.ChannelID == request.ChannelID {
				relationship = "same_channel"
			} else if item.Repository == repository {
				relationship = "same_repository"
			}
			result.RelatedSituations = append(
				result.RelatedSituations,
				conversationSituationContext{
					ChannelID: item.ChannelID, ChannelName: item.ChannelName,
					ThreadTS:   item.ThreadTS,
					Repository: item.Repository, Relationship: relationship,
					Summary:   sanitizeMemory(item.State),
					UpdatedAt: item.UpdatedAt.UTC().Format(time.RFC3339),
				},
			)
		}
	}
	if request.IncludeRecent && request.TargetInput != nil {
		admitted, err := s.store.ListRecentWatchMessages(
			ctx,
			request.ChannelID,
			s.cfg.Slack.WatchContext,
		)
		if err != nil {
			return assembledAgentContext{}, err
		}
		history, err := s.slack.RecentMessages(
			ctx,
			request.ChannelID,
			request.TargetInput.ThreadTS,
			request.TargetInput.MessageTS,
			sinceTS,
			s.cfg.Slack.WatchContext,
		)
		if err != nil {
			return assembledAgentContext{}, err
		}
		recent := mergeSlackContext(
			admitted,
			history,
			*request.TargetInput,
			s.cfg.Slack.WatchContext,
		)
		result.RecentMessages = makeWatchContext(
			recent,
			*request.TargetInput,
			s.identity.BotUserID,
		)
	}
	if request.ReferencedThreadTS != "" &&
		(request.TargetInput == nil ||
			request.ReferencedThreadTS != request.TargetInput.ThreadTS) {
		referenced := &referencedThreadContext{ThreadTS: request.ReferencedThreadTS}
		conversation, conversationErr := s.store.GetConversationMemory(
			ctx,
			request.ChannelID,
			request.ReferencedThreadTS,
		)
		if conversationErr == nil {
			referenced.LastMessageTS = conversation.LastMessage
			referenced.Summary = sanitizeMemory(conversation.State)
			if err := s.store.MarkConversationMemoriesRecalled(
				ctx, []core.ConversationMemory{conversation},
			); err != nil {
				return assembledAgentContext{}, err
			}
		} else if !errors.Is(conversationErr, store.ErrNotFound) {
			return assembledAgentContext{}, conversationErr
		}
		history, historyErr := s.recentMessages(
			ctx,
			request.ChannelID,
			request.ReferencedThreadTS,
			referenced.LastMessageTS,
			"",
			s.cfg.Slack.WatchContext,
		)
		if historyErr != nil {
			return assembledAgentContext{}, historyErr
		}
		referenced.RecentMessages = historyWatchContext(
			history,
			request.ChannelID,
			s.identity.BotUserID,
		)
		result.ReferencedThread = referenced
	}
	return result, nil
}

func (s *Service) recentMessages(
	ctx context.Context,
	channelID string,
	threadTS string,
	targetTS string,
	sinceTS string,
	limit int,
) ([]slackui.HistoryMessage, error) {
	if targetTS == "" {
		return s.slack.RecentMessages(
			ctx, channelID, threadTS, targetTS, sinceTS, limit,
		)
	}
	key := fmt.Sprintf(
		"%s\x00%s\x00%s\x00%s\x00%d",
		channelID, threadTS, targetTS, sinceTS, limit,
	)
	now := time.Now()
	s.historyMu.Lock()
	cached, ok := s.historyCache[key]
	if ok && now.Before(cached.expiresAt) {
		messages := append([]slackui.HistoryMessage(nil), cached.messages...)
		s.historyMu.Unlock()
		return messages, nil
	}
	if ok {
		delete(s.historyCache, key)
	}
	s.historyMu.Unlock()
	messages, err := s.slack.RecentMessages(
		ctx, channelID, threadTS, targetTS, sinceTS, limit,
	)
	if err != nil {
		return nil, err
	}
	s.historyMu.Lock()
	if len(s.historyCache) >= 256 {
		for cacheKey, item := range s.historyCache {
			if now.After(item.expiresAt) {
				delete(s.historyCache, cacheKey)
			}
		}
		if len(s.historyCache) >= 256 {
			for cacheKey := range s.historyCache {
				delete(s.historyCache, cacheKey)
				break
			}
		}
	}
	s.historyCache[key] = cachedSlackHistory{
		messages:  append([]slackui.HistoryMessage(nil), messages...),
		expiresAt: now.Add(5 * time.Minute),
	}
	s.historyMu.Unlock()
	return messages, nil
}

func (s *Service) invalidateSlackHistory(channelID string) {
	if channelID == "" {
		return
	}
	prefix := channelID + "\x00"
	s.historyMu.Lock()
	defer s.historyMu.Unlock()
	for key := range s.historyCache {
		if strings.HasPrefix(key, prefix) {
			delete(s.historyCache, key)
		}
	}
}

func historyWatchContext(
	history []slackui.HistoryMessage,
	channelID string,
	botUserID string,
) []watchContextMessage {
	inputs := make([]core.SlackInput, 0, len(history))
	for _, message := range history {
		kind := "message"
		userID := message.UserID
		if message.BotID != "" {
			kind = "bot_message"
			if userID == "" {
				userID = message.BotID
			}
		}
		inputs = append(inputs, core.SlackInput{
			Kind: kind, ChannelID: channelID, ThreadTS: message.ThreadTS,
			MessageTS: message.Timestamp, UserID: userID, Text: message.Text,
			Reactions: coreSlackReactions(message.Reactions),
		})
	}
	slices.SortFunc(inputs, func(left, right core.SlackInput) int {
		switch {
		case left.MessageTS < right.MessageTS:
			return -1
		case left.MessageTS > right.MessageTS:
			return 1
		default:
			return 0
		}
	})
	result := make([]watchContextMessage, 0, len(inputs))
	for _, input := range inputs {
		result = append(result, watchPromptMessage(input, botUserID, false))
	}
	return result
}

func coreSlackReactions(reactions []slackui.HistoryReaction) []core.SlackReaction {
	result := make([]core.SlackReaction, 0, len(reactions))
	for _, reaction := range reactions {
		result = append(result, core.SlackReaction{
			Name: reaction.Name, Count: reaction.Count,
			UserIDs: append([]string(nil), reaction.UserIDs...),
		})
	}
	return result
}

func decodeAssembledAgentContext(data []byte) (assembledAgentContext, bool) {
	if len(data) == 0 || string(data) == "{}" {
		return assembledAgentContext{}, false
	}
	var result assembledAgentContext
	if err := json.Unmarshal(data, &result); err != nil ||
		result.CapturedAt.IsZero() {
		return assembledAgentContext{}, false
	}
	return result, true
}

func mergeSlackContext(
	admitted []core.SlackInput,
	history []slackui.HistoryMessage,
	target core.SlackInput,
	limit int,
) []core.SlackInput {
	byTimestamp := make(map[string]core.SlackInput, len(admitted)+len(history)+1)
	for _, input := range admitted {
		if input.MessageTS != "" && sameSlackConversation(input, target) {
			byTimestamp[input.MessageTS] = input
		}
	}
	for _, message := range history {
		if message.Timestamp == "" {
			continue
		}
		kind := "message"
		userID := message.UserID
		if message.BotID != "" {
			kind = "bot_message"
			if userID == "" {
				userID = message.BotID
			}
		}
		if _, exists := byTimestamp[message.Timestamp]; !exists {
			attachments := make([]core.SlackAttachment, 0, len(message.Files))
			for _, file := range message.Files {
				attachments = append(attachments, core.SlackAttachment{
					ID: file.ID, Name: file.Name, MediaType: file.MediaType,
					Size: file.Size, URLPrivate: file.URLPrivate,
				})
			}
			byTimestamp[message.Timestamp] = core.SlackInput{
				Kind: kind, ChannelID: target.ChannelID,
				ThreadTS: message.ThreadTS, MessageTS: message.Timestamp,
				UserID: userID, Text: message.Text, Attachments: attachments,
				Reactions: coreSlackReactions(message.Reactions),
			}
		}
	}
	if target.MessageTS != "" {
		byTimestamp[target.MessageTS] = target
	}
	result := make([]core.SlackInput, 0, len(byTimestamp))
	for _, input := range byTimestamp {
		result = append(result, input)
	}
	slices.SortFunc(result, func(left, right core.SlackInput) int {
		switch {
		case left.MessageTS < right.MessageTS:
			return -1
		case left.MessageTS > right.MessageTS:
			return 1
		case left.ReceivedAt.Before(right.ReceivedAt):
			return -1
		case left.ReceivedAt.After(right.ReceivedAt):
			return 1
		default:
			return 0
		}
	})
	return targetCenteredSlackContext(result, target, limit)
}

func sameSlackConversation(input core.SlackInput, target core.SlackInput) bool {
	if target.ThreadTS == "" {
		return input.ThreadTS == ""
	}
	return input.ThreadTS == target.ThreadTS || input.MessageTS == target.ThreadTS
}

func targetCenteredSlackContext(
	inputs []core.SlackInput,
	target core.SlackInput,
	limit int,
) []core.SlackInput {
	if limit < 1 || len(inputs) <= limit {
		return inputs
	}
	targetIndex := -1
	rootIndex := -1
	for index := range inputs {
		if inputs[index].MessageTS == target.MessageTS {
			targetIndex = index
		}
		if target.ThreadTS != "" && inputs[index].MessageTS == target.ThreadTS {
			rootIndex = index
		}
	}
	if targetIndex < 0 {
		return slices.Clone(inputs[len(inputs)-limit:])
	}
	selected := make(map[int]struct{}, limit)
	selected[targetIndex] = struct{}{}
	if rootIndex >= 0 {
		selected[rootIndex] = struct{}{}
	}
	following := min(3, len(inputs)-targetIndex-1)
	for index := targetIndex + 1; index <= targetIndex+following && len(selected) < limit; index++ {
		selected[index] = struct{}{}
	}
	for index := targetIndex - 1; index >= 0 && len(selected) < limit; index-- {
		selected[index] = struct{}{}
	}
	for index := targetIndex + following + 1; index < len(inputs) && len(selected) < limit; index++ {
		selected[index] = struct{}{}
	}
	result := make([]core.SlackInput, 0, len(selected))
	for index, input := range inputs {
		if _, ok := selected[index]; ok {
			result = append(result, input)
		}
	}
	return result
}
