package service

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/memorystore"
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
	if count, err := st.Memory.CountConversationMemories(ctx); err != nil || count != 0 {
		t.Fatalf("conversation summaries = %d, %v", count, err)
	}
	rollups, err := st.Memory.ListMemoryRollupsForContext(ctx, "COTHER", "repo", 4)
	if err != nil || len(rollups) != 1 || rollups[0].SourceCount != 2 {
		t.Fatalf("rollups = %+v, %v", rollups, err)
	}
	health, err := st.Memory.MemoryHealth(ctx)
	if err != nil || health.LastDreamedAt.IsZero() || !health.LastDreamedAt.Equal(future) {
		t.Fatalf("health = %+v, %v", health, err)
	}
}

func TestGroupMemoryRollupsKeepsPrivateChannelsIsolated(t *testing.T) {
	now := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	candidates := []memorystore.ConversationMemoryCandidate{
		{Memory: core.ConversationMemory{ChannelID: "CPUBLIC1", Repository: "repo", UpdatedAt: now}},
		{Memory: core.ConversationMemory{ChannelID: "CPUBLIC2", Repository: "repo", UpdatedAt: now.Add(time.Hour)}},
		{Memory: core.ConversationMemory{ChannelID: "CPRIVATE", Repository: "repo", UpdatedAt: now}, Private: true},
	}
	groups := memorypkg.GroupMemoryRollups(candidates)
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
	merged := memorypkg.MergeAgentMemories(states)
	if merged.Goal != "new goal" || len(merged.Decisions) != 2 ||
		merged.Decisions[0] != "keep canary" {
		t.Fatalf("merged = %+v", merged)
	}
}

// Rollup source refs and merged memory fields carry model-produced text, so a
// bound that lands mid-rune corrupts what is stored and later re-encoded.
func TestBoundedUniqueKeepsRunesIntact(t *testing.T) {
	// 199 ASCII bytes then a 3-byte rune, so a 200-byte bound lands inside it.
	value := strings.Repeat("a", 199) + "→ tail"
	result := memorypkg.BoundedUnique([]string{value}, 10, 200)
	if len(result) != 1 {
		t.Fatalf("result = %+v", result)
	}
	if !utf8.ValidString(result[0]) {
		t.Fatalf("bounded value is not valid UTF-8: %q", result[0])
	}
	if len(result[0]) > 200 {
		t.Fatalf("bounded value is %d bytes, over the 200 bound", len(result[0]))
	}
}

func TestMergeAgentMemoriesSupersedesOlderKnowledge(t *testing.T) {
	merged := memorypkg.MergeAgentMemories([]core.AgentMemory{
		{Knowledge: []core.KnowledgeItem{{
			Subject: "Symbol storage", Kind: "decision", Statement: "Use GCS.",
			Status: "accepted", Confidence: 3, SourceRef: "https://app.slack.com/client/T/C/thread/C-200", SourceMessageTS: "200.001",
		}}},
		{Knowledge: []core.KnowledgeItem{{
			Subject: "Symbol storage", Kind: "decision", Statement: "Use MinIO.",
			Status: "tentative", Confidence: 2, SourceRef: "https://app.slack.com/client/T/C/thread/C-100", SourceMessageTS: "100.001",
		}}},
	})
	if len(merged.Knowledge) != 1 || merged.Knowledge[0].Statement != "Use GCS." {
		t.Fatalf("merged knowledge = %#v", merged.Knowledge)
	}
}

// A rollup has a bounded number of slots. Spending several of them on the same
// fact said different ways is how consolidated memory gets noisier the longer a
// channel runs.
func TestBoundedUniqueCollapsesNearDuplicates(t *testing.T) {
	result := memorypkg.BoundedUnique([]string{
		"payments-api is degraded",
		"payments-api degraded",
		"The payments-api is degraded.",
		"checkout latency is elevated",
	}, 12, 400)

	if len(result) != 2 {
		t.Fatalf("near-duplicates were not collapsed: %+v", result)
	}
	// The longest phrasing survives: it is the most specific statement.
	if result[0] != "The payments-api is degraded." {
		t.Fatalf("collapsed to the less specific phrasing: %q", result[0])
	}
	if result[1] != "checkout latency is elevated" {
		t.Fatalf("a distinct fact was collapsed away: %+v", result)
	}
}

// Collapsing must not merge facts that merely share vocabulary.
func TestBoundedUniqueKeepsDistinctFacts(t *testing.T) {
	result := memorypkg.BoundedUnique([]string{
		"payments-api is degraded",
		"payments-api is healthy",
		"payments-db is degraded",
	}, 12, 400)
	if len(result) != 3 {
		t.Fatalf("distinct facts were collapsed: %+v", result)
	}
}

// Consolidation is lossy by design, so what it keeps has to be predictable. A
// golden here is the difference between "the summary changed because the
// conversation changed" and "the summary changed because we edited the merge".
func TestMergeAgentMemoriesIsDeterministic(t *testing.T) {
	older := core.AgentMemory{
		Goal:                "keep checkout healthy",
		ChannelPurpose:      "payments operations",
		SituationSummary:    "investigating elevated latency",
		ActiveTopics:        []string{"checkout latency", "db connections"},
		OpenLoops:           []string{"confirm the connection pool size"},
		Decisions:           []string{"roll back the pool change"},
		UnresolvedQuestions: []string{"why did the pool shrink?"},
		Topology:            []string{"checkout -> payments-db"},
	}
	newer := core.AgentMemory{
		// A later summary must not overwrite the established goal or purpose.
		Goal:             "keep checkout healthy after the rollback",
		SituationSummary: "rollback complete, latency normal",
		ActiveTopics:     []string{"checkout latency", "rollback"},
		OpenLoops:        []string{"confirm the connection pool size"},
		Decisions:        []string{"roll back the pool change", "add a pool alarm"},
	}

	// Newest first, matching how buildMemoryRollup orders its sources.
	merged := memorypkg.MergeAgentMemories([]core.AgentMemory{newer, older})

	if merged.Goal != "keep checkout healthy after the rollback" {
		t.Fatalf("goal = %q; the newest non-empty value should win", merged.Goal)
	}
	if merged.ChannelPurpose != "payments operations" {
		t.Fatalf("purpose = %q; an older value should fill a gap the newer one left",
			merged.ChannelPurpose)
	}
	if got := len(merged.ActiveTopics); got != 3 {
		t.Fatalf("active topics = %v; the shared topic should appear once", merged.ActiveTopics)
	}
	if got := len(merged.OpenLoops); got != 1 {
		t.Fatalf("open loops = %v; the identical loop should not be duplicated", merged.OpenLoops)
	}
	if got := len(merged.Decisions); got != 2 {
		t.Fatalf("decisions = %v; both distinct decisions should survive", merged.Decisions)
	}
	if got := len(merged.UnresolvedQuestions); got != 1 {
		t.Fatalf("questions = %v", merged.UnresolvedQuestions)
	}

	// Merging is stable: the same inputs give the same result.
	again := memorypkg.MergeAgentMemories([]core.AgentMemory{newer, older})
	if !reflect.DeepEqual(merged, again) {
		t.Fatal("merging the same sources twice produced different summaries")
	}
}

// Under storage pressure dreaming widens its net, but it must never sweep up
// conversations that are still active.
func TestDreamingPressureKeepsVeryRecentSummaries(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Memory.DreamingEnabled = true
	cfg.Memory.MaxConversationSummaries = 4
	cfg.Memory.PressurePercent = 50
	cfg.Memory.TargetPercent = 25
	cfg.Memory.MinRollupSources = 2
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, nil, nil)
	clock := useTestClock(svc, st)
	now := clock.Now()

	// Three old summaries plus one from a minute ago.
	for index := range 3 {
		if err := st.UpsertConversationMemoryState(ctx, core.ConversationMemory{
			ChannelID: "COLD", ThreadTS: fmt.Sprintf("16%02d.001", index),
			Repository: cfg.Slack.DefaultRepository, LastMessage: "1600.001",
			State: core.AgentMemory{SituationSummary: fmt.Sprintf("old %d", index)},
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.UpsertConversationMemoryState(ctx, core.ConversationMemory{
		ChannelID: "CLIVE", ThreadTS: "1799.001",
		Repository: cfg.Slack.DefaultRepository, LastMessage: "1799.001",
		State: core.AgentMemory{SituationSummary: "still talking"},
	}); err != nil {
		t.Fatal(err)
	}

	if err := svc.maintainMemory(ctx, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}

	live, err := st.GetConversationMemory(ctx, "CLIVE", "1799.001")
	if err != nil {
		t.Fatalf("the live conversation's summary was consolidated away: %v", err)
	}
	if live.State.SituationSummary != "still talking" {
		t.Fatalf("live summary = %+v", live.State)
	}
}
