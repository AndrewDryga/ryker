package webui

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// The control plane says what an assignment would have done, refusals included.
//
// This page is the evidence a grant gets argued from, and a page that showed
// only the passes could not carry that argument: standing rules learned it on
// 2026-08-09, when a rule with 64 fires read as productive and had ignored
// every one of them. So the tally is the count, the refusals, and the reason
// that repeated — a misconfigured scope and traffic that simply did not deserve
// a pull request are the same number and opposite responses.
//
// It also has to say, in words, that the assignment is opening nothing. An
// operator who reads "would have opened 2" and goes looking for two pull
// requests has been misled by a page that was technically correct.
func TestTheControlPlaneShowsWhatAShadowedAssignmentWouldHaveDone(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	assignment, err := live.StandingAssignments.Create(ctx, core.StandingAssignment{
		ChannelID: "C1", SignalPattern: "sentry payments timeout",
		Repository: "payments-api", PathGlobs: []string{"src/payments/**"},
		ChangeClass: "observability", DailyBudget: 2, ActorID: "U1", Shadow: true,
		ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, verdict := range []struct{ verdict, reason string }{
		{"declined", "this has not happened often enough to be a pattern yet"},
		{"declined", "this has not happened often enough to be a pattern yet"},
		{"declined", "no verified evidence supports the change"},
		{"eligible", "in scope, recurring, and evidence-backed"},
	} {
		if _, err := live.StandingAssignments.RecordEvaluation(
			ctx, core.StandingAssignmentEvaluation{
				AssignmentID: assignment.ID, InputID: "in_1", Signal: "FIRING: payments timeout",
				Shadow: true, Verdict: verdict.verdict, Reason: verdict.reason,
			},
		); err != nil {
			t.Fatal(err)
		}
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}

	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	handler, err := NewHandler(reader, "test", "77", "responder-abc",
		func() (bool, string) { return true, "" }, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)

	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/assignments", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("/assignments answered %d", recorder.Code)
	}
	page := recorder.Body.String()
	for _, required := range []string{
		"evaluated 4",         // it looked
		"would have opened 1", // and this is the number a grant would be worth
		"refused 3",           // out of this many, which is the other half
		"not happened often enough to be a pattern yet", // the repeated refusal
		"(2 times)",       // and how often it repeated
		"shadow",          // stated, not implied
		"payments-api",    // the grant it covers
		"src/payments/**", // including the paths that bound it
	} {
		if !strings.Contains(page, required) {
			t.Errorf("/assignments does not say %q", required)
		}
	}

	// And the Configuration index counts it, so the feature is discoverable
	// from the page an operator actually lands on rather than only by URL.
	recorder = httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/configuration", nil))
	index := recorder.Body.String()
	for _, required := range []string{"Standing assignments", "1 opening nothing"} {
		if !strings.Contains(index, required) {
			t.Errorf("/configuration does not say %q", required)
		}
	}
}
