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

	"github.com/AndrewDryga/responder/internal/store"

	_ "modernc.org/sqlite"
)

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
