package decision_test

import (
	"strings"
	"testing"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// words builds a reply body of the requested length. The audit measured
// length, not content, so the filler stands in for the paragraphs of restated
// context that made these replies long in the first place.
func words(count int) string {
	return strings.TrimSpace(strings.Repeat("the scheduler reported a healthy allocation again ", count/7))
}

// The two replies the operator actually received, reconstructed at their
// measured lengths. A validator that does not reject these has not been
// written.
func TestReplyShapeRejectsTheRepliesThatCausedThisRule(t *testing.T) {
	greeting := words(238) + "\n\nOne gap worth naming: no Emisar tool is exposed in this " +
		"session, so I couldn't check the live account."
	if got := decisionpkg.ProseWordCount(greeting); got < 240 || got > 260 {
		t.Fatalf("reconstructed greeting reply is %d words, not the measured 245", got)
	}
	correction := decisionpkg.ReplyShapeCorrection("hi", "conversation", "reply", greeting)
	if !strings.Contains(correction, "60-word bound") {
		t.Fatalf("a 245-word answer to \"hi\" was not rejected: %q", correction)
	}
	// The same reply out of the bounded lane, where an investigation gets half
	// again as much room, is still four times over.
	if decisionpkg.ReplyShapeCorrection("hi", "investigation", "reply", greeting) == "" {
		t.Fatal("a 245-word answer to \"hi\" was accepted in the investigation lane")
	}

	terraform := "I can't see the lock from here — Terraform Cloud isn't reachable in this " +
		"session — so I can't tell you what's holding it. " + words(250)
	if got := decisionpkg.ProseWordCount(terraform); got < 255 || got > 285 {
		t.Fatalf("reconstructed Terraform reply is %d words, not the measured 266", got)
	}
	correction = decisionpkg.ReplyShapeCorrection(
		"is it save to unlock the terraform workspace?", "conversation", "reply", terraform,
	)
	if !strings.Contains(correction, "100-word bound") {
		t.Fatalf("a 266-word answer to an 8-word question was not rejected: %q", correction)
	}
	if decisionpkg.ReplyShapeCorrection(
		"is it save to unlock the terraform workspace?", "investigation", "reply", terraform,
	) == "" {
		t.Fatal("a 266-word answer to an 8-word question was accepted in the investigation lane")
	}
}

// The five messages that postdate every prose rule ran a median of 170 words
// with none under 60, which is the corpus this bound has to bite on.
func TestReplyShapeBoundsLengthAgainstTheTriggerAndLane(t *testing.T) {
	for _, test := range []struct {
		name     string
		trigger  string
		lane     string
		reply    string
		rejected bool
	}{
		{"greeting draws a paragraph", "thanks!", "conversation", words(170), true},
		{"greeting draws a sentence", "thanks!", "conversation", words(40), false},
		{"short question, median answer", "did the deploy land?", "conversation", words(170), true},
		{"short question, tight answer", "did the deploy land?", "conversation", words(90), false},
		{
			"a paragraph of context earns a longer answer",
			strings.Repeat("context ", 30) + "so which allocation should we drain first?",
			"conversation", words(170), false,
		},
		{
			"an investigation reports its evidence",
			"did the deploy land?", "investigation", words(140), false,
		},
		{
			"depth was asked for",
			"walk me through what happened in detail", "conversation", words(400), false,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			correction := decisionpkg.ReplyShapeCorrection(
				test.trigger, test.lane, "reply", test.reply,
			)
			if rejected := correction != ""; rejected != test.rejected {
				t.Fatalf("rejected = %t, want %t (%d words): %q",
					rejected, test.rejected, decisionpkg.ProseWordCount(test.reply), correction)
			}
		})
	}
}

// A table or a config listing is the one shape a long answer is allowed to
// take, and word-counting it would reject the most useful replies Responder
// produces.
func TestReplyShapeDoesNotCountCodeOrTableRows(t *testing.T) {
	reply := "Six runs are queued behind the lock:\n\n```\n" +
		strings.Repeat("run-ZGHrDH6bLQ2iKP1X discarded without applying\n", 30) +
		"```\n\nThe first one is holding it."
	if correction := decisionpkg.ReplyShapeCorrection(
		"which runs are stuck?", "conversation", "reply", reply,
	); correction != "" {
		t.Fatalf("a fenced listing was counted as prose: %q", correction)
	}
	table := "| run | state |\n" + strings.Repeat("| run-7nxL1Gu4pT3fnVE1 | discarded |\n", 40)
	if correction := decisionpkg.ReplyShapeCorrection(
		"which runs are stuck?", "conversation", "reply", "Here they are.\n\n"+table,
	); correction != "" {
		t.Fatalf("a table was counted as prose: %q", correction)
	}
}

// 25 of 244 replies ended on a caveat. Position is the whole rule.
func TestReplyShapeRejectsOnlyAClosingHandBack(t *testing.T) {
	body := words(70)
	for _, closing := range []string{
		"One gap worth naming: no Emisar tool is exposed in this session.",
		"I still need the workspace ID before I can clear it.",
		"Two allocations remain unverified.",
		"That is the remaining boundary here.",
		"I can't tell you which run is holding it.",
		"You'll need to check the Terraform Cloud console yourself.",
	} {
		reply := body + "\n\n" + closing
		phrase := decisionpkg.HandBackClosing(reply)
		if phrase == "" {
			t.Fatalf("closing hand-back not detected: %q", closing)
		}
		correction := decisionpkg.ReplyShapeCorrection(
			strings.Repeat("context ", 30)+"what is going on?", "conversation", "reply", reply,
		)
		if !strings.Contains(correction, "hands the question back") {
			t.Fatalf("closing %q produced %q", closing, correction)
		}
	}

	// The same sentence in the middle, with a finding after it, is exactly what
	// the rule asks for and must survive.
	legitimate := "I can't verify the pool size from here, so I read the committed config " +
		"instead. " + body + "\n\nThe pool is set to eight and the last apply took it there."
	if phrase := decisionpkg.HandBackClosing(legitimate); phrase != "" {
		t.Fatalf("a mid-message caveat was read as a closing hand-back: %q", phrase)
	}
	if correction := decisionpkg.ReplyShapeCorrection(
		strings.Repeat("context ", 30)+"what is the pool size?", "conversation", "reply", legitimate,
	); correction != "" {
		t.Fatalf("a mid-message caveat was rejected: %q", correction)
	}

	// A short reply that is nothing but the blocker is an honest answer.
	short := "Terraform Cloud isn't reachable from this session, so I can't tell you what is " +
		"holding the lock."
	if correction := decisionpkg.ReplyShapeCorrection(
		"what is holding the lock?", "conversation", "reply", short,
	); correction != "" {
		t.Fatalf("a short blocker-only answer was rejected: %q", correction)
	}
}

// Only a reply has a shape to get wrong.
func TestReplyShapeIgnoresNonReplyActions(t *testing.T) {
	for _, action := range []string{"ignore", "react", "escalate"} {
		if correction := decisionpkg.ReplyShapeCorrection(
			"hi", "conversation", action, words(400),
		); correction != "" {
			t.Fatalf("action %q was shape-checked: %q", action, correction)
		}
	}
	if correction := decisionpkg.ReplyShapeCorrection("hi", "conversation", "reply", "  "); correction != "" {
		t.Fatalf("an empty reply was shape-checked: %q", correction)
	}
}
