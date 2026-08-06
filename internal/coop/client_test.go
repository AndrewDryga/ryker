package coop

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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

// Retry classification decides whether Responder replays a Coop mutation, so
// it must not depend on matching an error message. A transport failure is
// always retryable; an API error follows its status; anything else is not.
func TestRetryableClassifiesByType(t *testing.T) {
	for _, testCase := range []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"transport", &TransportError{Err: errors.New("dial unix: connection refused")}, true},
		{"wrapped transport", fmt.Errorf("submit turn: %w", &TransportError{Err: io.ErrUnexpectedEOF}), true},
		{"rate limited", &APIError{Status: http.StatusTooManyRequests, Code: "rate_limited"}, true},
		{"server error", &APIError{Status: http.StatusBadGateway, Code: "upstream"}, true},
		{"conflict", &APIError{Status: http.StatusConflict, Code: "revision_conflict"}, false},
		{"not found", &APIError{Status: http.StatusNotFound, Code: "no_session"}, false},
		{"invalid state", &APIError{Status: http.StatusUnprocessableEntity, Code: "invalid_session_state"}, false},
		{"plain error", errors.New("call Coop: something that merely mentions it"), false},
		{"net error", &net.OpError{Op: "dial", Err: errors.New("refused")}, true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if got := Retryable(testCase.err); got != testCase.want {
				t.Fatalf("Retryable(%v) = %t, want %t", testCase.err, got, testCase.want)
			}
		})
	}
}

// A revision conflict must stay distinguishable so callers can surface it
// instead of guessing a new action, and it must not read as retryable.
func TestAPIErrorMessageAndUnwrapping(t *testing.T) {
	detailed := &APIError{Status: 409, Code: "revision_conflict", Detail: "session moved"}
	if got := detailed.Error(); got != "Coop API revision_conflict (409): session moved" {
		t.Fatalf("error = %q", got)
	}
	bare := &APIError{Status: 500, Code: "internal"}
	if got := bare.Error(); got != "Coop API internal (500)" {
		t.Fatalf("error = %q", got)
	}
	var target *APIError
	if !errors.As(fmt.Errorf("close session: %w", detailed), &target) ||
		target.Code != "revision_conflict" {
		t.Fatal("APIError did not survive wrapping")
	}

	transport := &TransportError{Err: io.ErrUnexpectedEOF}
	if got := transport.Error(); got != "call Coop: unexpected EOF" {
		t.Fatalf("transport error = %q", got)
	}
	if !errors.Is(transport, io.ErrUnexpectedEOF) {
		t.Fatal("TransportError does not unwrap to its cause")
	}
}

// A lost response must replay the exact same request, so every revision-bearing
// mutation has to send the revision it froze and its stable idempotency key.
func TestRevisionBearingMutationsFreezeTheirRequest(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	type seen struct {
		method, path, key string
		body              map[string]any
	}
	var requests []seen
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		record := seen{method: r.Method, path: r.URL.Path, key: r.Header.Get("Idempotency-Key")}
		_ = json.NewDecoder(r.Body).Decode(&record.body)
		requests = append(requests, record)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/discard-plan"):
			fmt.Fprint(w, `{"operation_id":"op_1","plan":{"workspace":{"head":"abc","dirty":false}}}`)
		case strings.Contains(r.URL.Path, "/turns/"):
			fmt.Fprint(w, `{"id":"turn_1","session_id":"s1","state":"cancelled"}`)
		default:
			fmt.Fprint(w, `{"id":"s1","revision":8,"state":"closed"}`)
		}
	})}
	go server.Serve(listener)
	defer server.Close()

	client := New(socket, 5*time.Second)
	ctx := context.Background()
	if _, _, err := client.Cancel(ctx, "responder:stop:in_1", "s1", "turn_1", 7); err != nil {
		t.Fatal(err)
	}
	if _, _, err := client.Extend(ctx, "responder:extend:in_1", "s1", 7, 3); err != nil {
		t.Fatal(err)
	}
	if _, _, err := client.Close(ctx, "responder:close:in_1", "s1", 7); err != nil {
		t.Fatal(err)
	}
	if _, _, err := client.PlanDiscard(ctx, "responder:gc-plan:s1:7", "s1", 7, false, false); err != nil {
		t.Fatal(err)
	}
	if len(requests) != 4 {
		t.Fatalf("requests = %d, want 4", len(requests))
	}
	for _, request := range requests {
		if request.key == "" {
			t.Fatalf("%s %s carried no idempotency key", request.method, request.path)
		}
		revision, ok := request.body["expected_revision"]
		if !ok {
			t.Fatalf("%s %s did not freeze a revision: %#v", request.method, request.path, request.body)
		}
		if revision != float64(7) {
			t.Fatalf("%s %s froze revision %v, want 7", request.method, request.path, revision)
		}
	}
}

// The polling and review reads carry the cursor and revision the caller froze.
// Events in particular are consumed by durable sequence cursor, so a wrong
// `after` would silently replay or skip session history.
func TestReadPathsCarryCursorsAndRevisions(t *testing.T) {
	socket := shortSocket(t)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	var paths, queries []string
	var reviewRevision any
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		queries = append(queries, r.URL.RawQuery)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/events"):
			fmt.Fprint(w, `[{"id":"e1","session_id":"s1","sequence":12,"type":"turn.completed"}]`)
		case strings.HasSuffix(r.URL.Path, "/changes"):
			fmt.Fprint(w, `{"base_commit":"abc","committed":[{"path":"x","status":"modified"}]}`)
		case strings.HasSuffix(r.URL.Path, "/review"):
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			reviewRevision = body["expected_revision"]
			fmt.Fprint(w, `{"operation":{"id":"op_r","state":"succeeded"},"review":{"publishable":true,"parent_head":"a","candidate_tree":"b"}}`)
		case strings.Contains(r.URL.Path, "/turns/"):
			fmt.Fprint(w, `{"id":"turn_9","session_id":"s1","state":"completed"}`)
		default:
			fmt.Fprint(w, `[{"id":"s1","state":"open"}]`)
		}
	})}
	go server.Serve(listener)
	defer server.Close()

	client := New(socket, 5*time.Second)
	ctx := context.Background()

	events, err := client.Events(ctx, "s1", 11, 50)
	if err != nil || len(events) != 1 || events[0].Sequence != 12 {
		t.Fatalf("events = %+v err=%v", events, err)
	}
	if !strings.Contains(queries[0], "after=11") || !strings.Contains(queries[0], "limit=50") {
		t.Fatalf("events query = %q", queries[0])
	}

	changes, err := client.Changes(ctx, "s1")
	if err != nil || len(changes.Committed) != 1 || changes.Committed[0].Path != "x" {
		t.Fatalf("changes = %+v err=%v", changes, err)
	}

	if _, err := client.ChangesPage(ctx, "s1", -1, 10); err == nil {
		t.Fatal("a negative patch offset should be rejected before any request")
	}
	if _, err := client.ChangesPage(ctx, "s1", 0, 0); err == nil {
		t.Fatal("a non-positive patch limit should be rejected before any request")
	}
	if _, err := client.ChangesPage(ctx, "s1", 100, 25); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(queries[len(queries)-1], "patch_offset=100") {
		t.Fatalf("changes page query = %q", queries[len(queries)-1])
	}

	review, operation, err := client.Review(ctx, "responder:review:in_1", "s1", 4)
	if err != nil || !review.Publishable || operation.ID != "op_r" {
		t.Fatalf("review = %+v op=%+v err=%v", review, operation, err)
	}
	if reviewRevision != float64(4) {
		t.Fatalf("review froze revision %v, want 4", reviewRevision)
	}

	if _, err := client.GetTurn(ctx, "s1", "turn_9"); err != nil {
		t.Fatal(err)
	}
	if sessions, err := client.ListSessions(ctx, 10); err != nil || len(sessions) != 1 {
		t.Fatalf("sessions = %+v err=%v", sessions, err)
	}
	if got := client.Socket(); got != socket {
		t.Fatalf("socket = %q, want %q", got, socket)
	}
	for _, path := range paths {
		if !strings.HasPrefix(path, "/v1/sessions/s1") && path != "/v1/sessions" {
			t.Fatalf("unexpected path %q", path)
		}
	}
}
