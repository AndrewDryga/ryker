package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func maintenanceStore(t *testing.T) *Store {
	t.Helper()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

// Behaviour is scoped to a repository, so removing one from the configuration
// must remove what it authorised. Leaving orphaned rules behind means the agent
// keeps acting on a repository nobody has configured any more.
func TestPruneOrphanBehaviorFollowsTheConfiguration(t *testing.T) {
	ctx := context.Background()
	st := maintenanceStore(t)
	expires := time.Now().UTC().Add(24 * time.Hour)

	for _, repository := range []string{"kept", "removed"} {
		if _, _, err := st.UpsertPreference(ctx, core.ResponderPreference{
			ScopeKind: "repository", ScopeKey: repository,
			Name: "health_check_depth", Value: "deep",
			SourceRef: "slack_1", ActorID: "U1", ExpiresAt: expires,
		}, 100, 50); err != nil {
			t.Fatal(err)
		}
		if _, _, err := st.UpsertStandingRule(ctx, core.StandingRule{
			ChannelID: "C1", Repository: repository,
			Trigger: "operational_alert", Action: "triage_alert", SourceKind: "app",
			SourceRef: "slack_2", ActorID: "U1", ExpiresAt: expires,
		}, 100, 50); err != nil {
			t.Fatal(err)
		}
	}

	// An empty configuration is refused rather than treated as "remove
	// everything" — a misread config must not delete an operator's work.
	if _, _, err := st.PruneOrphanBehavior(ctx, nil); err == nil {
		t.Fatal("an empty repository list was treated as a valid configuration")
	}

	preferences, rules, err := st.PruneOrphanBehavior(ctx, []string{"kept"})
	if err != nil {
		t.Fatal(err)
	}
	if preferences != 1 || rules != 1 {
		t.Fatalf("pruned %d preferences and %d rules, want 1 and 1", preferences, rules)
	}
	remaining, err := st.ListPreferencesForHome(ctx, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range remaining {
		if item.ScopeKey == "removed" {
			t.Fatalf("behaviour for an unconfigured repository survived: %+v", item)
		}
	}
}

// Cleanup is ownership-based: Responder records the exact session it owns
// before asking Coop to discard anything, so an unrelated fork is never in its
// cleanup set.
func TestScheduleCleanupRecordsOwnershipAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	st := maintenanceStore(t)
	now := time.Now().UTC()

	if err := st.ScheduleCleanup(ctx, "", "inc_1", "reason", false, now); err == nil {
		t.Fatal("cleanup was scheduled without a session to clean up")
	}
	if err := st.ScheduleCleanup(ctx, "sess_1", "inc_1", "", false, now); err == nil {
		t.Fatal("cleanup was scheduled with no recorded reason")
	}

	if err := st.ScheduleCleanup(
		ctx, "sess_1", "inc_1", "conversation policy changed", false, now,
	); err != nil {
		t.Fatal(err)
	}
	// Scheduling the same session twice is ordinary — a retry, or two paths
	// noticing the same closed session — and must not error or duplicate.
	if err := st.ScheduleCleanup(
		ctx, "sess_1", "inc_1", "conversation policy changed", false, now,
	); err != nil {
		t.Fatalf("re-scheduling the same session errored: %v", err)
	}

	item, err := st.NextCleanup(ctx, now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if item.SessionID != "sess_1" || item.IncidentID != "inc_1" {
		t.Fatalf("cleanup record = %+v", item)
	}
}

// Rollups are bounded so consolidated memory cannot grow without limit, and an
// expired one must go regardless of the cap.
func TestPruneMemoryRollupsHonoursExpiry(t *testing.T) {
	ctx := context.Background()
	st := maintenanceStore(t)
	now := time.Now().UTC()

	source := core.ConversationMemory{
		ChannelID: "C1", ThreadTS: "1700.001", Repository: "emisar",
		LastMessage: "1700.001",
		State:       core.AgentMemory{SituationSummary: "an older conversation"},
	}
	if err := st.UpsertConversationMemoryState(ctx, source); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetConversationMemory(ctx, "C1", "1700.001")
	if err != nil {
		t.Fatal(err)
	}
	period := now.AddDate(0, 0, -14)
	if err := st.Memory.CompactConversationMemories(ctx, core.MemoryRollup{
		ScopeKind: "channel", ScopeKey: "C1", Repository: "emisar",
		PeriodStart: period, PeriodEnd: period.Add(time.Hour),
		State:       core.AgentMemory{SituationSummary: "consolidated"},
		SourceCount: 1,
		// Already expired, so maintenance must remove it.
		ExpiresAt: now.Add(-time.Hour),
		CreatedAt: now, UpdatedAt: now,
	}, []core.ConversationMemory{stored}); err != nil {
		t.Fatal(err)
	}

	deleted, err := st.Memory.PruneMemoryRollups(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 1 {
		t.Fatalf("pruning removed %d rollups, want the one that had expired", deleted)
	}
	remaining, err := st.Memory.ListMemoryRollupsForContext(ctx, "C1", "emisar", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(remaining) != 0 {
		t.Fatalf("an expired rollup survived maintenance: %+v", remaining)
	}
}
