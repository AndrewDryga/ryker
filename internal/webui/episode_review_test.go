package webui

import (
	"strings"
	"testing"
)

// The daily self-improvement pass reads terminal traces with a frontier model.
// Its queue is this page: without the filter it is handed the whole history
// every day and has to work out for itself which endings are new, which is the
// cost that stops a daily review from happening daily.
//
// seedSecondTerminalEpisode adds an ending nobody has judged beside the fixture's
// own, so a page showing both is indistinguishable from a filter that ran and
// matched everything — the failure this test exists to catch.
func seedSecondTerminalEpisode(f *episodeProjectionFixture) {
	f.exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, result_json, terminal_state, state,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id, attempt_id, attempt_number)
	  VALUES ('run-2','triage','C1','1786000000.000002','C1:1786000000.000002',
	          'watch','input-2','U1','emisar','idem-2',?,'completed','completed',
	          ?,?,?,?,'episode-2','attempt-2',1)`, f.result, f.stamp, f.stamp, f.stamp, f.stamp)
	f.exec(`INSERT INTO work_episodes
	  (id, agent_run_id, effort, authority, objective, phase, status, next_action,
	   created_at, updated_at, completed_at, lifecycle_state, channel_id, thread_ts,
	   anchor_ts, latest_attempt_id)
	  VALUES ('episode-2','run-2','focused_check','read_only','Check the migration',
	          'complete','Completed','None',?,?,?,'completed','C1','1786000000.000002',
	          '1786000000.000002','attempt-2')`, f.stamp, f.stamp, f.stamp)
	f.exec(`INSERT INTO commitments (episode_id, title)
	  VALUES ('episode-1','The ending somebody already read')`)
	f.exec(`INSERT INTO commitments (episode_id, title)
	  VALUES ('episode-2','The ending nobody has read')`)
}

func seedReview(f *episodeProjectionFixture, episodeID, state string, attempts int, completed string) {
	f.exec(`INSERT INTO episode_reviews
	  (episode_id, reviewed_at, reviewer, note, lifecycle_state, attempts,
	   completed_at, created_at, updated_at)
	  VALUES (?,?,?,?,?,?,?,?,?)`,
		episodeID, f.stamp, "self-improve", "the answer held up", state, attempts,
		completed, f.stamp, f.stamp)
}

func TestTheEpisodesPageServesOnlyWhatAwaitsReview(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	seedSecondTerminalEpisode(fixture)
	seedReview(fixture, "episode-1", "completed", 0, fixture.stamp)
	reader := fixture.reader()
	defer reader.Close()

	pending := servePage(t, reader, "/episodes?review=pending")
	if !strings.Contains(pending, "The ending nobody has read") {
		t.Fatal("the queue dropped an ending nobody has judged; the pass would never see it")
	}
	if strings.Contains(pending, "The ending somebody already read") {
		t.Fatal("a judged ending is still queued; the pass pays to read it a second time")
	}

	// Unfiltered, both are still there. A filter that narrows the page it is
	// absent from is a filter that has quietly become the default.
	all := servePage(t, reader, "/episodes?q=ending")
	if !strings.Contains(all, "The ending somebody already read") ||
		!strings.Contains(all, "The ending nobody has read") {
		t.Fatal("the unfiltered list lost an episode")
	}
}

// An ending whose review is stale is an ending nobody has read. The fingerprint
// is the whole mechanism: a blocked episode that revives, spends another
// attempt and finishes elsewhere carries a review of a trace that no longer
// exists, and a queue keyed on the episode id alone would suppress it forever.
func TestAnEndingThatMovedIsQueuedAgain(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	seedSecondTerminalEpisode(fixture)
	seedReview(fixture, "episode-1", "completed", 0, fixture.stamp)
	// Reviewed while it was blocked with no attempts; it has since completed.
	seedReview(fixture, "episode-2", "blocked", 0, "")
	reader := fixture.reader()
	defer reader.Close()

	pending := servePage(t, reader, "/episodes?review=pending")
	if !strings.Contains(pending, "The ending nobody has read") {
		t.Fatal("an episode that ended somewhere else than its review says stayed out of the queue")
	}
	if strings.Contains(pending, "The ending somebody already read") {
		t.Fatal("an episode whose review still describes it exactly was queued anyway")
	}
}

// Absence has to read as a state on this page. An unreviewed terminal episode
// rendering as nothing is indistinguishable from a reviewed one whose panel
// failed to load, and the reader's conclusion in both cases is "no review
// exists" — which is right half the time.
func TestAnEpisodePageSaysWhoReviewedItAndWhy(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	seedSecondTerminalEpisode(fixture)
	seedReview(fixture, "episode-1", "completed", 0, fixture.stamp)
	reader := fixture.reader()
	defer reader.Close()

	reviewed := servePage(t, reader, "/episodes/episode-1")
	for _, expected := range []string{"self-improve", "the answer held up"} {
		if !strings.Contains(reviewed, expected) {
			t.Fatalf("the episode page never said %q; the ledger is also the record of who judged it", expected)
		}
	}

	unreviewed := servePage(t, reader, "/episodes/episode-2")
	if !strings.Contains(unreviewed, "Awaiting review") {
		t.Fatal("a terminal episode nobody has read says nothing at all about review")
	}
	if strings.Contains(unreviewed, "self-improve") {
		t.Fatal("episode-2 is showing episode-1's review")
	}
}
