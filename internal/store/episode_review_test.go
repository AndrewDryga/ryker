package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The daily self-improvement pass (.agent/skills/self-improve/SKILL.md §6)
// reads terminal traces end to end with a frontier model. Before this ledger
// there was nothing on disk saying which endings a previous pass had read, so
// every daily pass paid for the whole history to find the few endings that
// were new — a review whose cost grows with the corpus is a review that stops
// running daily. These tests hold shut the two halves that make the ledger
// worth having: a judged ending goes quiet, and an ending that MOVES comes
// back.

// reviewedFingerprintMatches is the pending-review predicate in the store's own
// terms: an episode is awaiting review when no row records it, or when any of
// the three fingerprint columns disagrees with what the episode says now.
//
// The dashboard carries its own copy of this comparison against episodeSelect,
// pinned by TestTheEpisodesPageServesOnlyWhatAwaitsReview. Two copies because
// the two queries select different things and neither package imports the
// other; neither can rot silently, because a change to what a review records
// fails here and a change to what the page asks fails there.
func reviewedFingerprintMatches(t *testing.T, st *Store, episodeID string) bool {
	t.Helper()
	var matches int
	err := st.db.QueryRowContext(context.Background(), `
		SELECT COUNT(*) FROM work_episodes AS e
		JOIN episode_reviews AS rev ON rev.episode_id = e.id
		WHERE e.id = ?
		  AND rev.lifecycle_state = e.lifecycle_state
		  AND rev.attempts = (SELECT COUNT(*) FROM episode_attempts AS a WHERE a.episode_id = e.id)
		  AND rev.completed_at = COALESCE(e.completed_at, '')`, episodeID).Scan(&matches)
	if err != nil {
		t.Fatal(err)
	}
	return matches == 1
}

// reviewRows is how many reviews the ledger holds for one episode. A review is
// a judgement of the episode's latest ending, not an append-only log of every
// reading, so a second review must refresh the row rather than add one.
func reviewRows(t *testing.T, st *Store, episodeID string) int {
	t.Helper()
	var rows int
	if err := st.db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM episode_reviews WHERE episode_id = ?`, episodeID,
	).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	return rows
}

func reviewableEpisodeFixture(t *testing.T, st *Store, channelID string) core.WorkEpisode {
	t.Helper()
	ctx := context.Background()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: channelID, ConversationKey: "channel:" + channelID,
		SourceKind: "watch", SourceID: "input-" + channelID, Prompt: "Investigate the rollout",
	})
	if err != nil || !created {
		t.Fatalf("queue episode: created=%t err=%v", created, err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	return episode
}

func TestAReviewedEpisodeLeavesThePendingQueue(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	episode := reviewableEpisodeFixture(t, st, "C1")
	if err := st.SetEpisodePhase(ctx, episode.ID, core.EpisodeCompleted, "complete",
		"Completed", "None", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if reviewedFingerprintMatches(t, st, episode.ID) {
		t.Fatal("a terminal episode nobody has read was already outside the queue")
	}
	if err := st.ReviewEpisode(ctx, episode.ID, "self-improve", "answer was accurate"); err != nil {
		t.Fatal(err)
	}
	if !reviewedFingerprintMatches(t, st, episode.ID) {
		t.Fatal("a judged ending is still pending; tomorrow's pass pays to read it again")
	}
	var reviewer, note string
	if err := st.db.QueryRowContext(ctx,
		`SELECT reviewer, note FROM episode_reviews WHERE episode_id = ?`, episode.ID,
	).Scan(&reviewer, &note); err != nil {
		t.Fatal(err)
	}
	if reviewer != "self-improve" || note != "answer was accurate" {
		t.Fatalf("review recorded reviewer=%q note=%q; the ledger is also the record of who judged it and why",
			reviewer, note)
	}
}

// A blocked ending is still an ending — RecallableTerminalState keeps blocked
// episodes for the same reason, they diagnosed something real on the way. What
// makes that safe is this: when the episode revives and finishes somewhere
// else, the fingerprint moves and the pass reads the ending it has not seen.
func TestARevivedEpisodeReturnsForReview(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	episode := reviewableEpisodeFixture(t, st, "C2")
	if err := st.SetEpisodePhase(ctx, episode.ID, core.EpisodeBlocked, "blocked",
		"Waiting for an operator decision", "Decide", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := st.ReviewEpisode(ctx, episode.ID, "self-improve", "blocked on a real external limit"); err != nil {
		t.Fatalf("a blocked ending was refused; a blocked episode has ended: %v", err)
	}
	if !reviewedFingerprintMatches(t, st, episode.ID) {
		t.Fatal("a judged blocked ending is still pending")
	}

	if _, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C2", ConversationKey: "channel:C2",
		SourceKind: "watch", SourceID: "input-C2-again", Prompt: "The limit was raised; continue",
	}); err != nil || !created {
		t.Fatalf("resume episode: created=%t err=%v", created, err)
	}
	if err := st.SetEpisodePhase(ctx, episode.ID, core.EpisodeCompleted, "complete",
		"Completed", "None", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if reviewedFingerprintMatches(t, st, episode.ID) {
		t.Fatal("the episode ended somewhere else and the ledger still says it was judged")
	}

	if err := st.ReviewEpisode(ctx, episode.ID, "self-improve", "the retry finished it"); err != nil {
		t.Fatal(err)
	}
	if !reviewedFingerprintMatches(t, st, episode.ID) {
		t.Fatal("the new ending was judged and the ledger did not take the new fingerprint")
	}
	if rows := reviewRows(t, st, episode.ID); rows != 1 {
		t.Fatalf("episode_reviews holds %d rows for one episode; a review judges the latest ending, it is not a log", rows)
	}
	var state string
	var attempts int
	var completed string
	if err := st.db.QueryRowContext(ctx,
		`SELECT lifecycle_state, attempts, completed_at FROM episode_reviews WHERE episode_id = ?`,
		episode.ID,
	).Scan(&state, &attempts, &completed); err != nil {
		t.Fatal(err)
	}
	if state != string(core.EpisodeCompleted) || attempts != 2 || completed == "" {
		t.Fatalf("refreshed fingerprint = (%s, %d, %q); it must describe the ending that was just read",
			state, attempts, completed)
	}
}

// The review judges an ending, so there has to be one. An episode still
// working or still parked on a person will keep writing timeline nobody has
// read, and a ledger row against it would suppress exactly the reading the
// pass exists to do — the trace would be marked judged before the interesting
// half of it happened.
func TestAnUnfinishedEpisodeCannotBeMarkedReviewed(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, unfinished := range []struct {
		channel string
		state   core.WorkEpisodeState
		phase   string
	}{
		{"C3", core.EpisodeWorking, "working"},
		{"C4", core.EpisodeWaitingOperator, "waiting"},
	} {
		episode := reviewableEpisodeFixture(t, st, unfinished.channel)
		if err := st.SetEpisodePhase(ctx, episode.ID, unfinished.state, unfinished.phase,
			"Still going", "Continue", time.Time{}); err != nil {
			t.Fatal(err)
		}
		err := st.ReviewEpisode(ctx, episode.ID, "self-improve", "looks fine so far")
		if err == nil {
			t.Fatalf("%s episode accepted a review; the trace is still being written", unfinished.state)
		}
		if !strings.Contains(err.Error(), "has not ended") {
			t.Fatalf("refusal for a %s episode reads %q; it must say the review judges an ending",
				unfinished.state, err)
		}
		if rows := reviewRows(t, st, episode.ID); rows != 0 {
			t.Fatalf("a refused review left %d rows behind", rows)
		}
	}
}
