package alertstreamstore_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store/alertstreamstore"
	"github.com/AndrewDryga/ryker/internal/store/storetest"
)

// What a channel has already offered is read from the channel, not from one
// episode, and only from the part of it an operator is still living through.
//
// Six identical Traefik offers on 2026-08-16, none accepted; the sixth came
// from the scheduled health review in another thread, which the episode-scoped
// check could not see. Widening that to the channel is what this reader is for,
// and each of its three bounds is load-bearing: another channel's offer is not
// this channel's, this episode's own answers are already read by RepliesPosted,
// and an offer from before the window has scrolled out of the conversation the
// pointer would send someone back to.
func TestAChannelsOtherEpisodesAreReadNewestFirstInsideTheWindow(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repository := alertstreamstore.New(db)
	now := time.Now().UTC()

	recordReply(t, db, "CALERTS", "answering", "the card being answered now", now)
	recordReply(t, db, "CALERTS", "older-thread", "the review's offer", now.Add(-2*time.Hour))
	recordReply(t, db, "CALERTS", "newer-thread", "the stream's offer", now.Add(-1*time.Hour))
	recordReply(t, db, "CALERTS", "yesterday", "an offer nobody took up", now.Add(-30*time.Hour))
	recordReply(t, db, "COTHER", "another-channel", "another channel's offer", now.Add(-1*time.Hour))

	payloads, err := repository.RepliesPostedInChannel(
		ctx, "CALERTS", "episode-answering", now.Add(-6*time.Hour), 20,
	)
	if err != nil {
		t.Fatal(err)
	}
	if got := offerTitles(t, payloads); strings.Join(got, "|") !=
		"the stream's offer|the review's offer" {
		t.Fatalf("the channel's recent answers = %v", got)
	}

	// The limit is over what the query returns, not over what it read: the
	// newest answer has to survive it.
	payloads, err = repository.RepliesPostedInChannel(
		ctx, "CALERTS", "episode-answering", now.Add(-6*time.Hour), 1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if got := offerTitles(t, payloads); len(got) != 1 || got[0] != "the stream's offer" {
		t.Fatalf("the bounded read = %v", got)
	}

	// A search with no window would point at an offer from any time at all,
	// which is the opposite of "already offered here".
	if _, err := repository.RepliesPostedInChannel(
		ctx, "CALERTS", "episode-answering", time.Time{}, 20,
	); err == nil {
		t.Fatal("an unbounded channel-wide search was accepted")
	}
}

// recordReply writes one episode in a channel and the reply_posted event it
// answered with, the way the alert-stream path does.
func recordReply(
	t *testing.T,
	db *sql.DB,
	channelID string,
	name string,
	offerTitle string,
	at time.Time,
) {
	t.Helper()
	stamp := at.UTC().Format(core.TimestampFormat)
	payload, err := json.Marshal(map[string]string{
		"offer_title": offerTitle, "offer_repository": "blitz-infra",
		"source_input_id": "input-" + name, "posted_at": stamp,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO agent_runs (id, mode, conversation_key, source_kind, source_id,
		  idempotency_key, state, next_attempt_at, created_at, updated_at)
		VALUES (?, 'triage', ?, 'watch', ?, ?, 'completed', ?, ?, ?)`,
		"run-"+name, "operation:"+channelID+":alert:"+name, "input-"+name,
		"key-"+name, stamp, stamp, stamp,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO work_episodes (id, agent_run_id, effort, authority,
		  objective, channel_id, lifecycle_state, created_at, updated_at)
		VALUES (?, ?, 'operational_assessment', 'read_only',
		  'traefik memory is near its cap', ?, 'completed', ?, ?)`,
		"episode-"+name, "run-"+name, channelID, stamp, stamp,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO work_episode_events (id, episode_id, sequence, kind, actor,
		  idempotency_key, payload_json, created_at)
		VALUES (?, ?, 1, 'reply_posted', 'host', ?, ?, ?)`,
		"event-"+name, "episode-"+name, "reply_posted:run-"+name, string(payload), stamp,
	); err != nil {
		t.Fatal(err)
	}
}

func offerTitles(t *testing.T, payloads []json.RawMessage) []string {
	t.Helper()
	titles := make([]string, 0, len(payloads))
	for _, payload := range payloads {
		var reply struct {
			OfferTitle string `json:"offer_title"`
		}
		if err := json.Unmarshal(payload, &reply); err != nil {
			t.Fatal(err)
		}
		titles = append(titles, reply.OfferTitle)
	}
	return titles
}
