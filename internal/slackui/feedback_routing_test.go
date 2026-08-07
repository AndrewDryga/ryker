package slackui

import (
	"strings"
	"testing"
)

// Only tone feedback gets the typed-preference button.
//
// Guidance is advisory — the model weighs it and may reasonably set it aside.
// A preference is enforced by the host. response_detail is the one typed
// preference that tone feedback can actually express, so it is the one category
// that gets the stronger option; offering it everywhere would promise
// enforcement the host cannot deliver.
func TestOnlyToneFeedbackOffersATypedPreference(t *testing.T) {
	for _, testCase := range []struct {
		category string
		expect   bool
	}{
		{"tone", true},
		{"correctness", false},
		{"latency", false},
		{"feature_request", false},
		{"other", false},
	} {
		t.Run(testCase.category, func(t *testing.T) {
			message := AppendFeedbackDigest(Message{}, []FeedbackSummary{
				{ID: "fb_1", Category: testCase.category, Sentiment: "suggestion",
					Summary: "replies are long"},
			})
			var offered bool
			for _, action := range message.Actions {
				if action.ID == ActionConvertFeedbackBrief {
					offered = true
				}
			}
			if offered != testCase.expect {
				t.Fatalf("typed preference offered = %t for category %q, want %t",
					offered, testCase.category, testCase.expect)
			}
		})
	}
}

// The button says which direction it sets, and the confirmation says it is
// enforced rather than advisory.
//
// The direction is fixed by the button rather than read out of the feedback
// text on purpose: "be more concise" and "that was too terse" are both tone,
// and inferring between them from prose is how an agent ends up confidently
// doing the opposite of what was asked.
func TestTypedPreferenceButtonStatesDirectionAndEnforcement(t *testing.T) {
	message := AppendFeedbackDigest(Message{}, []FeedbackSummary{
		{ID: "fb_1", Category: "tone", Sentiment: "suggestion", Summary: "too long"},
	})
	for _, action := range message.Actions {
		if action.ID != ActionConvertFeedbackBrief {
			continue
		}
		if !strings.Contains(strings.ToLower(action.Label), "brief") {
			t.Errorf("button label does not say which way it sets things: %q", action.Label)
		}
		if !strings.Contains(action.Confirm, "enforced") {
			t.Errorf("confirmation does not distinguish enforcement from a hint: %q", action.Confirm)
		}
		if action.Value != "fb_1" {
			t.Errorf("action value = %q, want the feedback id", action.Value)
		}
		return
	}
	t.Fatal("tone feedback offered no typed preference button")
}
