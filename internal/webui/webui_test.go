package webui

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Every page renders, and an unwired panel says so rather than showing a zero.
// A dashboard that half-renders is indistinguishable from a system with missing
// data, which is the confusion this package exists to end.
func TestEveryPageRendersAndUnwiredPanelsSayWhyTheyAreEmpty(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "responder-abc1234",
		func() bool { return true },
		[]PromptBudget{{Name: "watch", Bytes: 47000, Cap: 65536}})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)

	for _, path := range []string{
		"/", "/episodes", "/failures", "/decisions", "/memory", "/configuration", "/usage",
	} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200: %s", path, recorder.Code, recorder.Body.String())
			continue
		}
		body := recorder.Body.String()
		if !strings.Contains(body, "<nav class=\"sidebar\">") {
			t.Errorf("GET %s did not render the shell", path)
		}
		// Nothing is fetched at render time: the page must work with the
		// network off, and no request about production work should leave.
		if strings.Contains(body, "//cdn.") || strings.Contains(body, "https://unpkg") {
			t.Errorf("GET %s fetches an external asset", path)
		}
	}

	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/usage", nil))
	body := recorder.Body.String()
	if !strings.Contains(body, "Not recorded yet") {
		t.Error("the usage page does not mark its panels unwired")
	}
	// An unwired panel names what would fill it, so nobody has to guess whether
	// the number is zero or the pipe is missing.
	if !strings.Contains(body, "does not report them on the turn") {
		t.Error("an unwired panel does not say what is missing")
	}
	if strings.Contains(body, ">0<") {
		t.Error("the usage page renders a zero where it has no data")
	}
}

// The dashboard is read-only in v1. Loopback is the only thing between a button
// and production state, so a write path is opted into deliberately.
func TestNoWriteRoutesAreExposed(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "abc", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(method, "/episodes", nil))
		if recorder.Code == http.StatusOK {
			t.Errorf("%s /episodes was accepted; v1 is read-only", method)
		}
	}
}

// Every list must be a way in, not a dead end. A grouped failure that cannot be
// opened tells you twenty-nine runs hit one error and gives you no route to any
// of them; a conversation row that cannot be opened counts a memory without
// showing what is in it.
func TestListsLinkToDetail(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "abc", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)

	// The detail routes exist and answer, rather than falling through to the
	// list route and silently rendering the wrong page.
	for _, path := range []string{
		"/episodes/ep_missing",
		"/failures/0000000000000000",
		"/conversations/C1/channel",
	} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d; an unknown entity should be 404, not a page about something else",
				path, recorder.Code)
		}
	}
}
