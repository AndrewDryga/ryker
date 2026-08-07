package coop

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// MaxPromptBytes is the largest prompt a Coop turn accepts. Callers budget
// their context against it: the transport still enforces the cap, but a caller
// that arrives over it has already lost the ability to choose what is dropped.
const MaxPromptBytes = maxPromptBytes

const (
	maxResponseBytes       = 3 << 20
	maxReviewPatchBytes    = 64 << 20
	maxOutputArtifactBytes = 8 << 20
	maxPromptBytes         = 64 << 10
	promptTailBytes        = 20 << 10
)

const promptElisionMarker = "\n\n<responder-context-elided>\nOlder bounded context was omitted to fit the Coop turn limit.\n</responder-context-elided>\n\n"

type Client struct {
	socket string
	http   *http.Client

	// truncated reports a prompt the transport had to elide. Elision is a
	// backstop, not a strategy: it cuts the middle out, which can slice through
	// structured context, so a caller that trips it needs to know.
	truncated func(originalBytes, cap int)
}

// SetTruncationObserver installs a callback invoked whenever a prompt exceeds
// MaxPromptBytes and has to be elided.
func (c *Client) SetTruncationObserver(observer func(originalBytes, cap int)) {
	c.truncated = observer
}

type APIError struct {
	Status int
	Code   string
	Detail string
}

func (e *APIError) Error() string {
	if e.Detail == "" {
		return fmt.Sprintf("Coop API %s (%d)", e.Code, e.Status)
	}
	return fmt.Sprintf("Coop API %s (%d): %s", e.Code, e.Status, e.Detail)
}

func (e *APIError) Retryable() bool {
	return e.Status == http.StatusTooManyRequests || e.Status >= 500
}

// TransportError marks a failure to complete a Coop request at all: dial,
// write, read, or timeout. It is always retryable, and having a type for it
// means retry classification never depends on matching an error message.
type TransportError struct{ Err error }

func (e *TransportError) Error() string { return "call Coop: " + e.Err.Error() }

func (e *TransportError) Unwrap() error { return e.Err }

type Operation struct {
	ID           string    `json:"id"`
	Method       string    `json:"method"`
	State        string    `json:"state"`
	ResourceType string    `json:"resource_type,omitempty"`
	ResourceID   string    `json:"resource_id,omitempty"`
	ErrorCode    string    `json:"error_code,omitempty"`
	ErrorDetail  string    `json:"error_detail,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type Session struct {
	ID                string                `json:"id"`
	ExternalRef       string                `json:"external_ref"`
	Target            string                `json:"target"`
	Policy            string                `json:"policy"`
	PolicyDigest      string                `json:"policy_digest"`
	BaseCommit        string                `json:"base_commit"`
	Companions        []CompanionRepository `json:"companions,omitempty"`
	ForkName          string                `json:"fork_name"`
	Revision          int64                 `json:"revision"`
	State             string                `json:"state"`
	Activity          string                `json:"activity"`
	MaxTurns          int                   `json:"max_turns"`
	MaxQueuedTurns    int                   `json:"max_queued_turns"`
	MaxQueuedBytes    int                   `json:"max_queued_bytes"`
	TurnsUsed         int                   `json:"turns_used"`
	QueuedTurnCount   int                   `json:"queued_turn_count"`
	QueuedPromptBytes int                   `json:"queued_prompt_bytes"`
	ActiveTurnID      string                `json:"active_turn_id,omitempty"`
	LastEventSequence int64                 `json:"last_event_sequence"`
	CreatedAt         time.Time             `json:"created_at"`
	UpdatedAt         time.Time             `json:"updated_at"`
}

type CompanionRepository struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	BaseCommit string `json:"base_commit"`
}

type Turn struct {
	ID               string           `json:"id"`
	SessionID        string           `json:"session_id"`
	Ordinal          int64            `json:"ordinal"`
	State            string           `json:"state"`
	SendState        string           `json:"send_state"`
	AssistantMessage string           `json:"assistant_message,omitempty"`
	StopReason       string           `json:"stop_reason,omitempty"`
	ErrorCode        string           `json:"error_code,omitempty"`
	ErrorDetail      string           `json:"error_detail,omitempty"`
	QueuedAt         time.Time        `json:"queued_at"`
	StartedAt        time.Time        `json:"started_at,omitempty"`
	FinishedAt       time.Time        `json:"finished_at,omitempty"`
	OutputArtifacts  []OutputArtifact `json:"output_artifacts,omitempty"`
}

type OutputArtifact struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	MediaType string `json:"media_type"`
	SHA256    string `json:"sha256"`
	Bytes     int64  `json:"bytes"`
	Data      []byte `json:"-"`
}

type InputArtifact struct {
	Name      string `json:"name"`
	MediaType string `json:"media_type"`
	SHA256    string `json:"sha256"`
	Data      []byte `json:"data"`
}

type Event struct {
	ID         string    `json:"id"`
	SessionID  string    `json:"session_id"`
	Sequence   int64     `json:"sequence"`
	TurnID     string    `json:"turn_id,omitempty"`
	Type       string    `json:"type"`
	Version    int       `json:"version"`
	OccurredAt time.Time `json:"occurred_at"`
}

type Change struct {
	Path         string `json:"path,omitempty"`
	PathBytes    []byte `json:"path_bytes,omitempty"`
	OldPath      string `json:"old_path,omitempty"`
	OldPathBytes []byte `json:"old_path_bytes,omitempty"`
	Status       string `json:"status"`
}

type ParentDivergence struct {
	Ahead        int  `json:"ahead"`
	Behind       int  `json:"behind"`
	BaseToFork   int  `json:"base_to_fork"`
	BaseToParent int  `json:"base_to_parent"`
	Diverged     bool `json:"diverged"`
}

type Changes struct {
	BaseCommit       string           `json:"base_commit"`
	ForkHead         string           `json:"fork_head"`
	ParentHead       string           `json:"parent_head"`
	Committed        []Change         `json:"committed"`
	Staged           []Change         `json:"staged"`
	Unstaged         []Change         `json:"unstaged"`
	Untracked        []Change         `json:"untracked"`
	Conflicts        []Change         `json:"conflicts"`
	ParentDivergence ParentDivergence `json:"parent_divergence"`
	Patch            []byte           `json:"patch,omitempty"`
	Truncated        bool             `json:"truncated"`
	PatchDigest      string           `json:"patch_digest,omitempty"`
	PatchBytes       int64            `json:"patch_bytes"`
	PatchOffset      int64            `json:"patch_offset"`
	PatchNextOffset  int64            `json:"patch_next_offset"`
	PatchHasMore     bool             `json:"patch_has_more"`
}

type Review struct {
	OperationID           string   `json:"operation_id"`
	SessionID             string   `json:"session_id"`
	SessionRevision       int64    `json:"session_revision"`
	PolicyDigest          string   `json:"policy_digest"`
	CreationBase          string   `json:"creation_base"`
	SourceHead            string   `json:"source_head"`
	SourceTree            string   `json:"source_tree"`
	ParentHead            string   `json:"parent_head"`
	ParentTree            string   `json:"parent_tree"`
	CandidateHead         string   `json:"candidate_head"`
	CandidateTree         string   `json:"candidate_tree"`
	Rebase                string   `json:"rebase"`
	Gate                  string   `json:"gate"`
	GateError             string   `json:"gate_error,omitempty"`
	PolicyFindings        []string `json:"policy_findings,omitempty"`
	Patch                 []byte   `json:"patch,omitempty"`
	PatchTruncated        bool     `json:"patch_truncated"`
	PatchArtifactID       string   `json:"patch_artifact_id,omitempty"`
	PatchDigest           string   `json:"patch_digest,omitempty"`
	PatchBytes            int64    `json:"patch_bytes"`
	Publishable           bool     `json:"publishable"`
	NotPublishableReasons []string `json:"not_publishable_reasons,omitempty"`
}

type ReviewPatchArtifact struct {
	Patch  []byte
	Digest string
}

type DiscardWorkspace struct {
	Branch           string `json:"branch"`
	Head             string `json:"head"`
	StatusDigest     string `json:"status_digest"`
	Dirty            bool   `json:"dirty"`
	Unmerged         bool   `json:"unmerged"`
	Running          bool   `json:"running"`
	AcceptedDirty    bool   `json:"accepted_dirty,omitempty"`
	AcceptedUnmerged bool   `json:"accepted_unmerged,omitempty"`
}

type DiscardPlan struct {
	OperationID string `json:"operation_id"`
	Plan        struct {
		SessionID string           `json:"session_id"`
		Revision  int64            `json:"revision"`
		Workspace DiscardWorkspace `json:"workspace"`
	} `json:"plan"`
}

type sessionResponse struct {
	Operation Operation `json:"operation"`
	Session   Session   `json:"session"`
}

type turnResponse struct {
	Operation Operation `json:"operation"`
	Turn      Turn      `json:"turn"`
}

type reviewResponse struct {
	Operation Operation `json:"operation"`
	Review    Review    `json:"review"`
}

type discardPlanResponse struct {
	Operation Operation   `json:"operation"`
	Plan      DiscardPlan `json:"plan"`
}

func New(socket string, timeout time.Duration) *Client {
	transport := &http.Transport{
		DisableCompression: true,
		Proxy:              nil,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			dialer := net.Dialer{Timeout: 5 * time.Second}
			return dialer.DialContext(ctx, "unix", socket)
		},
	}
	return &Client{
		socket: socket,
		http:   &http.Client{Transport: transport, Timeout: timeout},
	}
}

func (c *Client) Socket() string {
	return c.socket
}

func (c *Client) Ready(ctx context.Context) error {
	var response struct {
		Ready bool `json:"ready"`
	}
	if err := c.get(ctx, "/readyz", nil, &response); err != nil {
		return err
	}
	if !response.Ready {
		return errors.New("Coop session controller is not ready")
	}
	return nil
}

func (c *Client) CreateSession(ctx context.Context, key, policy, externalRef string) (Session, Operation, error) {
	var response sessionResponse
	err := c.post(ctx, "/v1/sessions", key, map[string]any{
		"policy": policy,
		"task":   externalRef,
	}, &response)
	return response.Session, response.Operation, err
}

func (c *Client) GetSession(ctx context.Context, id string) (Session, error) {
	var response Session
	err := c.get(ctx, "/v1/sessions/"+url.PathEscape(id), nil, &response)
	return response, err
}

func (c *Client) PrepareSession(ctx context.Context, key, id string, expectedRevision int64) (Session, error) {
	var response Session
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(id)+"/prepare", key, map[string]any{
		"expected_revision": expectedRevision,
	}, &response)
	return response, err
}

func (c *Client) ListSessions(ctx context.Context, limit int) ([]Session, error) {
	if limit < 1 || limit > 1000 {
		return nil, errors.New("Coop session list limit must be between 1 and 1000")
	}
	var response []Session
	err := c.get(ctx, "/v1/sessions", url.Values{"limit": {strconv.Itoa(limit)}}, &response)
	return response, err
}

func (c *Client) SubmitTurn(ctx context.Context, key, sessionID string, expectedRevision int64, prompt string) (Turn, Operation, error) {
	return c.SubmitTurnWithArtifacts(ctx, key, sessionID, expectedRevision, prompt, nil)
}

func (c *Client) SubmitTurnWithArtifacts(
	ctx context.Context,
	key, sessionID string,
	expectedRevision int64,
	prompt string,
	artifacts []InputArtifact,
) (Turn, Operation, error) {
	prompt = c.boundedPrompt(prompt)
	var response turnResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/turns", key, map[string]any{
		"expected_revision": expectedRevision,
		"prompt":            prompt,
		"artifacts":         artifacts,
	}, &response)
	return response.Turn, response.Operation, err
}

func (c *Client) boundedPrompt(prompt string) string {
	prompt = strings.ToValidUTF8(prompt, "\uFFFD")
	prompt = strings.ReplaceAll(prompt, "\x00", "\uFFFD")
	if len(prompt) <= maxPromptBytes {
		return prompt
	}
	if c.truncated != nil {
		c.truncated(len(prompt), maxPromptBytes)
	}
	tailStart := len(prompt) - promptTailBytes
	for tailStart < len(prompt) && !utf8.RuneStart(prompt[tailStart]) {
		tailStart++
	}
	headBytes := maxPromptBytes - len(promptElisionMarker) - (len(prompt) - tailStart)
	for headBytes > 0 && !utf8.ValidString(prompt[:headBytes]) {
		headBytes--
	}
	return prompt[:headBytes] + promptElisionMarker + prompt[tailStart:]
}

func (c *Client) GetTurn(ctx context.Context, sessionID, turnID string) (Turn, error) {
	var response Turn
	err := c.get(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/turns/"+url.PathEscape(turnID), nil, &response)
	return response, err
}

func (c *Client) GetOutputArtifact(ctx context.Context, sessionID, turnID, artifactID string) (OutputArtifact, error) {
	if strings.TrimSpace(sessionID) == "" || strings.TrimSpace(turnID) == "" || strings.TrimSpace(artifactID) == "" {
		return OutputArtifact{}, errors.New("Coop output artifact identity is required")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://coop.local/v1/sessions/"+url.PathEscape(sessionID)+"/turns/"+url.PathEscape(turnID)+"/artifacts/"+url.PathEscape(artifactID), nil)
	if err != nil {
		return OutputArtifact{}, err
	}
	request.Header.Set("Accept", "image/png,image/jpeg,image/webp,image/gif")
	response, err := c.http.Do(request)
	if err != nil {
		return OutputArtifact{}, fmt.Errorf("call Coop: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxOutputArtifactBytes+1))
	if err != nil {
		return OutputArtifact{}, fmt.Errorf("read Coop output artifact: %w", err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return OutputArtifact{}, &APIError{Status: response.StatusCode, Code: "artifact_unavailable"}
	}
	if len(data) == 0 || len(data) > maxOutputArtifactBytes {
		return OutputArtifact{}, errors.New("Coop output artifact exceeds 8 MiB")
	}
	return OutputArtifact{
		ID: artifactID, MediaType: strings.TrimSpace(strings.Split(response.Header.Get("Content-Type"), ";")[0]),
		SHA256: strings.Trim(response.Header.Get("ETag"), `"`), Bytes: int64(len(data)), Data: data,
	}, nil
}

func (c *Client) Events(ctx context.Context, sessionID string, after int64, limit int) ([]Event, error) {
	query := url.Values{
		"after": {strconv.FormatInt(after, 10)},
		"limit": {strconv.Itoa(limit)},
	}
	var response []Event
	err := c.get(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/events", query, &response)
	return response, err
}

func (c *Client) Changes(ctx context.Context, sessionID string) (Changes, error) {
	var response Changes
	err := c.get(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/changes", nil, &response)
	return response, err
}

func (c *Client) ChangesPage(
	ctx context.Context,
	sessionID string,
	patchOffset int64,
	patchLimit int,
) (Changes, error) {
	if patchOffset < 0 || patchLimit < 1 {
		return Changes{}, errors.New("Coop patch page requires a non-negative offset and positive limit")
	}
	query := url.Values{
		"patch_offset": {strconv.FormatInt(patchOffset, 10)},
		"patch_limit":  {strconv.Itoa(patchLimit)},
	}
	var response Changes
	err := c.get(
		ctx,
		"/v1/sessions/"+url.PathEscape(sessionID)+"/changes",
		query,
		&response,
	)
	return response, err
}

func (c *Client) Review(ctx context.Context, key, sessionID string, expectedRevision int64) (Review, Operation, error) {
	var response reviewResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/review", key, map[string]any{
		"expected_revision": expectedRevision,
	}, &response)
	return response.Review, response.Operation, err
}

func (c *Client) ReviewPatch(
	ctx context.Context,
	operationID string,
) (ReviewPatchArtifact, error) {
	if strings.TrimSpace(operationID) == "" {
		return ReviewPatchArtifact{}, errors.New("Coop review operation ID is required")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		"http://coop.local/v1/operations/"+url.PathEscape(operationID)+"/review-patch",
		nil,
	)
	if err != nil {
		return ReviewPatchArtifact{}, err
	}
	request.Header.Set("Accept", "text/x-diff")
	response, err := c.http.Do(request)
	if err != nil {
		return ReviewPatchArtifact{}, fmt.Errorf("call Coop: %w", err)
	}
	defer response.Body.Close()
	limit := int64(maxReviewPatchBytes + 1)
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		limit = maxResponseBytes + 1
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, limit))
	if err != nil {
		return ReviewPatchArtifact{}, fmt.Errorf("read Coop review patch: %w", err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Error struct {
				Code   string `json:"code"`
				Detail string `json:"detail"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &failure); err != nil {
			return ReviewPatchArtifact{}, &APIError{
				Status: response.StatusCode, Code: "invalid_error_response",
			}
		}
		return ReviewPatchArtifact{}, &APIError{
			Status: response.StatusCode,
			Code:   failure.Error.Code, Detail: failure.Error.Detail,
		}
	}
	if len(data) > maxReviewPatchBytes {
		return ReviewPatchArtifact{}, errors.New("Coop review patch exceeds 64 MiB")
	}
	return ReviewPatchArtifact{
		Patch:  data,
		Digest: strings.Trim(response.Header.Get("ETag"), `"`),
	}, nil
}

func (c *Client) Cancel(ctx context.Context, key, sessionID, turnID string, expectedRevision int64) (Turn, Operation, error) {
	var response turnResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/turns/"+url.PathEscape(turnID)+"/cancel", key, map[string]any{
		"expected_revision": expectedRevision,
	}, &response)
	return response.Turn, response.Operation, err
}

func (c *Client) Extend(ctx context.Context, key, sessionID string, expectedRevision int64, additionalTurns int) (Session, Operation, error) {
	var response sessionResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/budget", key, map[string]any{
		"expected_revision": expectedRevision,
		"additional_turns":  additionalTurns,
	}, &response)
	return response.Session, response.Operation, err
}

func (c *Client) Close(ctx context.Context, key, sessionID string, expectedRevision int64) (Session, Operation, error) {
	var response sessionResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/close", key, map[string]any{
		"expected_revision": expectedRevision,
	}, &response)
	return response.Session, response.Operation, err
}

func (c *Client) PlanDiscard(
	ctx context.Context,
	key string,
	sessionID string,
	expectedRevision int64,
	acceptDirty bool,
	acceptUnmerged bool,
) (DiscardPlan, Operation, error) {
	var response discardPlanResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/discard-plan", key, map[string]any{
		"expected_revision": expectedRevision,
		"accept_dirty":      acceptDirty,
		"accept_unmerged":   acceptUnmerged,
	}, &response)
	return response.Plan, response.Operation, err
}

func (c *Client) Discard(
	ctx context.Context,
	key string,
	sessionID string,
	planOperationID string,
) (Session, Operation, error) {
	var response sessionResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/discard", key, map[string]any{
		"plan_operation_id": planOperationID,
	}, &response)
	return response.Session, response.Operation, err
}

func (c *Client) Operation(ctx context.Context, id string) (Operation, error) {
	var response Operation
	err := c.get(ctx, "/v1/operations/"+url.PathEscape(id), nil, &response)
	return response, err
}

func (c *Client) get(ctx context.Context, path string, query url.Values, result any) error {
	if len(query) > 0 {
		path += "?" + query.Encode()
	}
	return c.do(ctx, http.MethodGet, path, "", nil, result)
}

func (c *Client) post(ctx context.Context, path, key string, body any, result any) error {
	if strings.TrimSpace(key) == "" {
		return errors.New("Coop idempotency key is required")
	}
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	return c.do(ctx, http.MethodPost, path, key, data, result)
}

func (c *Client) do(ctx context.Context, method, path, key string, body []byte, result any) error {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, "http://coop.local"+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Idempotency-Key", key)
	}
	response, err := c.http.Do(request)
	if err != nil {
		return &TransportError{Err: err}
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return &TransportError{Err: fmt.Errorf("read response: %w", err)}
	}
	if len(data) > maxResponseBytes {
		return errors.New("Coop response exceeds 3 MiB")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Error struct {
				Code   string `json:"code"`
				Detail string `json:"detail"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &failure); err != nil {
			return &APIError{Status: response.StatusCode, Code: "invalid_error_response"}
		}
		return &APIError{Status: response.StatusCode, Code: failure.Error.Code, Detail: failure.Error.Detail}
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(result); err != nil {
		return fmt.Errorf("decode Coop response: %w", err)
	}
	var extra any
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("Coop response contains trailing data")
	}
	return nil
}

func Retryable(err error) bool {
	if err == nil {
		return false
	}
	var apiErr *APIError
	if errors.As(err, &apiErr) {
		return apiErr.Retryable()
	}
	var transportErr *TransportError
	if errors.As(err, &transportErr) {
		return true
	}
	var netErr net.Error
	return errors.As(err, &netErr)
}
