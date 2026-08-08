package slackui

import (
	"encoding/json"
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
	message := Message{
		Text:     "list",
		Sections: []string{"*Corrections worth keeping?*"},
		Rows: []Row{
			{Text: "first correction", Actions: []Action{
				{ID: ActionKeepFixtureCandidate, Label: "Keep", Value: "a"},
				{ID: ActionDiscardFixtureCandidate, Label: "Discard", Value: "a"},
			}},
			{Text: "second correction", Actions: []Action{
				{ID: ActionKeepFixtureCandidate, Label: "Keep", Value: "b"},
				{ID: ActionDiscardFixtureCandidate, Label: "Discard", Value: "b"},
			}},
		},
	}

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
