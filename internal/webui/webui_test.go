package webui

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
)

// Every page renders, and an unwired panel says so rather than showing a zero.
// A dashboard that half-renders is indistinguishable from a system with missing
// data, which is the confusion this package exists to end.
func TestEveryPageRendersAndUnwiredPanelsSayWhyTheyAreEmpty(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "ryker-abc1234",
		func() (bool, string) { return true, "" },
		config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)

	for _, path := range []string{
		"/", "/episodes", "/schedules", "/channels", "/failures", "/workspaces",
		"/decisions", "/findings", "/audit", "/memory", "/configuration",
		"/preferences", "/rules", "/assignments", "/usage",
	} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200: %s", path, recorder.Code, recorder.Body.String())
			continue
		}
		body := recorder.Body.String()
		for _, landmark := range []string{
			`<aside class="sidebar"`,
			`<details class="mobile-navigation"`,
			`<div class="shell-canvas">`,
			`<header class="page-header">`,
			`<main id="main-content"`,
		} {
			if !strings.Contains(body, landmark) {
				t.Errorf("GET %s did not render shell landmark %q", path, landmark)
			}
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
	if !strings.Contains(body, "Nothing measured in this window") {
		t.Error("the usage page does not mark its unmeasured window unwired")
	}
	if !strings.Contains(body, `class="empty-state empty-state-hint"`) {
		t.Error("the usage page does not use the shared Emisar-style empty-state primitive")
	}
	// An unwired panel names what would fill it, so nobody has to guess whether
	// the number is zero or the pipe is missing. This deployment was handed an
	// empty price table, so the cost panel must distinguish the absent provider
	// report from the missing fallback estimate and point at the documented
	// shape — never render either absence as zero money.
	if !strings.Contains(body, "No provider-reported cost or price table") ||
		!strings.Contains(body, "config/ryker.example.yaml") {
		t.Error("the cost panel does not say the price table is missing or where the shape lives")
	}
	// Wall clock reads the timing columns now; with nothing timed it must say
	// nothing was timed rather than average an invented zero.
	if !strings.Contains(body, "Nothing timed in this window") {
		t.Error("the wall clock panel does not say nothing was timed")
	}
	// The token pipe landed. A page still claiming Coop does not report usage
	// would send an operator to plumb what is already plumbed, which is the same
	// class of lie as a panel that looks live and is not.
	if strings.Contains(body, "does not report them on the turn") {
		t.Error("the usage page still describes token accounting as unplumbed")
	}
	if strings.Contains(body, ">0<") {
		t.Error("the usage page renders a zero where it has no data")
	}
}

// Dense tables use Emisar's naked canvas treatment, but the viewport around
// them must still be keyboard-scrollable. Without the focusable frame, a wide
// audit or usage table is reachable with a pointer and clipped for a keyboard
// user on the same narrow screen.
func TestEveryDenseTableHasAKeyboardScrollableFrame(t *testing.T) {
	entries, err := assets.ReadDir("templates")
	if err != nil {
		t.Fatal(err)
	}
	table := regexp.MustCompile(`<table(?:\s|>)`)
	for _, entry := range entries {
		data, err := assets.ReadFile("templates/" + entry.Name())
		if err != nil {
			t.Fatal(err)
		}
		body := string(data)
		for _, at := range table.FindAllStringIndex(body, -1) {
			start := max(0, at[0]-180)
			frame := body[start:at[0]]
			if !strings.Contains(frame, `tabindex="0"`) ||
				(!strings.Contains(frame, `class="table-scroll"`) &&
					!strings.Contains(frame, `class="trace-table-wrap"`)) {
				t.Errorf("%s has a table without a focusable scroll frame near byte %d", entry.Name(), at[0])
			}
		}
	}
}

// Emisar keeps operating lists wide, entity detail a step narrower, and
// settings narrower again. That hierarchy is part of the shared shell rather
// than a page-by-page CSS accident, so a new detail route inherits it.
func TestShellUsesEmisarContentWidthTiers(t *testing.T) {
	if got := NewShell("episodes", "test", nil).Width; got != "width-table" {
		t.Errorf("list shell width = %q, want width-table", got)
	}

	detail := NewShell("episodes", "test", nil)
	detail.Width = detailWidth("episodes")
	if detail.Width != "width-detail" {
		t.Errorf("entity detail width = %q, want width-detail", detail.Width)
	}

	settings := NewShell("configuration", "test", nil)
	settings.Width = detailWidth("configuration")
	if settings.Width != "width-settings" {
		t.Errorf("settings detail width = %q, want width-settings", settings.Width)
	}
}

// The first redesign copied Emisar's colors but kept Ryker's old dashboard
// composition: a subtitle under every title, an overloaded dashboard rail,
// duplicate summaries, and a card around every trace step. These invariants
// keep the control plane on Emisar's actual hierarchy even when fixtures have
// too little data to exercise every optional branch in a rendered page.
func TestControlPlaneKeepsEmisarVisualHierarchy(t *testing.T) {
	read := func(name string) string {
		t.Helper()
		data, err := assets.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}

	layout := read("templates/layout.html")
	for _, required := range []string{
		`class="title-line{{if .Crumbs}} detail-title{{end}}"`,
		`class="brand-wordmark"`,
	} {
		if !strings.Contains(layout, required) {
			t.Errorf("shared shell lost %q", required)
		}
	}
	if strings.Contains(layout, `class="ask"`) {
		t.Error("shared shell put explanatory copy under every page title")
	}

	pages := read("templates/pages.html")
	for _, obsolete := range []string{`class="ov-grid"`, `class="rail-pulse"`, "Where work happens"} {
		if strings.Contains(pages, obsolete) {
			t.Errorf("list pages restored the redundant dashboard element %q", obsolete)
		}
	}
	for _, required := range []string{`class="overview-grid"`, `class="overview-upcoming"`} {
		if !strings.Contains(pages, required) {
			t.Errorf("dashboard lost the focused schedule rail %q", required)
		}
	}

	episode := read("templates/episode.html")
	for _, duplicate := range []string{`class="journey"`, `class="timebar"`} {
		if strings.Contains(episode, duplicate) {
			t.Errorf("episode detail restored the duplicate summary %q", duplicate)
		}
	}

	css := read("static/app.css")
	for _, offBrand := range []string{"#60a5fa", "#22d3ee", "#a78bfa", "#c084fc", "#f472b6"} {
		if strings.Contains(css, offBrand) {
			t.Errorf("trace palette restored off-brand color %s", offBrand)
		}
	}
	if !strings.Contains(css, ".trace-step-card {") ||
		!strings.Contains(css, "border-bottom: 1px solid var(--divide);") {
		t.Error("trace steps no longer form the continuous hairline timeline")
	}

	wordmark := read("static/emisar-wordmark.svg")
	if !strings.Contains(wordmark, `viewBox="0 0 896 155"`) {
		t.Error("shared shell no longer carries Emisar's wordmark geometry")
	}
}

// A table is a scan surface, not a database export. The control plane used to
// expose up to eleven equal-weight columns, forcing operators to read every
// heading before they could find the subject, state, or result of a row.
// Secondary facts now sit beneath their primary value, as they do in Emisar.
func TestTablesKeepACompactScanPath(t *testing.T) {
	headerRow := regexp.MustCompile(`(?s)<tr>\s*(?:<thead>)?\s*<th.*?</tr>`)
	header := regexp.MustCompile(`<th(?:\s|>)`)

	for _, name := range []string{
		"templates/audit.html",
		"templates/channel.html",
		"templates/incident.html",
		"templates/pages.html",
		"templates/workspaces.html",
	} {
		body, err := assets.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, row := range headerRow.FindAll(body, -1) {
			if columns := len(header.FindAll(row, -1)); columns > 6 {
				t.Errorf("%s has a %d-column table; stack supporting facts beneath the primary value", name, columns)
			}
		}
	}

	css, err := assets.ReadFile("static/app.css")
	if err != nil {
		t.Fatal(err)
	}
	for _, hierarchy := range []string{".cell-main {", ".cell-sub {", ".cell-action {"} {
		if !strings.Contains(string(css), hierarchy) {
			t.Errorf("shared table hierarchy lost %q", hierarchy)
		}
	}
}

func TestShellExposesKeyboardLocationAndSkipNavigation(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "ryker-abc1234",
		func() (bool, string) { return true, "" }, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/episodes", nil))
	body := recorder.Body.String()

	if !strings.Contains(body, `<a class="skip-link" href="#main-content">Skip to content</a>`) {
		t.Error("the shell has no skip link to its main content landmark")
	}
	// The navigation is rendered once in the desktop rail and once in the
	// native mobile drawer; each copy must expose the current page.
	if got := strings.Count(body, `aria-current="page"`); got != 2 {
		t.Errorf("active navigation markers = %d, want 2", got)
	}
}

// Every action confirms through a native <details> disclosure, never through
// script. The CSP is default-src 'none' with no script-src, so the inline
// onclick confirms these buttons used to carry never executed in a real
// browser — every destructive button fired on first click while looking
// guarded, which is a safety step that looks present and is not.
func TestActionsConfirmWithoutScript(t *testing.T) {
	entries, err := assets.ReadDir("templates")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		data, err := assets.ReadFile("templates/" + entry.Name())
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(data), "onclick") {
			t.Errorf("%s carries an inline handler; the CSP refuses those, so it is a confirm that never runs", entry.Name())
		}
	}
	render, err := NewRenderer()
	if err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	err = render.templates.ExecuteTemplate(&out, "confirm",
		confirmStep("Discard", "It will not be pinned.", "Yes, discard it", "/actions/corrections/discard", "cand_1"))
	if err != nil {
		t.Fatal(err)
	}
	step := out.String()
	for _, needed := range []string{
		"<details class=\"confirm\">", "<summary>Discard</summary>",
		"action=\"/actions/corrections/discard\"", "value=\"cand_1\"", "Yes, discard it",
	} {
		if !strings.Contains(step, needed) {
			t.Errorf("the confirm step is missing %q:\n%s", needed, step)
		}
	}
}

// The dashboard is read-only in v1. Loopback is the only thing between a button
// and production state, so a write path is opted into deliberately.
func TestNoWriteRoutesAreExposed(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "abc", nil, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(method, "/episodes", nil))
		if recorder.Code == http.StatusOK {
			t.Errorf("%s /episodes was accepted; reading pages never mutates", method)
		}
	}
	// A mutation is never a GET. One that were would fire on a preload or an
	// accidental revisit, and loopback is the only thing guarding it.
	for _, path := range []string{
		"/actions/corrections/keep", "/actions/corrections/discard", "/actions/failures/retry",
		"/actions/workspaces/publish", "/actions/workspaces/discard", "/actions/workspaces/rerun",
		"/actions/episodes/resolve", "/actions/episodes/review",
		"/actions/replays/cancel", "/actions/incidents/resolve",
		"/actions/memory/forget", "/actions/memory/keep", "/actions/memory/dismiss",
		"/actions/feedback/dismiss", "/actions/feedback/convert",
	} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code == http.StatusOK {
			t.Errorf("GET %s was accepted; actions must be POST", path)
		}
	}
}

// A build without write access offers no buttons, and refuses the routes rather
// than appearing to accept them. A control that looks live and is not is the
// defect this dashboard exists to stop showing.
func TestActionsRefusedWhenTheBuildCannotWrite(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "abc", nil, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if handler.CanAct() {
		t.Fatal("a handler with no Actions reports that it can act")
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/actions/corrections/keep",
		strings.NewReader("id=cand_1"))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	mux.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNotImplemented {
		t.Errorf("keep returned %d; a build that cannot write should say so", recorder.Code)
	}
}

// An action reports its failure. One that failed quietly while the page
// re-rendered unchanged would leave the operator believing it was done.
func TestActionFailureIsReported(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "abc", nil, config.Pricing{}, nil, failingActions{})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/actions/corrections/keep",
		strings.NewReader("id=cand_1"))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	mux.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusInternalServerError {
		t.Errorf("a failed action returned %d, want 500", recorder.Code)
	}
	if !strings.Contains(recorder.Body.String(), "store refused") {
		t.Errorf("the reason did not reach the operator: %q", recorder.Body.String())
	}
}

type failingActions struct{}

func (failingActions) KeepCorrection(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) SetSchedulePaused(context.Context, string, bool, string) error {
	return errors.New("store refused")
}
func (failingActions) RerunEpisode(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) DeleteSchedule(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) DiscardCorrection(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) RetryFailure(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) SetChannelSetting(context.Context, string, string, string, string) error {
	return errors.New("store refused")
}
func (failingActions) PublishRetainedWork(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) DiscardRetainedWork(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) RerunCleanup(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) DiscardWorkspace(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) ReviewEpisode(context.Context, string, string, string) error {
	return errors.New("store refused")
}
func (failingActions) ResolveEpisodeOvertaken(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) CancelSlackReplay(context.Context, string, string, string) error {
	return errors.New("store refused")
}
func (failingActions) ResolveIncident(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) ForgetMemory(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) KeepMemoryReview(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) DismissMemoryReview(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) DismissFeedback(context.Context, string, string) error {
	return errors.New("store refused")
}
func (failingActions) ConvertFeedback(context.Context, string, string) error {
	return errors.New("store refused")
}

// Every list must be a way in, not a dead end. A grouped failure that cannot be
// opened tells you twenty-nine runs hit one error and gives you no route to any
// of them; a conversation row that cannot be opened counts a memory without
// showing what is in it.
func TestListsLinkToDetail(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "47", "abc", nil, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)

	// The detail routes exist and answer, rather than falling through to the
	// list route and silently rendering the wrong page.
	for _, path := range []string{
		"/episodes/ep_missing",
		"/incidents/inc_missing",
		"/failures/0000000000000000",
		"/conversations/C1/channel",
		// An audit kind nobody ever recorded must 404 rather than render an
		// empty table, which reads as "this never happens" when the truth is
		// that the URL was wrong.
		"/audit/slack.invented",
	} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d; an unknown entity should be 404, not a page about something else",
				path, recorder.Code)
		}
	}
}

// The timeline has to say what happened, not name event kinds. A generic scan
// of top-level keys rendered six evidence rows as the word "evidence_recorded"
// six times and a completion — the whole answer — as nothing at all, because
// the substance is nested and differs per kind.
func TestTimelineSummariesUnpackEachKind(t *testing.T) {
	for _, testCase := range []struct{ kind, payload, want string }{
		{"evidence_recorded",
			`{"evidence":{"claim":"The run has not produced a plan","observation":"still planning"}}`,
			"The run has not produced a plan"},
		{"evidence_recorded",
			`{"evidence":{"observation":"eight hosts responsive"}}`,
			"eight hosts responsive"},
		{"completion_submitted",
			`{"completion":{"message":"Degraded.","completion":{"status":"blocked","verdict":"confirmed"}}}`,
			"blocked · confirmed — Degraded."},
		{"context_extended",
			`{"reference_count":5,"version":1}`,
			"5 references, manifest v1"},
		{"destination_changed",
			`{"reason":"communication_policy"}`,
			"reply routed elsewhere · communication policy"},
		{"phase_changed", `{"status":"Planning the work"}`, "Planning the work"},
		// A kind-specific branch that guesses wrong must not silence the generic
		// one; progress reports went blank that way while this was being built.
		{"progress_reported", `{"summary":"Still working"}`, "Still working"},
	} {
		if got := summarizePayload(testCase.kind, testCase.payload); got != testCase.want {
			t.Errorf("summarizePayload(%s) = %q, want %q", testCase.kind, got, testCase.want)
		}
	}
}

// Waiting is one fact however long it lasts. A run polling once a second wrote
// a phase_changed event every second — 5,483 identical "waiting for the
// previous agent run" rows, 47% of the whole episode stream. The store no
// longer writes those repeats, but they are already on disk and history still
// has to be readable, so consecutive identical events collapse to one row with
// a count and the span they cover.
func TestConsecutiveIdenticalEventsCollapse(t *testing.T) {
	base := time.Date(2026, 8, 8, 16, 31, 0, 0, time.UTC)
	rows := []Event{}
	for index := range 24 {
		rows = append(rows, Event{
			Kind: "phase_changed", Actor: "host",
			Detail: "waiting for the previous agent run in this Slack channel",
			At:     base.Add(time.Duration(index) * time.Second),
		})
	}
	collapsed := collapseEvents(rows)
	if len(collapsed) != 1 {
		t.Fatalf("24 identical events rendered as %d rows, want 1", len(collapsed))
	}
	if collapsed[0].Repeats != 23 {
		t.Errorf("repeat count = %d, want 23", collapsed[0].Repeats)
	}
	if collapsed[0].Span != "23s" {
		t.Errorf("span = %q, want the time it covered", collapsed[0].Span)
	}

	// A different event breaks the run: collapsing must not merge across a
	// change, or a timeline would hide the thing that actually happened.
	rows = append(rows, Event{Kind: "phase_changed", Detail: "Investigating", At: base.Add(time.Minute)})
	if got := len(collapseEvents(rows)); got != 2 {
		t.Errorf("a distinct event was swallowed: %d rows, want 2", got)
	}
}

// The response section shows the answer, not the transport.
//
// The stored result arrives in three shapes and a display decoder that only
// handled the bare envelope rendered a thousand characters of raw JSON where
// the reply should be, because the model narrated before fencing its answer.
// This reads it with decision.ParseWatchDecision — the parser the host itself
// used — so the page shows what was actually read rather than a second guess
// at it.
func TestTheTurnReadsEveryShapeTheResultArrivesIn(t *testing.T) {
	evidence := func(id, claim string) string {
		return `{"id":"` + id + `","type":"record_evidence","evidence":{"claim_id":"host.current_state",` +
			`"claim":"` + claim + `","observation":"the host answered","relation":"supports",` +
			`"source_type":"monitoring","source_name":"node exporter"}}`
	}
	envelope := `{"action":"reply","reason":"live evidence confirms the alert",` +
		`"message":"Checkout errors are affecting requests.",` +
		`"attention":{"addressee":"channel","confidence":3,"novelty":2,"ownership":2},` +
		`"operations":[` + evidence("a", "the host is up") + `,` +
		evidence("b", "the host has headroom") + `,` +
		`{"id":"c","type":"record_coverage","coverage":{"layer":"host","status":"healthy",` +
		`"detail":"every node answered"}},` +
		`{"id":"done","type":"complete_episode","completion":{"message":"Checkout errors are ` +
		`affecting requests.","completion":{"status":"decision_ready","verdict":"unhealthy",` +
		`"summary":"One backend is failing checkout requests."}}}]}`

	var bare Turn
	bare.readResult(envelope)
	if bare.Action != "reply" || bare.Message == "" {
		t.Errorf("a bare envelope did not decode: %+v", bare)
	}
	if bare.Prose != "" {
		t.Errorf("a decoded envelope was also dumped as prose: %q", truncate(bare.Prose, 60))
	}
	// The heaviest operation leads: a turn that recorded six pieces of evidence
	// and completed once spent itself on the evidence, and map order would have
	// buried that behind whichever key iterated first.
	if len(bare.Operations) != 3 || bare.Operations[0] != (Tally{"record_evidence", 2}) {
		t.Errorf("operations were not tallied by weight: %+v", bare.Operations)
	}
	// Urgency was not sent. Rendering it as 0 would read as "nothing urgent"
	// rather than "not scored".
	if bare.Attention != "channel · confidence 3 · novelty 2 · ownership 2" {
		t.Errorf("attention line = %q", bare.Attention)
	}

	var fenced Turn
	fenced.readResult("Let me emit the closure record properly.\n\n```json\n" + envelope + "\n```")
	if fenced.Action != "reply" {
		t.Errorf("an envelope fenced inside narration was not read: %+v", fenced)
	}
	if fenced.Prose != "" {
		t.Error("a fenced envelope was dumped as prose instead of decoded")
	}

	var prose Turn
	prose.readResult("I corrected the organization and re-ran the validation.")
	if prose.Prose == "" {
		t.Error("a prose answer rendered as nothing at all")
	}
	// The failure is the answer, not a gap: an unreadable result is why the
	// episode retried, and the parser's own complaint says which part was wrong.
	if prose.Unreadable == "" {
		t.Error("an unreadable result did not say the host could not read it")
	}
}

// A reference list has to say what the reference points at. The stored string
// restates the kind column and buries the part a reader can use.
func TestManifestReferencesAreDescribedNotRestated(t *testing.T) {
	reader := &Reader{}
	ctx := context.Background()
	for _, testCase := range []struct{ kind, ref, revision, metadata, want string }{
		{"compiled_prompt", "agent-run:run_2e29ee88f6d4be177b60ab9f7d66e062:prompt", "", "",
			"attempt run_2e29ee88f6d4\u2026"},
		{"repository", "repository:blitz-platform", "797bcedb8d26dfbedb36f6ec68847dc3f17296d6", "",
			"blitz-platform @ 797bcedb\u2026"},
		{"execution_policy", "coop-policy:blitz-platform-observe", "", "",
			"blitz-platform-observe"},
		{"artifact", "artifact:github-pr-509.md:0", "",
			`{"media_type":"text/markdown","name":"github-pr-509.md"}`,
			"github-pr-509.md (text/markdown)"},
	} {
		got := reader.describeRef(ctx, testCase.kind, testCase.ref, testCase.revision, testCase.metadata)
		if got != testCase.want {
			t.Errorf("describeRef(%s) = %q, want %q", testCase.kind, got, testCase.want)
		}
	}
}

// A slash command that failed on a dead channel eleven times in twenty minutes
// took eleven of the forty rows on the audit page and pushed everything else
// that happened that hour off it. Eleven identical failures are one fact.
func TestIdenticalAuditRowsFold(t *testing.T) {
	base := time.Date(2026, 8, 8, 23, 18, 0, 0, time.UTC)
	rows := []AuditRow{}
	for index := range 11 {
		rows = append(rows, AuditRow{
			Kind: "slack.command.feedback", Outcome: "failed", Actor: "U089UCBNT38",
			Detail: "channel_not_found",
			At:     base.Add(time.Duration(index) * time.Minute),
		})
	}
	folded := foldAudit(rows)
	if len(folded) != 1 {
		t.Fatalf("11 identical actions rendered as %d rows, want 1", len(folded))
	}
	if folded[0].Repeats != 10 || folded[0].Span != "10m0s" {
		t.Errorf("fold lost the count or the span: %+v", folded[0])
	}
	// A different outcome breaks the run. Merging across one would hide the
	// action that actually differed, which is the only one worth reading.
	rows = append(rows, AuditRow{
		Kind: "slack.command.feedback", Outcome: "succeeded", Actor: "U089UCBNT38",
		At: base.Add(time.Hour),
	})
	if got := len(foldAudit(rows)); got != 2 {
		t.Errorf("a distinct outcome was swallowed: %d rows, want 2", got)
	}
}

// There is no directory that turns a Slack id into a name, so the log says what
// kind of thing acted. Inventing a name would be worse than the id, and the
// distinction that matters reading back is person versus app versus the host.
func TestAuditActorsAreClassifiedNotInvented(t *testing.T) {
	for actor, want := range map[string]string{
		"U089UCBNT38":           "person",
		"B08N64XSHNU":           "app",
		"responder":             "ryker",
		dashboardActor:          "this dashboard",
		"":                      "unattributed",
		"scheduled-task-runner": "host",
	} {
		if got := whom(actor); got != want {
			t.Errorf("whom(%q) = %q, want %q", actor, got, want)
		}
	}
}

// A title that cleaned down to punctuation is not a title. A Slack permalink
// posted with the same URL as its own link text arrives truncated, both halves
// strip as bare links, and the separator survives alone: one row of the episode
// list was the single character "|".
func TestATitleStrippedToPunctuationIsNotATitle(t *testing.T) {
	permalink := "<https://theblitzapp.slack.com/archives/C091FK0SXGU/p1786193195175159?" +
		"thread_ts=1786136831.213219&cid=C091FK0SXGU|https://theblitzapp.slack.com/archives/p178"
	if got := cleanTitle(permalink); got != "Untitled work" {
		t.Errorf("cleanTitle stripped a permalink down to %q", got)
	}
	// The ordinary case still keeps its words: stripping must not become
	// discarding.
	alert := "<https://grafana.example/alerting/view?orgId=1|[VA1 FIRING:1] CRITICAL " +
		"Cassandra Reaper schedule overdue> *FIRING*"
	if got := cleanTitle(alert); !strings.Contains(got, "Cassandra Reaper schedule overdue") {
		t.Errorf("cleanTitle lost the alert text: %q", got)
	}
}

// Which model answered belongs on every row that has one.
//
// It was recorded per attempt and rendered in one table near the bottom of the
// episode page, behind a conditional that was false for every row in the
// database because nothing had ever populated the column. Two separate
// failures wearing one symptom: the value was missing, and the one place that
// would have shown it hid itself when it was.
func TestEveryEpisodeRowNamesTheModelThatAnsweredIt(t *testing.T) {
	answered := Item{Model: "opus", Effort: "max", Provider: "claude"}
	if got := answered.Answered(); got != "opus/max" {
		t.Errorf("Answered() = %q, want the model and the effort", got)
	}
	// The effort is the whole difference between two rungs of one ladder, so
	// it travels with the model rather than being dropped for brevity.
	if got := (Item{Model: "opus", Provider: "claude"}).Answered(); got != "opus" {
		t.Errorf("Answered() without an effort = %q, want just the model", got)
	}
	// An attempt frozen before the target was recorded says nothing rather
	// than inventing a default — the row must not claim a model that may not
	// have been the one that ran.
	if got := (Item{}).Answered(); got != "" {
		t.Errorf("Answered() with nothing recorded = %q, want empty", got)
	}
}

// The channel settings action carries three fields, not one, so it validates
// them itself rather than through act. The value list is closed: this surface
// offers on, off and inherit, and anything else is a request it never made.
func TestChannelSettingRefusesWhatItNeverOffered(t *testing.T) {
	handler, err := NewHandler(&Reader{}, "test", "50", "abc", nil, config.Pricing{}, nil, failingActions{})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)

	post := func(body string) int {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/actions/channels/setting",
			strings.NewReader(body))
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		mux.ServeHTTP(recorder, request)
		return recorder.Code
	}

	for _, refused := range []string{
		"id=C1&name=proactive&value=maybe", // not one of the three
		"id=C1&name=repository&value=on",   // a setting this surface cannot write
		"name=proactive&value=on",          // no channel
	} {
		if code := post(refused); code != http.StatusBadRequest {
			t.Errorf("POST %q = %d, want 400", refused, code)
		}
	}
	// A well-formed request reaches the service, and its failure is reported
	// rather than swallowed into a redirect that looks like success.
	if code := post("id=C1&name=shadow&value=inherit"); code != http.StatusInternalServerError {
		t.Errorf("a failing action returned %d, want the error surfaced", code)
	}
}
