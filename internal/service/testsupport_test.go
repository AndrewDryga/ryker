package service

// Test-only conveniences. These were production functions that no live code
// path reached: the scheduler drives processChannelIncident and
// processSessionIncident directly, watch sessions are always resolved for an
// explicit repository, and prompt and correction helpers are exercised through
// their unbounded forms. Keeping them here preserves the tests' ergonomics
// without carrying unreachable code in the service.

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func (s *Service) processChannel(ctx context.Context) error {
	incidents, err := s.store.ListChannelWork(ctx, 1)
	if err != nil {
		return err
	}
	if len(incidents) == 0 {
		incidents, err = s.store.ListRootWork(ctx, 1)
		if err != nil || len(incidents) == 0 {
			if err == nil {
				return store.ErrNotFound
			}
			return err
		}
	}
	return s.processChannelIncident(ctx, incidents[0].ID)
}

func (s *Service) processSession(ctx context.Context) error {
	incidents, err := s.store.ListSessionWork(ctx, 1)
	if err != nil || len(incidents) == 0 {
		if err == nil {
			return store.ErrNotFound
		}
		return err
	}
	return s.processSessionIncident(ctx, incidents[0].ID)
}

func (s *Service) ensureWatchSession(
	ctx context.Context,
	channelID string,
) (core.ChannelMemory, coop.Session, error) {
	return s.ensureWatchSessionAtGeneration(ctx, channelID, 1)
}

func (s *Service) ensureWatchSessionAtGeneration(
	ctx context.Context,
	channelID string,
	minimumGeneration int,
) (core.ChannelMemory, coop.Session, error) {
	return s.ensureWatchSessionForRepositoryAtGeneration(
		ctx, channelID, "", minimumGeneration,
	)
}

func watchPrompt(
	input core.SlackInput,
	botUserID string,
	recent []watchContextMessage,
) string {
	return (&Service{}).watchPrompt(
		input,
		botUserID,
		false,
		recent,
		core.AgentMemory{},
		nil,
		nil,
		operationalMemoryContext{},
		"",
		nil,
	)
}

func alertReplyLanguageCorrection(input core.SlackInput, decision watchDecision) string {
	return alertReplyLanguageCorrectionWithContext(input, watchTurnState{}, decision)
}

// testClock is a manually advanced clock shared by a Service and its Store, so
// tests exercise real retry and reconciliation windows without sleeping through
// them. Guarded because scheduler lanes may read it from several goroutines.
type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func newTestClock() *testClock {
	return &testClock{now: time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)}
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// useTestClock puts a Service and its Store on one advanceable clock.
func useTestClock(svc *Service, st *store.Store) *testClock {
	clock := newTestClock()
	svc.SetClock(clock.Now)
	st.SetClock(clock.Now)
	return clock
}

// firstOf drops the presence flag from a two-value accessor in assertions.
func firstOf[T any](value T, _ bool) T { return value }

// The Slack write slot must defer its scheduler item while cooling down, not
// report success. Reporting success requeues a recurring item as immediately
// available, which spins the control lane against the single shared database
// connection for the whole window after every Slack write.
func TestSlackWriteDefersWhileCoolingDownInsteadOfReportingSuccess(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)

	// Take the slot, then ask again inside the cooldown window.
	if _, ok := svc.writeSlot.acquire(clock.Now()); !ok {
		t.Fatal("first acquire should succeed on a fresh slot")
	}
	svc.writeSlot.release(clock.Now())

	err = svc.processSlackWrite(ctx)
	var deferral scheduledWorkDeferral
	if !errors.As(err, &deferral) {
		t.Fatalf("cooling-down write = %v, want a scheduled-work deferral", err)
	}
	if wait := deferral.at.Sub(clock.Now()); wait <= 0 || wait > slackWriteInterval {
		t.Fatalf("deferral wait = %v, want (0, %v]", wait, slackWriteInterval)
	}

	// Once the interval elapses the slot reopens and ordinary draining resumes.
	clock.Advance(slackWriteInterval)
	if err := svc.processSlackWrite(ctx); err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("write after cooldown = %v", err)
	}
}
