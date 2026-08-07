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
