package slackui

import (
	"strings"
	"testing"
)

// Redaction is one security-relevant unit: what it covers, what it must not
// mutate, and which URLs it will accept. Its tests live beside it so a change
// to any of the three has the other two in front of it.
func TestSanitizerRedactsSecretsMentionsANSIAndBounds(t *testing.T) {
	sanitizer := NewSanitizer(120, "super-secret-token")
	input := "\x1b[31mfailed\x1b[0m <@U123> <!channel> xoxb-1234567890-secret super-secret-token " + strings.Repeat("x", 200)
	got := sanitizer.Text(input)
	for _, forbidden := range []string{"\x1b", "xoxb-", "super-secret-token", "<@U123>", "<!channel>"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("sanitized output contains %q: %q", forbidden, got)
		}
	}
	if len(got) > 150 || !strings.Contains(got, "truncated") {
		t.Fatalf("bound output = %q (%d)", got, len(got))
	}
}

func TestSanitizerCoversEveryUntrustedMessageSurface(t *testing.T) {
	sanitizer := NewSanitizer(500, "super-secret-token")
	message := sanitizer.Message(Message{
		Text: "<!channel>", Header: "super-secret-token",
		Sections: []string{"<@U123>"}, Fields: []Field{{Label: "xoxb-1234567890-secret", Value: "\x1b[31mvalue"}},
		Context: []string{"<!here>"},
	})
	data, err := Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"<!channel>", "<@U123>", "<!here>", "super-secret-token", "xoxb-", "\x1b"} {
		if strings.Contains(string(data), forbidden) {
			t.Fatalf("message contains %q: %s", forbidden, data)
		}
	}
}

// Sanitizing a copy of a Message must not rewrite the caller's own slices.
func TestSanitizerDoesNotMutateCallerMessage(t *testing.T) {
	sanitizer := NewSanitizer(12000, "SUPERSECRETVALUE1")
	original := Message{
		Text:     "text SUPERSECRETVALUE1",
		Sections: []string{"section SUPERSECRETVALUE1"},
		Fields:   []Field{{Label: "label SUPERSECRETVALUE1", Value: "value SUPERSECRETVALUE1"}},
		Context:  []string{"context SUPERSECRETVALUE1"},
		Actions:  []Action{{Label: "label SUPERSECRETVALUE1", Confirm: "confirm SUPERSECRETVALUE1"}},
	}
	cleaned := sanitizer.Message(original)

	if !strings.Contains(original.Sections[0], "SUPERSECRETVALUE1") ||
		!strings.Contains(original.Fields[0].Value, "SUPERSECRETVALUE1") ||
		!strings.Contains(original.Context[0], "SUPERSECRETVALUE1") ||
		!strings.Contains(original.Actions[0].Label, "SUPERSECRETVALUE1") {
		t.Fatalf("sanitizing mutated the caller's message: %+v", original)
	}
	for _, value := range []string{
		cleaned.Text, cleaned.Sections[0], cleaned.Fields[0].Label,
		cleaned.Fields[0].Value, cleaned.Context[0],
		cleaned.Actions[0].Label, cleaned.Actions[0].Confirm,
	} {
		if strings.Contains(value, "SUPERSECRETVALUE1") {
			t.Fatalf("sanitized copy still carries the secret: %q", value)
		}
	}
}

// A button URL must be an ordinary web link; Slack renders it directly.
// A button URL must be an ordinary web link; Slack renders it directly.
func TestSanitizerDropsNonHTTPSActionURL(t *testing.T) {
	sanitizer := NewSanitizer(12000)
	cleaned := sanitizer.Message(Message{Actions: []Action{
		{Label: "ok", URL: "https://emisar.example.com/approvals/req_1"},
		{Label: "bad", URL: "javascript:alert(1)"},
		{Label: "also bad", URL: "http://insecure.example.com"},
	}})
	if cleaned.Actions[0].URL != "https://emisar.example.com/approvals/req_1" {
		t.Fatalf("https URL was dropped: %q", cleaned.Actions[0].URL)
	}
	if cleaned.Actions[1].URL != "" || cleaned.Actions[2].URL != "" {
		t.Fatalf("unsafe URLs survived: %+v", cleaned.Actions)
	}
}
