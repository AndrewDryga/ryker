package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/core"
)

// pausedReaction marks a message Responder has not answered yet.
//
// A pause, not a cross: the work is still queued and will be tried again. It
// says "not yet" to the channel without saying anything the channel has to read.
const pausedReaction = "double_vertical_bar"

// markInputPaused reacts to the message instead of posting a failure.
//
// Responder used to post "Responder could not complete this check. Coop ended
// the agent turn before it produced a usable response." into the channel. That
// is an error about Responder's own plumbing, addressed to someone who asked a
// question about their infrastructure — it cannot be acted on by the person
// reading it, it arrives in a shared room, and it arrives once per retry.
//
// A reaction carries the same fact in the only form that is any use: this
// message has not been answered yet. The work stays in the queue, so when the
// obstacle clears the answer arrives in the thread where it was asked, and the
// pause is removed.
//
// Failures to react are swallowed on purpose. The reaction is a courtesy; the
// queue is the guarantee. Failing the run because a decoration did not land
// would be the same mistake in a smaller form.
func (s *Service) markInputPaused(ctx context.Context, input core.SlackInput) {
	if input.ChannelID == "" || input.MessageTS == "" {
		return
	}
	client, ok := s.slack.(interface {
		React(context.Context, string, string, string) error
	})
	if !ok {
		return
	}
	if err := client.React(
		ctx, input.ChannelID, input.MessageTS, pausedReaction,
	); err != nil && s.log != nil {
		s.log.Warn(
			"could not mark a message as paused; it is still queued",
			"channel", input.ChannelID,
			"message", input.MessageTS,
			"error", err,
		)
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.paused", ActorID: "responder", ObjectID: input.ID,
		Outcome: "queued", Detail: "answer deferred; the work stays queued",
	})
}

// clearInputPaused removes the pause once the work is answered.
func (s *Service) clearInputPaused(ctx context.Context, input core.SlackInput) {
	if input.ChannelID == "" || input.MessageTS == "" {
		return
	}
	client, ok := s.slack.(interface {
		Unreact(context.Context, string, string, string) error
	})
	if !ok {
		return
	}
	if err := client.Unreact(
		ctx, input.ChannelID, input.MessageTS, pausedReaction,
	); err != nil && s.log != nil {
		s.log.Warn(
			"could not clear the paused mark",
			"channel", input.ChannelID,
			"message", input.MessageTS,
			"error", err,
		)
	}
}
