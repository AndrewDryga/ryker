package store

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Pruning spans the store and the memory repository, so it is tested here
// rather than in memorystore: Prune is whole-database maintenance and stays on
// Store, while what it removes lives in store.Memory.
func TestMemoryLifecyclePrunesMetadataAndDeletedChannelRollups(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	repo := st.Memory
	db := st.db
	now := time.Now().UTC().Truncate(time.Second)
	entry := core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE", SubjectKey: "style",
		Predicate: "guidance", Value: "Use plain language.", SourceRef: "slack:1",
		ActorID: "UOPERATOR", VisibilityKind: "workspace", VisibilityID: "TWORKSPACE",
		ExpiresAt: now.Add(30 * 24 * time.Hour),
	}
	if _, _, err := repo.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	entry.Value = "Start with plain language."
	if _, _, err := repo.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	old := now.Add(-60 * 24 * time.Hour).Format(timestampFormat)
	if _, err := db.ExecContext(ctx, `UPDATE memory_supersessions SET created_at = ?`, old); err != nil {
		t.Fatal(err)
	}
	state, _ := json.Marshal(core.AgentMemory{SituationSummary: "Private history."})
	if _, err := db.ExecContext(ctx, `
		INSERT INTO memory_rollups (
		  id, scope_kind, scope_key, repository, period_start, period_end,
		  state_json, source_refs_json, source_count, expires_at, created_at, updated_at
		) VALUES ('dream_private', 'channel', 'GPRIVATE', 'repo', ?, ?, ?, '[]', 1, ?, ?, ?)`,
		old, old, string(state), now.Add(time.Hour).Format(timestampFormat), old, old); err != nil {
		t.Fatal(err)
	}
	deleted, err := st.Memory.DeleteConversationMemories(ctx, "GPRIVATE")
	if err != nil || deleted != 1 {
		t.Fatalf("channel memory deletion = %d, %v", deleted, err)
	}
	if _, err := repo.GetMemoryRollupByID(ctx, "dream_private"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("private rollup survived channel deletion: %v", err)
	}
	result, err := st.Prune(
		ctx, now.Add(-time.Hour), now.Add(-90*24*time.Hour),
		now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour),
	)
	if err != nil || result.MemorySupersessions != 1 {
		t.Fatalf("memory metadata prune = %+v, %v", result, err)
	}
}

func TestMemoryExpiryPruneAndRecentEvidenceIsolation(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	repo := st.Memory
	db := st.db
	entry, _, err := repo.UpsertMemoryEntry(ctx, core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
		SubjectKey: "portal", Predicate: "evidence_route",
		Value: "emisar:service/portal", SourceRef: "slack_1", ActorID: "UOPERATOR",
		VisibilityKind: "workspace", VisibilityID: "TWORKSPACE",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(
		`UPDATE memory_entries SET expires_at = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(timestampFormat), entry.ID,
	); err != nil {
		t.Fatal(err)
	}
	result, err := st.Prune(
		ctx,
		time.Now().Add(-time.Hour),
		time.Now().Add(-time.Hour),
		time.Now().Add(-time.Hour),
		time.Now().Add(-time.Hour),
	)
	if err != nil || result.MemoryEntries != 1 {
		t.Fatalf("prune = %+v, %v", result, err)
	}
	_, err = st.Intelligence.RecordEvidence(ctx, []core.Evidence{
		{
			ChannelID: "COPS", SourceInput: "slack_current", Claim: "current",
			Observation: "excluded", SourceType: "slack", SourceName: "Slack",
		},
		{
			ChannelID: "COPS", SourceInput: "slack_prior", Claim: "prior",
			Observation: "same channel", SourceType: "emisar", SourceName: "Emisar",
		},
		{
			ChannelID: "COTHER", SourceInput: "slack_other", Claim: "private",
			Observation: "other channel", SourceType: "emisar", SourceName: "Emisar",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := repo.ListRecentChannelEvidence(ctx, "COPS", "slack_current", 10)
	if err != nil || len(evidence) != 1 || evidence[0].Claim != "prior" {
		t.Fatalf("recent evidence = %+v, %v", evidence, err)
	}
}
