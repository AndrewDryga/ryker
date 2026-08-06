package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/webhook"
)

type Handler struct {
	cfg     config.Config
	store   *store.Store
	service *service.Service
	secrets map[string]string
	log     *slog.Logger

	accepted  atomic.Uint64
	duplicate atomic.Uint64
	rejected  atomic.Uint64

	statusMu    sync.Mutex
	status      serviceStatus
	statusUntil time.Time
	statusClock func() time.Time
}

// statusTTL bounds how stale a health or metrics answer may be.
//
// Every field in a status answer is read from the single writer connection that
// the scheduler, webhook admission, and Slack admission all share. These
// endpoints are unauthenticated, so without a cache any scrape interval — or a
// misconfigured one — competes directly with real work for that connection. One
// second is well inside a normal Prometheus or load-balancer interval while
// collapsing a burst into a single read.
const statusTTL = time.Second

type serviceStatus struct {
	metrics   store.Metrics
	scheduler []service.SchedulerLaneSnapshot
	ready     bool
	reason    string
	err       error
}

func (h *Handler) now() time.Time {
	if h.statusClock != nil {
		return h.statusClock()
	}
	return time.Now()
}

// serviceStatus returns a recent status answer, reading through at most once
// per statusTTL. Concurrent callers share one read: the lock is deliberately
// held across it so a scrape storm cannot become a storm of database queries.
func (h *Handler) serviceStatus(ctx context.Context) serviceStatus {
	h.statusMu.Lock()
	defer h.statusMu.Unlock()
	if now := h.now(); now.Before(h.statusUntil) {
		return h.status
	}
	var status serviceStatus
	status.metrics, status.err = h.store.Metrics(ctx)
	if status.err == nil {
		status.scheduler, status.err = h.service.SchedulerSnapshot(ctx)
	}
	if status.err == nil {
		status.ready, status.reason = h.service.Ready(ctx)
	}
	h.status = status
	h.statusUntil = h.now().Add(statusTTL)
	return status
}

func New(
	cfg config.Config,
	st *store.Store,
	svc *service.Service,
	secrets map[string]string,
	logger *slog.Logger,
) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	handler := &Handler{cfg: cfg, store: st, service: svc, secrets: secrets, log: logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handler.health)
	mux.HandleFunc("GET /readyz", handler.ready)
	mux.HandleFunc("GET /metrics", handler.metrics)
	mux.HandleFunc("POST /v1/hooks/{route}", handler.webhook)
	return wrapped{Handler: securityHeaders(mux), handler: handler}
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	if err := h.store.Ping(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"healthy": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"healthy": true})
}

func (h *Handler) ready(w http.ResponseWriter, r *http.Request) {
	status := h.serviceStatus(r.Context())
	if status.err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"ready": false, "reason": "status unavailable",
		})
		return
	}
	code := http.StatusOK
	if !status.ready {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, map[string]any{"ready": status.ready, "reason": status.reason})
}

func (h *Handler) metrics(w http.ResponseWriter, r *http.Request) {
	status := h.serviceStatus(r.Context())
	if status.err != nil {
		http.Error(w, "metrics unavailable", http.StatusServiceUnavailable)
		return
	}
	snapshot, scheduler := status.metrics, status.scheduler
	readyValue := 0
	if status.ready {
		readyValue = 1
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprintf(w, "# HELP responder_ready Whether Slack, Coop, and workers are ready.\n")
	fmt.Fprintf(w, "# TYPE responder_ready gauge\nresponder_ready %d\n", readyValue)
	metrics := []struct {
		name  string
		help  string
		value int
	}{
		{"responder_incidents_open", "Open incidents.", snapshot.IncidentsOpen},
		{"responder_incidents_total", "All durable incidents.", snapshot.IncidentsTotal},
		{"responder_coop_sessions_open", "Open Coop sessions.", snapshot.SessionsOpen},
		{"responder_draft_prs_published", "Responder-managed draft pull requests.", snapshot.PublishedPRs},
		{"responder_cleanup_pending", "Owned Coop sessions awaiting cleanup.", snapshot.CleanupPending},
		{"responder_cleanup_blocked", "Owned Coop sessions retained for operator action.", snapshot.CleanupBlocked},
		{"responder_memory_entries_active", "Active operator-confirmed memory entries.", snapshot.MemoryActive},
		{"responder_memory_entries_expired", "Expired memory entries awaiting maintenance pruning.", snapshot.MemoryExpired},
		{"responder_memory_rollups", "Active synthesized conversation continuity rollups.", snapshot.MemoryRollups},
		{"responder_memory_reviews_pending", "Operator-confirmed memory items awaiting review.", snapshot.MemoryReviewsPending},
		{"responder_conversation_memories", "Recent per-conversation summaries retained before consolidation.", snapshot.ConversationMemories},
		{"responder_preferences_active", "Enabled operator-confirmed Responder preferences.", snapshot.PreferencesActive},
		{"responder_preferences_disabled", "Disabled unexpired Responder preferences.", snapshot.PreferencesDisabled},
		{"responder_standing_rules_active", "Enabled operator-confirmed standing rules.", snapshot.RulesActive},
		{"responder_standing_rules_disabled", "Disabled unexpired standing rules.", snapshot.RulesDisabled},
		{"responder_scheduled_tasks_active", "Enabled unexpired operator-confirmed scheduled tasks.", snapshot.SchedulesActive},
		{"responder_scheduled_tasks_paused", "Paused unexpired scheduled tasks.", snapshot.SchedulesPaused},
		{"responder_scheduled_task_runs_active", "Scheduled task occurrences currently queued or running.", snapshot.ScheduleRunsActive},
		{"responder_webhook_work_pending", "Webhook events awaiting completion.", snapshot.WebhooksPending},
		{"responder_slack_input_pending", "Slack inputs awaiting completion.", snapshot.SlackPending},
		{"responder_slack_deliveries_pending", "Slack writes awaiting confirmed delivery.", snapshot.SlackDeliveriesPending},
		{"responder_agent_runs_pending", "Agent runs awaiting terminal completion.", snapshot.AgentRunsPending},
		{"responder_work_failed", "Durable work items in a terminal failure state.", snapshot.WorkFailed},
	}
	for _, metric := range metrics {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %d\n",
			metric.name, metric.help, metric.name, metric.name, metric.value)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_work_pending Durable scheduled work awaiting a lease.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_work_pending gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_work_pending{lane=%q} %d\n",
			lane.Lane,
			lane.Pending,
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_work_running Durable scheduled work with an active lease.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_work_running gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_work_running{lane=%q} %d\n",
			lane.Lane,
			lane.Running,
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_work_failed Durable scheduler records in terminal failure.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_work_failed gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_work_failed{lane=%q} %d\n",
			lane.Lane,
			lane.Failed,
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_oldest_due_seconds Age of the oldest due scheduler item.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_oldest_due_seconds gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_oldest_due_seconds{lane=%q} %.3f\n",
			lane.Lane,
			lane.OldestDueAge.Seconds(),
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_oldest_running_seconds Age of the oldest running scheduler item.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_oldest_running_seconds gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_oldest_running_seconds{lane=%q} %.3f\n",
			lane.Lane,
			lane.OldestRunningAge.Seconds(),
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_heartbeat_age_seconds Age of the last worker heartbeat, or -1 before startup.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_heartbeat_age_seconds gauge")
	for _, lane := range scheduler {
		age := -1.0
		if lane.HeartbeatPresent {
			age = lane.HeartbeatAge.Seconds()
		}
		fmt.Fprintf(
			w,
			"responder_scheduler_heartbeat_age_seconds{lane=%q} %.3f\n",
			lane.Lane,
			age,
		)
	}
	fmt.Fprintf(w, "# TYPE responder_webhooks_accepted_total counter\nresponder_webhooks_accepted_total %d\n", h.accepted.Load())
	fmt.Fprintf(w, "# TYPE responder_webhooks_duplicate_total counter\nresponder_webhooks_duplicate_total %d\n", h.duplicate.Load())
	fmt.Fprintf(w, "# TYPE responder_webhooks_rejected_total counter\nresponder_webhooks_rejected_total %d\n", h.rejected.Load())
}

func (h *Handler) webhook(w http.ResponseWriter, r *http.Request) {
	routeName := r.PathValue("route")
	route, ok := h.cfg.Webhooks[routeName]
	if !ok || strings.Contains(routeName, "/") {
		h.rejected.Add(1)
		writeError(w, http.StatusNotFound, "unknown webhook route")
		return
	}
	if r.URL.RawQuery != "" {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, "query parameters are not accepted")
		return
	}
	contentTypes := r.Header.Values("Content-Type")
	mediaType := ""
	var err error
	if len(contentTypes) == 1 {
		mediaType, _, err = mime.ParseMediaType(contentTypes[0])
	}
	if len(contentTypes) != 1 || err != nil || mediaType != "application/json" {
		h.rejected.Add(1)
		writeError(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, int64(h.cfg.Limits.MaxWebhookBytes)))
	if err != nil {
		h.rejected.Add(1)
		writeError(w, http.StatusRequestEntityTooLarge, "webhook body exceeds the configured limit")
		return
	}
	if err := webhook.Verify(route, r.Header, body, h.secrets[routeName], time.Now()); err != nil {
		h.rejected.Add(1)
		writeError(w, http.StatusUnauthorized, "webhook authentication failed")
		return
	}
	signals, err := webhook.Normalize(route, body, time.Now())
	if err != nil {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	digestBytes := sha256.Sum256(body)
	digest := hex.EncodeToString(digestBytes[:])
	deliveryIDs := r.Header.Values("X-Responder-Event-ID")
	if len(deliveryIDs) > 1 {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, "at most one X-Responder-Event-ID is accepted")
		return
	}
	dedupeKey := ""
	if len(deliveryIDs) == 1 {
		dedupeKey = strings.TrimSpace(deliveryIDs[0])
	}
	if dedupeKey == "" {
		dedupeKey = digest
	}
	if len(dedupeKey) > 500 || strings.ContainsRune(dedupeKey, '\x00') {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, "X-Responder-Event-ID is invalid")
		return
	}
	event, created, err := h.store.AdmitWebhook(r.Context(), routeName, dedupeKey, digest, signals)
	if err != nil {
		h.log.Error("persist webhook", "route", routeName, "error", err)
		writeError(w, http.StatusServiceUnavailable, "webhook could not be persisted")
		return
	}
	if !created && event.BodyDigest != digest {
		h.rejected.Add(1)
		writeError(w, http.StatusConflict, "event ID was already used for different content")
		return
	}
	if created {
		h.accepted.Add(1)
	} else {
		h.duplicate.Add(1)
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"accepted": true, "duplicate": !created, "event_id": event.ID,
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

func writeError(w http.ResponseWriter, status int, detail string) {
	writeJSON(w, status, map[string]any{"error": detail})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "response encoding failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(append(data, '\n'))
}

// wrapped lets tests reach the Handler behind securityHeaders without exporting
// it. Production callers only ever see the http.Handler that New returns.
type wrapped struct {
	http.Handler
	handler *Handler
}

func handlerBehindMiddleware(value http.Handler) (*Handler, bool) {
	inner, ok := value.(wrapped)
	if !ok {
		return nil, false
	}
	return inner.handler, true
}
