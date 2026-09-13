package webui

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/promptarchive"
)

func promptStepText(t *testing.T, page episodePage) string {
	t.Helper()
	trace := buildEpisodeTrace(config.Pricing{}, page, nil)
	for _, step := range trace.Steps {
		if step.ID != "prompt" {
			continue
		}
		joined := ""
		for _, detail := range step.Details {
			joined += detail.Label + "\n" + detail.Status + "\n" +
				detail.Description + "\n" + detail.Body + "\n"
		}
		return joined
	}
	t.Fatal("trace has no prompt step")
	return ""
}

// The trace panel says what the archive is standing in for.
//
// context_manifest_texts stopped storing the instruction block — ~131 MB/week
// on blitz, ~60% of it the same block stored a hundred and forty times a day —
// and the panel is the one place an operator reads that row back. A page that
// rendered the marker as an unexplained tag in the middle of the prompt would
// have traded a storage bill for an operator quietly concluding the prompt was
// truncated, which is the failure the original landing refused to risk.
//
// It is LABELLED rather than reconstructed on purpose. ryker-prompt-v3 is
// bumped when the contract changes, not when a paragraph is reworded, and the
// paragraphs are reworded most weeks — so rebuilding the block from today's
// constants would show a reader words that model was never sent, under a
// version stamp claiming otherwise. The byte count and the digest are true; a
// reconstruction would not be.
func TestTheTracePanelNamesTheInstructionBlockTheArchiveElided(t *testing.T) {
	block := promptarchive.Block{
		Name: "service.watchActionChoicePolicy",
		Text: strings.Repeat("choose exactly one action. ", 64),
	}
	archived := promptarchive.Elide("ryker-prompt-v3",
		"You are Emisar.\n"+block.Text+"\n<untrusted-slack-context>\n"+
			`{"target_message":{"text":"did the deploy recover"}}`+
			"\n</untrusted-slack-context>", []promptarchive.Block{block})

	joined := promptStepText(t, episodePage{Manifest: ManifestRow{
		Version: 1, PromptVersion: "ryker-prompt-v3", RetainedPrompt: archived,
	}})
	for _, want := range []string{
		"service.watchActionChoicePolicy", "1,728", "ryker-prompt-v3",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("the panel never says %q, so the reader cannot tell what is missing "+
				"from the prompt in front of them:\n%s", want, joined)
		}
	}
	// The conversation the archive exists to keep is still rendered.
	if !strings.Contains(joined, "did the deploy recover") {
		t.Fatalf("the Slack context was lost from the panel:\n%s", joined)
	}
}

// A row archived before the elision landed renders exactly as it always has.
//
// There are hundreds of them and none will ever gain a marker. The panel must
// not grow a section apologising for an elision that never happened.
func TestALegacyArchivedPromptRendersWithoutAnElisionNotice(t *testing.T) {
	legacy := "SYSTEM: inspect the request\n" +
		"<untrusted-slack-context>\n" +
		`{"target_message":{"text":"check [REDACTED] this"}}` + "\n" +
		"</untrusted-slack-context>\nUSER: check this"

	joined := promptStepText(t, episodePage{Manifest: ManifestRow{
		Version: 1, PromptVersion: "ryker-prompt-v3", RetainedPrompt: legacy,
	}})
	if strings.Contains(strings.ToLower(joined), "elided") {
		t.Fatalf("a row with nothing elided was labelled as though it had been:\n%s", joined)
	}
	if !strings.Contains(joined, "check [REDACTED] this") {
		t.Fatalf("the legacy archive stopped rendering:\n%s", joined)
	}
}
