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
	Attachments []SlackAttachment
	Reactions   []SlackReaction
	ActionID    string
	ActionValue string
	Frozen      []byte
	State       string
	Attempts    int
	Failures    int
	ReceivedAt  time.Time
}

// SlackReaction is bounded conversation context returned by Slack. Reaction events use the
// existing ActionID and ActionValue fields so they remain durable without storing a second copy.
type SlackReaction struct {
	Name    string   `json:"name"`
	Count   int      `json:"count"`
	UserIDs []string `json:"user_ids,omitempty"`
}

// SlackAttachment is durable Slack-owned metadata. URLPrivate is used only by the ordered input
// worker for an authenticated download and is never included in model prompts or Slack output.
type SlackAttachment struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	MediaType  string `json:"media_type"`
	Size       int64  `json:"size"`
	URLPrivate string `json:"url_private"`
}

type ChannelConfiguration struct {
	ChannelID        string   `json:"channel_id"`
	Participation    string   `json:"participation"`
	Repository       string   `json:"repository"`
	AlertPolicy      string   `json:"alert_policy"`
	InviteUsers      []string `json:"invite_users,omitempty"`
	InviteUserGroups []string `json:"invite_user_groups,omitempty"`
	ActorID          string   `json:"actor_id"`
	Revision         int      `json:"revision"`
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

type ConfigurationSession struct {
	ID               string
	TeamID           string
	ChannelID        string
	ThreadTS         string
	ResponseThreadTS string
	ThreadRoots      []string
	Initiator        string
	Step             string
	Status           string
	Draft            ChannelConfiguration
	Revision         int
	ExpiresAt        time.Time
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

type SlackDelivery struct {
	ID            string
	IncidentID    string
	Operation     string
	Kind          string
	ChannelID     string
	ThreadTS      string
	MessageTS     string
	Body          []byte
	Status        string
	Steps         []string
	CoalesceKey   string
	CardVersion   int64
	State         string
	Attempts      int
	NextAttemptAt time.Time
	LastError     string
	CreatedAt     time.Time
}

type GeneratedVisual struct {
	Artifact string `json:"artifact"`
	Title    string `json:"title"`
	AltText  string `json:"alt_text"`
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
	ChannelPurpose      string   `json:"channel_purpose,omitempty"`
	SituationSummary    string   `json:"situation_summary,omitempty"`
	ActiveTopics        []string `json:"active_topics,omitempty"`
	OpenLoops           []string `json:"open_loops,omitempty"`
	Topology            []string `json:"topology,omitempty"`
	Decisions           []string `json:"decisions,omitempty"`
	UnresolvedQuestions []string `json:"unresolved_questions,omitempty"`
	EvidenceRefs        []string `json:"evidence_refs,omitempty"`
}

type MemoryOffer struct {
	Scope          string `json:"scope"`
	Repository     string `json:"repository,omitempty"`
	Subject        string `json:"subject"`
	Predicate      string `json:"predicate"`
	Value          string `json:"value"`
	Visibility     string `json:"visibility"`
	ExpiresIn      string `json:"expires_in,omitempty"`
	SourceRevision string `json:"source_revision,omitempty"`
}

type MemoryEntry struct {
	ID             string    `json:"id"`
	ScopeKind      string    `json:"scope_kind"`
	ScopeKey       string    `json:"scope_key"`
	SubjectKey     string    `json:"subject_key"`
	Predicate      string    `json:"predicate"`
	Value          string    `json:"value"`
	ValueHash      string    `json:"value_hash"`
	SourceRef      string    `json:"source_ref"`
	SourceRevision string    `json:"source_revision,omitempty"`
	ActorID        string    `json:"actor_id"`
	VisibilityKind string    `json:"visibility_kind"`
	VisibilityID   string    `json:"visibility_id"`
	ExpiresAt      time.Time `json:"expires_at"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type PreferenceOffer struct {
	Scope      string `json:"scope"`
	Repository string `json:"repository,omitempty"`
	Name       string `json:"name"`
	Value      string `json:"value"`
	ExpiresIn  string `json:"expires_in,omitempty"`
}

type ResponderPreference struct {
	ID        string
	ScopeKind string
	ScopeKey  string
	Name      string
	Value     string
	Enabled   bool
	SourceRef string
	ActorID   string
	ExpiresAt time.Time
	CreatedAt time.Time
	UpdatedAt time.Time
}

type RuleOffer struct {
	Scope      string `json:"scope"`
	Repository string `json:"repository"`
	Trigger    string `json:"trigger"`
	Action     string `json:"action"`
	SourceKind string `json:"source_kind,omitempty"`
	ExpiresIn  string `json:"expires_in,omitempty"`
}

type StandingRule struct {
	ID            string
	ChannelID     string
	Repository    string
	Trigger       string
	Action        string
	SourceKind    string
	Enabled       bool
	SourceRef     string
	ActorID       string
	TriggerCount  int
	LastTriggered time.Time
	ExpiresAt     time.Time
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

func (m *AgentMemory) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for name := range fields {
		switch name {
		case "goal", "channel_purpose", "situation_summary", "active_topics",
			"open_loops", "topology", "decisions", "unresolved_questions",
			"evidence_refs":
		default:
			return fmt.Errorf("json: unknown field %q", name)
		}
	}
	if value := fields["goal"]; len(value) != 0 {
		if err := json.Unmarshal(value, &m.Goal); err != nil {
			return fmt.Errorf("decode memory goal: %w", err)
		}
	}
	if value := fields["channel_purpose"]; len(value) != 0 {
		if err := json.Unmarshal(value, &m.ChannelPurpose); err != nil {
			return fmt.Errorf("decode memory channel purpose: %w", err)
		}
	}
	if value := fields["situation_summary"]; len(value) != 0 {
		if err := json.Unmarshal(value, &m.SituationSummary); err != nil {
			return fmt.Errorf("decode memory situation summary: %w", err)
		}
	}
	var err error
	if m.ActiveTopics, err = decodeMemoryStrings(fields["active_topics"]); err != nil {
		return fmt.Errorf("decode memory active topics: %w", err)
	}
	if m.OpenLoops, err = decodeMemoryStrings(fields["open_loops"]); err != nil {
		return fmt.Errorf("decode memory open loops: %w", err)
	}
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
	var value string
	if err := json.Unmarshal(data, &value); err == nil {
		return []string{value}, nil
	}
	var items []json.RawMessage
	if err := json.Unmarshal(data, &items); err == nil {
		var values []string
		for _, item := range items {
			normalized, err := decodeMemoryStrings(item)
			if err != nil {
				return nil, err
			}
			if len(normalized) == 0 {
				continue
			}
			if len(normalized) == 1 {
				values = append(values, normalized[0])
				continue
			}
			values = append(values, strings.Join(normalized, "; "))
		}
		return values, nil
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err == nil {
		keys := make([]string, 0, len(object))
		for key := range object {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		values := make([]string, 0, len(keys))
		for _, key := range keys {
			var item string
			if err := json.Unmarshal(object[key], &item); err != nil {
				item = string(object[key])
			}
			values = append(values, key+": "+item)
		}
		return values, nil
	}
	var scalar any
	if err := json.Unmarshal(data, &scalar); err != nil {
		return nil, errors.New("expected a JSON memory value")
	}
	return []string{string(data)}, nil
}

type ChannelMemory struct {
	ChannelID         string
	Repository        string
	SessionID         string
	SessionRevision   int64
	CoopEventSequence int64
	Generation        int
	TurnCount         int
	State             AgentMemory
	SessionStarted    time.Time
	RotatedAt         time.Time
	UpdatedAt         time.Time
}

type ConversationMemory struct {
	ChannelID   string
	ChannelName string
	ThreadTS    string
	Repository  string
	LastMessage string
	State       AgentMemory
	UpdatedAt   time.Time
}

type ConversationSession struct {
	ChannelID         string
	Repository        string
	Policy            string
	SessionID         string
	SessionRevision   int64
	CoopEventSequence int64
	Generation        int
	TurnCount         int
	SessionStarted    time.Time
	RotatedAt         time.Time
	UpdatedAt         time.Time
}

type ConversationRoute struct {
	ChannelID        string
	UserID           string
	ActiveThreadTS   string
	PreviousThreadTS string
	Explicit         bool
	UpdatedAt        time.Time
}

type AgentRunMode string

const (
	AgentRunTriage          AgentRunMode = "triage"
	AgentRunIncident        AgentRunMode = "incident"
	AgentRunEngineeringTask AgentRunMode = "engineering_task"
)

type AgentRunState string

const (
	AgentRunPending    AgentRunState = "pending"
	AgentRunPreparing  AgentRunState = "preparing"
	AgentRunRunning    AgentRunState = "running"
	AgentRunApplying   AgentRunState = "applying"
	AgentRunFinalizing AgentRunState = "finalizing"
	AgentRunCompleted  AgentRunState = "completed"
	AgentRunFailed     AgentRunState = "failed"
	AgentRunCancelled  AgentRunState = "cancelled"
	AgentRunSuperseded AgentRunState = "superseded"
)

type AgentRun struct {
	ID                string
	Mode              AgentRunMode
	IncidentID        string
	ChannelID         string
	ThreadTS          string
	ConversationKey   string
	SourceKind        string
	SourceID          string
	UserID            string
	Repository        string
	Prompt            string
	IdempotencyKey    string
	SessionID         string
	SessionGeneration int
	ExpectedRevision  int64
	CoopTurnID        string
	CoopEventSequence int64
	Context           []byte
	Result            []byte
	TerminalState     string
	State             AgentRunState
	Failures          int
	NextAttemptAt     time.Time
	LastError         string
	CreatedAt         time.Time
	UpdatedAt         time.Time
	StartedAt         time.Time
	CompletedAt       time.Time
	CommitmentTitle   string
}

type CommitmentState string

const (
	CommitmentQueued    CommitmentState = "queued"
	CommitmentWorking   CommitmentState = "working"
	CommitmentFinishing CommitmentState = "finishing"
	CommitmentDone      CommitmentState = "done"
	CommitmentBlocked   CommitmentState = "blocked"
	CommitmentCancelled CommitmentState = "cancelled"
)

// Commitment is the operator-facing projection of durable agent work. The
// underlying AgentRun remains the execution record; this projection answers
// what Emisar owes the team without exposing model or Coop internals.
type Commitment struct {
	ID          string
	AgentRunID  string
	ChannelID   string
	ThreadTS    string
	UserID      string
	Repository  string
	Title       string
	State       CommitmentState
	Status      string
	NextAction  string
	SourceKind  string
	SourceID    string
	CreatedAt   time.Time
	UpdatedAt   time.Time
	CompletedAt time.Time
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

type EmisarApproval struct {
	RequestID          string    `json:"request_id"`
	IncidentID         string    `json:"incident_id,omitempty"`
	ChannelID          string    `json:"channel_id,omitempty"`
	SourceInput        string    `json:"source_input,omitempty"`
	RequestedBy        string    `json:"requested_by,omitempty"`
	DeliveryID         string    `json:"delivery_id,omitempty"`
	MessageTS          string    `json:"message_ts,omitempty"`
	RunID              string    `json:"run_id"`
	OperationID        string    `json:"operation_id"`
	ActionID           string    `json:"action_id"`
	PackRef            string    `json:"pack_ref"`
	RunnerRef          string    `json:"runner_ref"`
	Status             string    `json:"status"`
	ApprovalURL        string    `json:"approval_url"`
	RunURL             string    `json:"run_url,omitempty"`
	LastError          string    `json:"last_error,omitempty"`
	FailureCount       int       `json:"failure_count,omitempty"`
	ContinuationQueued bool      `json:"continuation_queued,omitempty"`
	NextCheckAt        time.Time `json:"next_check_at,omitempty"`
	ExpiresAt          time.Time `json:"expires_at"`
	TerminalAt         time.Time `json:"terminal_at,omitempty"`
	CreatedAt          time.Time `json:"created_at,omitempty"`
	UpdatedAt          time.Time `json:"updated_at,omitempty"`
}

type EvaluationDecision struct {
	ID          string
	ChannelID   string
	ThreadTS    string
	MessageTS   string
	Repository  string
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
	SlackInputs           int64
	WebhookEvents         int64
	SlackDeliveries       int64
	AgentRuns             int64
	EvaluationDecisions   int64
	ChannelIntelligence   int64
	ConversationMemories  int64
	MemoryEntries         int64
	Preferences           int64
	StandingRules         int64
	StandingRuleRuns      int64
	ActionProposals       int64
	EmisarApprovals       int64
	ConfigurationSessions int64
	ClosedIncidents       int64
	AuditEvents           int64
}

func (r PruneResult) Total() int64 {
	return r.SlackInputs + r.WebhookEvents + r.SlackDeliveries + r.AgentRuns +
		r.EvaluationDecisions + r.ChannelIntelligence + r.ConversationMemories +
		r.MemoryEntries + r.ActionProposals + r.Preferences + r.StandingRules +
		r.StandingRuleRuns + r.EmisarApprovals + r.ConfigurationSessions +
		r.ClosedIncidents + r.AuditEvents
}
