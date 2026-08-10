package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestAdmitSyntheticSlackInputPersistsFrozenBeforeActivation(t *testing.T) {
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	want := []byte(`{"repository":"infra","session_channel_id":"scheduled:occurrence"}`)
	input := core.SlackInput{
		ID: "scheduled_occurrence", EnvelopeID: "scheduled_occurrence",
		EventID: "scheduled_occurrence", Kind: "scheduled", TeamID: "T1",
		ChannelID: "C1", UserID: "U1", Text: "Check production health.",
		Frozen: want, ReceivedAt: time.Now().UTC(),
	}
	created, err := st.AdmitSyntheticSlackInput(context.Background(), input)
	if err != nil || !created {
		t.Fatalf("admit synthetic input: created=%v err=%v", created, err)
	}

	got, err := st.GetSlackInput(context.Background(), input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != "processing" || string(got.Frozen) != string(want) {
		t.Fatalf("synthetic input = state %q frozen %q", got.State, got.Frozen)
	}
}
