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
	// 256 KiB, matching Coop's session.MaxPromptBytes. At the old 64 KiB cap
	// this deployment trimmed context on 100% of turns — dropping evidence,
	// related summaries, and continuity on nearly every call — and still hit
	// transport elision. The sources are bounded upstream, so the cap's job
	// is to be a transport backstop, not the working ceiling of every turn.
	maxPromptBytes  = 256 << 10
	promptTailBytes = 20 << 10
)

const promptElisionMarker = "\n\n<responder-context-elided>\nOlder bounded context was omitted to fit the Coop turn limit.\n</responder-context-elided>\n\n"

type Client struct {
	socket            string
	http              *http.Client
	asyncPollInterval time.Duration
	asyncPollWindow   time.Duration

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

// SetAsyncCreateHandoff keeps one scheduled worker from waiting until its
// stall deadline for a cold session. The operation remains durable in Coop and
// the same request key resumes polling it on the next lease.
func (c *Client) SetAsyncCreateHandoff(workerStall time.Duration) {
	if handoff := workerStall / 2; handoff > 0 && handoff < c.asyncPollWindow {
		c.asyncPollWindow = handoff
	}
}

type APIError struct {
	Status      int
	Code        string
	Detail      string
	OperationID string
}

func (e *APIError) Error() string {
	operation := ""
	if e.OperationID != "" {
		operation = " operation=" + e.OperationID
	}
	if e.Detail == "" {
		return fmt.Sprintf("Coop API %s (%d)%s", e.Code, e.Status, operation)
	}
	return fmt.Sprintf("Coop API %s (%d)%s: %s", e.Code, e.Status, operation, e.Detail)
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

// OperationPendingError hands a durable asynchronous operation back to the
// scheduler before the worker lease expires. Retrying the same request key
// resumes polling the same Coop operation.
//
// Method names what is actually pending: this string becomes the episode's
// status and its trace card, and "operation op_7a83… is still running" told
// an operator that something was queued without saying what.
type OperationPendingError struct {
	ID     string
	Method string
	Cause  error
}

func (e *OperationPendingError) Error() string {
	what := "Coop operation " + e.ID + " is still running"
	switch e.Method {
	case "CreateSession", "CreateRemoteSession":
		what = "Coop is still preparing the model session (operation " + e.ID + ")"
	case "SubmitTurn":
		what = "Coop is still starting the model turn (operation " + e.ID + ")"
	case "CloseSession":
		what = "Coop is still closing the model session (operation " + e.ID + ")"
	case "PlanDiscard", "Discard":
		what = "Coop is still cleaning up the workspace (operation " + e.ID + ")"
	default:
		if e.Method != "" {
			what = "Coop is still running " + e.Method + " (operation " + e.ID + ")"
		}
	}
	if e.Cause != nil {
		return fmt.Sprintf("%s: %v", what, e.Cause)
	}
	return what
}

func (e *OperationPendingError) Unwrap() error       { return e.Cause }
func (e *OperationPendingError) OperationID() string { return e.ID }

type operationError struct {
	id  string
	err error
}

func (e *operationError) Error() string       { return fmt.Sprintf("Coop operation %s: %v", e.id, e.err) }
func (e *operationError) Unwrap() error       { return e.err }
func (e *operationError) OperationID() string { return e.id }

func correlateOperation(id string, err error) error {
	if err == nil || id == "" {
		return err
	}
	return &operationError{id: id, err: err}
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
	PullRequest       *PullRequestBinding   `json:"pull_request,omitempty"`
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

type PullRequestBinding struct {
	Number     int    `json:"number"`
	Ref        string `json:"ref"`
	HeadCommit string `json:"head_commit"`
}

// SessionSource pins an engineering session to an authenticated pull-request
// head. Coop still owns the repository and remote through its policy; the
// caller supplies only the PR number and exact immutable head it approved.
type SessionSource struct {
	PullRequestNumber int
	HeadCommit        string
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
	Usage            Usage            `json:"usage,omitzero"`
}

// Usage is what one turn cost the provider, as Coop reported it.
//
// Coop omits the whole `usage` object when every field is zero, so an older
// Coop that predates schema v5 decodes to the same zero value as a turn no
// provider measured. Both are "not recorded", which is what Recorded reports.
//
// Cached input stays separate from the input total because Coop keeps it
// separate: every provider prices a cache read differently, and a total that
// folded them together could not be turned back into a cost.
type Usage struct {
	InputTokens       int     `json:"input_tokens,omitempty"`
	CachedInputTokens int     `json:"cached_input_tokens,omitempty"`
	OutputTokens      int     `json:"output_tokens,omitempty"`
	ReasoningTokens   int     `json:"reasoning_tokens,omitempty"`
	CostUSD           float64 `json:"cost_usd,omitempty"`
	CostRecorded      bool    `json:"cost_recorded,omitempty"`
}

// Recorded reports whether the provider gave us anything at all.
//
// Zero is a real answer for a trivial turn, so absence has to stay
// distinguishable from free: ACP does not require an adapter to report usage,
// and Responder must show "not recorded" rather than a fabricated zero when
// nobody measured the turn.
func (u Usage) Recorded() bool {
	return u.InputTokens > 0 || u.CachedInputTokens > 0 ||
		u.OutputTokens > 0 || u.ReasoningTokens > 0 || u.CostRecorded
}

func (u Usage) CostedTurns() int {
	if u.CostRecorded {
		return 1
	}
	return 0
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
	// Payload is what the event says happened. An older Coop omits it, so
	// absence has to stay readable as "this Coop does not narrate" rather than
	// as an empty turn.
	Payload json.RawMessage `json:"payload,omitempty"`
}

// Activity event types. These narrate the interior of a turn — the tool calls,
// plan revisions, reasoning, and permission decisions Coop observed — as
// against the lifecycle events that report what Coop itself decided.
const (
	EventToolStarted    = "tool.started"
	EventToolCompleted  = "tool.completed"
	EventModelPlan      = "model.plan"
	EventModelThought   = "model.thought"
	EventPermission     = "permission.decided"
	EventActivityElided = "activity.elided"
)

// IsActivity reports whether an event narrates work inside a turn.
func IsActivity(eventType string) bool {
	switch eventType {
	case EventToolStarted, EventToolCompleted, EventModelPlan,
		EventModelThought, EventPermission, EventActivityElided:
		return true
	}
	return false
}

// Activity is one narrated moment inside a turn, in the shape a caller can
// store and show. The payload fields are a union across event types: a tool
// call fills the tool fields, a thought fills Text, a plan fills Entries.
type Activity struct {
	ToolCallID string      `json:"tool_call_id,omitempty"`
	Title      string      `json:"title,omitempty"`
	Kind       string      `json:"kind,omitempty"`
	Status     string      `json:"status,omitempty"`
	Input      any         `json:"input,omitempty"`
	Text       string      `json:"text,omitempty"`
	Entries    []PlanEntry `json:"entries,omitempty"`
	Outcome    string      `json:"outcome,omitempty"`
	OptionID   string      `json:"option_id,omitempty"`
	OptionKind string      `json:"option_kind,omitempty"`
	Dropped    int         `json:"dropped,omitempty"`
	Reason     string      `json:"reason,omitempty"`
}

type PlanEntry struct {
	Content  string `json:"content"`
	Status   string `json:"status,omitempty"`
	Priority string `json:"priority,omitempty"`
}

// DecodeActivity reads an activity payload. A payload Responder cannot parse
// is not an error worth failing a poll over: the run still has to finish, and
// a missing timeline line is the whole cost.
func DecodeActivity(payload json.RawMessage) (Activity, bool) {
	if len(payload) == 0 {
		return Activity{}, false
	}
	var activity Activity
	if json.Unmarshal(payload, &activity) != nil {
		return Activity{}, false
	}
	return activity, true
}

// Label names the moment. A moment that arrived without a title still needs
// one, or a trace prints an empty row or a bare opaque identifier.
func (a Activity) Label(eventType string) string {
	if a.Title != "" {
		return a.Title
	}
	switch eventType {
	case EventToolStarted, EventToolCompleted:
		if a.Kind != "" {
			return a.Kind
		}
		if a.ToolCallID != "" {
			return a.ToolCallID
		}
		return "Tool call"
	case EventModelPlan:
		return "Plan updated"
	case EventModelThought:
		return "Reasoning"
	case EventPermission:
		return "Permission decided"
	case EventActivityElided:
		return "Activity not recorded"
	}
	return ""
}

// Detail is the part of the payload a timeline renders beyond the columns
// beside it. Storing the whole payload again under every row would duplicate
// those columns and put a tool's arguments on a page that only meant to show
// its name.
func (a Activity) Detail(eventType string) json.RawMessage {
	var detail any
	switch eventType {
	case EventToolStarted:
		if a.Input == nil {
			return nil
		}
		detail = map[string]any{"input": a.Input}
	case EventModelPlan:
		if len(a.Entries) == 0 {
			return nil
		}
		detail = map[string]any{"entries": a.Entries}
	case EventModelThought:
		if strings.TrimSpace(a.Text) == "" {
			return nil
		}
		detail = map[string]any{"text": a.Text}
	case EventPermission:
		detail = map[string]any{
			"outcome": a.Outcome, "option_id": a.OptionID, "option_kind": a.OptionKind,
		}
	case EventActivityElided:
		detail = map[string]any{"dropped": a.Dropped, "reason": a.Reason}
	default:
		return nil
	}
	encoded, err := json.Marshal(detail)
	if err != nil {
		return nil
	}
	return encoded
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
	ForkTree         string           `json:"fork_tree"`
	PullRequestTree  string           `json:"pull_request_tree,omitempty"`
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
	OperationID           string              `json:"operation_id"`
	SessionID             string              `json:"session_id"`
	SessionRevision       int64               `json:"session_revision"`
	PolicyDigest          string              `json:"policy_digest"`
	PullRequest           *PullRequestBinding `json:"pull_request,omitempty"`
	CreationBase          string              `json:"creation_base"`
	SourceHead            string              `json:"source_head"`
	SourceTree            string              `json:"source_tree"`
	ParentHead            string              `json:"parent_head"`
	ParentTree            string              `json:"parent_tree"`
	CandidateHead         string              `json:"candidate_head"`
	CandidateTree         string              `json:"candidate_tree"`
	Rebase                string              `json:"rebase"`
	Gate                  string              `json:"gate"`
	GateError             string              `json:"gate_error,omitempty"`
	PolicyFindings        []string            `json:"policy_findings,omitempty"`
	Patch                 []byte              `json:"patch,omitempty"`
	PatchTruncated        bool                `json:"patch_truncated"`
	PatchArtifactID       string              `json:"patch_artifact_id,omitempty"`
	PatchDigest           string              `json:"patch_digest,omitempty"`
	PatchBytes            int64               `json:"patch_bytes"`
	Publishable           bool                `json:"publishable"`
	NotPublishableReasons []string            `json:"not_publishable_reasons,omitempty"`
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
		socket: socket, http: &http.Client{Transport: transport, Timeout: timeout},
		asyncPollInterval: 250 * time.Millisecond, asyncPollWindow: 30 * time.Second,
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

func (c *Client) CreateSession(
	ctx context.Context,
	key, policy, externalRef string,
	sources ...SessionSource,
) (Session, Operation, error) {
	var response sessionResponse
	body := map[string]any{
		"policy": policy,
		"task":   externalRef,
	}
	if len(sources) > 1 {
		return response.Session, response.Operation, errors.New("only one Coop session source is supported")
	}
	if len(sources) == 1 {
		body["pull_request"] = map[string]any{
			"number": sources[0].PullRequestNumber, "head_commit": sources[0].HeadCommit,
		}
	}
	err := c.postPreferAsync(ctx, "/v1/sessions", key, body, &response)
	if err != nil || response.Session.ID != "" {
		return response.Session, response.Operation, err
	}
	op := response.Operation
	if op.ID == "" {
		return Session{}, Operation{}, errors.New("Coop async session response has no operation id")
	}
	ticker := time.NewTicker(c.asyncPollInterval)
	defer ticker.Stop()
	deadline := time.NewTimer(c.asyncPollWindow)
	defer deadline.Stop()
	for {
		switch op.State {
		case "succeeded":
			if op.ResourceType != "session" || op.ResourceID == "" {
				return Session{}, op, correlateOperation(op.ID, errors.New("Coop create operation has no session resource"))
			}
			sess, getErr := c.GetSession(ctx, op.ResourceID)
			return sess, op, correlateOperation(op.ID, getErr)
		case "failed", "uncertain":
			status := http.StatusConflict
			if op.ErrorCode == "internal_error" {
				status = http.StatusInternalServerError
			}
			return Session{}, op, &APIError{
				Status: status, Code: op.ErrorCode, Detail: op.ErrorDetail, OperationID: op.ID,
			}
		case "reserved", "running":
		default:
			return Session{}, op, correlateOperation(op.ID,
				fmt.Errorf("Coop create operation has unsupported state %q", op.State))
		}
		select {
		case <-ctx.Done():
			return Session{}, op, &OperationPendingError{ID: op.ID, Method: op.Method, Cause: ctx.Err()}
		case <-deadline.C:
			return Session{}, op, &OperationPendingError{ID: op.ID, Method: op.Method}
		case <-ticker.C:
		}
		pollCtx, cancel := context.WithTimeout(ctx, min(5*time.Second, c.asyncPollWindow))
		next, pollErr := c.Operation(pollCtx, op.ID)
		cancel()
		if pollErr != nil {
			return Session{}, op, &OperationPendingError{ID: op.ID, Method: op.Method, Cause: pollErr}
		}
		op = next
	}
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
	bounded, truncated := BoundPrompt(prompt)
	if truncated && c.truncated != nil {
		c.truncated(len(prompt), maxPromptBytes)
	}
	return bounded
}

// BoundPrompt applies the exact transport limit before callers freeze their
// context manifest, preserving the assignment head and contract tail.
func BoundPrompt(prompt string) (string, bool) {
	prompt = strings.ToValidUTF8(prompt, "\uFFFD")
	prompt = strings.ReplaceAll(prompt, "\x00", "\uFFFD")
	if len(prompt) <= maxPromptBytes {
		return prompt, false
	}
	tailStart := len(prompt) - promptTailBytes
	for tailStart < len(prompt) && !utf8.RuneStart(prompt[tailStart]) {
		tailStart++
	}
	headBytes := maxPromptBytes - len(promptElisionMarker) - (len(prompt) - tailStart)
	for headBytes > 0 && !utf8.ValidString(prompt[:headBytes]) {
		headBytes--
	}
	return prompt[:headBytes] + promptElisionMarker + prompt[tailStart:], true
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

// OperationByKey recovers the durable outcome of a request whose HTTP response
// may have been lost after Coop committed it. The response deliberately omits
// the key; callers already possess the exact key they are querying.
func (c *Client) OperationByKey(ctx context.Context, key string) (Operation, error) {
	if strings.TrimSpace(key) == "" {
		return Operation{}, errors.New("Coop operation idempotency key is required")
	}
	var response Operation
	err := c.get(ctx, "/v1/operations", url.Values{"key": {key}}, &response)
	return response, err
}

func (c *Client) get(ctx context.Context, path string, query url.Values, result any) error {
	if len(query) > 0 {
		path += "?" + query.Encode()
	}
	return c.do(ctx, http.MethodGet, path, "", nil, result)
}

func (c *Client) post(ctx context.Context, path, key string, body any, result any) error {
	return c.postWithHeaders(ctx, path, key, body, nil, result)
}

func (c *Client) postPreferAsync(ctx context.Context, path, key string, body any, result any) error {
	return c.postWithHeaders(ctx, path, key, body, http.Header{"Prefer": {"respond-async"}}, result)
}

func (c *Client) postWithHeaders(
	ctx context.Context,
	path string,
	key string,
	body any,
	headers http.Header,
	result any,
) error {
	if strings.TrimSpace(key) == "" {
		return errors.New("Coop idempotency key is required")
	}
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	return c.doWithHeaders(ctx, http.MethodPost, path, key, data, headers, result)
}

func (c *Client) do(ctx context.Context, method, path, key string, body []byte, result any) error {
	return c.doWithHeaders(ctx, method, path, key, body, nil, result)
}

func (c *Client) doWithHeaders(
	ctx context.Context,
	method string,
	path string,
	key string,
	body []byte,
	headers http.Header,
	result any,
) error {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, "http://coop.local"+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	for name, values := range headers {
		for _, value := range values {
			request.Header.Add(name, value)
		}
	}
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
				Code        string `json:"code"`
				Detail      string `json:"detail"`
				OperationID string `json:"operation_id"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &failure); err != nil {
			return &APIError{Status: response.StatusCode, Code: "invalid_error_response"}
		}
		return &APIError{Status: response.StatusCode, Code: failure.Error.Code, Detail: failure.Error.Detail, OperationID: failure.Error.OperationID}
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
	var pending *OperationPendingError
	if errors.As(err, &pending) {
		return true
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
