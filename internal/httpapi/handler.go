package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
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
	return securityHeaders(mux)
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	if err := h.store.Ping(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"healthy": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"healthy": true})
}

func (h *Handler) ready(w http.ResponseWriter, _ *http.Request) {
	ready, reason := h.service.Ready()
	status := http.StatusOK
	if !ready {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, map[string]any{"ready": ready, "reason": reason})
}

func (h *Handler) metrics(w http.ResponseWriter, r *http.Request) {
	snapshot, err := h.store.Metrics(r.Context())
	if err != nil {
		http.Error(w, "metrics unavailable", http.StatusServiceUnavailable)
		return
	}
	ready, _ := h.service.Ready()
	readyValue := 0
	if ready {
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
		{"responder_webhook_work_pending", "Webhook events awaiting completion.", snapshot.WebhooksPending},
		{"responder_slack_input_pending", "Slack inputs awaiting completion.", snapshot.SlackPending},
		{"responder_slack_outbox_pending", "Slack messages awaiting confirmed delivery.", snapshot.OutboxPending},
		{"responder_coop_turns_pending", "Coop turns awaiting terminal completion.", snapshot.TurnsPending},
		{"responder_work_failed", "Durable work items in a terminal failure state.", snapshot.WorkFailed},
	}
	for _, metric := range metrics {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %d\n",
			metric.name, metric.help, metric.name, metric.name, metric.value)
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
