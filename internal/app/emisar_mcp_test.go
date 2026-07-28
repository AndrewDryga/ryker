package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPreflightEmisarMCPAuthenticatesAndRequiresOperationalTools(t *testing.T) {
	var methods []string
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("authorization = %q", request.Header.Get("Authorization"))
		}
		var rpc struct {
			ID     int    `json:"id"`
			Method string `json:"method"`
		}
		if err := json.NewDecoder(request.Body).Decode(&rpc); err != nil {
			t.Errorf("decode request: %v", err)
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		methods = append(methods, rpc.Method)
		writer.Header().Set("Content-Type", "application/json")
		switch rpc.Method {
		case "initialize":
			if got := request.Header.Get("MCP-Protocol-Version"); got != "" {
				t.Errorf("initialize protocol header = %q", got)
			}
			_, _ = writer.Write([]byte(`{
				"jsonrpc":"2.0",
				"id":1,
				"result":{
					"protocolVersion":"2025-11-25",
					"serverInfo":{"name":"emisar","version":"test"}
				}
			}`))
		case "tools/list":
			if got := request.Header.Get("MCP-Protocol-Version"); got != "2025-11-25" {
				t.Errorf("tools/list protocol header = %q", got)
			}
			_, _ = writer.Write([]byte(`{
				"jsonrpc":"2.0",
				"id":2,
				"result":{"tools":[
					{"name":"list_runners"},
					{"name":"find_actions"},
					{"name":"get_action"},
					{"name":"run_action"},
					{"name":"recent_runs"}
				]}
			}`))
		default:
			t.Fatalf("unexpected MCP method %q", rpc.Method)
		}
	}))
	defer server.Close()

	report, err := preflightEmisarMCP(
		context.Background(),
		server.Client(),
		server.URL,
		"test-token",
	)
	if err != nil {
		t.Fatal(err)
	}
	if report.ProtocolVersion != "2025-11-25" || report.ToolCount != 5 {
		t.Fatalf("report = %+v", report)
	}
	if strings.Join(methods, ",") != "initialize,tools/list" {
		t.Fatalf("methods = %v", methods)
	}
}

func TestPreflightEmisarMCPRejectsMissingRequiredTool(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var rpc struct {
			Method string `json:"method"`
		}
		if err := json.NewDecoder(request.Body).Decode(&rpc); err != nil {
			t.Errorf("decode request: %v", err)
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		if rpc.Method == "initialize" {
			_, _ = writer.Write([]byte(`{
				"jsonrpc":"2.0",
				"id":1,
				"result":{
					"protocolVersion":"2025-11-25",
					"serverInfo":{"name":"emisar"}
				}
			}`))
			return
		}
		_, _ = writer.Write([]byte(`{
			"jsonrpc":"2.0",
			"id":2,
			"result":{"tools":[{"name":"list_runners"}]}
		}`))
	}))
	defer server.Close()

	_, err := preflightEmisarMCP(
		context.Background(),
		server.Client(),
		server.URL,
		"test-token",
	)
	if err == nil || !strings.Contains(err.Error(), `missing required tool "find_actions"`) {
		t.Fatalf("missing tool error = %v", err)
	}
}

func TestPreflightEmisarMCPReportsAuthenticationFailureWithoutToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()

	_, err := preflightEmisarMCP(
		context.Background(),
		server.Client(),
		server.URL,
		"invalid-token",
	)
	if err == nil || !strings.Contains(err.Error(), "initialize: HTTP 401") {
		t.Fatalf("authentication error = %v", err)
	}
	if strings.Contains(err.Error(), "invalid-token") {
		t.Fatalf("authentication error leaked token: %v", err)
	}
}
