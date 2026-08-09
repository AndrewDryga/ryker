package webui

import (
	"context"
	"net/http"
	"net/url"
	"strings"
)

// Actions is every mutation the dashboard can perform.
//
// An interface, and narrow on purpose. The dashboard reads through its own
// read-only connection, so a write cannot go that way even by accident — it has
// to be handed a capability. Each method is implemented by calling the same
// store path the Slack button calls, which is what keeps the audit trail, the
// authorization checks and the invariants identical whichever surface the
// operator used. A dashboard that wrote directly to the database would be a
// second implementation of every rule.
type Actions interface {
	KeepCorrection(ctx context.Context, id, actor string) error
	DiscardCorrection(ctx context.Context, id, actor string) error
	RetryFailure(ctx context.Context, runID, actor string) error
	// PublishRetainedWork and DiscardRetainedWork run the identical service
	// handlers the Slack buttons call, Coop review and verified discard plan
	// included; their outcome notices land in the room's Slack channel exactly
	// as a button press would. RerunCleanup sends a blocked workspace back
	// through the janitor's own checks.
	PublishRetainedWork(ctx context.Context, incidentID, actor string) error
	DiscardRetainedWork(ctx context.Context, incidentID, actor string) error
	RerunCleanup(ctx context.Context, sessionID, actor string) error
	// ResolveEpisodeOvertaken closes blocked or waiting work whose moment has
	// passed, through the episode kernel's own cancel transition. Nothing is
	// deleted: the event and the audit row are the record of who decided.
	ResolveEpisodeOvertaken(ctx context.Context, episodeID, actor string) error
	// ResolveIncident closes an open room through the same handler the Slack
	// close control uses, cleanup scheduling and closing notice included.
	ResolveIncident(ctx context.Context, incidentID, actor string) error
	// The memory and feedback actions mirror the Slack handlers' store calls
	// and audit kinds one for one, so the log reads the same whichever surface
	// the operator used.
	// SetChannelSetting writes a participation override the way the slash
	// command writes it, "inherit" included — an override storing the word
	// would shadow the workspace default it is meant to defer to.
	SetChannelSetting(ctx context.Context, channelID, name, value, actor string) error
	ForgetMemory(ctx context.Context, entryID, actor string) error
	KeepMemoryReview(ctx context.Context, reviewID, actor string) error
	DismissMemoryReview(ctx context.Context, reviewID, actor string) error
	DismissFeedback(ctx context.Context, feedbackID, actor string) error
	ConvertFeedback(ctx context.Context, feedbackID, actor string) error
}

// dashboardActor is recorded against anything done here.
//
// There are no accounts: loopback is the authentication, so the audit trail
// cannot name a person. It says where the action came from instead, which is
// the honest version — "someone at the keyboard of this machine" — and keeps
// dashboard actions distinguishable from Slack ones when reading the log back.
const dashboardActor = "control-plane@localhost"

// act runs one mutation and returns the operator to where they were.
//
// POST then redirect, so a refresh does not repeat the action. Every action is
// a form post rather than a link: a GET that mutates would fire on any preload,
// crawl or accidental revisit, and on a surface with no authentication the
// browser itself is the only thing that would have to be wrong.
func (h *Handler) act(w http.ResponseWriter, r *http.Request, run func(context.Context, string) error) {
	if h.actions == nil {
		h.trouble(w, r, http.StatusNotImplemented, "No write access",
			"This build was not handed the service paths, so it can only read.")
		return
	}
	id := strings.TrimSpace(r.FormValue("id"))
	if id == "" {
		h.trouble(w, r, http.StatusBadRequest, "Nothing to act on",
			"The form arrived without an id. Reload the page and try the control again.")
		return
	}
	if err := run(r.Context(), id); err != nil {
		// Reported, not swallowed — and in the shell, not as two words of bare
		// plaintext. An action that silently failed while the page re-rendered
		// unchanged is the worst version; an unstyled 500 that reads as a crash
		// is the second worst, because the refusal is usually a sentence worth
		// reading ("this work is closed; discard is the remaining exit").
		h.trouble(w, r, http.StatusInternalServerError, "The action was refused", err.Error())
		return
	}
	back := r.Header.Get("Referer")
	if back == "" || !strings.HasPrefix(back, "http://127.0.0.1") {
		back = "/"
	}
	http.Redirect(w, r, back, http.StatusSeeOther)
}

func (h *Handler) keepCorrection(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.KeepCorrection(ctx, id, dashboardActor)
	})
}

func (h *Handler) discardCorrection(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.DiscardCorrection(ctx, id, dashboardActor)
	})
}

func (h *Handler) retryFailure(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.RetryFailure(ctx, id, dashboardActor)
	})
}

func (h *Handler) publishRetainedWork(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.PublishRetainedWork(ctx, id, dashboardActor)
	})
}

func (h *Handler) discardRetainedWork(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.DiscardRetainedWork(ctx, id, dashboardActor)
	})
}

func (h *Handler) rerunCleanup(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.RerunCleanup(ctx, id, dashboardActor)
	})
}

func (h *Handler) resolveEpisode(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.ResolveEpisodeOvertaken(ctx, id, dashboardActor)
	})
}

func (h *Handler) resolveIncident(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.ResolveIncident(ctx, id, dashboardActor)
	})
}

func (h *Handler) forgetMemory(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.ForgetMemory(ctx, id, dashboardActor)
	})
}

func (h *Handler) keepMemoryReview(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.KeepMemoryReview(ctx, id, dashboardActor)
	})
}

func (h *Handler) dismissMemoryReview(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.DismissMemoryReview(ctx, id, dashboardActor)
	})
}

func (h *Handler) dismissFeedback(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.DismissFeedback(ctx, id, dashboardActor)
	})
}

func (h *Handler) convertFeedback(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, func(ctx context.Context, id string) error {
		return h.actions.ConvertFeedback(ctx, id, dashboardActor)
	})
}

// channelSetting carries three fields where every other action carries one, so
// it validates them here rather than through act. The value list is closed:
// anything else is a request this surface did not offer.
func (h *Handler) channelSetting(w http.ResponseWriter, r *http.Request) {
	if h.actions == nil {
		h.trouble(w, r, http.StatusNotImplemented, "No write access",
			"This build was not handed the service paths, so it can only read.")
		return
	}
	id := strings.TrimSpace(r.FormValue("id"))
	name := strings.TrimSpace(r.FormValue("name"))
	value := strings.TrimSpace(r.FormValue("value"))
	if id == "" || (name != "proactive" && name != "shadow") ||
		(value != "on" && value != "off" && value != "inherit") {
		h.trouble(w, r, http.StatusBadRequest, "Not a setting this page offers",
			"A channel, one of the two participation settings, and on, off or inherit are required.")
		return
	}
	if err := h.actions.SetChannelSetting(r.Context(), id, name, value, dashboardActor); err != nil {
		h.trouble(w, r, http.StatusInternalServerError, "The change was refused", err.Error())
		return
	}
	http.Redirect(w, r, "/channels/"+url.PathEscape(id), http.StatusSeeOther)
}
