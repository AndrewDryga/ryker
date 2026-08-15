package remediation

// DemotionForRunStatus reads one Emisar run status as what it implies about the
// grant that offered the action.
//
// The tempting implementation is `status != "success"`, and it is wrong twice.
// Emisar denying a request is the governance layer doing its job — the approval
// card deliberately colours denied grey rather than red for exactly this reason
// — and demoting on it would mean a grant loses a rung every time the policy in
// front of it works. A cancelled run establishes nothing about the action at
// all. Neither is evidence against the grant, and treating them as evidence
// would make the ladder impossible to climb in any environment with a real
// approval policy.
//
// The split between the two demotion reasons is diagnostic and it is the same
// split the spec draws. A run that failed, errored, timed out or was refused is
// the action not working: the grant's premise is in doubt, and that is
// VerificationFailed. A run that came back unknown_action or validation_failed
// is Emisar saying the identity no longer resolves to what it used to — the
// target_contract_changed case — and the successes were earned on an action
// that is no longer there.
//
// Anything unrecognized demotes nothing. A status Emisar adds later must not
// take authority away before somebody has decided what it means.
func DemotionForRunStatus(status string) (DemotionReason, bool) {
	switch status {
	case "failed", "error", "timed_out", "refused":
		return VerificationFailed, true
	case "unknown_action", "validation_failed":
		return ContractChanged, true
	default:
		return "", false
	}
}
