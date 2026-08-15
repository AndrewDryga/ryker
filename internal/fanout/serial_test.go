package fanout

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// The promise this feature was accepted on: a simple incident costs exactly
// what it costs today.
//
// It is load-bearing and it is easy to break by accident, because every gate
// above it is written as a refusal and a refusal that stops firing is silent.
// So this goes through the real ledger builder rather than a hand-assembled
// one: an ordinary single-service incident, its evidence recorded the way a
// model records it, and the assertion is that the host measures one thing to
// look at and mints no branch conversation at all. No branch conversation means
// no second run, no second Coop session, and a trace identical to the serial
// path — which is the only form of "costs the same" that can be checked.
func TestASimpleIncidentNeverLeavesTheSerialPath(t *testing.T) {
	now := time.Date(2026, 8, 14, 21, 0, 0, 0, time.UTC)
	contract := investigation.InvestigationContract{
		Version:   investigation.Version,
		Effort:    core.EffortIncidentInvestigation,
		Authority: core.AuthorityReadOnly,
		Claims: []investigation.ClaimRequirement{
			{ID: "host.current_state", Layer: "host", Required: true},
			{ID: "runtime.current_state", Layer: "runtime", Required: true},
			{ID: "workload.desired_state", Layer: "workload", Required: true},
		},
		Completion: investigation.CompletionRule{ConclusionKind: "operational_health"},
	}
	// One service is degraded and every observation is about that service. This
	// is what most incidents look like.
	evidence := []core.Evidence{
		{
			ID: "ev_host", ClaimID: "host.current_state", Target: "checkout-api",
			Observation: "The two checkout-api hosts are up and answering.",
			SourceType:  "emisar", SourceName: "emisar host snapshot",
			HealthEffect: "none", ObservedAt: now.Add(-2 * time.Minute),
		},
		{
			ID: "ev_runtime", ClaimID: "runtime.current_state", Target: "checkout-api",
			Observation: "The checkout-api runtime is restarting on a memory limit.",
			SourceType:  "emisar", SourceName: "emisar runtime status",
			HealthEffect: "degraded", ObservedAt: now.Add(-2 * time.Minute),
		},
		{
			ID: "ev_workload", ClaimID: "workload.desired_state", Target: "checkout-api",
			Observation: "checkout-api runs 2 of 4 desired replicas.",
			SourceType:  "emisar", SourceName: "emisar allocation list",
			HealthEffect: "degraded", ObservedAt: now.Add(-2 * time.Minute),
		},
	}
	coverage := []core.Coverage{
		{
			Layer: "host", Status: "healthy", Source: "emisar",
			Detail: "Both hosts healthy.", ClaimIDs: []string{"host.current_state"},
			ObservedAt: now.Add(-2 * time.Minute),
		},
		{
			Layer: "runtime", Status: "degraded", Source: "emisar",
			Detail: "Restart loop on the memory limit.", ClaimIDs: []string{"runtime.current_state"},
			ObservedAt: now.Add(-2 * time.Minute),
		},
		{
			Layer: "workload", Status: "degraded", Source: "emisar",
			Detail: "Half the desired replicas are running.", ClaimIDs: []string{"workload.desired_state"},
			ObservedAt: now.Add(-2 * time.Minute),
		},
	}

	ledger := investigation.BuildLedger(contract, evidence, coverage, now)
	clusters := Clusters(ledger)
	if len(clusters) > 1 {
		t.Fatalf("a single-service incident measured %d independent clusters (%v); "+
			"it would have paid for branches it did not need",
			len(clusters), clusterIdentities(clusters))
	}

	decision := Decide(Request{
		Effort:           core.EffortIncidentInvestigation,
		Lane:             "investigation",
		FinishedAttempts: 1,
		Clusters:         clusters,
		Proposals: []Proposal{
			{
				GoalID: "goal-runtime", Authority: core.AuthorityReadOnly,
				RequestedOutcome: "Establish why runtime.current_state is degraded on checkout-api.",
			},
			{
				GoalID: "goal-workload", Authority: core.AuthorityReadOnly,
				RequestedOutcome: "Establish why workload.desired_state is unmet on checkout-api.",
			},
		},
		BranchLimit: DefaultBranchLimit,
		Spend:       Spend{Tokens: 10_000, TokenBudget: 400_000},
	})
	if decision.Admitted() {
		t.Fatalf("a single-service incident fanned out into %d branches even though the "+
			"host measured one thing to look at", len(decision.Branches))
	}
	if decision.Refusal == "" {
		t.Fatalf("the serial path was taken with no reason recorded; a trace of this " +
			"incident cannot say why it did not fan out")
	}
}
