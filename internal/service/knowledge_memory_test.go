package service

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func TestSanitizeKnowledgeKeepsNewestValidItemPerSubject(t *testing.T) {
	items := sanitizeKnowledge([]core.KnowledgeItem{
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
			ChannelID: "CDESIGN", ThreadTS: "100", Repository: "tenant-infra", UpdatedAt: now,
			State: core.AgentMemory{Knowledge: []core.KnowledgeItem{{
				Subject: "Sentry symbol storage", Kind: "decision",
				Statement: "Store PDB files in GCS and upload from GitHub Actions through WIF.",
				Status:    "accepted", Confidence: 3, SourceRef: "https://app.slack.com/client/T/C/thread/C-100", SourceMessageTS: "100.001",
			}}},
		},
		{
			ChannelID: "CDB", ThreadTS: "200", Repository: "tenant-infra", UpdatedAt: now.Add(time.Minute),
			State: core.AgentMemory{Knowledge: []core.KnowledgeItem{{
				Subject: "Cassandra repairs", Kind: "fact", Statement: "Repairs run every five days.",
				Status: "accepted", Confidence: 3, SourceRef: "https://app.slack.com/client/T/C/thread/C-200", SourceMessageTS: "200.001",
			}}},
		},
	}
	selected := selectRelevantConversationMemories(
		items,
		"Review the Symbolicator PR and check its GCS upload through WIF",
		6,
	)
	if len(selected) != 1 || selected[0].ThreadTS != "100" {
		t.Fatalf("selected = %#v", selected)
	}
	if got := selectRelevantConversationMemories(items, "Why is Redis memory high?", 6); len(got) != 0 {
		t.Fatalf("unrelated memory leaked into context: %#v", got)
	}
}

func TestMergeAgentMemoriesSupersedesOlderKnowledge(t *testing.T) {
	merged := mergeAgentMemories([]core.AgentMemory{
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

func TestIgnoreDecisionMayUpdateOnlyConversationMemory(t *testing.T) {
	memory := core.AgentMemory{Knowledge: []core.KnowledgeItem{{
		Subject: "Sentry placement", Kind: "decision", Statement: "Keep Sentry in GCP.",
		Status: "accepted", Confidence: 3, SourceRef: "https://app.slack.com/client/T/C/thread/C-100", SourceMessageTS: "100.001",
	}}}
	decision := watchDecision{
		Action: "ignore",
		Operations: []investigation.ResultOperation{{
			ID: "memory-1", Type: "update_memory", Memory: &memory,
		}},
	}
	if err := applyWatchResultOperations(&decision); err != nil {
		t.Fatal(err)
	}
	if decision.Message != "" || len(decision.Memory.Knowledge) != 1 ||
		len(decision.AppliedOperations) != 1 {
		t.Fatalf("decision = %#v", decision)
	}

	decision.Operations = append(decision.Operations, investigation.ResultOperation{
		ID: "complete-1", Type: "complete_episode",
		Completion: &investigation.CompleteEpisode{Message: "This must not be hidden."},
	})
	if err := applyWatchResultOperations(&decision); err == nil ||
		!strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("silent mixed operations error = %v", err)
	}

	decision = watchDecision{
		Action:   "ignore",
		Evidence: []core.Evidence{{Claim: "hidden work"}},
		Operations: []investigation.ResultOperation{{
			ID: "memory-1", Type: "update_memory", Memory: &memory,
		}},
	}
	if err := applyWatchResultOperations(&decision); err == nil ||
		!strings.Contains(err.Error(), "other result fields") {
		t.Fatalf("silent legacy side effect error = %v", err)
	}
}

func TestWatchPromptsDefineAmbientKnowledgeAndConfidenceGate(t *testing.T) {
	input := core.SlackInput{
		TeamID: "T123ABC", ChannelID: "C123ABC", MessageTS: "100.001",
		UserID: "U123ABC", Text: "Use GCS for debug symbols.",
	}
	svc := &Service{}
	for name, prompt := range map[string]string{
		"bounded": svc.conversationPrompt(
			input, "U999BOT", false, nil, core.AgentMemory{}, nil, "repo",
		),
		"full": svc.unboundedWatchPrompt(
			input, "U999BOT", false, nil, core.AgentMemory{}, nil, nil,
			operationalMemoryContext{}, "repo", nil,
		),
	} {
		for _, required := range []string{
			"durable organizational knowledge",
			"status=tentative|accepted|superseded",
			"confidence=3",
			"source_ref",
			"action=ignore",
			"materially contradicts",
		} {
			if !strings.Contains(prompt, required) {
				t.Fatalf("%s prompt missing %q", name, required)
			}
		}
	}
}
