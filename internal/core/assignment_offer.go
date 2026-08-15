package core

// StandingAssignmentOffer proposes scoped authority to open a pull request
// without a per-action click.
//
// It is the most authority any offer in this product asks for, and it is
// deliberately the offer that says the least. Every field is a BOUND the
// operator is agreeing to, so the model's job is to write down the bounds it
// heard in the sentence — this repository, this class of change, this many a
// day, for this many days — and nothing else. The host normalizes them,
// re-derives the expiry from its own clock, sets shadow itself, and shows the
// operator the normalized result rather than the proposal.
//
// There is no shadow field, and that absence is the point. A standing
// assignment is created in shadow with no exception and no argument; the flag
// is cleared later against an assignment that already has an audit to argue
// with. A model that could ask for a live grant would be a model that could ask
// for the one thing this whole feature withholds.
type StandingAssignmentOffer struct {
	// Repository is the exact alias from the repository set, never a guess.
	Repository string `json:"repository"`
	// ChangeClass is one of StandingAssignmentChangeClasses.
	ChangeClass string `json:"change_class"`
	// SignalPattern is the words this assignment watches for. Without it the
	// grant would cover every message in the channel, so it has no default.
	SignalPattern string `json:"signal_pattern"`
	// PathGlobs narrows the grant inside the repository. Absent means the whole
	// repository, which is a wider grant and is allowed to be said out loud.
	PathGlobs []string `json:"path_globs,omitempty"`
	// DailyBudget and ExpiryDays are optional. Zero means the operator did not
	// say, and the host fills in the cautious default rather than the
	// permissive one.
	DailyBudget int `json:"daily_budget,omitempty"`
	ExpiryDays  int `json:"expiry_days,omitempty"`
	// Rationale is one operator-facing sentence for the confirmation card.
	Rationale string `json:"rationale,omitempty"`
}

// UnmarshalJSON accepts the names an operator's own sentence suggests.
//
// The slash grammar this operation replaces used `repo=`, `class=`, `signal=`,
// `paths=`, `budget=` and `days=`, and those spellings are what two months of
// documentation, help text and channel history taught. Each names exactly one
// real field here and nothing else in an assignment offer could be meant, so a
// model reaching for the short form is answered rather than rejected over a key.
func (offer *StandingAssignmentOffer) UnmarshalJSON(data []byte) error {
	type wire StandingAssignmentOffer
	var value wire
	if err := DecodeModelObject(data, map[string]string{
		"repo":   "repository",
		"class":  "change_class",
		"signal": "signal_pattern",
		"paths":  "path_globs",
		"budget": "daily_budget",
		"days":   "expiry_days",
		"reason": "rationale",
	}, &value); err != nil {
		return err
	}
	*offer = StandingAssignmentOffer(value)
	return nil
}
