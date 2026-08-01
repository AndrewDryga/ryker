package emisar

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) Do(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestWaitForRunReturnsOnlyLifecycleProjection(t *testing.T) {
	client := New(roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Header.Get("Authorization") != "Bearer secret" ||
			request.Header.Get("MCP-Protocol-Version") != protocolVersion {
			t.Fatalf("headers = %+v", request.Header)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		for _, expected := range []string{`"name":"wait_for_run"`, `"run_id":"run_1"`, `"timeout":"0"`} {
			if !strings.Contains(string(body), expected) {
				t.Fatalf("request body lacks %s: %s", expected, body)
			}
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(strings.NewReader(`{
				"jsonrpc":"2.0","id":1,"result":{
					"isError":false,
					"structuredContent":{"ok":true,"run":{
						"run_id":"run_1","operation_id":"op_1",
						"action_id":"service.restart","pack_ref":"ops@1#sha256:abc",
						"runner_ref":"prod~abc","status":"success",
						"run_url":"https://emisar.dev/app/runs/run_1",
						"stdout":"must not escape","structured_output":{"secret":"must not escape"}
					}}
				}
			}`)),
		}, nil
	}), "https://emisar.dev/api/mcp/rpc", "secret")
	state, err := client.WaitForRun(context.Background(), "run_1")
	if err != nil {
		t.Fatal(err)
	}
	if state.Status != "success" || state.ActionID != "service.restart" ||
		state.RunURL != "https://emisar.dev/app/runs/run_1" {
		t.Fatalf("run state = %+v", state)
	}
}

func TestWaitForRunRejectsMalformedAndCrossOriginResults(t *testing.T) {
	client := New(roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(strings.NewReader(`{
				"jsonrpc":"2.0","id":1,"result":{
					"isError":false,
					"structuredContent":{"ok":true,"run":{
						"run_id":"run_1","operation_id":"op_1",
						"action_id":"service.restart","pack_ref":"ops@1#sha256:abc",
						"runner_ref":"prod~abc","status":"running",
						"run_url":"https://evil.example/runs/run_1"
					}}
				}
			}`)),
		}, nil
	}), "https://emisar.dev/api/mcp/rpc", "secret")
	state, err := client.WaitForRun(context.Background(), "run_1")
	if err != nil {
		t.Fatal(err)
	}
	if state.RunURL != "" {
		t.Fatalf("cross-origin run URL retained: %+v", state)
	}

	client = New(roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"ok":true,"run":{"run_id":"run_1"}}}}`)),
		}, nil
	}), "https://emisar.dev/api/mcp/rpc", "secret")
	if _, err := client.WaitForRun(context.Background(), "run_1"); err == nil ||
		!strings.Contains(err.Error(), "incomplete run identity") {
		t.Fatalf("incomplete identity error = %v", err)
	}
}
