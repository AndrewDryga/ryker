package emisar

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// DraftState is the intentionally small projection Responder keeps after
// asking Emisar to hold a runbook draft.
//
// Small for the same reason RunState is. The draft's definition lives in
// Emisar, a person reviews it there, and Emisar alone decides whether it is
// ever published. What Responder needs back is proof that the draft exists and
// enough of an identity to say so in a Slack receipt.
type DraftState struct {
	Slug             string
	DefinitionSHA256 string
	RunbookRef       string
	RunbookURL       string
}

// CreateRunbookDraft asks Emisar to hold one unpublished runbook change.
//
// The arguments are built by internal/knowledgeoffer from an operator-confirmed
// offer and the host's own approval records; this function adds nothing to them
// and interprets nothing in them. It is the narrowest possible boundary: one
// tool, one payload, one answer.
//
// A slug the server did not echo back is accepted, and a slug it echoed back
// DIFFERENTLY is refused. Emisar may normalize or assign one, and a draft
// created under a name Responder does not know about is a draft Responder will
// later tell an operator the wrong thing about — the receipt would name a
// document nobody can find.
func (c *Client) CreateRunbookDraft(
	ctx context.Context,
	arguments map[string]any,
) (DraftState, error) {
	requested, _ := arguments["slug"].(string)
	if strings.TrimSpace(requested) == "" {
		return DraftState{}, errors.New("Emisar runbook draft is missing its slug")
	}
	content, isError, err := c.call(ctx, "create_runbook_draft", arguments)
	if err != nil {
		return DraftState{}, err
	}
	var result struct {
		OK    bool `json:"ok"`
		Error *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
		Runbook struct {
			Slug       string `json:"slug"`
			RunbookURL string `json:"runbook_url"`
			Draft      struct {
				DefinitionSHA256 string `json:"definition_sha256"`
				RunbookRef       string `json:"runbook_ref"`
			} `json:"draft"`
		} `json:"runbook"`
	}
	if err := json.Unmarshal(content, &result); err != nil {
		return DraftState{}, fmt.Errorf("decode Emisar create_runbook_draft content: %w", err)
	}
	if isError || !result.OK {
		if result.Error != nil {
			return DraftState{}, fmt.Errorf(
				"Emisar create_runbook_draft %s: %s", result.Error.Code, result.Error.Message,
			)
		}
		return DraftState{}, errors.New("Emisar create_runbook_draft returned an error")
	}
	slug := strings.TrimSpace(result.Runbook.Slug)
	if slug != "" && slug != strings.TrimSpace(requested) {
		return DraftState{}, fmt.Errorf(
			"Emisar created the draft as %q, not the requested %q", slug, requested,
		)
	}
	return DraftState{
		Slug:             strings.TrimSpace(requested),
		DefinitionSHA256: strings.TrimSpace(result.Runbook.Draft.DefinitionSHA256),
		RunbookRef:       strings.TrimSpace(result.Runbook.Draft.RunbookRef),
		RunbookURL:       safeSameOriginURL(result.Runbook.RunbookURL, c.url),
	}, nil
}
