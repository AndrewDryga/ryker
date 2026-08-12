package retrydelay

import (
	"testing"
	"time"
)

func TestDurationReachesAndHoldsCeiling(t *testing.T) {
	for attempt, want := range map[int]time.Duration{
		1:  2 * time.Second,
		8:  256 * time.Second,
		9:  300 * time.Second,
		20: 300 * time.Second,
	} {
		if got := Duration(attempt); got != want {
			t.Errorf("Duration(%d) = %s, want %s", attempt, got, want)
		}
	}
}

func TestDependencyWaitHoldsFloorAndCeiling(t *testing.T) {
	for waited, want := range map[time.Duration]time.Duration{
		0:                time.Second,
		16 * time.Second: 2 * time.Second,
		2 * time.Minute:  15 * time.Second,
		time.Hour:        15 * time.Second,
		-time.Hour:       time.Second,
	} {
		if got := DependencyWait(waited); got != want {
			t.Errorf("DependencyWait(%s) = %s, want %s", waited, got, want)
		}
	}
}

func TestRetryPoliciesAreMonotonicAndBounded(t *testing.T) {
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
	if got := At(now, 1, 30*time.Second); !got.Equal(now.Add(30 * time.Second)) {
		t.Fatalf("minimum retry = %s", got)
	}
	if !Exhausted(3, 3) || Exhausted(2, 3) {
		t.Fatal("exhaustion boundary changed")
	}
	if got := NextSessionGeneration(3, 3, true); got != 4 {
		t.Fatalf("unusable generation = %d", got)
	}
	if got := NextSessionGeneration(7, 2, true); got != 7 {
		t.Fatalf("generation moved backwards to %d", got)
	}
}
