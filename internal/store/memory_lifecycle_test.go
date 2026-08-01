package store

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestMemoryRollupCompactionRecallAndHealth(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Truncate(time.Second)
	state := core.AgentMemory{
		SituationSummary: "A deployment was reviewed.",
		Decisions:        []string{"Keep the canary until the error rate settles."},
	}
	data, _ := json.Marshal(state)
	for index, thread := range []string{"1700.1", "1700.2"} {
		updated := now.Add(time.Duration(-48+index) * time.Hour)
		if _, err := st.db.ExecContext(ctx, `
			INSERT INTO conversation_memories (
			  channel_id, thread_ts, repository, last_message_ts, state_json, updated_at
			) VALUES ('CPUBLIC', ?, 'repo', ?, ?, ?)`,
			thread, thread, string(data), updated.Format(timestampFormat)); err != nil {
			t.Fatal(err)
		}
	}
	sources, err := st.ListConversationMemoryCandidates(ctx, now.Add(-24*time.Hour), 10)
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
	if err := st.CompactConversationMemories(ctx, rollup, memories); err != nil {
		t.Fatal(err)
	}
	if count, err := st.CountConversationMemories(ctx); err != nil || count != 0 {
		t.Fatalf("conversation count = %d, %v", count, err)
	}
	rollups, err := st.ListMemoryRollupsForContext(ctx, "COTHER", "repo", 4)
	if err != nil || len(rollups) != 1 || rollups[0].SourceCount != 2 {
		t.Fatalf("rollups = %+v, %v", rollups, err)
	}
	if err := st.MarkMemoryRollupsRecalled(ctx, []string{rollups[0].ID}); err != nil {
		t.Fatal(err)
	}
	health, err := st.MemoryHealth(ctx)
	if err != nil || health.Rollups != 1 {
		t.Fatalf("health = %+v, %v", health, err)
	}
}

func TestMemoryReviewQueueNeverMutatesUntilResolved(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	add := func(subject string) core.MemoryEntry {
		entry, _, err := st.UpsertMemoryEntry(ctx, core.MemoryEntry{
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
	old := now.Add(-45 * 24 * time.Hour).Format(timestampFormat)
	if _, err := st.db.ExecContext(ctx, `
		UPDATE memory_entries SET updated_at = ?, last_reviewed_at = NULL WHERE id IN (?, ?)`,
		old, first.ID, second.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.RefreshMemoryReviewQueue(ctx, now.Add(-30*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	reviews, err := st.ListPendingMemoryReviews(ctx, 10)
	if err != nil || len(reviews) != 3 {
		t.Fatalf("reviews = %+v, %v", reviews, err)
	}
	if active, _ := st.CountMemoryForHome(ctx, "TWORKSPACE", "UOPERATOR"); active != 2 {
		t.Fatalf("review queue mutated entries: %d", active)
	}
	var duplicate core.MemoryReviewItem
	for _, review := range reviews {
		if review.Kind == "duplicate" {
			duplicate = review
		}
	}
	if _, err := st.ResolveMemoryReview(ctx, duplicate.ID, "merge", "UOPERATOR"); err != nil {
		t.Fatal(err)
	}
	if active, _ := st.CountMemoryForHome(ctx, "TWORKSPACE", "UOPERATOR"); active != 1 {
		t.Fatalf("duplicate merge retained %d entries", active)
	}
}

func TestMemoryReplacementRecordsHashOnlySupersession(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	entry := core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: "COPS", SubjectKey: "portal",
		Predicate: "alias_of", Value: "service:portal", SourceRef: "slack:1",
		ActorID: "UOPERATOR", VisibilityKind: "channel", VisibilityID: "COPS",
		ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
	}
	if _, _, err := st.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	entry.Value = "service:portal-v2"
	if _, _, err := st.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	var count int
	var previous, replacement string
	if err := st.db.QueryRowContext(ctx, `
		SELECT count(*), previous_value_hash, replacement_value_hash FROM memory_supersessions`,
	).Scan(&count, &previous, &replacement); err != nil {
		t.Fatal(err)
	}
	if count != 1 || len(previous) != 64 || len(replacement) != 64 || previous == replacement {
		t.Fatalf("supersession = count=%d previous=%q replacement=%q", count, previous, replacement)
	}
}

func TestMemoryLifecyclePrunesMetadataAndDeletedChannelRollups(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Truncate(time.Second)
	entry := core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE", SubjectKey: "style",
		Predicate: "guidance", Value: "Use plain language.", SourceRef: "slack:1",
		ActorID: "UOPERATOR", VisibilityKind: "workspace", VisibilityID: "TWORKSPACE",
		ExpiresAt: now.Add(30 * 24 * time.Hour),
	}
	if _, _, err := st.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	entry.Value = "Start with plain language."
	if _, _, err := st.UpsertMemoryEntry(ctx, entry, 10, 10); err != nil {
		t.Fatal(err)
	}
	old := now.Add(-60 * 24 * time.Hour).Format(timestampFormat)
	if _, err := st.db.ExecContext(ctx, `UPDATE memory_supersessions SET created_at = ?`, old); err != nil {
		t.Fatal(err)
	}
	state, _ := json.Marshal(core.AgentMemory{SituationSummary: "Private history."})
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO memory_rollups (
		  id, scope_kind, scope_key, repository, period_start, period_end,
		  state_json, source_refs_json, source_count, expires_at, created_at, updated_at
		) VALUES ('dream_private', 'channel', 'GPRIVATE', 'repo', ?, ?, ?, '[]', 1, ?, ?, ?)`,
		old, old, string(state), now.Add(time.Hour).Format(timestampFormat), old, old); err != nil {
		t.Fatal(err)
	}
	deleted, err := st.DeleteConversationMemories(ctx, "GPRIVATE")
	if err != nil || deleted != 1 {
		t.Fatalf("channel memory deletion = %d, %v", deleted, err)
	}
	if _, err := st.GetMemoryRollupByID(ctx, "dream_private"); !errors.Is(err, ErrNotFound) {
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
