package memory

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Every way a memory can be scoped, and who may see it.
//
// This had no test. Making the function return true unconditionally — every
// private memory visible to everyone — broke nothing in the suite. That is the
// worst shape a gap can take: the check fails open, so the bug is silence
// rather than an error, and the symptom is Responder telling a channel
// something it was never meant to hear.
func TestMemoryIsOnlyVisibleInsideItsScope(t *testing.T) {
	const workspace = "T_WORKSPACE"
	viewer := core.SlackInput{TeamID: workspace, ChannelID: "C_OPEN", UserID: "U_VIEWER"}

	for _, testCase := range []struct {
		name  string
		entry core.MemoryEntry
		input core.SlackInput
		want  bool
	}{
		{
			name:  "workspace memory is visible to a member of that workspace",
			entry: core.MemoryEntry{VisibilityKind: "workspace", VisibilityID: workspace},
			input: viewer,
			want:  true,
		},
		{
			name:  "workspace memory is not visible from another workspace",
			entry: core.MemoryEntry{VisibilityKind: "workspace", VisibilityID: workspace},
			input: core.SlackInput{TeamID: "T_OTHER", ChannelID: "C_OPEN", UserID: "U_VIEWER"},
			want:  false,
		},
		{
			name:  "channel memory is visible in its own channel",
			entry: core.MemoryEntry{VisibilityKind: "channel", VisibilityID: "C_OPEN"},
			input: viewer,
			want:  true,
		},
		{
			name:  "channel memory does not leak into another channel",
			entry: core.MemoryEntry{VisibilityKind: "channel", VisibilityID: "C_PRIVATE"},
			input: viewer,
			want:  false,
		},
		{
			name:  "operator memory is visible only to that operator",
			entry: core.MemoryEntry{VisibilityKind: "operator", VisibilityID: "U_VIEWER"},
			input: viewer,
			want:  true,
		},
		{
			name:  "operator memory does not leak to another person",
			entry: core.MemoryEntry{VisibilityKind: "operator", VisibilityID: "U_SOMEONE_ELSE"},
			input: viewer,
			want:  false,
		},
		{
			// The default must deny. A scope this code does not recognize is
			// one whose rules it cannot enforce, and guessing means guessing
			// about who is allowed to read something.
			name:  "an unrecognized scope is denied rather than guessed at",
			entry: core.MemoryEntry{VisibilityKind: "something_new", VisibilityID: "C_OPEN"},
			input: viewer,
			want:  false,
		},
		{
			name:  "an empty scope is denied",
			entry: core.MemoryEntry{},
			input: viewer,
			want:  false,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if got := MemoryEntryVisibleForAction(testCase.entry, testCase.input, workspace); got != testCase.want {
				t.Fatalf("visible = %t, want %t", got, testCase.want)
			}
		})
	}
}

// A memory that never expires eventually describes a system that no longer
// exists, so an unbounded or absurd TTL is refused rather than clamped.
func TestMemoryTTLIsBounded(t *testing.T) {
	if ttl, err := ParseMemoryTTL(""); err != nil || ttl != DefaultTTL {
		t.Fatalf("empty TTL = %v, %v; want the default", ttl, err)
	}
	if _, err := ParseMemoryTTL("400d"); err == nil {
		t.Fatal("a TTL beyond the maximum was accepted")
	}
	if _, err := ParseMemoryTTL("-1h"); err == nil {
		t.Fatal("a negative TTL was accepted")
	}
	if ttl, err := ParseMemoryTTL("7d"); err != nil || ttl != 7*24*time.Hour {
		t.Fatalf("7d = %v, %v", ttl, err)
	}
}
