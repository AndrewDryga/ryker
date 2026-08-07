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

// incidentForEvidence creates one active incident to attach evidence to.
func incidentForEvidence(t *testing.T, ctx context.Context, st *Store) core.Incident {
	t.Helper()
	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), 0, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("create incident = %+v, %v", incidents, err)
	}
	return incidents[0]
}
