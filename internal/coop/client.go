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
)

const maxResponseBytes = 3 << 20

type Client struct {
	socket string
	http   *http.Client
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
	ID               string    `json:"id"`
	SessionID        string    `json:"session_id"`
	Ordinal          int64     `json:"ordinal"`
	State            string    `json:"state"`
	SendState        string    `json:"send_state"`
	AssistantMessage string    `json:"assistant_message,omitempty"`
	StopReason       string    `json:"stop_reason,omitempty"`
	ErrorCode        string    `json:"error_code,omitempty"`
	ErrorDetail      string    `json:"error_detail,omitempty"`
	QueuedAt         time.Time `json:"queued_at"`
	StartedAt        time.Time `json:"started_at,omitempty"`
	FinishedAt       time.Time `json:"finished_at,omitempty"`
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
	Publishable           bool     `json:"publishable"`
	NotPublishableReasons []string `json:"not_publishable_reasons,omitempty"`
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

func (c *Client) ListSessions(ctx context.Context, limit int) ([]Session, error) {
	if limit < 1 || limit > 1000 {
		return nil, errors.New("Coop session list limit must be between 1 and 1000")
	}
	var response []Session
	err := c.get(ctx, "/v1/sessions", url.Values{"limit": {strconv.Itoa(limit)}}, &response)
	return response, err
}

func (c *Client) SubmitTurn(ctx context.Context, key, sessionID string, expectedRevision int64, prompt string) (Turn, Operation, error) {
	var response turnResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/turns", key, map[string]any{
		"expected_revision": expectedRevision,
		"prompt":            prompt,
	}, &response)
	return response.Turn, response.Operation, err
}

func (c *Client) GetTurn(ctx context.Context, sessionID, turnID string) (Turn, error) {
	var response Turn
	err := c.get(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/turns/"+url.PathEscape(turnID), nil, &response)
	return response, err
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

func (c *Client) Review(ctx context.Context, key, sessionID string, expectedRevision int64) (Review, Operation, error) {
	var response reviewResponse
	err := c.post(ctx, "/v1/sessions/"+url.PathEscape(sessionID)+"/review", key, map[string]any{
		"expected_revision": expectedRevision,
	}, &response)
	return response.Review, response.Operation, err
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
		return fmt.Errorf("call Coop: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return fmt.Errorf("read Coop response: %w", err)
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
	var netErr net.Error
	return errors.As(err, &netErr) || strings.Contains(err.Error(), "call Coop")
}
