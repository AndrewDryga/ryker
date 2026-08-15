package httpapi

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/store"
)

func changeRouteConfig(t *testing.T) config.Config {
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
    path: /srv/repos/repo
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
  deploys:
    kind: change
    auth: bearer
    secret_env: DEPLOY_TOKEN
    repository: repo
    change:
      kind: event.type
      occurred_at: deployment.finished_at
      summary: deployment.description
      actor: deployment.actor
      revision: deployment.sha
      source_url: deployment.url
      services: deployment.services
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

const deployBody = `{
  "event": {"type": "release"},
  "deployment": {
    "finished_at": "2026-08-14T11:50:00Z",
    "description": "checkout v41",
    "actor": "dana",
    "sha": "9f21c0a",
    "url": "https://deploys.example.com/41",
    "services": ["checkout", "cart"]
  }
}`

// A deploy notification arriving twice must leave one change in the ledger.
//
// Every sender in this class is at-least-once — that is what the delivery ID
// header is for — and the ledger's answer to "what changed?" is a count as much
// as a list. Two rows for one deploy is a wrong answer to the question the
// whole section exists to answer, and it is the answer an operator would then
// see repeated in a prompt.
//
// The identity is the delivery ID the HMAC binds, not a field mapped out of the
// body, so this dedupe cannot be stepped around by re-posting the same payload
// with the body's own id changed.
func TestARedeliveredDeployRecordsOneChange(t *testing.T) {
	cfg := changeRouteConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := service.New(cfg, st, nil, nil, nil, nil, nil)
	handler := New(cfg, st, svc, map[string]string{
		"grafana": "hook-secret", "deploys": "deploy-secret",
	}, nil)
	post := func(payload string, delivery string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(
			http.MethodPost, "/v1/hooks/deploys", bytes.NewReader([]byte(payload)),
		)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer deploy-secret")
		req.Header.Set("X-Responder-Event-ID", delivery)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		return response
	}
	for _, attempt := range []string{"first", "redelivery"} {
		if code := post(deployBody, "delivery-1").Code; code != http.StatusAccepted {
			t.Fatalf("%s = %d", attempt, code)
		}
	}
	events, err := st.Changes.Recent(context.Background(), time.Time{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("the ledger holds %d changes for one delivery", len(events))
	}
	change := events[0]
	if change.Kind != "deploy" {
		t.Errorf("kind = %q, want the release alias mapped onto deploy", change.Kind)
	}
	if change.Summary != "checkout v41" || change.Actor != "dana" || change.Revision != "9f21c0a" {
		t.Errorf("the mapping lost the change: %+v", change)
	}
	// Both mapped services, plus the route's own repository, which is what
	// makes a change recallable at all.
	if len(change.Services) != 2 || change.Services[0] != "cart" || change.Services[1] != "checkout" {
		t.Errorf("services = %v, want both mapped entries normalized", change.Services)
	}
	if len(change.Repositories) != 1 || change.Repositories[0] != "repo" {
		t.Errorf("repositories = %v, want the route's own repository", change.Repositories)
	}
	if !change.OccurredAt.Equal(time.Date(2026, 8, 14, 11, 50, 0, 0, time.UTC)) {
		t.Errorf("occurred_at = %s, want the mapped payload time", change.OccurredAt)
	}
	if change.SourceRef != "https://deploys.example.com/41" {
		t.Errorf("source_ref = %q", change.SourceRef)
	}

	// A second, genuinely different delivery is a second change. Without this
	// the test above would also pass on a ledger that recorded nothing at all.
	if code := post(deployBody, "delivery-2").Code; code != http.StatusAccepted {
		t.Fatalf("second delivery = %d", code)
	}
	events, err = st.Changes.Recent(context.Background(), time.Time{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("a distinct delivery did not record its own change: %d rows", len(events))
	}
}

// A change route opens nothing. It is the invariant that keeps this feature
// from becoming a second, unreviewed path into starting work: a deploy
// notification is context, and context does not page anybody.
func TestAChangeRouteNeverOpensAnIncident(t *testing.T) {
	cfg := changeRouteConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := service.New(cfg, st, nil, nil, nil, nil, nil)
	handler := New(cfg, st, svc, map[string]string{
		"grafana": "hook-secret", "deploys": "deploy-secret",
	}, nil)
	req := httptest.NewRequest(
		http.MethodPost, "/v1/hooks/deploys", bytes.NewReader([]byte(deployBody)),
	)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer deploy-secret")
	req.Header.Set("X-Responder-Event-ID", "delivery-1")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	if response.Code != http.StatusAccepted {
		t.Fatalf("change delivery = %d %s", response.Code, response.Body.String())
	}
	admitted, err := st.GetWebhookByKey(context.Background(), "deploys", "delivery-1")
	if err != nil {
		t.Fatal(err)
	}
	// Admitted through the same dedupe and replay machinery as every other
	// route, and carrying no signals — so the async pass has nothing to apply
	// and no incident can come of it.
	if len(admitted.Signals) != 0 {
		t.Fatalf("a change route produced %d signals", len(admitted.Signals))
	}
	incidents, err := st.ListIncidents(context.Background(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(incidents) != 0 {
		t.Fatalf("a deploy notification opened %d incidents", len(incidents))
	}
}

// A mapping typo must stop at the door. Falling back to deploy would put a
// change that never happened in front of an incident, wearing the one kind an
// operator is most likely to act on.
func TestAnUnknownChangeKindIsRefusedAtIngest(t *testing.T) {
	cfg := changeRouteConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := service.New(cfg, st, nil, nil, nil, nil, nil)
	handler := New(cfg, st, svc, map[string]string{
		"grafana": "hook-secret", "deploys": "deploy-secret",
	}, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/hooks/deploys",
		bytes.NewReader([]byte(`{"event":{"type":"rollback"},"deployment":{}}`)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer deploy-secret")
	req.Header.Set("X-Responder-Event-ID", "delivery-1")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("unsupported kind = %d %s", response.Code, response.Body.String())
	}
	events, err := st.Changes.Recent(context.Background(), time.Time{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("a refused delivery still wrote %d changes", len(events))
	}
}
