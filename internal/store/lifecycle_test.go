package store

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestPublicationCanRecoverBeforeBranchIdentityIsKnown(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	publication := core.Publication{
		IncidentID: incidents[0].ID, Repository: "owner/repository", BaseBranch: "main",
		ParentHead: "parent", CandidateTree: "tree", State: "publishing",
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatalf("save pre-side-effect publication: %v", err)
	}
	stored, err := st.GetPublication(ctx, incidents[0].ID)
	if err != nil || stored.HeadBranch != "" || stored.State != "publishing" {
		t.Fatalf("stored publication = %+v, %v", stored, err)
	}

	publication.State = "published"
	if err := st.SavePublication(ctx, publication); err == nil {
		t.Fatal("published record without remote proof was accepted")
	}
	publication.HeadBranch = "responder/fix"
	publication.CommitSHA = "commit"
	publication.RemoteSHA = "commit"
	publication.PRNumber = 12
	publication.PRURL = "https://github.com/owner/repository/pull/12"
	publication.PublishedAt = time.Now().UTC()
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatalf("save proved publication: %v", err)
	}
}

func TestExpiredChannelMemoryIsOwnedBeforeItIsPruned(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	started := time.Now().UTC().Add(-2 * time.Hour)
	if err := st.BindChannelSession(ctx, "COPS", "repo", "session-old", 3, 1, started); err != nil {
		t.Fatal(err)
	}
	count, err := st.ScheduleExpiredChannelMemoryCleanup(
		ctx, started.Add(time.Minute), time.Now().Add(-time.Minute),
	)
	if err != nil || count != 1 {
		t.Fatalf("scheduled = %d, %v", count, err)
	}
	item, err := st.NextCleanup(ctx, time.Now())
	if err != nil || item.SessionID != "session-old" || item.IncidentID != "" {
		t.Fatalf("cleanup = %+v, %v", item, err)
	}
	if err := st.SetCleanupState(
		ctx, item.SessionID, "done", "discard-plan", "", time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Prune(
		ctx,
		time.Now().Add(time.Hour),
		time.Now().Add(time.Hour),
		time.Now().Add(time.Hour),
		time.Now().Add(-time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetChannelMemory(ctx, "COPS"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired channel memory remained after owned cleanup: %v", err)
	}
}

func TestIncidentCardRevisionInvalidatesRenderedCardsOnce(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "ems-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	incident, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkCardRendered(ctx, incident.ID, incident.CardVersion); err != nil {
		t.Fatal(err)
	}
	changed, err := st.EnsureIncidentCardRevision(ctx, "revision-1")
	if err != nil || !changed {
		t.Fatalf("first revision = %v, %v", changed, err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 1 || dirty[0].ID != incident.ID {
		t.Fatalf("dirty after UI upgrade = %+v, %v", dirty, err)
	}
	if err := st.MarkCardRendered(ctx, dirty[0].ID, dirty[0].CardVersion); err != nil {
		t.Fatal(err)
	}
	changed, err = st.EnsureIncidentCardRevision(ctx, "revision-1")
	if err != nil || changed {
		t.Fatalf("same revision = %v, %v", changed, err)
	}
	dirty, err = st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 0 {
		t.Fatalf("same revision dirtied cards = %+v, %v", dirty, err)
	}
	changed, err = st.EnsureIncidentCardRevision(ctx, "revision-2")
	if err != nil || !changed {
		t.Fatalf("second revision = %v, %v", changed, err)
	}
}

func TestResolvedDeletedWorkIsClosedAndQueuedForSafeCleanup(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	event := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CDELETED", "ems-deleted"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "session-deleted", "fork-deleted", 1); err != nil {
		t.Fatal(err)
	}
	resolved := event
	resolved.DedupeKey = "delivery-resolved"
	resolved.BodyDigest = "resolved-digest"
	resolved.Signals = append([]core.Signal(nil), event.Signals...)
	resolved.Signals[0].EventID = "event-resolved"
	resolved.Signals[0].Status = core.SignalResolved
	resolved.Signals[0].ReceivedAt = time.Now().UTC()
	if _, err := st.ApplySignals(ctx, resolved, time.Hour, 0, 100); err != nil {
		t.Fatal(err)
	}
	deletedAt := time.Now().UTC()
	if _, err := st.SetIncidentChannelState(
		ctx,
		"CDELETED",
		core.ChannelDeleted,
		deletedAt,
	); err != nil {
		t.Fatal(err)
	}

	retired, err := st.RetireResolvedDeletedWork(
		ctx,
		deletedAt.Add(time.Hour),
	)
	if err != nil || retired != 1 {
		t.Fatalf("retired = %d, %v", retired, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.Status != core.IncidentClosed ||
		incident.Workflow != core.WorkflowClosed {
		t.Fatalf("retired incident = %+v, %v", incident, err)
	}
	cleanup, err := st.NextCleanup(ctx, time.Now().UTC())
	if err != nil || cleanup.SessionID != "session-deleted" ||
		cleanup.IncidentID != incident.ID || cleanup.AllowUnmerged {
		t.Fatalf("cleanup ownership = %+v, %v", cleanup, err)
	}
}
