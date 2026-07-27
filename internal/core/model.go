package core

import "time"

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
	ID                  string
	Route               string
	Repository          string
	CorrelationKey      string
	SourceIncidentID    string
	Title               string
	Severity            string
	Status              IncidentStatus
	Workflow            WorkflowState
	SignalCount         int
	FiringCount         int
	ChannelID           string
	ChannelName         string
	RootTS              string
	CoopSessionID       string
	CoopForkName        string
	CoopRevision        int64
	CoopEventSequence   int64
	ActiveTurnID        string
	InitialTurnQueued   bool
	CardVersion         int64
	CardRenderedVersion int64
	LastError           string
	CreatedAt           time.Time
	UpdatedAt           time.Time
	LastFiringAt        time.Time
	ResolveDueAt        time.Time
	ResolvedAt          time.Time
	ClosedAt            time.Time
}

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
