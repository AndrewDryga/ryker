package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestGeneratedVisualRetryRequest(t *testing.T) {
	for _, text := range []string{
		"so show me the image?",
		"Please retry the chart upload",
		"attach that graph again",
		"resend the visual",
	} {
		if !generatedVisualRetryRequest(text) {
			t.Errorf("retry request not recognized: %q", text)
		}
	}
	for _, text := range []string{
		"make a new image of a cat",
		"show me the current CPU utilization",
		"try again",
		"the chart looks good",
	} {
		if generatedVisualRetryRequest(text) {
			t.Errorf("new or unrelated request recognized as a retry: %q", text)
		}
	}
}

func TestSlackVisualFollowupRetriesRetainedFileWithoutAgentRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)

	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "retained-visual", Operation: "file", Kind: "generated_visual",
		ChannelID: "C123", ThreadTS: "1700.1", Body: []byte(`{"retained":true}`),
	}); err != nil || !created {
		t.Fatalf("enqueue retained visual = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackDelivery(
		ctx, leased.ID, "missing_scope", time.Now().Add(time.Hour), false, true,
	); err != nil {
		t.Fatal(err)
	}

	input := core.SlackInput{
		ID: "show-retained", EnvelopeID: "show-retained-envelope",
		EventID: "show-retained-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "C123", ThreadTS: "1700.1", MessageTS: "1700.2",
		UserID: "U123ABC", Text: "So show me the image?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit follow-up = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	storedInput, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || storedInput.State != "done" {
		t.Fatalf("follow-up input = %+v, %v", storedInput, err)
	}
	visual, err := st.GetSlackDelivery(ctx, "retained-visual")
	if err != nil || visual.State != "retry" || visual.Attempts != 0 ||
		visual.LastError != "" || visual.NextAttemptAt.After(time.Now()) {
		t.Fatalf("retained visual = %+v, %v", visual, err)
	}
	if _, err := st.LeaseAgentRun(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("visual retry queued an agent run: %v", err)
	}
}
