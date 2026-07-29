package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestMemoryEntryReplacementScopeVisibilityAndForget(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	base := core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: "COPS", SubjectKey: "old runner",
		Predicate: "alias_of", Value: "emisar:runner/current",
		SourceRef: "slack_1", ActorID: "UOPERATOR",
		VisibilityKind: "channel", VisibilityID: "COPS",
		ExpiresAt: now.Add(30 * 24 * time.Hour),
	}
	created, replaced, err := st.UpsertMemoryEntry(ctx, base, 10, 5)
	if err != nil || replaced || created.ID == "" {
		t.Fatalf("create = %+v, replaced=%t, err=%v", created, replaced, err)
	}
	base.Value = "emisar:runner/replacement"
	base.SourceRef = "slack_2"
	updated, replaced, err := st.UpsertMemoryEntry(ctx, base, 10, 5)
	if err != nil || !replaced || updated.ID != created.ID ||
		updated.Value != "emisar:runner/replacement" {
		t.Fatalf("replace = %+v, replaced=%t, err=%v", updated, replaced, err)
	}
	visible, err := st.ListMemoryForContext(
		ctx, "TWORKSPACE", "COPS", "repo", "UOPERATOR", 10,
	)
	if err != nil || len(visible) != 1 || visible[0].ID != created.ID {
		t.Fatalf("visible = %+v, %v", visible, err)
	}
	hidden, err := st.ListMemoryForContext(
		ctx, "TWORKSPACE", "COTHER", "repo", "UOPERATOR", 10,
	)
	if err != nil || len(hidden) != 0 {
		t.Fatalf("cross-channel memory leaked = %+v, %v", hidden, err)
	}
	deleted, err := st.DeleteMemoryEntry(ctx, created.ID)
	if err != nil || deleted.Value != "emisar:runner/replacement" {
		t.Fatalf("delete = %+v, %v", deleted, err)
	}
	if _, err := st.GetMemoryEntry(ctx, created.ID); err != ErrNotFound {
		t.Fatalf("deleted get error = %v", err)
	}
}

func TestMemoryExpiryPruneAndRecentEvidenceIsolation(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	entry, _, err := st.UpsertMemoryEntry(ctx, core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
		SubjectKey: "portal", Predicate: "evidence_route",
		Value: "emisar:service/portal", SourceRef: "slack_1", ActorID: "UOPERATOR",
		VisibilityKind: "workspace", VisibilityID: "TWORKSPACE",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec(
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
	)
	if err != nil || result.MemoryEntries != 1 {
		t.Fatalf("prune = %+v, %v", result, err)
	}
	_, err = st.RecordEvidence(ctx, []core.Evidence{
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
	evidence, err := st.ListRecentChannelEvidence(ctx, "COPS", "slack_current", 10)
	if err != nil || len(evidence) != 1 || evidence[0].Claim != "prior" {
		t.Fatalf("recent evidence = %+v, %v", evidence, err)
	}
}

func TestMemoryCapacityAppliesOnlyToNewLogicalEntries(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	entry := core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: "COPS", SubjectKey: "portal",
		Predicate: "alias_of", Value: "service:portal",
		SourceRef: "slack_1", ActorID: "UOPERATOR",
		VisibilityKind: "channel", VisibilityID: "COPS",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}
	if _, _, err := st.UpsertMemoryEntry(ctx, entry, 1, 1); err != nil {
		t.Fatal(err)
	}
	entry.Value = "service:portal-v2"
	if _, replaced, err := st.UpsertMemoryEntry(ctx, entry, 1, 1); err != nil || !replaced {
		t.Fatalf("replacement at capacity = replaced=%t, err=%v", replaced, err)
	}
	entry.SubjectKey = "database"
	if _, _, err := st.UpsertMemoryEntry(ctx, entry, 1, 1); err == nil {
		t.Fatal("new memory unexpectedly exceeded capacity")
	}
}

func TestMemoryHomePrivacyRepositoryBindingAndOrphanPrune(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	add := func(entry core.MemoryEntry) core.MemoryEntry {
		entry.SourceRef = "slack_1"
		entry.ActorID = "UOPERATOR"
		entry.ExpiresAt = time.Now().UTC().Add(time.Hour)
		saved, _, saveErr := st.UpsertMemoryEntry(ctx, entry, 20, 10)
		if saveErr != nil {
			t.Fatal(saveErr)
		}
		return saved
	}
	add(core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE", SubjectKey: "portal",
		Predicate: "alias_of", Value: "service:portal",
		VisibilityKind: "workspace", VisibilityID: "TWORKSPACE",
	})
	add(core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE", SubjectKey: "private",
		Predicate: "alias_of", Value: "service:private",
		VisibilityKind: "operator", VisibilityID: "UOTHER",
	})
	add(core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: "COPS", SubjectKey: "channel:COPS",
		Predicate: "repository_for_channel", Value: "repo-two",
		VisibilityKind: "channel", VisibilityID: "COPS",
	})
	add(core.MemoryEntry{
		ScopeKind: "repository", ScopeKey: "removed-repo", SubjectKey: "old",
		Predicate: "alias_of", Value: "repo:removed-repo/service",
		VisibilityKind: "workspace", VisibilityID: "TWORKSPACE",
	})
	home, err := st.ListMemoryForHome(ctx, "TWORKSPACE", "UOPERATOR", 10)
	if err != nil || len(home) != 2 {
		t.Fatalf("home entries = %+v, %v", home, err)
	}
	for _, entry := range home {
		if entry.SubjectKey == "private" || entry.ScopeKind == "channel" {
			t.Fatalf("private memory leaked into App Home: %+v", entry)
		}
	}
	binding, err := st.GetChannelRepositoryBinding(
		ctx, "TWORKSPACE", "COPS", "UOPERATOR",
	)
	if err != nil || binding.Value != "repo-two" {
		t.Fatalf("binding = %+v, %v", binding, err)
	}
	pruned, err := st.PruneOrphanMemoryEntries(ctx, []string{"repo-two"})
	if err != nil || pruned != 1 {
		t.Fatalf("orphan prune = %d, %v", pruned, err)
	}
	deleted, err := st.DeleteChannelMemoryEntries(ctx, "COPS")
	if err != nil || deleted != 1 {
		t.Fatalf("channel memory delete = %d, %v", deleted, err)
	}
}
