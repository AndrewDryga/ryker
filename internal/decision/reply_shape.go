package decision

import (
	"fmt"
	"strings"
)

// How long a Slack answer may be, and how it may end.
//
// These two rules were prose for months and prose stopped working. An audit of
// 244 posted replies found a median of 81 words against a stated bar of one to
// three sentences, one in five inside it, and 25 replies that closed on a
// caveat rather than an answer — a 245-word four-paragraph reply to the word
// "hi", a 266-word reply to an eight-word yes-or-no question. The prompt that
// produced them already said "a one-line question gets one to three sentences"
// and already banned "remaining boundary" by name, and the five messages that
// postdate every one of those rules are worse than the corpus average. The
// instruction was present and read; it simply did not bind. So the host
// measures the reply now instead of asking for it.

// handBackFloor is the length below which the closing rule does not apply. A
// short reply that is only a blocker is an honest answer — "the workspace is
// locked by run-7nxL and I cannot clear it from here" is the finding. The
// measured failure is a long message that trails off into caveats after the
// answer has already been given.
const handBackFloor = 40

// ReplyShapeCorrection returns what to tell the model about a reply the host
// refuses to post as written, or "" when the reply is acceptable.
//
// The trigger is the message being answered, because length is only meaningful
// against the question that earned it. The lane says how much room the answer
// deserves.
func ReplyShapeCorrection(trigger, lane, action, message string) string {
	if action != "reply" {
		return ""
	}
	message = strings.TrimSpace(message)
	if message == "" {
		return ""
	}
	words := ProseWordCount(message)
	if budget := ReplyWordBudget(trigger, lane); budget > 0 && words > budget {
		return fmt.Sprintf(
			"the reply runs %d words against a message of %d words, over the %d-word bound for a "+
				"message that size. Rewrite it: lead with the answer, keep only what changes the "+
				"reader's next decision, and delete background, restated context, and caveats "+
				"nobody asked for. A one-line question gets one to three sentences.",
			words, len(strings.Fields(trigger)), budget,
		)
	}
	if words <= handBackFloor {
		return ""
	}
	if phrase := HandBackClosing(message); phrase != "" {
		return "the reply closes on `" + phrase + "`, which hands the question back instead of " +
			"answering it. Rewrite the ending so the last sentence is what you established or the " +
			"next concrete action. If a blocker changes what the reader should do, name it in one " +
			"clause inside the answer rather than as the parting thought."
	}
	return ""
}

// ReplyWordBudget is the longest reply the host will accept for this trigger,
// or 0 when the trigger asked for depth and no bound applies.
//
// The ladder is measured rather than chosen. A message of fifteen words or
// fewer drew a median of 93 words across the audited corpus, so a bound has to
// sit below what the model does unprompted or it enforces nothing. It sits
// above the stated one-to-three-sentence target rather than on it, because
// every rejection costs a whole extra turn and the prompt should still be
// doing most of the work; the host is here for the answers that blow the bound
// by a factor of four, not for the ones that miss it by a sentence.
func ReplyWordBudget(trigger, lane string) int {
	if RequestedDepth(trigger) {
		return 0
	}
	budget := 260
	switch words := len(strings.Fields(trigger)); {
	case lane == "conversation" && words <= 4 && !strings.Contains(trigger, "?"):
		// A greeting in the bounded lane. That turn calls no tools, so there is
		// nothing to report that the conversation did not already contain, and
		// this is the tier the word "hi" drew 245 words and four paragraphs in.
		return 60
	case words <= 15:
		budget = 100
	case words <= 50:
		budget = 180
	}
	if lane != "conversation" {
		// An investigation turn called tools and has fresh evidence to report
		// that a bounded conversation turn does not have and cannot produce.
		budget += budget / 2
	}
	return budget
}

// RequestedDepth reports whether the message asked for a long answer. Someone
// who says "walk me through it" has waived the bound, and correcting them into
// three sentences would be the same failure in the other direction.
func RequestedDepth(trigger string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(trigger), " "))
	return EpisodeContainsAny(normalized,
		"in detail", "detailed", "in full", "full report", "full picture",
		"step by step", "step-by-step", "walk me through", "walk through",
		"deep dive", "deep-dive", "comprehensive", "elaborate", "long version",
		"write up", "write-up", "everything you", "as much detail",
	)
}

// ProseWordCount counts the words a reader has to read. Fenced code and table
// rows are content someone scans for a value, not prose padding an answer, and
// counting them would punish the one shape a long answer is allowed to take.
func ProseWordCount(message string) int {
	count := 0
	fenced := false
	for _, line := range strings.Split(message, "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(trimmed, "```"):
			fenced = !fenced
		case fenced, strings.HasPrefix(trimmed, "|"):
		default:
			count += len(strings.Fields(trimmed))
		}
	}
	return count
}

// handBackClosings are the phrases measured at the ends of real replies, where
// the last thing the reader was left holding was a gap rather than a finding.
// Six replies closed on "still need", five on "one gap", three on "remain
// unverified", three on "remaining boundary" — a phrase the prompt bans by
// name — and two on "can't tell you".
var handBackClosings = []string{
	"still need", "one gap", "gap worth naming", "remaining boundary",
	"remain unverified", "remains unverified", "stays unverified", "is unverified",
	"cant tell you", "cannot tell you", "cant say", "cannot say for",
	"couldnt verify", "could not verify", "couldnt check", "could not check",
	"couldnt confirm", "could not confirm", "youll need to check",
	"you will need to check", "you would need to check", "someone should check",
}

// HandBackClosing returns the hand-back phrase a reply ends on, or "".
//
// Matched only in the close, because position is the whole rule: "I can't
// verify the pool size from here, so I read the committed config instead" is a
// good sentence in the middle of an answer and a bad one as its last word.
func HandBackClosing(message string) string {
	closing := replyClosing(message)
	for _, phrase := range handBackClosings {
		if strings.Contains(closing, phrase) {
			return phrase
		}
	}
	return ""
}

// replyClosing is the last two sentences of the last non-empty line, folded to
// lowercase with apostrophes and inline emphasis removed so "can't", "can’t"
// and "*can't*" are one phrase.
//
// The last line rather than the last sentence of the message, because a reply
// that trails off into a bullet list ends on that bullet. Two sentences rather
// than one, because "I still need the workspace ID. Let me know." hands the
// question back in the first of them.
func replyClosing(message string) string {
	last := ""
	lines := strings.Split(message, "\n")
	for index := len(lines) - 1; index >= 0 && last == ""; index-- {
		last = strings.TrimSpace(lines[index])
	}
	last = strings.ToLower(strings.NewReplacer(
		"'", "", "’", "", "`", "", "*", "", "_", "", "~", "",
	).Replace(last))
	sentences := strings.FieldsFunc(last, func(symbol rune) bool {
		return symbol == '.' || symbol == '!' || symbol == '?'
	})
	if len(sentences) > 2 {
		sentences = sentences[len(sentences)-2:]
	}
	return strings.Join(strings.Fields(strings.Join(sentences, " ")), " ")
}
