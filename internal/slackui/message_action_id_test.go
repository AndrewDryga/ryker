package slackui

import (
	"encoding/json"
	"strings"
	"testing"
)

// Slack rejects a whole surface when two elements in one block share an
// action_id, and a list UI repeats an action by nature: five corrections mean
// five identical "Keep" buttons. views.publish answered invalid_arguments and
// Slack showed its default "still a work in progress" tab, so the App Home was
// blank for two days with fifteen corrections waiting behind it — the tab is
// the only place they can be reviewed, and nothing else reported the failure.
func TestRepeatedActionsGetDistinctIDs(t *testing.T) {
	message := Message{Text: "corrections"}
	for range 5 {
		message.Actions = append(message.Actions,
			Action{ID: ActionKeepFixtureCandidate, Label: "Keep", Value: "fixcand_1"},
			Action{ID: ActionDiscardFixtureCandidate, Label: "Discard", Value: "fixcand_1"},
		)
	}

	seen := map[string]int{}
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Type     string `json:"type"`
			Elements []struct {
				ActionID string `json:"action_id"`
			} `json:"elements"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			t.Fatal(err)
		}
		if probe.Type != "actions" {
			continue
		}
		// Slack scopes the requirement to a block, but a view is rejected for
		// repeats across blocks too, so this asserts uniqueness over the surface.
		for _, element := range probe.Elements {
			seen[element.ActionID]++
			if seen[element.ActionID] > 1 {
				t.Errorf("action_id %q appears more than once in the surface", element.ActionID)
			}
		}
	}
	if len(seen) != 10 {
		t.Fatalf("expected 10 distinct action ids, got %d", len(seen))
	}
}

// The suffix is presentation. Routing has to see the action a button stands
// for, or every copy after the first would fall through to no handler — which
// is a worse failure than the one being fixed, because the button would render
// and then do nothing.
func TestBaseActionIDRecoversTheRoute(t *testing.T) {
	for _, testCase := range []struct{ in, want string }{
		{ActionKeepFixtureCandidate, ActionKeepFixtureCandidate},
		{ActionKeepFixtureCandidate + ActionInstanceSeparator + "2", ActionKeepFixtureCandidate},
		{ActionKeepFixtureCandidate + ActionInstanceSeparator + "10", ActionKeepFixtureCandidate},
		// Not a suffix this code wrote: leave it alone rather than guess.
		{"responder_setup_repository_" + ActionInstanceSeparator + "x", "responder_setup_repository_" + ActionInstanceSeparator + "x"},
		{ActionInstanceSeparator + "3", ActionInstanceSeparator + "3"},
		{"", ""},
	} {
		if got := BaseActionID(testCase.in); got != testCase.want {
			t.Errorf("BaseActionID(%q) = %q, want %q", testCase.in, got, testCase.want)
		}
	}
}

// An overflow option value is a routing key, and the only one there is: Slack
// reports the menu's shared action_id and the chosen value, and nothing that
// says which option object produced it.
func TestOverflowOptionValueRoundTrips(t *testing.T) {
	for _, testCase := range []struct{ id, value string }{
		{ActionUpdate, "inc_01ce33abd2000000"},
		// A value that carries the separator itself still splits at the
		// boundary the encoder wrote, because the id side cannot contain one.
		{ActionPublishPR, PublicationActionValue("inc_01ce33abd2000000", 3)},
		{ActionToggleSchedule, `{"id":"schedule_1","enabled":false}`},
		{ActionHelp, ""},
	} {
		encoded := OverflowOptionValue(Action{ID: testCase.id, Value: testCase.value})
		id, value, ok := DecodeOverflowOptionValue(encoded)
		if !ok || id != testCase.id || value != testCase.value {
			t.Errorf("round trip of %q/%q = %q/%q/%t",
				testCase.id, testCase.value, id, value, ok)
		}
	}
	// Nothing this renderer wrote. There is no id to recover and no honest
	// guess to make, so it reports failure and the socket drops the click.
	for _, malformed := range []string{
		"", "inc_01ce33abd2000000", "~opt~inc_01ce33abd2000000",
		"responder_update~opt", "responder-update",
	} {
		if id, value, ok := DecodeOverflowOptionValue(malformed); ok {
			t.Errorf("DecodeOverflowOptionValue(%q) = %q/%q/true, want a refusal",
				malformed, id, value)
		}
	}
}

// The ask toggle's value carries which view the click asks for, and it has to
// survive being nested inside an overflow option — the same control appears as
// a row button and as a ⋯ choice, and the two must decode to the same thing.
func TestFullRequestActionValueRoundTrips(t *testing.T) {
	const task = "inc_01ce33abd2000000"

	for _, expanded := range []bool{false, true} {
		encoded := FullRequestActionValue(task, expanded)
		id, view, ok := DecodeFullRequestActionValue(encoded)
		if !ok || id != task || view != expanded {
			t.Errorf("round trip of expanded=%t = %q/%t/%t", expanded, id, view, ok)
		}
		// Through the ⋯ as well.
		wrapped := OverflowOptionValue(Action{ID: ActionFullRequest, Value: encoded})
		actionID, value, decoded := DecodeOverflowOptionValue(wrapped)
		if !decoded || actionID != ActionFullRequest {
			t.Fatalf("overflow round trip = %q/%q/%t", actionID, value, decoded)
		}
		if id, view, ok = DecodeFullRequestActionValue(value); !ok || id != task ||
			view != expanded {
			t.Errorf("nested round trip of expanded=%t = %q/%t/%t", expanded, id, view, ok)
		}
		// Slack refuses an option value over 150 characters, and this one is
		// nested inside another codec, so its length is worth stating.
		if len(wrapped) > overflowOptionValueLimit {
			t.Errorf("the nested toggle value is %d characters", len(wrapped))
		}
	}

	// A value written before the toggle existed is a bare incident id, and it
	// means the view it always meant rather than a refusal.
	if id, view, ok := DecodeFullRequestActionValue(task); !ok || id != task || view {
		t.Errorf("legacy value = %q/%t/%t", id, view, ok)
	}
	// Nothing to route: no incident named, either way round.
	for _, malformed := range []string{"", fullRequestExpandedSuffix} {
		if id, view, ok := DecodeFullRequestActionValue(malformed); ok {
			t.Errorf("DecodeFullRequestActionValue(%q) = %q/%t/true, want a refusal",
				malformed, id, view)
		}
	}
}

// Slack rejects an option value over 150 characters and rejects the message
// carrying it. The option is dropped rather than cut: a truncated routing key
// still decodes to a real action, and would fire it at a target that has had
// its tail removed — the right control against the wrong incident.
func TestOversizedOverflowOptionIsDroppedRatherThanTruncated(t *testing.T) {
	fits := Action{ID: ActionUpdate, Label: "Ask for an update", Value: "inc_1"}
	oversized := Action{
		ID:    ActionChangesNext,
		Label: "Next page",
		Value: strings.Repeat("c", overflowOptionValueLimit),
	}
	message := Message{Text: "receipt", Overflow: []Action{fits, oversized}}

	options := renderedOverflowOptions(t, message)
	if len(options) != 1 {
		t.Fatalf("overflow rendered %d options, want the oversized one dropped: %v",
			len(options), options)
	}
	if options[0] != OverflowOptionValue(fits) {
		t.Fatalf("surviving option = %q", options[0])
	}
	// Exactly at the limit is inside it, and the ⋯ still renders when every
	// option is dropped only because there is nothing left to render.
	atLimit := oversized
	atLimit.Value = strings.Repeat(
		"c", overflowOptionValueLimit-len(ActionChangesNext)-len(overflowOptionSeparator),
	)
	if got := renderedOverflowOptions(t, Message{
		Text: "receipt", Overflow: []Action{atLimit},
	}); len(got) != 1 || len(got[0]) != overflowOptionValueLimit {
		t.Fatalf("option at exactly the limit = %v", got)
	}
	if got := renderedOverflowOptions(t, Message{
		Text: "receipt", Overflow: []Action{oversized},
	}); len(got) != 0 {
		t.Fatalf("menu with only an oversized option rendered %v", got)
	}
}

// Slack allows ten fields per section and rejects the entire view over it. The
// App Home dashboard carries a dozen counters, so every view it built was
// invalid and the tab showed Slack's default placeholder instead. The error was
// "invalid_arguments" and nothing else until the response metadata was read:
// "no more than 10 items allowed [json-pointer:/view/blocks/13/fields]".
func TestSectionFieldsAreChunkedToSlacksLimit(t *testing.T) {
	message := Message{Text: "dashboard"}
	for index := range 23 {
		message.Fields = append(message.Fields, Field{
			Label: "Metric", Value: string(rune('a' + index%26)),
		})
	}

	total := 0
	sections := 0
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Type   string `json:"type"`
			Fields []struct {
				Text string `json:"text"`
			} `json:"fields"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			t.Fatal(err)
		}
		if probe.Type != "section" || len(probe.Fields) == 0 {
			continue
		}
		sections++
		total += len(probe.Fields)
		if len(probe.Fields) > 10 {
			t.Errorf("section carries %d fields, over Slack's limit of 10", len(probe.Fields))
		}
	}
	// Chunked, not truncated: a dropped counter would be a silent failure
	// replacing a loud one.
	if total != 23 {
		t.Errorf("rendered %d of 23 fields; the rest were dropped", total)
	}
	if sections != 3 {
		t.Errorf("expected 3 field sections for 23 fields, got %d", sections)
	}
}

// Buttons belong to the item they act on. When Sections and Actions were
// parallel lists, a list of five corrections rendered five sections and then
// nineteen buttons in one pile at the bottom — "Keep 1" through "Discard 5"
// mixed in with preference and rule controls, none of them next to what they
// referred to. The operator could not tell which button was which.
func TestRowActionsRenderBesideTheirRow(t *testing.T) {
	// AppendRow records the position, so rows land under the heading they
	// belong to instead of after every section on the surface.
	message := Message{Text: "list", Sections: []string{"*Corrections worth keeping?*"}}
	message = AppendRow(message, "first correction", []Action{
		{ID: ActionKeepFixtureCandidate, Label: "Keep", Value: "a"},
		{ID: ActionDiscardFixtureCandidate, Label: "Discard", Value: "a"},
	})
	message = AppendRow(message, "second correction", []Action{
		{ID: ActionKeepFixtureCandidate, Label: "Keep", Value: "b"},
		{ID: ActionDiscardFixtureCandidate, Label: "Discard", Value: "b"},
	})

	var order []string
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Type string `json:"type"`
			Text struct {
				Text string `json:"text"`
			} `json:"text"`
			Elements []struct {
				Value string `json:"value"`
			} `json:"elements"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			t.Fatal(err)
		}
		switch probe.Type {
		case "section":
			order = append(order, "section:"+probe.Text.Text)
		case "actions":
			values := ""
			for _, element := range probe.Elements {
				values += element.Value
			}
			order = append(order, "actions:"+values)
		}
	}

	// Each row's buttons immediately follow its text, and carry that row's id.
	want := []string{
		"section:*Corrections worth keeping?*",
		"section:first correction",
		"actions:aa",
		"section:second correction",
		"actions:bb",
	}
	if len(order) != len(want) {
		t.Fatalf("block order = %v, want %v", order, want)
	}
	for index := range want {
		if order[index] != want[index] {
			t.Fatalf("block order = %v, want %v", order, want)
		}
	}
}
