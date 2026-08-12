package webui

import (
	"context"
	"html/template"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
)

// Handler serves the control plane. Read-only in v1: every write path is opted
// into individually, because loopback is the only thing standing between a
// button and production state.
type Handler struct {
	reader     *Reader
	render     *Renderer
	deployment string
	schema     string
	binary     string
	ready      func() bool
	prompts    []PromptBudget
	pricing    config.Pricing
	actions    Actions
}

// PromptBudget is measured by the caller, which owns the prompt builders.
type PromptBudget struct {
	Name  string
	Bytes int
	Cap   int
}

func (p PromptBudget) Left() int    { return max(p.Cap-p.Bytes, 0) }
func (p PromptBudget) LeftPct() int { return percent(p.Left(), p.Cap) }

// NewHandler takes the price table by value from configuration: prices change
// on the provider's schedule, so they live in the operator's file rather than
// in this binary, and an empty table is a valid answer that the Usage page
// reports as "not priced" rather than as zero money.
func NewHandler(
	reader *Reader,
	deployment, schema, binary string,
	ready func() bool,
	prompts []PromptBudget,
	pricing config.Pricing,
	actions Actions,
) (*Handler, error) {
	render, err := NewRenderer()
	if err != nil {
		return nil, err
	}
	if ready == nil {
		ready = func() bool { return true }
	}
	return &Handler{
		reader: reader, render: render, deployment: deployment,
		schema: schema, binary: binary, ready: ready, prompts: prompts,
		pricing: pricing, actions: actions,
	}, nil
}

func (h *Handler) Register(mux *http.ServeMux) {
	mux.Handle("GET /static/", Static())
	mux.HandleFunc("GET /{$}", h.overview)
	mux.HandleFunc("GET /episodes", h.episodes)
	mux.HandleFunc("GET /episodes/{id}", h.episode)
	mux.HandleFunc("GET /incidents/{id}", h.incident)
	mux.HandleFunc("GET /failures", h.failures)
	mux.HandleFunc("GET /failures/{key}", h.failure)
	mux.HandleFunc("GET /workspaces", h.workspaces)
	mux.HandleFunc("GET /conversations/{channel}/{thread}", h.conversation)
	mux.HandleFunc("GET /decisions", h.decisions)
	mux.HandleFunc("GET /findings", h.findings)
	mux.HandleFunc("GET /audit", h.audit)
	mux.HandleFunc("GET /audit/{kind}", h.auditKind)
	mux.HandleFunc("GET /memory", h.memory)
	mux.HandleFunc("GET /configuration", h.configuration)
	mux.HandleFunc("GET /channels/{id}", h.channel)
	mux.HandleFunc("GET /usage", h.usage)
	// Writes are POST only, and only these routes. Each calls the same store
	// or service path the equivalent Slack button calls.
	mux.HandleFunc("POST /actions/corrections/keep", h.keepCorrection)
	mux.HandleFunc("POST /actions/corrections/discard", h.discardCorrection)
	mux.HandleFunc("POST /actions/failures/retry", h.retryFailure)
	mux.HandleFunc("POST /actions/workspaces/publish", h.publishRetainedWork)
	mux.HandleFunc("POST /actions/workspaces/discard", h.discardRetainedWork)
	mux.HandleFunc("POST /actions/workspaces/rerun", h.rerunCleanup)
	mux.HandleFunc("POST /actions/workspaces/discard-session", h.discardWorkspace)
	mux.HandleFunc("POST /actions/episodes/resolve", h.resolveEpisode)
	mux.HandleFunc("POST /actions/replays/cancel", h.cancelSlackReplay)
	mux.HandleFunc("POST /actions/incidents/resolve", h.resolveIncident)
	mux.HandleFunc("POST /actions/memory/forget", h.forgetMemory)
	mux.HandleFunc("POST /actions/memory/keep", h.keepMemoryReview)
	mux.HandleFunc("POST /actions/memory/dismiss", h.dismissMemoryReview)
	mux.HandleFunc("POST /actions/feedback/dismiss", h.dismissFeedback)
	mux.HandleFunc("POST /actions/feedback/convert", h.convertFeedback)
	mux.HandleFunc("POST /actions/channels/setting", h.channelSetting)
}

// CanAct reports whether this build was given write access, so a page can offer
// a button only when pressing it would do something.
func (h *Handler) CanAct() bool { return h.actions != nil }

// trouble renders a refusal or a miss inside the shell instead of as two
// words of bare text. http.Error and http.NotFound answer in unstyled
// plaintext, and on a dashboard where every other state is designed, the
// browser-default page reads as a crash rather than an answer — the operator
// who mistyped an episode id deserves the same typography as one who did not.
func (h *Handler) trouble(w http.ResponseWriter, r *http.Request, code int, kind, message string) {
	back := r.Header.Get("Referer")
	if back == "" || !strings.HasPrefix(back, "http://127.0.0.1") {
		back = "/"
	}
	w.WriteHeader(code)
	shell := h.shell(r, "", struct {
		Code          int
		Kind, Message string
		Back          string
		Bad           bool
	}{code, kind, message, back, code >= 500})
	shell.TitleOverride = kind
	h.render.Render(w, "trouble", shell)
}

// page names the body template explicitly rather than deriving it from the
// slug: the episode detail page lives under the Episodes nav entry but is its
// own template, and inferring one from the other would couple navigation to
// rendering for no benefit.
func (h *Handler) page(w http.ResponseWriter, r *http.Request, slug, body string, content any) {
	shell := h.shell(r, slug, content)
	if slug == "" {
		shell.Refresh = 30
	}
	h.render.Render(w, body, shell)
}

// detail renders an entity page: titled after the entity, pointing back at its
// section. With the section name as the h1, an episode page was headed
// "Episodes" and its subject was buried in a panel below a bare back-link.
func (h *Handler) detail(w http.ResponseWriter, r *http.Request, slug, body, title string, content any) {
	shell := h.shell(r, slug, content)
	shell.TitleOverride = truncate(title, 90)
	for _, page := range pages {
		if page.Slug == slug {
			shell.Crumbs = []Crumb{{Href: "/" + slug, Label: page.Title}}
		}
	}
	h.render.Render(w, body, shell)
}

func (h *Handler) shell(r *http.Request, slug string, content any) Shell {
	shell := NewShell(slug, h.deployment, content)
	shell.Binary, shell.Schema, shell.Ready = h.binary, h.schema, h.ready()
	ctx := r.Context()
	// A few tiny counts per render, against a local SQLite. The alternative —
	// badges only on the pages that computed them — made the numbers appear
	// and vanish as you navigated, which reads as the counts changing.
	shell.Badges = map[string]Badge{
		"": {N: h.reader.Count(ctx, `SELECT COUNT(*) FROM work_episodes
		  WHERE lifecycle_state IN ('blocked','waiting_operator','waiting_approval')`), Warn: true},
		"failures":   {N: h.reader.Count(ctx, `SELECT COUNT(*) FROM agent_runs WHERE terminal_state = 'failed'`)},
		"workspaces": {N: h.reader.Count(ctx, countRetained), Warn: true},
		"decisions":  {N: h.reader.Count(ctx, `SELECT COUNT(*) FROM fixture_candidates WHERE status = 'pending'`), Warn: true},
		// Confirmed only, and not a warning. There is no action to take on a
		// finding from this page, so a red badge would be a to-do nobody can
		// discharge; the number is here because a page nobody opens is the
		// state this whole change exists to leave behind.
		"findings": {N: h.reader.Count(ctx, countConfirmedFindings)},
	}
	return shell
}

// problems collects what a page could not load.
//
// A read error is reported, not swallowed. Discarding one rendered "98 failed
// work items" directly above "No failed work", and a second discarded error —
// an evidence query against a column that does not exist — reported "No
// evidence was recorded" on every episode in the database. Each section names
// itself so the page says which part is missing rather than going quiet.
type problems []string

func (p *problems) note(section string, err error) {
	if err != nil {
		*p = append(*p, section+": "+err.Error())
	}
}

// blockedRow folds duplicates: the same alert firing twice makes two episodes
// with the same headline, and two identical rows read as a rendering fault
// rather than two events.
type blockedRow struct {
	Item
	Repeats int
}

func foldBlocked(items []Item) []blockedRow {
	rows := make([]blockedRow, 0, len(items))
	for _, item := range items {
		if last := len(rows) - 1; last >= 0 &&
			rows[last].Title == item.Title && rows[last].Channel == item.Channel {
			rows[last].Repeats++
			continue
		}
		rows = append(rows, blockedRow{Item: item})
	}
	return rows
}

func (h *Handler) overview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	blocked, _ := h.reader.Blocked(ctx, 8)

	var failed problems
	lanes, err := h.reader.Lanes(ctx)
	failed.note("queues", err)
	schedules, err := h.reader.Schedules(ctx)
	failed.note("scheduled tasks", err)
	h.page(w, r, "", "overview", struct {
		NeedsYou, Failed, InFlight, Retained int
		Blocked                              []blockedRow
		Lanes                                []Lane
		Schedules                            []Schedule
		Errs                                 problems
		Deployment, Binary, Schema           string
		Ready                                bool
	}{
		Lanes: lanes, Schedules: schedules, Errs: failed,
		NeedsYou:   h.reader.Count(ctx, countNeedsDecision),
		Failed:     h.reader.Count(ctx, countFailedRuns),
		InFlight:   h.reader.Count(ctx, countInFlight),
		Retained:   h.reader.Count(ctx, countRetained),
		Blocked:    foldBlocked(blocked),
		Deployment: h.deployment, Binary: h.binary, Schema: h.schema, Ready: h.ready(),
	})
}

// episodePageSize keeps one page readable; the pager reaches the rest.
const episodePageSize = 50

// episodes lists the work, optionally narrowed to one slice of it.
//
// The filter is what makes the Usage breakdowns openable, and the search box
// is what makes eight hundred episodes findable: the query is a plain GET, so
// a filtered page stays a URL that can be bookmarked or pasted into a thread.
// Incident rooms are dropped while a filter is active: they are not filtered
// by it, and an unfiltered table sitting above a filtered list reads as part
// of the same answer.
func (h *Handler) episodes(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var failed problems
	filter := h.episodeFilter(ctx, r)
	episodes, err := h.reader.EpisodesMatching(ctx, filter, episodePageSize)
	failed.note("episodes", err)
	total, err := h.reader.CountMatching(ctx, filter)
	failed.note("episode count", err)
	states, err := h.reader.EpisodeStates(ctx)
	failed.note("states", err)
	rooms := []Room{}
	if !filter.Active() {
		rooms, err = h.reader.Rooms(ctx)
		failed.note("incident rooms", err)
	}
	page := struct {
		Episodes     []Item
		Rooms        []Room
		Errs         problems
		Filter       EpisodeFilter
		Total        int
		States       []string
		From, To     int
		Older, Newer template.URL
	}{Episodes: episodes, Rooms: rooms, Errs: failed, Filter: filter,
		Total: total, States: states}
	page.From, page.To = filter.Offset+1, filter.Offset+len(episodes)
	if filter.Offset+episodePageSize < total {
		page.Older = episodesURL(filter, filter.Offset+episodePageSize)
	}
	if filter.Offset > 0 {
		page.Newer = episodesURL(filter, max(filter.Offset-episodePageSize, 0))
	}
	h.page(w, r, "episodes", "episodes", page)
}

func (h *Handler) episodeFilter(ctx context.Context, r *http.Request) EpisodeFilter {
	query := r.URL.Query()
	filter := EpisodeFilter{
		Channel:    strings.TrimSpace(query.Get("channel")),
		Repository: strings.TrimSpace(query.Get("repository")),
		Mode:       strings.TrimSpace(query.Get("mode")),
		Provider:   strings.TrimSpace(query.Get("provider")),
		Model:      strings.TrimSpace(query.Get("model")),
		Query:      strings.TrimSpace(query.Get("q")),
		State:      strings.TrimSpace(query.Get("state")),
		Offset:     pageOffset(query.Get("offset")),
	}
	filter.ChannelName = h.reader.channelName(ctx, filter.Channel)
	return filter
}

// pageOffset reads an offset that came from a link this dashboard wrote.
// Anything unreadable or negative is page one, not an error page: the URL is
// user-editable and a mistyped offset should land somewhere useful.
func pageOffset(raw string) int {
	offset, err := strconv.Atoi(raw)
	if err != nil || offset < 0 {
		return 0
	}
	return offset
}

// episodesURL rebuilds the list URL for a different page of the same filter,
// so pagination can never drop a filter term and quietly widen the list.
func episodesURL(filter EpisodeFilter, offset int) template.URL {
	values := url.Values{}
	for _, param := range []struct{ key, value string }{
		{"q", filter.Query}, {"state", filter.State},
		{"channel", filter.Channel}, {"repository", filter.Repository},
		{"mode", filter.Mode}, {"provider", filter.Provider}, {"model", filter.Model},
	} {
		if param.value != "" {
			values.Set(param.key, param.value)
		}
	}
	if offset > 0 {
		values.Set("offset", strconv.Itoa(offset))
	}
	if len(values) == 0 {
		return template.URL("/episodes")
	}
	return template.URL("/episodes?" + values.Encode()) //nolint:gosec // literal path, encoded values
}

// episodePage is the whole record of one piece of work.
//
// Every debugging question in this repository's history is answered here, and
// until now was answered by running sqlite against a production database.
type episodePage struct {
	Item
	Turn       Turn
	Turns      []Turn
	Source     SourceInput
	Trigger    SourceInput
	Wakeup     Wakeup
	Wakeups    []Wakeup
	Trace      EpisodeTrace
	Events     []Event
	Claims     []ClaimRow
	Evidence   []EvidenceRow
	Coverage   []CoverageRow
	Manifest   ManifestRow
	Manifests  []ManifestRow
	Attempts   []Attempt
	Rejections []Rejection
	Artifacts  []EpisodeArtifact
	Delivered  []Delivery
	Effects    []SideEffect
	Audit      []AuditRow
	Errs       problems
	Spent      EpisodeTokens
	CanAct     bool
	// Resolvable gates the overtaken-by-events action to the states where a
	// person is what the episode is waiting for. The kernel re-checks on the
	// way through; this only decides whether a button is honest to offer.
	Resolvable bool
}

// resolvableState lists the lifecycle states an operator may close as
// overtaken: the episode is parked on a person, an approval, or an external
// event, and no worker owns it. Running work is stopped through Slack's stop
// control, not silently cancelled from a dashboard.
func resolvableState(state string) bool {
	switch state {
	case "blocked", "waiting_operator", "waiting_approval", "waiting_external":
		return true
	default:
		return false
	}
}

func (h *Handler) episode(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	item, err := h.reader.Episode(ctx, id)
	if err != nil || item.ID == "" {
		h.trouble(w, r, http.StatusNotFound, "No such episode",
			"Nothing on record carries this id. If it came from an old link, the episode may predate the event ledger.")
		return
	}
	page := episodePage{Item: item, CanAct: h.CanAct(), Resolvable: resolvableState(item.State)}
	page.Events, err = h.reader.Events(ctx, id)
	page.Errs.note("timeline", err)
	page.Source, err = h.reader.SourceInput(ctx, id)
	page.Errs.note("source input", err)
	page.Trigger, err = h.reader.TriggerInput(ctx, id)
	page.Errs.note("episode trigger", err)
	page.Wakeups, err = h.reader.Wakeups(ctx, id, page.Trigger.ID)
	page.Errs.note("scheduled wake-ups", err)
	if len(page.Wakeups) > 0 {
		page.Wakeup = page.Wakeups[len(page.Wakeups)-1]
	}
	page.Turns, err = h.reader.Turns(ctx, id)
	page.Errs.note("model turns", err)
	if len(page.Turns) > 0 {
		page.Turn = page.Turns[len(page.Turns)-1]
	}
	page.Claims, err = h.reader.Claims(ctx, id)
	page.Errs.note("claims", err)
	page.Evidence, err = h.reader.Evidence(ctx, id)
	page.Errs.note("evidence", err)
	page.Coverage, err = h.reader.Coverage(ctx, id)
	page.Errs.note("coverage", err)
	page.Manifests, err = h.reader.Manifests(ctx, id)
	page.Errs.note("context manifests", err)
	if len(page.Manifests) > 0 {
		page.Manifest = page.Manifests[len(page.Manifests)-1]
	}
	page.Attempts, err = h.reader.Attempts(ctx, id)
	page.Errs.note("attempts", err)
	page.Rejections, err = h.reader.Rejections(ctx, id)
	page.Errs.note("host corrections", err)
	page.Artifacts, err = h.reader.Artifacts(ctx, id)
	page.Errs.note("durable episode records", err)
	page.Delivered, err = h.reader.Deliveries(ctx, id)
	page.Errs.note("delivery", err)
	confirmedEffects, err := h.reader.SideEffects(ctx, id)
	page.Errs.note("side effects", err)
	page.Effects = episodeSideEffects(page.Turns, confirmedEffects)
	page.Audit, err = h.reader.AuditForEpisode(ctx, id)
	page.Errs.note("audit trail", err)
	page.Spent, err = h.reader.EpisodeTokens(ctx, id)
	page.Errs.note("token usage", err)
	present := func(text string) string { return h.reader.resolveSlackText(ctx, text) }
	page.Trace = buildEpisodeTrace(h.pricing, page, present)
	shell := h.shell(r, "episodes", page)
	shell.TitleOverride = episodeDisplayTitle(page)
	shell.Crumbs = []Crumb{{Href: "/episodes", Label: "Episodes"}}
	if page.Source.ChannelID != "" {
		shell.Crumbs = append(shell.Crumbs, Crumb{
			Href: "/channels/" + url.PathEscape(page.Source.ChannelID), Label: page.Source.Channel,
		})
	}
	h.render.Render(w, "episode", shell)
}

func episodeSideEffects(turns []Turn, confirmed []SideEffect) []SideEffect {
	inferred := make([]SideEffect, 0)
	for _, turn := range turns {
		for _, effect := range turn.Effects {
			if effect.At.IsZero() {
				effect.At = turn.Updated
			}
			inferred = append(inferred, effect)
		}
	}
	return mergeSideEffects(inferred, confirmed)
}

var leadingSlackAddressee = regexp.MustCompile(`^@\S+\s+`)

func episodeDisplayTitle(page episodePage) string {
	title := strings.TrimSpace(leadingSlackAddressee.ReplaceAllString(page.Source.Text, ""))
	if title == "" {
		title = page.Title
	}
	return truncate(cleanTitle(title), 90)
}

// incident opens the room a whole conversation of work happened in: the ask
// that started it, what was said back, and the pull request that came out.
func (h *Handler) incident(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	room, err := h.reader.Room(ctx, id)
	if err != nil || room.ID == "" {
		h.trouble(w, r, http.StatusNotFound, "No such incident room",
			"Nothing on record carries this id.")
		return
	}
	page := struct {
		Room
		Signals   []Signal
		Moments   []Moment
		Published Publication
		Episodes  []Item
		Audit     []AuditRow
		Errs      problems
		CanAct    bool
	}{Room: room, CanAct: h.CanAct()}
	page.Signals, err = h.reader.Signals(ctx, id)
	page.Errs.note("signals", err)
	page.Moments, err = h.reader.Moments(ctx, id)
	page.Errs.note("timeline", err)
	page.Published, err = h.reader.Publication(ctx, id)
	page.Errs.note("publication", err)
	page.Episodes, err = h.reader.EpisodesForIncident(ctx, id)
	page.Errs.note("episodes", err)
	page.Audit, err = h.reader.AuditForIncident(ctx, id)
	page.Errs.note("audit trail", err)
	h.detail(w, r, "episodes", "incident", page.Title, page)
}

func (h *Handler) audit(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var failed problems
	kinds, err := h.reader.AuditKinds(ctx)
	failed.note("kinds", err)
	recent, err := h.reader.AuditRecent(ctx, 40)
	failed.note("recent activity", err)
	h.page(w, r, "audit", "audit", struct {
		Kinds  []AuditGroup
		Recent []AuditRow
		Errs   problems
		Total  int
	}{kinds, recent, failed, h.reader.Count(ctx, countAudited)})
}

func (h *Handler) auditKind(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	kind := r.PathValue("kind")
	if !h.reader.KnownAuditKind(ctx, kind) {
		h.trouble(w, r, http.StatusNotFound, "No such audit kind",
			"No event of this kind has been recorded. The audit page lists every kind that has.")
		return
	}
	query := r.URL.Query()
	// The window keys are the Usage page's, so "last 7 days" means the same
	// thing on every page; audit defaults to everything because its question
	// is usually "when did this ever happen".
	sinceKey := query.Get("since")
	if sinceKey == "" {
		sinceKey = "all"
	}
	windows := UsageWindows(sinceKey, time.Now().UTC())
	window := chosenWindow(windows)
	filter := AuditFilter{
		Kind:     kind,
		Actor:    strings.TrimSpace(query.Get("actor")),
		Since:    window.Since,
		SinceKey: window.Key,
		Offset:   pageOffset(query.Get("offset")),
	}
	var failed problems
	events, err := h.reader.AuditOfKindFiltered(ctx, filter)
	failed.note("events", err)
	total, err := h.reader.CountAuditOfKind(ctx, filter)
	failed.note("count", err)
	page := struct {
		Kind         string
		Events       []AuditRow
		Errs         problems
		Filter       AuditFilter
		Total, Raw   int
		From, To     int
		Windows      []UsageWindow
		Older, Newer template.URL
	}{Kind: kind, Events: events, Errs: failed, Filter: filter,
		Total: total, Windows: windows}
	// Raw is rows before identical neighbours fold; the caption carries both
	// so a folded page cannot be mistaken for a short one.
	page.Raw = min(auditPageSize, max(total-filter.Offset, 0))
	page.From, page.To = filter.Offset+1, filter.Offset+page.Raw
	if filter.Offset+auditPageSize < total {
		page.Older = auditKindURL(filter, filter.Offset+auditPageSize)
	}
	if filter.Offset > 0 {
		page.Newer = auditKindURL(filter, max(filter.Offset-auditPageSize, 0))
	}
	h.detail(w, r, "audit", "auditkind", kind, page)
}

func auditKindURL(filter AuditFilter, offset int) template.URL {
	values := url.Values{}
	if filter.Actor != "" {
		values.Set("actor", filter.Actor)
	}
	if filter.SinceKey != "" && filter.SinceKey != "all" {
		values.Set("since", filter.SinceKey)
	}
	if offset > 0 {
		values.Set("offset", strconv.Itoa(offset))
	}
	path := "/audit/" + url.PathEscape(filter.Kind)
	if len(values) == 0 {
		return template.URL(path) //nolint:gosec // path-escaped kind
	}
	return template.URL(path + "?" + values.Encode()) //nolint:gosec // path-escaped kind, encoded values
}

func (h *Handler) failures(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	// A read error is reported, not swallowed. Discarding it rendered "98
	// failed work items" directly above "No failed work" — the same
	// could-not-run-shown-as-nothing-found defect this repository has now hit
	// in a deploy script, a projection diff, a quality watcher, and here.
	groups, err := h.reader.Failures(ctx)
	message := ""
	if err != nil {
		message = err.Error()
	}
	h.page(w, r, "failures", "failures", struct {
		Groups []FailureGroup
		Total  int
		Err    string
	}{groups, h.reader.Count(ctx, countFailedRuns), message})
}

// failure opens one grouped cause. A group that cannot be opened is a report,
// not triage: it tells you twenty-nine runs hit the same error and gives you no
// way to reach one of them.
func (h *Handler) failure(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	cause := h.reader.CauseForKey(ctx, r.PathValue("key"))
	if cause == "" {
		h.trouble(w, r, http.StatusNotFound, "No such failure group",
			"No current failure matches this link — likely every run behind it was retried or aged out since the page that linked here was rendered.")
		return
	}
	runs, _ := h.reader.FailureRuns(ctx, cause)
	h.detail(w, r, "failures", "failure", cause, struct {
		Cause  string
		Runs   []FailureRun
		CanAct bool
	}{cause, runs, h.CanAct()})
}

// workspaces lists every Coop fork still on disk and why. The blocked rows are
// the operator's queue: the janitor has refused each for a stated reason and
// will never look again unless a person publishes, discards, or sends it back
// through the checks.
func (h *Handler) workspaces(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var failed problems
	held, queued, err := h.reader.RetainedWorkspaces(ctx)
	failed.note("workspaces", err)
	h.page(w, r, "workspaces", "workspaces", struct {
		Held, Queued []RetainedWorkspace
		Reclaimed    int
		Errs         problems
		CanAct       bool
	}{held, queued, h.reader.Count(ctx, countCleanupDone), failed, h.CanAct()})
}

// conversation unpacks the state blob a list can only count. The goal, open
// loops and learned knowledge are the substance of what Responder believes
// about a channel, stored as one opaque column that nothing rendered.
func (h *Handler) conversation(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	channelID := r.PathValue("channel")
	detail, err := h.reader.Conversation(ctx, channelID, r.PathValue("thread"))
	// An empty detail is checked as well as the error: a conversation that does
	// not exist rendered a blank page with every heading and no content, which
	// reads as a memory that holds nothing rather than one that is not there.
	if err != nil || detail.Channel == "" {
		h.trouble(w, r, http.StatusNotFound, "No such conversation",
			"No conversation memory exists at this address. It is written the first time a turn in the conversation learns something worth carrying.")
		return
	}
	episodes, _ := h.reader.EpisodesForChannel(ctx, channelID, 10)
	h.detail(w, r, "memory", "conversation", detail.Channel, struct {
		ConversationDetail
		Episodes []Item
	}{detail, episodes})
}

type rate struct {
	Label   string
	Count   int
	Total   int
	Percent int
}

func (h *Handler) decisions(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var failed problems
	corrections, err := h.reader.Corrections(ctx)
	failed.note("corrections", err)
	total := h.reader.Count(ctx, countTerminalRuns)
	rates := []rate{}
	for _, class := range []string{"unreadable", "incomplete", "rejected"} {
		count := h.reader.Count(ctx, countCorrections, class)
		rates = append(rates, rate{class, count, total, percent(count, total)})
	}
	items, err := h.reader.Feedback(ctx)
	failed.note("feedback", err)
	// Praise is separated from the complaints rather than mixed in with them.
	//
	// Positive reactions have been captured for a while and read by nothing: they
	// landed in the same list, under a heading about being told Responder got
	// something wrong, with no way to tell how many there were relative to the
	// complaints. Two lists and one ratio is the difference between a table that
	// accumulates and a page that says whether people are happy — and the praised
	// rows are the ones that link to an episode worth copying, which is the whole
	// reason "this answer was right" was worth collecting.
	var feedback, praise []Feedback
	for _, item := range items {
		if item.Sentiment == "positive" {
			praise = append(praise, item)
			continue
		}
		feedback = append(feedback, item)
	}
	praised := h.reader.Count(ctx, countFeedbackSentiment, "positive")
	complained := h.reader.Count(ctx, countFeedbackSentiment, "negative")
	h.page(w, r, "decisions", "decisions", struct {
		Rates            []rate
		Corrections      []Correction
		Feedback, Praise []Feedback
		Praised, Reacted int
		PraisedPercent   int
		Errs             problems
		CanAct           bool
	}{
		rates, corrections, feedback, praise,
		praised, praised + complained, percent(praised, praised+complained),
		failed, h.CanAct(),
	})
}

func (h *Handler) memory(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	channels, _ := h.reader.ChannelMemory(ctx)
	entries, _ := h.reader.MemoryEntries(ctx)
	conversations, _ := h.reader.Conversations(ctx)
	rollups, _ := h.reader.Rollups(ctx)
	review, _ := h.reader.MemoryReview(ctx)
	h.page(w, r, "memory", "memory", struct {
		Channels      []ChannelMemoryRow
		Entries       []MemoryEntry
		Conversations []Conversation
		Rollups       []Rollup
		Review        []ReviewItem
		CanAct        bool
	}{channels, entries, conversations, rollups, review, h.CanAct()})
}

// channel is the hub every other page's channel name now points at.
//
// Configuration listed channels and stopped there, so the question "how does
// Responder behave here, and what has it done here" had no page: participation
// lived in a slash command, memory on another page, work on a third, and
// nothing tied them to the channel they belonged to.
func (h *Handler) channel(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	detail, found, err := h.reader.Channel(ctx, r.PathValue("id"))
	if err != nil || !found {
		h.trouble(w, r, http.StatusNotFound, "No such channel",
			"Responder has never seen this channel: it is not a member, nothing is configured for it, and no work is recorded in it.")
		return
	}
	var failed problems
	failed.note("channel", err)
	h.detail(w, r, "configuration", "channel", detail.Name, struct {
		ChannelDetail
		CanAct bool
		Errs   problems
		Setup  Unwired
	}{
		ChannelDetail: detail, CanAct: h.CanAct(), Errs: failed,
		Setup: Unwired{
			Tag: "Changed in Slack",
			Needs: "The repository binding, alert policy, and participation mode are set in the " +
				"channel setup conversation. Run /responder setup in the channel to change them.",
		},
	})
}

func (h *Handler) configuration(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	channels, _ := h.reader.Channels(ctx)
	schedules, _ := h.reader.Schedules(ctx)
	preferences, _ := h.reader.Preferences(ctx)
	rules, _ := h.reader.StandingRules(ctx)
	h.page(w, r, "configuration", "configuration", struct {
		Prompts     []PromptBudget
		Channels    []ChannelConfigRow
		Schedules   []Schedule
		Preferences []Preference
		Rules       []StandingRule
	}{h.prompts, channels, schedules, preferences, rules})
}

// usagePage is what the machine spent, measured rather than estimated.
//
// Every figure here is a SUM of counts a provider reported. Nothing is derived
// from prompt bytes: a number worked out from the size of the text is a guess,
// and a guess in a spend report is worse than a blank, because it is indistinguishable
// from a measurement once it is on the page.
type usagePage struct {
	Windows              []UsageWindow
	Window               UsageWindow
	Totals               UsageTotals
	Trend                UsageTrend
	Tables               []UsageTable
	Cost                 UsageCost
	Errs                 problems
	Unmetered            Unwired
	CostUnwired, Latency Unwired
}

func (h *Handler) usage(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	page := usagePage{Windows: UsageWindows(r.URL.Query().Get("window"), time.Now().UTC())}
	page.Window = chosenWindow(page.Windows)
	var err error
	page.Totals, err = h.reader.UsageTotals(ctx, page.Window)
	page.Errs.note("totals", err)
	page.Trend, err = h.reader.UsageTrend(ctx, page.Window)
	page.Errs.note("trend", err)
	// The model breakdown is loaded apart from the loop because it is the one
	// that gets priced: cost is a property of which model answered, and the
	// other dimensions would just re-total the same money.
	byModel, err := h.reader.UsageByModel(ctx, page.Window)
	page.Errs.note("tokens by provider and model", err)
	byModel, page.Cost = priceUsage(h.pricing, byModel)
	page.Tables = append(page.Tables, UsageTable{
		Heading: "Tokens by provider and model", Column: "Provider and model",
		Note:  "What actually answered each attempt, including fallbacks after rate limits.",
		Money: page.Cost.Configured,
		Rows:  shareOf(byModel, page.Totals.Total()),
	})
	for _, table := range []struct {
		heading, column, note string
		load                  func(context.Context, UsageWindow) ([]UsageGroup, error)
	}{
		{"Tokens by channel", "Channel",
			"Where the work came from.", h.reader.UsageByChannel},
		{"Tokens by repository", "Repository",
			"Which codebase the work was bound to.", h.reader.UsageByRepository},
		{"Tokens by episode kind", "Kind",
			"Triage reads a channel; an engineering task reads and writes a repository.", h.reader.UsageByKind},
	} {
		rows, loadErr := table.load(ctx, page.Window)
		page.Errs.note(strings.ToLower(table.heading), loadErr)
		page.Tables = append(page.Tables, UsageTable{
			Heading: table.heading, Column: table.column, Note: table.note,
			Rows: shareOf(rows, page.Totals.Total()),
		})
	}
	page.Unmetered = Unwired{Tag: "Nothing measured in this window",
		Needs: "No attempt in this window reported token usage. The breakdowns below still " +
			"count attempts per provider, channel, repository and kind, so the gap is visible " +
			"where the spend will appear."}
	page.CostUnwired = costUnwired(page.Cost)
	page.Latency = Unwired{Tag: "Nothing timed in this window",
		Needs: "How the wall clock divides between Coop queueing, the provider working, and the " +
			"host noticing the turn finished. No turn in this window carried timing."}
	h.page(w, r, "usage", "usage", page)
}

// costUnwired says which of the three reasons there is no money figure, about
// the right thing: a missing table is the operator's to fill, an empty window
// has nothing to price, and a table that covers none of the models that ran
// names a mismatch rather than a gap.
func costUnwired(cost UsageCost) Unwired {
	switch {
	case !cost.Configured:
		return Unwired{Tag: "No price table configured",
			Needs: "Cost is priced only from the pricing table in the configuration file, and " +
				"this deployment has none. config/responder.example.yaml shows the shape: " +
				"per-model rates per million tokens, with the currency named."}
	case cost.Measured == 0:
		return Unwired{Tag: "Nothing measured to price",
			Needs: "A price table is configured, but no attempt in this window reported token " +
				"usage. The figure appears with the first measured attempt."}
	default:
		return Unwired{Tag: "The price table covers none of these models",
			Needs: "No measured provider and model pair matches a table key. Keys are " +
				"\"provider:model\" with bare \"provider\" as the fallback — the rows above " +
				"show the pairs that ran."}
	}
}
