package store

import (
	"context"
	"testing"
	"time"
)

// The count exists so a stalled self-improvement loop is visible from the CLI.
//
// Corrections the product makes about itself are only actionable while they are
// pending, and until this was counted the only place they appeared was App Home
// — a surface nobody has to open. Six were pending on the deployed instance when
// this was written, all created that day, all expiring in thirteen days, and
// nothing reported them.
func TestCorrectionsAwaitingReviewAreCounted(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	now := time.Now().UTC()

	for _, c := range []struct {
		id      string
		status  string
		expires time.Time
	}{
		{"fixcand_fresh", "pending", now.Add(10 * 24 * time.Hour)},
		{"fixcand_soon", "pending", now.Add(2 * time.Hour)},
		{"fixcand_also_soon", "pending", now.Add(2 * 24 * time.Hour)},
		// Reviewed and lapsed candidates are not awaiting anything.
		{"fixcand_approved", "approved", now.Add(10 * 24 * time.Hour)},
		{"fixcand_lapsed", "pending", now.Add(-time.Hour)},
	} {
		if _, err := st.db.ExecContext(ctx, `
			INSERT INTO fixture_candidates (id, episode_id, run_id, capability,
			  correction_class, correction, status, created_at, expires_at, updated_at)
			VALUES (?,?,'run','cap','incomplete','detail',?,?,?,?)`,
			c.id, "ep_"+c.id, c.status, now.Format(timestampFormat),
			c.expires.Format(timestampFormat), now.Format(timestampFormat),
		); err != nil {
			t.Fatal(err)
		}
	}

	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.CorrectionsAwaitingReview != 3 {
		t.Fatalf(
			"awaiting review = %d, want 3 (approved and lapsed do not await anything)",
			metrics.CorrectionsAwaitingReview,
		)
	}
	if metrics.CorrectionsLapsingSoon != 2 {
		t.Fatalf(
			"lapsing soon = %d, want 2; without this the stall is visible only "+
				"after the corrections are already gone",
			metrics.CorrectionsLapsingSoon,
		)
	}
}
