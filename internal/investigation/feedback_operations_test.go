package investigation

import "testing"

func TestFeedbackOperationValidation(t *testing.T) {
	operation := ResultOperation{
		ID: "feedback-1", Type: "record_feedback",
		Feedback: &FeedbackOperation{
			Category: "ux", Sentiment: "negative", Summary: "The progress indicator disappeared.",
		},
	}
	if err := operation.Validate(); err != nil {
		t.Fatal(err)
	}
	operation.Feedback.NeedsFollowup = true
	if err := operation.Validate(); err == nil {
		t.Fatal("expected a missing follow-up question to fail")
	}
	operation.Feedback.FollowupQuestion = "What did you expect to see while I worked?"
	if err := operation.Validate(); err != nil {
		t.Fatal(err)
	}
	operation.Feedback.Category = "incident"
	if err := operation.Validate(); err == nil {
		t.Fatal("expected an unsupported category to fail")
	}
}
