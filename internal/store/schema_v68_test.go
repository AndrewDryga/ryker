package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestSchemaV68PreservesOutboxAndAddsDurableReactions(t *testing.T) {
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
	for version := baselineSchemaVersion + 1; version <= 67; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	const now = "2026-08-12T12:00:00.000000000Z"
	if _, err := db.Exec(`
		INSERT INTO slack_deliveries (
		  id, operation, kind, channel_id, body_json, state,
		  next_attempt_at, created_at, updated_at
		) VALUES ('delivery_before_v68', 'post', 'notice', 'C1', '{}', 'sent', ?, ?, ?)`,
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
	if delivery, err := st.GetSlackDelivery(context.Background(), "delivery_before_v68"); err != nil || delivery.State != "sent" {
		t.Fatalf("preserved delivery = %+v, %v", delivery, err)
	}
	created, err := st.EnqueueSlackDelivery(context.Background(), core.SlackDelivery{
		ID: "delivery_reaction_v68", Operation: "reaction", Kind: "failure_marker_add",
		ChannelID: "C1", MessageTS: "1700.001", Status: "warning",
	})
	if err != nil || !created {
		t.Fatalf("enqueue reaction = %t, %v", created, err)
	}
}
