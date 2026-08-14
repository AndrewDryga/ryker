package slackui

import (
	"strings"
	"testing"
	"time"
)

// receiptRow reads one label/value row back out of the rendered strip.
func receiptRow(t *testing.T, message Message, label string) (string, bool) {
	t.Helper()
	for _, line := range ledgerLines(message.Ledger, 0) {
		fields := strings.Fields(line)
		if len(fields) < 2 || !strings.HasPrefix(strings.TrimSpace(line), label) {
			continue
		}
		return fields[len(fields)-1], true
	}
	return "", false
}

// A receipt states what a turn did, and states what nobody measured as
// unmeasured.
//
// The cost row is the one that has to be earned. ACP does not require an
// adapter to report usage, so a turn arriving with no numbers is ordinary — and
// rendering that as "$0.0000" would invent a free turn out of an absent
// measurement. Absence and zero are different answers and the card has to be
// able to say both.
func TestTurnReceiptSaysWhatWasMeasuredAndWhatWasNot(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		receipt  TurnReceipt
		wantRows map[string]string
		absent   []string
		contains []string
	}{{
		name: "a measured turn shows its tokens and its price",
		receipt: TurnReceipt{
			RunID: "run_663b998e06", Duration: 4 * time.Minute, DurationKnown: true,
			Moments: 22, ToolCalls: 19, Files: 3, Evidence: 2,
			TokensRecorded: true, InputTokens: 18204, OutputTokens: 2140,
			ReasoningTokens: 6300, CostRecorded: true, CostUSD: 0.4213,
		},
		wantRows: map[string]string{
			"Duration": "4m", "Tool calls": "19", "Files changed": "3",
			"Evidence": "2", "Tokens in": "18204", "Tokens out": "2140",
			"Reasoning": "6300", "Cost": "$0.4213",
		},
		absent: []string{"Cached in"},
	}, {
		name: "an unmeasured turn says so instead of pricing it at nothing",
		receipt: TurnReceipt{
			RunID: "run_abc", Duration: 90 * time.Second, DurationKnown: true,
			Moments: 4, ToolCalls: 3, Files: 0, Evidence: 0,
		},
		wantRows: map[string]string{
			"Duration": "1m", "Tool calls": "3", "Tokens": "recorded",
		},
		absent: []string{"Cost", "Tokens in", "Reasoning"},
	}, {
		name: "tokens measured, price not",
		receipt: TurnReceipt{
			RunID: "run_abc", Moments: 2, ToolCalls: 2, TokensRecorded: true,
			InputTokens: 900, CachedTokens: 400, OutputTokens: 40,
		},
		wantRows: map[string]string{
			"Tokens in": "900", "Cached in": "400", "Reasoning": "0",
		},
		absent: []string{"Cost", "Duration"},
	}, {
		name: "a turn that narrated nothing says that in words",
		receipt: TurnReceipt{
			RunID: "run_quiet", Duration: 3 * time.Second, DurationKnown: true,
		},
		wantRows: map[string]string{"Duration": "3s"},
		absent:   []string{"Tool calls", "Files changed", "Evidence"},
		contains: []string{"narrated nothing"},
	}} {
		t.Run(testCase.name, func(t *testing.T) {
			message := TurnReceiptMessage(testCase.receipt)
			for label, want := range testCase.wantRows {
				value, ok := receiptRow(t, message, label)
				if !ok {
					t.Fatalf("no %q row in %v", label, ledgerLines(message.Ledger, 0))
				}
				if !strings.Contains(value, want) {
					t.Fatalf("%s = %q, want %q", label, value, want)
				}
			}
			for _, label := range testCase.absent {
				if value, ok := receiptRow(t, message, label); ok {
					t.Fatalf("%q was reported as %q, and nothing measured it", label, value)
				}
			}
			rendered := strings.Join(append(
				append([]string{message.Text}, message.Sections...), message.Context...,
			), "\n")
			for _, want := range testCase.contains {
				if !strings.Contains(rendered, want) {
					t.Fatalf("receipt %q is missing %q", rendered, want)
				}
			}
		})
	}
}

// A turn that narrated nothing gets a sentence, not a table of noughts.
//
// Coop narrates tool calls and reasoning as they happen, so no narrated moment
// means the turn either did none of those things or finished before anything
// was watching it. Rows of zeroes would present that absence as a measurement,
// and "0 tool calls" reads as a fact about the work rather than about the
// record of it.
func TestTurnReceiptWithNoActivityExplainsItselfRatherThanRenderingZeroes(t *testing.T) {
	message := TurnReceiptMessage(TurnReceipt{RunID: "run_quiet"})
	if len(message.Sections) != 1 ||
		!strings.Contains(message.Sections[0], "No tool call, file change, or reasoning summary") {
		t.Fatalf("silent turn = %+v", message.Sections)
	}
	for _, label := range []string{"Tool calls", "Files changed", "Evidence"} {
		if _, ok := receiptRow(t, message, label); ok {
			t.Fatalf("a turn with no record still rendered a %q count", label)
		}
	}
	if !strings.Contains(message.Text, "narrated no tool call") {
		t.Fatalf("fallback = %q", message.Text)
	}
}

// A receipt is a statement about work that already stopped: nothing to decide,
// nobody waiting, no header telling the asker what they just asked.
func TestTurnReceiptIsAHeaderlessStatementWithNoControls(t *testing.T) {
	message := TurnReceiptMessage(TurnReceipt{
		RunID: "run_663b998e06be99f11d21fcdc44e3c9da", Moments: 3, ToolCalls: 3,
	})
	if message.Header != "" {
		t.Fatalf("header = %q, want none", message.Header)
	}
	if message.Stripe != StripeIdle {
		t.Fatalf("stripe = %q, want the informational grey", message.Stripe)
	}
	if len(message.Actions) != 0 || len(message.Overflow) != 0 {
		t.Fatalf("controls = %+v / %+v", message.Actions, message.Overflow)
	}
	// Provenance, because a receipt whose source is unstated is
	// indistinguishable from one the model wrote about itself.
	if len(message.Context) != 1 ||
		!strings.HasPrefix(message.Context[0], "from the durable turn record · ") {
		t.Fatalf("context = %v", message.Context)
	}
	// The run id is a footnote, abbreviated: it is here to match a receipt to a
	// trace, not to be read.
	if strings.Contains(message.Context[0], "run_663b998e06be99f11d21fcdc44e3c9da") {
		t.Fatalf("the whole run id is on the card: %q", message.Context[0])
	}
}

// A dear turn prices in dollars and cents; a cheap one keeps the digits that
// distinguish it from free.
func TestTurnReceiptCostKeepsTheDigitsThatMatter(t *testing.T) {
	if got := turnReceiptCost(0.0004); got != "$0.0004" {
		t.Fatalf("small cost = %q", got)
	}
	if got := turnReceiptCost(12.4); got != "$12.40" {
		t.Fatalf("large cost = %q", got)
	}
}
