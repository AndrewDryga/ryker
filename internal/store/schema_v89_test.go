package store

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// Cards used to recover check counts from a sentence such as "2 of 2". The
// migration makes the poll result durable so rendering remains typed.
func TestSchemaV89AddsStructuredPublicationCheckCounts(t *testing.T) {
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
	for version := baselineSchemaVersion + 1; version <= 88; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	if err := applySchemaStep(db, migrations[89], 88, 89); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, column := range []string{"checks_total", "checks_passed", "checks_failed"} {
		var count int
		if err := db.QueryRow(`
			SELECT COUNT(*) FROM pragma_table_info('publication_followups')
			WHERE name = ? AND type = 'INTEGER' AND dflt_value = '0' AND "notnull" = 1`,
			column,
		).Scan(&count); err != nil || count != 1 {
			t.Fatalf("column %s = %d, %v", column, count, err)
		}
	}
}
