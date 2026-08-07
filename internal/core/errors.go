package core

import "errors"

// Sentinel outcomes every persistence path shares.
//
// They live in core because the store is no longer a single package: a
// sub-repository cannot import the store that owns it, so a sentinel defined
// there is one a sub-repository has to reinvent. That already happened —
// scheduleproposal grew its own expectOne returning a plain "database
// conflict" string, so errors.Is(err, ErrConflict) silently stopped matching
// and a duplicate schedule acceptance surfaced a raw database error to the
// user instead of being recognised as already done.
var (
	// ErrNotFound: the row asked for is not there.
	ErrNotFound = errors.New("not found")
	// ErrConflict: the write lost a race, or the row was not in the state the
	// write required. Callers are expected to treat this as "someone else got
	// there first" rather than as a failure.
	ErrConflict = errors.New("conflict")
)
