package webui

import (
	"context"
	"net/http"
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
		http.Error(w, "this build has no write access to the service", http.StatusNotImplemented)
		return
	}
	id := strings.TrimSpace(r.FormValue("id"))
	if id == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	if err := run(r.Context(), id); err != nil {
		// Reported, not swallowed. An action that silently failed while the page
		// re-rendered unchanged is the worst version of this: the operator
		// believes the thing is done.
		http.Error(w, err.Error(), http.StatusInternalServerError)
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
