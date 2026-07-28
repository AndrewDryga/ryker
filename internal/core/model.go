package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

type SignalStatus string

const (
	SignalFiring   SignalStatus = "firing"
	SignalResolved SignalStatus = "resolved"
)

type IncidentStatus string

const (
	IncidentActive     IncidentStatus = "active"
	IncidentMonitoring IncidentStatus = "monitoring"
	IncidentResolved   IncidentStatus = "resolved"
	IncidentClosed     IncidentStatus = "closed"
)

type WorkflowState string

const (
	WorkflowProvisioningChannel WorkflowState = "provisioning_channel"
	WorkflowProvisioningSession WorkflowState = "provisioning_session"
	WorkflowHolding             WorkflowState = "holding"
	WorkflowInvestigating       WorkflowState = "investigating"
	WorkflowParked              WorkflowState = "parked"
	WorkflowBlocked             WorkflowState = "blocked"
	WorkflowClosed              WorkflowState = "closed"
)

type ChannelState string

const (
	ChannelPending     ChannelState = "pending"
	ChannelActive      ChannelState = "active"
	ChannelArchived    ChannelState = "archived"
	ChannelDeleted     ChannelState = "deleted"
	ChannelUnreachable ChannelState = "unreachable"
)

type Signal struct {
	Route            string            `json:"route"`
	SourceID         string            `json:"source_id"`
	SourceIncidentID string            `json:"source_incident_id,omitempty"`
	EventID          string            `json:"event_id"`
	Repository       string            `json:"repository"`
	CorrelationKey   string            `json:"correlation_key"`
	Status           SignalStatus      `json:"status"`
	Title            string            `json:"title"`
	Severity         string            `json:"severity,omitempty"`
	Summary          string            `json:"summary,omitempty"`
	SourceURL        string            `json:"source_url,omitempty"`
	Labels           map[string]string `json:"labels,omitempty"`
	Annotations      map[string]string `json:"annotations,omitempty"`
	StartsAt         time.Time         `json:"starts_at,omitempty"`
	EndsAt           time.Time         `json:"ends_at,omitempty"`
	ReceivedAt       time.Time         `json:"received_at"`
	ResolveAfter     time.Duration     `json:"-"`
}

type Incident struct {
	ID                    string
	Route                 string
	Repository            string
	CorrelationKey        string
	SourceIncidentID      string
	WorkKind              WorkKind
	WorkScope             WorkScope
	OriginChannelID       string
	OriginThreadTS        string
	Title                 string
	Severity              string
	Status                IncidentStatus
	Workflow              WorkflowState
	SignalCount           int
	FiringCount           int
	ChannelID             string
	ChannelName           string
	ChannelState          ChannelState
	ChannelStateChangedAt time.Time
	ChannelCheckedAt      time.Time
	RootTS                string
	CoopSessionID         string
	CoopForkName          string
	CoopRevision          int64
	CoopEventSequence     int64
	ActiveTurnID          string
	InitialTurnQueued     bool
	CardVersion           int64
	CardRenderedVersion   int64
	LastError             string
	CreatedAt             time.Time
	UpdatedAt             time.Time
	LastFiringAt          time.Time
	ResolveDueAt          time.Time
	ResolvedAt            time.Time
	ClosedAt              time.Time
}

func (i Incident) ChannelWritable() bool {
	return i.ChannelState == "" || i.ChannelState == ChannelActive
}

func (i Incident) IsEngineeringTask() bool {
	return i.WorkKind == WorkKindEngineeringTask ||
		(i.WorkKind == "" && i.Route == "manual" && strings.HasPrefix(i.SourceIncidentID, "task:"))
}

func (i Incident) IsThreadScoped() bool {
	return i.WorkScope == WorkScopeThread ||
		(i.WorkScope == "" && i.IsEngineeringTask() && i.OriginThreadTS != "")
}

func (i Incident) ConversationThreadTS() string {
	if i.IsThreadScoped() && i.OriginThreadTS != "" {
		return i.OriginThreadTS
	}
	return i.RootTS
}

type WorkKind string

const (
	WorkKindIncident        WorkKind = "incident"
	WorkKindEngineeringTask WorkKind = "engineering_task"
)

type WorkScope string

const (
	WorkScopeRoom   WorkScope = "room"
	WorkScopeThread WorkScope = "thread"
)

type WebhookEvent struct {
	ID            string
	Route         string
	DedupeKey     string
	BodyDigest    string
	Signals       []Signal
	IncidentIDs   []string
	Applied       bool
	State         string
	Attempts      int
	NextAttemptAt time.Time
	LastError     string
	ReceivedAt    time.Time
}

type SlackInput struct {
	ID          string
	EnvelopeID  string
	EventID     string
	Kind        string
	TeamID      string
	ChannelID   string
	ThreadTS    string
	MessageTS   string
	UserID      string
	Text        string
	ActionID    string
	ActionValue string
	Frozen      []byte
	State       string
	Attempts    int
	ReceivedAt  time.Time
}

type OutboxMessage struct {
	ID            string
	IncidentID    string
	Kind          string
	ChannelID     string
	ThreadTS      string
	MessageTS     string
	Body          []byte
	State         string
	Attempts      int
	NextAttemptAt time.Time
	LastError     string
	CreatedAt     time.Time
}

type TurnSubmission struct {
	ID               string
	IncidentID       string
	SourceKind       string
	SourceID         string
	UserID           string
	Prompt           string
	IdempotencyKey   string
	ExpectedRevision int64
	CoopTurnID       string
	State            string
	Attempts         int
	NextAttemptAt    time.Time
	LastError        string
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

type AuditEvent struct {
	ID         string
	IncidentID string
	Kind       string
	ActorID    string
	ObjectID   string
	Outcome    string
	Detail     string
	CreatedAt  time.Time
}

type Evidence struct {
	ID          string            `json:"id,omitempty"`
	IncidentID  string            `json:"incident_id,omitempty"`
	ChannelID   string            `json:"channel_id,omitempty"`
	SourceInput string            `json:"source_input,omitempty"`
	Claim       string            `json:"claim"`
	Observation string            `json:"observation"`
	SourceType  string            `json:"source_type"`
	SourceName  string            `json:"source_name"`
	SourceURL   string            `json:"source_url,omitempty"`
	Target      string            `json:"target,omitempty"`
	Freshness   string            `json:"freshness,omitempty"`
	Confidence  string            `json:"confidence,omitempty"`
	ObservedAt  time.Time         `json:"observed_at,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
	CreatedAt   time.Time         `json:"created_at,omitempty"`
}

type Coverage struct {
	ID          string    `json:"id,omitempty"`
	IncidentID  string    `json:"incident_id,omitempty"`
	ChannelID   string    `json:"channel_id,omitempty"`
	SourceInput string    `json:"source_input,omitempty"`
	Layer       string    `json:"layer"`
	Status      string    `json:"status"`
	Source      string    `json:"source,omitempty"`
	Detail      string    `json:"detail,omitempty"`
	ObservedAt  time.Time `json:"observed_at,omitempty"`
	CreatedAt   time.Time `json:"created_at,omitempty"`
}

type AgentMemory struct {
	Goal                string   `json:"goal,omitempty"`
	Topology            []string `json:"topology,omitempty"`
	Decisions           []string `json:"decisions,omitempty"`
	UnresolvedQuestions []string `json:"unresolved_questions,omitempty"`
	EvidenceRefs        []string `json:"evidence_refs,omitempty"`
}

func (m *AgentMemory) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for name := range fields {
		switch name {
		case "goal", "topology", "decisions", "unresolved_questions", "evidence_refs":
		default:
			return fmt.Errorf("json: unknown field %q", name)
		}
	}
	if value := fields["goal"]; len(value) != 0 {
		if err := json.Unmarshal(value, &m.Goal); err != nil {
			return fmt.Errorf("decode memory goal: %w", err)
		}
	}
	var err error
	if m.Topology, err = decodeMemoryStrings(fields["topology"]); err != nil {
		return fmt.Errorf("decode memory topology: %w", err)
	}
	if m.Decisions, err = decodeMemoryStrings(fields["decisions"]); err != nil {
		return fmt.Errorf("decode memory decisions: %w", err)
	}
	if m.UnresolvedQuestions, err = decodeMemoryStrings(fields["unresolved_questions"]); err != nil {
		return fmt.Errorf("decode memory unresolved questions: %w", err)
	}
	if m.EvidenceRefs, err = decodeMemoryStrings(fields["evidence_refs"]); err != nil {
		return fmt.Errorf("decode memory evidence refs: %w", err)
	}
	return nil
}

func decodeMemoryStrings(data json.RawMessage) ([]string, error) {
	if len(data) == 0 || string(data) == "null" {
		return nil, nil
	}
	var values []string
	if err := json.Unmarshal(data, &values); err == nil {
		return values, nil
	}
	var value string
	if err := json.Unmarshal(data, &value); err == nil {
		return []string{value}, nil
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil {
		return nil, errors.New("expected a string, string array, or object")
	}
	keys := make([]string, 0, len(object))
	for key := range object {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	values = make([]string, 0, len(keys))
	for _, key := range keys {
		var item string
		if err := json.Unmarshal(object[key], &item); err != nil {
			item = string(object[key])
		}
		values = append(values, key+": "+item)
	}
	return values, nil
}

type ChannelMemory struct {
	ChannelID       string
	Repository      string
	SessionID       string
	SessionRevision int64
	Generation      int
	TurnCount       int
	State           AgentMemory
	SessionStarted  time.Time
	RotatedAt       time.Time
	UpdatedAt       time.Time
}

type TimelineEvent struct {
	ID          string
	IncidentID  string
	ChannelID   string
	Kind        string
	ActorID     string
	Title       string
	Detail      string
	EvidenceIDs []string
	CreatedAt   time.Time
}

type ActionProposal struct {
	ID            string            `json:"id,omitempty"`
	IncidentID    string            `json:"incident_id,omitempty"`
	ChannelID     string            `json:"channel_id,omitempty"`
	SourceInput   string            `json:"source_input,omitempty"`
	ActionName    string            `json:"action_name"`
	Title         string            `json:"title"`
	Summary       string            `json:"summary"`
	Target        string            `json:"target"`
	Parameters    map[string]string `json:"parameters,omitempty"`
	BlastRadius   string            `json:"blast_radius"`
	Rollback      string            `json:"rollback"`
	Verification  string            `json:"verification"`
	Authority     string            `json:"authority"`
	Risk          string            `json:"risk"`
	Status        string            `json:"status,omitempty"`
	Required      int               `json:"required_approvals,omitempty"`
	ApprovalCount int               `json:"approval_count,omitempty"`
	RequestedBy   string            `json:"requested_by,omitempty"`
	ExecutionTurn string            `json:"execution_turn,omitempty"`
	Result        string            `json:"result,omitempty"`
	ExpiresAt     time.Time         `json:"expires_at,omitempty"`
	CreatedAt     time.Time         `json:"created_at,omitempty"`
	UpdatedAt     time.Time         `json:"updated_at,omitempty"`
}

type EvaluationDecision struct {
	ID          string
	ChannelID   string
	SourceInput string
	Mode        string
	Action      string
	Reason      string
	Evidence    int
	Coverage    int
	CreatedAt   time.Time
}

type Publication struct {
	IncidentID    string
	Repository    string
	BaseBranch    string
	HeadBranch    string
	ParentHead    string
	CandidateTree string
	CommitSHA     string
	RemoteSHA     string
	PRNumber      int
	PRURL         string
	State         string
	LastError     string
	CreatedAt     time.Time
	UpdatedAt     time.Time
	PublishedAt   time.Time
}

func (p Publication) Published() bool {
	return p.State == "published" && p.PRNumber > 0 && p.PRURL != ""
}

type CoopCleanup struct {
	SessionID       string
	IncidentID      string
	Reason          string
	AllowUnmerged   bool
	State           string
	PlanOperationID string
	Attempts        int
	EligibleAt      time.Time
	NextAttemptAt   time.Time
	LastError       string
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

type PruneResult struct {
	SlackInputs         int64
	WebhookEvents       int64
	OutboxMessages      int64
	TurnSubmissions     int64
	EvaluationDecisions int64
	ChannelIntelligence int64
	ActionProposals     int64
	ClosedIncidents     int64
	AuditEvents         int64
}

func (r PruneResult) Total() int64 {
	return r.SlackInputs + r.WebhookEvents + r.OutboxMessages + r.TurnSubmissions +
		r.EvaluationDecisions + r.ChannelIntelligence + r.ActionProposals +
		r.ClosedIncidents + r.AuditEvents
}
