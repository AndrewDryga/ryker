package slackui

import (
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
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
		RootTS: "1700.001", CoopSessionID: "ses_1", CoopForkName: "incident-api",
		CreatedAt: time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC),
		UpdatedAt: time.Date(2026, 7, 27, 1, 0, 0, 0, time.UTC),
	}
	card := IncidentCard(incident, "Infrastructure", []core.Signal{{
		Status: core.SignalFiring, Summary: "Checkout requests are timing out.",
		SourceURL: "https://grafana.example.test/alerting/1",
	}})
	if card.Header != "CRITICAL | "+incident.Title || len(card.Actions) != 3 {
		t.Fatalf("card = %+v", card)
	}
	if !strings.Contains(card.Text, "Severity critical") ||
		!strings.Contains(card.Text, "Responder Investigating") ||
		!strings.Contains(card.Text, "2 of 3 signals firing") {
		t.Fatalf("fallback omits incident state: %q", card.Text)
	}
	if len(card.Sections) != 2 || !strings.Contains(card.Sections[1], "Checkout requests") ||
		!slices.Contains(card.Context, "Alert source: <https://grafana.example.test/alerting/1|Open grafana.example.test>") {
		t.Fatalf("card omits alert evidence: %+v", card)
	}
	var actionBlocks int
	for _, action := range card.Actions {
		if action.ID == ActionUpdate || action.ID == ActionReview || action.ID == ActionResolve {
			t.Fatalf("active card exposes unavailable action: %+v", action)
		}
	}
	for _, block := range card.Blocks() {
		if actionBlock, ok := block.(*slack.ActionBlock); ok {
			actionBlocks++
			if len(actionBlock.Elements.ElementSet) > 4 {
				t.Fatalf("action row has %d elements", len(actionBlock.Elements.ElementSet))
			}
		}
	}
	if actionBlocks != 1 || card.Actions[0].ID != ActionStop ||
		card.Actions[0].Style != "danger" || card.Actions[0].Confirm == "" {
		t.Fatalf("card lacks compact safe stop action: %+v", card.Actions)
	}
}

func TestIncidentCardControlsFollowLifecycle(t *testing.T) {
	base := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed", Status: core.IncidentActive,
		RootTS: "1700.001", CoopSessionID: "ses_1", CoopForkName: "incident-api",
		UpdatedAt: time.Now(),
	}
	tests := []struct {
		name     string
		incident core.Incident
		want     []string
	}{
		{
			name: "provisioning",
			incident: core.Incident{
				ID: base.ID, Title: base.Title, Status: core.IncidentActive,
				Workflow: core.WorkflowProvisioningSession, RootTS: base.RootTS,
			},
			want: []string{ActionResolve},
		},
		{
			name: "active turn",
			incident: func() core.Incident {
				value := base
				value.Workflow = core.WorkflowInvestigating
				value.ActiveTurnID = "turn_1"
				return value
			}(),
			want: []string{ActionStop, ActionChanges, ActionExtend},
		},
		{
			name: "parked",
			incident: func() core.Incident {
				value := base
				value.Workflow = core.WorkflowParked
				return value
			}(),
			want: []string{ActionUpdate, ActionChanges, ActionReview, ActionResolve},
		},
		{
			name: "budget blocked",
			incident: func() core.Incident {
				value := base
				value.Workflow = core.WorkflowBlocked
				return value
			}(),
			want: []string{ActionExtend, ActionChanges, ActionReview, ActionResolve},
		},
		{
			name: "closed",
			incident: func() core.Incident {
				value := base
				value.Status = core.IncidentClosed
				value.Workflow = core.WorkflowClosed
				return value
			}(),
			want: []string{ActionChanges, ActionReview},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			card := IncidentCard(test.incident, "Repository", nil)
			got := make([]string, 0, len(card.Actions))
			for _, action := range card.Actions {
				got = append(got, action.ID)
			}
			if !slices.Equal(got, test.want) {
				t.Fatalf("actions = %v, want %v", got, test.want)
			}
		})
	}
}

func TestInitialIncidentCardHasNoControlsUntilRootIsBound(t *testing.T) {
	card := IncidentCard(core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed",
		Status: core.IncidentActive, Workflow: core.WorkflowProvisioningChannel,
		UpdatedAt: time.Now(),
	}, "Repository", nil)
	if len(card.Actions) != 0 {
		t.Fatalf("unbound root exposes stale controls: %+v", card.Actions)
	}
}

func TestIncidentCardFallbackIncludesActionableErrorAndRejectsUnsafeSource(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed <!channel>", Severity: "high",
		Status: core.IncidentActive, Workflow: core.WorkflowBlocked,
		FiringCount: 1, SignalCount: 1, LastError: "Turn budget exhausted; notify <@U123>.",
		UpdatedAt: time.Now(),
	}
	card := IncidentCard(incident, "Repository", []core.Signal{{
		Status: core.SignalFiring, Summary: "See <https://evil.example|details>.",
		SourceURL: "javascript:alert(1)",
	}})
	if !strings.Contains(card.Text, "Action needed: Turn budget exhausted") ||
		strings.Contains(card.Text, "<!channel>") || strings.Contains(card.Text, "<@U123>") ||
		len(card.Sections) < 3 || strings.Contains(card.Sections[2], "<https://evil.example") {
		t.Fatalf("fallback = %q", card.Text)
	}
	for _, context := range card.Context {
		if strings.Contains(context, "javascript:") {
			t.Fatalf("unsafe source rendered: %q", context)
		}
	}
}

func TestIncidentCardSourceLinkNamesHostAndDropsCredentials(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed", Status: core.IncidentActive,
		Workflow: core.WorkflowInvestigating, UpdatedAt: time.Now(),
	}
	card := IncidentCard(incident, "Repository", []core.Signal{{
		Status:    core.SignalFiring,
		SourceURL: "https://alerts.example.test/path/to/alert?token=super-secret&signature=abc#details",
	}})
	want := "Alert source: <https://alerts.example.test/path/to/alert|Open alerts.example.test>"
	if !slices.Contains(card.Context, want) {
		t.Fatalf("sanitized source link = %+v, want %q", card.Context, want)
	}
	for _, context := range card.Context {
		if strings.Contains(context, "super-secret") || strings.Contains(context, "signature=") {
			t.Fatalf("source credentials leaked into Slack: %q", context)
		}
	}
	concealed := IncidentCard(incident, "Repository", []core.Signal{{
		Status: core.SignalFiring, SourceURL: "https://trusted.example@evil.example/phish",
	}})
	for _, context := range concealed.Context {
		if strings.Contains(context, "evil.example") {
			t.Fatalf("credential-style concealed host rendered: %q", context)
		}
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
		!strings.Contains(message.Sections[len(message.Sections)-1], "truncated") ||
		message.Header != "Investigation update" ||
		!strings.HasPrefix(message.Text, "Investigation update:") {
		t.Fatalf("long response was not visibly bounded: %d sections", len(message.Sections))
	}
}

func TestTurnFailureAndManualHandoffPreserveTheNextStep(t *testing.T) {
	failure := TurnFailureMessage("failed", "MCP request timed out.")
	if failure.Header != "Investigation could not finish" ||
		!strings.Contains(strings.Join(failure.Sections, "\n"), "preserved") ||
		!strings.Contains(strings.Join(failure.Sections, "\n"), "continue") {
		t.Fatalf("failure message = %+v", failure)
	}
	handoff := ManualHandoff("C123INCIDENT")
	if handoff.Header != "Incident room ready" ||
		!strings.Contains(handoff.Text, "<#C123INCIDENT>") ||
		!strings.Contains(handoff.Sections[0], "<#C123INCIDENT>") {
		t.Fatalf("handoff = %+v", handoff)
	}
}
