package memorystore_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/memorystore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

func TestMemoryRollupCompactionRecallAndHealth(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := memorystore.New(db, time.Now)
	now := time.Now().UTC().Truncate(time.Second)
	state := core.AgentMemory{
		SituationSummary: "A deployment was reviewed.",
		Decisions:        []string{"Keep the canary until the error rate settles."},
	}
	data, _ := json.Marshal(state)
	for index, thread := range []string{"1700.1", "1700.2"} {
		updated := now.Add(time.Duration(-48+index) * time.Hour)
		if _, err := db.ExecContext(ctx, `
			INSERT INTO conversation_memories (
			  channel_id, thread_ts, repository, last_message_ts, state_json, updated_at
			) VALUES ('CPUBLIC', ?, 'repo', ?, ?, ?)`,
			thread, thread, string(data), updated.Format(core.TimestampFormat)); err != nil {
			t.Fatal(err)
		}
	}
	sources, err := repo.ListConversationMemoryCandidates(ctx, now.Add(-24*time.Hour), 10)
	if err != nil || len(sources) != 2 {
		t.Fatalf("sources = %+v, %v", sources, err)
	}
	period := now.Add(-7 * 24 * time.Hour)
	period = time.Date(period.Year(), period.Month(), period.Day(), 0, 0, 0, 0, time.UTC)
	rollup := core.MemoryRollup{
		ScopeKind: "repository", ScopeKey: "repo", Repository: "repo",
		PeriodStart: period, PeriodEnd: now.Add(-47 * time.Hour), State: state,
		SourceRefs:  []string{"slack:CPUBLIC:1700.1", "slack:CPUBLIC:1700.2"},
		SourceCount: 2, ExpiresAt: now.Add(30 * 24 * time.Hour),
	}
	memories := []core.ConversationMemory{sources[0].Memory, sources[1].Memory}
	if err := repo.CompactConversationMemories(ctx, rollup, memories); err != nil {
		t.Fatal(err)
	}
	if count, err := repo.CountConversationMemories(ctx); err != nil || count != 0 {
		t.Fatalf("conversation count = %d, %v", count, err)
	}
	rollups, err := repo.ListMemoryRollupsForContext(ctx, "COTHER", "repo", 4)
	if err != nil || len(rollups) != 1 || rollups[0].SourceCount != 2 {
		t.Fatalf("rollups = %+v, %v", rollups, err)
	}
	if err := repo.MarkMemoryRollupsRecalled(ctx, []string{rollups[0].ID}); err != nil {
		t.Fatal(err)
	}
	health, err := repo.MemoryHealth(ctx)
	if err != nil || health.Rollups != 1 {
		t.Fatalf("health = %+v, %v", health, err)
	}
}

func TestMemoryReviewQueueNeverMutatesUntilResolved(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := memorystore.New(db, time.Now)
	now := time.Now().UTC()
	add := func(subject string) core.MemoryEntry {
		entry, _, err := repo.UpsertMemoryEntry(ctx, core.MemoryEntry{
			ScopeKind: "workspace", ScopeKey: "TWORKSPACE", SubjectKey: subject,
			Predicate: "guidance", Value: "Prefer plain language before implementation detail.",
			SourceRef: "slack:" + subject, ActorID: "UOPERATOR",
			VisibilityKind: "workspace", VisibilityID: "TWORKSPACE",
			ExpiresAt: now.Add(90 * 24 * time.Hour),
		}, 20, 20)
		if err != nil {
			t.Fatal(err)
		}
		return entry
	}
	first := add("plain_language")
	second := add("explanation_style")
	old := now.Add(-45 * 24 * time.Hour).Format(core.TimestampFormat)
	if _, err := db.ExecContext(ctx, `
		UPDATE memory_entries SET updated_at = ?, last_reviewed_at = NULL WHERE id IN (?, ?)`,
		old, first.ID, second.ID); err != nil {
		t.Fatal(err)
	}
	if err := repo.RefreshMemoryReviewQueue(ctx, now.Add(-30*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	reviews, err := repo.ListPendingMemoryReviews(ctx, 10)
	if err != nil || len(reviews) != 3 {
		t.Fatalf("reviews = %+v, %v", reviews, err)
	}
	if active, _ := repo.CountMemoryForHome(ctx, "TWORKSPACE", "UOPERATOR"); active != 2 {
		t.Fatalf("review queue mutated entries: %d", active)
	}
	var duplicate core.MemoryReviewItem
	for _, review := range reviews {
		if review.Kind == "duplicate" {
			duplicate = review
		}
	}
	if _, err := repo.ResolveMemoryReview(ctx, duplicate.ID, "merge", "UOPERATOR"); err != nil {
		t.Fatal(err)
	}
	if active, _ := repo.CountMemoryForHome(ctx, "TWORKSPACE", "UOPERATOR"); active != 1 {
		t.Fatalf("duplicate merge retained %d entries", active)
	}
}

func TestMemoryReplacementRecordsHashOnlySupersession(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := memorystore.New(db, time.Now)
	entry := core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: "COPS", SubjectKey: "portal",
		Predicate: "alias_of", Value: "service:portal", SourceRef: "slack:1",
		ActorID: "UOPERATOR", VisibilityKind: "channel", VisibilityID: "COPS",
		ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
	}
	if _, _, err := repo.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	entry.Value = "service:portal-v2"
	if _, _, err := repo.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	var count int
	var previous, replacement string
	if err := db.QueryRowContext(ctx, `
		SELECT count(*), previous_value_hash, replacement_value_hash FROM memory_supersessions`,
	).Scan(&count, &previous, &replacement); err != nil {
		t.Fatal(err)
	}
	if count != 1 || len(previous) != 64 || len(replacement) != 64 || previous == replacement {
		t.Fatalf("supersession = count=%d previous=%q replacement=%q", count, previous, replacement)
	}
}
