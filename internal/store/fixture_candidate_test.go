package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func pendingCandidate(episode, class string) core.FixtureCandidate {
	return core.FixtureCandidate{
		EpisodeID: episode, RunID: "run_" + episode, CorrectionClass: class,
		Correction: "the reply claimed healthy without fresh evidence",
	}
}

// One lesson per episode and reason.
//
// An episode corrected three times for the same thing has taught one lesson,
// and queueing it three times spends a reviewer's attention proving that. The
// review queue only works if reviewing it is cheap.
func TestOneCandidatePerEpisodeAndReason(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	now := time.Now().UTC()

	for range 3 {
		if err := st.RecordFixtureCandidate(ctx, pendingCandidate("ep_1", "incomplete")); err != nil {
			t.Fatal(err)
		}
	}
	// A different reason on the same episode is a different lesson.
	if err := st.RecordFixtureCandidate(ctx, pendingCandidate("ep_1", "unreadable")); err != nil {
		t.Fatal(err)
	}
	pending, err := st.ListPendingFixtureCandidates(ctx, now, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 2 {
		t.Fatalf("pending candidates = %d, want 2 (one per reason, not one per correction)", len(pending))
	}
}

// A candidate nobody reviewed must lapse rather than wait.
//
// A correction is evidence about the prompt and model that produced it. Two
// weeks later that pairing may not exist, and approving the candidate then
// encodes a bug that was already fixed — the corpus becomes a museum that
// blocks good changes instead of a net that catches bad ones.
func TestUnreviewedCandidatesLapse(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	now := time.Now().UTC()

	if err := st.RecordFixtureCandidate(ctx, pendingCandidate("ep_stale", "incomplete")); err != nil {
		t.Fatal(err)
	}
	later := now.Add(fixtureCandidateTTL + time.Hour)

	// Already invisible to a reviewer before anything sweeps.
	pending, err := st.ListPendingFixtureCandidates(ctx, later, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 0 {
		t.Fatalf("a stale candidate was still offered for review: %+v", pending)
	}

	expired, err := st.ExpireFixtureCandidates(ctx, later)
	if err != nil {
		t.Fatal(err)
	}
	if expired != 1 {
		t.Fatalf("expired = %d, want 1", expired)
	}
}

// A decision is recorded once. A second review of the same candidate is a
// double-click or a stale App Home view, not a change of mind.
func TestACandidateIsReviewedOnce(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	now := time.Now().UTC()

	if err := st.RecordFixtureCandidate(ctx, pendingCandidate("ep_2", "incomplete")); err != nil {
		t.Fatal(err)
	}
	pending, err := st.ListPendingFixtureCandidates(ctx, now, 20)
	if err != nil || len(pending) != 1 {
		t.Fatalf("pending = %+v, %v", pending, err)
	}
	if err := st.ReviewFixtureCandidate(ctx, pending[0].ID, "approved", "UOPERATOR"); err != nil {
		t.Fatal(err)
	}
	if err := st.ReviewFixtureCandidate(ctx, pending[0].ID, "rejected", "UOTHER"); err == nil {
		t.Fatal("a reviewed candidate was reviewed again")
	}
	if err := st.ReviewFixtureCandidate(ctx, pending[0].ID, "maybe", "UOPERATOR"); err == nil {
		t.Fatal("accepted a status outside approved or rejected")
	}
}
