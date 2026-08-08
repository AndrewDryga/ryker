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
