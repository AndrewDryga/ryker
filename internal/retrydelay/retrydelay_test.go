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
