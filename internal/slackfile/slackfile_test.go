package slackfile

import (
	"strings"
	"testing"
)

// A private download URL arrives inside a Slack payload and is followed with a
// bot token attached, so the host it names decides who receives that token.
//
// The suffix case is the one that would slip through a naive check:
// `evilfiles.slack.com` ends with `files.slack.com` as a substring, and only an
// anchored dot tells them apart. These refusals lived in internal/service with
// no test of their own until the package moved.
func TestOnlySlacksOwnFileHostReceivesTheDownloadToken(t *testing.T) {
	for _, allowed := range []string{
		"https://files.slack.com/files-pri/T1-F1/x.png",
		"https://edgeapi.files.slack.com/files-pri/T1-F1/x.png",
	} {
		if err := ValidateURL(allowed); err != nil {
			t.Fatalf("a Slack file URL was refused: %q: %v", allowed, err)
		}
	}
	for _, refused := range []string{
		"https://evilfiles.slack.com/files-pri/T1-F1/x.png",
		"https://files.slack.com.evil.test/x.png",
		"http://files.slack.com/x.png",
		"https://user:pass@files.slack.com/x.png",
		"https://files.slack.com/x.png#fragment",
		"://nonsense",
	} {
		if err := ValidateURL(refused); err == nil {
			t.Fatalf("a token would have been sent to %q", refused)
		}
	}
}

// A declared media type is a claim by whoever uploaded the file, so the bytes
// are checked against it. The text branch is the strict one: everything in that
// family ends up in a prompt, and a NUL byte or invalid UTF-8 there corrupts
// anything that re-encodes it as JSON.
func TestDeclaredMediaTypesAreCheckedAgainstTheBytes(t *testing.T) {
	if !MatchesMediaType("application/pdf", []byte("%PDF-1.7\nrest")) {
		t.Fatal("a real PDF was rejected")
	}
	if MatchesMediaType("application/pdf", []byte("not a pdf at all")) {
		t.Fatal("a file claiming to be a PDF was accepted without one")
	}
	if !MatchesMediaType("image/webp", []byte("RIFF____WEBPrest")) {
		t.Fatal("a real WebP was rejected")
	}
	if MatchesMediaType("text/plain", []byte("hello\x00world")) {
		t.Fatal("text containing NUL was accepted")
	}
	if !MatchesMediaType("text/markdown", []byte("# héllo")) {
		t.Fatal("valid UTF-8 Markdown was rejected")
	}
}

// The allowlist is an allowlist. An unnamed type is refused here rather than
// passed downstream for something else to decide about.
func TestAnUnlistedMediaTypeIsRefusedRatherThanForwarded(t *testing.T) {
	if _, err := CanonicalMediaType("IMAGE/PNG; charset=utf-8"); err != nil {
		t.Fatalf("a listed type with parameters was refused: %v", err)
	}
	for _, refused := range []string{"application/zip", "text/html", "", "not/a/type"} {
		if _, err := CanonicalMediaType(refused); err == nil {
			t.Fatalf("media type %q was accepted", refused)
		}
	}
}

// A filename comes from a person and ends up on disk, so a separator or a
// control character cannot survive it, and an empty result gets a name rather
// than becoming one.
func TestAnAttachmentNameCannotEscapeItsDirectory(t *testing.T) {
	for _, name := range []string{"../../etc/passwd", `..\..\secrets`, "a/b/c.png"} {
		got := SafeName(name, "f1")
		if strings.ContainsAny(got, `/\`) {
			t.Fatalf("SafeName(%q) = %q, which still holds a separator", name, got)
		}
	}
	if got := SafeName("  ...  ", "f1"); got != "attachment-f1" {
		t.Fatalf("a name that trims to nothing became %q", got)
	}
	if got := SafeName("report\x07.csv", "f1"); strings.ContainsRune(got, 7) {
		t.Fatalf("a control character survived: %q", got)
	}
	if got := SafeName(strings.Repeat("é", 400), "f1"); len(got) > 255 {
		t.Fatalf("a long multi-byte name was not bounded: %d bytes", len(got))
	}
}

// The writer fails on the write that would cross the line rather than
// truncating. A silently truncated attachment is worse than a refused one: the
// model reasons about half a file and says nothing about the other half.
func TestABoundedDownloadRefusesRatherThanTruncates(t *testing.T) {
	writer := NewBoundedWriter(10)
	if _, err := writer.Write([]byte("12345")); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("123456789")); err != ErrTooLarge {
		t.Fatalf("an over-limit write returned %v", err)
	}
	if got := string(writer.Bytes()); got != "12345" {
		t.Fatalf("the refused write left %q behind", got)
	}
}

// A refusal about the file itself is permanent — the thousandth attempt reads
// the same bytes as the first — and a network failure is not.
func TestOnlyTheFilesOwnFaultIsPermanent(t *testing.T) {
	if !PermanentInputError(InvalidInput("Slack file %q is too large", "x.png")) {
		t.Fatal("a file-shaped refusal was treated as retryable")
	}
	if PermanentInputError(ErrTooLarge) {
		t.Fatal("a transport-shaped error was treated as permanent")
	}
}
