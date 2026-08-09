package webui

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
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

func NewHandler(
	reader *Reader,
	deployment, schema, binary string,
	ready func() bool,
	prompts []PromptBudget,
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
		actions: actions,
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
	mux.HandleFunc("GET /conversations/{channel}/{thread}", h.conversation)
	mux.HandleFunc("GET /decisions", h.decisions)
	mux.HandleFunc("GET /audit", h.audit)
	mux.HandleFunc("GET /audit/{kind}", h.auditKind)
	mux.HandleFunc("GET /memory", h.memory)
	mux.HandleFunc("GET /configuration", h.configuration)
	mux.HandleFunc("GET /usage", h.usage)
	// Writes are POST only, and only these three. Each calls the same store
	// path the equivalent Slack button calls.
	mux.HandleFunc("POST /actions/corrections/keep", h.keepCorrection)
	mux.HandleFunc("POST /actions/corrections/discard", h.discardCorrection)
	mux.HandleFunc("POST /actions/failures/retry", h.retryFailure)
}

// CanAct reports whether this build was given write access, so a page can offer
// a button only when pressing it would do something.
func (h *Handler) CanAct() bool { return h.actions != nil }

// page names the body template explicitly rather than deriving it from the
// slug: the episode detail page lives under the Episodes nav entry but is its
// own template, and inferring one from the other would couple navigation to
// rendering for no benefit.
func (h *Handler) page(w http.ResponseWriter, r *http.Request, slug, body string, content any) {
	h.render.Render(w, body, h.shell(r, slug, content))
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
	// Three tiny counts per render, against a local SQLite. The alternative —
	// badges only on the pages that computed them — made the numbers appear
	// and vanish as you navigated, which reads as the counts changing.
	shell.Badges = map[string]Badge{
		"": {N: h.reader.Count(ctx, `SELECT COUNT(*) FROM work_episodes
		  WHERE lifecycle_state IN ('blocked','waiting_operator','waiting_approval')`), Warn: true},
		"failures":  {N: h.reader.Count(ctx, `SELECT COUNT(*) FROM agent_runs WHERE terminal_state = 'failed'`)},
		"decisions": {N: h.reader.Count(ctx, `SELECT COUNT(*) FROM fixture_candidates WHERE status = 'pending'`), Warn: true},
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
	h.page(w, r, "", "overview", struct {
		NeedsYou, Failed, InFlight, Retained int
		Blocked                              []blockedRow
		Lanes                                []Lane
		Errs                                 problems
		Deployment, Binary, Schema           string
		Ready                                bool
	}{
		Lanes: lanes, Errs: failed,
		NeedsYou:   h.reader.Count(ctx, countNeedsDecision),
		Failed:     h.reader.Count(ctx, countFailedRuns),
		InFlight:   h.reader.Count(ctx, countInFlight),
		Retained:   h.reader.Count(ctx, countRetained),
		Blocked:    foldBlocked(blocked),
		Deployment: h.deployment, Binary: h.binary, Schema: h.schema, Ready: h.ready(),
	})
}

// episodes lists the work, optionally narrowed to one slice of it.
//
// The filter is what makes the Usage breakdowns openable. Incident rooms are
// dropped while one is active: they are not filtered by it, and an unfiltered
// table sitting above a filtered list reads as part of the same answer.
func (h *Handler) episodes(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var failed problems
	filter := h.episodeFilter(ctx, r)
	episodes, err := h.reader.EpisodesMatching(ctx, filter, 200)
	failed.note("episodes", err)
	total, err := h.reader.CountMatching(ctx, filter)
	failed.note("episode count", err)
	rooms := []Room{}
	if !filter.Active() {
		rooms, err = h.reader.Rooms(ctx)
		failed.note("incident rooms", err)
	}
	h.page(w, r, "episodes", "episodes", struct {
		Episodes []Item
		Rooms    []Room
		Errs     problems
		Filter   EpisodeFilter
		Total    int
	}{episodes, rooms, failed, filter, total})
}

func (h *Handler) episodeFilter(ctx context.Context, r *http.Request) EpisodeFilter {
	query := r.URL.Query()
	filter := EpisodeFilter{
		Channel:    strings.TrimSpace(query.Get("channel")),
		Repository: strings.TrimSpace(query.Get("repository")),
		Mode:       strings.TrimSpace(query.Get("mode")),
		Provider:   strings.TrimSpace(query.Get("provider")),
		Model:      strings.TrimSpace(query.Get("model")),
	}
	filter.ChannelName = h.reader.channelName(ctx, filter.Channel)
	return filter
}

// episodePage is the whole record of one piece of work.
//
// Every debugging question in this repository's history is answered here, and
// until now was answered by running sqlite against a production database.
type episodePage struct {
	Item
	Turn      Turn
	Events    []Event
	Claims    []ClaimRow
	Evidence  []EvidenceRow
	Coverage  []CoverageRow
	Manifest  ManifestRow
	Attempts  []Attempt
	Delivered []Delivery
	Audit     []AuditRow
	Errs      problems
	Answered  Unwired
	Omitted   Unwired
	Spent     EpisodeTokens
	Unmetered Unwired
	Latency   Unwired
}

func (h *Handler) episode(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	item, err := h.reader.Episode(ctx, id)
	if err != nil || item.ID == "" {
		http.NotFound(w, r)
		return
	}
	page := episodePage{Item: item}
	page.Events, err = h.reader.Events(ctx, id)
	page.Errs.note("timeline", err)
	page.Turn, err = h.reader.Turn(ctx, id)
	page.Errs.note("the turn", err)
	page.Claims, err = h.reader.Claims(ctx, id)
	page.Errs.note("claims", err)
	page.Evidence, err = h.reader.Evidence(ctx, id)
	page.Errs.note("evidence", err)
	page.Coverage, err = h.reader.Coverage(ctx, id)
	page.Errs.note("coverage", err)
	page.Manifest, err = h.reader.Manifest(ctx, id)
	page.Errs.note("context manifest", err)
	page.Attempts, err = h.reader.Attempts(ctx, id)
	page.Errs.note("attempts", err)
	page.Delivered, err = h.reader.Deliveries(ctx, id)
	page.Errs.note("delivery", err)
	page.Audit, err = h.reader.AuditForEpisode(ctx, id)
	page.Errs.note("audit trail", err)
	page.Spent, err = h.reader.EpisodeTokens(ctx, id)
	page.Errs.note("token usage", err)
	// Both of these gaps were invisible because the page hid them. The manifest
	// has carried provider, model and reasoning_effort since it was created and
	// nothing assigned them until recently, so gating the whole section on the
	// model name printed "No context manifest for this episode" over a manifest
	// that was right there with six references in it.
	//
	// Each is scoped to this attempt, not to the product. Both columns are
	// assigned now, so a page-wide "not recorded yet" would report a fixed gap as
	// an open one and send someone to plumb what is already plumbed.
	page.Answered = Unwired{Tag: "Not recorded for this attempt",
		Needs: "Which provider and model answered, and at what reasoning effort. The manifest " +
			"has always carried a column for each, and nothing assigned them until the session's " +
			"effective target started being recorded — so an attempt frozen before that change " +
			"reads blank and what ran cannot be recovered. Attempts frozen since carry all three."}
	page.Omitted = Unwired{Tag: "Not recorded for this attempt",
		Needs: "What was left out of this prompt and why. The manifest carries an omitted_reason " +
			"per reference and an omissions list, and this one sets neither: every reference " +
			"listed above is one that went in, and nothing says what was dropped to make room."}
	page.Unmetered = unmeteredEpisode(page.Spent)
	page.Latency = Unwired{Tag: "Not read here",
		Needs: "How this episode's wall clock divides: waiting for a provider, the provider " +
			"working, and the host noticing it had finished. The attempt ledger above gives the " +
			"duration end to end; the split inside it is a separate per-attempt measurement this " +
			"page does not read."}
	h.detail(w, r, "episodes", "episode", page.Title, page)
}

// unmeteredEpisode says why there is no token count, and the two reasons are
// not the same. An episode with no manifest never froze one; an episode with
// manifests and no counts ran before the accounting landed, or ran on an
// adapter that reported nothing — ACP does not require one to.
func unmeteredEpisode(spent EpisodeTokens) Unwired {
	if spent.Manifests == 0 {
		return Unwired{Needs: "What this episode spent, in tokens. Usage is recorded against " +
			"the context manifest of the attempt that spent it, and no manifest was frozen for " +
			"this episode, so there is nothing to read it from."}
	}
	return Unwired{Tag: "Not measured for this episode",
		Needs: fmt.Sprintf("What this episode spent, in tokens. Usage is recorded against the "+
			"attempt's context manifest and none of this episode's %d carries a count: an attempt "+
			"that ran before the accounting landed has nothing to read back, and an adapter that "+
			"reports no usage — which ACP permits — leaves the same blank rather than a zero.",
			spent.Manifests)}
}

// incident opens the room a whole conversation of work happened in: the ask
// that started it, what was said back, and the pull request that came out.
func (h *Handler) incident(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	room, err := h.reader.Room(ctx, id)
	if err != nil || room.ID == "" {
		http.NotFound(w, r)
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
	}{Room: room}
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
		http.NotFound(w, r)
		return
	}
	var failed problems
	events, err := h.reader.AuditOfKind(ctx, kind)
	failed.note("events", err)
	h.detail(w, r, "audit", "auditkind", kind, struct {
		Kind   string
		Events []AuditRow
		Errs   problems
	}{kind, events, failed})
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
		http.NotFound(w, r)
		return
	}
	runs, _ := h.reader.FailureRuns(ctx, cause)
	h.detail(w, r, "failures", "failure", cause, struct {
		Cause  string
		Runs   []FailureRun
		CanAct bool
	}{cause, runs, h.CanAct()})
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
		http.NotFound(w, r)
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
	corrections, _ := h.reader.Corrections(ctx)
	total := h.reader.Count(ctx, countTerminalRuns)
	rates := []rate{}
	for _, class := range []string{"unreadable", "incomplete", "rejected"} {
		count := h.reader.Count(ctx, countCorrections, class)
		rates = append(rates, rate{class, count, total, percent(count, total)})
	}
	feedback, _ := h.reader.Feedback(ctx)
	h.page(w, r, "decisions", "decisions", struct {
		Rates       []rate
		Corrections []Correction
		Feedback    []Feedback
		CanAct      bool
	}{rates, corrections, feedback, h.CanAct()})
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
	}{channels, entries, conversations, rollups, review})
}

func (h *Handler) configuration(w http.ResponseWriter, r *http.Request) {
	channels, _ := h.reader.Channels(r.Context())
	h.page(w, r, "configuration", "configuration", struct {
		Prompts   []PromptBudget
		Channels  []ChannelConfigRow
		Schedules []struct{ Prompt, Cadence string }
	}{h.prompts, channels, nil})
}

// usagePage is what the machine spent, measured rather than estimated.
//
// Every figure here is a SUM of counts a provider reported. Nothing is derived
// from prompt bytes: a number worked out from the size of the text is a guess,
// and a guess in a spend report is worse than a blank, because it is indistinguishable
// from a measurement once it is on the page.
type usagePage struct {
	Windows                []UsageWindow
	Window                 UsageWindow
	Totals                 UsageTotals
	Trend                  UsageTrend
	Tables                 []UsageTable
	Errs                   problems
	Unmetered, Composition Unwired
	Cost, Latency          Unwired
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
	for _, table := range []struct {
		heading, column, note string
		load                  func(context.Context, UsageWindow) ([]UsageGroup, error)
	}{
		{"Tokens by provider and model", "Provider and model",
			"What answered the attempt, frozen on its manifest — so a turn that rotated to a " +
				"fallback after a rate limit counts against what actually ran.",
			h.reader.UsageByModel},
		{"Tokens by channel", "Channel",
			"Where the work came from.", h.reader.UsageByChannel},
		{"Tokens by repository", "Repository",
			"Which codebase the work was bound to.", h.reader.UsageByRepository},
		{"Tokens by episode kind", "Kind",
			"A triage turn reads a channel; an engineering task reads a repository and writes to " +
				"it. They are not the same unit of spend.", h.reader.UsageByKind},
	} {
		rows, loadErr := table.load(ctx, page.Window)
		page.Errs.note(strings.ToLower(table.heading), loadErr)
		page.Tables = append(page.Tables, UsageTable{
			Heading: table.heading, Column: table.column, Note: table.note,
			Rows: shareOf(rows, page.Totals.Total()),
		})
	}
	page.Unmetered = Unwired{Tag: "Nothing measured in this window",
		Needs: "No attempt in this window reported token usage. Accounting records against the " +
			"attempt's context manifest, so an attempt that ran before it landed has nothing to " +
			"read back, and an adapter that reports no usage — which ACP permits — leaves the " +
			"same blank rather than a zero. The breakdowns below still say how many attempts " +
			"each provider, channel, repository and kind covered, so the gap is visible where " +
			"the spend will appear."}
	page.Composition = Unwired{Needs: "How much of each turn was instructions, context, tool " +
		"results and conversation. The manifest names every reference that went into the prompt " +
		"and the digest of each, and carries no size for any of them, so the shares would have " +
		"to be invented — it needs a byte count per reference at freeze time."}
	// Cost and wall clock are scoped to what this page reads, not to what the
	// system records. Written the other way they would go stale the moment a
	// price table or a timing column landed, and a panel claiming a fixed gap is
	// still open is the same defect as one claiming a live number it does not
	// have — it sends an operator to plumb what is already plumbed.
	page.Cost = Unwired{Tag: "Not priced here",
		Needs: "What the tokens above cost. This page is handed no price table, so it prices " +
			"nothing. The table belongs in configuration rather than in the binary — prices change " +
			"on the provider's schedule and a compiled-in rate reports confident wrong money — and " +
			"a model the table does not cover has to report no cost rather than a zero, because a " +
			"zero in a spend report reads as \"this was free\"."}
	page.Latency = Unwired{Tag: "Not read here",
		Needs: "How the wall clock divides: waiting for a provider, the provider working, and the " +
			"host noticing it had finished. This page totals tokens and not time. Each episode's " +
			"duration end to end is already on its own page, from the attempt ledger; the split " +
			"inside that duration is a separate per-attempt measurement this page does not read, " +
			"and \"the answer took four minutes\" and \"the model took four minutes\" are " +
			"different claims that need different numbers."}
	h.page(w, r, "usage", "usage", page)
}
