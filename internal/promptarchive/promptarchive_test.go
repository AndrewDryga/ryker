package promptarchive

import (
	"strings"
	"testing"
)

func longBlock(word string, bytes int) string {
	return strings.Repeat(word+" ", bytes/(len(word)+1)+1)
}

// A prompt archived before this existed carries no marker, and reads back
// exactly as it was written.
//
// The whole archive is 428 rows of history that nobody is going to rewrite, and
// a reader opening a week-old episode has to see what the model saw. Elide
// touches only what it recognizes, and Markers reports nothing rather than
// guessing at the shape of an old row.
func TestAPromptArchivedBeforeTheMarkerReadsBackUnchanged(t *testing.T) {
	legacy := "You are Emisar.\n<untrusted-slack-context>\n{\"target_message\":{}}\n" +
		"</untrusted-slack-context>\nUSER: check the api"
	if got := Elide("responder-prompt-v3", legacy, nil); got != legacy {
		t.Fatalf("an archive with no blocks to elide was rewritten:\n%q", got)
	}
	unrelated := []Block{{Name: "other", Text: longBlock("unrelated", 900)}}
	if got := Elide("responder-prompt-v3", legacy, unrelated); got != legacy {
		t.Fatalf("a prompt that carries none of the blocks was rewritten:\n%q", got)
	}
	if markers := Markers(legacy); len(markers) != 0 {
		t.Fatalf("a legacy row reported %d elided blocks it never had: %+v",
			len(markers), markers)
	}
}

// The instruction texts nest — the watch envelope contract contains the
// result-operations list, and StructuredResponseInstructions contains both the
// offer contract and the behavior-offer policy — so the order blocks are tried
// in decides how much comes out.
//
// Shortest first, the inner block is replaced, the outer one no longer matches
// anything, and the archive keeps ten kilobytes it was supposed to drop while
// reporting a marker that makes it look like it did not.
func TestTheOuterInstructionBlockIsElidedBeforeTheOneNestedInsideIt(t *testing.T) {
	inner := longBlock("inner", 600)
	outer := "opening\n" + inner + "\nclosing " + longBlock("outer", 600)
	prompt := "head\n" + outer + "\nSlack said something"

	got := Elide("responder-prompt-v3", prompt, []Block{
		{Name: "inner", Text: inner},
		{Name: "outer", Text: outer},
	})
	markers := Markers(got)
	if len(markers) != 1 || markers[0].Block != "outer" {
		t.Fatalf("the nested block was elided first, leaving the outer one stored in full: %+v",
			markers)
	}
	if strings.Contains(got, "opening") || strings.Contains(got, "closing") {
		t.Fatalf("the outer block's own text survived: %q", got)
	}
	if !strings.Contains(got, "Slack said something") {
		t.Fatalf("the conversation was elided with the instructions: %q", got)
	}
	if markers[0].Bytes != len(outer) {
		t.Fatalf("marker reports %d bytes elided, want %d", markers[0].Bytes, len(outer))
	}
}

// A block small enough to appear inside the conversation is never elided.
//
// The archive replaces text by exact match, and an operator quoting a line of
// the prompt back at Responder is a thing that happens. Eliding a short block
// would delete the operator's message and report it as an instruction, which is
// a far worse outcome than storing a couple of hundred bytes.
func TestAShortBlockIsLeftAloneRatherThanCutOutOfSomebodysMessage(t *testing.T) {
	short := "Choose exactly one action."
	if len(short) >= MinBlockBytes {
		t.Fatalf("this test needs a block under %d bytes", MinBlockBytes)
	}
	prompt := "instructions\n<untrusted-slack-context>\n" +
		`{"target_message":{"text":"you told it: ` + short + `"}}` +
		"\n</untrusted-slack-context>"
	got := Elide("responder-prompt-v3", prompt, []Block{{Name: "short", Text: short}})
	if got != prompt {
		t.Fatalf("a short block was cut out of a Slack message:\n%q", got)
	}
}

// The marker has to survive being read back, because reading it back is the
// only thing standing between an operator and a wall of text that silently lost
// half its content.
func TestAMarkerNamesTheVersionBlockSizeAndDigestItStandsFor(t *testing.T) {
	text := longBlock("instruction", 1200)
	prompt := "head\n" + text + "\ntail"
	got := Elide("responder-prompt-v42", prompt, []Block{{Name: "pkg.Symbol", Text: text}})

	markers := Markers(got)
	if len(markers) != 1 {
		t.Fatalf("markers = %+v, want exactly one", markers)
	}
	marker := markers[0]
	switch {
	case marker.Version != "responder-prompt-v42":
		t.Fatalf("marker version = %q", marker.Version)
	case marker.Block != "pkg.Symbol":
		t.Fatalf("marker block = %q", marker.Block)
	case marker.Bytes != len(text):
		t.Fatalf("marker bytes = %d, want %d", marker.Bytes, len(text))
	case len(marker.Digest) != 12:
		t.Fatalf("marker digest = %q, want twelve hex characters", marker.Digest)
	}
	if ElidedBytes(markers) != len(text) {
		t.Fatalf("ElidedBytes = %d, want %d", ElidedBytes(markers), len(text))
	}
	// Two blocks with the same NAME and different words must be told apart, or
	// the digest is decoration. prompt_version is bumped for contract changes,
	// not for the weekly rewording, so the name and the version together do not
	// pin the text; the digest is what does.
	other := Elide("responder-prompt-v42", "head\n"+longBlock("reworded", 1200)+"\ntail",
		[]Block{{Name: "pkg.Symbol", Text: longBlock("reworded", 1200)}})
	if Markers(other)[0].Digest == marker.Digest {
		t.Fatal("two different instruction texts archived under the same digest")
	}
}
