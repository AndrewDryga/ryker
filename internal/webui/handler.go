package webui

import (
	"net/http"
	"strings"
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
func (h *Handler) page(w http.ResponseWriter, slug, body string, content any) {
	h.render.Render(w, body, NewShell(slug, h.deployment, content))
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

func (h *Handler) overview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	blocked, _ := h.reader.Blocked(ctx, 6)
	var failed problems
	lanes, err := h.reader.Lanes(ctx)
	failed.note("queues", err)
	h.page(w, "", "overview", struct {
		NeedsYou, Failed, InFlight, Retained int
		Blocked                              []Item
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
		Blocked:    blocked,
		Deployment: h.deployment, Binary: h.binary, Schema: h.schema, Ready: h.ready(),
	})
}

func (h *Handler) episodes(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	episodes, _ := h.reader.Episodes(ctx, 100)
	var failed problems
	rooms, err := h.reader.Rooms(ctx)
	failed.note("incident rooms", err)
	h.page(w, "episodes", "episodes", struct {
		Episodes []Item
		Rooms    []Room
		Errs     problems
		Total    int
	}{episodes, rooms, failed, h.reader.Count(ctx, countEpisodes)})
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
	Usage     Unwired
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
	// Both of these gaps were invisible because the page hid them. The manifest
	// has carried provider, model and reasoning_effort since it was created and
	// nothing assigned them until recently, so gating the whole section on the
	// model name printed "No context manifest for this episode" over a manifest
	// that was right there with six references in it.
	page.Answered = Unwired{Needs: "Which provider and model answered, and at what reasoning " +
		"effort. The manifest has always carried a column for each and nothing assigned them " +
		"until the session's effective target started being recorded, so an attempt frozen " +
		"before that reads blank and what ran cannot be recovered."}
	page.Omitted = Unwired{Needs: "What was left out of this prompt and why. The manifest " +
		"carries an omitted_reason per reference and an omissions list, and the service that " +
		"freezes the manifest sets neither — it records what it included and has no path that " +
		"records what it dropped. Every reference listed above is one that went in."}
	page.Usage = Unwired{Needs: "Tokens and wall-clock for this episode. Coop parses usage " +
		"from the provider stream but does not report it, so nothing is persisted per attempt."}
	h.page(w, "episodes", "episode", page)
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
	h.page(w, "episodes", "incident", page)
}

func (h *Handler) audit(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var failed problems
	kinds, err := h.reader.AuditKinds(ctx)
	failed.note("kinds", err)
	recent, err := h.reader.AuditRecent(ctx, 40)
	failed.note("recent activity", err)
	h.page(w, "audit", "audit", struct {
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
	h.page(w, "audit", "auditkind", struct {
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
	h.page(w, "failures", "failures", struct {
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
	h.page(w, "failures", "failure", struct {
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
	h.page(w, "memory", "conversation", struct {
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
	h.page(w, "decisions", "decisions", struct {
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
	h.page(w, "memory", "memory", struct {
		Channels      []ChannelMemoryRow
		Entries       []MemoryEntry
		Conversations []Conversation
		Rollups       []Rollup
		Review        []ReviewItem
	}{channels, entries, conversations, rollups, review})
}

func (h *Handler) configuration(w http.ResponseWriter, r *http.Request) {
	channels, _ := h.reader.Channels(r.Context())
	h.page(w, "configuration", "configuration", struct {
		Prompts   []PromptBudget
		Channels  []ChannelConfigRow
		Schedules []struct{ Prompt, Cadence string }
	}{h.prompts, channels, nil})
}

// usage renders its full shape with every panel marked unwired. Showing an
// estimate derived from prompt bytes would be a guess dressed as a
// measurement, and a guess in a cost report is worse than a blank.
func (h *Handler) usage(w http.ResponseWriter, r *http.Request) {
	needs := func(what string) Unwired {
		return Unwired{Needs: what + " Coop parses input, cached-input, output and " +
			"reasoning tokens from the provider stream; it does not report them on the turn " +
			"result, and Responder persists nothing per attempt."}
	}
	h.page(w, "usage", "usage", struct{ ByModel, ByScope, Composition, Cache, Cost, Latency Unwired }{
		ByModel:     needs("Per-provider and per-model token totals."),
		ByScope:     needs("Token totals by deployment, channel and repository."),
		Composition: needs("How much of each turn was instructions, context, tool results and conversation."),
		Cache:       needs("Cache hit rate across cached input tokens."),
		Cost: Unwired{Needs: "Cost needs both token accounting and a per-model price table in " +
			"configuration. The table is deliberately not hardcoded: prices change, and a stale " +
			"rate reports confident wrong money."},
		Latency: Unwired{Needs: "Time split between model inference, tool calls and host processing. " +
			"Episode duration is derivable from timestamps; the split is not recorded."},
	})
}

func deploymentName(stateDir string) string {
	parts := strings.Split(strings.TrimSuffix(stateDir, "/"), "/")
	for index := len(parts) - 1; index >= 0; index-- {
		if part := parts[index]; part != "" && part != "state" && part != ".responder" {
			return part
		}
	}
	return "responder"
}
