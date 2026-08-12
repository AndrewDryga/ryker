// Package retrydelay owns bounded exponential retry timing.
package retrydelay

import (
	"math"
	"time"
)

// Duration returns 2^attempt seconds up to the five-minute ceiling.
func Duration(attempt int) time.Duration {
	seconds := math.Min(300, math.Pow(2, float64(min(max(attempt, 1), 9))))
	return time.Duration(seconds) * time.Second
}

// DependencyWait keeps a one-second handoff for short waits, then polls at an
// eighth of elapsed time up to fifteen seconds.
func DependencyWait(waited time.Duration) time.Duration {
	return min(max(waited/8, time.Second), 15*time.Second)
}

func At(now time.Time, attempt int, minimum time.Duration) time.Time {
	return now.Add(max(Duration(attempt), minimum))
}

func Exhausted(attempt, maximum int) bool { return attempt >= maximum }

func NextSessionGeneration(current, observed int, unusable bool) int {
	next := max(current, observed)
	if unusable && observed > 0 {
		next = max(next, observed+1)
	}
	return next
}
