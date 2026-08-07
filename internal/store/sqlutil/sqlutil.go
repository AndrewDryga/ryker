// Package sqlutil holds the helpers every persistence package needs.
//
// It exists because the store is no longer one package. A sub-repository
// cannot import the store that owns it, so anything defined only in store is
// something a sub-repository has to reinvent — and that is not a theory:
// scheduleproposal grew its own copies of ParseTime and ExpectOne, and the
// ExpectOne copy drifted to returning a formatted string instead of the
// conflict sentinel, which silently broke errors.Is for that whole package.
//
// Everything here is deliberately small and stateless. A clock belongs to the
// repository that owns it, not to a shared package.
package sqlutil

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// ParseTime reads a stored timestamp, returning the zero time for anything
// unreadable.
//
// Reads use core.TimestampParseFormat rather than the write format on purpose:
// Go requires exactly the layout's digit count when a fraction is written with
// zeros, so parsing with the write format rejects every value stored before
// timestamps became fixed-width — including one in a restored backup.
func ParseTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	parsed, _ := time.Parse(core.TimestampParseFormat, value)
	return parsed
}

// ScanTime reads a nullable stored timestamp.
func ScanTime(value sql.NullString) time.Time {
	if !value.Valid {
		return time.Time{}
	}
	return ParseTime(value.String)
}

// ExpectOne turns a write that should have touched exactly one row into an
// error when it did not.
//
// A miss is core.ErrConflict, not a formatted message, because the caller has
// to be able to tell "someone else got there first" from a real failure with
// errors.Is. That distinction is what the duplicated copy of this function
// lost.
func ExpectOne(result sql.Result, err error, action string) error {
	if err != nil {
		return fmt.Errorf("%s: %w", action, err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s: %w", action, err)
	}
	if rows != 1 {
		return fmt.Errorf("%s: %w", action, core.ErrConflict)
	}
	return nil
}

// BoundedError caps a stored error message so one runaway string cannot
// dominate a row.
func BoundedError(value string) string {
	return core.BoundedText(value, 1000)
}

// RowScanner is whatever a query returned that can be scanned — a *sql.Row or
// a *sql.Rows — so one scan function serves both the single-row and the
// iterating call sites.
//
// Shared for the same reason as everything else here: it was defined three
// times across store, memorystore and scheduleproposal.
type RowScanner interface {
	Scan(dest ...any) error
}

// TimeText renders a timestamp for storage, or NULL for the zero time.
//
// The zero time has to become NULL rather than the year 1: a column meaning
// "not yet" is queried with IS NULL, and a stored 0001-01-01 satisfies neither
// that nor a range check, so it goes missing from both.
func TimeText(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(core.TimestampFormat)
}
