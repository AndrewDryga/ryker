package service

import (
	"context"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack/socketmode"
)

// schedulerGoroutines counts live scheduler lanes by stack frame. The service
// owns the store and the Coop connection, so its callers close both as soon as
// Run returns; a lane still running at that point would use a closed database.
func schedulerGoroutines() int {
	buffer := make([]byte, 1<<20)
	buffer = buffer[:runtime.Stack(buffer, true)]
	return strings.Count(string(buffer), "service.(*Service).runScheduledLane")
}

// Run must not return until every scheduler lane has stopped.
func TestRunDrainsSchedulerLanesBeforeReturning(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	// A socket whose Run blocks until cancellation, so the lanes are reliably
	// alive when the test asks the service to stop. The shared fake returns
	// immediately, which would end Run before it had scheduled anything.
	socket := &blockingSocket{fakeSocket: fakeSocket{events: make(chan socketmode.Event)}}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.seedScheduledWork(ctx); err != nil {
		t.Fatal(err)
	}
	svc.initialized.Store(true)

	runCtx, cancel := context.WithCancel(ctx)
	stopped := make(chan error, 1)
	go func() { stopped <- svc.Run(runCtx) }()

	// Wait for the lanes to actually start before asking them to stop. This
	// polls because the condition is goroutines reaching a particular frame,
	// which is observable only by looking; there is nothing to select on.
	deadline := time.Now().Add(10 * time.Second)
	for schedulerGoroutines() < cfg.Limits.ControlWorkers {
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("scheduler lanes never started (saw %d)", schedulerGoroutines())
		}
		time.Sleep(time.Millisecond)
	}

	cancel()
	select {
	case <-stopped:
	case <-time.After(30 * time.Second):
		t.Fatal("Run did not return after cancellation")
	}

	if remaining := schedulerGoroutines(); remaining != 0 {
		t.Fatalf("Run returned with %d scheduler lane(s) still running", remaining)
	}
	if svc.running.Load() {
		t.Fatal("Run returned while still reporting itself as running")
	}
}

// blockingSocket keeps Run alive until its context is cancelled.
type blockingSocket struct {
	fakeSocket
}

func (b *blockingSocket) Run(ctx context.Context) error {
	<-ctx.Done()
	return nil
}
