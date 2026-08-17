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
	signature := alertstream.SignatureOf(decision, input.Text)
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
		Signature:     alertstream.SignatureOf(decision, input.Text),
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

// openStreamTaskOffer finds an offer already made for this work that nobody has
// accepted and that is still reachable — first in this stream, then anywhere in
// this channel.
//
// The stream comes first because it is the cheaper question and the better
// answer: an offer in this same thread is the one an operator reading this
// thread can see. The channel is asked only when the stream has nothing,
// because one stream is not what a channel remembers — the sixth identical
// Traefik offer of 2026-08-16 came from the 15:00 whole-platform review, in
// another thread, and A4 could not see it from here.
func (s *Service) openStreamTaskOffer(
	ctx context.Context,
	input core.SlackInput,
	episodeID string,
	repository string,
	title string,
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
	offer, found, err := s.firstOpenOffer(
		ctx, input, alertstream.OpenOfferCandidates(replies, repository, input.ID),
	)
	if err != nil || found {
		return offer, found, err
	}
	return s.openChannelTaskOffer(ctx, input, episodeID, repository, title)
}

// openChannelTaskOffer finds the same fix already on offer from another episode
// in this channel.
//
// Same repository AND the same fix, because a channel's other episodes are
// other situations: the repository alone is the test inside one stream and would
// hide unrelated work here. The window is the alert stream's own — the span over
// which the host already treats a channel as still living through one
// operational situation — so the same configuration that decides "this card
// continues that episode" decides "that offer is still what we are talking
// about". A separate constant would be a second clock for the same idea, and the
// deployed six hours covers the real case: the day's last stream offer was at
// 10:04 and the review repeated it at 15:00.
func (s *Service) openChannelTaskOffer(
	ctx context.Context,
	input core.SlackInput,
	episodeID string,
	repository string,
	title string,
) (openTaskOffer, bool, error) {
	window := s.cfg.Slack.AlertStreamOpenWindow.Duration
	if window <= 0 || strings.TrimSpace(title) == "" {
		return openTaskOffer{}, false, nil
	}
	payloads, err := s.store.AlertStream.RepliesPostedInChannel(
		ctx, input.ChannelID, episodeID, s.now().UTC().Add(-window), 20,
	)
	if err != nil {
		return openTaskOffer{}, false, err
	}
	replies, unreadable := alertstream.DecodeReplies(payloads)
	if unreadable > 0 {
		s.log.Warn(
			"decode what this channel already offered",
			"channel", input.ChannelID, "unreadable", unreadable,
		)
	}
	return s.firstOpenOffer(
		ctx, input,
		alertstream.SameFixCandidates(replies, repository, title, input.ID),
	)
}

// firstOpenOffer returns the first of these offers that is still open.
//
// Open means all of it. An accepted offer is a closed question, and the reply
// after it should say what the task is doing rather than offer it again; an
// offer whose reply never reached Slack has no button at all; and a reply that
// landed in another channel is a message the operator reading this one may not
// even be able to open. Each of those would send them somewhere that does not
// answer, which is worse than a second button.
func (s *Service) firstOpenOffer(
	ctx context.Context,
	input core.SlackInput,
	candidates []alertstream.ReplyPosted,
) (openTaskOffer, bool, error) {
	for _, posted := range candidates {
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
		if reply.ChannelID != "" && reply.ChannelID != input.ChannelID {
			continue
		}
		return openTaskOffer{
			Title:     posted.OfferTitle,
			Permalink: exactSlackMessageLink(input, reply.MessageTS),
		}, true, nil
	}
	return openTaskOffer{}, false, nil
}

// streamWasLive reports whether this episode has already told the channel the
// alert was a real, current problem.
//
// It is the question a recovery has to answer before the host holds its episode
// open: a stream that was live is a conversation the next firing continues, and
// a stream that never was is a card saying nothing is wrong. Read from the
// episode's own posted answers rather than from its evidence, because what was
// SAID is what a re-fire would be continuing.
func (s *Service) streamWasLive(ctx context.Context, episodeID string) (bool, error) {
	// Twenty, on the same reasoning as the offer walk above: this reads one
	// stream's own answers, and a stream that fires all day is one episode.
	replies, err := s.postedStreamReplies(ctx, episodeID, 20)
	if err != nil {
		return false, err
	}
	for _, posted := range replies {
		switch strings.TrimSpace(posted.Verdict) {
		case "confirmed_issue", "likely_issue":
			return true, nil
		}
	}
	return false, nil
}

// foldedIntoAnsweredStream reports whether this card was already answered by
// the reply this stream posted while the card was waiting its turn, and the
// sentence the audit should carry when it was.
//
// A1 stopped a newer card destroying the investigation in flight, and A3
// stopped its answer being posted twice — but the turn was still spent. The
// second card was leased, briefed, submitted, answered, and only then compared
// and suppressed, so the 2026-08-16 va1-nomad-oom-risk stream paid for six
// investigations of a condition the first had established.
//
// The host can see for itself when a card says nothing new, but only from what
// the card states about itself: the bracketed marker's firing and resolved
// counts. Everything else about "is this the same news" is the model's judgment
// and stays there. Three conditions, each closing a way this could suppress
// real news:
//
//   - the card carries a marker at all. A Terraform run notification and a
//     Better Stack alert both read 0 and 0, and folding on that would make
//     "Run Applied" and "Run Errored" the same card.
//   - its counts equal the answered card's. A third allocation crossing the
//     line is the fact an operator is watching; the comparator was taught that
//     on 2026-08-16 and this must not take it back.
//   - the answer was posted after this card arrived. Otherwise the card is
//     newer than the answer in every sense and nobody has looked at it.
func (s *Service) foldedIntoAnsweredStream(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
) (bool, string, error) {
	if input.Kind != "bot_message" || isPrivateSlackVerificationReplay(input) ||
		run.EpisodeID == "" || !strings.HasPrefix(run.ConversationKey, "operation:") {
		return false, "", nil
	}
	firing, resolved := alertstream.AlertCounts(input.Text)
	if firing == 0 && resolved == 0 {
		return false, "", nil
	}
	posted, err := s.latestStreamReply(ctx, run.EpisodeID)
	if err != nil || posted == nil {
		return false, "", err
	}
	if posted.Signature.Firing != firing || posted.Signature.Resolved != resolved {
		return false, "", nil
	}
	// Compared at the archived precision, not the wire's. PostedAt is written as
	// RFC3339 seconds while an input's ReceivedAt carries nanoseconds, so a
	// strict After() answers "no" for everything that happened inside the same
	// second — invisible in production, where the gap is minutes, and exactly
	// the kind of nothing that makes a rule fire only where it was measured.
	postedAt, err := time.Parse(time.RFC3339, posted.PostedAt)
	if err != nil || postedAt.Before(input.ReceivedAt.Truncate(time.Second)) {
		return false, "", nil
	}
	return true, "answered by this stream's reply to " + posted.SourceInputID, nil
}
