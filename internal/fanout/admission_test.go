package fanout

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
)

// admissible is a request that passes every gate, so each test below can turn
// exactly one thing off and name the gate that caught it. A test that builds
// its own request from scratch tends to fail for the gate before the one it
// meant to check, and then passes for the wrong reason when that gate moves.
func admissible() Request {
	clusters := Clusters(ledgerOf(
		unresolved("host.current_state", "host", "nomad-hvn03"),
		unresolved("dependency.current_health", "dependency", "postgres-primary"),
	))
	return Request{
		Effort:           core.EffortIncidentInvestigation,
		Lane:             "investigation",
		FinishedAttempts: 1,
		Clusters:         clusters,
		Proposals: []Proposal{
			{
				GoalID: "goal-host", Authority: core.AuthorityReadOnly,
				RequestedOutcome: "Establish whether host.current_state holds on nomad-hvn03.",
			},
			{
				GoalID: "goal-dependency", Authority: core.AuthorityReadOnly,
				RequestedOutcome: "Establish whether dependency.current_health holds for postgres-primary.",
			},
		},
		ActiveBranches: 0,
		BranchLimit:    DefaultBranchLimit,
		Spend:          Spend{Tokens: 10_000, TokenBudget: 400_000},
	}
}

func TestAMeasurablyAmbiguousIncidentEarnsItsBranches(t *testing.T) {
	decision := Decide(admissible())
	if !decision.Admitted() {
		t.Fatalf("a two-cluster incident with budget was refused: %q", decision.Refusal)
	}
	if len(decision.Branches) != 2 {
		t.Fatalf("admitted %d branches, want one per cluster", len(decision.Branches))
	}
	if decision.Refusal != "" {
		t.Fatalf("an admitted fan-out still carries a refusal: %q", decision.Refusal)
	}
	first, second := decision.Branches[0], decision.Branches[1]
	if first.Cluster.Identity == second.Cluster.Identity {
		t.Fatalf("both branches bound to %q; they are the same investigation",
			first.Cluster.Identity)
	}
}

// The operator's constraint, and the whole reason this gate exists: tokens are
// never burned on a guess that the work is divisible. Two goals against one
// pocket of ambiguity is two turns to learn what one turn would have.
func TestFanOutIsRefusedWhenTheProposalsOverlap(t *testing.T) {
	request := admissible()
	request.Proposals[1].RequestedOutcome =
		"Also establish whether host.current_state holds on nomad-hvn03."
	decision := Decide(request)
	if decision.Admitted() {
		t.Fatalf("two goals against one cluster were admitted as %d branches",
			len(decision.Branches))
	}
	if !strings.Contains(decision.Refusal, "same") && !strings.Contains(decision.Refusal, "overlap") {
		t.Fatalf("the refusal does not say the proposals overlap: %q", decision.Refusal)
	}
}

// A goal that names no measured cluster is a hypothesis the ledger does not
// support. Admitting it is exactly the blind spend the gate is here to stop.
func TestFanOutIsRefusedWhenAProposalNamesNoMeasuredCluster(t *testing.T) {
	request := admissible()
	request.Proposals[1].RequestedOutcome = "Have a look at the network generally."
	decision := Decide(request)
	if decision.Admitted() {
		t.Fatalf("a goal bound to nothing measured was admitted")
	}
	if !strings.Contains(decision.Refusal, "goal-dependency") {
		t.Fatalf("the refusal does not name the unbound goal: %q", decision.Refusal)
	}
}

func TestFanOutIsRefusedWithoutTheSpendToPayForIt(t *testing.T) {
	request := admissible()
	request.Spend = Spend{Tokens: 400_000, TokenBudget: 400_000}
	decision := Decide(request)
	if decision.Admitted() {
		t.Fatalf("an episode that had spent its whole budget still fanned out")
	}
	if !strings.Contains(decision.Refusal, "budget") && !strings.Contains(decision.Refusal, "spend") {
		t.Fatalf("the refusal does not name the budget: %q", decision.Refusal)
	}
}

// "Zero tokens" and "nobody measured" are different figures. Coop reports no
// usage at all on the ACP path, so a budget denominated only in tokens would
// read every such episode as having spent nothing and fan out forever.
func TestAnUnmeasuredSpendFallsBackToCountingTurns(t *testing.T) {
	request := admissible()
	request.Spend = Spend{Tokens: 0, TokenBudget: 400_000, Turns: 12, TurnBudget: 12}
	if decision := Decide(request); decision.Admitted() {
		t.Fatalf("an episode with no usage reported and no turns left still fanned out")
	}
	request.Spend.Turns = 2
	if decision := Decide(request); !decision.Admitted() {
		t.Fatalf("an episode with turns left was refused: %q", decision.Refusal)
	}
}

func TestFanOutIsRefusedOutsideAnInvestigationEffort(t *testing.T) {
	for _, effort := range []core.EffortContract{
		core.EffortConversational,
		core.EffortFocusedCheck,
		core.EffortEngineeringTask,
	} {
		request := admissible()
		request.Effort = effort
		decision := Decide(request)
		if decision.Admitted() {
			t.Fatalf("%s fanned out; only assessment and investigation may", effort)
		}
		if !strings.Contains(decision.Refusal, string(effort)) {
			t.Fatalf("the refusal for %s does not name it: %q", effort, decision.Refusal)
		}
	}
	for _, effort := range []core.EffortContract{
		core.EffortOperationalAssessment,
		core.EffortIncidentInvestigation,
	} {
		request := admissible()
		request.Effort = effort
		if decision := Decide(request); !decision.Admitted() {
			t.Fatalf("%s was refused: %q", effort, decision.Refusal)
		}
	}
}

// The bounded conversation lane answers a person in a thread. Fanning it out
// would spend an incident's worth of turns on a question that wanted a
// sentence, and the lane has no ledger to measure ambiguity against anyway.
func TestTheConversationLaneNeverFansOut(t *testing.T) {
	request := admissible()
	request.Lane = "conversation"
	decision := Decide(request)
	if decision.Admitted() {
		t.Fatalf("the conversation lane fanned out")
	}
	if !strings.Contains(decision.Refusal, "conversation") {
		t.Fatalf("the refusal does not name the lane: %q", decision.Refusal)
	}
}

// Serial first, always. The ambiguity fan-out spends against is measured from a
// sweep that has finished; before that there is no ledger to measure and every
// claim is trivially unresolved, so a first-attempt fan-out would fire on every
// incident including the simple ones.
func TestTheFirstSweepAlwaysRunsAlone(t *testing.T) {
	request := admissible()
	request.FinishedAttempts = 0
	decision := Decide(request)
	if decision.Admitted() {
		t.Fatalf("the first sweep of an investigation fanned out")
	}
	if !strings.Contains(decision.Refusal, "first") && !strings.Contains(decision.Refusal, "sweep") {
		t.Fatalf("the refusal does not say a sweep must run first: %q", decision.Refusal)
	}
}

// A single cluster is one thing to look at. This is the common case on a simple
// incident and it must take the serial path unchanged.
func TestOneClusterIsNotAmbiguityWorthBranching(t *testing.T) {
	request := admissible()
	request.Clusters = Clusters(ledgerOf(
		unresolved("host.current_state", "host", "nomad-hvn03"),
		unresolved("runtime.current_state", "runtime", "nomad-hvn03"),
	))
	decision := Decide(request)
	if decision.Admitted() {
		t.Fatalf("a single-cluster ledger fanned out")
	}
	if !strings.Contains(decision.Refusal, "one") && !strings.Contains(decision.Refusal, "independent") {
		t.Fatalf("the refusal does not say the ambiguity is not independent: %q", decision.Refusal)
	}
}

func TestFanOutIsRefusedWithoutConcurrencyHeadroom(t *testing.T) {
	request := admissible()
	request.ActiveBranches = DefaultBranchLimit
	decision := Decide(request)
	if decision.Admitted() {
		t.Fatalf("branches were admitted with the workspace pool full")
	}
	if !strings.Contains(decision.Refusal, "capacity") && !strings.Contains(decision.Refusal, "concurren") {
		t.Fatalf("the refusal does not name the capacity limit: %q", decision.Refusal)
	}
}

// One branch is the serial path with extra bookkeeping: the same single
// investigation, plus a synthesis attempt nobody needed. If capacity or the cap
// leaves room for only one, take the serial path instead.
func TestRoomForOneBranchTakesTheSerialPath(t *testing.T) {
	request := admissible()
	request.ActiveBranches = DefaultBranchLimit - 1
	if decision := Decide(request); decision.Admitted() {
		t.Fatalf("a single branch was admitted; that is the serial path with overhead")
	}
}

// Branches are read-only. A branch that could write would be a second actor
// changing the world while the lead reasons about it, and only the lead holds
// the episode's destination.
func TestABranchMayNotAskForWriteAuthority(t *testing.T) {
	for _, authority := range []core.AuthorityBoundary{
		core.AuthorityRepositoryWrite,
		core.AuthorityGovernedOperation,
	} {
		request := admissible()
		request.Proposals[1].Authority = authority
		decision := Decide(request)
		if decision.Admitted() {
			t.Fatalf("a %s branch was admitted", authority)
		}
		if !strings.Contains(decision.Refusal, "read-only") {
			t.Fatalf("the refusal for %s does not say read-only: %q", authority, decision.Refusal)
		}
	}
}

// The cap is what stops a model that found eight loose threads from opening
// eight sessions. Clusters beyond it stay for the lead to walk serially.
func TestTheBranchCapHoldsAgainstMoreClustersThanItAllows(t *testing.T) {
	request := admissible()
	views := []string{"alpha", "bravo", "charlie", "delta", "echo"}
	ledger := ledgerOf(
		unresolved("host.current_state", "host", views[0]),
		unresolved("runtime.current_state", "runtime", views[1]),
		unresolved("dependency.current_health", "dependency", views[2]),
		unresolved("workload.desired_state", "workload", views[3]),
		unresolved("application.functional_behavior", "application", views[4]),
	)
	request.Clusters = Clusters(ledger)
	request.Proposals = nil
	for i, claim := range []string{
		"host.current_state", "runtime.current_state", "dependency.current_health",
		"workload.desired_state", "application.functional_behavior",
	} {
		request.Proposals = append(request.Proposals, Proposal{
			GoalID:           "goal-" + views[i],
			Authority:        core.AuthorityReadOnly,
			RequestedOutcome: "Establish whether " + claim + " holds.",
		})
	}
	decision := Decide(request)
	if !decision.Admitted() {
		t.Fatalf("five independent clusters were refused: %q", decision.Refusal)
	}
	if len(decision.Branches) != DefaultBranchLimit {
		t.Fatalf("admitted %d branches, want the cap of %d",
			len(decision.Branches), DefaultBranchLimit)
	}
}

// Every refusal is recorded as episode progress, so a trace through an
// ambiguous incident that took the serial path says why. A blank reason is
// indistinguishable from the feature being broken.
func TestEveryRefusalSaysWhy(t *testing.T) {
	for name, mutate := range map[string]func(*Request){
		"wrong effort":     func(r *Request) { r.Effort = core.EffortConversational },
		"conversation":     func(r *Request) { r.Lane = "conversation" },
		"first sweep":      func(r *Request) { r.FinishedAttempts = 0 },
		"one cluster":      func(r *Request) { r.Clusters = r.Clusters[:1] },
		"no proposals":     func(r *Request) { r.Proposals = nil },
		"budget spent":     func(r *Request) { r.Spend = Spend{Tokens: 9, TokenBudget: 9} },
		"no headroom":      func(r *Request) { r.ActiveBranches = DefaultBranchLimit },
		"write authority":  func(r *Request) { r.Proposals[0].Authority = core.AuthorityRepositoryWrite },
		"unbound proposal": func(r *Request) { r.Proposals[0].RequestedOutcome = "something else" },
	} {
		t.Run(name, func(t *testing.T) {
			request := admissible()
			mutate(&request)
			decision := Decide(request)
			if decision.Admitted() {
				t.Fatalf("%s was admitted", name)
			}
			if strings.TrimSpace(decision.Refusal) == "" {
				t.Fatalf("%s was refused with no reason recorded", name)
			}
		})
	}
}
