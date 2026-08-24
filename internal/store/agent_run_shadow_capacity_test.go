package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// On 2026-08-23 two silent Better Stack shadow investigations consumed the
// available model turns while a visible Nexus follow-up waited forty minutes.
// Shadow work may use spare capacity, but it may neither outrank a visible
// alert nor occupy more than one background worker at a time.
func TestShadowInvestigationsLeaveCapacityForVisibleWork(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	for _, channel := range []string{"CSHADOW1", "CSHADOW2"} {
		if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
			ChannelID: channel, Participation: "shadow", Repository: "repo",
			AlertPolicy: "reply", ActorID: "UOPERATOR",
		}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CLIVE", Participation: "proactive", Repository: "repo",
		AlertPolicy: "reply", ActorID: "UOPERATOR",
	}); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC()
	inputs := []core.SlackInput{
		{ID: "a-shadow", EnvelopeID: "env-a-shadow", EventID: "event-a-shadow",
			Kind: "bot_message", TeamID: "T1", ChannelID: "CSHADOW1", MessageTS: "1.1",
			UserID: "BBETTERSTACK", Text: "shadow incident one", ReceivedAt: now},
		{ID: "b-shadow", EnvelopeID: "env-b-shadow", EventID: "event-b-shadow",
			Kind: "bot_message", TeamID: "T1", ChannelID: "CSHADOW2", MessageTS: "1.2",
			UserID: "BBETTERSTACK", Text: "shadow incident two", ReceivedAt: now.Add(time.Second)},
		{ID: "z-visible", EnvelopeID: "env-z-visible", EventID: "event-z-visible",
			Kind: "bot_message", TeamID: "T1", ChannelID: "CLIVE", MessageTS: "1.3",
			UserID: "BGRAFANA", Text: "visible production alert", ReceivedAt: now.Add(2 * time.Second)},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
		if _, created, err := st.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
			ConversationKey: "operation:" + input.ID, SourceKind: "watch",
			SourceID: input.ID, UserID: input.UserID, Prompt: input.Text,
		}); err != nil || !created {
			t.Fatalf("queue %s = %t, %v", input.ID, created, err)
		}
	}

	visible, err := st.LeaseAgentRun(ctx)
	if err != nil || visible.SourceID != "z-visible" {
		t.Fatalf("first lease = %+v, %v; visible work must outrank shadow work", visible, err)
	}
	if err := st.SupersedeAgentRun(ctx, visible.ID, "test completed visible work"); err != nil {
		t.Fatal(err)
	}
	shadow, err := st.LeaseAgentRun(ctx)
	if err != nil || (shadow.SourceID != "a-shadow" && shadow.SourceID != "b-shadow") {
		t.Fatalf("first shadow lease = %+v, %v", shadow, err)
	}
	if _, err := st.LeaseAgentRun(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second shadow consumed reserved capacity: %v", err)
	}
	if err := st.SupersedeAgentRun(ctx, shadow.ID, "test released shadow capacity"); err != nil {
		t.Fatal(err)
	}
	remaining, err := st.LeaseAgentRun(ctx)
	if err != nil || remaining.SourceID == shadow.SourceID ||
		(remaining.SourceID != "a-shadow" && remaining.SourceID != "b-shadow") {
		t.Fatalf("remaining shadow did not resume after capacity returned: %+v, %v", remaining, err)
	}
}
