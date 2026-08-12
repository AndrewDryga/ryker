package agentcontext

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestNeedsCaptureRejectsLegacyRepositoryMismatch(t *testing.T) {
	if !NeedsCapture(true, "channel-default", "task-repository") {
		t.Fatal("legacy channel repository was accepted for pinned task work")
	}
	if NeedsCapture(true, "task-repository", "task-repository") {
		t.Fatal("matching pinned task context was unnecessarily recaptured")
	}
	if !NeedsCapture(false, "task-repository", "task-repository") {
		t.Fatal("missing durable context was accepted")
	}
}

func TestSituationPromptAndPresenceShareTheSanitizedMemoryContract(t *testing.T) {
	memory := core.AgentMemory{Goal: "restore service"}
	if !MemoryPresent(memory) {
		t.Fatal("nonempty memory was not recognized")
	}
	prompt := SituationPrompt(memory)
	if !strings.Contains(prompt, "restore service") ||
		!strings.Contains(prompt, "<prior-channel-situation>") {
		t.Fatalf("situation prompt = %q", prompt)
	}
	if MemoryPresent(core.AgentMemory{}) || SituationPrompt(core.AgentMemory{}) != "" {
		t.Fatal("empty memory produced context")
	}
}
