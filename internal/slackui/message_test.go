package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

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

func TestIncidentCardHasVisibleStateAndDeterministicControls(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API readiness failed", Severity: "critical",
		Status: core.IncidentActive, Workflow: core.WorkflowInvestigating,
		FiringCount: 2, SignalCount: 3, ActiveTurnID: "turn_1",
		UpdatedAt: time.Date(2026, 7, 27, 1, 0, 0, 0, time.UTC),
	}
	card := IncidentCard(incident, "Infrastructure")
	if card.Header != incident.Title || len(card.Actions) != 7 {
		t.Fatalf("card = %+v", card)
	}
	foundStop := false
	for _, action := range card.Actions {
		if action.ID == ActionStop {
			foundStop = action.Style == "danger" && action.Confirm != ""
		}
	}
	if !foundStop || len(card.Blocks()) == 0 {
		t.Fatal("card lacks safe stop action or blocks")
	}
}

func TestChannelNameIsSlackSafeAndDeterministic(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API / Checkout: 5xx above 20%",
		CreatedAt: time.Date(2026, 7, 27, 1, 0, 0, 0, time.UTC),
	}
	name := ChannelName("inc", incident)
	if name != ChannelName("inc", incident) || !strings.HasPrefix(name, "inc-0727-") {
		t.Fatalf("channel name is not deterministic: %q", name)
	}
	if len(name) > 80 || !strings.HasSuffix(name, "-1234567890") {
		t.Fatalf("channel name = %q", name)
	}
	for _, char := range name {
		if !(char >= 'a' && char <= 'z') && !(char >= '0' && char <= '9') && char != '-' && char != '_' {
			t.Fatalf("unsafe channel character %q in %q", char, name)
		}
	}
}

func TestLongAssistantResponseShowsTruncation(t *testing.T) {
	message := AssistantResponse(strings.Repeat("paragraph\n", 5000), NewSanitizer(30000))
	if len(message.Sections) != 5 ||
		!strings.Contains(message.Sections[len(message.Sections)-1], "truncated") {
		t.Fatalf("long response was not visibly bounded: %d sections", len(message.Sections))
	}
}
