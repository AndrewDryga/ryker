package localstate

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/slackui"
)

// PaceChannelWrites wraps a Slack client so that every call spending a
// channel's message-posting budget records itself against slots.
//
// The delivery queue was the only thing that ever told the pacer anything, so
// the pacer's picture of a channel was the queue's own traffic and nothing
// else. Twenty other call sites write to Slack without going through the queue
// — an ephemeral refusal, an abandoned-request notice, a setup question posted
// straight from the interaction handler — and every one of them spent posting
// budget invisibly. The queue then paced against room it did not have, which is
// how a burst becomes Slack-side rate limiting.
//
// Recording here rather than at each call site is the point: a caller that
// forgets is the defect, so there is nowhere left to forget. The service holds
// this wrapper as its only Slack client, which means a write path added later
// is paced without anyone having to know the pacer exists.
func PaceChannelWrites(
	api slackui.API,
	slots *ChannelWriteSlots,
	now func() time.Time,
) slackui.API {
	if api == nil || slots == nil {
		return api
	}
	return &pacedSlack{API: api, slots: slots, now: now}
}

// pacedSlack records the writes that compete for a channel's posting budget and
// forwards everything else untouched.
//
// Slack does not meter its methods alike, and pretending it does would be its
// own defect. chat.postMessage is limited per channel — roughly one a second,
// which is exactly what ChannelWriteSlots paces — and chat.postEphemeral shares
// that posting limit. Message edits, thread status and file uploads are metered
// by workspace tier rather than per channel, but the delivery queue has always
// spent a channel's slot on them, and narrowing that here would loosen pacing
// as a side effect of a change meant to tighten it. So they stay.
//
// Reactions, pins, topics, invites, joins and channel creation are workspace
// tier methods that do not touch the posting bucket at all, and App Home
// publishing is addressed to a person rather than a channel. None of them
// records: pacing a room's replies against a reaction someone got would delay
// answers to buy back budget that was never spent.
type pacedSlack struct {
	slackui.API
	slots *ChannelWriteSlots
	now   func() time.Time
}

// Unwrap returns the client underneath. Optional Slack capabilities — reacting,
// listing channels, reading a timezone — are reached by type assertion rather
// than through slackui.API, and asserting against this wrapper would find
// nothing. Every capability reached that way is one this type does not pace.
func (p *pacedSlack) Unwrap() slackui.API { return p.API }

// record notes the attempt rather than the success: a rate-limited or failed
// post spent the channel's budget just as surely as a delivered one.
func (p *pacedSlack) record(channelID string) {
	at := time.Now()
	if p.now != nil {
		at = p.now()
	}
	p.slots.Record(channelID, at)
}

func (p *pacedSlack) Post(
	ctx context.Context,
	deliveryID string,
	channel string,
	threadTS string,
	message slackui.Message,
) (string, error) {
	defer p.record(channel)
	return p.API.Post(ctx, deliveryID, channel, threadTS, message)
}

func (p *pacedSlack) PostBroadcast(
	ctx context.Context,
	deliveryID string,
	channel string,
	threadTS string,
	message slackui.Message,
) (string, error) {
	defer p.record(channel)
	return p.API.PostBroadcast(ctx, deliveryID, channel, threadTS, message)
}

func (p *pacedSlack) PostEphemeral(
	ctx context.Context,
	channel string,
	user string,
	threadTS string,
	message slackui.Message,
) error {
	defer p.record(channel)
	return p.API.PostEphemeral(ctx, channel, user, threadTS, message)
}

func (p *pacedSlack) Update(
	ctx context.Context,
	channel string,
	timestamp string,
	message slackui.Message,
) error {
	defer p.record(channel)
	return p.API.Update(ctx, channel, timestamp, message)
}

func (p *pacedSlack) SetStatus(
	ctx context.Context,
	channel string,
	threadTS string,
	status string,
) error {
	defer p.record(channel)
	return p.API.SetStatus(ctx, channel, threadTS, status)
}

func (p *pacedSlack) SetProgress(
	ctx context.Context,
	channel string,
	threadTS string,
	status string,
	loadingMessages []string,
) error {
	defer p.record(channel)
	return p.API.SetProgress(ctx, channel, threadTS, status, loadingMessages)
}

func (p *pacedSlack) UploadFile(
	ctx context.Context,
	channel string,
	threadTS string,
	upload slackui.FileUpload,
) (slackui.FileDeliveryResult, error) {
	defer p.record(channel)
	return p.API.UploadFile(ctx, channel, threadTS, upload)
}
