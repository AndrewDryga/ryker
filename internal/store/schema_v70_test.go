package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// A database migrated from v69 gains the artifact-body table, and the store
// can retain and read back the exact bytes an input artifact carried.
func TestSchemaV70RetainsInputArtifactBodies(t *testing.T) {
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
	for version := baselineSchemaVersion + 1; version <= 69; version++ {
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

	ctx := context.Background()
	body := []byte("# PR 529\n\nThe exact snapshot the model saw.")
	if err := st.Artifacts.Save(ctx, []core.ContextArtifact{
		{Digest: "digest-pr-529", Name: "github-pr-529.md", MediaType: "text/markdown", Body: body},
		// Oversized and binary artifacts are refused rather than stored.
		{Digest: "digest-huge", Name: "huge.md", MediaType: "text/markdown",
			Body: make([]byte, core.MaxRetainedArtifactBytes+1)},
		{Digest: "digest-image", Name: "shot.png", MediaType: "image/png", Body: []byte{1, 2, 3}},
	}); err != nil {
		t.Fatal(err)
	}
	// Saving the same digest twice stays idempotent.
	if err := st.Artifacts.Save(ctx, []core.ContextArtifact{
		{Digest: "digest-pr-529", Name: "github-pr-529.md", MediaType: "text/markdown", Body: body},
	}); err != nil {
		t.Fatal(err)
	}

	artifact, found, err := st.Artifacts.Get(ctx, "digest-pr-529")
	if err != nil || !found || string(artifact.Body) != string(body) ||
		artifact.Name != "github-pr-529.md" || artifact.MediaType != "text/markdown" {
		t.Fatalf("retained artifact = %+v, found %t, err %v", artifact, found, err)
	}
	for _, refused := range []string{"digest-huge", "digest-image"} {
		if _, found, err := st.Artifacts.Get(ctx, refused); err != nil || found {
			t.Fatalf("refused artifact %q was stored: found=%t err=%v", refused, found, err)
		}
	}
}
