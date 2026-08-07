package sqlutil_test

import (
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// A miss must be matchable as a conflict.
//
// This is the whole reason the package exists. The duplicated copy of this
// function in scheduleproposal returned a formatted "database conflict" string,
// so errors.Is could not match it and a caller could not tell "someone else got
// there first" from a real failure.
func TestExpectOneReportsAMatchableConflict(t *testing.T) {
	err := sqlutil.ExpectOne(rowsAffected(0), nil, "accept something")
	if err == nil {
		t.Fatal("a write that touched no rows reported success")
	}
	if !errors.Is(err, core.ErrConflict) {
		t.Fatalf("not matchable as a conflict: %v", err)
	}
	if !errors.Is(sqlutil.ExpectOne(rowsAffected(2), nil, "x"), core.ErrConflict) {
		t.Fatal("a write that touched two rows is also a conflict")
	}
	if err := sqlutil.ExpectOne(rowsAffected(1), nil, "x"); err != nil {
		t.Fatalf("exactly one row is the success case: %v", err)
	}
	// A real driver error must survive rather than be reported as a conflict.
	driverErr := errors.New("disk is on fire")
	got := sqlutil.ExpectOne(nil, driverErr, "x")
	if !errors.Is(got, driverErr) || errors.Is(got, core.ErrConflict) {
		t.Fatalf("a driver failure was flattened into a conflict: %v", got)
	}
}

// Reads must accept both timestamp widths.
//
// Parsing with the write format rejects every value stored before timestamps
// became fixed-width, including one in a restored backup, so this is not
// cosmetic.
func TestParseTimeReadsBothStoredWidths(t *testing.T) {
	want := time.Date(2026, 8, 7, 12, 0, 0, 500000000, time.UTC)
	for _, stored := range []string{
		"2026-08-07T12:00:00.5Z",
		"2026-08-07T12:00:00.500000000Z",
	} {
		if got := sqlutil.ParseTime(stored); !got.Equal(want) {
			t.Fatalf("ParseTime(%q) = %v, want %v", stored, got, want)
		}
	}
	if got := sqlutil.ParseTime(""); !got.IsZero() {
		t.Fatalf("an empty timestamp should read as the zero time, got %v", got)
	}
	if got := sqlutil.ParseTime("not a time"); !got.IsZero() {
		t.Fatalf("an unreadable timestamp should read as the zero time, got %v", got)
	}
	if got := sqlutil.ScanTime(sql.NullString{}); !got.IsZero() {
		t.Fatalf("a NULL timestamp should read as the zero time, got %v", got)
	}
	if got := sqlutil.ScanTime(sql.NullString{
		String: "2026-08-07T12:00:00.500000000Z", Valid: true,
	}); !got.Equal(want) {
		t.Fatalf("ScanTime = %v, want %v", got, want)
	}
}

type affected int64

func (a affected) LastInsertId() (int64, error) { return 0, nil }
func (a affected) RowsAffected() (int64, error) { return int64(a), nil }

func rowsAffected(n int64) sql.Result { return affected(n) }
