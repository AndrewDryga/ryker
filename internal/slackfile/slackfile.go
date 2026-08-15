// Package slackfile decides what Responder will accept as a Slack file, what
// it will call one, and how much of one it will read.
//
// Every rule here is a refusal, and every refusal is about a byte string
// somebody else controls: a download URL that came back in a Slack payload, a
// media type a client declared, a filename a person typed. None of it needs the
// coordinator, a store, or a session — the answers are pure functions of the
// values — and none of it was ever really about coordinating anything, which is
// why it now lives beside its own table tests instead of inside the largest
// package in the repository.
//
// Extracted from internal/service unchanged on 2026-08-15. The behaviour is
// identical on purpose: this is a move, and a move that also fixed something
// would be a move nobody could review.
package slackfile

import (
	"bytes"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// Merge fills an attachment's gaps from the resolved history entry.
//
// The ID is the one field the attachment wins: it is how the download is
// addressed, and a resolved record describing a different file must not be able
// to redirect one.
func Merge(
	attachment core.SlackAttachment,
	resolved slackui.HistoryFile,
) core.SlackAttachment {
	if resolved.ID != "" && attachment.ID == "" {
		attachment.ID = resolved.ID
	}
	if resolved.Name != "" {
		attachment.Name = resolved.Name
	}
	if resolved.MediaType != "" {
		attachment.MediaType = resolved.MediaType
	}
	if resolved.Size != 0 {
		attachment.Size = resolved.Size
	}
	if resolved.URLPrivate != "" {
		attachment.URLPrivate = resolved.URLPrivate
	}
	return attachment
}

// InputError marks a refusal that retrying cannot change: the file itself is
// unacceptable, so the thousandth attempt reads the same bytes as the first.
type InputError struct {
	detail string
}

func (e *InputError) Error() string { return e.detail }

// InvalidInput builds a permanent refusal with an operator-readable reason.
func InvalidInput(format string, args ...any) error {
	return &InputError{detail: fmt.Sprintf(format, args...)}
}

// PermanentInputError reports whether a failure is the file's fault rather than
// the network's.
func PermanentInputError(err error) bool {
	var target *InputError
	return errors.As(err, &target)
}

// ValidateURL refuses any download URL that is not Slack's own file host.
//
// A private download URL arrives inside a Slack payload and is followed with a
// bot token attached, so the host it names decides who receives that token. The
// suffix check is anchored on a dot for the reason such checks always are:
// `evilfiles.slack.com` must not pass as `files.slack.com`.
func ValidateURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil ||
		parsed.Fragment != "" {
		return errors.New("private download URL is invalid")
	}
	host := strings.ToLower(parsed.Hostname())
	if host != "files.slack.com" && !strings.HasSuffix(host, ".files.slack.com") {
		return errors.New("private download URL is outside Slack file hosting")
	}
	return nil
}

// CanonicalMediaType is an allowlist, not a parser. Anything not named here is
// refused rather than passed along for something downstream to decide about.
func CanonicalMediaType(raw string) (string, error) {
	value, _, err := mime.ParseMediaType(strings.TrimSpace(raw))
	if err != nil {
		return "", errors.New("declared media type is invalid")
	}
	value = strings.ToLower(value)
	switch value {
	case "image/png", "image/jpeg", "image/webp", "image/gif",
		"text/plain", "text/markdown", "text/csv", "application/json",
		"application/yaml", "application/x-yaml", "application/pdf":
		return value, nil
	default:
		return "", fmt.Errorf("media type %q is not supported", value)
	}
}

// MatchesMediaType checks the bytes against the declaration.
//
// The declaration comes from a client and is therefore a claim. Sniffing is the
// cheap way to notice a PDF arriving as an image, and the text branch is the
// strict one: valid UTF-8 with no NUL, because everything in the text family
// ends up in a prompt.
func MatchesMediaType(mediaType string, data []byte) bool {
	switch mediaType {
	case "image/png", "image/jpeg", "image/gif":
		return http.DetectContentType(data) == mediaType
	case "image/webp":
		return len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP"
	case "application/pdf":
		return len(data) >= 5 && string(data[:5]) == "%PDF-"
	default:
		return utf8.Valid(data) && !bytes.ContainsRune(data, 0)
	}
}

// SafeName makes a filename that cannot escape a directory or hide a control
// character, and that always has something in it.
func SafeName(name, fallback string) string {
	name = strings.TrimSpace(name)
	var clean strings.Builder
	for _, r := range name {
		if r == '/' || r == '\\' || unicode.IsControl(r) {
			clean.WriteByte('_')
		} else {
			clean.WriteRune(r)
		}
	}
	value := strings.Trim(clean.String(), " .")
	if value == "" {
		value = "attachment-" + fallback
	}
	return core.TruncateUTF8(value, 255)
}

// ErrTooLarge is a download that reached its ceiling mid-stream.
var ErrTooLarge = errors.New("artifact exceeds byte limit")

// BoundedWriter reads a download up to a limit and refuses the rest.
//
// It fails on the write that would cross the line rather than truncating,
// because a silently truncated attachment is worse than a refused one: the
// model would reason about half a file and say nothing about the other half.
type BoundedWriter struct {
	buffer bytes.Buffer
	limit  int
}

// NewBoundedWriter builds a writer that accepts at most limit bytes.
func NewBoundedWriter(limit int) *BoundedWriter { return &BoundedWriter{limit: limit} }

func (w *BoundedWriter) Write(data []byte) (int, error) {
	if w.buffer.Len() > w.limit-len(data) {
		return 0, ErrTooLarge
	}
	return w.buffer.Write(data)
}

func (w *BoundedWriter) Bytes() []byte { return w.buffer.Bytes() }
