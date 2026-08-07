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
	"github.com/AndrewDryga/responder/internal/localstate"
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

// A busy channel must not hold up an answer somewhere unrelated: Slack rate
// limits chat.postMessage per channel, so cooling channels are skipped rather
// than waited on. Only when every ready write belongs to a cooling channel is
// there anything to defer for.
func TestSlackWritesArePacedPerChannel(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)

	queue := func(id, channelID string) {
		t.Helper()
		body, err := slackui.Encode(slackui.Notice("a reply for " + channelID))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID: id, Operation: "post", Kind: "notice",
			ChannelID: channelID, ThreadTS: "1700.001", Body: body,
		}); err != nil {
			t.Fatal(err)
		}
	}
	queue("out_busy_1", "CBUSY")
	queue("out_busy_2", "CBUSY")
	queue("out_quiet_1", "CQUIET")

	// First write goes to the busy channel and starts its cooldown.
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 || slack.posts[0].channel != "CBUSY" {
		t.Fatalf("first write = %+v", slack.posts)
	}

	// The busy channel is cooling, but the quiet one is not — so the next pass
	// answers the other conversation instead of waiting.
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 2 || slack.posts[1].channel != "CQUIET" {
		t.Fatalf("a cooling channel blocked an unrelated one: %+v", slack.posts)
	}

	// Now every remaining write belongs to a cooling channel, so there is
	// genuinely something to wait for.
	err = svc.processSlackWrite(ctx)
	var deferral scheduledWorkDeferral
	if !errors.As(err, &deferral) {
		t.Fatalf("all-cooling write = %v, want a scheduled-work deferral", err)
	}

	// Once the interval elapses the remaining message goes out.
	clock.Advance(localstate.SlackWriteInterval)
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 3 {
		t.Fatalf("the cooled channel did not resume: %+v", slack.posts)
	}
}

// testDecodeClock is a fixed reading for parser tests. Decoding validates
// shape and freshness bounds, so a stable clock keeps those assertions from
// depending on when the suite runs.
var testDecodeClock = time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
