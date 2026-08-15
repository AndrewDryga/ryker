package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/retrydelay"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
)

type pendingCreateCoop struct {
	*fakeCoop
	remaining int
	entered   chan<- struct{}
	release   <-chan struct{}
}

func (f *pendingCreateCoop) CreateSession(
	ctx context.Context,
	key, policy, task string,
	sources ...coop.SessionSource,
) (coop.Session, coop.Operation, error) {
	if f.remaining > 0 {
		f.remaining--
		if f.entered != nil {
			f.entered <- struct{}{}
		}
		select {
		case <-ctx.Done():
			return coop.Session{}, coop.Operation{}, ctx.Err()
		case <-f.release:
		}
		operation := coop.Operation{ID: "op_cold", Method: "CreateRemoteSession", State: "running"}
		return coop.Session{}, operation, &coop.OperationPendingError{ID: operation.ID}
	}
	return f.fakeCoop.CreateSession(ctx, key, policy, task, sources...)
}

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

func TestScheduledColdSessionCreationYieldsAndEventuallyResumesWithoutRestart(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CCOLD"}
	cfg.Limits.WorkerStallAfter.Duration = time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	entered, release := make(chan struct{}), make(chan struct{})
	client := &pendingCreateCoop{
		fakeCoop: newFakeCoop(), remaining: 2, entered: entered, release: release,
	}
	svc := New(cfg, st, client, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	clock := useTestClock(svc, st)
	input := core.SlackInput{
		ID: "cold-create", EnvelopeID: "cold-create-envelope", EventID: "cold-create-event",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CCOLD",
		MessageTS: "1700.500", UserID: "U123ABC", Text: "<@U999BOT> investigate this",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureWork(ctx, store.WorkItem{
		Kind: workAgentRun, SubjectID: "cold-create-drain", Lane: store.WorkLaneBackground,
		ConversationKey: "", Priority: 10,
	}); err != nil {
		t.Fatal(err)
	}
	started := clock.Now()
	for attempt := range 3 {
		item, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
		if err != nil {
			t.Fatalf("lease attempt %d: %v", attempt, err)
		}
		done := make(chan struct{})
		go func() {
			svc.handleScheduledWork(ctx, item)
			close(done)
		}()
		if attempt < 2 {
			<-entered
			release <- struct{}{}
		}
		<-done
		run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
		if err != nil {
			t.Fatal(err)
		}
		if attempt < 2 {
			if run.State != core.AgentRunPending || run.Failures != 0 {
				t.Fatalf("yielded run attempt %d = %+v", attempt, run)
			}
			clock.Advance(cfg.Limits.WorkerStallAfter.Duration + time.Second)
		} else if run.State != core.AgentRunRunning || run.CoopTurnID == "" {
			t.Fatalf("resumed run = %+v", run)
		}
	}
	if elapsed := clock.Now().Sub(started); elapsed <= cfg.Limits.WorkerStallAfter.Duration {
		t.Fatalf("cold operation duration %s did not exceed worker stall %s", elapsed, cfg.Limits.WorkerStallAfter.Duration)
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
	if got := episodepkg.ActivityNativeStatus(requestEpisodeActivity("Check this in 24 hours and report again")); got != "is scheduling the follow-up..." {
		t.Fatalf("schedule status = %q", got)
	}
	if got := episodepkg.ActivityNativeStatus(requestEpisodeActivity("Check whether the deployment is healthy")); got != "is investigating..." {
		t.Fatalf("investigation status = %q", got)
	}
	if got := episodepkg.ActivityNativeStatus(requestEpisodeActivity("Explain the earlier answer in simple terms")); got != "is explaining the earlier answer..." {
		t.Fatalf("explanation status = %q", got)
	}
}

func TestScheduledRetryHonorsSlackRetryAfter(t *testing.T) {
	now := time.Date(2026, time.July, 31, 12, 0, 0, 0, time.UTC)
	err := fmt.Errorf("list Slack channels: %w", &slack.RateLimitedError{
		RetryAfter: 30 * time.Second,
	})
	delay, rateLimited := slackui.RetryAfter(err)
	next := retrydelay.At(now, 1, delay)
	if !rateLimited || delay != 30*time.Second || !next.Equal(now.Add(30*time.Second)) {
		t.Fatalf("scheduled retry = %s, %s, %t", next, delay, rateLimited)
	}
	delay, rateLimited = slackui.RetryAfter(errors.New("temporary failure"))
	next = retrydelay.At(now, 1, delay)
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

// The 2026-08-13 buildkit-corruption outage ran 75 minutes with /readyz green:
// every turn died on "Coop box image is not built" while readiness reported
// the process fine, so the watchdog had nothing to surface. A repair streak
// past the gate's own prune-and-rebuild attempt means the self-heal has been
// tried and lost; readiness must name it, in the exact token the watchdog's
// ready_reason() forwards to a person.
func TestReadyNamesAnUnbuildableCoopImage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.WorkerStallAfter.Duration = time.Minute
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

	failures := 0
	svc.SetCoopRuntimeRepairer(nil, func() (int, error) {
		return failures, errors.New("invalid output path: stat /var/lib/docker/overlay2/x")
	})
	failures = 2
	if ready, reason := svc.Ready(ctx); !ready || reason != "ready" {
		t.Fatalf("readiness at two failures = %v, %q; the gate's own prune "+
			"fires at two and deserves its chance", ready, reason)
	}
	failures = 3
	if ready, reason := svc.Ready(ctx); ready || reason != "coop_image_unbuildable" {
		t.Fatalf("readiness at three failures = %v, %q; ready_reason() forwards "+
			"this exact token", ready, reason)
	}
	failures = 0
	if ready, reason := svc.Ready(ctx); !ready || reason != "ready" {
		t.Fatalf("readiness after recovery = %v, %q", ready, reason)
	}
}
