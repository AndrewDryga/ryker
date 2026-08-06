package core

import (
	"strings"
	"unicode/utf8"
)

// TruncateUTF8 bounds value to at most limit bytes without splitting a rune.
//
// Slack messages, incident titles, agent objectives, and stored errors all
// carry operator and model text that routinely contains multi-byte runes.
// Slicing those on a byte boundary yields invalid UTF-8, which surfaces to
// operators as a replacement character and corrupts anything that later
// re-encodes the value as JSON. Every bound in Responder goes through here.
func TruncateUTF8(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	if len(value) <= limit {
		return value
	}
	value = value[:limit]
	for !utf8.ValidString(value) {
		value = value[:len(value)-1]
	}
	return strings.TrimSpace(value)
}

// BoundedText trims surrounding whitespace before applying TruncateUTF8, for
// the many fields whose limit is meant to bound meaningful content rather than
// incidental padding.
func BoundedText(value string, limit int) string {
	return TruncateUTF8(strings.TrimSpace(value), limit)
}

// TruncateUTF8WithSuffix bounds value to limit bytes including suffix, which is
// appended only when the value actually had to be shortened.
func TruncateUTF8WithSuffix(value string, limit int, suffix string) string {
	if len(value) <= limit {
		return value
	}
	return TruncateUTF8(value, limit-len(suffix)) + suffix
}
