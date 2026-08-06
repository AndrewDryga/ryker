package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func queueKernelEpisodeForConversation(t *testing.T, st *Store, source string, conversation string) (core.AgentRun, core.WorkEpisode) {
	t.Helper()
	run, created, err := st.QueueAgentRun(context.Background(), core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: conversation,
		SourceKind: "watch", SourceID: source, Prompt: "Investigate " + source,
	})
	if err != nil || !created {
		t.Fatalf("queue episode: created=%t run=%+v err=%v", created, run, err)
	}
	episode, err := st.GetWorkEpisodeByRun(context.Background(), run.ID)
	if err != nil {
		t.Fatal(err)
	}
	return run, episode
}

func queueKernelEpisode(t *testing.T, st *Store, source string) (core.AgentRun, core.WorkEpisode) {
	t.Helper()
	return queueKernelEpisodeForConversation(t, st, source, "thread:COPS:"+source)
}

func TestEpisodeLeasingSerializesConversationButNotChannel(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first, _ := queueKernelEpisodeForConversation(t, st, "message-1", "thread:COPS:1")
	second, _ := queueKernelEpisodeForConversation(t, st, "message-2", "thread:COPS:2")
	leasedFirst, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	leasedSecond, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatalf("unrelated conversation in the same channel was blocked: %v", err)
	}
	if leasedFirst.ID == leasedSecond.ID {
		t.Fatalf("same run leased twice: %s", leasedFirst.ID)
	}
	if (leasedFirst.ID != first.ID && leasedFirst.ID != second.ID) ||
		(leasedSecond.ID != first.ID && leasedSecond.ID != second.ID) {
		t.Fatalf("unexpected leases: %s, %s", leasedFirst.ID, leasedSecond.ID)
	}
}

func TestEpisodeLeasingKeepsSameConversationOrdered(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	queueKernelEpisodeForConversation(t, st, "message-1", "channel:COPS")
	queueKernelEpisodeForConversation(t, st, "message-2", "channel:COPS")
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("same conversation leased out of order: %v", err)
	}
}

func TestEpisodeLeasingPrioritizesHumanRequestsAheadOfAmbientAlerts(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	inputs := []core.SlackInput{
		{
			ID: "ambient-alert", EnvelopeID: "env-ambient-alert", EventID: "event-ambient-alert",
			Kind: "bot_message", TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.1",
			UserID: "BGRAFANA", Text: "Alert firing", ReceivedAt: now,
		},
		{
			ID: "human-mention", EnvelopeID: "env-human-mention", EventID: "event-human-mention",
			Kind: "mention", TeamID: "T1", ChannelID: "CASK", MessageTS: "1700.2",
			UserID: "UOPERATOR", Text: "Please check production", ReceivedAt: now.Add(time.Second),
		},
	}
	for _, input := range inputs {
		created, err := st.AdmitSlackInput(ctx, input)
		if err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
		if _, created, err := st.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
			ConversationKey: "test:" + input.ID, SourceKind: "watch", SourceID: input.ID,
			UserID: input.UserID, Prompt: input.Text,
		}); err != nil || !created {
			t.Fatalf("queue %s = %t, %v", input.ID, created, err)
		}
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.SourceID != "human-mention" {
		t.Fatalf("leased %s before the human request", leased.SourceID)
	}
}

func TestEpisodeCannotCompleteWithRequiredGoalOpen(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "multi-instruction")

	goal, err := st.CreateEpisodeGoal(ctx, core.EpisodeGoal{
		EpisodeID: episode.ID, Kind: "check", RequestedOutcome: "Verify the rollout",
		CompletionContract: "Record a terminal rollout state", Required: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "finished", "Completed", "", time.Time{},
	); err == nil {
		t.Fatal("episode completed with an open required goal")
	}
	if err := st.SetEpisodeGoalState(ctx, goal.ID, core.GoalCompleted, ""); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "finished", "Completed", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
}

func TestContextManifestRequiresMonotonicLineage(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "context")
	attempt, err := st.GetEpisodeAttempt(ctx, run.AttemptID)
	if err != nil {
		t.Fatal(err)
	}
	first, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: attempt.ID,
		PromptVersion: "p1", ContractVersion: "c1", ToolSchemaVersion: "t1",
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", ContentDigest: "sha256:a",
			Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: attempt.ID, ParentManifestID: first.ID,
		PromptVersion: "p1", ContractVersion: "c1", ToolSchemaVersion: "t1",
	})
	if err == nil {
		t.Fatal("continued context silently dropped its prior message")
	}
	second, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: attempt.ID, ParentManifestID: first.ID,
		PromptVersion: "p1", ContractVersion: "c1", ToolSchemaVersion: "t1",
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", ContentDigest: "sha256:a",
			Visibility: "channel",
		}, {
			Kind: "repository", SourceRef: "repo:infra", SourceRevision: "abc123",
			Visibility: "workspace",
		}},
	})
	if err != nil || second.Version != 2 {
		t.Fatalf("extended context = %+v, %v", second, err)
	}
}

func TestSlackDeliveryIsBoundToEpisodeDestinationRevision(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	_, episode := queueKernelEpisode(t, st, "delivery-route")

	created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "delivery-old", EpisodeID: episode.ID, Operation: "post",
		ChannelID: "COPS", Body: []byte(`{"text":"old"}`),
	})
	if err != nil || !created {
		t.Fatalf("enqueue old delivery = %t, %v", created, err)
	}
	current, err := st.ChangeEpisodeDestination(
		ctx,
		episode.ID,
		core.BoundDestination{ChannelID: "COPS", ThreadTS: "2.0"},
		"operator moved the conversation",
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackDelivery(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stale delivery remained leaseable: %v", err)
	}
	old, err := st.GetSlackDelivery(ctx, "delivery-old")
	if err != nil || old.State != "superseded" {
		t.Fatalf("old delivery = %+v, %v", old, err)
	}

	created, err = st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "delivery-current", EpisodeID: episode.ID, Operation: "post",
		ChannelID: "COPS", ThreadTS: "2.0", Body: []byte(`{"text":"new"}`),
		ExpectedDestinationRevision: current.DestinationRevision,
	})
	if err != nil || !created {
		t.Fatalf("enqueue current delivery = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx)
	if err != nil || leased.ID != "delivery-current" {
		t.Fatalf("lease current delivery = %+v, %v", leased, err)
	}
}

func TestEpisodeWakeupSurvivesLeaseAndResolvesWithFence(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	_, episode := queueKernelEpisode(t, st, "wakeup")
	now := time.Now().UTC()
	wakeup, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
		EpisodeID: episode.ID, Kind: "timer", DueAt: now.Add(-time.Second),
		Deadline: now.Add(time.Hour), EventMatcher: []byte(`{"kind":"timer"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseDueEpisodeWakeup(ctx, "scheduler-a", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != wakeup.ID || leased.FencingToken < 1 {
		t.Fatalf("leased wakeup = %+v", leased)
	}
	if err := st.ResolveEpisodeWakeup(
		ctx, leased.ID, "scheduler-a", leased.FencingToken, []byte(`{"status":"ready"}`),
	); err != nil {
		t.Fatal(err)
	}
	items, err := st.ListEpisodeWakeups(ctx, episode.ID)
	if err != nil || len(items) != 1 || items[0].State != core.WakeupResolved {
		t.Fatalf("wakeups = %+v, %v", items, err)
	}
}
