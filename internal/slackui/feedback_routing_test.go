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

// The review section asks an operator to judge a lesson, not to triage an error.
//
// Someone opening App Home is being asked whether a correction is worth keeping
// as a test. Leading with the internal check that produced it would make that a
// debugging task, which is not what is being asked and not something most
// operators can answer.
func TestFixtureReviewAsksAboutTheLessonNotTheMachinery(t *testing.T) {
	message := AppendFixtureReview(Message{}, []FixtureCandidateSummary{
		{ID: "cand_1", Reason: "incomplete", Capability: "operational-health",
			Correction: "the reply claimed healthy without fresh evidence"},
	})
	content := strings.Join(message.Sections, "\n")

	if !strings.Contains(content, "told I got something wrong") {
		t.Errorf("review section does not frame this as a judgement:\n%s", content)
	}
	if !strings.Contains(content, "claimed healthy without fresh evidence") {
		t.Errorf("review section does not show what the correction said:\n%s", content)
	}
	// The internal class name is not what an operator is being asked about.
	if strings.Contains(content, "incomplete") {
		t.Errorf("review section leads with the internal check class:\n%s", content)
	}

	var keep, discard bool
	for _, action := range message.Actions {
		switch action.ID {
		case ActionKeepFixtureCandidate:
			keep = true
			if !strings.Contains(action.Confirm, "regression test") {
				t.Errorf("keep confirmation does not say what keeping does: %q", action.Confirm)
			}
		case ActionDiscardFixtureCandidate:
			discard = true
		}
	}
	if !keep || !discard {
		t.Fatalf("review offers keep=%t discard=%t; both are needed", keep, discard)
	}

	// Nothing to review means no section at all, not an empty heading.
	if empty := AppendFixtureReview(Message{}, nil); len(empty.Sections) != 0 {
		t.Errorf("an empty review queue still rendered a section: %+v", empty.Sections)
	}
}
