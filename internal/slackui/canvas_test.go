package slackui

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/slack-go/slack"
)

// canvasServer answers the three methods a canvas takes, and remembers what it
// was asked for. handlers maps a Slack method path to its response body; a path
// with no handler answers ok, which keeps each test naming only the call it is
// about.
func canvasServer(t *testing.T, handlers map[string]string) (*Client, *[]string) {
	t.Helper()
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if body, ok := handlers[r.URL.Path]; ok {
			_, _ = fmt.Fprint(w, body)
			return
		}
		_, _ = fmt.Fprint(w, `{"ok":true}`)
	}))
	t.Cleanup(server.Close)
	return &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}, &paths
}

// A canvas is made, opened to the room that asked for it, and answered with the
// link Slack itself states.
//
// The link matters more than it looks. canvases.create answers with an id and
// nothing else, and Slack documents no URL that could be assembled from that
// id — so the permalink is asked for rather than guessed at. A guessed link
// that 404s would be the worst outcome available here: the card would still
// claim the report is over there, and the reader would find a door that does
// not open.
func TestCreateCanvasPublishesTheReportAndAnswersWithSlacksOwnLink(t *testing.T) {
	client, paths := canvasServer(t, map[string]string{
		"/canvases.create": `{"ok":true,"canvas_id":"F0CANVAS"}`,
		"/files.info": `{"ok":true,"file":{"id":"F0CANVAS",
		  "permalink":"https://acme.slack.com/docs/T1/F0CANVAS"}}`,
	})
	url, err := client.CreateCanvas(
		context.Background(), "CINCIDENT", "Remediation timeline", "## Remediation timeline\n\n- one",
	)
	if err != nil {
		t.Fatal(err)
	}
	if url != "https://acme.slack.com/docs/T1/F0CANVAS" {
		t.Fatalf("canvas link = %q", url)
	}
	// Access is granted before the link is handed back: a canvas the room
	// cannot read is a link to a closed door, and the order is what makes the
	// returned URL a promise rather than a hope.
	if !slices.Equal(*paths, []string{
		"/canvases.create", "/canvases.access.set", "/files.info",
	}) {
		t.Fatalf("canvas calls = %v", *paths)
	}
}

// A workspace whose token cannot make canvases says so, and says it in Slack's
// words.
//
// This is the whole feature detection. There is no setting asking whether
// canvases are available — the attempt is the question, and missing_scope is
// the answer. The caller's job on any error is to post the report as a message,
// so what this proves is that the error arrives intact rather than being
// swallowed into an empty URL the caller would treat as success.
func TestCreateCanvasReportsWhatSlackRefused(t *testing.T) {
	client, paths := canvasServer(t, map[string]string{
		"/canvases.create": `{"ok":false,"error":"missing_scope"}`,
	})
	url, err := client.CreateCanvas(
		context.Background(), "CINCIDENT", "Remediation timeline", "## Remediation timeline",
	)
	if err == nil || !strings.Contains(err.Error(), "missing_scope") {
		t.Fatalf("refusal = %q, %v", url, err)
	}
	if url != "" {
		t.Fatalf("a refused canvas still answered with a link: %q", url)
	}
	// Nothing follows a refusal. Asking for access to a canvas that was never
	// made would be a second failure reported in place of the first.
	if !slices.Equal(*paths, []string{"/canvases.create"}) {
		t.Fatalf("calls after a refusal = %v", *paths)
	}
}

// A canvas the room cannot read is cleaned up rather than left behind.
//
// The caller falls back to the message form either way, so the document would
// otherwise sit in the workspace forever: owned by the bot, readable by nobody,
// and pointed at by nothing. Tidying is best-effort — failing to tidy is not a
// second reason to fail the report — but it is attempted.
func TestCreateCanvasDiscardsADocumentTheRoomCannotRead(t *testing.T) {
	client, paths := canvasServer(t, map[string]string{
		"/canvases.create":     `{"ok":true,"canvas_id":"F0CANVAS"}`,
		"/canvases.access.set": `{"ok":false,"error":"channel_not_found"}`,
	})
	if _, err := client.CreateCanvas(
		context.Background(), "CGONE", "Remediation timeline", "## Remediation timeline",
	); err == nil || !strings.Contains(err.Error(), "channel_not_found") {
		t.Fatalf("access failure = %v", err)
	}
	if !slices.Equal(*paths, []string{
		"/canvases.create", "/canvases.access.set", "/canvases.delete",
	}) {
		t.Fatalf("calls after an ungrantable canvas = %v", *paths)
	}
}

// A canvas with no link is the same as no canvas.
//
// Slack answering files.info without a permalink would leave a document that
// exists and cannot be reached. Returning it anyway would put an empty URL on
// the card's one button.
func TestCreateCanvasRefusesADocumentItCannotLinkTo(t *testing.T) {
	client, paths := canvasServer(t, map[string]string{
		"/canvases.create": `{"ok":true,"canvas_id":"F0CANVAS"}`,
		"/files.info":      `{"ok":true,"file":{"id":"F0CANVAS","permalink":""}}`,
	})
	if _, err := client.CreateCanvas(
		context.Background(), "CINCIDENT", "Remediation timeline", "## Remediation timeline",
	); err == nil {
		t.Fatal("a canvas with no link was reported as a canvas")
	}
	if !slices.Contains(*paths, "/canvases.delete") {
		t.Fatalf("an unreachable canvas was left behind: %v", *paths)
	}
}

// The document travels as markdown, which is the form all four reports already
// build. Sending them as plain text would strip the headings, tables and
// checklists the reports are made of.
func TestCreateCanvasSendsTheReportAsMarkdown(t *testing.T) {
	var content string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if r.URL.Path == "/canvases.create" {
			content = r.FormValue("document_content")
			_, _ = fmt.Fprint(w, `{"ok":true,"canvas_id":"F0CANVAS"}`)
			return
		}
		if r.URL.Path == "/files.info" {
			_, _ = fmt.Fprint(w, `{"ok":true,"file":{"permalink":"https://acme.slack.com/docs/T1/F0CANVAS"}}`)
			return
		}
		_, _ = fmt.Fprint(w, `{"ok":true}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	if _, err := client.CreateCanvas(
		context.Background(), "CINCIDENT", "Post-incident draft", "## Post-incident draft\n\n- [ ] Confirm impact",
	); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(content, `"type":"markdown"`) ||
		!strings.Contains(content, "Confirm impact") {
		t.Fatalf("document content = %s", content)
	}
}

// A canvas with no room to read it is refused before it is made, because there
// would be nobody to grant access to and the document would be born
// unreachable.
func TestCreateCanvasNeedsARoomAndADocument(t *testing.T) {
	client, paths := canvasServer(t, nil)
	if _, err := client.CreateCanvas(context.Background(), "", "Title", "body"); err == nil {
		t.Fatal("a canvas was made with no room that could read it")
	}
	if _, err := client.CreateCanvas(context.Background(), "CINCIDENT", "Title", "  "); err == nil {
		t.Fatal("an empty canvas was made")
	}
	if len(*paths) != 0 {
		t.Fatalf("Slack was called for a canvas that could not exist: %v", *paths)
	}
}
