package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/alertstream"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store"
)

// What one alert stream has already said, and what that means for the next card
// on it.
//
// A Grafana stream posted seven cards for one Traefik memory alert in ninety
// minutes on 2026-08-16 and drew five replies into the same thread, each
// restating that all five allocations sat near the 4 GiB cap and each ending
// with the same engineering offer. Two of them said only that a node had
// crossed back over the line, and a sixth identical offer arrived from a
// scheduled review in another thread. The prompt asked for silence unless
// something changed and never said what "unchanged" meant; the host forbade the
// silence anyway; and nothing on either side compared a new answer with the one
// already posted.
//
// So the episode now carries what each answer DECIDED, the model is told what
// it already said, and the host refuses to post a decision it has already
// posted. Everything below is that record and those two questions.

// postedStreamReplies reads what this episode has already answered, newest
// first.
func (s *Service) postedStreamReplies(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]alertstream.ReplyPosted, error) {
	if strings.TrimSpace(episodeID) == "" {
		return nil, nil
	}
	payloads, err := s.store.AlertStream.RepliesPosted(ctx, episodeID, limit)
	if err != nil {
		return nil, err
	}
	replies, unreadable := alertstream.DecodeReplies(payloads)
	if unreadable > 0 {
		s.log.Warn(
			"decode what this alert stream already answered",
			"episode", episodeID, "unreadable", unreadable,
		)
	}
	return replies, nil
}

// latestStreamReply is the last answer this episode posted, or nil when it has
// posted none.
func (s *Service) latestStreamReply(
	ctx context.Context,
	episodeID string,
) (*alertstream.ReplyPosted, error) {
	replies, err := s.postedStreamReplies(ctx, episodeID, 1)
	if err != nil || len(replies) == 0 {
		return nil, err
	}
	return &replies[0], nil
}

// captureAnsweredStream carries what this stream already said into the turn
// state, so the model can be told and the correction can allow silence.
//
// A terminal predecessor still counts inside the stream's open window: a
// recovery closes the episode, and a card arriving minutes later is the same
// conversation to everyone reading the channel. Past the window it is a new
// alert and gets a new answer.
func (s *Service) captureAnsweredStream(
	ctx context.Context,
	previous core.WorkEpisode,
	state *decisionpkg.WatchTurnState,
) error {
	if episodepkg.Terminal(previous.State) {
		window := s.cfg.Slack.AlertStreamOpenWindow.Duration
		if window <= 0 || previous.CompletedAt.IsZero() ||
			s.now().UTC().Sub(previous.CompletedAt.UTC()) > window {
			return nil
		}
	}
	posted, err := s.latestStreamReply(ctx, previous.ID)
	if err != nil || posted == nil {
		return err
	}
	state.StreamAnsweredAt = posted.PostedAt
	state.StreamAnsweredVerdict = posted.Verdict
	state.StreamAnsweredAction = posted.Action
	return nil
}

// alertReplyRepeats compares an alert reply with the last one this stream
// posted: true when the decision is the same one, otherwise a one-line note of
// what moved.
//
// Only for an app's card on an operational stream. A human asking the same
// question twice is owed an answer twice; an alert crossing the same threshold
// twice is not.
func (s *Service) alertReplyRepeats(
	ctx context.Context,
	input core.SlackInput,
	run core.AgentRun,
	decision decisionpkg.WatchDecision,
) (bool, string, error) {
	if decision.Action != "reply" || input.Kind != "bot_message" ||
		run.EpisodeID == "" || !strings.HasPrefix(run.ConversationKey, "operation:") {
		return false, "", nil
	}
	previous, err := s.latestStreamReply(ctx, run.EpisodeID)
	if err != nil || previous == nil {
		return false, "", err
	}
	signature := alertstream.SignatureOf(decision)
	if signature.Equal(previous.Signature) {
		return true, "", nil
	}
	return false, signature.Change(previous.Signature), nil
}

// recordAlertReplyPosted puts what an answer decided on its episode, after it
// has been written to the outbox.
//
// The offer it records is the one the click handler will act on — the title and
// repository persisted on the run context — rather than the one the model
// named, because those are the same only after the host has resolved it.
func (s *Service) recordAlertReplyPosted(
	ctx context.Context,
	input core.SlackInput,
	decision decisionpkg.WatchDecision,
	run core.AgentRun,
) error {
	if input.Kind != "bot_message" || run.EpisodeID == "" ||
		!strings.HasPrefix(run.ConversationKey, "operation:") {
		return nil
	}
	posted := alertstream.ReplyPosted{
		Signature:     alertstream.SignatureOf(decision),
		SourceInputID: input.ID,
		PostedAt:      s.now().UTC().Format(time.RFC3339),
	}
	if decision.AlertAssessment != nil {
		posted.Verdict = strings.TrimSpace(decision.AlertAssessment.Verdict)
		posted.Action = TruncateWatchText(
			strings.TrimSpace(decision.AlertAssessment.ImmediateAction), 200,
		)
	}
	if offered, err := s.store.GetAgentRunBySource(ctx, "watch", input.ID); err == nil {
		if state, decodeErr := decodeWatchRunContext(offered); decodeErr == nil {
			posted.OfferTitle = state.OfferedTaskTitle
			posted.OfferRepository = state.OfferedTaskRepository
			posted.DeliveryID = state.ReplyDeliveryID
		}
	}
	posted.DeliveryID = executionDeliveryID(
		core.FirstNonempty(posted.DeliveryID, "watch_reply_"+input.ID),
		run.IdempotencyKey,
	)
	payload, err := json.Marshal(posted)
	if err != nil {
		return err
	}
	_, err = s.store.AppendWorkEpisodeEvent(ctx, run.ID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventReplyPosted, Actor: "host",
		IdempotencyKey: "reply_posted:" + run.ID, Payload: payload,
	})
	return err
}

// openTaskOffer is an engineering task this stream has already put a button on,
// and where that button is.
type openTaskOffer struct {
	Title     string
	Permalink string
}

// openStreamTaskOffer finds an offer this stream has already made in the same
// repository that nobody has accepted and that is still reachable.
//
// Open means both halves. An accepted offer is a closed question, and the reply
// after it should say what the task is doing rather than offer it again; an
// offer whose reply never reached Slack has no button at all, so pointing at it
// would send an operator to a message that does not exist.
func (s *Service) openStreamTaskOffer(
	ctx context.Context,
	input core.SlackInput,
	episodeID string,
	repository string,
) (openTaskOffer, bool, error) {
	if input.Kind != "bot_message" || episodeID == "" ||
		!strings.HasPrefix(watchConversationKey(input), "operation:") {
		return openTaskOffer{}, false, nil
	}
	// Twenty, because this walks one stream's own answers and a stream that
	// fires all day is one episode. The offer being repeated is by construction
	// a recent one.
	replies, err := s.postedStreamReplies(ctx, episodeID, 20)
	if err != nil {
		return openTaskOffer{}, false, err
	}
	for _, posted := range alertstream.OpenOfferCandidates(
		replies, repository, input.ID,
	) {
		accepted, err := s.store.AlertStream.EngineeringTaskExistsForSource(
			ctx, posted.SourceInputID,
		)
		if err != nil {
			return openTaskOffer{}, false, err
		}
		if accepted {
			continue
		}
		reply, err := s.store.AlertStream.SentReplyForInput(ctx, posted.SourceInputID)
		if errors.Is(err, store.ErrNotFound) {
			continue
		}
		if err != nil {
			return openTaskOffer{}, false, err
		}
		return openTaskOffer{
			Title:     posted.OfferTitle,
			Permalink: exactSlackMessageLink(input, reply.MessageTS),
		}, true, nil
	}
	return openTaskOffer{}, false, nil
}
