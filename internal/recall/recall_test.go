package recall

import (
	"fmt"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

func TestSanitizeKnowledgeKeepsNewestValidItemPerSubject(t *testing.T) {
	items := SanitizeKnowledge([]core.KnowledgeItem{
		{
			Subject: "symbol storage", Kind: "decision",
			Statement: "Use MinIO.", Status: "tentative", Confidence: 2,
			SourceRef: "https://app.slack.com/client/T123/C123/thread/C123-90", SourceMessageTS: "90.001",
		},
		{
			Subject: "symbol storage", Kind: "decision",
			Statement: "Use GCS with GitHub Actions WIF.", Status: "accepted", Confidence: 3,
			SourceRef: "https://app.slack.com/client/T123/C123/thread/C123-100", SourceMessageTS: "100.001",
		},
		{
			Subject: "secret", Kind: "guess", Statement: "invalid kind",
			Status: "accepted", Confidence: 3, SourceRef: "https://example.com", SourceMessageTS: "101.001",
		},
	})
	if len(items) != 1 || items[0].Statement != "Use GCS with GitHub Actions WIF." {
		t.Fatalf("knowledge = %#v", items)
	}
}

func TestRelatedConversationMemoryIsSelectedOnlyWhenRelevant(t *testing.T) {
	now := time.Now().UTC()
	items := []core.ConversationMemory{
		{
			ChannelID: "CDESIGN", ThreadTS: "100", Repository: "blitz-infra", UpdatedAt: now,
			State: core.AgentMemory{Knowledge: []core.KnowledgeItem{{
				Subject: "Sentry symbol storage", Kind: "decision",
				Statement: "Store PDB files in GCS and upload from GitHub Actions through WIF.",
				Status:    "accepted", Confidence: 3, SourceRef: "https://app.slack.com/client/T/C/thread/C-100", SourceMessageTS: "100.001",
			}}},
		},
		{
			ChannelID: "CDB", ThreadTS: "200", Repository: "blitz-infra", UpdatedAt: now.Add(time.Minute),
			State: core.AgentMemory{Knowledge: []core.KnowledgeItem{{
				Subject: "Cassandra repairs", Kind: "fact", Statement: "Repairs run every five days.",
				Status: "accepted", Confidence: 3, SourceRef: "https://app.slack.com/client/T/C/thread/C-200", SourceMessageTS: "200.001",
			}}},
		},
	}
	selected := SelectConversationMemories(
		items,
		"Review the Symbolicator PR and check its GCS upload through WIF",
		6,
	)
	if len(selected) != 1 || selected[0].ThreadTS != "100" {
		t.Fatalf("selected = %#v", selected)
	}
	if got := SelectConversationMemories(items, "Why is Redis memory high?", 6); len(got) != 0 {
		t.Fatalf("unrelated memory leaked into context: %#v", got)
	}
}

// Recall must not degrade as the agent is taught more. A mapping taught months
// ago has to win its slot back when the request names it, or every lesson makes
// the next one less likely to surface.
func TestConfirmedMemoryRecallRanksByRelevance(t *testing.T) {
	base := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	candidates := make([]core.MemoryEntry, 0, 15)
	// Fourteen newer, unrelated entries the store returns first by recency.
	for index := range 14 {
		candidates = append(candidates, core.MemoryEntry{
			ID:         fmt.Sprintf("recent-%02d", index),
			Predicate:  "evidence_route",
			SubjectKey: fmt.Sprintf("service:unrelated-%02d", index),
			Value:      "emisar:unrelated",
			UpdatedAt:  base.Add(-time.Duration(index) * time.Hour),
		})
	}
	// The entry we want back is the oldest, so recency alone drops it off the
	// end of the window entirely.
	candidates = append(candidates, core.MemoryEntry{
		ID: "old-alias", Predicate: "alias_of",
		SubjectKey: "payments-api", Value: "repo:payments",
		UpdatedAt: base.Add(-90 * 24 * time.Hour),
	})

	selected := SelectMemoryEntries(candidates, "why is payments-api returning 500s", 10)
	if len(selected) != 10 {
		t.Fatalf("selected %d entries, want 10", len(selected))
	}
	if selected[0].ID != "old-alias" {
		t.Fatalf("the named mapping did not rank first: %+v", ids(selected))
	}

	// With no operator wording there is nothing to rank against, so recency
	// stands and the behaviour matches what the store already ordered.
	unranked := SelectMemoryEntries(candidates, "", 10)
	if len(unranked) != 10 {
		t.Fatalf("empty query returned %d entries", len(unranked))
	}
	for index := range unranked {
		if unranked[index].ID != candidates[index].ID {
			t.Fatalf("empty query reordered candidates at %d: %+v", index, ids(unranked))
		}
	}
}

// Guidance answers no question, so it never matches the wording of one — but it
// is how the operator asked to be worked with, so it has to travel anyway.
func TestConfirmedMemoryRecallAlwaysCarriesGuidance(t *testing.T) {
	candidates := []core.MemoryEntry{
		{ID: "guide-1", Predicate: "guidance", SubjectKey: "communication_style",
			Value: "prefer short answers with the decision first"},
		{ID: "guide-2", Predicate: "guidance", SubjectKey: "escalation",
			Value: "page the on-call before opening an incident room"},
	}
	for index := range 12 {
		candidates = append(candidates, core.MemoryEntry{
			ID:         fmt.Sprintf("route-%02d", index),
			Predicate:  "evidence_route",
			SubjectKey: "service:checkout",
			Value:      "emisar:checkout",
		})
	}
	selected := SelectMemoryEntries(candidates, "checkout latency", 10)
	found := map[string]bool{}
	for _, entry := range selected {
		found[entry.ID] = true
	}
	if !found["guide-1"] || !found["guide-2"] {
		t.Fatalf("guidance was crowded out by matching entries: %+v", ids(selected))
	}
}

func ids(entries []core.MemoryEntry) []string {
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		result = append(result, entry.ID)
	}
	return result
}
