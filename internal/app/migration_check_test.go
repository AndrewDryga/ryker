package app

import (
	"os"
	"path/filepath"
	"testing"
)

// The check must never be what damages the database it is checking.
//
// It runs against a deployed instance, so the source has to come out
// byte-identical. A check that migrates the live database in place would be
// worse than having no check at all.
func TestMigrationCheckLeavesTheSourceUntouched(t *testing.T) {
	source := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(source, 0o700); err != nil {
		t.Fatal(err)
	}
	original := []byte("not a real database, but bytes that must not change")
	if err := os.WriteFile(
		filepath.Join(source, "responder.db"), original, 0o600,
	); err != nil {
		t.Fatal(err)
	}

	destination := filepath.Join(t.TempDir(), "copy")
	if err := os.MkdirAll(destination, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := copyDatabase(source, destination); err != nil {
		t.Fatal(err)
	}

	// Write to the copy the way a migration would.
	if err := os.WriteFile(
		filepath.Join(destination, "responder.db"), []byte("migrated"), 0o600,
	); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(filepath.Join(source, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(original) {
		t.Fatal("migrating the copy changed the source database")
	}
}

// A missing database has to be reported as such rather than silently checking
// nothing and reporting success.
func TestMigrationCheckReportsAMissingDatabase(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "copy")
	if err := os.MkdirAll(destination, 0o700); err != nil {
		t.Fatal(err)
	}
	err := copyDatabase(filepath.Join(t.TempDir(), "absent"), destination)
	if err == nil {
		t.Fatal("a missing source database was accepted, so the check would prove nothing")
	}
}
