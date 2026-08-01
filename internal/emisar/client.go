package emisar

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
)

const (
	protocolVersion = "2025-11-25"
	responseLimit   = 2 << 20
)

type HTTPDoer interface {
	Do(*http.Request) (*http.Response, error)
}

// RunState is the intentionally small projection Responder needs to supervise
// an Emisar run. Action output remains in Emisar and is interpreted later by a
// policy-bound Coop turn after the run becomes terminal.
type RunState struct {
	RunID        string
	OperationID  string
	ActionID     string
	PackRef      string
	RunnerRef    string
	Status       string
	RunURL       string
	ErrorMessage string
}

type Client struct {
	http  HTTPDoer
	url   string
	token string
	next  atomic.Uint64
}

func New(client HTTPDoer, endpoint string, token string) *Client {
	return &Client{http: client, url: endpoint, token: token}
}

func (c *Client) WaitForRun(ctx context.Context, runID string) (RunState, error) {
	if c == nil || c.http == nil {
		return RunState{}, errors.New("Emisar HTTP client is unavailable")
	}
	if strings.TrimSpace(c.url) == "" || strings.TrimSpace(c.token) == "" ||
		strings.TrimSpace(runID) == "" {
		return RunState{}, errors.New("Emisar run lookup is incomplete")
	}
	payload := map[string]any{
		"jsonrpc": "2.0",
		"id":      c.next.Add(1),
		"method":  "tools/call",
		"params": map[string]any{
			"name": "wait_for_run",
			"arguments": map[string]any{
				"run_id":  runID,
				"timeout": "0",
			},
		},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return RunState{}, err
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		c.url,
		bytes.NewReader(body),
	)
	if err != nil {
		return RunState{}, err
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("MCP-Protocol-Version", protocolVersion)
	request.Header.Set("User-Agent", "responder")
	response, err := c.http.Do(request)
	if err != nil {
		return RunState{}, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, responseLimit+1))
	if err != nil {
		return RunState{}, err
	}
	if len(data) > responseLimit {
		return RunState{}, errors.New("Emisar response exceeds 2 MiB")
	}
	if response.StatusCode != http.StatusOK {
		return RunState{}, fmt.Errorf("Emisar HTTP %d", response.StatusCode)
	}
	var rpc struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(data, &rpc); err != nil {
		return RunState{}, fmt.Errorf("decode Emisar JSON-RPC response: %w", err)
	}
	if rpc.Error != nil {
		return RunState{}, fmt.Errorf(
			"Emisar JSON-RPC error %d: %s",
			rpc.Error.Code,
			rpc.Error.Message,
		)
	}
	if len(rpc.Result) == 0 {
		return RunState{}, errors.New("Emisar JSON-RPC response has no result")
	}
	var tool struct {
		IsError           bool            `json:"isError"`
		StructuredContent json.RawMessage `json:"structuredContent"`
	}
	if err := json.Unmarshal(rpc.Result, &tool); err != nil {
		return RunState{}, fmt.Errorf("decode Emisar tool result: %w", err)
	}
	if len(tool.StructuredContent) == 0 {
		return RunState{}, errors.New("Emisar wait_for_run returned no structured content")
	}
	var result struct {
		OK    bool `json:"ok"`
		Error *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
		Run struct {
			RunID        string `json:"run_id"`
			OperationID  string `json:"operation_id"`
			ActionID     string `json:"action_id"`
			PackRef      string `json:"pack_ref"`
			RunnerRef    string `json:"runner_ref"`
			Status       string `json:"status"`
			RunURL       string `json:"run_url"`
			ErrorMessage string `json:"error_message"`
		} `json:"run"`
	}
	if err := json.Unmarshal(tool.StructuredContent, &result); err != nil {
		return RunState{}, fmt.Errorf("decode Emisar wait_for_run content: %w", err)
	}
	if tool.IsError || !result.OK {
		if result.Error != nil {
			return RunState{}, fmt.Errorf(
				"Emisar wait_for_run %s: %s",
				result.Error.Code,
				result.Error.Message,
			)
		}
		return RunState{}, errors.New("Emisar wait_for_run returned an error")
	}
	state := RunState{
		RunID: result.Run.RunID, OperationID: result.Run.OperationID,
		ActionID: result.Run.ActionID, PackRef: result.Run.PackRef,
		RunnerRef: result.Run.RunnerRef, Status: result.Run.Status,
		RunURL:       safeSameOriginURL(result.Run.RunURL, c.url),
		ErrorMessage: strings.TrimSpace(result.Run.ErrorMessage),
	}
	if state.RunID == "" || state.OperationID == "" || state.ActionID == "" ||
		state.PackRef == "" || state.RunnerRef == "" || state.Status == "" {
		return RunState{}, errors.New("Emisar wait_for_run returned an incomplete run identity")
	}
	return state, nil
}

func safeSameOriginURL(value string, endpoint string) string {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil ||
		parsed.RawQuery != "" || parsed.Fragment != "" {
		return ""
	}
	base, err := url.Parse(endpoint)
	if err != nil || !strings.EqualFold(parsed.Host, base.Host) {
		return ""
	}
	return parsed.String()
}
