package replaycontrol

import (
	"context"
	"errors"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

type fakeCoop struct {
	calls     int
	revision  int64
	operation coop.Operation
	turn      coop.Turn
}

func (f *fakeCoop) GetSession(context.Context, string) (coop.Session, error) {
	return coop.Session{ID: "ses_1", Revision: 9}, nil
}

func (f *fakeCoop) OperationByKey(context.Context, string) (coop.Operation, error) {
	return f.operation, nil
}

func (f *fakeCoop) GetTurn(context.Context, string, string) (coop.Turn, error) {
	return f.turn, nil
}

func (f *fakeCoop) Cancel(_ context.Context, _ string, _ string, _ string, revision int64) (coop.Turn, coop.Operation, error) {
	f.calls++
	f.revision = revision
	return coop.Turn{}, coop.Operation{}, nil
}

type fakeActive struct{ runID, runKey string }

func (f *fakeActive) Cancel(runID, runKey string) { f.runID, f.runKey = runID, runKey }

func TestCancelInterruptsTheExactActiveRunAndRemoteTurn(t *testing.T) {
	run := core.AgentRun{
		ID: "run_1", IdempotencyKey: "responder:run:1", SessionID: "ses_1",
		CoopTurnID: "turn_1", ExpectedRevision: 3,
	}
	var audit core.AuditEvent
	remote := &fakeCoop{}
	active := &fakeActive{}
	controller := Controller{
		CancelReplay: func(context.Context, string, string, string) (core.AgentRun, bool, bool, error) {
			return run, true, false, nil
		},
		Audit: func(_ context.Context, event core.AuditEvent) error { audit = event; return nil },
		Coop:  remote, Active: active,
	}
	if err := controller.Cancel(context.Background(), "slack_replay_1", run.IdempotencyKey, "cli"); err != nil {
		t.Fatal(err)
	}
	if active.runID != "run_1" || active.runKey != run.IdempotencyKey || remote.calls != 1 || remote.revision != 9 {
		t.Fatalf("cancel effects = active %q/%q remote calls=%d revision=%d", active.runID, active.runKey, remote.calls, remote.revision)
	}
	if audit.Kind != "replay.cancel" || audit.Outcome != "local_and_remote_cancelled" {
		t.Fatalf("audit = %+v", audit)
	}
}

type failingCoop struct{}

func (failingCoop) GetSession(context.Context, string) (coop.Session, error) {
	return coop.Session{}, errors.New("offline")
}

func (failingCoop) OperationByKey(context.Context, string) (coop.Operation, error) {
	return coop.Operation{}, errors.New("offline")
}

func (failingCoop) GetTurn(context.Context, string, string) (coop.Turn, error) {
	return coop.Turn{}, errors.New("offline")
}

func (failingCoop) Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error) {
	return coop.Turn{}, coop.Operation{}, errors.New("offline")
}

func TestCancelKeepsDurableCancellationWhenRemoteInterruptFails(t *testing.T) {
	run := core.AgentRun{
		ID: "run_1", SessionID: "ses_1", CoopTurnID: "turn_1",
	}
	var audit core.AuditEvent
	controller := Controller{
		CancelReplay: func(context.Context, string, string, string) (core.AgentRun, bool, bool, error) {
			return run, true, false, nil
		},
		Audit: func(_ context.Context, event core.AuditEvent) error { audit = event; return nil },
		Coop:  failingCoop{},
	}
	if err := controller.Cancel(context.Background(), "slack_replay_1", "", "cli"); err == nil {
		t.Fatal("remote interruption failure was reported as success")
	}
	if audit.Outcome != "local_cancelled_remote_best_effort_failed" {
		t.Fatalf("audit = %+v", audit)
	}
}

func TestCancelPersistsItsReceiptAfterTheCallerDeadline(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	controller := Controller{
		CancelReplay: func(context.Context, string, string, string) (core.AgentRun, bool, bool, error) {
			return core.AgentRun{}, true, false, nil
		},
		Audit: func(ctx context.Context, _ core.AuditEvent) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			called = true
			return nil
		},
	}
	if err := controller.Cancel(ctx, "slack_replay_1", "", "cli"); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Fatal("durable cancellation receipt was not written")
	}
}

func TestCancelRetriesRemoteInterruptForAlreadyCancelledRun(t *testing.T) {
	remote := &fakeCoop{}
	controller := Controller{
		CancelReplay: func(context.Context, string, string, string) (core.AgentRun, bool, bool, error) {
			return core.AgentRun{
				ID: "run_1", State: core.AgentRunCancelled, IdempotencyKey: "run-key",
				SessionID: "ses_1", CoopTurnID: "turn_1",
			}, false, false, nil
		},
		Audit: func(context.Context, core.AuditEvent) error { return nil },
		Coop:  remote,
	}
	if err := controller.Cancel(context.Background(), "slack_replay_1", "run-key", "cli"); err != nil {
		t.Fatal(err)
	}
	if remote.calls != 1 || remote.revision != 9 {
		t.Fatalf("remote retry calls=%d revision=%d", remote.calls, remote.revision)
	}
}

func TestCancelReportsInFlightSlackDeliveryAsUncertain(t *testing.T) {
	controller := Controller{
		CancelReplay: func(context.Context, string, string, string) (core.AgentRun, bool, bool, error) {
			return core.AgentRun{ID: "run_1"}, true, true, nil
		},
		Audit: func(context.Context, core.AuditEvent) error { return nil },
	}
	if err := controller.Cancel(context.Background(), "slack_replay_1", "", "cli"); err == nil {
		t.Fatal("in-flight Slack delivery was reported as a complete cancellation")
	}
}
