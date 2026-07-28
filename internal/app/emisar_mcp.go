package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
)

const (
	emisarMCPProtocolVersion = "2025-11-25"
	emisarMCPResponseLimit   = 2 << 20
)

var requiredEmisarTools = []string{
	"find_actions",
	"get_action",
	"list_runners",
	"run_action",
}

type emisarMCPReport struct {
	ProtocolVersion string
	ToolCount       int
}

type httpDoer interface {
	Do(*http.Request) (*http.Response, error)
}

type mcpResponse struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func preflightEmisarMCP(
	ctx context.Context,
	client httpDoer,
	url string,
	token string,
) (emisarMCPReport, error) {
	if client == nil {
		return emisarMCPReport{}, errors.New("HTTP client is unavailable")
	}
	initialize, err := callEmisarMCP(
		ctx,
		client,
		url,
		token,
		"",
		map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"method":  "initialize",
			"params": map[string]any{
				"protocolVersion": emisarMCPProtocolVersion,
				"capabilities":    map[string]any{},
				"clientInfo": map[string]string{
					"name":    "responder",
					"version": "dev",
				},
			},
		},
	)
	if err != nil {
		return emisarMCPReport{}, fmt.Errorf("initialize: %w", err)
	}
	var initialized struct {
		ProtocolVersion string `json:"protocolVersion"`
		ServerInfo      struct {
			Name string `json:"name"`
		} `json:"serverInfo"`
	}
	if err := json.Unmarshal(initialize.Result, &initialized); err != nil {
		return emisarMCPReport{}, fmt.Errorf("initialize returned malformed result: %w", err)
	}
	if initialized.ProtocolVersion == "" || initialized.ServerInfo.Name != "emisar" {
		return emisarMCPReport{}, errors.New("initialize returned an unexpected server identity")
	}

	list, err := callEmisarMCP(
		ctx,
		client,
		url,
		token,
		initialized.ProtocolVersion,
		map[string]any{
			"jsonrpc": "2.0",
			"id":      2,
			"method":  "tools/list",
			"params":  map[string]any{},
		},
	)
	if err != nil {
		return emisarMCPReport{}, fmt.Errorf("tools/list: %w", err)
	}
	var catalog struct {
		Tools []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(list.Result, &catalog); err != nil {
		return emisarMCPReport{}, fmt.Errorf("tools/list returned malformed result: %w", err)
	}
	names := make([]string, 0, len(catalog.Tools))
	for _, tool := range catalog.Tools {
		names = append(names, tool.Name)
	}
	for _, required := range requiredEmisarTools {
		if !slices.Contains(names, required) {
			return emisarMCPReport{}, fmt.Errorf("tools/list is missing required tool %q", required)
		}
	}
	return emisarMCPReport{
		ProtocolVersion: initialized.ProtocolVersion,
		ToolCount:       len(catalog.Tools),
	}, nil
}

func callEmisarMCP(
	ctx context.Context,
	client httpDoer,
	url string,
	token string,
	protocolVersion string,
	payload any,
) (mcpResponse, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return mcpResponse{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return mcpResponse{}, err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("User-Agent", "responder")
	if protocolVersion != "" {
		request.Header.Set("MCP-Protocol-Version", protocolVersion)
	}
	response, err := client.Do(request)
	if err != nil {
		return mcpResponse{}, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, emisarMCPResponseLimit+1))
	if err != nil {
		return mcpResponse{}, err
	}
	if len(data) > emisarMCPResponseLimit {
		return mcpResponse{}, errors.New("response exceeds 2 MiB")
	}
	if response.StatusCode != http.StatusOK {
		return mcpResponse{}, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	var rpc mcpResponse
	if err := json.Unmarshal(data, &rpc); err != nil {
		return mcpResponse{}, fmt.Errorf("malformed JSON-RPC response: %w", err)
	}
	if rpc.Error != nil {
		return mcpResponse{}, fmt.Errorf(
			"JSON-RPC error %d: %s",
			rpc.Error.Code,
			rpc.Error.Message,
		)
	}
	if len(rpc.Result) == 0 {
		return mcpResponse{}, errors.New("JSON-RPC response has no result")
	}
	return rpc, nil
}
