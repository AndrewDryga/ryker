package store

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// The workflow URL is part of the observed check summary. Without a durable
// column, a restart turns an exact Actions link back into a generic PR link.
func TestSchemaV90AddsPublicationChecksURL(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDir(stateDir); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
		t.Fatal(err)
	}
	for version := baselineSchemaVersion + 1; version <= 89; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	if err := applySchemaStep(db, migrations[90], 89, 90); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := db.QueryRow(`
		SELECT COUNT(*) FROM pragma_table_info('publication_followups')
		WHERE name = 'checks_url' AND type = 'TEXT' AND dflt_value = "''"
		  AND "notnull" = 1`,
	).Scan(&count); err != nil || count != 1 {
		t.Fatalf("checks_url column = %d, %v", count, err)
	}
}
