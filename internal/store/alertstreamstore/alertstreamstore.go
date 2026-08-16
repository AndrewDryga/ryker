// Package alertstreamstore reads what an alert stream has already said and
// already offered.
//
// Three questions, all of them about the past of one stream: what did the last
// reply on this episode decide, was the engineering task it offered ever
// accepted, and is the message carrying that offer's button actually on the
// channel. They live together because they are only ever asked together — the
// second and third are how "an offer is still open" is decided, and an offer
// nobody can reach is not an offer.
package alertstreamstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
)

type Repository struct{ db *sql.DB }

func New(db *sql.DB) *Repository { return &Repository{db: db} }

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
