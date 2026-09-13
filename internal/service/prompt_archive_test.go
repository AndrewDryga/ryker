package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/promptarchive"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

// The archive keeps the conversation and forgets the instructions.
//
// context_manifest_texts grew ~131 MB/week on blitz — ~560 MB at the 30-day
// episode-history horizon — and ~60% of every row was the same instruction
// block, stored a hundred and forty times a day. 426 of 428 prompts were
// unique, so deduplication had nothing to work with; the only compressible
// thing in the row was the part the host wrote itself and can name. Measured
// after: 76,772 bytes off a full briefing, ~42% off the archive.
//
// Both halves of this are load-bearing and they pull in opposite directions.
// The archive must LOSE the instructions, or the row is the same size it was.
// It must KEEP everything else byte-for-byte — the envelope tags, the Slack
// JSON inside them, the memory layers — because the trace panel parses
// <untrusted-slack-context> out of exactly this text, and the previous attempt
// at this problem was rejected for breaking that. And the SUBMITTED prompt must
// not move at all: it is what the replay fingerprint was taken over, and a
// saving bought out of the transport copy would be a saving bought by lying
// about what the model read.
func TestTheArchiveKeepsTheEnvelopeAndElidesTheInstructions(t *testing.T) {
	// One sentence out of an elided block, and one out of the conversation.
	// Asserting on the marker alone would pass on an archive that wrote a
	// marker and kept the paragraph beside it.
	const instruction = "Background learning is part of normal channel observation"
	const conversation = "the checkout latency alert is still firing"
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","message":"Recovered."}`
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack_archive", EnvelopeID: "env_archive", EventID: "EvArchive",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.500", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> " + conversation + ", did it recover?",
	}); err != nil || !created {
		t.Fatalf("admit mention = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	run, err := st.GetAgentRunBySource(ctx, "watch", "slack_archive")
	if err != nil {
		t.Fatalf("load the agent run: %v", err)
	}
	latest, err := st.GetLatestContextManifest(ctx, run.EpisodeID)
	if err != nil {
		t.Fatalf("load the attempt context manifest: %v", err)
	}
	manifest, err := st.GetContextManifest(ctx, latest.ID)
	if err != nil {
		t.Fatalf("re-read the manifest: %v", err)
	}

	// What was sent is untouched. This is asserted first because every other
	// assertion below is worthless if the elision reached the transport copy.
	if !strings.Contains(manifest.SubmittedPrompt, instruction) {
		t.Fatal("the submitted prompt lost the instruction block, so the model was " +
			"briefed with whatever the archive decided to keep")
	}
	if strings.Contains(manifest.SubmittedPrompt, "<host-elided-instructions ") {
		t.Fatal("an archive marker reached the prompt that was actually submitted")
	}

	archived := manifest.RetainedPrompt
	if archived == "" {
		t.Fatal("no prompt was retained for the attempt, so nothing outlives the turn")
	}
	markers := promptarchive.Markers(archived)
	if len(markers) == 0 {
		t.Fatalf("the archive stored the instruction block in full: %d bytes, no marker",
			len(archived))
	}
	if strings.Contains(archived, instruction) {
		t.Fatal("the archive wrote a marker and kept the instruction paragraph beside it")
	}
	for _, marker := range markers {
		if marker.Version != rykerPromptVersion {
			t.Fatalf("marker %q names prompt version %q, not the version that assembled it (%q)",
				marker.Block, marker.Version, rykerPromptVersion)
		}
		if marker.Block == "" || marker.Bytes <= 0 || marker.Digest == "" {
			t.Fatalf("a marker cannot say what it stands for: %+v", marker)
		}
	}

	// The envelope survives whole. promptEnvelope in the trace panel reads the
	// Slack JSON out of these exact tags, and the operator's own words are the
	// thing the archive exists to keep.
	for _, want := range []string{
		"<untrusted-slack-context>", "</untrusted-slack-context>", conversation,
	} {
		if !strings.Contains(archived, want) {
			t.Fatalf("the archive lost %q, which was never an instruction", want)
		}
	}

	elided := promptarchive.ElidedBytes(markers)
	if elided < len(archived) {
		t.Fatalf("the archive elided %d bytes and still stores %d; the instruction "+
			"block was supposed to be the larger half", elided, len(archived))
	}
	t.Logf("archived %d bytes in place of %d submitted; %d bytes of instructions elided across %d blocks",
		len(archived), len(manifest.SubmittedPrompt), elided, len(markers))
}

// Every block on the dictionary must be able to survive being cut out of a
// prompt without taking a structural marker with it.
//
// The trace panel finds the Slack context by string index, so a block whose
// text spanned <untrusted-slack-context> would elide the tag and take the whole
// memory projection with it — the exact failure the original landing refused to
// risk by not truncating at all. This is cheap to assert and impossible to
// notice by reading a 5 KB constant.
func TestNoElidedInstructionBlockSwallowsAStructuralTag(t *testing.T) {
	structural := []string{
		"<untrusted-slack-context>", "</untrusted-slack-context>",
		"<trusted-responder-context>", "<trusted-ryker-configuration>",
		"\nUSER:",
	}
	for _, block := range instructionBlocks() {
		if strings.TrimSpace(block.Text) == "" {
			t.Errorf("block %q is empty, so it names nothing", block.Name)
			continue
		}
		if len(block.Text) < promptarchive.MinBlockBytes {
			t.Logf("block %q is %d bytes and will never be elided; drop it or merge it",
				block.Name, len(block.Text))
		}
		for _, tag := range structural {
			if strings.Contains(block.Text, tag) {
				t.Errorf("block %q contains %q; eliding it would break the trace panel's "+
					"envelope parsing", block.Name, tag)
			}
		}
	}
}
