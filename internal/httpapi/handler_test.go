package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestWebhookAdmissionDeduplicationAndConflict(t *testing.T) {
	cfg := testConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := service.New(cfg, st, nil, nil, nil, nil, nil)
	handler := New(cfg, st, svc, map[string]string{"grafana": "hook-secret"}, nil)
	body := []byte(`{
	  "status":"firing",
	  "groupKey":"api-prod",
	  "alerts":[{
	    "status":"firing",
	    "labels":{"alertname":"API down","cluster":"prod","severity":"critical"},
	    "annotations":{"summary":"API down"},
	    "fingerprint":"abc123"
	  }]
	}`)
	request := func(payload []byte) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/hooks/grafana", bytes.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer hook-secret")
		req.Header.Set("X-Responder-Event-ID", "delivery-1")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		return response
	}
	first := request(body)
	if first.Code != http.StatusAccepted {
		t.Fatalf("first = %d %s", first.Code, first.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(first.Body.Bytes(), &response); err != nil || response["duplicate"] != false {
		t.Fatalf("first response = %v, %v", response, err)
	}
	second := request(body)
	if second.Code != http.StatusAccepted {
		t.Fatalf("duplicate = %d %s", second.Code, second.Body.String())
	}
	conflict := request(bytes.Replace(body, []byte("API down"), []byte("API slow"), 1))
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflict = %d %s", conflict.Code, conflict.Body.String())
	}
}

func TestWebhookRejectsBadAuthAndContentType(t *testing.T) {
	cfg := testConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	handler := New(cfg, st, service.New(cfg, st, nil, nil, nil, nil, nil),
		map[string]string{"grafana": "hook-secret"}, nil)
	for name, values := range map[string][2]string{
		"auth":         {"application/json", "wrong"},
		"content type": {"text/plain", "hook-secret"},
	} {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/hooks/grafana", bytes.NewBufferString(`{}`))
			req.Header.Set("Content-Type", values[0])
			req.Header.Set("Authorization", "Bearer "+values[1])
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, req)
			if response.Code < 400 {
				t.Fatalf("response = %d %s", response.Code, response.Body.String())
			}
		})
	}
}

func TestWebhookRejectsAmbiguousHeaders(t *testing.T) {
	cfg := testConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	handler := New(cfg, st, service.New(cfg, st, nil, nil, nil, nil, nil),
		map[string]string{"grafana": "hook-secret"}, nil)
	body := `{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"x"},"fingerprint":"x"}]}`
	for name, header := range map[string]string{
		"content type": "Content-Type",
		"delivery ID":  "X-Responder-Event-ID",
	} {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/hooks/grafana", bytes.NewBufferString(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer hook-secret")
			req.Header.Add(header, "first")
			req.Header.Add(header, "second")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, req)
			if response.Code < 400 {
				t.Fatalf("ambiguous header accepted: %d %s", response.Code, response.Body.String())
			}
		})
	}
}

func TestMetricsExposeDurableSchedulerHealth(t *testing.T) {
	cfg := testConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := service.New(cfg, st, nil, nil, nil, nil, nil)
	handler := New(cfg, st, svc, nil, nil)
	request := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("metrics = %d %s", response.Code, response.Body.String())
	}
	body := response.Body.String()
	for _, want := range []string{
		`responder_scheduler_work_pending{lane="control"}`,
		`responder_scheduler_oldest_due_seconds{lane="background"}`,
		`responder_scheduler_oldest_running_seconds{lane="maintenance"}`,
		`responder_scheduler_heartbeat_age_seconds{lane="control"} -1.000`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("metrics missing %q:\n%s", want, body)
		}
	}
}

func testConfig(t *testing.T) config.Config {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "responder.yaml")
	body := `version: 1
state_dir: ` + filepath.Join(root, "state") + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
coop: {}
repositories:
  repo:
    coop_policy: repo-observe
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

// Health and metrics are unauthenticated and read the single writer connection
// that every worker shares, so a burst of scrapes must collapse into one read
// and must still refresh once the TTL elapses.
func TestStatusReadsAreCachedAndRefreshAfterTTL(t *testing.T) {
	cfg := testConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	handler := New(cfg, st, service.New(cfg, st, nil, nil, nil, nil, nil),
		map[string]string{"grafana": "hook-secret"}, nil)

	inner := unwrapHandler(t, handler)
	base := time.Unix(1700000000, 0).UTC()
	inner.statusClock = func() time.Time { return base }

	scrape := func(path string) {
		t.Helper()
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusOK && recorder.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s = %d", path, recorder.Code)
		}
	}

	scrape("/metrics")
	firstExpiry := inner.statusUntil
	if firstExpiry.IsZero() {
		t.Fatal("first scrape did not populate the status cache")
	}
	for range 50 {
		scrape("/metrics")
		scrape("/readyz")
	}
	if !inner.statusUntil.Equal(firstExpiry) {
		t.Fatal("scrapes inside the TTL re-read the database")
	}

	inner.statusClock = func() time.Time { return base.Add(2 * statusTTL) }
	scrape("/readyz")
	if !inner.statusUntil.After(firstExpiry) {
		t.Fatal("status cache did not refresh after its TTL")
	}
}

// unwrapHandler reaches the Handler behind the security-header middleware.
func unwrapHandler(t *testing.T, handler http.Handler) *Handler {
	t.Helper()
	inner, ok := handlerBehindMiddleware(handler)
	if !ok {
		t.Fatal("could not reach the Handler behind its middleware")
	}
	return inner
}

// The truncation counters are how an operator learns the agent is being handed
// an elided view of its context, so they have to reach /metrics.
func TestMetricsRenderPromptTruncationCounters(t *testing.T) {
	cfg := testConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := service.New(cfg, st, nil, nil, nil, nil, nil)
	handler := New(cfg, st, svc, map[string]string{"grafana": "hook-secret"}, nil)

	svc.RecordPromptTruncation(70000, 65536)
	svc.RecordPromptTruncation(90000, 65536)
	svc.RecordPromptTruncation(80000, 65536)

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := recorder.Body.String()
	if !strings.Contains(body, "responder_coop_prompt_truncations_total 3") {
		t.Fatalf("truncation counter missing or wrong:\n%s", body)
	}
	if !strings.Contains(body, "responder_coop_prompt_max_bytes 90000") {
		t.Fatalf("max prompt gauge missing or wrong:\n%s", body)
	}
}
