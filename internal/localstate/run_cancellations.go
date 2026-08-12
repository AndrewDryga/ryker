package localstate

import (
	"context"
	"sync"
)

// RunCancellations interrupts process-local work after its durable owner has
// been cancelled. Durable state remains authoritative; this registry only
// closes the gap between a control-plane cancellation and an in-flight HTTP
// request noticing that its database lease is gone.
type RunCancellations struct {
	mu     sync.Mutex
	next   uint64
	active map[string]map[uint64]context.CancelFunc
}

func NewRunCancellations() *RunCancellations {
	return &RunCancellations{active: make(map[string]map[uint64]context.CancelFunc)}
}

// Track returns a child context and an idempotent release function. Durable
// run state closes the cancel-before-registration race; this process-local map
// exists only to interrupt work that is already active.
func (r *RunCancellations) Track(parent context.Context, runID, runKey string) (context.Context, func()) {
	identity := runID + "\x00" + runKey
	ctx, cancel := context.WithCancel(parent)
	r.mu.Lock()
	r.next++
	token := r.next
	if r.active[identity] == nil {
		r.active[identity] = make(map[uint64]context.CancelFunc)
	}
	r.active[identity][token] = cancel
	r.mu.Unlock()
	return ctx, func() {
		r.mu.Lock()
		delete(r.active[identity], token)
		if len(r.active[identity]) == 0 {
			delete(r.active, identity)
		}
		r.mu.Unlock()
		cancel()
	}
}

func (r *RunCancellations) Cancel(runID, runKey string) {
	identity := runID + "\x00" + runKey
	r.mu.Lock()
	cancels := make([]context.CancelFunc, 0, len(r.active[identity]))
	for _, cancel := range r.active[identity] {
		cancels = append(cancels, cancel)
	}
	r.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}
