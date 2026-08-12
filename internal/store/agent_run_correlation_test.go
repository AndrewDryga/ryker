package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestRequeueAgentRunUsesUniqueTransportIdentityAfterCounterRepair(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_first",
	})
	if err != nil {
		t.Fatal(err)
	}

	requeue := func(turnID string) core.AgentRun {
		t.Helper()
		leased, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := st.BindAgentRunSession(
			ctx, leased.ID, "session_1", 1, "repo", 0, []byte("{}"),
		); err != nil {
			t.Fatal(err)
		}
		if err := st.MarkAgentRunSubmitted(ctx, leased.ID, turnID, 1, 0); err != nil {
			t.Fatal(err)
		}
		if err := st.RequeueAgentRun(ctx, leased.ID, "retry", 0, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
		stored, err := st.GetAgentRun(ctx, leased.ID)
		if err != nil {
			t.Fatal(err)
		}
		return stored
	}

	first := requeue("turn_1")
	if first.Failures != 1 || !strings.Contains(first.IdempotencyKey, ":recovery_") {
		t.Fatalf("first recovery identity = %+v", first)
	}
	if _, err := st.db.ExecContext(ctx, `
		UPDATE agent_runs SET failure_count = 0 WHERE id = ?`, run.ID,
	); err != nil {
		t.Fatal(err)
	}
	second := requeue("turn_2")
	if second.Failures != 1 {
		t.Fatalf("repaired failure count = %d, want 1", second.Failures)
	}
	if second.IdempotencyKey == first.IdempotencyKey {
		t.Fatalf("reused recovery key %q after counter repair", second.IdempotencyKey)
	}
}

func TestMentionOnlyRunDoesNotSupersedeSubstantiveWork(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	firstInput := core.SlackInput{
		ID: "input_first", EnvelopeID: "env_first", EventID: "event_first",
		Kind: "message", TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1",
		MessageTS: "100.2", UserID: "U1", Text: "Test again",
	}
	if created, err := st.AdmitSlackInput(ctx, firstInput); err != nil || !created {
		t.Fatalf("admit first input = %t, %v", created, err)
	}
	first, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: firstInput.ID,
	})
	if err != nil {
		t.Fatal(err)
	}

	bareMention := core.SlackInput{
		ID: "input_nudge", EnvelopeID: "env_nudge", EventID: "event_nudge",
		Kind: "mention", TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1",
		MessageTS: "100.3", UserID: "U1", Text: "<@UBOT>",
	}
	if created, err := st.AdmitSlackInput(ctx, bareMention); err != nil || !created {
		t.Fatalf("admit nudge = %t, %v", created, err)
	}
	if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: bareMention.ID,
	}); err != nil {
		t.Fatal(err)
	}
	newer, err := st.HasNewerSubstantivePendingAgentRun(ctx, first, "UBOT")
	if err != nil || newer {
		t.Fatalf("bare mention superseded substantive work = %t, %v", newer, err)
	}

	substantive := core.SlackInput{
		ID: "input_new", EnvelopeID: "env_new", EventID: "event_new",
		Kind: "mention", TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1",
		MessageTS: "100.4", UserID: "U1", Text: "<@UBOT> use the new table mapping",
	}
	if created, err := st.AdmitSlackInput(ctx, substantive); err != nil || !created {
		t.Fatalf("admit substantive input = %t, %v", created, err)
	}
	if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: substantive.ID,
	}); err != nil {
		t.Fatal(err)
	}
	newer, err = st.HasNewerSubstantivePendingAgentRun(ctx, first, "UBOT")
	if err != nil || !newer {
		t.Fatalf("substantive follow-up was not detected = %t, %v", newer, err)
	}
}

func TestFailedNewerHumanCorrectionStillSuppressesOlderThreadAnswer(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	inputs := []core.SlackInput{
		{ID: "input_old_answer", EnvelopeID: "env_old_answer", EventID: "event_old_answer",
			Kind: "mention", TeamID: "T1", ChannelID: "C1", MessageTS: "100.1",
			UserID: "U1", Text: "use the old target", ReceivedAt: now},
		{ID: "input_new_correction", EnvelopeID: "env_new_correction", EventID: "event_new_correction",
			Kind: "message", TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1",
			MessageTS: "100.2", UserID: "U1", Text: "use the new target",
			ReceivedAt: now.Add(time.Second)},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: inputs[0].ID,
		CreatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	newer, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: inputs[1].ID,
		CreatedAt: now.Add(time.Second),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `UPDATE agent_runs SET state = 'failed' WHERE id = ?`, newer.ID); err != nil {
		t.Fatal(err)
	}
	if superseded, err := st.HasNewerAgentRun(ctx, older, true); err != nil || !superseded {
		t.Fatalf("failed human correction = %t, %v", superseded, err)
	}
	if active, err := st.HasNewerAgentRun(ctx, older, false); err != nil || active {
		t.Fatalf("failed operational successor = %t, %v", active, err)
	}
}

func TestNudgeLatestAgentRunWakesPendingConversation(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	future := time.Now().UTC().Add(time.Hour)
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_first",
		NextAttemptAt: future,
	})
	if err != nil {
		t.Fatal(err)
	}
	nudged, err := st.NudgeLatestAgentRun(ctx, "C1", "100.1")
	if err != nil || !nudged {
		t.Fatalf("nudge = %t, %v", nudged, err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || !stored.NextAttemptAt.Before(future) {
		t.Fatalf("nudged run = %+v, %v", stored, err)
	}

	nudged, err = st.NudgeLatestAgentRun(ctx, "C1", "other-thread")
	if err != nil || nudged {
		t.Fatalf("unmatched nudge = %t, %v", nudged, err)
	}
}
