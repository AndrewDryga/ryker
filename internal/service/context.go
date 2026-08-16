package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/AndrewDryga/responder/internal/agentcontext"
	"github.com/AndrewDryga/responder/internal/changeledger"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
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
	// Effort gates episode recall. Only an assessment or an investigation is
	// helped by what a past incident turned out to be.
	Effort core.EffortContract
	// AlertGroupKey is the firing alert's stable identity when the turn has
	// one, and the strongest signal recall has.
	AlertGroupKey string
	// RecallText is what to recall against when there is no Slack message to
	// read it from, which is every escalated incident.
	RecallText string
	// ExcludeEpisodeID keeps an episode from recalling itself.
	ExcludeEpisodeID string
	// AlertSignals are the firing alerts behind an escalated incident, carried
	// for their labels: an alert that names its service is the difference
	// between recalling that service's deploys and recalling the repository's.
	AlertSignals []core.Signal
}

type assembledAgentContext struct {
	Repository          string                                     `json:"repository"`
	Prior               decisionpkg.OperationalMemoryContext       `json:"prior_operational_context,omitempty"`
	Situation           core.AgentMemory                           `json:"conversation_situation,omitempty"`
	RelatedSituations   []decisionpkg.ConversationSituationContext `json:"related_situations,omitempty"`
	RecentMessages      []decisionpkg.WatchContextMessage          `json:"recent_messages_around_target,omitempty"`
	ChannelAroundRoot   []decisionpkg.WatchContextMessage          `json:"channel_messages_around_thread_root,omitempty"`
	ReferencedThread    *decisionpkg.ReferencedThreadContext       `json:"referenced_thread,omitempty"`
	SimilarPastEpisodes []core.SimilarEpisode                      `json:"similar_past_episodes,omitempty"`
	// RelatedTasks is the engineering work this channel has already opened.
	// Recall answers "what did this turn out to be last time"; this answers
	// "did somebody already write the fix", which is a different question and
	// was the one nothing could ask.
	RelatedTasks                  []core.RelatedTask  `json:"related_engineering_tasks,omitempty"`
	RecentChanges                 []core.RecentChange `json:"recent_changes,omitempty"`
	InitialTaskChangesFingerprint string              `json:"initial_task_changes_fingerprint,omitempty"`
	// StructuredCorrections counts how many times this run has been sent back
	// to the model because its result could not be read. The watch path has
	// always had this; incident and engineering-task runs did not, so a single
	// malformed response ended the turn and showed the operator a parse error.
	StructuredCorrections int `json:"structured_corrections,omitempty"`
	// ReplyShapeCorrections counts the reply-shape rewrites this run has been
	// asked for. Separate from the count above because it has its own budget:
	// exactly one, after which the answer is posted as written.
	ReplyShapeCorrections int `json:"reply_shape_corrections,omitempty"`
	// CorrectionClasses counts the corrections this run has had of each class,
	// and MinTargetIndex is the rung of the session policy's target ladder its
	// next turn may not be answered below. Both are written by the store, which
	// edits the envelope as raw fields; they are declared here because this
	// struct is re-encoded whole by the correction paths, and a field it does
	// not name would be dropped on the next round.
	CorrectionClasses map[string]int `json:"correction_classes,omitempty"`
	MinTargetIndex    int            `json:"min_target_index,omitempty"`
	CapturedAt        time.Time      `json:"captured_at"`
	// CarriedEvidence and CarriedCoverage are this run's accepted rows, the
	// incident-side half of decision.CarryEvidence: a correction round returns
	// only the operations the correction named, and nothing persists what the
	// rounds before it established.
	CarriedEvidence []core.Evidence `json:"carried_evidence,omitempty"`
	CarriedCoverage []core.Coverage `json:"carried_coverage,omitempty"`
	// CarriedFindings is the same for typed findings, and it matters more than
	// either: an unexplained finding refuses the completion, so a round that
	// dropped one would be judged as having discovered nothing at all.
	CarriedFindings []investigation.FindingOperation `json:"carried_findings,omitempty"`
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
	request.Repository = repository
	result := assembledAgentContext{
		Repository:          repository,
		Prior:               prior,
		SimilarPastEpisodes: s.similarPastEpisodes(ctx, request, memoryQuery+" "+request.RecallText, prior),
		RelatedTasks:        s.relatedEngineeringTasks(ctx, request),
		RecentChanges:       s.recentChanges(ctx, request, prior),
		CapturedAt:          s.now().UTC(),
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
		if request.TargetInput.ThreadTS != "" {
			result.ChannelAroundRoot = s.channelAroundThreadRoot(
				ctx,
				request.ChannelID,
				request.TargetInput.ThreadTS,
				recent,
			)
		}
	}
	referencedChannelID := core.FirstNonempty(request.ReferencedChannelID, request.ChannelID)
	if request.ReferencedThreadTS != "" &&
		(request.TargetInput == nil || referencedChannelID != request.ChannelID ||
			request.ReferencedThreadTS != request.TargetInput.ThreadTS) {
		referenced := &decisionpkg.ReferencedThreadContext{
			ThreadTS:  request.ReferencedThreadTS,
			ChannelID: referencedChannelID,
			Elsewhere: referencedChannelID != request.ChannelID,
		}
		conversation, conversationErr := s.store.Intelligence.GetConversationMemory(
			ctx,
			referencedChannelID,
			request.ReferencedThreadTS,
		)
		if conversationErr == nil {
			referenced.LastMessageTS = conversation.LastMessage
			referenced.ChannelName = conversation.ChannelName
			referenced.Summary = memorypkg.SanitizeMemory(conversation.State)
			if err := s.store.Memory.MarkConversationMemoriesRecalled(
				ctx, []core.ConversationMemory{conversation},
			); err != nil {
				return assembledAgentContext{}, err
			}
		} else if !errors.Is(conversationErr, store.ErrNotFound) {
			return assembledAgentContext{}, conversationErr
		}
		// Falls back to the membership roster, because a thread Responder has
		// never summarised has no conversation memory to carry the name — and
		// that is exactly the case a cross-channel link creates.
		if referenced.ChannelName == "" {
			name, nameErr := s.store.SlackChannelName(ctx, referencedChannelID)
			if nameErr != nil {
				return assembledAgentContext{}, nameErr
			}
			referenced.ChannelName = name
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

// recentChanges reads what changed recently to anything this turn implicates.
//
// Everything interesting is in internal/changeledger — the window, the scope
// resolution, the ranking, the prompt text, the effort gate. What stays here is
// the store handle and the two configuration values, because those are the only
// parts that need a Service. A failed read is logged and the turn continues.
func (s *Service) recentChanges(
	ctx context.Context,
	request agentContextRequest,
	prior decisionpkg.OperationalMemoryContext,
) []core.RecentChange {
	changes, err := changeledger.Read(ctx, s.store.Changes, changeledger.Turn{
		Repository: request.Repository, Signals: request.AlertSignals,
		Evidence: prior.RecentEvidence, Effort: request.Effort, Now: s.now().UTC(),
		Window: s.cfg.Limits.ChangeWindow.Duration, Limit: s.cfg.Limits.MaxRecentChanges,
	})
	if err != nil && ctx.Err() == nil {
		s.log.Warn("read the change ledger", "channel", request.ChannelID, "error", err)
	}
	return changes
}

// channelAroundThreadRoot reads the channel-level messages sitting around a
// thread's root — the ones a person scrolling above the thread sees, and the
// ones a thread turn never could.
//
// A turn inside a thread fetches conversations.replies, which is the thread and
// nothing else, so "see in the channel above", "^", and answering a bot notice
// that said "reply in this thread" all pointed at messages that were not in the
// prompt. On 2026-08-13 in #infra-alerts that cost a turn: the thread root was a
// bare mention with no text, the referent was the alert directly above it at
// channel level, and the model correctly reported it could not see what it was
// being pointed at.
//
// It is deliberately a second read carried in its own field rather than a merge
// into the recent transcript: the in-thread transcript is captured once and
// deduplicated against the resolved mention, and channel-level messages have no
// business inside either rule.
//
// A failed read returns nothing rather than failing the turn. The surround is an
// addition to what a thread turn already had, so losing it must cost no more
// than the answer this code was written to improve.
func (s *Service) channelAroundThreadRoot(
	ctx context.Context,
	channelID string,
	rootTS string,
	inThread []core.SlackInput,
) []decisionpkg.WatchContextMessage {
	history, err := s.recentMessages(
		ctx, channelID, "", rootTS, "", s.cfg.Slack.WatchContext,
	)
	if err != nil {
		if ctx.Err() == nil {
			s.log.Warn(
				"read the channel around a thread root",
				"channel", channelID, "thread", rootTS, "error", err,
			)
		}
		return nil
	}
	return historyWatchContext(
		agentcontext.AroundThreadRoot(history, rootTS, inThread),
		channelID,
		s.identity.BotUserID,
	)
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
		result = append(result, WatchPromptMessage(input, botUserID, false))
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
