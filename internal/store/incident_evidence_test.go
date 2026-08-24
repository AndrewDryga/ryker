package store

import (
	"context"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// An episode that escalated to an incident must see the evidence recorded
// against that incident.
//
// Evidence from an incident investigation is keyed by the incident, not by the
// Slack input that started it, so matching on source_input alone made an
// escalated episode's own findings invisible to it. That lookup feeds the
// inherited claim ledger, whose whole purpose — per its own doc comment — is
// that correlated episodes stop "repeatedly rediscovering (and contradicting)
// the same incident". Incidents were the one case where it did not work.
func TestEscalatedEpisodeSeesItsIncidentEvidence(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())

	incident := incidentForEvidence(t, ctx, st)
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: "CINFRA", ConversationKey: "incident:" + incident.ID,
		SourceKind: "slack", SourceID: "input_escalated", UserID: "UOPERATOR",
	})
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}

	// Evidence as the incident path records it: keyed by incident, with a
	// source input that is not this episode's run.
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: incident.ID, ChannelID: "CINFRA",
		SourceInput: "some_other_input",
		ClaimID:     "service.health", Claim: "checkout is degraded",
		Observation: "error rate is 8% over ten minutes",
		SourceType:  "emisar", SourceName: "prod-eu",
	}}); err != nil {
		t.Fatal(err)
	}

	found, err := st.Intelligence.ListEpisodeEvidence(ctx, episode.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 1 {
		t.Fatalf("escalated episode sees %d evidence items, want 1 — its own incident "+
			"investigation is invisible to it, so anything correlated to it rediscovers", len(found))
	}
	if found[0].Claim != "checkout is degraded" {
		t.Fatalf("wrong evidence returned: %+v", found[0])
	}
}

// Another incident's evidence must not leak in. Incident scope is the width
// that is wanted; anything wider would put one team's investigation into
// another's ledger.
func TestEpisodeDoesNotSeeAnotherIncidentsEvidence(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())

	mine := incidentForEvidence(t, ctx, st)
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: mine.ID,
		ChannelID: "CINFRA", ConversationKey: "incident:" + mine.ID,
		SourceKind: "slack", SourceID: "input_mine", UserID: "UOPERATOR",
	})
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: "inc_someone_elses", ChannelID: "COTHER",
		SourceInput: "unrelated_input",
		ClaimID:     "service.health", Claim: "a different service is fine",
		Observation: "no errors", SourceType: "emisar", SourceName: "other",
	}}); err != nil {
		t.Fatal(err)
	}
	found, err := st.Intelligence.ListEpisodeEvidence(ctx, episode.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 0 {
		t.Fatalf("another incident's evidence leaked into this episode: %+v", found)
	}
}

// Current-candidate validation must not promote incident-wide history to this
// attempt's proof. A parent episode's rows still belong in the historical
// ledger, but a child recheck claiming a current result has to record its own.
func TestCurrentEpisodeRecordsExcludeParentRowsFromTheSameIncident(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	incident := incidentForEvidence(t, ctx, st)
	parentRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID, ChannelID: "CINFRA",
		ConversationKey: "incident:" + incident.ID, SourceKind: "slack",
		SourceID: "parent-input", UserID: "UOPERATOR",
	})
	if err != nil {
		t.Fatal(err)
	}
	parent, err := st.GetWorkEpisodeByRun(ctx, parentRun.ID)
	if err != nil {
		t.Fatal(err)
	}
	childRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID, ChannelID: "CINFRA",
		ConversationKey: "incident-child:" + incident.ID, SourceKind: "slack",
		SourceID: "child-input", UserID: "UOPERATOR",
		Episode: &core.WorkEpisode{ParentEpisodeID: parent.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	child, err := st.GetWorkEpisodeByRun(ctx, childRun.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: incident.ID, ChannelID: "CINFRA", SourceInput: "parent-input",
		ClaimID: "service.health", Claim: "parent state", Observation: "parent observed healthy",
		SourceType: "monitoring", SourceName: "parent probe",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.Intelligence.RecordCoverage(ctx, []core.Coverage{{
		IncidentID: incident.ID, ChannelID: "CINFRA", SourceInput: "parent-input",
		Layer: "application", Status: "healthy", Detail: "parent coverage",
	}}); err != nil {
		t.Fatal(err)
	}

	currentEvidence, err := st.Intelligence.ListCurrentEpisodeEvidence(ctx, child.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	currentCoverage, err := st.Intelligence.ListCurrentEpisodeCoverage(ctx, child.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(currentEvidence) != 0 || len(currentCoverage) != 0 {
		t.Fatalf("parent incident rows became current child proof: evidence=%+v coverage=%+v",
			currentEvidence, currentCoverage)
	}
	historyEvidence, err := st.Intelligence.ListEpisodeEvidence(ctx, child.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	historyCoverage, err := st.Intelligence.ListEpisodeCoverage(ctx, child.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(historyEvidence) != 1 || len(historyCoverage) != 1 {
		t.Fatalf("parent rows disappeared from history: evidence=%+v coverage=%+v",
			historyEvidence, historyCoverage)
	}
}

// incidentForEvidence creates one active incident to attach evidence to.
func incidentForEvidence(t *testing.T, ctx context.Context, st *Store) core.Incident {
	t.Helper()
	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), 0, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("create incident = %+v, %v", incidents, err)
	}
	return incidents[0]
}
