package incidentsessionstore_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// A concurrent generation advance must never let an older writable create
// bind through the new generation. That would restore the exact authority the
// rotation is meant to remove.
func TestAStaleWritableSessionCannotCrossANewerGeneration(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incident, created, err := st.CreateManualIncident(
		ctx, "repo", "source", "title", "summary", "U123", "C123", "1700.1", 10,
	)
	if err != nil || !created {
		t.Fatalf("create incident = %+v, %t, %v", incident, created, err)
	}

	rotated, err := st.IncidentSessions.RotateReadOnly(
		ctx, incident.ID, "legacy-writable", 2, "legacy writable authority", time.Now(),
	)
	if rotated || !errors.Is(err, core.ErrConflict) {
		t.Fatalf("stale rotation = %t, %v; want conflict", rotated, err)
	}
	if _, err := st.GetCoopCleanup(ctx, "legacy-writable"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("stale session gained cleanup ownership: %v", err)
	}
}
