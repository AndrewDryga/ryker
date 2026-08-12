package replayinterrupt

import (
	"context"
	"errors"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

type scriptedCoop struct {
	sessions     []coop.Session
	turn         coop.Turn
	operation    coop.Operation
	operationErr error
	cancelErrs   []error
	cancelHooks  []func()
	cancelCalls  int
}

func (f *scriptedCoop) GetSession(context.Context, string) (coop.Session, error) {
	if len(f.sessions) == 0 {
		return coop.Session{}, errors.New("missing session")
	}
	value := f.sessions[0]
	if len(f.sessions) > 1 {
		f.sessions = f.sessions[1:]
	}
	return value, nil
}
func (f *scriptedCoop) GetTurn(context.Context, string, string) (coop.Turn, error) {
	return f.turn, nil
}
func (f *scriptedCoop) OperationByKey(context.Context, string) (coop.Operation, error) {
	return f.operation, f.operationErr
}
func (f *scriptedCoop) Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error) {
	f.cancelCalls++
	if len(f.cancelHooks) > 0 {
		f.cancelHooks[0]()
		f.cancelHooks = f.cancelHooks[1:]
	}
	if len(f.cancelErrs) == 0 {
		return f.turn, coop.Operation{}, nil
	}
	err := f.cancelErrs[0]
	f.cancelErrs = f.cancelErrs[1:]
	if err == nil {
		f.turn.State = "cancelled"
	}
	return f.turn, coop.Operation{}, err
}

func TestCancelShortCircuitsAnObservedTerminalTurn(t *testing.T) {
	fake := &scriptedCoop{turn: coop.Turn{ID: "turn_1", State: "cancelled"}}
	if err := Cancel(context.Background(), fake, core.AgentRun{SessionID: "ses_1", CoopTurnID: "turn_1"}); err != nil {
		t.Fatal(err)
	}
	if fake.cancelCalls != 0 {
		t.Fatalf("cancel calls = %d", fake.cancelCalls)
	}
}

func TestCancelRecoversALostSubmitReceiptByOperationKey(t *testing.T) {
	fake := &scriptedCoop{
		operation: coop.Operation{State: "succeeded", ResourceType: "turn", ResourceID: "turn_1"},
		turn:      coop.Turn{ID: "turn_1", State: "running"},
		sessions:  []coop.Session{{Revision: 4}},
	}
	if err := Cancel(context.Background(), fake, core.AgentRun{IdempotencyKey: "run-key", SessionID: "ses_1"}); err != nil {
		t.Fatal(err)
	}
	if fake.cancelCalls != 1 {
		t.Fatalf("cancel calls = %d", fake.cancelCalls)
	}
}

func TestCancelRefetchesRevisionAfterConflict(t *testing.T) {
	fake := &scriptedCoop{
		turn:       coop.Turn{ID: "turn_1", State: "running"},
		sessions:   []coop.Session{{Revision: 4}, {Revision: 5}},
		cancelErrs: []error{&coop.APIError{Status: 409, Code: "revision_conflict"}, nil},
	}
	if err := Cancel(context.Background(), fake, core.AgentRun{IdempotencyKey: "run-key", SessionID: "ses_1", CoopTurnID: "turn_1"}); err != nil {
		t.Fatal(err)
	}
	if fake.cancelCalls != 2 {
		t.Fatalf("cancel calls = %d", fake.cancelCalls)
	}
}

func TestCancelReconcilesALostCancelResponse(t *testing.T) {
	fake := &scriptedCoop{
		turn: coop.Turn{ID: "turn_1", State: "running"}, sessions: []coop.Session{{Revision: 4}},
		cancelErrs: []error{errors.New("response lost")},
	}
	// The fake represents a remote commit whose response was lost.
	fake.cancelErrs = []error{errors.New("response lost")}
	fake.cancelHooks = []func(){func() { fake.turn.State = "cancelled" }}
	if err := Cancel(context.Background(), fake, core.AgentRun{IdempotencyKey: "run-key", SessionID: "ses_1", CoopTurnID: "turn_1"}); err != nil {
		t.Fatal(err)
	}
}

func TestCancelClassifiesMissingSubmitOperation(t *testing.T) {
	fake := &scriptedCoop{operationErr: &coop.APIError{Status: 404, Code: "not_found"}}
	err := Cancel(context.Background(), fake, core.AgentRun{IdempotencyKey: "run-key", SessionID: "ses_1"})
	if !errors.Is(err, ErrSubmitOperationNotFound) {
		t.Fatalf("error = %v", err)
	}
}

func TestCancelSettlesADefinitivelyFailedSubmitWithoutRetrying(t *testing.T) {
	fake := &scriptedCoop{operation: coop.Operation{Method: "SubmitTurn", State: "failed"}}
	if err := Cancel(context.Background(), fake, core.AgentRun{
		IdempotencyKey: "run-key", SessionID: "ses_1",
	}); err != nil {
		t.Fatal(err)
	}
	if fake.cancelCalls != 0 {
		t.Fatalf("cancel calls = %d", fake.cancelCalls)
	}
}
