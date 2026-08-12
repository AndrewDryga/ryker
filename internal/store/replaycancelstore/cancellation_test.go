package replaycancelstore

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	_ "modernc.org/sqlite"
)

func testRepository(t *testing.T) (*sql.DB, *Repository, *time.Time) {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+t.Name()+"?mode=memory&cache=shared")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE replay_cancellations (
		run_key TEXT PRIMARY KEY, replay_id TEXT, run_id TEXT, session_id TEXT, turn_id TEXT,
		state TEXT, failure_count INTEGER, next_attempt_at TEXT, last_error TEXT,
		created_at TEXT, updated_at TEXT)`); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
	return db, New(db, func() time.Time { return now }), &now
}

func insertCancellation(t *testing.T, db *sql.DB, key string, due, created time.Time) {
	t.Helper()
	if _, err := db.Exec(`INSERT INTO replay_cancellations VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, '', ?, ?)`,
		key, "replay-"+key, "run-"+key, "ses-"+key, "turn-"+key,
		due.Format(core.TimestampFormat), created.Format(core.TimestampFormat), created.Format(core.TimestampFormat)); err != nil {
		t.Fatal(err)
	}
}

func TestNextOrdersDueInterruptionsAndRoundTripsCreationTime(t *testing.T) {
	db, repo, now := testRepository(t)
	defer db.Close()
	insertCancellation(t, db, "later", now.Add(-time.Minute), now.Add(-time.Hour))
	insertCancellation(t, db, "first", now.Add(-time.Minute), now.Add(-2*time.Hour))
	got, err := repo.Next(context.Background())
	if err != nil || got.RunKey != "first" || !got.CreatedAt.Equal(now.Add(-2*time.Hour)) {
		t.Fatalf("next = %+v, %v", got, err)
	}
}

func TestCompleteAndRetryAreAbsorbingAfterConcurrentCompletion(t *testing.T) {
	db, repo, now := testRepository(t)
	defer db.Close()
	insertCancellation(t, db, "key", *now, *now)
	if err := repo.Complete(context.Background(), "key"); err != nil {
		t.Fatal(err)
	}
	if err := repo.Complete(context.Background(), "key"); err != nil {
		t.Fatalf("repeat complete: %v", err)
	}
	if err := repo.Retry(context.Background(), "key", "late failure", now.Add(time.Minute)); err != nil {
		t.Fatalf("late retry: %v", err)
	}
	if err := repo.Complete(context.Background(), "missing"); !errors.Is(err, core.ErrNotFound) {
		t.Fatalf("missing complete = %v", err)
	}
}

func TestRetryBoundsStoredTransportErrors(t *testing.T) {
	db, repo, now := testRepository(t)
	defer db.Close()
	insertCancellation(t, db, "key", *now, *now)
	if err := repo.Retry(context.Background(), "key", strings.Repeat("x", 5000), now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	var detail string
	if err := db.QueryRow(`SELECT last_error FROM replay_cancellations WHERE run_key='key'`).Scan(&detail); err != nil {
		t.Fatal(err)
	}
	if len(detail) > 1000 {
		t.Fatalf("stored error bytes = %d", len(detail))
	}
}
