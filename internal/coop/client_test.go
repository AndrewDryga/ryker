package coop

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestClientUsesUnixSocketAndExactMutationHeaders(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/sessions" || r.Method != http.MethodPost {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Idempotency-Key"); got != "create-1" {
			t.Errorf("idempotency key = %q", got)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("content type = %q", got)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body["policy"] != "observe" || body["task"] != "incident:1" {
			t.Errorf("body = %#v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"operation":{"id":"op_1","method":"CreateSession","state":"succeeded"},"session":{"id":"ses_1","external_ref":"incident:1","revision":1,"state":"open","activity":"parked"}}`))
	})}
	go server.Serve(listener)
	defer server.Shutdown(context.Background())

	client := New(socket, time.Second)
	session, operation, err := client.CreateSession(context.Background(), "create-1", "observe", "incident:1")
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_1" || operation.ID != "op_1" {
		t.Fatalf("response = %+v %+v", session, operation)
	}
}

func TestClientReturnsTypedErrorsAndBoundsResponses(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"error":{"code":"revision_conflict","detail":"stale"}}`))
	})}
	go server.Serve(listener)
	defer server.Shutdown(context.Background())
	client := New(socket, time.Second)
	_, err = client.GetSession(context.Background(), "ses_1")
	apiErr, ok := err.(*APIError)
	if !ok || apiErr.Code != "revision_conflict" || apiErr.Retryable() {
		t.Fatalf("error = %#v", err)
	}
}

func TestReadyFailsWhenSocketMissing(t *testing.T) {
	client := New(filepath.Join(filepath.Dir(shortSocket(t)), "missing.sock"), 100*time.Millisecond)
	if err := client.Ready(context.Background()); err == nil {
		t.Fatal("missing socket was ready")
	}
}

func shortSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "rsp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "c.sock")
}
