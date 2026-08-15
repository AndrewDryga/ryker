package investigation

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Harvested from tenant run_3a615b9db928d7b5f1462c660b43cb89: nineteen
// correction rounds in twenty-two minutes, every one of them class
// `incomplete`, on an alert that had already recovered.
//
// The run is the whole cost of this file in one row: started_at
// 03:21:49Z, completed_at 03:45:43Z, failure_count 19. Thirteen rounds were
// contradiction whack-a-mole on change.recent, four were "stale" on evidence
// the loop itself aged out, and at round 15 the host told the model the answer
// outright — "fresh evidence verifies the alert condition recovered; return
// decision_ready with the healthy verdict" — and it still needed four more
// rounds. Understanding was never the blocker. The correction withheld the
// information needed to act on it.
//
// The same shape ran on run_3c5418076 (19 rounds), run_03d30c2f (19),
// run_806c9593 (18), run_006e593a (18) and run_f7e37eb4 (17). 257 `incomplete`
// corrections in two days, dominated by this loop, each round resubmitting a
// ~146KB briefing.
const (
	// The exact record the loop kept naming as the contradicting side, from
	// evidence.id ev_1e8a0e8029fe43e3685c5e924b2735df. Its truncated prose is
	// the "contradicted by:" clause in ten of the nineteen recorded rounds.
	replayConflictingID   = "ev_1e8a0e8029fe43e3685c5e924b2735df"
	replayConflictingText = "tenant-infra run-o2BA7juuNF9VKQCV applied, while va1-apps " +
		"run-UEi6Q77Gdi7CpRB6 exited 1 after cms-server, cms-web, and payments missed their " +
		"healthy deadline and rolled back; this partial rollout affected nomad-hst03 and is " +
		"separate from the nomad-hst02 sdb alert."
	replayConflictingSource = "TFC agent and Nomad allocation events"

	// The supporting side the model rewrote every round trying to guess which
	// half of the disagreement the host wanted retired.
	replaySupportingID   = "ev_9c22f1a740bb2ec1f0dd42a1c8b6e5aa"
	replaySupportingText = "The saved plan for run-b3d4iNqNaNqj654q contained one in-place " +
		"update to module.realtime_gateway.nomad_job.app, with no creates, deletes, " +
		"replacements, or drift outside that module."
	replaySupportingSource = "HCP Terraform plan summary"
)

// recordedContradictionRounds is the change.recent clause of every recorded
// round that carried one, in order. Rounds 13, 14, 16 and 17 carry no
// supporting side at all: the model had replaced its own support while chasing
// the conflict, and the correction never said so — it kept quoting the
// contradiction alone, which reads as though the support were still there.
var recordedContradictionRounds = []string{
	"change.recent (The saved plan for run-b3d4iNqNaNqj654q contained one in-place update to module.realtime_gateway.nomad_job.app, with no creates, deletes, replacements, or dr... [HCP Terraform plan summary] — contradicted by: For revision 0f0fdcdbc2ef310206612573eb8eb7a01e1ed086, tenant-infra applied while va1-apps rolled back cms-server, cms-web, and payments. The older cbffff22 r... [Terraform agent and Nomad rollout evidence])",
	"change.recent (The saved plan for run-b3d4iNqNaNqj654q contained one in-place update to module.realtime_gateway.nomad_job.app, with no creates, deletes, replacements, or dr... [HCP Terraform plan summary] — contradicted by: tenant-infra applied revision 0f0fdcdbc2ef310206612573eb8eb7a01e1ed086, while va1-apps rolled back cms-server, cms-web, and payments after missed healthy dead... [Terraform agent and Nomad rollout evidence])",
	"change.recent (The saved plan for run-b3d4iNqNaNqj654q contained one in-place update to module.realtime_gateway.nomad_job.app, with no creates, deletes, replacements, or dr... [HCP Terraform plan summary] — contradicted by: tenant-infra run-o2BA7juuNF9VKQCV applied, while va1-apps run-UEi6Q77Gdi7CpRB6 exited 1 after cms-server, cms-web, and payments missed their healthy deadline ... [TFC agent and Nomad allocation events])",
	"change.recent (contradicted by: A reconciliation of run-b3d4iNqNaNqj654q shows it belongs to revision cbffff22148ccf70b03836ea04568f2faa9f8d45. Revision 0f0fdcdbc2ef310206612573eb8eb7a01e1e... [HCP Terraform plan summary])",
	"change.recent (Revision 0f0fdcdbc2ef310206612573eb8eb7a01e1ed086 applied in tenant-infra. In va1-apps, cms-server, cms-web, and payments missed their healthy deadline and No... [Terraform agent and Nomad rollout evidence] — contradicted by: tenant-infra run-o2BA7juuNF9VKQCV applied, while va1-apps run-UEi6Q77Gdi7CpRB6 exited 1 after cms-server, cms-web, and payments missed their healthy deadline ... [TFC agent and Nomad allocation events])",
	"change.recent (contradicted by: For revision 0f0fdcdbc2ef310206612573eb8eb7a01e1ed086, tenant-infra run-o2BA7juuNF9VKQCV applied, while va1-apps run-UEi6Q77Gdi7CpRB6 exited 1 after cms-serve... [Terraform agent, Nomad rollout evidence, and HCP run reconciliation])",
	"change.recent (tenant-infra run-o2BA7juuNF9VKQCV applied. In va1-apps, cms-server, cms-web, and payments missed their healthy deadline and Nomad restored their previous heal... [TFC agent and Nomad rollback reconciliation] — contradicted by: tenant-infra run-o2BA7juuNF9VKQCV applied, while va1-apps run-UEi6Q77Gdi7CpRB6 exited 1 after cms-server, cms-web, and payments missed their healthy deadline ... [TFC agent and Nomad allocation events])",
	"change.recent (Revision 0f0fdcdbc2ef310206612573eb8eb7a01e1ed086 changed application images. The va1-apps failure involved cms-server, cms-web, and payments allocations on ... [TFC agent and Nomad allocation events] — contradicted by: tenant-infra run-o2BA7juuNF9VKQCV applied, while va1-apps run-UEi6Q77Gdi7CpRB6 exited 1 after cms-server, cms-web, and payments missed their healthy deadline ... [TFC agent and Nomad allocation events])",
	"change.recent (contradicted by: tenant-infra run-o2BA7juuNF9VKQCV applied, while va1-apps run-UEi6Q77Gdi7CpRB6 exited 1 after cms-server, cms-web, and payments missed their healthy deadline ... [TFC agent and Nomad allocation events])",
}

func replayChangeContract() InvestigationContract {
	return InvestigationContract{
		Claims: []ClaimRequirement{{
			ID: "change.recent", Layer: "change", Required: true,
		}},
		Completion: CompletionRule{ConclusionKind: "operational_health"},
	}
}

// The recorded round-2 ledger: one supporting statement and one contradicting
// statement on change.recent, with the contradiction observed after the
// support, and healthy change coverage. This is the state the host rejected
// seventeen more times.
func replayRoundTwoLedger(now time.Time) Ledger {
	evidence := []core.Evidence{
		{
			ID: replaySupportingID, ClaimID: "change.recent", Relation: "supports",
			Observation: replaySupportingText, SourceName: replaySupportingSource,
			SourceType: "monitoring", ObservedAt: now.Add(-40 * time.Minute),
			Confidence: "high",
		},
		{
			ID: replayConflictingID, ClaimID: "change.recent", Relation: "contradicts",
			Observation: replayConflictingText, SourceName: replayConflictingSource,
			SourceType: "monitoring", ObservedAt: now.Add(-20 * time.Minute),
			Confidence: "high", HealthEffect: "risk",
		},
	}
	coverage := []core.Coverage{{
		Layer: "change", Status: "healthy", ClaimIDs: []string{"change.recent"},
		Detail:     "the alert condition cleared and the rollout reconciled",
		ObservedAt: now.Add(-time.Minute),
	}}
	return BuildLedger(replayChangeContract(), evidence, coverage, now)
}

// A correction that names a conflict must carry the conflict, not a bounded
// glimpse of one side of it.
//
// The recorded rounds show the failure exactly: the host quotes ONE
// contradicting observation, truncated to 160 runes, with no evidence id. The
// model cannot address a record it cannot name, so it rewrote the claim
// instead, hit a different pairwise conflict, and the host quoted that one —
// nine distinct change.recent clauses across the run, thirteen rounds, and the
// underlying disagreement never moved.
//
// Covers: TestContradictionCorrectionCarriesEveryConflictingStatement
func TestACorrectionNamesEveryConflictingStatementWithItsEvidenceID(t *testing.T) {
	now := time.Date(2026, 8, 15, 3, 44, 0, 0, time.UTC)
	ledger := replayRoundTwoLedger(now)

	correction := ledger.CompletionCorrectionFor("decision_ready", "healthy")
	if correction == "" {
		t.Fatal("the recorded round-2 answer was accepted; the replay no longer reproduces the loop")
	}

	// The identity of both sides, which is the whole information the model was
	// missing: it cannot retract or supersede a record it cannot name.
	for _, want := range []string{replayConflictingID, replaySupportingID} {
		if !strings.Contains(correction, want) {
			t.Fatalf(
				"the correction does not name evidence id %q, so the model cannot say "+
					"which record it is retiring:\n%s",
				want, correction,
			)
		}
	}

	// Both sides quoted, and quoted whole. The recorded corrections cut every
	// observation at 160 runes mid-word, so the model was matching prefixes.
	for _, want := range []string{replayConflictingText, replaySupportingText} {
		if !strings.Contains(correction, want) {
			t.Fatalf("the correction does not quote %q verbatim:\n%s", want, correction)
		}
	}

	// The three moves that close a conflict. Without them the model's only
	// visible option is to restate the claim, which is what it did.
	for _, want := range []string{"retract", "supersede", "reconcile"} {
		if !strings.Contains(strings.ToLower(correction), want) {
			t.Fatalf("the correction does not offer the %q resolution:\n%s", want, correction)
		}
	}
}

// A contradicted claim whose support the model has already replaced must say
// so. Four recorded rounds — 13, 14, 16 and 17 — rendered as
// "change.recent (contradicted by: …)" with no asserted side, because
// view.Evidence was empty. Read plainly that says "your claim conflicts with
// this", when what it means is "nothing supports this claim at all". Those are
// different repairs, and the model made neither.
func TestAClaimWithNoSupportingStatementSaysSoRatherThanQuotingOnlyTheConflict(t *testing.T) {
	now := time.Date(2026, 8, 15, 3, 42, 0, 0, time.UTC)
	view := ClaimView{
		Requirement: ClaimRequirement{ID: "change.recent", Layer: "change", Required: true},
		State:       ClaimContradicted,
		Contradictions: []core.Evidence{{
			ID: replayConflictingID, Observation: replayConflictingText,
			SourceName: replayConflictingSource, ObservedAt: now.Add(-20 * time.Minute),
		}},
	}
	detail := contradictionDetail(view)
	if !strings.Contains(detail, replayConflictingID) {
		t.Fatalf("the sole conflicting record is not named by id:\n%s", detail)
	}
	if !strings.Contains(strings.ToLower(detail), "no supporting") {
		t.Fatalf(
			"a claim with an empty supporting side must say the support is missing, "+
				"not quote the conflict alone:\n%s",
			detail,
		)
	}
}

// Evidence fresh when the attempt chain began stays fresh for every correction
// round of that chain.
//
// Four of the nineteen rounds were "required claims do not have fresh
// supporting evidence: … (stale)". Nothing about the world went stale — the
// loop did. The chain started at 03:21:49Z, the model observed the cluster at
// 03:28:47Z, and by round 19 at 03:44 that reading was sixteen minutes old
// against a ten-minute window. The model watched its own evidence expire and
// renamed the records to match: the harvested rows are literally
// `evidence-host-expired`, `evidence-scheduler-expired`,
// `evidence-workload-expired` and `evidence-application-expired`, each with an
// observation explaining that the snapshot "is now outside the required
// ten-minute window".
//
// Two validators ping-ponged: fixing a contradiction aged the evidence, and
// refreshing the evidence resurfaced the contradiction.
//
// Covers: TestEvidenceFreshnessIsJudgedAtAttemptChainStart
func TestEvidenceFreshAtChainStartStaysFreshForEveryCorrectionRound(t *testing.T) {
	chainStart := time.Date(2026, 8, 15, 3, 21, 49, 0, time.UTC)
	round19 := time.Date(2026, 8, 15, 3, 44, 10, 0, time.UTC)
	observed := time.Date(2026, 8, 15, 3, 28, 47, 0, time.UTC)

	contract := InvestigationContract{
		Claims: []ClaimRequirement{{
			ID: "workload.desired_state", Layer: "workload", Required: true,
			Freshness: FreshnessRequirement{Class: "live", MaxAge: 10 * time.Minute},
		}},
		Completion: CompletionRule{ConclusionKind: "operational_health"},
	}
	evidence := []core.Evidence{{
		ID: "evidence-workload-live", ClaimID: "workload.desired_state", Relation: "supports",
		Observation: "The realtime-gateway allocation and sampled active allocations were " +
			"running with DesiredStatus run.",
		SourceName: "Emisar Nomad workload snapshot", SourceType: "emisar",
		ObservedAt: observed, Confidence: "high",
	}}
	coverage := []core.Coverage{{
		Layer: "workload", Status: "healthy", ClaimIDs: []string{"workload.desired_state"},
		Detail: "sampled VA1 allocations running as desired", ObservedAt: observed,
	}}

	// The recorded behaviour: judged against the wall clock of round 19, a
	// reading taken during round 3 is stale and the turn goes back.
	wallClock := BuildLedger(contract, evidence, coverage, round19)
	if got := wallClock.CompletionCorrectionFor("decision_ready", "healthy"); got == "" {
		t.Fatal("the replay no longer reproduces the freshness ping-pong")
	}

	// Judged at the start of the attempt chain, the same reading is what it
	// was when the model took it: fresh.
	chained := BuildLedgerForChain(contract, evidence, coverage, round19, chainStart)
	if got := chained.CompletionCorrectionFor("decision_ready", "healthy"); got != "" {
		t.Fatalf(
			"evidence taken inside the attempt chain was still judged stale at round 19: %q",
			got,
		)
	}
}

// Freshness anchored at chain start must not resurrect evidence that was
// already stale when the chain began. The rejected alternative was widening
// the window globally, which weakens exactly this case: a first try quoting a
// reading from an hour ago is genuinely stale and must still be told so.
func TestEvidenceAlreadyStaleWhenTheChainBeganIsStillStale(t *testing.T) {
	chainStart := time.Date(2026, 8, 15, 3, 21, 49, 0, time.UTC)
	contract := InvestigationContract{
		Claims: []ClaimRequirement{{
			ID: "workload.desired_state", Layer: "workload", Required: true,
			Freshness: FreshnessRequirement{Class: "live", MaxAge: 10 * time.Minute},
		}},
		Completion: CompletionRule{ConclusionKind: "operational_health"},
	}
	evidence := []core.Evidence{{
		ID: "evidence-workload-old", ClaimID: "workload.desired_state", Relation: "supports",
		Observation: "sampled allocations running as desired",
		SourceName:  "Emisar Nomad workload snapshot", SourceType: "emisar",
		ObservedAt: chainStart.Add(-time.Hour), Confidence: "high",
	}}
	coverage := []core.Coverage{{
		Layer: "workload", Status: "healthy", ClaimIDs: []string{"workload.desired_state"},
		Detail: "sampled VA1 allocations running as desired", ObservedAt: chainStart,
	}}
	ledger := BuildLedgerForChain(
		contract, evidence, coverage, chainStart.Add(2*time.Minute), chainStart,
	)
	correction := ledger.CompletionCorrectionFor("decision_ready", "healthy")
	if !strings.Contains(correction, "stale") {
		t.Fatalf(
			"an hour-old reading quoted on the first try must still be called stale, got %q",
			correction,
		)
	}
}

// The recorded loop, replayed end to end: the old correction repeated one
// claim id nine different ways and never named a record, and the new one
// closes the same conflict in a single round.
//
// The verdict this test carries: the recorded round-2 answer is NOT acceptable
// as written — change.recent really is contradicted, and no correction text
// can make a contradicted ledger consistent. What the recorded correction
// withheld is the information needed to act in one round, and this names it:
// the evidence id of each conflicting record, and the fact that superseding
// means recording a replacement observed AFTER the record it retires. Given
// both, the round-2 answer plus one supersession clears the ledger.
func TestTheRecordedNineteenRoundLoopClosesInOneRoundWithTheFullConflict(t *testing.T) {
	now := time.Date(2026, 8, 15, 3, 44, 0, 0, time.UTC)

	// What the recorded corrections actually carried: no evidence id anywhere
	// across nine distinct clauses for one claim.
	for round, clause := range recordedContradictionRounds {
		if strings.Contains(clause, "ev_") || strings.Contains(clause, "evidence-") {
			t.Fatalf("recorded round %d unexpectedly named an evidence id: %s", round+1, clause)
		}
	}

	// The resolution the new correction prescribes, applied once: supersede the
	// conflicting record with a replacement observed after it. Everything else
	// about the round-2 answer is unchanged.
	evidence := []core.Evidence{
		{
			ID: replaySupportingID, ClaimID: "change.recent", Relation: "supports",
			Observation: replaySupportingText, SourceName: replaySupportingSource,
			SourceType: "monitoring", ObservedAt: now.Add(-40 * time.Minute),
			Confidence: "high",
		},
		{
			ID: replayConflictingID, ClaimID: "change.recent", Relation: "contradicts",
			Observation: replayConflictingText, SourceName: replayConflictingSource,
			SourceType: "monitoring", ObservedAt: now.Add(-20 * time.Minute),
			Confidence: "high", HealthEffect: "risk",
		},
		{
			ID: "ev_supersedes_o2BA", ClaimID: "change.recent", Relation: "supports",
			Observation: "Superseding " + replayConflictingID + ": the va1-apps rollback " +
				"completed and both workspaces now report revision " +
				"0f0fdcdbc2ef310206612573eb8eb7a01e1ed086 converged.",
			SourceName: replayConflictingSource, SourceType: "monitoring",
			ObservedAt: now.Add(-5 * time.Minute), Confidence: "high",
		},
	}
	coverage := []core.Coverage{{
		Layer: "change", Status: "healthy", ClaimIDs: []string{"change.recent"},
		Detail:     "the alert condition cleared and the rollout reconciled",
		ObservedAt: now.Add(-time.Minute),
	}}
	ledger := BuildLedger(replayChangeContract(), evidence, coverage, now)
	if got := ledger.CompletionCorrectionFor("decision_ready", "healthy"); got != "" {
		t.Fatalf(
			"one supersession did not close the recorded conflict, so the correction "+
				"still does not say enough to finish in one round: %q",
			got,
		)
	}
}
