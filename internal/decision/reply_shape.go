package decision

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
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
//
// The first cut of those measurements then shipped unmeasured, and it was
// wrong. The audit read a sample; scripts/reply-shape-replay.sh replays all 246
// posted replies through this file, and the first ladder rejected 27 of them —
// eleven percent of everything Responder has ever said — of which reading every
// one says eighteen were good answers. A rejection costs a whole extra model
// turn, so a rule that is wrong two times in three does not survive contact
// with an operator. It gets switched off, and then nothing bounds anything.
//
// The numbers below are the second cut: 11 rejections, 4.5%, of which two are
// answers this file would rather have kept and does not know how to keep. Each
// constant carries the messages that moved it, so changing one has to argue
// with them, and the replay is the argument.

// handBackFloor is the length below which the closing rule does not apply. A
// short reply that is only a blocker is an honest answer — "the workspace is
// locked by run-7nxL and I cannot clear it from here" is the finding. The
// measured failure is a long message that trails off into caveats after the
// answer has already been given.
//
// Raised from 40 after replaying the corpus: four replies landed in the 40-to-60
// band and three of them were good — a 43-word apply report that ends "the
// separate 63 detected drift entries still need review", a 44-word recovery
// note that ends on a decision not to act, a 47-word commit report that ends on
// the next governed step. At that length the reply has not had room to give the
// answer and then trail off; the caveat is the second half of a two-sentence
// finding.
const handBackFloor = 60

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
	// A scope disclaimer is refused at any length; everything else on the list
	// keeps the floor, because at that length a caveat is usually the second
	// half of a two-sentence finding rather than a trailing gap.
	phrase := scopeDisclaimerClosing(message)
	if phrase == "" && words > handBackFloor {
		phrase = HandBackClosing(message)
	}
	if phrase != "" {
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
// The ladder is measured rather than chosen, and it was measured wrong the
// first time. The replay found the fifteen-word tier bound of 150 rejecting
// thirteen replies, of which a read of every one says ten were good: dense
// alert triage where each bullet carries its own timestamped measurement,
// engineering reports that name the commit and the validation that ran, a
// 152-word answer that missed by two.
//
// 154 of the 246 replies answered a trigger of fifteen words or fewer, and that
// tier has a median of 80 words, a 90th percentile of 149 and a 98th of 203.
// The old bound sat on its 90th percentile, so it spent an extra model turn on
// one reply in ten and caught the tenth for being ordinary. A bound belongs
// above what a tier produces when it is behaving — the host is for the answer
// that blows it by a factor of four, and at fifteen words of trigger the corpus
// says that is 266 words, not 165.
func ReplyWordBudget(trigger, lane string) int {
	if RequestedDepth(trigger) {
		return 0
	}
	words := len(strings.Fields(trigger))
	if GreetingTrigger(trigger) {
		// A greeting, in either lane. This is the tier the word "hi" drew 245
		// words and four paragraphs in, and no amount of fresh evidence makes
		// that the answer to a greeting, so the investigation lane gets no
		// extra room here.
		return 60
	}
	budget := 260
	switch {
	case words <= 15:
		budget = 140
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

// greetingWords maps the words a message may consist of and still be only an
// opening. True is a greeting; false is a word allowed to keep one company. The
// list is short on purpose: every word added takes a real request down to the
// sixty-word tier, and the replay found that most short triggers are terse
// instructions rather than pleasantries.
var greetingWords = map[string]bool{
	"hi": true, "hii": true, "hiya": true, "hey": true, "heya": true,
	"hello": true, "yo": true, "howdy": true, "thanks": true, "thank": true,
	"thankyou": true, "ty": true, "thx": true, "cheers": true, "gm": true,
	"morning": true, "afternoon": true, "evening": true, "night": true,
	"good": true, "you": false, "all": false, "there": false, "again": false,
	"team": false, "everyone": false, "and": false,
}

// slackMarkup matches the angle-bracket spans Slack wraps mentions, channel
// references, links and date renderings in.
var slackMarkup = regexp.MustCompile(`<[^>]*>`)

// GreetingTrigger reports whether the message is nothing but a greeting or a
// thank-you once Slack markup and punctuation are removed.
//
// A greeting is recognised by what it says, not by how short it is. The
// four-word triggers in the corpus are mostly terse instructions — "Make a pr",
// "activate it", "Test again", "why it failed", a bare task title — and each of
// them drew a good answer of 68 to 162 words that a length-only rule rejects.
// One trigger in the corpus is a bare greeting, and it drew 245 words.
func GreetingTrigger(trigger string) bool {
	greeted := false
	stripped := slackMarkup.ReplaceAllString(strings.ToLower(trigger), " ")
	for _, field := range strings.FieldsFunc(stripped, notLetter) {
		opener, allowed := greetingWords[field]
		if !allowed {
			return false
		}
		greeted = greeted || opener
	}
	return greeted
}

func notLetter(symbol rune) bool { return !unicode.IsLetter(symbol) }

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
// Five replies closed on "one gap", three on "remain unverified", three on
// "remaining boundary" — a phrase the prompt bans by name.
//
// "still need" was on this list and is not any more. It was the most frequent
// closing in the audit at six replies, and replaying those six found that not
// one of them handed anything back: "the separate 63 detected drift entries
// still need review", "the two read actions still need to reveal the plan and
// apply error first", "after deployment, we still need to verify the exact
// account with account.show". Every one names remaining work after the answer
// was delivered, which is what the correction this rule sends asks for. The
// audit matched a grammatical form and read it as a speech act. What makes a
// closing a hand-back is that it points at the reader — "I still need the
// workspace ID", "you'll need to check" — so the phrase is narrowed to the
// first person rather than dropped, and the reader-directed forms stay.
var handBackClosings = []string{
	"i still need", "one gap", "gap worth naming", "remaining boundary",
	"remain unverified", "remains unverified", "stays unverified", "is unverified",
	"cant tell you", "cannot tell you", "cant say", "cannot say for",
	"couldnt verify", "could not verify", "couldnt check", "could not check",
	"couldnt confirm", "could not confirm", "youll need to check",
	"you will need to check", "you would need to check", "someone should check",
}

// scopeDisclaimerClosings are hand-backs that carry nothing at all, so the
// length floor does not apply to them.
//
// The floor exists because a short caveat is usually the second half of a
// two-sentence finding: the three good replies that raised it from 40 to 60 end
// on remaining work, a decision not to act, and the next governed step. Each
// gives the reader something.
//
// These give nothing. An operator read two Terraform replies closing on
// "application behavior and customer impact weren't tested by this check" and
// "a public website request wasn't tested" and asked the question this encodes:
// "why say it if it wasn't tested? either it should be tested or not
// mentioned." A closing that names an untested thing with no reason it could
// not be tested and no action to test it is a gap handed over as an answer, at
// any length — the two above are 27 and 35 words, comfortably under the floor
// the actionable caveats needed.
//
// Position is still the whole rule. Naming what was out of scope mid-message is
// fine; ending on it is not.
var scopeDisclaimerClosings = []string{
	"wasnt tested", "was not tested", "werent tested", "were not tested",
	"isnt tested", "is not tested", "arent tested", "are not tested",
	"untested by this", "not covered by this check",
}

// scopeDisclaimerClosing returns the bare scope disclaimer a reply ends on, or
// "". Separate from HandBackClosing because only these bypass the length floor.
func scopeDisclaimerClosing(message string) string {
	closing := replyClosing(message)
	for _, phrase := range scopeDisclaimerClosings {
		if strings.Contains(closing, phrase) {
			return phrase
		}
	}
	return ""
}

// HandBackClosing returns the hand-back phrase a reply ends on, or "".
//
// Matched only in the close, because position is the whole rule: "I can't
// verify the pool size from here, so I read the committed config instead" is a
// good sentence in the middle of an answer and a bad one as its last word.
func HandBackClosing(message string) string {
	closing := replyClosing(message)
	for _, phrase := range append(append([]string{}, handBackClosings...), scopeDisclaimerClosings...) {
		if strings.Contains(closing, phrase) {
			return phrase
		}
	}
	return ""
}

// replyClosing is the last substantive sentence of the last non-empty line,
// folded to lowercase with apostrophes and inline emphasis removed so "can't",
// "can’t" and "*can't*" are one phrase.
//
// The last line rather than the last sentence of the message, because a reply
// that trails off into a bullet list ends on that bullet.
//
// One sentence rather than two. The two-sentence window was there to catch "I
// still need the workspace ID. Let me know.", where the hand-back is followed
// by a sign-off, and it is kept for that by skipping trailing sentences too
// short to carry a finding. But a plain two-sentence window read the caveat in
// the second-to-last sentence of replies that then closed on exactly what the
// rule asks for: "Customer impact remains unverified, and ... The safest
// follow-up is to verify the migration proxies through their representative
// connection path." That reply ends on the next concrete action and was
// rejected anyway. Position is the whole rule, so the window has to be the
// position.
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
	for index := len(sentences) - 1; index >= 0; index-- {
		if words := strings.Fields(sentences[index]); len(words) >= closingSentenceWords {
			return strings.Join(words, " ")
		}
	}
	return strings.Join(strings.Fields(last), " ")
}

// closingSentenceWords is the shortest sentence that can be the closing rather
// than a sign-off after it. "Let me know." and "Happy to dig in." are three and
// four words; the shortest real closing in the corpus is nine.
const closingSentenceWords = 6
