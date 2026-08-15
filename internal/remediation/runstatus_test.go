package remediation

import "testing"

// TestOnlyAFailedActionDemotesItsGrant is the whole reason this mapping is a
// function and not an `if status != "success"`.
//
// Emisar has fourteen run statuses and they do not mean the same thing about
// the grant. An operator declining a change is the control working, not a
// failure — the approval card already says so in its own words, colouring
// denied grey rather than red, and demoting on it would punish a grant for the
// governance that is supposed to sit in front of it. A cancelled run teaches
// nothing about whether the action works. Those two are the ones that get
// implemented wrong, because "did not succeed" is such an easy predicate to
// reach for.
func TestOnlyAFailedActionDemotesItsGrant(t *testing.T) {
	for _, tc := range []struct {
		status string
		reason DemotionReason
		demote bool
	}{
		{"success", "", false},
		// The control working. Emisar was asked and said no; the action is
		// untested, not discredited.
		{"denied", "", false},
		// Somebody stopped it. Nothing was learned either way.
		{"cancelled", "", false},
		// Still moving — a grant is never demoted on a status that is not
		// terminal, or the first slow run takes the rung away.
		{"pending", "", false},
		{"pending_approval", "", false},
		{"sent", "", false},
		{"running", "", false},
		{"cancelling", "", false},
		// The action ran and did not work.
		{"failed", VerificationFailed, true},
		{"error", VerificationFailed, true},
		{"timed_out", VerificationFailed, true},
		{"refused", VerificationFailed, true},
		// The action is not the action that was granted. This is the
		// target_contract_changed case the spec names: the identity the
		// successes were earned under no longer resolves.
		{"unknown_action", ContractChanged, true},
		{"validation_failed", ContractChanged, true},
	} {
		t.Run(tc.status, func(t *testing.T) {
			reason, demote := DemotionForRunStatus(tc.status)
			if demote != tc.demote {
				t.Fatalf("demote=%v, want %v", demote, tc.demote)
			}
			if reason != tc.reason {
				t.Fatalf("reason=%q, want %q", reason, tc.reason)
			}
		})
	}
}

// TestAnUnknownRunStatusNeverDemotes keeps a status Emisar adds later from
// silently taking authority away before anybody has decided what it means.
func TestAnUnknownRunStatusNeverDemotes(t *testing.T) {
	if _, demote := DemotionForRunStatus("quarantined"); demote {
		t.Fatal("an unrecognized run status demoted a grant")
	}
}
