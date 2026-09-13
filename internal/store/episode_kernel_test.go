package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
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
		SubmittedPrompt: "SYSTEM: bounded test prompt\n\nUSER: verify the rollout",
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", ContentDigest: "sha256:a",
			Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := st.GetContextManifest(ctx, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.SubmittedPrompt != first.SubmittedPrompt {
		t.Fatalf("submitted prompt = %q, want %q", loaded.SubmittedPrompt, first.SubmittedPrompt)
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

// One attempt can run several Coop turns — a refused result is sent back as a
// correction on the same attempt — so the manifest has to total them. Recording
// only the last turn would report the smallest number for the attempts that
// cost the most.
func TestContextManifestUsageTotalsEveryTurnOfTheAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "usage-total")
	manifest, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: run.AttemptID,
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Usage.Recorded() {
		t.Fatalf("a fresh manifest claimed measured usage: %+v", manifest.Usage)
	}
	if err := st.RecordAttemptTurnCost(ctx, run.AttemptID, "turn_1", core.ContextUsage{
		InputTokens: 100, CachedInputTokens: 10, OutputTokens: 20, ReasoningTokens: 5,
		CostUSD: 0.25, CostedTurns: 1,
	}, core.ContextLatency{}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordAttemptTurnCost(ctx, run.AttemptID, "turn_2", core.ContextUsage{
		InputTokens: 200, CachedInputTokens: 20, OutputTokens: 40, ReasoningTokens: 7,
		CostUSD: 0.40, CostedTurns: 1,
	}, core.ContextLatency{}); err != nil {
		t.Fatal(err)
	}
	loaded, err := st.GetContextManifest(ctx, manifest.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := core.ContextUsage{
		InputTokens: 300, CachedInputTokens: 30, OutputTokens: 60, ReasoningTokens: 12,
		CostUSD: 0.65, CostedTurns: 2,
	}
	if loaded.Usage != want {
		t.Fatalf("attempt usage = %+v, want %+v", loaded.Usage, want)
	}
	if !loaded.Usage.Recorded() {
		t.Fatal("measured usage reported itself as not recorded")
	}
}

// Usage is written on the way out of a terminal turn, before the staging that
// follows it can fail; when it does, the same turn is polled and recorded
// again. A total that grows on every retry is worse than no total, because
// nothing tells it apart from a real one.
func TestContextManifestUsageIgnoresTheSameTurnTwice(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "usage-replay")
	manifest, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: run.AttemptID,
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	usage := core.ContextUsage{InputTokens: 100, OutputTokens: 20, CostUSD: 0.25, CostedTurns: 1}
	for range 3 {
		if err := st.RecordAttemptTurnCost(
			ctx, run.AttemptID, "turn_1", usage, core.ContextLatency{},
		); err != nil {
			t.Fatal(err)
		}
	}
	loaded, err := st.GetContextManifest(ctx, manifest.ID)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Usage != usage {
		t.Fatalf("replayed turn counted more than once: %+v, want %+v", loaded.Usage, usage)
	}
}

// A provider that reported nothing must not look like a turn that was free, and
// must not mark the manifest as measured either.
func TestContextManifestUsageKeepsUnreportedTurnsUnrecorded(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "usage-silent")
	manifest, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: run.AttemptID,
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RecordAttemptTurnCost(
		ctx, run.AttemptID, "turn_1", core.ContextUsage{}, core.ContextLatency{},
	); err != nil {
		t.Fatal(err)
	}
	loaded, err := st.GetContextManifest(ctx, manifest.ID)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Usage.Recorded() {
		t.Fatalf("an unmeasured turn was recorded as usage: %+v", loaded.Usage)
	}
	// A later turn that the provider did measure still lands: the silent turn
	// must not have consumed the idempotency key.
	if err := st.RecordAttemptTurnCost(
		ctx, run.AttemptID, "turn_2", core.ContextUsage{InputTokens: 5}, core.ContextLatency{},
	); err != nil {
		t.Fatal(err)
	}
	loaded, err = st.GetContextManifest(ctx, manifest.ID)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Usage.InputTokens != 5 {
		t.Fatalf("measured turn after a silent one = %+v", loaded.Usage)
	}
}

func TestContextManifestUsageRejectsInvalidProviderCost(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, usage := range []core.ContextUsage{
		{CostUSD: -1, CostedTurns: 1},
		{CostUSD: 1, CostedTurns: -1},
	} {
		if err := st.RecordAttemptTurnCost(ctx, "attempt", "turn", usage, core.ContextLatency{}); err == nil {
			t.Fatalf("invalid provider cost was accepted: %+v", usage)
		}
	}
}

// Timings total across the turns of an attempt exactly as tokens do, and are
// kept apart from each other because a slow reply blamed on the model when it
// was actually the host waiting to notice sends someone to fix the wrong thing.
func TestContextManifestLatencyTotalsEveryTurnOfTheAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "latency-total")
	manifest, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: run.AttemptID,
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Latency.Recorded() {
		t.Fatalf("a fresh manifest claimed measured latency: %+v", manifest.Latency)
	}
	for index, latency := range []core.ContextLatency{
		{Turns: 1, Queued: 250 * time.Millisecond, Provider: 40 * time.Second, Host: time.Second},
		{Turns: 1, Queued: 750 * time.Millisecond, Provider: 20 * time.Second, Host: 2 * time.Second},
	} {
		if err := st.RecordAttemptTurnCost(
			ctx, run.AttemptID, fmt.Sprintf("turn_%d", index), core.ContextUsage{}, latency,
		); err != nil {
			t.Fatal(err)
		}
	}
	loaded, err := st.GetContextManifest(ctx, manifest.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := core.ContextLatency{
		Turns: 2, Queued: time.Second, Provider: time.Minute, Host: 3 * time.Second,
	}
	if loaded.Latency != want {
		t.Fatalf("attempt latency = %+v, want %+v", loaded.Latency, want)
	}
	// The usage columns must not have been disturbed by a timing-only write:
	// today every real turn is exactly that, because Coop reports no tokens.
	if loaded.Usage.Recorded() {
		t.Fatalf("timing-only turns invented token usage: %+v", loaded.Usage)
	}
}

// A turn that finished before it started, or that never started at all, has no
// duration to record. Recording zero would put it in the divisor and drag every
// average toward a number no turn actually took.
func TestContextLatencyIgnoresTurnsItCannotMeasure(t *testing.T) {
	start := time.Date(2026, 8, 8, 12, 0, 0, 0, time.UTC)
	for name, latency := range map[string]core.ContextLatency{
		"never started": core.NewContextLatency(
			start, time.Time{}, start.Add(time.Second), start.Add(2*time.Second),
		),
		"never finished": core.NewContextLatency(
			start, start.Add(time.Second), time.Time{}, start.Add(2*time.Second),
		),
	} {
		if latency.Recorded() {
			t.Fatalf("%s: an unmeasurable turn reported a duration: %+v", name, latency)
		}
	}
	// A turn Coop never queued still measures the spans it does have, rather
	// than reporting two millennia of queueing from a zero timestamp.
	unqueued := core.NewContextLatency(
		time.Time{}, start, start.Add(30*time.Second), start.Add(31*time.Second),
	)
	want := core.ContextLatency{Turns: 1, Provider: 30 * time.Second, Host: time.Second}
	if unqueued != want {
		t.Fatalf("unqueued turn = %+v, want %+v", unqueued, want)
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
	if current.Conversation.ChannelID != "COPS" || current.Conversation.ThreadTS != "2.0" {
		t.Fatalf("blank source route was not repaired with the first bound destination: %+v", current)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, ErrNotFound) {
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
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || leased.ID != "delivery-current" {
		t.Fatalf("lease current delivery = %+v, %v", leased, err)
	}
}

func TestChangingDestinationPreservesExistingConversationIdentity(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	_, episode := queueKernelEpisode(t, st, "destination-source")

	current, err := st.ChangeEpisodeDestination(
		ctx,
		episode.ID,
		core.BoundDestination{ChannelID: "CDEST", ThreadTS: "2.0"},
		"operator moved the answer",
	)
	if err != nil {
		t.Fatal(err)
	}
	if current.Conversation != episode.Conversation {
		t.Fatalf("destination move rewrote source identity: before=%+v after=%+v",
			episode.Conversation, current.Conversation)
	}
}

func TestFinalSlackPostPartCreatesDurableEpisodeThread(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	_, episode := queueKernelEpisode(t, st, "multipart-thread")
	for index, id := range []string{
		"opaque_delivery_001",
		"opaque_delivery_999",
	} {
		created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID: id, EpisodeID: episode.ID, Operation: "post", Kind: "notice",
			ChannelID: "COPS", Body: []byte(`{"text":"part"}`),
			ExpectedDestinationRevision: episode.DestinationRevision,
			ResponseRoot:                index == 1,
		})
		if err != nil || !created {
			t.Fatalf("enqueue %s = %t, %v", id, created, err)
		}
	}
	first, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, first.ID, "1700.101", "sending"); err != nil {
		t.Fatal(err)
	}
	current, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil || current.Destination.ThreadTS != "" {
		t.Fatalf("intermediate part rebound episode = %+v, %v", current, err)
	}
	last, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, last.ID, "1700.199", "sending"); err != nil {
		t.Fatal(err)
	}
	current, err = st.GetWorkEpisode(ctx, episode.ID)
	if err != nil || current.Destination.ThreadTS != "1700.199" ||
		current.Conversation.ThreadTS != "1700.199" {
		t.Fatalf("final part did not establish durable reply thread = %+v, %v", current, err)
	}
}

func TestVisualResponseRootCreatesDurableEpisodeThread(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	_, episode := queueKernelEpisode(t, st, "visual-thread")
	created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "opaque_visual", EpisodeID: episode.ID, Operation: "file",
		Kind: "generated_visual", ChannelID: "COPS", Body: []byte(`{"file":"chart"}`),
		ExpectedDestinationRevision: episode.DestinationRevision, ResponseRoot: true,
	})
	if err != nil || !created {
		t.Fatalf("enqueue visual = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, leased.ID, "1700.299", "sending"); err != nil {
		t.Fatal(err)
	}
	current, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil || current.Destination.ThreadTS != "1700.299" {
		t.Fatalf("visual response did not establish durable thread = %+v, %v", current, err)
	}
}

func TestSlackProcessingStatusBelongsToEpisodeWithoutChangingReplyDestination(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	_, episode := queueKernelEpisode(t, st, "status-source-route")

	current, err := st.ChangeEpisodeDestination(
		ctx,
		episode.ID,
		core.BoundDestination{ChannelID: "COPS"},
		"operator moved the answer back to the channel",
	)
	if err != nil {
		t.Fatal(err)
	}
	created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "delivery-status", EpisodeID: episode.ID, Operation: "status",
		ChannelID: "COPS", ThreadTS: "2.0", Status: "Working",
		ExpectedDestinationRevision: current.DestinationRevision,
	})
	if err != nil || !created {
		t.Fatalf("enqueue source-thread status = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || leased.ID != "delivery-status" || leased.EpisodeID != episode.ID {
		t.Fatalf("lease source-thread status = %+v, %v", leased, err)
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

// The deployed Svelte recovery exposed a wakeup written by an older binary:
// its episode was terminal but the row still said pending. A scheduler restart
// must repair that durable mismatch instead of launching obsolete work.
func TestWakeupLeaseReconcilesTerminalEpisodeLeftByOlderBinary(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "legacy-terminal-wakeup")
	now := time.Now().UTC()
	wakeup, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
		ID: "legacy-terminal-wakeup", EpisodeID: episode.ID, Kind: "scheduled_verification",
		PollAfter: now.Add(-time.Second), Deadline: now.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "finished", "Completed", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `
		UPDATE episode_wakeups
		SET state = 'pending', resolved_at = NULL, updated_at = ?
		WHERE id = ?`, now.Format(timestampFormat), wakeup.ID); err != nil {
		t.Fatal(err)
	}

	if _, err := st.LeaseDueEpisodeWakeup(ctx, "scheduler", time.Minute); !errors.Is(err, ErrNotFound) {
		t.Fatalf("terminal episode wakeup was leased: %v", err)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, episode.ID)
	if err != nil || len(wakeups) != 1 || wakeups[0].State != core.WakeupCancelled ||
		wakeups[0].ResolvedAt.IsZero() {
		t.Fatalf("legacy terminal wakeup was not reconciled: %+v, %v", wakeups, err)
	}
}

// A manifest remembers which rung of the model ladder its briefing went out on.
//
// It is the only record of WHICH MODEL was taught the result contract. A
// repeated correction escalates the retry up the session policy's ladder, and a
// ladder step is a different model; without this column the delta-turn decision
// can only see that a session holds a briefing, never that the model about to
// read that session was not the one briefed. On blitz on 2026-08-16 that cost
// two envelope rounds — about $0.85 and four minutes — of a fresh model
// answering `unknown field "completion_contract"` and then `unknown field
// "record_evidence"` about a schema the previous rung had been taught.
func TestAContextManifestRemembersTheRungItsBriefingWentOutOn(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "target-floor")
	escalated, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: run.AttemptID, TargetFloor: 2,
		SubmittedPrompt: "SYSTEM: the whole briefing",
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := st.GetContextManifest(ctx, escalated.ID)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.TargetFloor != 2 {
		t.Fatalf("the manifest reads back at rung %d, so nothing on disk says "+
			"which model was taught this contract", loaded.TargetFloor)
	}
	// The delta-turn decision reads the episode's latest manifest and no other,
	// so a rung the row holds and this reader drops is a rung nothing enforces.
	latest, err := st.GetLatestContextManifest(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if latest.TargetFloor != 2 {
		t.Fatalf("the standing briefing reads back at rung %d", latest.TargetFloor)
	}
	ordinary, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: run.AttemptID, ParentManifestID: escalated.ID,
		SubmittedPrompt: "SYSTEM: the whole briefing",
		References: []core.ContextReference{{
			Kind: "slack_message", SourceRef: "slack:COPS:1.0", Visibility: "channel",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if loaded, err := st.GetContextManifest(ctx, ordinary.ID); err != nil ||
		loaded.TargetFloor != 0 {
		t.Fatalf("an unescalated briefing recorded rung %d: %v", loaded.TargetFloor, err)
	}
}

// The second correction budget measures what the episode SPENT, not how many
// attempts it has had. An alert stream is one episode across every card and
// wakeup it produces, so attempts count cards: without this sum, a stream that
// fired all day on 2026-08-16 would have been refused its first correction at
// attempt twenty-one having spent none.
func TestEpisodeCorrectionTotalCountsCorrectionsNotAttempts(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first, episode := queueKernelEpisode(t, st, "stream-card-1")
	total, err := st.SumEpisodeStructuredCorrections(ctx, episode.ID)
	if err != nil || total != 0 {
		t.Fatalf("a fresh episode has spent %d corrections (%v), want 0", total, err)
	}
	if err := st.SetAgentRunContext(
		ctx, first.ID, []byte(`{"captured_at":"2026-08-16T12:00:00Z","structured_corrections":2}`),
	); err != nil {
		t.Fatal(err)
	}
	for index := range 3 {
		next, _, queueErr := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: first.ChannelID,
			ConversationKey: first.ConversationKey, SourceKind: "watch",
			SourceID: fmt.Sprintf("stream-card-%d", index+2),
		})
		if queueErr != nil {
			t.Fatal(queueErr)
		}
		// Only the last of the three spends anything; the others are cards that
		// were answered without argument and must contribute zero.
		if index == 2 {
			if err := st.SetAgentRunContext(
				ctx, next.ID,
				[]byte(`{"captured_at":"2026-08-16T13:00:00Z","structured_corrections":3}`),
			); err != nil {
				t.Fatal(err)
			}
		}
	}
	total, err = st.SumEpisodeStructuredCorrections(ctx, episode.ID)
	if err != nil || total != 5 {
		t.Fatalf("episode corrections = %d (%v), want 5 across four attempts", total, err)
	}
}

// A live OOM replay completed a three-minute investigation, then never got the
// one correction its result needed. Two older runs in the same alert episode
// predated structured contexts and stored an empty context blob; json_extract
// failed on that legacy row, so Ryker discarded the useful result before
// it could ask the model to repair it.
func TestEpisodeCorrectionTotalTreatsLegacyInvalidContextsAsZero(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first, episode := queueKernelEpisode(t, st, "legacy-stream-card")
	if err := st.SetAgentRunContext(ctx, first.ID, []byte(`{`)); err != nil {
		t.Fatal(err)
	}
	second, _, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: first.ChannelID,
		ConversationKey: first.ConversationKey, SourceKind: "watch",
		SourceID: "current-stream-card",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetAgentRunContext(
		ctx, second.ID, []byte(`{"structured_corrections":2}`),
	); err != nil {
		t.Fatal(err)
	}

	total, err := st.SumEpisodeStructuredCorrections(ctx, episode.ID)
	if err != nil || total != 2 {
		t.Fatalf("episode corrections = %d (%v), want 2 with legacy context ignored", total, err)
	}
}

// An answer already written and queued is withdrawn on one criterion: a newer
// reply for the same thread has already been posted. On 2026-08-16 the criterion
// was "a newer input was admitted", which threw away four finished Grafana
// answers for questions nobody had answered yet.
func TestOnlyASentReplyMakesAnOlderThreadReplyStale(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	enqueue := func(id, sourceInput string, responseRoot bool, operation string) core.SlackDelivery {
		t.Helper()
		created, enqueueErr := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID: id, Operation: operation, Kind: "notice", ChannelID: "CWATCH",
			ThreadTS: "1700.100", Body: []byte(`{"text":"answer"}`),
			ResponseRoot: responseRoot, SourceInputID: sourceInput,
		})
		if enqueueErr != nil || !created {
			t.Fatalf("enqueue %s = %t, %v", id, created, enqueueErr)
		}
		stored, getErr := st.GetSlackDelivery(ctx, id)
		if getErr != nil {
			t.Fatal(getErr)
		}
		return stored
	}

	older := enqueue("older-reply", "card-1", true, "post")
	newer := enqueue("newer-reply", "card-2", true, "post")
	found, err := st.HasNewerSentReplyInThread(
		ctx, older.ChannelID, older.ThreadTS, older.SourceInputID, older.CreatedAt,
	)
	if err != nil || found {
		t.Fatalf("a merely queued newer reply made the older one stale: %t, %v", found, err)
	}
	if err := st.FinishSlackDelivery(ctx, newer.ID, "1700.500", "pending"); err != nil {
		t.Fatal(err)
	}
	found, err = st.HasNewerSentReplyInThread(
		ctx, older.ChannelID, older.ThreadTS, older.SourceInputID, older.CreatedAt,
	)
	if err != nil || !found {
		t.Fatalf("a sent newer reply did not make the older one stale: %t, %v", found, err)
	}
	// Its own delivery never counts, and neither does one sent before it.
	found, err = st.HasNewerSentReplyInThread(
		ctx, newer.ChannelID, newer.ThreadTS, newer.SourceInputID, newer.CreatedAt,
	)
	if err != nil || found {
		t.Fatalf("a reply was made stale by itself: %t, %v", found, err)
	}
}
