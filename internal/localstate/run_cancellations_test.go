package localstate

import (
	"context"
	"testing"
)

func TestRunCancellationsClosesOnlyTheExactActiveContext(t *testing.T) {
	registry := NewRunCancellations()
	active, releaseActive := registry.Track(context.Background(), "run_active", "generation_1")
	activeFinalizer, releaseFinalizer := registry.Track(context.Background(), "run_active", "generation_1")
	defer releaseFinalizer()
	newGeneration, releaseNewGeneration := registry.Track(context.Background(), "run_active", "generation_2")
	defer releaseNewGeneration()
	other, releaseOther := registry.Track(context.Background(), "run_other", "generation_1")
	defer releaseOther()
	registry.Cancel("run_active", "generation_1")
	if active.Err() == nil {
		t.Fatal("active context was not cancelled")
	}
	if activeFinalizer.Err() == nil {
		t.Fatal("overlapping finalizer context was not cancelled")
	}
	if other.Err() != nil {
		t.Fatal("unrelated run context was cancelled")
	}
	if newGeneration.Err() != nil {
		t.Fatal("newer execution generation was cancelled")
	}
	releaseActive()
}
