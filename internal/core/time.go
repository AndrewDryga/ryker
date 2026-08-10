package core

import "time"

// TimestampFormat is how every stored timestamp is written.
//
// Stored timestamps are TEXT and SQLite compares them as text, so their text
// order has to equal their chronological order. RFC3339Nano breaks that: it
// strips trailing zeros, and the terminating Z sorts after every digit, so
// `.5Z` sorts after `.53Z` despite being earlier. A row could be skipped for
// the rest of its second and then reappear.
//
// The fixed nine-digit fraction makes every value exactly 30 bytes, which makes
// text order and chronological order the same thing again.
//
// It lives in core because two packages write these values. When the constant
// was defined separately in each, one of them could be changed alone — and a
// value written in the old format compares just as wrongly against the new one
// as the bug this replaces.
const TimestampFormat = "2006-01-02T15:04:05.000000000Z07:00"

// TimestampParseFormat reads a stored timestamp.
//
// It is deliberately not TimestampFormat. Go requires exactly the layout's
// digit count when a fraction is written with zeros, so parsing with
// TimestampFormat rejects every value written before the migration to it.
// RFC3339Nano accepts both widths, so reads keep working across the change and
// across a database restored from an older backup.
const TimestampParseFormat = time.RFC3339Nano

// PermanentExpiry is the instant a row that never expires is stored at.
//
// Every expiry column in this schema is `expires_at TEXT NOT NULL`, every read
// that means "still active" is `expires_at > now`, and every sweep that means
// "gone" is `expires_at <= now`. A sentinel that is simply later than any real
// clock keeps all of both correct without editing either: a permanent row is
// active in the twenty-odd context, capacity, home and dashboard queries that
// were written before permanence existed, and no pruner can reach it.
//
// The obvious alternative — making the column nullable — inverts that. SQLite
// evaluates `NULL > '2026-08-10...'` to NULL, which is not true, so a permanent
// memory would be silently invisible everywhere instead of permanently visible.
// Getting that right would mean editing every one of those queries correctly,
// and a single miss reads as "the thing I told you to remember forever is
// gone". This shape fails in the safe direction when a caller forgets it: the
// worst a surface that does not know the sentinel can do is print a date in the
// year 9999, which is wrong and obvious rather than wrong and silent.
//
// Nanosecond precision is deliberate. TimestampFormat writes a fixed nine-digit
// fraction, so the value round-trips through the database byte for byte and
// IsPermanentExpiry recognizes what it wrote.
var PermanentExpiry = time.Date(9999, 12, 31, 23, 59, 59, 999999999, time.UTC)

// NeverExpires is the one word every surface uses for PermanentExpiry, so a
// card, a home tab, a review item and a dashboard cell all say the same thing.
const NeverExpires = "never"

// IsPermanentExpiry reports whether an expiry means "never".
//
// It compares with a boundary rather than equality because a value that has
// been through a database round-trip, a JSON encode, or a timezone conversion
// is the same instant without being the same struct.
func IsPermanentExpiry(value time.Time) bool {
	return !value.Before(PermanentExpiry)
}
