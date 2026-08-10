package core

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// The exact shape that broke a real assessment: a 2,559-byte operator
// instruction against a 2,000-byte channel-message bound, cut mid-enumeration
// at "Decide healthy, degraded, or". Unmarked, the model asked the operator to
// resend the ending, which is the right answer to the wrong question.
func TestTruncateForPromptSaysTheHostCutIt(t *testing.T) {
	const limit = 2000
	head := strings.Repeat("method. ", 230) // 1840 bytes
	value := head + "Decide healthy, degraded, or unhealthy. " + strings.Repeat("more. ", 100)
	if len(value) <= limit {
		t.Fatalf("the fixture is %d bytes, which does not exercise the bound", len(value))
	}

	got := TruncateForPrompt(value, limit)
	if len(got) > limit {
		t.Fatalf("bounded text is %d bytes, over the %d limit", len(got), limit)
	}
	if !strings.HasSuffix(got, PromptTruncationMarker) {
		t.Fatalf("a cut message did not say it was cut: %q", got[max(0, len(got)-80):])
	}
	if !strings.Contains(got, "Decide healthy, degraded, or") {
		t.Fatal("the bound dropped text it had room for")
	}
	if !utf8.ValidString(got) {
		t.Fatal("the bound split a rune")
	}
}

// A message that fits is passed through untouched. Marking one the host never
// cut would be its own lie, and it would change every short message in a
// transcript.
func TestTruncateForPromptLeavesAFittingMessageAlone(t *testing.T) {
	for _, value := range []string{"", "is checkout slow?", strings.Repeat("x", 2000)} {
		if got := TruncateForPrompt(value, 2000); got != value {
			t.Errorf("TruncateForPrompt(%d bytes) changed a fitting message to %d bytes",
				len(value), len(got))
		}
	}
}

// Multi-byte text still has to come back valid, marker and all.
func TestTruncateForPromptKeepsRunesWhole(t *testing.T) {
	value := strings.Repeat("héllo wörld ", 40)
	got := TruncateForPrompt(value, 100)
	if !utf8.ValidString(got) {
		t.Fatalf("truncation produced invalid UTF-8: %q", got)
	}
	if len(got) > 100 || !strings.HasSuffix(got, PromptTruncationMarker) {
		t.Fatalf("bounded text = %q (%d bytes)", got, len(got))
	}
}
