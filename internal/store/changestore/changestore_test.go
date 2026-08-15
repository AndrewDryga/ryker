package changestore_test

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/changeledger"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/changestore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

func at(minutesAgo int) time.Time {
	return time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC).
		Add(-time.Duration(minutesAgo) * time.Minute)
}

func recorded(t *testing.T, event core.ChangeEvent) core.ChangeEvent {
	t.Helper()
	stored, ok := changeledger.Record(event)
	if !ok {
		t.Fatalf("a well-formed change was refused: %+v", event)
	}
	return stored
}

// Ingestion is at-least-once on every one of the three paths, and this is the
// property that makes that safe. A webhook redelivers, restart recovery rewinds
// a poll cursor, and the approval watcher re-reads a terminal run after a lost
// response — so the second write has to land on the first row rather than beside
// it. The section this feeds says how many things changed; two rows for one
// deploy is a wrong answer to the question the section exists to answer.
func TestAReplayedChangeWritesOneRow(t *testing.T) {
	ctx := context.Background()
	repo := changestore.New(storetest.DB(t), func() time.Time { return at(0) })

	event := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "delivery-1",
		Kind: changeledger.KindDeploy, OccurredAt: at(10),
		Services: []string{"checkout"}, Summary: "checkout v41",
	})
	created, err := repo.Record(ctx, event)
	if err != nil {
		t.Fatal(err)
	}
	if !created {
		t.Fatal("the first ingest of a change did not report a new row")
	}
	// The identical delivery again, and then the same delivery carrying a
	// summary the sender revised. Both are the same change.
	replay := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "delivery-1",
		Kind: changeledger.KindDeploy, OccurredAt: at(9),
		Services: []string{"checkout"}, Summary: "checkout v41 (retry)",
	})
	for _, duplicate := range []core.ChangeEvent{event, replay} {
		created, err := repo.Record(ctx, duplicate)
		if err != nil {
			t.Fatalf("re-ingesting a delivered change failed: %v", err)
		}
		if created {
			t.Fatal("a replayed delivery was recorded as a new change")
		}
	}
	events, err := repo.Recent(ctx, at(360), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("the ledger holds %d rows for one delivery", len(events))
	}
	// The row is the one that was written first; a redelivery does not get to
	// rewrite what an operator may already have read.
	if events[0].Summary != "checkout v41" {
		t.Fatalf("a replay overwrote the recorded change: %q", events[0].Summary)
	}
	if events[0].Services[0] != "checkout" || events[0].OccurredAt != at(10) {
		t.Fatalf("the round trip lost the change: %+v", events[0])
	}
}

// Recent is the candidate window, and it is a window rather than "the newest N"
// because the caller still has to match scope over what comes back. A row older
// than the horizon can never be recalled, so returning it only spends the cap.
func TestTheCandidateWindowStopsAtItsHorizon(t *testing.T) {
	ctx := context.Background()
	repo := changestore.New(storetest.DB(t), func() time.Time { return at(0) })

	for _, minutesAgo := range []int{5, 100, 359, 361, 4000} {
		if _, err := repo.Record(ctx, recorded(t, core.ChangeEvent{
			Source:     "webhook:deploys",
			Kind:       changeledger.KindDeploy,
			OccurredAt: at(minutesAgo),
			Services:   []string{"checkout"},
			// The minute is the identity here, so each is a distinct change.
			SourceIdentity: at(minutesAgo).Format(time.RFC3339),
		})); err != nil {
			t.Fatal(err)
		}
	}
	events, err := repo.Recent(ctx, at(360), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 3 {
		t.Fatalf("the six-hour window returned %d changes, want 3", len(events))
	}
	// Newest first, so a cap applied afterwards keeps the changes nearest the
	// incident rather than the ones nearest the horizon.
	if !events[0].OccurredAt.Equal(at(5)) || !events[2].OccurredAt.Equal(at(359)) {
		t.Fatalf("the window is not newest-first: %+v", events)
	}
}
