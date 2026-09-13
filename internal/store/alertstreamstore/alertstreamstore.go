// Package alertstreamstore reads what an alert stream has already said and
// already offered.
//
// Four questions, all of them about what a channel has already been told: what
// did the last reply on this episode decide, what have the channel's other
// episodes answered lately, was the engineering task an offer named ever
// accepted, and is the message carrying that offer's button actually on the
// channel. They live together because they are only ever asked together — the
// last two are how "an offer is still open" is decided, and an offer nobody can
// reach is not an offer.
package alertstreamstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/ryker/internal/alertstream"
	"github.com/AndrewDryga/ryker/internal/core"
	episodepkg "github.com/AndrewDryga/ryker/internal/episode"
)

type Repository struct{ db *sql.DB }

func New(db *sql.DB) *Repository { return &Repository{db: db} }

// LifecycleInput is the last app card that changed one operational stream.
// Episode state alone is insufficient: an investigation can remain retrying
// after Grafana recovered, but that does not keep the recovered cycle open
// forever.
type LifecycleInput struct {
	Text       string
	ReceivedAt time.Time
}

// LatestLifecycleInput returns the newest app card already admitted for an
// operational conversation. Synthetic rechecks deliberately do not replace
// the source lifecycle state.
func (r *Repository) LatestLifecycleInput(
	ctx context.Context,
	conversationKey string,
) (LifecycleInput, error) {
	if strings.TrimSpace(conversationKey) == "" {
		return LifecycleInput{}, core.ErrNotFound
	}
	var value LifecycleInput
	var receivedAt string
	err := r.db.QueryRowContext(ctx, `
		SELECT input.text, input.received_at
		FROM agent_runs AS run
		JOIN slack_inputs AS input ON input.id = run.source_id
		WHERE run.conversation_key = ?
		  AND input.kind = 'bot_message'
		ORDER BY input.received_at DESC, run.created_at DESC, run.id DESC
		LIMIT 1`, conversationKey,
	).Scan(&value.Text, &receivedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return LifecycleInput{}, core.ErrNotFound
	}
	if err != nil {
		return LifecycleInput{}, err
	}
	value.ReceivedAt, err = time.Parse(core.TimestampParseFormat, receivedAt)
	if err != nil {
		return LifecycleInput{}, err
	}
	return value, nil
}

// RecoveredCycleExpired identifies a new firing that arrived after the prior
// recovery's hold window. A stuck episode does not keep an alert cycle open.
func (r *Repository) RecoveredCycleExpired(
	ctx context.Context,
	conversationKey string,
	input core.SlackInput,
	hold time.Duration,
) (bool, error) {
	firing, _ := alertstream.AlertCounts(input.Text)
	if firing == 0 || hold <= 0 {
		return false, nil
	}
	previous, err := r.LatestLifecycleInput(ctx, conversationKey)
	if errors.Is(err, core.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	previousFiring, previousResolved := alertstream.AlertCounts(previous.Text)
	if previousFiring != 0 || previousResolved == 0 || previous.ReceivedAt.IsZero() {
		return false, nil
	}
	return !input.ReceivedAt.Before(previous.ReceivedAt.Add(hold)), nil
}

// RepliesPosted returns the answers this episode has already posted, newest
// first.
//
// Newest first because the comparison that matters is against the last thing
// the channel read, and bounded because a stream that fires all day is one
// episode: the caller wants the recent history, not the transcript.
func (r *Repository) RepliesPosted(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]json.RawMessage, error) {
	if strings.TrimSpace(episodeID) == "" {
		return nil, nil
	}
	if limit < 1 || limit > 50 {
		return nil, errors.New("posted replies require a limit from 1 to 50")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT payload_json FROM work_episode_events
		WHERE episode_id = ? AND kind = ?
		ORDER BY sequence DESC LIMIT ?`,
		episodeID, episodepkg.EventReplyPosted, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	replies := make([]json.RawMessage, 0, limit)
	for rows.Next() {
		var payload []byte
		if err := rows.Scan(&payload); err != nil {
			return nil, err
		}
		replies = append(replies, json.RawMessage(payload))
	}
	return replies, rows.Err()
}

// RepliesPostedInChannel returns the answers the channel's OTHER episodes have
// posted lately, newest first.
//
// One episode is one alert stream, and a channel is several of them at once
// beside whatever a scheduled review or a conversation is doing. On 2026-08-16
// the same Traefik fix was offered six times in one channel from six episodes,
// so the question "has this already been offered here" cannot be asked of a
// single episode — which is all RepliesPosted can answer.
//
// Bounded twice, because this walks a channel rather than a stream. The window
// is the caller's: an offer nobody has taken up in days is not what an operator
// reading this thread means by "already offered", and pointing at it sends them
// to a message that has scrolled out of the conversation. The limit keeps a busy
// channel's history from being read into memory to answer one question.
//
// The join is deliberate rather than a channel column on the event: the episode
// owns where it is happening, and a copy on every event would be a second answer
// to that question able to disagree with the first. Measured on the deployed
// blitz database, work_episode_events holds 17,829 rows of which 10 are
// reply_posted, and this runs at most once per alert reply.
func (r *Repository) RepliesPostedInChannel(
	ctx context.Context,
	channelID string,
	excludeEpisodeID string,
	since time.Time,
	limit int,
) ([]json.RawMessage, error) {
	if strings.TrimSpace(channelID) == "" {
		return nil, nil
	}
	if limit < 1 || limit > 50 {
		return nil, errors.New("posted replies require a limit from 1 to 50")
	}
	if since.IsZero() {
		return nil, errors.New("a channel-wide reply search requires a time bound")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT event.payload_json
		FROM work_episode_events AS event
		JOIN work_episodes AS episode ON episode.id = event.episode_id
		WHERE episode.channel_id = ?
		  AND event.episode_id != ?
		  AND event.kind = ?
		  AND event.created_at >= ?
		ORDER BY event.created_at DESC, event.id DESC
		LIMIT ?`,
		channelID, excludeEpisodeID, episodepkg.EventReplyPosted,
		since.UTC().Format(core.TimestampFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	replies := make([]json.RawMessage, 0, limit)
	for rows.Next() {
		var payload []byte
		if err := rows.Scan(&payload); err != nil {
			return nil, err
		}
		replies = append(replies, json.RawMessage(payload))
	}
	return replies, rows.Err()
}

// EngineeringTaskExistsForSource reports whether the offer made on this Slack
// input was ever accepted.
//
// The join goes through the input's event id because that is the provenance the
// task carries: an engineering task records source_incident_id as "task:" plus
// the Slack event id of the message its button was on. An accepted offer is a
// closed question, and the reply that comes after it should say what the task
// is doing rather than offer it again.
func (r *Repository) EngineeringTaskExistsForSource(
	ctx context.Context,
	sourceInputID string,
) (bool, error) {
	if strings.TrimSpace(sourceInputID) == "" {
		return false, nil
	}
	var found int
	err := r.db.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1 FROM incidents
		  JOIN slack_inputs ON incidents.source_incident_id = 'task:' || slack_inputs.event_id
		  WHERE slack_inputs.id = ?
		    AND incidents.work_kind = 'engineering_task'
		)`, sourceInputID).Scan(&found)
	if err != nil {
		return false, err
	}
	return found == 1, nil
}

// SentReply is where an earlier answer landed: enough to link an operator to
// the message carrying its button, and nothing more.
type SentReply struct {
	DeliveryID string
	ChannelID  string
	ThreadTS   string
	MessageTS  string
}

// SentReplyForInput finds the posted root answer for a Slack input.
//
// core.ErrNotFound when the reply never went out, which is the whole reason
// this is asked: a button on a message that was never delivered is not an open
// offer, and pointing at it would send an operator to a message that does not
// exist.
func (r *Repository) SentReplyForInput(
	ctx context.Context,
	sourceInputID string,
) (SentReply, error) {
	if strings.TrimSpace(sourceInputID) == "" {
		return SentReply{}, core.ErrNotFound
	}
	var reply SentReply
	err := r.db.QueryRowContext(ctx, `
		SELECT id, channel_id, thread_ts, message_ts
		FROM slack_deliveries
		WHERE source_input_id = ?
		  AND operation = 'post'
		  AND response_root = 1
		  AND state = 'sent'
		  AND message_ts != ''
		ORDER BY created_at DESC, id DESC
		LIMIT 1`, sourceInputID,
	).Scan(&reply.DeliveryID, &reply.ChannelID, &reply.ThreadTS, &reply.MessageTS)
	if errors.Is(err, sql.ErrNoRows) {
		return SentReply{}, core.ErrNotFound
	}
	if err != nil {
		return SentReply{}, err
	}
	return reply, nil
}
