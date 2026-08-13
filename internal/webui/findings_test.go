package webui

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
)

// The findings page is rendered with a finding in it.
//
// TestEveryPageRendersAgainstTheMigratedSchema renders every route, but against
// an empty database — so {{range .Findings}} never executes and every field
// name inside it is unchecked. A template that names a field the handler stopped
// passing fails at execute time, and for a list page that failure lives
// entirely in the branch an empty table cannot reach. This is the page whose
// whole purpose is to carry a defect to a person, so the body that carries it
// is the part worth executing.
func TestFindingsPageShowsTheDefectAndItsChallenge(t *testing.T) {
	reader := seededReader(t)
	handler, err := NewHandler(reader, "test", "54", "responder-abc", nil, config.Pricing{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/findings", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("GET /findings = %d: %s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	for _, want := range []string{
		// What was wrong, and what should have happened instead.
		"the watch reply claimed a deploy it never verified",
		"it should say what it checked",
		// Where to look, which is the difference between a report and a task.
		"internal/service/watch.go: replyFromRun",
		// The challenger's verdict, in both the badge and its own words.
		"confirmed",
		"the delivered body does assert it",
		// The episode it came from, reachable.
		`href="/episodes/run_1"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("the findings page does not carry %q", want)
		}
	}
	if strings.Contains(body, "No turn has been reviewed") {
		t.Error("a page holding a finding rendered the empty state")
	}
}
