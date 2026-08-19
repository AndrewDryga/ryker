package slackui

import (
	"fmt"
	"time"
)

// TurnReceipt is what one finished turn did, and what it cost.
//
// Every number here is read back out of a record that outlives the turn — the
// run row, the activity ledger, and the turn Coop kept — rather than recomposed
// from the model's own account of itself. A turn that says "still working"
// twice and makes a hundred and nineteen tool calls has told the room nothing
// true; this is the answer that does not depend on the turn being a reliable
// narrator of its own work.
type TurnReceipt struct {
	// RunID is the run behind the turn, shown abbreviated as a footnote so a
	// receipt can be matched to a trace without becoming an identifier card.
	RunID string
	// Duration is how long the turn ran. Known separately from being nonzero,
	// because a run whose clocks were never stamped has no duration to state
	// and "0s" would be a claim rather than an absence.
	Duration      time.Duration
	DurationKnown bool
	// Moments is every activity Coop narrated for this turn, of every kind.
	// It is what tells a turn that did nothing apart from a turn whose work
	// was never narrated, and the two deserve different sentences.
	Moments   int
	ToolCalls int
	Files     int
	Evidence  int
	// TokensRecorded is false when nobody measured the turn. ACP does not
	// require an adapter to report usage, so absence is ordinary and has to
	// stay distinguishable from a turn that genuinely spent nothing.
	TokensRecorded  bool
	InputTokens     int
	CachedTokens    int
	OutputTokens    int
	ReasoningTokens int
	// CostRecorded is separate again: a provider can report tokens and price
	// nothing, and a zero rendered as money would invent a free turn.
	CostRecorded bool
	CostUSD      float64
}

// TurnReceiptMessage answers "what did that turn do?" and nothing else.
//
// Header-less: the question was asked in this thread a second ago and the
// answer does not need a title telling the asker what they asked. Grey, and
// with no controls, because a receipt is a statement about something that has
// already finished — there is nothing here to decide and nobody is waiting.
func TurnReceiptMessage(receipt TurnReceipt) Message {
	message := Message{
		Text:      turnReceiptFallback(receipt),
		Stripe:    StripeIdle,
		Ledger:    turnReceiptLedger(receipt),
		Temporary: true,
	}
	if receipt.Moments == 0 {
		// Rows of zeroes would read as a measurement; this is the absence of
		// one. Coop narrates tool calls and reasoning as they happen, so a turn
		// with no narrated moment either did nothing or was never watched, and
		// either way the honest card is a sentence rather than a table of
		// noughts.
		message.Sections = []string{
			"*This turn narrated nothing.* No tool call, file change, or reasoning " +
				"summary was recorded against it — the turn either did none of those " +
				"things or finished before Responder was watching it.",
		}
	}
	if source := turnReceiptSource(receipt); source != "" {
		message.Context = []string{source}
	}
	return message
}

func turnReceiptLedger(receipt TurnReceipt) []LedgerStep {
	var steps []LedgerStep
	row := func(label, value string) {
		// A blank glyph: these are label/value rows, and the ledger's default
		// bullet would present a receipt as a sequence of steps.
		steps = append(steps, LedgerStep{Glyph: " ", Label: label, When: value})
	}
	if receipt.DurationKnown {
		row("Duration", compactDuration(receipt.Duration))
	}
	if receipt.Moments > 0 {
		row("Tool calls", fmt.Sprintf("%d", receipt.ToolCalls))
		row("Files changed", fmt.Sprintf("%d", receipt.Files))
		row("Evidence", fmt.Sprintf("%d", receipt.Evidence))
	}
	if !receipt.TokensRecorded {
		row("Tokens", "not recorded")
		return steps
	}
	row("Tokens in", fmt.Sprintf("%d", receipt.InputTokens))
	if receipt.CachedTokens > 0 {
		row("Cached in", fmt.Sprintf("%d", receipt.CachedTokens))
	}
	row("Tokens out", fmt.Sprintf("%d", receipt.OutputTokens))
	row("Reasoning", fmt.Sprintf("%d", receipt.ReasoningTokens))
	if receipt.CostRecorded {
		row("Cost", turnReceiptCost(receipt.CostUSD))
	}
	return steps
}

func turnReceiptCost(cost float64) string {
	if cost < 1 {
		return fmt.Sprintf("$%.4f", cost)
	}
	return fmt.Sprintf("$%.2f", cost)
}

// turnReceiptSource names where the numbers came from, because a receipt whose
// provenance is unstated is indistinguishable from one the model wrote.
func turnReceiptSource(receipt TurnReceipt) string {
	if receipt.RunID == "" {
		return ""
	}
	return "Run `" + ShortID(receipt.RunID) + "`"
}

func turnReceiptFallback(receipt TurnReceipt) string {
	if receipt.Moments == 0 {
		return "That turn narrated no tool call, file change, or reasoning summary."
	}
	fallback := fmt.Sprintf(
		"That turn made %s and changed %s",
		countLabel(receipt.ToolCalls, "tool call"),
		countLabel(receipt.Files, "file"),
	)
	if receipt.DurationKnown {
		fallback += " in " + compactDuration(receipt.Duration)
	}
	return fallback + "."
}
