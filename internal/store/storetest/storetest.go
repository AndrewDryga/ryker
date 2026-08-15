// Package storetest gives an extracted repository a migrated database to test
// against.
//
// A repository that lives outside store cannot open one for itself: store.Open
// runs the migrations, and a package store imports cannot import it back. The
// memory extraction hit this immediately — its tests needed both a migrated
// schema and raw access to the database, and an external test package could
// have one or the other, so they had to stay behind in package store.
//
// This closes that. It runs the migrations through the real store, closes it,
// and hands back an ordinary connection to the same file, configured with the
// same pragmas the store uses. Every extraction after memory can own its tests.
package storetest

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"

	_ "modernc.org/sqlite"
)

// TouchAgentRun bumps only updated_at on one agent run, imitating the cosmetic
// writers — card refreshes, episode progress — that shielded a zombie turn
// from the first silent-turn deadline (run_dba732ef: an 87-minute-old poll
// stamp under a 70-second-old updated_at). It lives here rather than on Store
// so a test-only writer does not occupy the production method set the
// architecture budget guards. It opens the caller's own database file; WAL and
// the busy timeout make the one short write safe beside the store under test.
func TouchAgentRun(t *testing.T, stateDir, sourceKind, sourceID string) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatalf("open the database under test: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`PRAGMA busy_timeout = 5000;`); err != nil {
		t.Fatalf("apply connection pragmas: %v", err)
	}
	if _, err := db.Exec(`
		UPDATE agent_runs SET updated_at = ?
		WHERE source_kind = ? AND source_id = ?`,
		time.Now().UTC().Format(core.TimestampFormat), sourceKind, sourceID,
	); err != nil {
		t.Fatalf("touch agent run: %v", err)
	}
}

// MakeAgentRunDue pulls one run's next_attempt_at into the past, so a test
// can walk a backoff without a settable store clock. The service clock is
// injectable but the lease predicate compares next_attempt_at against the
// store's own now, so advancing the service clock alone leaves a requeued run
// unleasable for its full real-time backoff. Same direct-SQL residence rule
// as TouchAgentRun above.
func MakeAgentRunDue(t *testing.T, stateDir, sourceKind, sourceID string) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatalf("open the database under test: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`PRAGMA busy_timeout = 5000;`); err != nil {
		t.Fatalf("apply connection pragmas: %v", err)
	}
	if _, err := db.Exec(`
		UPDATE agent_runs SET next_attempt_at = ?
		WHERE source_kind = ? AND source_id = ?`,
		time.Now().Add(-time.Minute).UTC().Format(core.TimestampFormat), sourceKind, sourceID,
	); err != nil {
		t.Fatalf("make agent run due: %v", err)
	}
}

// DB returns a connection to a freshly migrated database.
//
// The schema comes from the real store rather than a fixture, so a repository
// test cannot pass against a schema the product does not actually create.
func DB(t *testing.T) *sql.DB {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "state")
	migrated, err := store.Open(dir)
	if err != nil {
		t.Fatalf("migrate a database to test against: %v", err)
	}
	if err := migrated.Close(); err != nil {
		t.Fatalf("close the migrating store: %v", err)
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatalf("reopen the migrated database: %v", err)
	}
	// Matching the store's own connection settings. Foreign keys especially:
	// they are off by default, so without this a repository test would accept
	// writes the product rejects.
	if _, err := db.Exec(`
		PRAGMA foreign_keys = ON;
		PRAGMA busy_timeout = 5000;`,
	); err != nil {
		t.Fatalf("apply connection pragmas: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}
