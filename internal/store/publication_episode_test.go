package store

import (
	"context"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// publications.incident_id is the table's PRIMARY KEY, which says something
// stronger than "this happened in that room": it says a publication IS an
// incident's, one each, reachable no other way. §25 phase 5 asks for
// engineering work that follows pull request, checks, merge and verification
// from a normal thread, and the first thing that costs is an owner the room
// does not supply.
//
// The publish CLICK owns no episode of its own — measured on the emisar
// deployment, publications.attempt_input_id joins to no run's source — so the
// only honest owner is the work that produced the diff: the incident's most
// recent episode-bearing run. This is the test that says the column is filled
// by the statement that creates the row rather than left for somebody to
// backfill later.
func TestAPublicationNamesTheEpisodeThatProducedTheDiff(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())

	task, _, err := st.CreateEngineeringTask(
		ctx, "owner/repo", "publication-episode", "Publish task", "summary",
		"UOPERATOR", "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID, ChannelID: "COPS",
		ConversationKey: "incident:" + task.ID,
		SourceKind:      "task", SourceID: "task_input_1", UserID: "UOPERATOR",
		Repository: "owner/repo", Prompt: "prepare the change",
		CommitmentTitle: "Prepare the change",
		Episode: &core.WorkEpisode{
			Effort: core.EffortFocusedCheck, Authority: core.AuthorityReadOnly,
			Objective: "Prepare the change",
		},
	})
	if err != nil || run.EpisodeID == "" {
		t.Fatalf("task run = %+v, %v", run, err)
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack_publish_1", EnvelopeID: "env_publish_1", EventID: "EvPublish1",
		Kind: "action", TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.200",
		UserID: "UOPERATOR", ActionID: "responder_publish_pr", ActionValue: task.ID,
	}); err != nil || !created {
		t.Fatalf("admit publish click = %t, %v", created, err)
	}

	publication, err := st.Publications.BeginReview(
		ctx, "slack_publish_1", "", task.ID, "owner/repo", "main", nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if publication.EpisodeID != run.EpisodeID {
		t.Fatalf(
			"publication episode = %q, want the episode that produced the diff %q; "+
				"a publication reachable only through its incident cannot exist for work "+
				"that never opened a room",
			publication.EpisodeID, run.EpisodeID,
		)
	}

	// A second attempt bumps the generation and re-resolves the owner, because
	// a replacement attempt may belong to a newer episode than the one that
	// opened the row.
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || stored.EpisodeID != run.EpisodeID {
		t.Fatalf("stored publication = %+v, %v", stored, err)
	}
}
