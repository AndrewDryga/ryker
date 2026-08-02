package coop

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
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

func TestClientSubmitsTypedTurnArtifacts(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	data := []byte("screenshot")
	digest := sha256.Sum256(data)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ExpectedRevision int64           `json:"expected_revision"`
			Prompt           string          `json:"prompt"`
			Artifacts        []InputArtifact `json:"artifacts"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body.ExpectedRevision != 2 || body.Prompt != "inspect it" ||
			len(body.Artifacts) != 1 ||
			string(body.Artifacts[0].Data) != string(data) ||
			body.Artifacts[0].SHA256 != fmt.Sprintf("%x", digest) {
			t.Errorf("turn body = %+v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
		  "operation":{"id":"op_turn","method":"SubmitTurn","state":"succeeded"},
		  "turn":{"id":"turn_1","session_id":"ses_1","state":"queued"}
		}`))
	})}
	go server.Serve(listener)
	defer server.Shutdown(context.Background())

	client := New(socket, time.Second)
	turn, operation, err := client.SubmitTurnWithArtifacts(
		context.Background(), "turn-1", "ses_1", 2, "inspect it",
		[]InputArtifact{{
			Name: "bug.png", MediaType: "image/png",
			SHA256: fmt.Sprintf("%x", digest), Data: data,
		}},
	)
	if err != nil || turn.ID != "turn_1" || operation.ID != "op_turn" {
		t.Fatalf("response = %+v %+v, %v", turn, operation, err)
	}
}

func TestClientBoundsTurnPromptAndPreservesInstructionsAndTarget(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	received := make(chan string, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Prompt string `json:"prompt"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		received <- body.Prompt
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
		  "operation":{"id":"op_turn","method":"SubmitTurn","state":"succeeded"},
		  "turn":{"id":"turn_1","session_id":"ses_1","state":"queued"}
		}`))
	})}
	go server.Serve(listener)
	defer server.Shutdown(context.Background())

	prompt := "GOVERNING INSTRUCTIONS\n" +
		strings.Repeat("old context ", 9000) +
		"\nCURRENT TARGET: investigate the memory alert \U0001F9E0"
	prompt = string([]byte(prompt[:len(prompt)-1])) + "\xff\x00" +
		"\nCURRENT TARGET: investigate the memory alert \U0001F9E0"

	if _, _, err := New(socket, time.Second).SubmitTurn(
		context.Background(), "turn-bounded", "ses_1", 1, prompt,
	); err != nil {
		t.Fatal(err)
	}
	bounded := <-received
	if len(bounded) > maxPromptBytes || !utf8.ValidString(bounded) ||
		strings.ContainsRune(bounded, 0) {
		t.Fatalf("bounded prompt bytes=%d valid=%t contains_nul=%t", len(bounded), utf8.ValidString(bounded), strings.ContainsRune(bounded, 0))
	}
	for _, required := range []string{
		"GOVERNING INSTRUCTIONS",
		"<responder-context-elided>",
		"CURRENT TARGET: investigate the memory alert",
	} {
		if !strings.Contains(bounded, required) {
			t.Fatalf("bounded prompt omitted %q", required)
		}
	}
}

func TestClientFetchesBoundedOutputArtifact(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	data := []byte("\x89PNG\r\n\x1a\nchart")
	digest := sha256.Sum256(data)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/sessions/ses_1/turns/turn_1/artifacts/artifact_1" {
			t.Errorf("artifact path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("ETag", fmt.Sprintf(`"%x"`, digest))
		_, _ = w.Write(data)
	})}
	go server.Serve(listener)
	defer server.Shutdown(context.Background())

	artifact, err := New(socket, time.Second).GetOutputArtifact(context.Background(), "ses_1", "turn_1", "artifact_1")
	if err != nil || string(artifact.Data) != string(data) || artifact.SHA256 != fmt.Sprintf("%x", digest) || artifact.MediaType != "image/png" {
		t.Fatalf("artifact = %+v err=%v", artifact, err)
	}
}

func TestClientPreparesWarmSession(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/sessions/ses_1/prepare" || r.Method != http.MethodPost {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Idempotency-Key"); got != "prepare-1" {
			t.Errorf("idempotency key = %q", got)
		}
		var body struct {
			ExpectedRevision int64 `json:"expected_revision"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body.ExpectedRevision != 3 {
			t.Errorf("expected revision = %d", body.ExpectedRevision)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ses_1","revision":4,"state":"open","activity":"parked"}`))
	})}
	go server.Serve(listener)
	defer server.Shutdown(context.Background())

	client := New(socket, time.Second)
	prepared, err := client.PrepareSession(context.Background(), "prepare-1", "ses_1", 3)
	if err != nil || prepared.ID != "ses_1" || prepared.Revision != 4 {
		t.Fatalf("prepared session = %+v, %v", prepared, err)
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

func TestClientPagesChangesAndDownloadsReviewPatch(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/sessions/ses_1/changes":
			if r.URL.Query().Get("patch_offset") != "7000" ||
				r.URL.Query().Get("patch_limit") != "7000" {
				t.Errorf("changes query = %s", r.URL.RawQuery)
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"base_commit":"base",
				"fork_head":"fork",
				"parent_head":"parent",
				"patch":"K3BhZ2UgMg==",
				"truncated":true,
				"patch_digest":"` + digest + `",
				"patch_bytes":14007,
				"patch_offset":7000,
				"patch_next_offset":7007,
				"patch_has_more":true
			}`))
		case "/v1/operations/op_1/review-patch":
			w.Header().Set("Content-Type", "text/x-diff")
			w.Header().Set("ETag", `"`+digest+`"`)
			_, _ = w.Write([]byte("+complete patch\n"))
		default:
			http.NotFound(w, r)
		}
	})}
	go server.Serve(listener)
	defer server.Shutdown(context.Background())

	client := New(socket, time.Second)
	changes, err := client.ChangesPage(context.Background(), "ses_1", 7000, 7000)
	if err != nil || string(changes.Patch) != "+page 2" ||
		changes.PatchOffset != 7000 || changes.PatchDigest != digest {
		t.Fatalf("changes page = %+v, %v", changes, err)
	}
	artifact, err := client.ReviewPatch(context.Background(), "op_1")
	if err != nil || string(artifact.Patch) != "+complete patch\n" ||
		artifact.Digest != digest {
		t.Fatalf("review patch = %+v, %v", artifact, err)
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
