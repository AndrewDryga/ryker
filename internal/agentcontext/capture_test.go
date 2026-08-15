package agentcontext

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
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

// The channel around a thread is what the thread does not already say.
//
// A thread turn gets two Slack reads, and Slack answers the channel one with
// the thread's root included. Sending the root and any reply back as "the
// channel around it" would have the model reading one message as two nearby
// events — the failure the surround exists to prevent, reproduced by the fix.
func TestTheSurroundExcludesEveryMessageTheThreadAlreadyCarries(t *testing.T) {
	history := []slackui.HistoryMessage{
		{Timestamp: "1702.050", BotID: "BALERT", Text: "5xx ratio is above threshold"},
		{Timestamp: "1702.080", UserID: "U2", Text: "already pasted in the thread"},
		{Timestamp: "1702.100", ThreadTS: "1702.100", UserID: "U1", Text: "root"},
		{Timestamp: "1702.110", ThreadTS: "1702.100", UserID: "U1", Text: "a reply"},
	}
	around := AroundThreadRoot(history, "1702.100", []core.SlackInput{
		{MessageTS: "1702.080"}, {MessageTS: "1702.100"}, {MessageTS: "1702.300"},
	})
	if len(around) != 1 || around[0].Timestamp != "1702.050" {
		t.Fatalf("channel around the root = %+v", around)
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
