package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestSchemaV67AddsDurableReplayCancellationObligations(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDir(stateDir); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
		t.Fatal(err)
	}
	for version := baselineSchemaVersion + 1; version <= 66; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	var table, index string
	if err := st.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name='replay_cancellations'`).Scan(&table); err != nil {
		t.Fatal(err)
	}
	if err := st.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='index' AND name='replay_cancellations_due_idx'`).Scan(&index); err != nil {
		t.Fatal(err)
	}
	if table != "replay_cancellations" || index != "replay_cancellations_due_idx" {
		t.Fatalf("migration objects = %q, %q", table, index)
	}
}

func TestSchemaV67FailsClosedOnAnIncompatiblePreexistingTable(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDir(stateDir); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
		t.Fatal(err)
	}
	for version := baselineSchemaVersion + 1; version <= 66; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	if _, err := db.Exec(`CREATE TABLE replay_cancellations (wrong_shape TEXT)`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(stateDir); err == nil {
		t.Fatal("incompatible table was silently accepted")
	}
	db, err = sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var version int
	if err := db.QueryRow(`SELECT version FROM schema_version`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	if version != 66 {
		t.Fatalf("schema version = %d, want rollback to 66", version)
	}
}
