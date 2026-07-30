package service

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

type agentContextRequest struct {
	ChannelID     string
	Repository    string
	OperatorID    string
	SourceInputID string
	TargetInput   *core.SlackInput
	IncludeRecent bool
}

type assembledAgentContext struct {
	Repository     string                   `json:"repository"`
	Prior          operationalMemoryContext `json:"prior_operational_context,omitempty"`
	Situation      core.AgentMemory         `json:"channel_situation,omitempty"`
	RecentMessages []watchContextMessage    `json:"recent_channel_messages,omitempty"`
	CapturedAt     time.Time                `json:"captured_at"`
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
	if request.ChannelID != "" {
		memory, memoryErr := s.store.GetChannelMemory(ctx, request.ChannelID)
		if memoryErr == nil {
			result.Situation = memory.State
		} else if !errors.Is(memoryErr, store.ErrNotFound) {
			return assembledAgentContext{}, memoryErr
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
			s.cfg.Slack.WatchContext,
		)
		if err != nil {
			return assembledAgentContext{}, err
		}
		recent := mergeSlackContext(admitted, history, *request.TargetInput)
		result.RecentMessages = makeWatchContext(
			recent,
			*request.TargetInput,
			s.identity.BotUserID,
		)
	}
	return result, nil
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
) []core.SlackInput {
	byTimestamp := make(map[string]core.SlackInput, len(admitted)+len(history)+1)
	for _, input := range admitted {
		if input.MessageTS != "" {
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
			byTimestamp[message.Timestamp] = core.SlackInput{
				Kind: kind, ChannelID: target.ChannelID,
				ThreadTS: message.ThreadTS, MessageTS: message.Timestamp,
				UserID: userID, Text: message.Text,
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
	return result
}
