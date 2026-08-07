package memorystore_test

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/memorystore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

func TestMemoryEntryReplacementScopeVisibilityAndForget(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := memorystore.New(db, time.Now)
	now := time.Now().UTC()
	base := core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: "COPS", SubjectKey: "old runner",
		Predicate: "alias_of", Value: "emisar:runner/current",
		SourceRef: "slack_1", ActorID: "UOPERATOR",
		VisibilityKind: "channel", VisibilityID: "COPS",
		ExpiresAt: now.Add(30 * 24 * time.Hour),
	}
	created, replaced, err := repo.UpsertMemoryEntry(ctx, base, 10, 5)
	if err != nil || replaced || created.ID == "" {
		t.Fatalf("create = %+v, replaced=%t, err=%v", created, replaced, err)
	}
	base.Value = "emisar:runner/replacement"
	base.SourceRef = "slack_2"
	updated, replaced, err := repo.UpsertMemoryEntry(ctx, base, 10, 5)
	if err != nil || !replaced || updated.ID != created.ID ||
		updated.Value != "emisar:runner/replacement" {
		t.Fatalf("replace = %+v, replaced=%t, err=%v", updated, replaced, err)
	}
	visible, err := repo.ListMemoryForContext(
		ctx, "TWORKSPACE", "COPS", "repo", "UOPERATOR", 10,
	)
	if err != nil || len(visible) != 1 || visible[0].ID != created.ID {
		t.Fatalf("visible = %+v, %v", visible, err)
	}
	hidden, err := repo.ListMemoryForContext(
		ctx, "TWORKSPACE", "COTHER", "repo", "UOPERATOR", 10,
	)
	if err != nil || len(hidden) != 0 {
		t.Fatalf("cross-channel memory leaked = %+v, %v", hidden, err)
	}
	deleted, err := repo.DeleteMemoryEntry(ctx, created.ID)
	if err != nil || deleted.Value != "emisar:runner/replacement" {
		t.Fatalf("delete = %+v, %v", deleted, err)
	}
	if _, err := repo.GetMemoryEntry(ctx, created.ID); err != core.ErrNotFound {
		t.Fatalf("deleted get error = %v", err)
	}
}

func TestOperatorGuidanceIsCrossChannelButNotCrossOperator(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := memorystore.New(db, time.Now)
	entry, _, err := repo.UpsertMemoryEntry(ctx, core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
		SubjectKey: "fix_explanation_style", Predicate: "guidance",
		Value:     "Start with a plain-language summary before technical details.",
		SourceRef: "slack_guidance", ActorID: "UOPERATOR",
		VisibilityKind: "operator", VisibilityID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(90 * 24 * time.Hour),
	}, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	visible, err := repo.ListMemoryForContext(
		ctx, "TWORKSPACE", "COTHER", "repo", "UOPERATOR", 10,
	)
	if err != nil || len(visible) != 1 || visible[0].ID != entry.ID {
		t.Fatalf("cross-channel guidance = %+v, %v", visible, err)
	}
	hidden, err := repo.ListMemoryForContext(
		ctx, "TWORKSPACE", "COTHER", "repo", "UOTHER", 10,
	)
	if err != nil || len(hidden) != 0 {
		t.Fatalf("operator guidance leaked = %+v, %v", hidden, err)
	}
}

func TestMemoryCapacityAppliesOnlyToNewLogicalEntries(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := memorystore.New(db, time.Now)
	entry := core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: "COPS", SubjectKey: "portal",
		Predicate: "alias_of", Value: "service:portal",
		SourceRef: "slack_1", ActorID: "UOPERATOR",
		VisibilityKind: "channel", VisibilityID: "COPS",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}
	if _, _, err := repo.UpsertMemoryEntry(ctx, entry, 1, 1); err != nil {
		t.Fatal(err)
	}
	entry.Value = "service:portal-v2"
	if _, replaced, err := repo.UpsertMemoryEntry(ctx, entry, 1, 1); err != nil || !replaced {
		t.Fatalf("replacement at capacity = replaced=%t, err=%v", replaced, err)
	}
	entry.SubjectKey = "database"
	if _, _, err := repo.UpsertMemoryEntry(ctx, entry, 1, 1); err == nil {
		t.Fatal("new memory unexpectedly exceeded capacity")
	}
}

func TestMemoryHomePrivacyRepositoryBindingAndOrphanPrune(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := memorystore.New(db, time.Now)
	add := func(entry core.MemoryEntry) core.MemoryEntry {
		entry.SourceRef = "slack_1"
		entry.ActorID = "UOPERATOR"
		entry.ExpiresAt = time.Now().UTC().Add(time.Hour)
		saved, _, saveErr := repo.UpsertMemoryEntry(ctx, entry, 20, 10)
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
	home, err := repo.ListMemoryForHome(ctx, "TWORKSPACE", "UOPERATOR", 10)
	if err != nil || len(home) != 2 {
		t.Fatalf("home entries = %+v, %v", home, err)
	}
	for _, entry := range home {
		if entry.SubjectKey == "private" || entry.ScopeKind == "channel" {
			t.Fatalf("private memory leaked into App Home: %+v", entry)
		}
	}
	binding, err := repo.GetChannelRepositoryBinding(
		ctx, "TWORKSPACE", "COPS", "UOPERATOR",
	)
	if err != nil || binding.Value != "repo-two" {
		t.Fatalf("binding = %+v, %v", binding, err)
	}
	pruned, err := repo.PruneOrphanMemoryEntries(ctx, []string{"repo-two"})
	if err != nil || pruned != 1 {
		t.Fatalf("orphan prune = %d, %v", pruned, err)
	}
	deleted, err := repo.DeleteChannelMemoryEntries(ctx, "COPS")
	if err != nil || deleted != 1 {
		t.Fatalf("channel memory delete = %d, %v", deleted, err)
	}
}
