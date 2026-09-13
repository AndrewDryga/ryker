package fanout

import (
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

func requirement(id, layer string) investigation.ClaimRequirement {
	return investigation.ClaimRequirement{ID: id, Layer: layer, Required: true}
}

// ledgerOf assembles a ledger directly rather than through BuildLedger, so a
// test can state the exact claim states it is about without also having to
// satisfy freshness, coverage and dimension rules that belong to another test.
func ledgerOf(views ...investigation.ClaimView) investigation.Ledger {
	ledger := investigation.Ledger{Claims: map[string]investigation.ClaimView{}}
	for _, view := range views {
		ledger.Contract.Claims = append(ledger.Contract.Claims, view.Requirement)
		ledger.Claims[view.Requirement.ID] = view
	}
	return ledger
}

func unresolved(id, layer string, targets ...string) investigation.ClaimView {
	view := investigation.ClaimView{
		Requirement: requirement(id, layer),
		State:       investigation.ClaimUnknown,
	}
	for _, target := range targets {
		view.Evidence = append(view.Evidence, core.Evidence{
			Target: target, Observation: "observed " + target, SourceName: "emisar",
		})
		view.State = investigation.ClaimMixed
	}
	return view
}

func identities(clusters []Cluster) []string {
	result := make([]string, 0, len(clusters))
	for _, cluster := range clusters {
		result = append(result, cluster.Identity)
	}
	return result
}

// Two claims whose evidence names the same thing are one pocket of ambiguity,
// not two. This is the half of the gate that stops fan-out: a branch sent to
// look at a target answers every claim about that target, so splitting them
// buys nothing and spends two turns to learn one thing.
func TestClaimsAboutOneThingAreOneCluster(t *testing.T) {
	clusters := Clusters(ledgerOf(
		unresolved("host.current_state", "host", "nomad-hvn03"),
		unresolved("runtime.current_state", "runtime", "nomad-hvn03"),
	))
	if len(clusters) != 1 {
		t.Fatalf("two claims about nomad-hvn03 produced %d clusters, want 1: %v",
			len(clusters), identities(clusters))
	}
	if got := len(clusters[0].ClaimIDs); got != 2 {
		t.Fatalf("the single cluster carries %d claims, want both", got)
	}
}

// The other half: claims about different things are the measurable independent
// ambiguity that fan-out exists for. The host computes this from the ledger, so
// a model cannot manufacture eligibility by asserting that its work is
// divisible.
func TestClaimsAboutDifferentThingsAreSeparateClusters(t *testing.T) {
	clusters := Clusters(ledgerOf(
		unresolved("host.current_state", "host", "nomad-hvn03"),
		unresolved("dependency.current_health", "dependency", "postgres-primary"),
	))
	if len(clusters) != 2 {
		t.Fatalf("claims about two different targets produced %d clusters, want 2: %v",
			len(clusters), identities(clusters))
	}
}

// A claim can be unresolved precisely because nothing has been observed about
// it, and such a claim carries no target at all. Falling back to the empty
// string would collapse every unexamined claim into one cluster and report "one
// thing to look at" at exactly the moment there are several — the case fan-out
// is for.
func TestAClaimNothingWasObservedAboutIsIdentifiedByItsLayer(t *testing.T) {
	clusters := Clusters(ledgerOf(
		unresolved("host.current_state", "host"),
		unresolved("dependency.current_health", "dependency"),
	))
	if len(clusters) != 2 {
		t.Fatalf("two unexamined claims produced %d clusters, want 2: %v",
			len(clusters), identities(clusters))
	}
}

// Transitivity matters: a claim that names both targets is the evidence that
// the two are one investigation, and the clusters have to merge through it or
// the host funds two branches to look at one thing from two directions.
func TestAClaimNamingTwoTargetsMergesThem(t *testing.T) {
	clusters := Clusters(ledgerOf(
		unresolved("host.current_state", "host", "nomad-hvn03"),
		unresolved("dependency.current_health", "dependency", "postgres-primary"),
		unresolved("workload.desired_state", "workload", "nomad-hvn03", "postgres-primary"),
	))
	if len(clusters) != 1 {
		t.Fatalf("a claim spanning both targets left %d clusters, want 1: %v",
			len(clusters), identities(clusters))
	}
}

// Ambiguity means unresolved. A claim the ledger has already settled, and a
// layer that does not apply at all, are not questions waiting for a branch.
func TestSettledClaimsAreNotAmbiguity(t *testing.T) {
	settled := unresolved("host.current_state", "host", "nomad-hvn03")
	settled.Resolved = true
	inapplicable := unresolved("slo.current", "slo", "checkout")
	inapplicable.State = investigation.ClaimNotApplicable
	clusters := Clusters(ledgerOf(
		settled, inapplicable,
		unresolved("dependency.current_health", "dependency", "postgres-primary"),
	))
	if len(clusters) != 1 {
		t.Fatalf("a resolved and a not-applicable claim still counted: got %d clusters %v",
			len(clusters), identities(clusters))
	}
	if clusters[0].ClaimIDs[0] != "dependency.current_health" {
		t.Fatalf("the surviving cluster is %v, want only the unresolved claim", clusters[0].ClaimIDs)
	}
}

// Evidence that has gone stale still says what the claim is about. Dropping it
// would send a claim we know the target of back to its layer identity, which
// splits one investigation into two branches that look at the same host.
func TestStaleEvidenceStillNamesWhatAClaimIsAbout(t *testing.T) {
	stale := investigation.ClaimView{
		Requirement: requirement("host.current_state", "host"),
		State:       investigation.ClaimUnknown,
		Stale:       true,
		StaleEvidence: []core.Evidence{{
			Target: "nomad-hvn03", Observation: "an hour old", SourceName: "emisar",
			ObservedAt: time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC),
		}},
	}
	clusters := Clusters(ledgerOf(stale, unresolved("runtime.current_state", "runtime", "nomad-hvn03")))
	if len(clusters) != 1 {
		t.Fatalf("stale evidence did not bind the claim to its target: %d clusters %v",
			len(clusters), identities(clusters))
	}
}

// The order clusters come back in decides which branch is planned first, and a
// map iteration would make that different on every run — which turns a
// reproduction of a live fan-out into a coin flip.
func TestClusterOrderIsStable(t *testing.T) {
	ledger := ledgerOf(
		unresolved("workload.desired_state", "workload", "zeta"),
		unresolved("host.current_state", "host", "alpha"),
		unresolved("dependency.current_health", "dependency", "mid"),
	)
	first := identities(Clusters(ledger))
	for range 20 {
		got := identities(Clusters(ledger))
		if len(got) != len(first) {
			t.Fatalf("cluster count moved between runs: %v then %v", first, got)
		}
		for i := range got {
			if got[i] != first[i] {
				t.Fatalf("cluster order moved between runs: %v then %v", first, got)
			}
		}
	}
}
