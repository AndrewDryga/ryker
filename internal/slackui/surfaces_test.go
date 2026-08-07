package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Slack rejects a payload whose blocks exceed its limits, and it does so at
// delivery — long after the code that built it, and in a way the agent cannot
// explain to the operator waiting for an answer. These bounds are what keep a
// long summary or verbose title from becoming an undeliverable message.
func TestOperatorSurfacesRespectBlockKitBounds(t *testing.T) {
	long := strings.Repeat("very long operator supplied text ", 200)
	future := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	task := core.ScheduledTask{
		ID: "task_1", Title: long, Recurrence: "daily", LocalTime: "09:00",
		Timezone: "UTC", Repository: "emisar", Enabled: true, NextRunAt: future,
	}

	surfaces := map[string]Message{
		"schedule saved":        ScheduleSavedMessage(task),
		"scheduled run started": ScheduledRunStartedMessage(task, future),
		"schedule state":        ScheduleStateMessage(task),
		"schedule deleted":      ScheduleDeletedMessage(),
		"preference state": PreferenceStateMessage(core.ResponderPreference{
			ID: "pref_1", Name: "health_check_depth", Value: long,
			ScopeKind: "channel", ScopeKey: "C1", ExpiresAt: future,
		}),
		"preference deleted": PreferenceDeletedMessage(),
		"rule state": RuleStateMessage(core.StandingRule{
			ID: "rule_1", Trigger: long, Action: "reply", Repository: "emisar",
		}),
		"rule deleted":           RuleDeletedMessage(),
		"memory forgotten":       MemoryForgottenMessage(),
		"rollup forgotten":       MemoryRollupForgottenMessage(),
		"memory review complete": MemoryReviewCompleteMessage("keep", 3),
		"memory review finished": MemoryReviewCompleteMessage("merge", 0),
	}

	// Every outgoing message passes through the sanitizer, which is where the
	// Block Kit bounds are applied, so that is the shape Slack actually sees.
	sanitizer := NewSanitizer(12000)
	for name, raw := range surfaces {
		message := sanitizer.Message(raw)
		if strings.TrimSpace(message.Text) == "" {
			t.Errorf("%s has no fallback text; Slack shows that in notifications", name)
		}
		if len(message.Header) > maxSlackHeaderBytes {
			t.Errorf("%s header is %d bytes, over Slack's %d limit",
				name, len(message.Header), maxSlackHeaderBytes)
		}
		for index, field := range message.Fields {
			if len(field.Value) > maxSlackFieldBytes {
				t.Errorf("%s field %d is %d bytes, over Slack's %d limit",
					name, index, len(field.Value), maxSlackFieldBytes)
			}
		}
		for index, section := range message.Sections {
			if len(section) > maxSlackSectionBytes {
				t.Errorf("%s section %d is %d bytes, over Slack's %d limit",
					name, index, len(section), maxSlackSectionBytes)
			}
		}
		for _, action := range message.Actions {
			if action.ID == "" {
				t.Errorf("%s has a button with no action ID, so it cannot be routed", name)
			}
			if len(action.Label) > maxSlackButtonBytes {
				t.Errorf("%s button %q has a %d byte label, over Slack's %d limit",
					name, action.ID, len(action.Label), maxSlackButtonBytes)
			}
		}
	}
}

// Every message crosses the delivery ledger as JSON, so it has to survive the
// round trip unchanged — and a message written by a different version must fail
// loudly rather than silently losing whatever this build does not understand.
func TestMessagesRoundTripThroughTheDeliveryLedger(t *testing.T) {
	original := Message{
		Text:     "a decision",
		Header:   "Emisar",
		Markdown: "*bold* and `code`",
		Sections: []string{"first", "second"},
		Fields:   []Field{{Label: "Repository", Value: "emisar"}},
		Context:  []string{"a footnote"},
		Actions: []Action{{
			ID: ActionViewPR, Label: "Open PR", Value: "inc_1",
			URL: "https://github.com/owner/name/pull/1", Style: "primary",
		}},
	}
	encoded, err := Encode(original)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := Decode(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Text != original.Text || restored.Header != original.Header ||
		restored.Markdown != original.Markdown ||
		len(restored.Sections) != 2 || len(restored.Fields) != 1 ||
		len(restored.Context) != 1 || len(restored.Actions) != 1 {
		t.Fatalf("round trip lost content: %+v", restored)
	}
	if restored.Actions[0].URL != original.Actions[0].URL {
		t.Fatalf("round trip lost a button URL: %+v", restored.Actions[0])
	}
	if _, err := Decode([]byte(`{"text":"x","unknown_field":1}`)); err == nil {
		t.Fatal("decoding accepted an unknown field")
	}
}

// Scope wording is the single most important thing on a guidance card: it tells
// the operator who the saved instruction will apply to. Getting it wrong means
// someone shares a personal preference with the workspace by accident.
func TestGuidanceScopeLabelsNameTheirAudience(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		offer    core.MemoryOffer
		expected string
	}{
		{
			"workspace-wide", core.MemoryOffer{Scope: "workspace", Visibility: "workspace"},
			"everyone",
		},
		{
			"private to the operator", core.MemoryOffer{Scope: "workspace", Visibility: "operator"},
			"only you",
		},
		{"channel", core.MemoryOffer{Scope: "channel", Visibility: "channel"}, "this channel"},
		{
			"repository", core.MemoryOffer{
				Scope: "repository", Visibility: "workspace", Repository: "emisar",
			},
			"emisar",
		},
		{
			"private repository", core.MemoryOffer{
				Scope: "repository", Visibility: "operator", Repository: "emisar",
			},
			"only you",
		},
	} {
		label := guidanceOfferScopeLabel(testCase.offer, "emisar")
		if !strings.Contains(strings.ToLower(label), testCase.expected) {
			t.Errorf("%s rendered as %q, which does not say %q",
				testCase.name, label, testCase.expected)
		}
	}
}

// A standing rule's trigger and a preference's value are operator text with no
// upstream length bound, so without the Block Kit limit applied here they can
// produce a card Slack refuses to deliver.
func TestUnboundedOperatorTextStaysDeliverable(t *testing.T) {
	sanitizer := NewSanitizer(12000)
	long := strings.Repeat("a very long standing rule trigger ", 300)

	rule := sanitizer.Message(RuleStateMessage(core.StandingRule{
		ID: "rule_1", Trigger: long, Action: "reply", Repository: "emisar",
	}))
	for index, section := range rule.Sections {
		if len(section) > maxSlackSectionBytes {
			t.Fatalf("rule section %d is %d bytes and Slack would reject the message",
				index, len(section))
		}
	}
	// Truncation must say so, or the operator reads a silently altered rule.
	joined := strings.Join(rule.Sections, "\n")
	if !strings.Contains(joined, "truncated") {
		t.Fatalf("the card was shortened without saying so:\n%s", joined)
	}
}
