package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
)

func TestReadyRequiresFreshSchedulerHeartbeatsAndDueWork(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.WorkerStallAfter.Duration = time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{connected: true}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		&fakeSlack{},
		socket,
		slackui.NewSanitizer(12000),
		nil,
	)
	if err := svc.seedScheduledWork(ctx); err != nil {
		t.Fatal(err)
	}
	svc.initialized.Store(true)
	svc.running.Store(true)
	svc.coopHealthy.Store(true)
	now := time.Now().UTC()
	for _, lane := range []string{
		store.WorkLaneControl,
		store.WorkLaneBackground,
		store.WorkLaneMaintenance,
	} {
		svc.heartbeats.mark(lane, now)
	}
	if ready, reason := svc.Ready(ctx); !ready || reason != "ready" {
		t.Fatalf("fresh readiness = %v, %q", ready, reason)
	}

	svc.heartbeats.mark(store.WorkLaneControl, now.Add(-2*time.Second))
	if ready, reason := svc.Ready(ctx); ready || reason != "control worker stalled" {
		t.Fatalf("stale heartbeat readiness = %v, %q", ready, reason)
	}

	svc.heartbeats.mark(store.WorkLaneControl, time.Now().UTC())
	if err := st.EnqueueWork(ctx, store.WorkItem{
		Kind: "stale_test", SubjectID: "due", Lane: store.WorkLaneControl,
		Priority: 1, AvailableAt: now.Add(-2 * time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	if ready, reason := svc.Ready(ctx); ready || reason != "control queue stalled" {
		t.Fatalf("stale queue readiness = %v, %q", ready, reason)
	}
}

func TestScheduledWorkSeedsOneAgentDrainPerBackgroundWorker(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.BackgroundWorkers = 4
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.seedScheduledWork(ctx); err != nil {
		t.Fatal(err)
	}
	drains := map[string]bool{}
	for {
		item, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if item.Kind == workAgentRun {
			drains[item.SubjectID] = true
		}
		if err := st.CompleteWork(ctx, item); err != nil {
			t.Fatal(err)
		}
	}
	if len(drains) != cfg.Limits.BackgroundWorkers {
		t.Fatalf("agent drains = %v, want %d", drains, cfg.Limits.BackgroundWorkers)
	}
}

func TestRequestNativeStatusIsStableAndScheduleSpecific(t *testing.T) {
	if got := requestNativeStatus("Check this in 24 hours and report again"); got != "is scheduling the follow-up..." {
		t.Fatalf("schedule status = %q", got)
	}
	if got := requestNativeStatus("Check whether the deployment is healthy"); got != "is investigating..." {
		t.Fatalf("investigation status = %q", got)
	}
	if got := requestNativeStatus("Explain the earlier answer in simple terms"); got != "is explaining the earlier answer..." {
		t.Fatalf("explanation status = %q", got)
	}
}

func TestScheduledRetryHonorsSlackRetryAfter(t *testing.T) {
	now := time.Date(2026, time.July, 31, 12, 0, 0, 0, time.UTC)
	next, delay, rateLimited := scheduledRetryAt(
		now,
		1,
		fmt.Errorf("list Slack channels: %w", &slack.RateLimitedError{
			RetryAfter: 30 * time.Second,
		}),
	)
	if !rateLimited || delay != 30*time.Second || !next.Equal(now.Add(30*time.Second)) {
		t.Fatalf("scheduled retry = %s, %s, %t", next, delay, rateLimited)
	}
	next, delay, rateLimited = scheduledRetryAt(now, 1, errors.New("temporary failure"))
	if rateLimited || delay != 0 || !next.Equal(now.Add(2*time.Second)) {
		t.Fatalf("ordinary retry = %s, %s, %t", next, delay, rateLimited)
	}
}

func TestCleanupRetainsCleanSessionWithUnpublishedCommit(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.session.BaseCommit = "abc123"
	coopClient.discardPlan.OperationID = "op_unpublished"
	coopClient.discardPlan.Plan.SessionID = coopClient.session.ID
	coopClient.discardPlan.Plan.Revision = coopClient.session.Revision
	coopClient.discardPlan.Plan.Workspace.Head = "def456"
	coopClient.discardPlan.Plan.Workspace.Unmerged = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "closed task", false,
		time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 0 || coopClient.session.State != "closed" {
		t.Fatalf("unpublished commit was discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
	if !slices.Equal(coopClient.discardAccepts, []bool{false}) {
		t.Fatalf("discard plan acceptance = %v", coopClient.discardAccepts)
	}
}

func TestOrphanReconciliationSchedulesOnlyResponderManagedSessions(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	coopClient := newFakeCoop()
	coopClient.listSessions = []coop.Session{
		{
			ID: "ses_orphan", ExternalRef: "engineering-task:task_1",
			ForkName: "remote-orphan", State: "closed", UpdatedAt: now.Add(-time.Hour),
		},
		{
			ID: "ses_unrelated", ExternalRef: "catalog-roadmap",
			ForkName: "catalog-roadmap", State: "closed", UpdatedAt: now.Add(-time.Hour),
		},
		{
			ID: "ses_fresh", ExternalRef: "incident:inc_fresh",
			ForkName: "remote-fresh", State: "closed", UpdatedAt: now,
		},
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.reconcileOrphanedResponderSessions(
		ctx, now.Add(-cfg.Retention.ClosedSessionGrace.Duration), now,
	); err != nil {
		t.Fatal(err)
	}
	item, err := st.NextCleanup(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if item.SessionID != "ses_orphan" || item.Reason != "orphaned Responder session" {
		t.Fatalf("scheduled cleanup = %+v", item)
	}
	for _, sessionID := range []string{"ses_unrelated", "ses_fresh"} {
		known, err := st.ResponderSessionKnown(ctx, sessionID)
		if err != nil {
			t.Fatal(err)
		}
		if known {
			t.Fatalf("session %s was incorrectly claimed by Responder", sessionID)
		}
	}
}

func TestOrphanReconciliationClosesDiscardedCleanupProjection(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	coopClient := newFakeCoop()
	coopClient.listSessions = []coop.Session{{
		ID: "ses_discarded", State: "discarded", UpdatedAt: now,
	}}
	if err := st.ScheduleCleanup(
		ctx, "ses_discarded", "", "old dirty workspace", false, now,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCleanupState(
		ctx, "ses_discarded", "blocked", "op_old", "workspace was dirty", now,
	); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.reconcileOrphanedResponderSessions(ctx, now.Add(-time.Hour), now); err != nil {
		t.Fatal(err)
	}
	cleanup, err := st.GetCoopCleanup(ctx, "ses_discarded")
	if err != nil || cleanup.State != "done" || cleanup.LastError != "" {
		t.Fatalf("discarded cleanup projection = %+v, %v", cleanup, err)
	}
}
