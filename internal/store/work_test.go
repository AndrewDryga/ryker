package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestScheduledWorkCoalescesAndRerunsAfterConcurrentEnqueue(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	item := WorkItem{
		Kind: "incident_card", SubjectID: "incident-1",
		Lane: WorkLaneControl, ConversationKey: "thread:C1:1", Priority: 20,
	}
	if err := st.EnqueueWork(ctx, item); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseWork(ctx, WorkLaneControl, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	rerunAt := time.Now().Add(2 * time.Second).UTC()
	item.AvailableAt = rerunAt
	if err := st.EnqueueWork(ctx, item); err != nil {
		t.Fatal(err)
	}
	if err := st.CompleteWork(ctx, leased); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseWork(ctx, WorkLaneControl, time.Minute); !errors.Is(err, ErrNotFound) {
		t.Fatalf("work reran before requested time: %v", err)
	}
	if _, err := st.db.ExecContext(ctx, `
		UPDATE work_items SET available_at = ?`,
		time.Now().Add(-time.Second).UTC().Format(timestampFormat),
	); err != nil {
		t.Fatal(err)
	}
	rerun, err := st.LeaseWork(ctx, WorkLaneControl, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if rerun.Kind != item.Kind || rerun.SubjectID != item.SubjectID {
		t.Fatalf("rerun = %+v", rerun)
	}
	if err := st.CompleteWork(ctx, rerun); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseWork(ctx, WorkLaneControl, time.Minute); !errors.Is(err, ErrNotFound) {
		t.Fatalf("completed work remained: %v", err)
	}
}

func TestScheduledWorkSerializesConversationButNotLane(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	for _, item := range []WorkItem{
		{
			Kind: "agent_run", SubjectID: "run-1", Lane: WorkLaneBackground,
			ConversationKey: "thread:C1:1", Priority: 10,
		},
		{
			Kind: "agent_run", SubjectID: "run-2", Lane: WorkLaneBackground,
			ConversationKey: "thread:C1:1", Priority: 10,
		},
		{
			Kind: "agent_run", SubjectID: "run-3", Lane: WorkLaneBackground,
			ConversationKey: "thread:C2:1", Priority: 10,
		},
	} {
		if err := st.EnqueueWork(ctx, item); err != nil {
			t.Fatal(err)
		}
	}
	first, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	second, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if first.ConversationKey == second.ConversationKey {
		t.Fatalf("same conversation leased concurrently: %+v and %+v", first, second)
	}
	if err := st.CompleteWork(ctx, first); err != nil {
		t.Fatal(err)
	}
	third, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if third.ConversationKey != first.ConversationKey {
		t.Fatalf("serialized conversation did not resume: first=%+v third=%+v", first, third)
	}
}

func TestScheduledWorkRetryRecoveryAndMetrics(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	item := WorkItem{
		Kind: "incident_session", SubjectID: "incident-1",
		Lane: WorkLaneBackground, Priority: 50,
	}
	if err := st.EnqueueWork(ctx, item); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseWork(ctx, WorkLaneBackground, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RecoverWorkLeases(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	recovered, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if recovered.SubjectID != leased.SubjectID {
		t.Fatalf("recovered = %+v, want %+v", recovered, leased)
	}
	if err := st.RetryWork(
		ctx,
		recovered,
		"temporary failure",
		time.Now().Add(-time.Second),
		false,
	); err != nil {
		t.Fatal(err)
	}
	retried, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if retried.Failures != 1 || retried.LastError != "temporary failure" {
		t.Fatalf("retried = %+v", retried)
	}
	if err := st.RetryWork(ctx, retried, "permanent failure", time.Now(), true); err != nil {
		t.Fatal(err)
	}
	metrics, err := st.WorkMetrics(ctx, WorkLaneBackground)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.Failed != 1 || metrics.Pending != 0 || metrics.Running != 0 {
		t.Fatalf("metrics = %+v", metrics)
	}
}

func TestExpiredWorkLeaseIsReclaimedAndRejectsStaleOwner(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	item := WorkItem{
		Kind: "agent_finalize", SubjectID: "run-1",
		Lane: WorkLaneBackground, ConversationKey: "thread:C1:1",
	}
	if err := st.EnqueueWork(ctx, item); err != nil {
		t.Fatal(err)
	}
	stale, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `
		UPDATE work_items
		SET lease_expires_at = ?
		WHERE kind = ? AND subject_id = ?`,
		time.Now().Add(-time.Second).UTC().Format(timestampFormat),
		item.Kind,
		item.SubjectID,
	); err != nil {
		t.Fatal(err)
	}
	reclaimed, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if reclaimed.LeaseToken == "" || reclaimed.LeaseToken == stale.LeaseToken {
		t.Fatalf("reclaimed lease did not receive a new owner token: stale=%+v reclaimed=%+v", stale, reclaimed)
	}
	if err := st.CompleteWork(ctx, stale); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale lease owner completed reclaimed work: %v", err)
	}
	if err := st.CompleteWork(ctx, reclaimed); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureWorkDoesNotEraseSubjectRetrySchedule(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	item := WorkItem{
		Kind: "incident_session", SubjectID: "incident-1",
		Lane: WorkLaneBackground, ConversationKey: "incident:incident-1",
	}
	if err := st.EnsureWork(ctx, item); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetryWork(
		ctx,
		leased,
		"temporary Slack failure",
		time.Now().Add(time.Minute),
		false,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureWork(ctx, item); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseWork(ctx, WorkLaneBackground, time.Minute); !errors.Is(err, ErrNotFound) {
		t.Fatalf("discovery erased per-subject retry schedule: %v", err)
	}
}
