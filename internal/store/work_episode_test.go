package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestWorkEpisodePersistsExecutionContractAndProgress(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: "input_1",
		CommitmentTitle: "Assess production health",
		Episode: &core.WorkEpisode{
			Effort:    core.EffortOperationalAssessment,
			Authority: core.AuthorityReadOnly,
			Objective: "Reconcile declared and live production health",
			RequiredCoverage: []string{
				"change", "host", "host", "application", "slo",
			},
			CompletionCriteria: []string{
				"cover the relevant layers", "state a decision or blocker",
			},
		},
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.Effort != core.EffortOperationalAssessment ||
		episode.Authority != core.AuthorityReadOnly ||
		episode.State != core.EpisodeAcknowledged ||
		episode.Objective != "Reconcile declared and live production health" ||
		episode.EventSequence != 1 ||
		!slices.Equal(episode.RequiredCoverage, []string{"change", "host", "application", "slo"}) {
		t.Fatalf("episode = %+v", episode)
	}
	progress, err := st.ListWorkEpisodeProgress(ctx, run.ID, 20)
	if err != nil || len(progress) != 1 || progress[0].Phase != "accepted" {
		t.Fatalf("initial progress = %+v, %v", progress, err)
	}

	due := time.Now().UTC().Add(2 * time.Minute)
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "investigating",
		"Checking required system layers", "Complete the evidence plan", due,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RecordWorkEpisodeProgress(
		ctx, run.ID, "verifying_impact", "Host checks passed; verifying customer impact", due,
	); err != nil {
		t.Fatal(err)
	}
	episode, err = st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil || episode.State != core.EpisodeWorking ||
		episode.Phase != "verifying_impact" || episode.ProgressSequence != 3 ||
		episode.EventSequence != 3 {
		t.Fatalf("advanced episode = %+v, %v", episode, err)
	}
	progress, err = st.ListWorkEpisodeProgress(ctx, run.ID, 20)
	if err != nil || len(progress) != 3 || progress[0].Sequence != 3 ||
		progress[1].Sequence != 2 || progress[2].Sequence != 1 {
		t.Fatalf("progress timeline = %+v, %v", progress, err)
	}
	events, err := st.ListWorkEpisodeEvents(ctx, run.ID, 20)
	if err != nil || len(events) != 3 || events[0].Kind != "episode_created" ||
		events[2].Kind != "progress_reported" {
		t.Fatalf("episode events = %+v, %v", events, err)
	}
	if _, err := st.AppendWorkEpisodeEvent(ctx, run.ID, events[2]); err != nil {
		t.Fatal(err)
	}
	episode, err = st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil || episode.EventSequence != 3 {
		t.Fatalf("idempotent event changed projection = %+v, %v", episode, err)
	}
}

func TestWorkEpisodeApprovalResolutionPreservesVerificationContinuation(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: "input_approval",
		Episode: &core.WorkEpisode{
			Effort: core.EffortFocusedCheck, Authority: core.AuthorityGovernedOperation,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWaitingApproval, "waiting_for_approval",
		"Waiting for Emisar approval", "Continue after the Emisar decision", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if err := st.ResolveWaitingApprovalEpisodes(
		ctx, "", "input_approval", "success",
	); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil || episode.State != core.EpisodeCompleted ||
		episode.Phase != "approval_decided" || episode.CompletedAt.IsZero() {
		t.Fatalf("resolved episode = %+v, %v", episode, err)
	}
	commitment, err := st.GetCommitmentByRun(ctx, run.ID)
	if err != nil || commitment.State != core.CommitmentDone ||
		commitment.NextAction != "Verify the terminal run and live effect" {
		t.Fatalf("resolved commitment = %+v, %v", commitment, err)
	}
}

func TestInvalidWorkEpisodeIsRejectedBeforeAgentRunIsStored(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	_, _, err = st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: "invalid_episode",
		Episode: &core.WorkEpisode{
			Effort: "unbounded", Authority: core.AuthorityReadOnly,
		},
	})
	if err == nil {
		t.Fatal("invalid effort was accepted")
	}
	if _, getErr := st.GetAgentRunBySource(ctx, "watch", "invalid_episode"); !errors.Is(getErr, ErrNotFound) {
		t.Fatalf("invalid run was persisted: %v", getErr)
	}
}

func TestBlockedWorkEpisodeRemainsOpenAfterTransportFinishes(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: "blocked_episode",
		State: core.AgentRunRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, run.ID, "completed", []byte(`{"action":"reply","message":"Blocked"}`), "", 1,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeBlocked, "blocked", "Monitoring access is unavailable",
		"Restore access and retry", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil || episode.State != core.EpisodeBlocked || !episode.CompletedAt.IsZero() {
		t.Fatalf("blocked episode = %+v, %v", episode, err)
	}
	commitment, err := st.GetCommitmentByRun(ctx, run.ID)
	if err != nil || commitment.State != core.CommitmentBlocked ||
		commitment.NextAction != "Restore access and retry" {
		t.Fatalf("blocked commitment = %+v, %v", commitment, err)
	}
}
