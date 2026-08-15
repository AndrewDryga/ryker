package emisar

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func draftResponse(body string) roundTripFunc {
	return roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(body)),
		}, nil
	})
}

// The draft call carries the arguments it was handed and nothing this package
// invented, and it goes out with the same authorization and protocol headers
// the run lookup does.
//
// Both halves matter. A second tool that quietly dropped the protocol header
// would fail at Emisar with a message nobody here would recognise, and one that
// rewrote its arguments would break the only claim this whole path makes: that
// the draft names the action the episode actually ran.
func TestCreatingARunbookDraftSendsExactlyTheArgumentsItWasGiven(t *testing.T) {
	var sent map[string]any
	client := New(roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Header.Get("Authorization") != "Bearer secret" ||
			request.Header.Get("MCP-Protocol-Version") != protocolVersion {
			t.Fatalf("headers = %+v", request.Header)
		}
		var envelope struct {
			Params struct {
				Name      string         `json:"name"`
				Arguments map[string]any `json:"arguments"`
			} `json:"params"`
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(body, &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Params.Name != "create_runbook_draft" {
			t.Fatalf("called %q", envelope.Params.Name)
		}
		sent = envelope.Params.Arguments
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":1,"result":{
				"isError":false,
				"structuredContent":{"ok":true,"runbook":{
					"slug":"pool-restart",
					"runbook_url":"https://emisar.dev/app/runbooks/pool-restart",
					"draft":{"definition_sha256":"abc123"}
				}}
			}}`)),
		}, nil
	}), "https://emisar.dev/mcp", "secret")
	state, err := client.CreateRunbookDraft(context.Background(), map[string]any{
		"title": "Restart the pool", "slug": "pool-restart",
		"description": "when the pool exhausts", "definition": map[string]any{"schema_version": 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	if sent["slug"] != "pool-restart" || sent["title"] != "Restart the pool" {
		t.Fatalf("arguments were rewritten: %+v", sent)
	}
	if state.Slug != "pool-restart" || state.DefinitionSHA256 != "abc123" {
		t.Fatalf("state = %+v", state)
	}
	if state.RunbookURL != "https://emisar.dev/app/runbooks/pool-restart" {
		t.Fatalf("same-origin runbook URL was dropped: %q", state.RunbookURL)
	}
}

// A URL pointing somewhere other than the configured Emisar endpoint is
// discarded rather than rendered. The receipt this ends up in is a Slack
// message an operator clicks, and a link an untrusted response chose is a link
// this product must never hand somebody.
func TestARunbookURLFromAnotherOriginIsDropped(t *testing.T) {
	client := New(draftResponse(`{"jsonrpc":"2.0","id":1,"result":{"isError":false,
		"structuredContent":{"ok":true,"runbook":{
			"slug":"pool-restart","runbook_url":"https://evil.example/app/runbooks/x",
			"draft":{"definition_sha256":"abc123"}}}}}`), "https://emisar.dev/mcp", "secret")
	state, err := client.CreateRunbookDraft(
		context.Background(), map[string]any{"slug": "pool-restart"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if state.RunbookURL != "" {
		t.Fatalf("a foreign-origin URL survived: %q", state.RunbookURL)
	}
}

// A draft Emisar named differently from the one that was requested is refused.
// The receipt would otherwise tell an operator to review a runbook under a slug
// that does not exist, and the one they cannot find is the one nobody reviews.
func TestADraftCreatedUnderAnotherSlugIsRefused(t *testing.T) {
	client := New(draftResponse(`{"jsonrpc":"2.0","id":1,"result":{"isError":false,
		"structuredContent":{"ok":true,"runbook":{"slug":"something-else",
			"draft":{"definition_sha256":"abc123"}}}}}`), "https://emisar.dev/mcp", "secret")
	_, err := client.CreateRunbookDraft(
		context.Background(), map[string]any{"slug": "pool-restart"},
	)
	if err == nil || !strings.Contains(err.Error(), "something-else") {
		t.Fatalf("a renamed draft was accepted: %v", err)
	}
}

// An error result is reported with the code Emisar chose, not flattened into a
// generic failure. "The definition is invalid at stages/0/steps/0" and "you are
// not allowed to create runbooks" lead to different next steps.
func TestARefusedDraftReportsEmisarsOwnReason(t *testing.T) {
	client := New(draftResponse(`{"jsonrpc":"2.0","id":1,"result":{"isError":true,
		"structuredContent":{"ok":false,"error":{"code":"invalid_definition",
			"message":"stages/0/steps/0/action is required"}}}}`), "https://emisar.dev/mcp", "secret")
	_, err := client.CreateRunbookDraft(
		context.Background(), map[string]any{"slug": "pool-restart"},
	)
	if err == nil || !strings.Contains(err.Error(), "invalid_definition") {
		t.Fatalf("error = %v", err)
	}
}
