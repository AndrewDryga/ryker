package evidencepolicy

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

// A recovered alert could name a root cause with nothing tying it to anything
// observed, and say so in the channel, because the binding rule ran only for a
// confirmed or likely issue. A claim about why something broke needs the same
// support whether or not it is still broken.
// Covers: TestAlertCauseCorrectionRejectsUnboundCauseOnRecoveredAssessment
// Covers finding: 20260812T113223Z-run_7115f6706614a17526ce5db4c7817732
func TestRecoveredAlertMustStillBindTheCauseItNames(t *testing.T) {
	naming := &investigation.AlertAssessment{
		Verdict: "not_issue", Impact: "none",
		Cause: "a leak in the new revision", CauseStatus: "identified",
	}
	if correction := AlertCauseCorrection(naming, nil); correction == "" {
		t.Fatal("a recovered alert named a cause with nothing binding it")
	}

	// Recovered and saying only that it recovered is the ordinary case, and it
	// asserts nothing that needs binding.
	quiet := &investigation.AlertAssessment{Verdict: "not_issue", Impact: "none"}
	if correction := AlertCauseCorrection(quiet, nil); correction != "" {
		t.Fatalf("a recovery that named no cause was corrected: %q", correction)
	}
	// Neither does one that says plainly it could not establish the cause.
	unverified := &investigation.AlertAssessment{
		Verdict: "not_issue", Impact: "none",
		Cause: "possibly memory pressure", CauseStatus: "unverified",
	}
	if correction := AlertCauseCorrection(unverified, nil); correction != "" {
		t.Fatalf("an explicitly unverified cause was corrected: %q", correction)
	}

	// Bound properly, it passes.
	bound := &investigation.AlertAssessment{
		Verdict: "not_issue", Impact: "none",
		Cause: "a leak in the new revision", CauseStatus: "identified",
		CauseClaimIDs: []string{"host.current_state"}, EvidenceRefs: []string{"evidence-host"},
	}
	if correction := AlertCauseCorrection(bound, []core.Evidence{{
		ID: "evidence-host", ClaimID: "host.current_state",
		Observation: "Memory climbed with the new revision and fell after rollback.",
	}}); correction != "" {
		t.Fatalf("a properly bound cause was corrected: %q", correction)
	}
}

// The four tests below all hold the same rule shut, and the rule is not what
// broke. Eight rounds on 2026-08-16, five of them after the day's deploys, each
// one a full re-emission of the result, because the correction never said which
// reference was wrong: every one of them read "the active issue cites absent or
// unrelated cause evidence", so the model had to guess which of its own
// references the host had rejected. It always found it in the end — the
// accepted answers bind their assessments correctly — at 6,000 to 20,000 output
// tokens a guess, on a day whose worst episode spent $8.84 over sixteen turns.
//
// A correction that names the offending id cannot be replaced by a shorter one
// without paying that again. The fixtures are the recorded claim ids and
// evidence-id naming from blitz runs run_ce80c26e8af15a710cdaf9f5fd813e88 and
// run_62721a37b3ff674509802b5dcf087ab9.
func namesEach(t *testing.T, correction string, wanted ...string) {
	t.Helper()
	if correction == "" {
		t.Fatal("a cause the host rejected produced no correction at all")
	}
	for _, want := range wanted {
		if !strings.Contains(correction, want) {
			t.Fatalf("correction never named %q: %q", want, correction)
		}
	}
}

// The usual cause is a renamed or misremembered id, so the ids that do exist
// are the answer the model is looking for.
func TestAnUnresolvedCauseReferenceNamesItAndWhatExists(t *testing.T) {
	assessment := &investigation.AlertAssessment{
		Verdict: "confirmed_issue", Impact: "Traefik allocations sat against their memory cap.",
		Cause:       "The 4,096 MiB cap is below what traefik holds under load.",
		CauseStatus: "identified",
		// The ledger holds neither of these under the id the assessment used.
		CauseClaimIDs: []string{"host.current_state"},
		EvidenceRefs:  []string{"evidence-cause-1"},
	}
	evidence := []core.Evidence{{
		ID: "evidence-growth", ClaimID: "host.current_state",
		Claim:       "Every traefik allocation is now below the alert threshold.",
		Observation: "The alert ratio (RSS + swap) / limit reads nomad-hvn03 92.78%.",
	}, {
		ID: "evidence-cap", ClaimID: "change.recent",
		Claim:       "The deployed revision still carries the 4,096 MiB cap.",
		Observation: "At revision 0997422a traefik.nomad.hcl still declares memory = 4096.",
	}}
	namesEach(t, AlertCauseCorrection(assessment, evidence),
		"evidence-cause-1", "evidence-growth", "evidence-cap")
}

// Two repairs fit this one, and they are not interchangeable: cite a record
// already bound to a named claim, or admit the claim into cause_claim_ids.
func TestAMismatchedCauseReferenceNamesItsClaimAndTheAllowedOnes(t *testing.T) {
	assessment := &investigation.AlertAssessment{
		Verdict: "not_issue", Impact: "Log delivery continued throughout.",
		Cause:         "Three isolated reader_failed events on one Nomad allocation source.",
		CauseStatus:   "identified",
		CauseClaimIDs: []string{"impact.current"},
		EvidenceRefs:  []string{"evidence-vector-application"},
	}
	evidence := []core.Evidence{{
		ID: "evidence-vector-application", ClaimID: "application.functional_behavior",
		Claim:       "Representative user paths work without a current error or timeout spike.",
		Observation: "The frontend-utilities internal endpoint returned HTTP 200 in 0.076 seconds.",
	}}
	namesEach(t, AlertCauseCorrection(assessment, evidence),
		"evidence-vector-application", "application.functional_behavior", "impact.current")
}

// Naming the uncited claim is half the answer; the other half is the set of
// records that already carry it, which the model need not go looking for.
func TestAnUncitedCauseClaimNamesTheEvidenceAvailableForIt(t *testing.T) {
	assessment := &investigation.AlertAssessment{
		Verdict: "confirmed_issue", Impact: "One user-facing backend still fails.",
		Cause:         "The scrapers time out calling the external Gate API.",
		CauseStatus:   "identified",
		CauseClaimIDs: []string{"impact.current", "host.current_state"},
		EvidenceRefs:  []string{"evidence-impact-cleared"},
	}
	evidence := []core.Evidence{{
		ID: "evidence-impact-cleared", ClaimID: "impact.current",
		Claim:       "The memory indicator genuinely recovered rather than oscillating.",
		Observation: "The five traefik cgroups are net -939.4 MiB of RSS over two hours.",
	}, {
		ID: "evidence-host-recovered", ClaimID: "host.current_state",
		Claim:       "Every traefik allocation is now below the alert threshold.",
		Observation: "All five are under the 95% line, against a 96.95% peak at 16:42:19Z.",
	}, {
		ID: "evidence-host-headroom", ClaimID: "host.current_state",
		Claim:       "The busiest allocation holds headroom below its cap.",
		Observation: "It keeps about 295.8 MiB below the 4,096 MiB cap.",
	}}
	correction := AlertCauseCorrection(assessment, evidence)
	namesEach(t, correction,
		"host.current_state", "evidence-host-recovered", "evidence-host-headroom")
	// The evidence for a different claim is not a candidate for this one, and
	// offering it would send the model to bind the wrong record.
	if strings.Contains(correction, "evidence-impact-cleared") {
		t.Fatalf("evidence for another claim was offered as a candidate: %q", correction)
	}
}

// A reference that resolves to a record carrying nothing is a third repair
// again: the observation itself is missing, so no re-citation fixes it.
func TestACauseReferenceToAnEmptyRecordSaysItCarriesNothing(t *testing.T) {
	assessment := &investigation.AlertAssessment{
		Verdict: "confirmed_issue", Impact: "Requests fail.",
		Cause: "The dependency is unavailable.", CauseStatus: "identified",
		CauseClaimIDs: []string{"dependency.current_health"},
		EvidenceRefs:  []string{"evidence-dependency-probe"},
	}
	evidence := []core.Evidence{{
		ID: "evidence-dependency-probe", ClaimID: "dependency.current_health",
		Dimensions: map[string]string{"probe": "failed"},
	}}
	namesEach(t, AlertCauseCorrection(assessment, evidence), "evidence-dependency-probe")
}

// Two fields, two different repairs. Telling a model that named its claims to
// name its claims is how a correction round buys nothing.
func TestAMissingCauseBindingNamesTheFieldThatIsEmpty(t *testing.T) {
	claimed := &investigation.AlertAssessment{
		Verdict: "confirmed_issue", Impact: "Requests fail.",
		Cause: "The dependency is unavailable.", CauseStatus: "identified",
		CauseClaimIDs: []string{"dependency.current_health"},
	}
	correction := AlertCauseCorrection(claimed, nil)
	namesEach(t, correction, "evidence_refs", "dependency.current_health")
	if strings.Contains(correction, "cause_claim_ids is empty") {
		t.Fatalf("a populated cause_claim_ids was reported empty: %q", correction)
	}

	cited := &investigation.AlertAssessment{
		Verdict: "confirmed_issue", Impact: "Requests fail.",
		Cause: "The dependency is unavailable.", CauseStatus: "identified",
		EvidenceRefs: []string{"evidence-dependency-probe"},
	}
	namesEach(t, AlertCauseCorrection(cited, nil), "cause_claim_ids", "evidence-dependency-probe")
}

// The guard. This is the accepted answer from blitz run_ce80c26e8af15a710cdaf9f5fd813e88,
// reached after four rounds; nothing in the rewrite may start correcting it.
func TestACauseBoundToItsOwnEvidenceIsNotCorrected(t *testing.T) {
	assessment := &investigation.AlertAssessment{
		Verdict: "confirmed_issue",
		Impact:  "rivals@consulcatalog fails 90.05% of its own requests on user-facing paths.",
		Cause: "The rivals scrapers time out calling the external Gate API for " +
			"query_match_summary and the backend answers 500 after almost exactly 5.01 s.",
		CauseStatus:   "identified",
		CauseClaimIDs: []string{"application.functional_behavior"},
		EvidenceRefs:  []string{"evidence-app-rivals-now", "evidence-app-rivals-cause"},
	}
	evidence := []core.Evidence{{
		ID: "evidence-app-rivals-now", ClaimID: "application.functional_behavior",
		Claim:       "Ingress is serving normally but rivals still fails about nine requests in ten.",
		Observation: "The websecure entrypoint carries 2,828.5 req/s with a 5xx share of 0.2246%.",
	}, {
		ID: "evidence-app-rivals-cause", ClaimID: "application.functional_behavior",
		Claim:       "The rivals 5xx stream is an external Gate API timeout surfacing through the scraper.",
		Observation: "OriginDuration is pinned between 5.0093 s and 5.0134 s with RetryAttempts 0.",
	}, {
		ID: "evidence-change-cap", ClaimID: "change.recent",
		Claim:       "The deployed revision still carries the 4,096 MiB cap.",
		Observation: "At revision 0997422a traefik.nomad.hcl still declares memory = 4096.",
	}}
	if correction := AlertCauseCorrection(assessment, evidence); correction != "" {
		t.Fatalf("an accepted, fully bound assessment was corrected: %q", correction)
	}
}
