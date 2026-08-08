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
	}, nil
}

func (h *Handler) Register(mux *http.ServeMux) {
	mux.Handle("GET /static/", Static())
	mux.HandleFunc("GET /{$}", h.overview)
	mux.HandleFunc("GET /episodes", h.episodes)
	mux.HandleFunc("GET /episodes/{id}", h.episode)
	mux.HandleFunc("GET /failures", h.failures)
	mux.HandleFunc("GET /decisions", h.decisions)
	mux.HandleFunc("GET /memory", h.memory)
	mux.HandleFunc("GET /configuration", h.configuration)
	mux.HandleFunc("GET /usage", h.usage)
}

// page names the body template explicitly rather than deriving it from the
// slug: the episode detail page lives under the Episodes nav entry but is its
// own template, and inferring one from the other would couple navigation to
// rendering for no benefit.
func (h *Handler) page(w http.ResponseWriter, slug, body string, content any) {
	h.render.Render(w, body, NewShell(slug, h.deployment, content))
}

func (h *Handler) overview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	blocked, _ := h.reader.Blocked(ctx, 6)
	h.page(w, "", "overview", struct {
		NeedsYou, Failed, InFlight, Retained int
		Blocked                              []Item
		Deployment, Binary, Schema           string
		Ready                                bool
	}{
		NeedsYou: h.reader.Count(ctx, `SELECT COUNT(*) FROM work_episodes
		  WHERE lifecycle_state IN ('blocked','waiting_operator','waiting_approval')`),
		Failed: h.reader.Count(ctx, `SELECT COUNT(*) FROM agent_runs WHERE terminal_state = 'failed'`),
		InFlight: h.reader.Count(ctx, `SELECT COUNT(*) FROM work_episodes
		  WHERE lifecycle_state IN ('accepted','acknowledged','planning','working','retrying','verifying')`),
		Retained:   h.reader.Count(ctx, `SELECT COUNT(*) FROM coop_cleanup WHERE state = 'blocked'`),
		Blocked:    blocked,
		Deployment: h.deployment, Binary: h.binary, Schema: h.schema, Ready: h.ready(),
	})
}

func (h *Handler) episodes(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	episodes, _ := h.reader.Episodes(ctx, 100)
	h.page(w, "episodes", "episodes", struct {
		Episodes []Item
		Total    int
	}{episodes, h.reader.Count(ctx, `SELECT COUNT(*) FROM work_episodes`)})
}

func (h *Handler) episode(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	item, err := h.reader.Episode(ctx, id)
	if err != nil || item.ID == "" {
		http.NotFound(w, r)
		return
	}
	events, _ := h.reader.Events(ctx, id)
	evidence, _ := h.reader.Evidence(ctx, id)
	h.page(w, "episodes", "episode", struct {
		Item
		Events   []Event
		Evidence []EvidenceRow
		Manifest ManifestRow
		Usage    Unwired
	}{
		Item: item, Events: events, Evidence: evidence,
		Manifest: h.reader.Manifest(ctx, id),
		Usage: Unwired{Needs: "Tokens and wall-clock for this episode. Coop parses usage " +
			"from the provider stream but does not report it, so nothing is persisted per attempt."},
	})
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
	}{groups, h.reader.Count(ctx, `SELECT COUNT(*) FROM agent_runs WHERE terminal_state = 'failed'`), message})
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
	total := h.reader.Count(ctx, `SELECT COUNT(*) FROM agent_runs WHERE terminal_state <> ''`)
	rates := []rate{}
	for _, class := range []string{"unreadable", "incomplete", "rejected"} {
		count := h.reader.Count(ctx,
			`SELECT COUNT(*) FROM fixture_candidates WHERE correction_class = ?`, class)
		rates = append(rates, rate{class, count, total, percent(count, total)})
	}
	h.page(w, "decisions", "decisions", struct {
		Rates       []rate
		Corrections []Correction
	}{rates, corrections})
}

func (h *Handler) memory(w http.ResponseWriter, r *http.Request) {
	channels, _ := h.reader.ChannelMemory(r.Context())
	h.page(w, "memory", "memory", struct {
		Channels []ChannelMemoryRow
		Entries  []struct{ Subject, Predicate, Value, Scope string }
	}{channels, nil})
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
