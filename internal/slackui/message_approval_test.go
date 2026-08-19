package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Every approval state ships a colour, a glyph and a word, and they agree.
//
// Three readers, three channels: the stripe is invisible in a notification, the
// glyph is stripped by the sidebar, and neither survives a screen reader. A
// table rather than a case per status because the failure this guards against
// is drift — one status gaining a colour without a word, which is invisible in
// review and total for whoever reads it in the wrong place.
func TestEmisarApprovalStatesAgreeOnColourGlyphAndWord(t *testing.T) {
	for _, testCase := range []struct {
		status, stripe, glyph, word string
	}{
		// Waiting is the default, and it is the only state where a person owes
		// something. An unrecognised status is treated as waiting rather than
		// as done: the safe reading of "I do not know" is "somebody look".
		{"", StripeNeedsYou, "✋", "Needs you"},
		{"pending_approval", StripeNeedsYou, "✋", "Needs you"},
		{"awaiting_operator", StripeNeedsYou, "✋", "Needs you"},
		{"pending", StripeWorking, "⚙️", "Working"},
		{"sent", StripeWorking, "⚙️", "Working"},
		{"running", StripeWorking, "⚙️", "Working"},
		{"cancelling", StripeWorking, "⚙️", "Working"},
		{"success", StripeDone, "✅", "Done"},
		// Grey, not red. An operator declining a change is the control working.
		{"denied", StripeIdle, "⏸", "Not approved"},
		{"cancelled", StripeIdle, "⏸", "Cancelled"},
		{"failed", StripeFailed, "🛑", "Failed"},
		{"error", StripeFailed, "🛑", "Failed"},
		{"validation_failed", StripeFailed, "🛑", "Failed"},
		{"unknown_action", StripeFailed, "🛑", "Failed"},
		{"timed_out", StripeFailed, "🛑", "Failed"},
		{"refused", StripeFailed, "🛑", "Failed"},
	} {
		t.Run(displayOr(testCase.status, "unset"), func(t *testing.T) {
			message := EmisarApprovalStateMessage(core.EmisarApproval{
				RequestID: "apr_1", RunID: "run_1", ActionID: "service.enable",
				RunnerRef: "prod~abc", Status: testCase.status,
				RunURL: "https://emisar.example/runs/run_1",
			}, false)
			if message.Stripe != testCase.stripe {
				t.Errorf("stripe = %q, want %q", message.Stripe, testCase.stripe)
			}
			if !strings.HasPrefix(message.Header, testCase.glyph+" ") {
				t.Errorf("header = %q, want the %q glyph", message.Header, testCase.glyph)
			}
			// The fallback leads with the word, because that line is the whole
			// message in a notification and in the channel list.
			if !strings.HasPrefix(message.Text, testCase.word+" — ") {
				t.Errorf("fallback = %q, want it to lead with %q", message.Text, testCase.word)
			}
			// One primary at most, and only where a person owes something.
			for _, action := range cardActions(message) {
				if action.Style == "primary" && testCase.stripe != StripeNeedsYou {
					t.Errorf("terminal or running card offers a primary button: %+v", action)
				}
				if !routedActionIDs[action.ID] {
					t.Errorf("action %q has no handler in internal/service", action.ID)
				}
			}
		})
	}
}

// A denied approval is reported, not editorialised.
//
// The card says what is true and continues without the declined action. It does
// not grade the decision or ask for it again. This is the one state where the
// temptation to argue is real, and the copy is the guard against it.
func TestDeniedApprovalStaysAcceptingAndStatesWhatHappensNext(t *testing.T) {
	message := EmisarApprovalStateMessage(core.EmisarApproval{
		RequestID: "apr_1", RunID: "run_1", ActionID: "nomad.alloc_restart",
		RunnerRef: "prod~abc", Status: "denied",
		ApprovalURL: "https://emisar.example/approvals/apr_1",
	}, false)
	content := cardText(message)
	if !strings.Contains(content, "was denied and did not run") ||
		!strings.Contains(content, "continue without this action") {
		t.Fatalf("denied approval lost the next step: %q", content)
	}
	for _, forbidden := range []string{"unfortunate", "should", "try again", "reconsider"} {
		if strings.Contains(strings.ToLower(content), forbidden) {
			t.Fatalf("denied approval editorialised with %q: %q", forbidden, content)
		}
	}
	if message.Stripe != StripeIdle {
		t.Fatalf("a denied approval is not an error: stripe = %q", message.Stripe)
	}
}

// The blast-radius strip shows recorded fields and invents nothing.
//
// The design asked for five rows — action, target and count, change, runner and
// pack, policy. core.EmisarApproval records three of those things. The other
// two could only have come from parsing the action's name or from the model's
// sentence about it, and a strip an operator approves a production change from
// is the last place in the system that should be guessing.
func TestApprovalBlastRadiusRendersOnlyRecordedFields(t *testing.T) {
	message := WithEmisarApproval(
		ConversationResponse("Emisar paused the restart.", NewSanitizer(12000)),
		core.EmisarApproval{
			RequestID: "apr_1", RunID: "run_1",
			// Hostile on purpose: a credential shape, a broadcast mention and a
			// newline that would take the strip's column alignment with it.
			ActionID:  "nomad.alloc_restart\n<!channel> xoxb-0123456789abcdefghij",
			RunnerRef: "prod-1~abc123",
			// A real pack ref carries a 64-character digest.
			PackRef:     "victoriametrics@0.1.7/sha256:" + strings.Repeat("2c", 32),
			ApprovalURL: "https://emisar.example/approvals/apr_1",
			ExpiresAt:   time.Date(2026, 7, 28, 6, 30, 0, 0, time.UTC),
		},
	)
	if len(message.Ledger) != 3 {
		t.Fatalf("blast radius rows = %+v", message.Ledger)
	}
	for index, want := range []string{"action", "runner", "pack"} {
		if message.Ledger[index].Label != want {
			t.Fatalf("row %d = %q, want %q", index, message.Ledger[index].Label, want)
		}
		// Empty glyph: these are facts, not steps, and nothing here has a
		// position or a state to mark.
		if message.Ledger[index].Glyph != "" {
			t.Fatalf("row %d claims a state: %+v", index, message.Ledger[index])
		}
	}
	strip := ledgerText(message.Ledger)
	if strings.Contains(strip, "xoxb-") || strings.Contains(strip, "\n<!channel>") ||
		!strings.Contains(strip, "[REDACTED]") {
		t.Fatalf("blast radius carried a credential or a broadcast: %q", strip)
	}
	if strings.Contains(strip, "sha256") ||
		!strings.Contains(strip, "victoriametrics@0.1.7") {
		t.Fatalf("pack digest survived into the strip: %q", strip)
	}
	// No invented rows. These are the three the design asked for that the
	// record cannot supply; if a future field makes one of them real it should
	// arrive with its own test rather than through this one going quiet.
	for _, absent := range []string{"target", "change", "policy"} {
		if strings.Contains(strip, absent) {
			t.Fatalf("blast radius invented a %q row: %q", absent, strip)
		}
	}
	// Delivery neuters the broadcast form even though the strip is rich text
	// that Slack never parses as mrkdwn — belt and braces, because the strip is
	// the one block on this card built from a field Emisar filled in.
	sanitized := NewSanitizer(12000).Message(message)
	if strings.Contains(ledgerText(sanitized.Ledger), "<!channel>") {
		t.Fatalf("sanitizer left a broadcast in the strip: %q", ledgerText(sanitized.Ledger))
	}
}

// The expiry is a date token, and there is no countdown anywhere.
//
// A countdown needs the time at which it is read, and this card is composed
// once and never refreshed — "expires in 1h 59m" would be accurate for one
// second and then wrong for the hour it mattered most.
func TestApprovalExpiryIsClientLocalAndNotACountdown(t *testing.T) {
	message := WithEmisarApproval(Message{Text: "reply"}, core.EmisarApproval{
		RequestID: "apr_1", RunID: "run_1", ActionID: "service.enable",
		ApprovalURL: "https://emisar.example/approvals/apr_1",
		ExpiresAt:   time.Now().Add(2 * time.Hour),
	})
	context := strings.Join(message.Context, "\n")
	if !strings.Contains(context, "expires <!date^") {
		t.Fatalf("approval expiry is not client-local: %q", context)
	}
	for _, countdown := range []string{"expires in", "1h 59m", "remaining"} {
		if strings.Contains(cardText(message), countdown) {
			t.Fatalf("approval card carries a countdown that will go stale: %q", countdown)
		}
	}
	// A request with no recorded expiry says nothing rather than 1970.
	noExpiry := WithEmisarApproval(Message{Text: "reply"}, core.EmisarApproval{
		RequestID: "apr_2", RunID: "run_2", ActionID: "service.enable",
	})
	if strings.Contains(strings.Join(noExpiry.Context, "\n"), "expires") {
		t.Fatalf("unset expiry rendered anyway: %+v", noExpiry.Context)
	}
}

// The decorator adds to the reply; it never speaks over it.
//
// The reply is the agent's account of why it wants this action, and it is the
// one sentence on the card this package could not have written. An approval
// that replaced it would leave an operator approving a change whose reason had
// just been deleted.
func TestApprovalDecoratorKeepsTheReplyItDecorates(t *testing.T) {
	reply := ConversationResponse(
		"I want to restart the stuck allocation; it will not fix the memory growth.",
		NewSanitizer(12000),
	)
	message := WithEmisarApproval(reply, core.EmisarApproval{
		RequestID: "apr_1", RunID: "run_1", ActionID: "nomad.alloc_restart",
		ApprovalURL: "https://emisar.example/approvals/apr_1",
	})
	if message.Markdown != reply.Markdown {
		t.Fatalf("approval clobbered the reply: %q", message.Markdown)
	}
	// One section from this decorator, where there used to be three.
	if len(message.Sections) != len(reply.Sections)+1 {
		t.Fatalf("approval added %d sections: %+v", len(message.Sections)-len(reply.Sections), message.Sections)
	}
	for _, action := range cardActions(message) {
		if !routedActionIDs[action.ID] {
			t.Fatalf("approval card offers an unrouted control: %+v", action)
		}
	}
}
