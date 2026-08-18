package investigation

import (
	"strings"
	"testing"
)

// A finding is the keystone of root-cause-by-default, so its validator is the
// one place a malformed one can still be refused where the model reads the
// answer.
//
// The cost this is holding shut: on 2026-08-11 the 12:16 Zot triage
// (episode_run_ebbee0227d72743cc4aee48ef01113ba) closed decision_ready/succeeded
// on a Terraform Run-Applied event while its reply said VA1 pyke "did not
// deploy: its rollout missed the progress deadline and automatically rolled back
// to job version 5". The rollback lived only in prose, no contract could see it,
// and three human nudges over 88 minutes bought a root cause a deep dive then
// found in four. Every rule below exists so that a finding cannot be recorded in
// a shape that says less than that prose did.
func TestAFindingCannotClaimMoreThanItRecords(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		finding FindingOperation
		want    string
	}{
		{
			name:    "a finding with no failure state names nothing",
			finding: FindingOperation{Status: "unexplained"},
			want:    "what failed",
		},
		{
			name: "an unlisted status is quoted back with the set",
			finding: FindingOperation{
				What: "VA1 pyke did not deploy", Status: "probably_fine",
			},
			want: "unexplained, explained, expected, out_of_scope",
		},
		{
			name:    "an empty status is refused like an unlisted one",
			finding: FindingOperation{What: "VA1 pyke did not deploy"},
			want:    "unexplained, explained, expected, out_of_scope",
		},
		{
			// The whole point of the status. "explained" with nothing behind it
			// is the prose claim this operation exists to replace.
			name: "explained without cause evidence is an assertion",
			finding: FindingOperation{
				What: "VA1 pyke did not deploy", Status: "explained",
			},
			want: "cause_evidence",
		},
		{
			name: "a blank cause evidence id does not count as one",
			finding: FindingOperation{
				What: "VA1 pyke did not deploy", Status: "explained",
				CauseEvidence: []string{"   "},
			},
			want: "cause_evidence",
		},
		{
			// expected and out_of_scope are the two ways to stop. Both are
			// reviewable later, and a classification with no sentence behind it
			// is not reviewable at all.
			name: "expected without a reason is an unauditable silence",
			finding: FindingOperation{
				What: "the nightly batch job restarted", Status: "expected",
			},
			want: "reason",
		},
		{
			name: "out_of_scope without a reason is refused the same way",
			finding: FindingOperation{
				What: "a partner API returned 500", Status: "out_of_scope",
			},
			want: "reason",
		},
		{
			name: "an alternative with no hypothesis names no rival",
			finding: FindingOperation{
				What: "VA1 pyke did not deploy", Status: "explained",
				CauseEvidence: []string{"evidence-va1-errored"},
				Alternatives:  []FindingAlternative{{DiscriminatedBy: "evidence-1"}},
			},
			want: "hypothesis",
		},
		{
			// "I considered it" with neither is the shape that proves nothing,
			// which is exactly the residue the host checks instead of trusting
			// that the prompt's attack-your-own-conclusion step happened.
			name: "an alternative that is neither ruled out nor uncheckable",
			finding: FindingOperation{
				What: "VA1 pyke did not deploy", Status: "explained",
				CauseEvidence: []string{"evidence-va1-errored"},
				Alternatives:  []FindingAlternative{{Hypothesis: "the image pull failed"}},
			},
			want: "discriminated_by",
		},
		{
			name: "an alternative claiming both at once",
			finding: FindingOperation{
				What: "VA1 pyke did not deploy", Status: "explained",
				CauseEvidence: []string{"evidence-va1-errored"},
				Alternatives: []FindingAlternative{{
					Hypothesis:      "the image pull failed",
					DiscriminatedBy: "evidence-registry",
					NotCheckable:    "the registry logs are gone",
				}},
			},
			want: "discriminated_by",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if testCase.finding.Key == "" {
				testCase.finding.Key = "finding-1"
			}
			operation := ResultOperation{
				ID: "finding-1", Type: "record_finding", Finding: &testCase.finding,
			}
			err := operation.Validate()
			if err == nil {
				t.Fatalf("the finding was accepted: %+v", testCase.finding)
			}
			if !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("rejection does not name %q: %v", testCase.want, err)
			}
		})
	}
}

// The four shapes that must go through, so the rules above cannot quietly become
// "record no findings at all" — which is the state this whole contract replaces.
func TestAWellFormedFindingIsAccepted(t *testing.T) {
	for _, finding := range []FindingOperation{
		{
			What:   "VA1 pyke did not deploy; its rollout missed the progress deadline",
			Scope:  "va1-apps",
			Status: "unexplained",
		},
		{
			What: "VA1 pyke did not deploy", Scope: "va1-apps", Status: "explained",
			CauseEvidence: []string{"evidence-zot-auth"},
			Alternatives: []FindingAlternative{
				{Hypothesis: "the health check threshold changed", DiscriminatedBy: "evidence-job-diff"},
				{Hypothesis: "the node ran out of disk", NotCheckable: "the allocation is already garbage collected"},
			},
		},
		{
			What: "the nightly batch job restarted", Status: "expected",
			Reason: "the job is scheduled to restart at 02:00 and did.",
		},
		{
			What: "a partner API returned 500", Status: "out_of_scope",
			Reason: "the partner owns that endpoint and Responder has no read access to it.",
		},
	} {
		finding.Key = "finding-1"
		operation := ResultOperation{
			ID: "finding-1", Type: "record_finding", Finding: &finding,
		}
		if err := operation.Validate(); err != nil {
			t.Fatalf("a well-formed finding was refused: %v (%+v)", err, finding)
		}
	}
}

func TestAFindingIdentityMustMatchItsOperationID(t *testing.T) {
	valid := FindingOperation{
		Key: "finding-1", What: "VA1 pyke did not deploy", Status: "unexplained",
	}
	for _, testCase := range []struct {
		name string
		id   string
		key  string
		want string
	}{
		{name: "missing key is host-derived", id: "finding-1", want: "finding-1"},
		{name: "forged prior key is ignored", id: "finding-new", key: "finding-1", want: "finding-new"},
		{name: "correction suffix", id: "finding-1-corrected", key: "finding-1", want: "finding-1"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			finding := valid
			finding.Key = testCase.key
			err := (ResultOperation{
				ID: testCase.id, Type: "record_finding", Finding: &finding,
			}).Validate()
			if err != nil {
				t.Fatalf("finding identity was rejected: %v", err)
			}
			if finding.Key != testCase.want {
				t.Fatalf("host finding key = %q, want %q", finding.Key, testCase.want)
			}
		})
	}
}

// The bare payload noun resolves to the verb form, like every other operation in
// the list. A model that writes `"type":"finding"` used to have its whole
// response rejected for the name; resolveOperationType is why it does not, and
// this holds record_finding inside that rule.
func TestABareFindingNounResolvesToTheOperation(t *testing.T) {
	if resolved := resolveOperationType("finding"); resolved != "record_finding" {
		t.Fatalf("type %q resolved to %q", "finding", resolved)
	}
}

// The operation must be in the prompt the model actually reads, with the honest
// default named. A validator nothing was ever asked to satisfy is a correction
// loop, not a contract.
func TestTheOperationsPromptTeachesRecordFinding(t *testing.T) {
	prompt := ResultOperationsPrompt()
	for _, required := range []string{
		`"type":"record_finding"`,
		`"status":"unexplained|explained|expected|out_of_scope"`,
		"cause_evidence",
		"alternatives",
		"unexplained is the honest default",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("the operations prompt lacks %q", required)
		}
	}
}
