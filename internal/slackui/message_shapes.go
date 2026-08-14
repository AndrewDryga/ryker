package slackui

import (
	"fmt"
	"strings"
)

// The five shapes behind memory, preferences, standing rules and schedules.
//
// Those four subjects meet a person in exactly five situations: being offered
// something, being told it was saved, being told its state changed, listing
// what exists, and being asked to judge one entry. Twenty-six constructors had
// each grown a private answer to those five questions — different verbs for the
// same act, buttons pooled at the bottom of a list in three of them, numbered
// labels ("Forget memory 3") in two, a red Forget one second after a save — so
// the same situation read differently depending on which subject it happened
// to, and none of the differences meant anything.
//
// These helpers are the shapes. A constructor supplies the words its subject
// needs; nothing else gets to decide layout.

// directoryRowLimit is how many items a directory shows.
//
// A row costs two blocks — the item, then its controls — where a section-only
// listing cost one, so moving buttons next to their subject also doubled what a
// listing costs. Memory allowed twenty entries: rendered as rows, twenty of them
// plus a review nudge and four continuity rollups is 53 blocks, and Slack
// rejects a message over 50 whole — after the query, in front of whoever asked.
// Ten leaves the header, the count line and the over-cap line room inside the
// ceiling.
const directoryRowLimit = 10

// offerProposal is one thing an offer asks permission to save.
//
// Quote is the proposal in the words it will be saved in, because those are the
// words being agreed to. Facts is the second line — scope and expiry, the two
// things that decide whether the proposal is safe to accept.
type offerProposal struct {
	Quote   string
	Facts   string
	Actions []Action
}

// offerCard attaches proposals to the conversation that produced them.
//
// The message arrives carrying a lede — the reply the offer came out of — and
// the proposal is appended to it as rows, so the confirmation sits on the thing
// it confirms rather than in a pile at the bottom of the card. A multi-item
// offer puts its one confirmation on the first row, because one confirmation is
// what it takes.
//
// boundary is a single context line: not saved yet, and what saving it still
// cannot do. One line, because it is the same line every time and a reader who
// has met it twice is already skipping it.
func offerCard(message Message, boundary string, proposals ...offerProposal) Message {
	for _, proposal := range proposals {
		message = AppendRow(message, proposalText(proposal), proposal.Actions)
	}
	if boundary == "" {
		return message
	}
	// One card can carry two offers — a preference and a standing rule out of
	// the same sentence — and they share a boundary. Said twice it reads as two
	// different warnings that happen to be identical.
	for _, existing := range message.Context {
		if existing == boundary {
			return message
		}
	}
	message.Context = append(message.Context, boundary)
	return message
}

func proposalText(proposal offerProposal) string {
	text := quoteLines(proposal.Quote)
	if proposal.Facts != "" {
		if text != "" {
			text += "\n"
		}
		text += proposal.Facts
	}
	return text
}

// receiptCard is what a save looks like a second after it happened.
//
// One line: the verb, then what is now true. The card that preceded it said the
// same thing three times — a header, a restatement, and a section repeating the
// value — and then offered a red Forget button, which is a strange thing to put
// in front of somebody who has just confirmed they want the thing.
//
// The one action is Undo, neutral and unconfirmed. The regret arrives seconds
// after the save or not at all, and a confirmation dialog on the way out of a
// mistake is a toll on the wrong person; re-saving is one message away.
func receiptCard(fallback, verb, restatement string, facts []string, actions ...Action) Message {
	message := Message{
		Text:     fallback,
		Stripe:   StripeDone,
		Sections: []string{strings.TrimSpace("*" + verb + "* " + restatement)},
		Actions:  actions,
	}
	if line := joinFacts(facts); line != "" {
		message.Context = []string{line}
	}
	return message
}

// undoAction is the receipt's one control, wired to the same action that
// forgets or deletes the thing — undo and delete are the same operation, and
// only the moment tells them apart.
func undoAction(actionID, value string) Action {
	return Action{ID: actionID, Label: "Undo", Value: value}
}

// stateChangeCard states what is true now, and offers the way back.
//
// Grey, because nobody is waiting on anything: the state changed, that is the
// whole event. Header-less, because every one of these cards used to carry a
// header that said "Preference disabled" above a sentence that said the
// preference was disabled. The fallback text still leads with the outcome, so
// the notification and the sidebar keep the word.
//
// note is the retention or audit line where the subject has one, and nothing
// otherwise. A deletion passes no actions at all — the thing it would act on
// does not exist any more.
func stateChangeCard(fallback, statement, note string, actions ...Action) Message {
	message := Message{
		Text:     fallback,
		Stripe:   StripeIdle,
		Sections: []string{statement},
		Actions:  actions,
	}
	if note != "" {
		message.Context = []string{note}
	}
	return message
}

// directoryEntry is one item in a list, with the controls that act on it.
type directoryEntry struct {
	Text     string
	Actions  []Action
	Overflow []Action
}

// directoryCard lists what exists, with each item's controls under that item.
//
// Every one of these lists used to number its buttons — "Forget memory 3", "Run
// now #2" — because the buttons were pooled at the bottom of the card and had
// to point back up at a list. A row carries its own controls, so the number is
// noise and the label can say what the button does.
//
// more is what the card says when there are more items than it shows: the
// listing is bounded and saying so is the difference between a short list and a
// wrong one.
func directoryCard(message Message, entries []directoryEntry, more string) Message {
	for _, entry := range entries[:min(len(entries), directoryRowLimit)] {
		message = AppendRowMenu(message, entry.Text, entry.Actions, entry.Overflow)
	}
	if extra := len(entries) - directoryRowLimit; extra > 0 {
		message.Context = append(message.Context, strings.TrimSpace(
			fmt.Sprintf("and %d more — %s", extra, more),
		))
	}
	return message
}

// reviewCard asks one question about one entry.
//
// The entry leads. The card that preceded it opened with "This saved memory has
// not been used recently", which is both the reason it is being asked about and
// a sentence the facts line underneath states precisely — so the entry now
// comes first and the reason is one sentence after it.
//
// Salmon: this is the one shape in the family that is genuinely waiting on a
// person.
func reviewCard(header, why string, entries []string, actions ...Action) Message {
	return Message{
		Text:     header + " " + why,
		Header:   header,
		Stripe:   StripeNeedsYou,
		Sections: append(append([]string{}, entries...), why),
		Context:  []string{"Nothing changes until you choose."},
		Actions:  actions,
	}
}

// quoteLines renders a proposal as a Slack blockquote.
//
// Per line, because Slack's quote marker applies to the line it starts and a
// multi-line prompt would otherwise leave its second sentence outside the quote
// it belongs to.
func quoteLines(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}
	lines := strings.Split(trimmed, "\n")
	for index, line := range lines {
		lines[index] = "> " + strings.TrimSpace(line)
	}
	return strings.Join(lines, "\n")
}

// joinFacts assembles a context line out of the parts a subject actually has,
// so an absent expiry or an unrecorded outcome leaves no dangling separator.
func joinFacts(parts []string) string {
	kept := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			kept = append(kept, trimmed)
		}
	}
	return strings.Join(kept, " · ")
}
