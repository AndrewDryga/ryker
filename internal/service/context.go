package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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
	if request.IncludeRecent && request.TargetInput != nil {
		recent, err := s.store.ListRecentWatchMessages(
			ctx,
			request.ChannelID,
			s.cfg.Slack.WatchContext,
		)
		if err != nil {
			return assembledAgentContext{}, err
		}
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
