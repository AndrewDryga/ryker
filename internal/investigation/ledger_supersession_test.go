package investigation

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Harvested from run 3 of the post-c07462c repro of the eval-prompts case
// "alert triage returns an alert assessment", 2026-08-15.
//
// The correction 79445e8 introduced tells the model to resolve a conflict one
// of three ways, one of them "supersede it with a record_evidence observed
// AFTER the record it retires". The live model did exactly that: for
// change.recent it recorded two replacements whose observations open
// "Supersedes evidence-change-repo." and "Supersedes evidence-change-live.",
// each observed after the record it names. The ledger went on listing both
// originals under "contradicted by:" and refused the completion again, every
// retry, until the budget ran out — because `supersed` appeared nowhere in
// ledger.go except inside the correction string. The host prescribed a move it
// did not implement, which is worse than prescribing nothing: the model spends
// its whole budget making the move that cannot work.
//
// Harvested: the four ids, their relations, their observation instants and
// their sources. The observation prose carries the recorded opening sentence of
// each replacement; the remainder and the coverage row are this test's, and the
// coverage row is the "unknown" the case records because the model could not
// map a Sentry release to a commit — the same row c07462c found holding this
// claim open.
const (
	supersededRepoID   = "evidence-change-repo"
	supersededLiveID   = "evidence-change-live"
	supersedingRepoID  = "evidence-change-repo-superseded"
	supersedingLiveID  = "evidence-change-live-superseded"
	supersededRepoText = "At repository commit cd8c8a1dce9ea29b57666f4621418c1a51999d7d, " +
		"Terraform declares the global `emisar-https` URL map with an " +
		"`emisar-<readiness_generation>-backend` regional MIG backend, which the live " +
		"backend service does not match."
	supersededLiveText = "The live `emisar-https` URL map resolves to a backend service whose " +
		"MIG differs from the declared readiness generation."
)

// alertTriageSupersessionEvidence is the recorded change.recent envelope: two
// contradicting statements, and the two replacements the model recorded after
// being told to supersede them. `retire` selects whether the replacements carry
// the typed supersedes the correction now names, so one function serves both
// the recorded behaviour and the repaired one.
//
// The replacements carry the reconciled revision rather than the revision they
// retire, following the same shape as the reconciling record harvested for
// c07462c. That is not decoration: correlation staleness keys on claim, source
// and every dimension value, so a replacement identical in all of them would
// age its original out as a duplicate reading and the envelope would stop
// reproducing the recorded correction — which quoted both originals live, under
// "contradicted by:", after the replacements had been recorded.
func alertTriageSupersessionEvidence(retire bool) []core.Evidence {
	day := func(hour, minute, second int) time.Time {
		return time.Date(2026, 8, 15, hour, minute, second, 0, time.UTC)
	}
	supersedes := func(id string) []string {
		if !retire {
			return nil
		}
		return []string{id}
	}
	return []core.Evidence{
		{
			ID: supersededRepoID, ClaimID: "change.recent", Relation: "contradicts",
			Observation: supersededRepoText,
			SourceType:  "repository", SourceName: "Emisar infra load-balancer configuration",
			ObservedAt: day(7, 24, 30), Confidence: "high", HealthEffect: "risk",
			Dimensions: map[string]string{
				"repository": "emisar", "environment": "production",
				"revision": "cd8c8a1dce9ea29b57666f4621418c1a51999d7d",
			},
		},
		{
			ID: supersededLiveID, ClaimID: "change.recent", Relation: "contradicts",
			Observation: supersededLiveText,
			SourceType:  "emisar", SourceName: "Emisar live backend service and MIG inspection",
			ObservedAt: day(7, 25, 58), Confidence: "high", HealthEffect: "risk",
			Dimensions: map[string]string{
				"repository": "emisar", "environment": "production", "revision": "live",
			},
		},
		{
			ID: supersedingRepoID, ClaimID: "change.recent", Relation: "supports",
			Observation: "Supersedes " + supersededRepoID + ". Re-read at the same commit, the " +
				"declared URL map names the readiness-generation backend the live service " +
				"resolves to; the earlier reading compared two different generations.",
			SourceType: "repository", SourceName: "Emisar infra load-balancer configuration",
			ObservedAt: day(7, 26, 41), Confidence: "high", HealthEffect: "none",
			Supersedes: supersedes(supersededRepoID),
			Dimensions: map[string]string{
				"repository": "emisar", "environment": "production",
				"revision": "readiness generation reconciled",
			},
		},
		{
			ID: supersedingLiveID, ClaimID: "change.recent", Relation: "supports",
			Observation: "Supersedes " + supersededLiveID + ". The live backend service " +
				"resolves to the declared readiness generation, so the topology agrees with " +
				"repository intent.",
			SourceType: "emisar", SourceName: "Emisar live backend service and MIG inspection",
			ObservedAt: day(7, 26, 42), Confidence: "high", HealthEffect: "none",
			Supersedes: supersedes(supersededLiveID),
			Dimensions: map[string]string{
				"repository": "emisar", "environment": "production",
				"revision": "live readiness generation reconciled",
			},
		},
	}
}

// alertTriageSupersessionLedger builds the recorded change.recent ledger. The
// coverage status is the row the case records, so a caller can watch the claim
// close once its evidence stops disagreeing with itself.
func alertTriageSupersessionLedger(retire bool, coverageStatus string) Ledger {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortIncidentInvestigation, RequiredCoverage: []string{"change"},
	})
	coverage := []core.Coverage{{
		Layer: "change", Status: coverageStatus, ClaimIDs: []string{"change.recent"},
		Detail: "The live backend matches the declared topology after the two earlier " +
			"readings were reconciled.",
		ObservedAt: time.Date(2026, 8, 15, 7, 26, 45, 0, time.UTC),
	}}
	return BuildLedger(
		contract,
		alertTriageSupersessionEvidence(retire),
		coverage,
		time.Date(2026, 8, 15, 7, 27, 0, 0, time.UTC),
	)
}

// A record another record supersedes stops being a live contradiction.
//
// This is the whole defect: the correction prescribed supersession, the model
// performed it, and the ledger had no supersession semantics at all — `grep -n
// supersed internal/investigation/ledger.go` matched only the correction text.
// Every retry re-read the same two retired statements back as live conflicts
// and the episode looped to its budget. A correction naming a move the
// receiving side does not implement is a host bug, not a prompt one.
func TestASupersededRecordStopsBeingALiveContradiction(t *testing.T) {
	// The recorded behaviour: the model's replacements are ignored and both
	// originals are still quoted as the conflict.
	recorded := alertTriageSupersessionLedger(false, "unknown")
	view := recorded.Claims["change.recent"]
	if len(view.Contradictions) != 2 {
		t.Fatalf(
			"the harvested envelope no longer records two contradicting statements: %+v",
			view.Contradictions,
		)
	}
	correction := recorded.CompletionCorrectionFor("decision_ready", "healthy")
	if !strings.Contains(correction, "unresolved contradictions") {
		t.Fatalf("the replay no longer reproduces the refusal:\n%s", correction)
	}
	for _, want := range []string{supersededRepoID, supersededLiveID} {
		if !strings.Contains(correction, want) {
			t.Fatalf("the recorded correction does not quote %q:\n%s", want, correction)
		}
	}

	// The same answer with the typed supersedes the correction now names. The
	// two originals are retired, so nothing on this claim disagrees with
	// anything, and the completion is no longer refused for a contradiction.
	repaired := alertTriageSupersessionLedger(true, "unknown")
	view = repaired.Claims["change.recent"]
	if len(view.Contradictions) != 0 {
		t.Fatalf(
			"a record named in a later record's supersedes is still a live contradiction: %+v",
			view.Contradictions,
		)
	}
	correction = repaired.CompletionCorrectionFor("decision_ready", "healthy")
	for _, forbidden := range []string{"unresolved contradictions", conflictResolutions} {
		if strings.Contains(correction, forbidden) {
			t.Fatalf(
				"a claim whose conflict was superseded is still corrected with %q:\n%s",
				forbidden, correction,
			)
		}
	}

	// And with the coverage row the claim's own evidence now establishes, it
	// closes — one round, which is what the correction promised.
	closed := alertTriageSupersessionLedger(true, "healthy").
		CompletionCorrectionFor("decision_ready", "healthy")
	if closed != "" {
		t.Fatalf("the superseded ledger still refuses a healthy completion: %q", closed)
	}
}

// "Observed after" alone never retires anything.
//
// The correction's own words are "a record_evidence observed AFTER the record
// it retires", and reading that as the rule would be the dangerous half of this
// change: an investigation records dozens of observations against one claim,
// and the newest of them is almost never a judgement about the oldest. A later
// record that names nothing retires nothing, however recent it is.
func TestALaterRecordThatNamesNothingRetiresNoContradiction(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortIncidentInvestigation, RequiredCoverage: []string{"change"},
	})
	observed := time.Date(2026, 8, 15, 7, 24, 30, 0, time.UTC)
	evidence := []core.Evidence{
		{
			ID: supersededRepoID, ClaimID: "change.recent", Relation: "contradicts",
			Observation: supersededRepoText, SourceType: "repository",
			SourceName: "Emisar infra load-balancer configuration",
			ObservedAt: observed, Confidence: "high", HealthEffect: "risk",
		},
		{
			// A perfectly ordinary later observation about the same claim, with
			// no opinion whatsoever about the record above it.
			ID: "evidence-change-release", ClaimID: "change.recent", Relation: "supports",
			Observation: "Sentry listed 0.39.0 as the newest release signal, created " +
				"2026-08-12T03:09:00Z.",
			SourceType: "emisar", SourceName: "Sentry releases via Emisar",
			ObservedAt: observed.Add(3 * time.Minute), Confidence: "medium",
		},
	}
	coverage := []core.Coverage{{
		Layer: "change", Status: "unknown", ClaimIDs: []string{"change.recent"},
		Detail: "the deployed commit remains unresolved", ObservedAt: observed,
	}}
	ledger := BuildLedger(contract, evidence, coverage, observed.Add(5*time.Minute))
	view := ledger.Claims["change.recent"]
	if len(view.Contradictions) != 1 || view.Contradictions[0].ID != supersededRepoID {
		t.Fatalf(
			"a later record carrying no supersedes silently retired an earlier "+
				"contradiction: %+v",
			view.Contradictions,
		)
	}
	if len(view.Superseded) != 0 {
		t.Fatalf("nothing was superseded, yet the ledger retired: %+v", view.Superseded)
	}
}

// A supersedes the ledger cannot honour is refused out loud, never in silence.
//
// Two ways it cannot: the named record is not one this claim holds, or the
// retiring record was not observed after it. Both leave the conflict live, and
// a model that is not told which one it hit repeats the move it already made —
// which is the exact loop this whole change exists to end. Silence here would
// reproduce the original bug with a typed field instead of a missing rule.
func TestASupersedesTheLedgerCannotHonourIsRefusedByName(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortIncidentInvestigation, RequiredCoverage: []string{"change"},
	})
	observed := time.Date(2026, 8, 15, 7, 24, 30, 0, time.UTC)
	coverage := []core.Coverage{{
		Layer: "change", Status: "unknown", ClaimIDs: []string{"change.recent"},
		Detail: "the deployed commit remains unresolved", ObservedAt: observed,
	}}
	conflict := core.Evidence{
		ID: supersededRepoID, ClaimID: "change.recent", Relation: "contradicts",
		Observation: supersededRepoText, SourceType: "repository",
		SourceName: "Emisar infra load-balancer configuration",
		ObservedAt: observed, Confidence: "high", HealthEffect: "risk",
	}
	// The reconciled revision keeps the replacement off the conflict's
	// correlation key, so what this test observes is the supersession rule and
	// not the duplicate-reading rule beside it.
	replacement := func(id string, at time.Time, supersedes string) core.Evidence {
		return core.Evidence{
			ID: id, ClaimID: "change.recent", Relation: "supports",
			Observation: "Supersedes " + supersedes + ". The declared and live topologies agree.",
			SourceType:  "repository", SourceName: "Emisar infra load-balancer configuration",
			ObservedAt: at, Confidence: "high", Supersedes: []string{supersedes},
			Dimensions: map[string]string{"revision": "readiness generation reconciled"},
		}
	}

	// The asserted refusals are the host's own words, never a fragment the
	// model's prose could supply: every replacement below opens "Supersedes
	// <id>.", so a check that only looked for the ids would pass against a host
	// that said nothing at all.
	for _, testCase := range []struct {
		name     string
		target   string
		evidence []core.Evidence
		refusal  string
	}{
		{
			// The id is not one this claim holds. A typo, a claim boundary
			// crossed, or a record from a turn whose evidence never landed.
			name: "names a record this claim does not hold", target: "evidence-change-repos",
			evidence: []core.Evidence{
				conflict,
				replacement(supersedingRepoID, observed.Add(time.Minute), "evidence-change-repos"),
			},
			refusal: "is not a record on this claim",
		},
		{
			// Observed before the record it claims to retire. Letting this
			// through would let an older reading bury a newer disagreement,
			// which is the opposite of what supersession means.
			name: "was observed before the record it retires", target: supersededRepoID,
			evidence: []core.Evidence{
				conflict,
				replacement(supersedingRepoID, observed.Add(-time.Minute), supersededRepoID),
			},
			refusal: "strictly later than the record it retires",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			ledger := BuildLedger(contract, testCase.evidence, coverage, observed.Add(time.Hour))
			view := ledger.Claims["change.recent"]
			if len(view.Contradictions) != 1 {
				t.Fatalf(
					"a supersedes the ledger cannot honour retired the conflict anyway: %+v",
					view.Contradictions,
				)
			}
			correction := ledger.CompletionCorrectionFor("decision_ready", "healthy")
			if !strings.Contains(correction, "unresolved contradictions") {
				t.Fatalf("the conflict is live but the host did not say so:\n%s", correction)
			}
			for _, want := range []string{
				supersedingRepoID + " supersedes " + testCase.target, testCase.refusal,
			} {
				if !strings.Contains(correction, want) {
					t.Fatalf(
						"the correction does not say why the supersession was not honoured "+
							"(missing %q):\n%s",
						want, correction,
					)
				}
			}
		})
	}
}

// A supersession the ledger did honour is quoted as retired, not forgotten.
//
// When a claim still holds another live conflict, the model needs to see that
// its previous supersession landed — otherwise the next round re-supersedes a
// record that is already retired and the conflict it has not addressed stays
// exactly where it was. Four rounds of the recorded nineteen were spent on
// repairs the host had already accepted without saying so.
func TestARetiredRecordIsQuotedAsRetiredBesideTheConflictThatRemains(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortIncidentInvestigation, RequiredCoverage: []string{"change"},
	})
	observed := time.Date(2026, 8, 15, 7, 24, 30, 0, time.UTC)
	evidence := append(alertTriageSupersessionEvidence(true), core.Evidence{
		ID: "evidence-change-drift", ClaimID: "change.recent", Relation: "contradicts",
		Observation: "A third reading found the readiness generation still drifting.",
		SourceType:  "emisar", SourceName: "Emisar live backend service and MIG inspection",
		ObservedAt: observed.Add(4 * time.Minute), Confidence: "high", HealthEffect: "degraded",
	})
	coverage := []core.Coverage{{
		Layer: "change", Status: "unknown", ClaimIDs: []string{"change.recent"},
		Detail: "the deployed commit remains unresolved", ObservedAt: observed,
	}}
	correction := BuildLedger(contract, evidence, coverage, observed.Add(time.Hour)).
		CompletionCorrectionFor("decision_ready", "healthy")
	if !strings.Contains(correction, "evidence-change-drift") {
		t.Fatalf("the remaining conflict is not named:\n%s", correction)
	}
	for _, want := range []string{supersededRepoID, supersedingRepoID} {
		if !strings.Contains(correction, want) {
			t.Fatalf(
				"a supersession the host honoured is invisible to the model (missing %q), so "+
					"the next round repeats it:\n%s",
				want, correction,
			)
		}
	}
	if strings.Contains(correction, "contradicted by: "+supersededRepoText) {
		t.Fatalf("a retired record is still quoted as a live contradiction:\n%s", correction)
	}
}
