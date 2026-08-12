package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/AndrewDryga/responder/internal/agentcontext"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/recall"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

type agentContextRequest struct {
	ChannelID           string
	Repository          string
	RepositoryPinned    bool
	OperatorID          string
	SourceInputID       string
	TargetInput         *core.SlackInput
	ReferencedChannelID string
	ReferencedThreadTS  string
	ReferencedMessageTS string
	IncludeRecent       bool
}

type assembledAgentContext struct {
	Repository                    string                                     `json:"repository"`
	Prior                         decisionpkg.OperationalMemoryContext       `json:"prior_operational_context,omitempty"`
	Situation                     core.AgentMemory                           `json:"conversation_situation,omitempty"`
	RelatedSituations             []decisionpkg.ConversationSituationContext `json:"related_situations,omitempty"`
	RecentMessages                []decisionpkg.WatchContextMessage          `json:"recent_messages_around_target,omitempty"`
	ReferencedThread              *decisionpkg.ReferencedThreadContext       `json:"referenced_thread,omitempty"`
	InitialTaskChangesFingerprint string                                     `json:"initial_task_changes_fingerprint,omitempty"`
	// StructuredCorrections counts how many times this run has been sent back
	// to the model because its result could not be read. The watch path has
	// always had this; incident and engineering-task runs did not, so a single
	// malformed response ended the turn and showed the operator a parse error.
	StructuredCorrections int `json:"structured_corrections,omitempty"`
	// ReplyShapeCorrections counts the reply-shape rewrites this run has been
	// asked for. Separate from the count above because it has its own budget:
	// exactly one, after which the answer is posted as written.
	ReplyShapeCorrections int       `json:"reply_shape_corrections,omitempty"`
	CapturedAt            time.Time `json:"captured_at"`
}

func (s *Service) assembleAgentContext(
	ctx context.Context,
	request agentContextRequest,
) (assembledAgentContext, error) {
	memoryQuery := recall.QueryText(request.TargetInput)
	repository := request.Repository
	var err error
	if !request.RepositoryPinned {
		repository, err = s.effectiveRepository(
			ctx,
			request.ChannelID,
			request.OperatorID,
			request.Repository,
		)
	}
	if err != nil {
		return assembledAgentContext{}, err
	}
	prior, err := s.loadOperationalMemoryContext(
		ctx,
		request.ChannelID,
		repository,
		request.OperatorID,
		request.SourceInputID,
		memoryQuery,
	)
	if err != nil {
		return assembledAgentContext{}, err
	}
	result := assembledAgentContext{
		Repository: repository,
		Prior:      prior,
		CapturedAt: s.now().UTC(),
	}
	sinceTS := ""
	if request.ChannelID != "" {
		memory, memoryErr := s.store.Intelligence.GetChannelMemory(ctx, request.ChannelID)
		if memoryErr == nil {
			result.Situation = memory.State
		} else if !errors.Is(memoryErr, store.ErrNotFound) {
			return assembledAgentContext{}, memoryErr
		}
		threadTS := ""
		if request.TargetInput != nil {
			threadTS = request.TargetInput.ThreadTS
			conversation, conversationErr := s.store.Intelligence.GetConversationMemory(
				ctx,
				request.ChannelID,
				threadTS,
			)
			if conversationErr == nil {
				result.Situation = conversation.State
				sinceTS = conversation.LastMessage
				s.markRecalled(ctx, []core.ConversationMemory{conversation})
			} else if !errors.Is(conversationErr, store.ErrNotFound) {
				return assembledAgentContext{}, conversationErr
			}
			// A thread with no memory of its own keeps the channel's.
			//
			// This used to zero the situation loaded twenty lines above, so the
			// first reply in every new thread started blind — in the channel
			// where Responder had been working all day, on a question that was
			// usually a follow-up to it. A thread lives in its channel and is
			// read by the same people, so there is no audience the channel
			// summary could leak to that the thread does not already have.
			//
			// The conversation memory still wins when it exists: it is the same
			// channel seen closer up, and it carries the last-message cursor.
		}
		related, relatedErr := s.store.Intelligence.ListRelatedConversationMemories(
			ctx,
			request.ChannelID,
			threadTS,
			repository,
			40,
		)
		if relatedErr != nil {
			return assembledAgentContext{}, relatedErr
		}
		related = recall.SelectConversationMemories(related, memoryQuery, 6)
		s.markRecalled(ctx, related)
		result.RelatedSituations = make(
			[]decisionpkg.ConversationSituationContext,
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
				decisionpkg.ConversationSituationContext{
					ChannelID: item.ChannelID, ChannelName: item.ChannelName,
					ThreadTS:   item.ThreadTS,
					Repository: item.Repository, Relationship: relationship,
					Summary:   memorypkg.SanitizeMemory(item.State),
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
	referencedChannelID := core.FirstNonempty(request.ReferencedChannelID, request.ChannelID)
	if request.ReferencedThreadTS != "" &&
		(request.TargetInput == nil || referencedChannelID != request.ChannelID ||
			request.ReferencedThreadTS != request.TargetInput.ThreadTS) {
		referenced := &decisionpkg.ReferencedThreadContext{
			ThreadTS: request.ReferencedThreadTS,
		}
		conversation, conversationErr := s.store.Intelligence.GetConversationMemory(
			ctx,
			referencedChannelID,
			request.ReferencedThreadTS,
		)
		if conversationErr == nil {
			referenced.LastMessageTS = conversation.LastMessage
			referenced.Summary = memorypkg.SanitizeMemory(conversation.State)
			if err := s.store.Memory.MarkConversationMemoriesRecalled(
				ctx, []core.ConversationMemory{conversation},
			); err != nil {
				return assembledAgentContext{}, err
			}
		} else if !errors.Is(conversationErr, store.ErrNotFound) {
			return assembledAgentContext{}, conversationErr
		}
		targetTS := request.ReferencedMessageTS
		if targetTS == "" {
			targetTS = referenced.LastMessageTS
		}
		history, historyErr := s.recentMessages(
			ctx,
			referencedChannelID,
			request.ReferencedThreadTS,
			targetTS,
			"",
			s.cfg.Slack.WatchContext,
		)
		if historyErr != nil {
			return assembledAgentContext{}, fmt.Errorf(
				"read linked Slack thread %s/%s: %w",
				referencedChannelID, request.ReferencedThreadTS, historyErr,
			)
		}
		referenced.RecentMessages = historyWatchContext(
			history,
			referencedChannelID,
			s.identity.BotUserID,
		)
		result.ReferencedThread = referenced
	}
	return result, nil
}

// markRecalled records that conversation memories were used. It is telemetry
// for the review queue, so a failed write is logged and the turn continues:
// losing a counter must not cost the model its context.
func (s *Service) markRecalled(ctx context.Context, items []core.ConversationMemory) {
	if len(items) == 0 {
		return
	}
	if err := s.store.Memory.MarkConversationMemoriesRecalled(ctx, items); err != nil && ctx.Err() == nil {
		s.log.Warn("record conversation memory recall", "memories", len(items), "error", err)
	}
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
	now := s.now()
	if cached, ok := s.historyCache.Get(key, now); ok {
		return cached, nil
	}
	messages, err := s.slack.RecentMessages(
		ctx, channelID, threadTS, targetTS, sinceTS, limit,
	)
	if err != nil {
		return nil, err
	}
	s.historyCache.Put(key, messages, now)
	return messages, nil
}

func (s *Service) invalidateSlackHistory(channelID string) {
	if channelID == "" {
		return
	}
	s.historyCache.InvalidateChannel(channelID)
}

func historyWatchContext(
	history []slackui.HistoryMessage,
	channelID string,
	botUserID string,
) []decisionpkg.WatchContextMessage {
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
			Reactions: agentcontext.Reactions(message.Reactions),
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
	result := make([]decisionpkg.WatchContextMessage, 0, len(inputs))
	for _, input := range inputs {
		result = append(result, watchPromptMessage(input, botUserID, false))
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
	return agentcontext.MergeSlackContext(admitted, history, target, limit)
}
