package service

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestMaintainMemoryRunsDueConsolidationEndToEnd(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.ReconcileSlackChannelMemberships(ctx, []store.SlackChannelMembershipObservation{
		{ChannelID: "CPUBLIC1", ChannelName: "deployments", Present: true},
		{ChannelID: "CPUBLIC2", ChannelName: "operations", Present: true},
	}, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	for index, channel := range []string{"CPUBLIC1", "CPUBLIC2"} {
		if err := st.EnsureChannelMemory(ctx, channel, "repo"); err != nil {
			t.Fatal(err)
		}
		applied, err := st.ApplyWatchDecision(ctx, core.EvaluationDecision{
			ChannelID: channel, ThreadTS: fmt.Sprintf("1700.%d", index+1),
			MessageTS: "1701.1", Repository: "repo",
			SourceInput: "source_" + channel, Mode: "watch", Action: "reply",
		}, "investigation", 1, core.AgentMemory{
			SituationSummary: "A deployment was reviewed in " + channel,
			OpenLoops:        []string{"Verify rollout health."},
		})
		if err != nil || !applied {
			t.Fatalf("apply %s = %t, %v", channel, applied, err)
		}
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, nil, nil)
	future := time.Now().UTC().Add(8 * 24 * time.Hour)
	if err := svc.maintainMemory(ctx, future); err != nil {
		t.Fatal(err)
	}
	if count, err := st.CountConversationMemories(ctx); err != nil || count != 0 {
		t.Fatalf("conversation summaries = %d, %v", count, err)
	}
	rollups, err := st.ListMemoryRollupsForContext(ctx, "COTHER", "repo", 4)
	if err != nil || len(rollups) != 1 || rollups[0].SourceCount != 2 {
		t.Fatalf("rollups = %+v, %v", rollups, err)
	}
	health, err := st.MemoryHealth(ctx)
	if err != nil || health.LastDreamedAt.IsZero() || !health.LastDreamedAt.Equal(future) {
		t.Fatalf("health = %+v, %v", health, err)
	}
}

func TestGroupMemoryRollupsKeepsPrivateChannelsIsolated(t *testing.T) {
	now := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	candidates := []store.ConversationMemoryCandidate{
		{Memory: core.ConversationMemory{ChannelID: "CPUBLIC1", Repository: "repo", UpdatedAt: now}},
		{Memory: core.ConversationMemory{ChannelID: "CPUBLIC2", Repository: "repo", UpdatedAt: now.Add(time.Hour)}},
		{Memory: core.ConversationMemory{ChannelID: "CPRIVATE", Repository: "repo", UpdatedAt: now}, Private: true},
	}
	groups := groupMemoryRollups(candidates)
	if len(groups) != 2 {
		t.Fatalf("groups = %+v", groups)
	}
	for _, group := range groups {
		switch group.ScopeKind {
		case "repository":
			if group.ScopeKey != "repo" || len(group.Sources) != 2 {
				t.Fatalf("public group = %+v", group)
			}
		case "channel":
			if group.ScopeKey != "CPRIVATE" || len(group.Sources) != 1 {
				t.Fatalf("private group = %+v", group)
			}
		default:
			t.Fatalf("unexpected group = %+v", group)
		}
	}
}

func TestMergeAgentMemoriesIsBoundedAndNewestWins(t *testing.T) {
	states := []core.AgentMemory{
		{Goal: "new goal", Decisions: []string{"keep canary", "keep canary"}},
		{Goal: "old goal", Decisions: []string{"old decision"}},
	}
	merged := mergeAgentMemories(states)
	if merged.Goal != "new goal" || len(merged.Decisions) != 2 ||
		merged.Decisions[0] != "keep canary" {
		t.Fatalf("merged = %+v", merged)
	}
}
