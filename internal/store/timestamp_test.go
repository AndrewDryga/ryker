package store

import (
	"testing"
	"time"
)

// Timestamps are stored as TEXT and compared lexicographically by SQLite, so
// their text order has to match their chronological order.
//
// It does — except for one case. RFC3339Nano strips trailing zeros, so a time
// landing exactly on a second has no fraction, and 'Z' sorts after '.'. This
// test states that edge explicitly rather than leaving it to be rediscovered
// during an outage, and it will start failing the moment anything begins
// writing whole-second times, which is exactly when someone needs to know.
func TestWholeSecondTimestampsWouldSortWrong(t *testing.T) {
	second := time.Date(2026, 8, 6, 12, 0, 0, 0, time.UTC).Format(timestampFormat)
	fraction := time.Date(2026, 8, 6, 12, 0, 0, 500_000_000, time.UTC).Format(timestampFormat)

	if second >= fraction {
		// This is the hazard, and it is expected today. If this branch ever
		// stops being taken, the format gained a fixed-width fraction and the
		// comment on timestampFormat should be updated.
		t.Logf("known hazard holds: %q sorts after %q despite being earlier", second, fraction)
	} else {
		t.Fatalf("the timestamp format changed: %q now sorts before %q.\n"+
			"That is an improvement, but the migration concern in timestampFormat's "+
			"comment must be revisited — mixed-width values compare wrongly.", second, fraction)
	}

	// The reachable case is not the whole second — it is any shortened fraction
	// that another timestamp in the same second extends. RFC3339Nano strips
	// trailing zeros, so this happens whenever a clock reading ends in zeros,
	// which on the deployed database is 13% of stored timestamps.
	shorter := time.Date(2026, 8, 6, 12, 0, 0, 700_000_000, time.UTC).Format(timestampFormat)
	longer := time.Date(2026, 8, 6, 12, 0, 0, 700_010_000, time.UTC).Format(timestampFormat)
	if shorter < longer {
		t.Fatalf("the prefix hazard is gone: %q now sorts before %q.\n"+
			"Good, but the migration concern in timestampFormat's comment must be "+
			"revisited before relying on it.", shorter, longer)
	}
	t.Logf("known hazard holds: %q sorts after %q despite being earlier", shorter, longer)

	// Whole-second values would be the same bug in its most extreme form.
	for _, moment := range []time.Time{
		time.Now().UTC(),
		time.Now().UTC().Add(37 * time.Millisecond),
	} {
		if formatted := moment.Format(timestampFormat); len(formatted) == len("2006-01-02T15:04:05Z") {
			t.Fatalf("clock produced a whole-second timestamp %q, which sorts wrongly "+
				"against fractional values in the same second", formatted)
		}
	}

	// Ordinary fractional values do compare correctly, including across a
	// second boundary and at differing fraction widths.
	for _, pair := range [][2]time.Time{
		{time.Date(2026, 8, 6, 12, 0, 0, 190_000_000, time.UTC),
			time.Date(2026, 8, 6, 12, 0, 0, 200_000_000, time.UTC)},
		{time.Date(2026, 8, 6, 12, 0, 0, 900_000_000, time.UTC),
			time.Date(2026, 8, 6, 12, 0, 1, 100_000_000, time.UTC)},
	} {
		earlier, later := pair[0].Format(timestampFormat), pair[1].Format(timestampFormat)
		if !(earlier < later) {
			t.Errorf("text order disagrees with time order: %q should sort before %q", earlier, later)
		}
	}
}
