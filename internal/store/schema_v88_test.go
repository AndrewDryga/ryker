package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestSchemaV88PreservesOutboxAndAddsDurableDeletes(t *testing.T) {
	if !tableRebuildMigrations[88] {
		t.Fatal("migration 88 rebuild is not protected by the foreign-key-safe wrapper")
	}
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
	for version := baselineSchemaVersion + 1; version <= 87; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	const now = "2026-08-18T12:00:00.000000000Z"
	if _, err := db.Exec(`
		INSERT INTO slack_deliveries (
		  id, operation, kind, channel_id, body_json, state,
		  next_attempt_at, created_at, updated_at
		) VALUES ('delivery_before_v88', 'post', 'notice', 'C1', '{}', 'sent', ?, ?, ?)`,
		now, now, now); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if version := schemaVersionOf(t, stateDir); version != currentSchemaVersion {
		t.Fatalf("schema version = %d, want %d", version, currentSchemaVersion)
	}
	var foreignKeys int
	if err := st.db.QueryRow(`PRAGMA foreign_keys`).Scan(&foreignKeys); err != nil || foreignKeys != 1 {
		t.Fatalf("foreign keys after v88 = %d, %v", foreignKeys, err)
	}
	rows, err := st.db.Query(`PRAGMA foreign_key_check`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	if rows.Next() {
		t.Fatal("migration 88 left a broken foreign-key reference")
	}
	if delivery, err := st.GetSlackDelivery(context.Background(), "delivery_before_v88"); err != nil || delivery.State != "sent" {
		t.Fatalf("preserved delivery = %+v, %v", delivery, err)
	}
	created, err := st.EnqueueSlackDelivery(context.Background(), core.SlackDelivery{
		ID: "delivery_delete_v88", Operation: "delete", Kind: "notice_retirement",
		ChannelID: "C1", MessageTS: "1700.001",
	})
	if err != nil || !created {
		t.Fatalf("enqueue delete = %t, %v", created, err)
	}
}
