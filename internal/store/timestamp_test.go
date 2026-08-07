package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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

// The hazard is not confined to the format. It reaches a production query, and
// this is the evidence for that.
//
// A cleanup row eligible at .5Z is invisible to a caller asking at .53Z, even
// though half a second is genuinely earlier than 530 milliseconds. NextCleanup
// filters with "eligible_at <= ?", SQLite compares those as text, and the
// terminating Z sorts after every digit — so the shorter fraction loses. The
// row is skipped for the remainder of its second and then appears, which is
// what an intermittent failure looks like from the outside.
//
// This is the shape TestResolvedDeletedWorkIsClosedAndQueuedForSafeCleanup
// failed in twice and never reproduced under roughly forty deliberate
// attempts: it writes eligible_at and then asks in the same second, so it is
// exposed whenever the written fraction is a strict prefix of the asked one.
// That it can be produced on demand here does not prove it produced those two
// failures — but it does retire "no mis-ordering pair exists in the data" as a
// reason not to migrate. One exists the moment two timestamps in a second have
// different fraction widths.
func TestShortenedFractionHidesAnEligibleRowFromNextCleanup(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	event := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	for _, step := range []error{
		st.SetChannel(ctx, incident.ID, "CDELETED", "ems-deleted"),
		st.SetRoot(ctx, incident.ID, "1700.001"),
		st.SetCoopSession(ctx, incident.ID, "session-deleted", "fork-deleted", 1),
	} {
		if step != nil {
			t.Fatal(step)
		}
	}
	resolved := event
	resolved.DedupeKey = "delivery-resolved"
	resolved.BodyDigest = "resolved-digest"
	resolved.Signals = append([]core.Signal(nil), event.Signals...)
	resolved.Signals[0].EventID = "event-resolved"
	resolved.Signals[0].Status = core.SignalResolved
	resolved.Signals[0].ReceivedAt = time.Now().UTC()
	if _, err := st.ApplySignals(ctx, resolved, time.Hour, 0, 100); err != nil {
		t.Fatal(err)
	}
	deletedAt := time.Now().UTC()
	if _, err := st.SetIncidentChannelState(
		ctx, "CDELETED", core.ChannelDeleted, deletedAt,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RetireResolvedDeletedWork(ctx, deletedAt.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}

	base := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	eligible := base.Add(500 * time.Millisecond)
	asked := base.Add(530 * time.Millisecond)
	if eligible.After(asked) {
		t.Fatal("the test's own premise is wrong: .5s must precede .53s")
	}
	if _, err := st.db.Exec(
		`UPDATE coop_cleanup SET eligible_at = ?, next_attempt_at = ?`,
		eligible.Format(timestampFormat), eligible.Format(timestampFormat),
	); err != nil {
		t.Fatal(err)
	}

	_, err = st.NextCleanup(ctx, asked)
	if err == nil {
		// The format gained a fixed-width fraction, or the comparison learned
		// to normalize. Either way the hazard is closed: delete this test, drop
		// the warning on timestampFormat, and take the flaky-cleanup task off
		// its "root cause unfixed" hold.
		t.Fatal("the timestamp comparison hazard is fixed — retire this test")
	}
	t.Logf(
		"known hazard holds: a row eligible at %q is hidden from a caller asking at %q",
		eligible.Format(timestampFormat), asked.Format(timestampFormat),
	)
}
