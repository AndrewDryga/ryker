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
	WorkflowClosing             WorkflowState = "closing"
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
	TaskPullRequest       *PullRequestTarget
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
	LatestUpdate          string
	LatestUpdateRunID     string
	LatestUpdateRunKey    string
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
	ID        string
	TeamID    string
	ChannelID string
	ThreadTS  string
	// CardTS is the one message this session owns. Every question,
	// confirmation, receipt and cancellation edits it, so a setup costs the
	// channel one message rather than one per step. ResponseThreadTS is where
	// that card lives — the empty string for the channel itself — and
	// ThreadRoots is the wider set of conversations whose replies still count
	// as answers, which stays larger than one whenever a setup has moved.
	CardTS           string
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
	ID                          string
	IncidentID                  string
	EpisodeID                   string
	AgentRunID                  string
	AgentRunKey                 string
	SourceInputID               string
	ExpectedEpisodeRevision     int
	ExpectedDestinationRevision int
	Operation                   string
	Kind                        string
	ChannelID                   string
	ThreadTS                    string
	MessageTS                   string
	Body                        []byte
	Status                      string
	Steps                       []string
	CoalesceKey                 string
	CardVersion                 int64
	// ResponseRoot marks the delivery that owns one logical Responder reply.
	// Slack returns the thread root only after this delivery succeeds; for a
	// visual-only bundle this is the first file, not the last delivery.
	ResponseRoot  bool
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
	// CompleteDetail is reserved for bounded, host-generated structured facts
	// whose syntax would be corrupted by the ordinary error-text limit.
	CompleteDetail bool
	CreatedAt      time.Time
}

type Evidence struct {
	ID           string            `json:"id,omitempty"`
	IncidentID   string            `json:"incident_id,omitempty"`
	ChannelID    string            `json:"channel_id,omitempty"`
	SourceInput  string            `json:"source_input,omitempty"`
	ClaimID      string            `json:"claim_id,omitempty"`
	Claim        string            `json:"claim"`
	Observation  string            `json:"observation"`
	Relation     string            `json:"relation,omitempty"`
	HealthEffect string            `json:"health_effect,omitempty"`
	SourceType   string            `json:"source_type"`
	SourceID     string            `json:"source_id,omitempty"`
	SourceName   string            `json:"source_name"`
	SourceURL    string            `json:"source_url,omitempty"`
	Target       string            `json:"target,omitempty"`
	ScopeNote    string            `json:"scope_note,omitempty"`
	Freshness    string            `json:"freshness,omitempty"`
	Confidence   string            `json:"confidence,omitempty"`
	ObservedAt   time.Time         `json:"observed_at,omitempty"`
	ValidUntil   time.Time         `json:"valid_until,omitempty"`
	Dimensions   map[string]string `json:"dimensions,omitempty"`
	Metadata     map[string]string `json:"metadata,omitempty"`
	CreatedAt    time.Time         `json:"created_at,omitempty"`
}

// confidenceBand reads a confidence written as a band or as a number.
//
// Evidence confidence is high, medium or low. The attention assessment beside
// it in the same result uses an integer from one to three, and models borrow
// that scale here — twelve results in two days were discarded whole for it,
// each costing a turn to be told the same thing again. A number on the scale
// the host itself defines is not ambiguous enough to be worth refusing.
func confidenceBand(raw json.RawMessage) (string, error) {
	text := strings.TrimSpace(string(raw))
	if text == "" || text == "null" {
		return "", nil
	}
	var band string
	if err := json.Unmarshal(raw, &band); err == nil {
		return band, nil
	}
	var number float64
	if err := json.Unmarshal(raw, &number); err != nil {
		return "", fmt.Errorf("evidence confidence must be high, medium, or low: %w", err)
	}
	// A decimal is a probability; a whole number is the one-to-three band used
	// everywhere else in the result.
	if strings.Contains(text, ".") && number <= 1 {
		number *= 3
	}
	switch {
	case number >= 2.5:
		return "high", nil
	case number >= 1.5:
		return "medium", nil
	default:
		return "low", nil
	}
}

// UnmarshalJSON accepts scalar dimension values and normalizes them to their
// lossless textual form. Models commonly emit counts and boolean scope axes as
// JSON numbers or booleans; rejecting those values would not improve evidence
// integrity because dimensions are labels rather than measurements.
func (item *Evidence) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	allowed := map[string]struct{}{
		"id": {}, "incident_id": {}, "channel_id": {}, "source_input": {},
		"claim_id": {}, "claim": {}, "observation": {}, "relation": {}, "health_effect": {},
		"source_type": {}, "source_id": {}, "source_name": {}, "source_url": {},
		"source": {}, "source_ref": {}, "source_time": {},
		"summary": {}, "statement": {},
		"target": {}, "scope_note": {}, "freshness": {}, "confidence": {},
		"observed_at": {}, "valid_until": {}, "dimensions": {}, "metadata": {},
		"created_at": {},
	}
	for key := range fields {
		if _, ok := allowed[key]; !ok {
			return fmt.Errorf("unknown evidence field %q", key)
		}
	}
	*item = Evidence{}
	type evidenceAlias Evidence
	wire := struct {
		*evidenceAlias
		Dimensions map[string]json.RawMessage `json:"dimensions,omitempty"`
		Source     string                     `json:"source,omitempty"`
		SourceRef  string                     `json:"source_ref,omitempty"`
		SourceTime time.Time                  `json:"source_time,omitempty"`
		Confidence json.RawMessage            `json:"confidence,omitempty"`
		Summary    string                     `json:"summary,omitempty"`
		Statement  string                     `json:"statement,omitempty"`
	}{evidenceAlias: (*evidenceAlias)(item)}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if confidence, err := confidenceBand(wire.Confidence); err != nil {
		return err
	} else if confidence != "" {
		item.Confidence = confidence
	}
	// An observation under another name. The whole record was being thrown away
	// over the label on the field carrying the finding, which is the one part of
	// it nothing else can supply.
	if item.Observation == "" {
		item.Observation = FirstNonempty(wire.Summary, wire.Statement)
	}
	if item.SourceName == "" {
		item.SourceName = wire.Source
	}
	if item.SourceType == "" && wire.Source != "" {
		switch strings.ToLower(wire.Source) {
		case "repository", "emisar", "monitoring", "slack", "other":
			item.SourceType = strings.ToLower(wire.Source)
		default:
			item.SourceType = "other"
		}
	}
	if wire.SourceRef != "" && item.SourceURL == "" && item.SourceID == "" {
		if strings.HasPrefix(wire.SourceRef, "https://") || strings.HasPrefix(wire.SourceRef, "http://") {
			item.SourceURL = wire.SourceRef
		} else {
			item.SourceID = wire.SourceRef
		}
	}
	if item.ObservedAt.IsZero() {
		item.ObservedAt = wire.SourceTime
	}
	if wire.Dimensions == nil {
		return nil
	}
	item.Dimensions = make(map[string]string, len(wire.Dimensions))
	for key, raw := range wire.Dimensions {
		var value string
		if err := json.Unmarshal(raw, &value); err == nil {
			item.Dimensions[key] = value
			continue
		}
		text := strings.TrimSpace(string(raw))
		if text == "true" || text == "false" || json.Valid(raw) && jsonScalarNumber(text) {
			item.Dimensions[key] = text
			continue
		}
		return fmt.Errorf("evidence dimension %q must be a string, number, or boolean", key)
	}
	return nil
}

func jsonScalarNumber(value string) bool {
	var number json.Number
	return json.Unmarshal([]byte(value), &number) == nil && number.String() == value
}

type Coverage struct {
	ID          string    `json:"id,omitempty"`
	IncidentID  string    `json:"incident_id,omitempty"`
	ChannelID   string    `json:"channel_id,omitempty"`
	SourceInput string    `json:"source_input,omitempty"`
	Layer       string    `json:"layer"`
	ClaimIDs    []string  `json:"claim_ids,omitempty"`
	Status      string    `json:"status"`
	Source      string    `json:"source,omitempty"`
	Detail      string    `json:"detail,omitempty"`
	ObservedAt  time.Time `json:"observed_at,omitempty"`
	CreatedAt   time.Time `json:"created_at,omitempty"`
}

type ClaimAssessment struct {
	ID               string    `json:"id,omitempty"`
	EpisodeID        string    `json:"episode_id,omitempty"`
	ClaimID          string    `json:"claim_id"`
	Status           string    `json:"status"`
	Confidence       string    `json:"confidence,omitempty"`
	EvidenceIDs      []string  `json:"evidence_ids,omitempty"`
	ContradictionIDs []string  `json:"contradiction_ids,omitempty"`
	Detail           string    `json:"detail,omitempty"`
	UpdatedAt        time.Time `json:"updated_at,omitempty"`
}

type AgentMemory struct {
	Goal                string          `json:"goal,omitempty"`
	ChannelPurpose      string          `json:"channel_purpose,omitempty"`
	SituationSummary    string          `json:"situation_summary,omitempty"`
	ActiveTopics        []string        `json:"active_topics,omitempty"`
	OpenLoops           []string        `json:"open_loops,omitempty"`
	Topology            []string        `json:"topology,omitempty"`
	Decisions           []string        `json:"decisions,omitempty"`
	UnresolvedQuestions []string        `json:"unresolved_questions,omitempty"`
	EvidenceRefs        []string        `json:"evidence_refs,omitempty"`
	Knowledge           []KnowledgeItem `json:"knowledge,omitempty"`
}

// WithoutThreadScope drops what belongs to a piece of work rather than to the
// place the work happened.
//
// Channel memory and thread memory are the same shape stored under two keys —
// a thread's timestamp, or the empty string for the channel itself — so a turn
// answered in the channel writes its own working state as the channel's. On an
// alerts feed that is plainly wrong: #backend-ops received one investigation's
// goal, "Explain why website image bumps are not reaching VA1", as though the
// channel existed to answer it, when the channel exists to carry alerts for
// many services and the goal belonged to one thread inside it.
//
// Only the goal is dropped. A channel purpose, the topology it has learned,
// the conventions it has settled and its standing knowledge are all properties
// of the place. A summary of what is going on there is continuity worth
// keeping. An objective is not: a room does not have one.
func (m AgentMemory) WithoutThreadScope() AgentMemory {
	m.Goal = ""
	return m
}

// KnowledgeItem is a provenance-linked fact learned from a Slack conversation.
// It is continuity context, not an instruction, authority grant, or current
// operational evidence.
type KnowledgeItem struct {
	Subject         string `json:"subject"`
	Kind            string `json:"kind"`
	Statement       string `json:"statement"`
	Status          string `json:"status"`
	Confidence      int    `json:"confidence"`
	SourceRef       string `json:"source_ref"`
	SourceMessageTS string `json:"source_message_ts,omitempty"`
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

// UnmarshalJSON accepts "topic" for the subject of a memory offer and
// "guidance" for its value. Both name exactly one real field and nothing else
// in a memory offer could be meant, so the only thing the strict spelling
// bought was a discarded offer — three separate real turns lost one that way.
func (offer *MemoryOffer) UnmarshalJSON(data []byte) error {
	type wire MemoryOffer
	var value wire
	if err := DecodeModelObject(data, map[string]string{
		"topic":    "subject",
		"guidance": "value",
	}, &value); err != nil {
		return err
	}
	*offer = MemoryOffer(value)
	return nil
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
	LastRecalledAt time.Time `json:"last_recalled_at,omitempty"`
	RecallCount    int       `json:"recall_count"`
	LastReviewedAt time.Time `json:"last_reviewed_at,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// PredicateMayBePermanent reports whether a memory predicate is allowed to
// never expire.
//
// Only guidance is. The expiry on everything else in this table exists because
// a memory that describes a system outlives the system: an alias, a channel's
// repository binding, an evidence route and an entity correction are all claims
// about infrastructure, and infrastructure is renamed, moved and deleted
// without telling Responder. A permanent one of those is a confident wrong
// answer with no expiry date.
//
// Guidance is not a claim about anything. "Always tell me the version delta" is
// a statement about how to talk, it is true of nobody's cluster, and there is
// no rename that can falsify it. Only the operator can, and the operator can
// say so. Deleting it after thirty days does not protect them from a stale
// fact; it silently drops an instruction they gave on purpose.
//
// It lives in core rather than in the memory package because persistence has to
// enforce it too — the feedback-to-guidance path in the dashboard writes
// entries straight to the store — and the store cannot import memory without a
// cycle.
func PredicateMayBePermanent(predicate string) bool {
	return predicate == "guidance"
}

// RepositoryContentsSubject is the single subject a repository-scoped memory
// uses for "which part of the product lives here". One subject per scope means
// the memory table's UNIQUE(scope_kind, scope_key, subject_key, predicate)
// gives each repository exactly one such row, replaced rather than accumulated.
const RepositoryContentsSubject = "repository_contents"

// MemoryRollup is an automatically synthesized continuity summary. It is derived
// from already bounded conversation summaries and is never operational evidence.
type MemoryRollup struct {
	ID             string
	ScopeKind      string
	ScopeKey       string
	Repository     string
	PeriodStart    time.Time
	PeriodEnd      time.Time
	State          AgentMemory
	SourceRefs     []string
	SourceCount    int
	LastRecalledAt time.Time
	RecallCount    int
	ExpiresAt      time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type MemoryReviewItem struct {
	ID           string
	Kind         string
	EntryIDs     []string
	Reason       string
	SourceDigest string
	Status       string
	ReviewedBy   string
	ReviewedAt   time.Time
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

type MemoryHealth struct {
	ExplicitActive        int
	ExplicitRecalled      int
	ConversationSummaries int
	Rollups               int
	PendingReviews        int
	LastDreamedAt         time.Time
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
	Scope      string            `json:"scope"`
	Repository string            `json:"repository"`
	Workflow   *StandingWorkflow `json:"workflow,omitempty"`
	// Trigger and Action accept old model responses and preserve compatibility
	// with rules saved before workflow documents. New offers use Workflow.
	Trigger    string `json:"trigger,omitempty"`
	Action     string `json:"action,omitempty"`
	SourceKind string `json:"source_kind,omitempty"`
	ExpiresIn  string `json:"expires_in,omitempty"`
}

// UnmarshalJSON accepts "event" for the trigger, and accepts and drops a
// channel_id.
//
// A rule offer is the one payload the prompt never shows field by field, and
// two consecutive real runs invented a different name apiece for it. "event"
// is what a rule fires on, which is what Trigger holds and the only field it
// could be. The channel is different in kind: a standing rule always binds to
// the channel the request arrived in, read from the Slack input and never from
// the offer, so a model naming it is agreeing with a decision that was never
// its own. Dropping it beats honoring it, and both beat rejecting the rule,
// the preference and the reply together.
func (offer *RuleOffer) UnmarshalJSON(data []byte) error {
	type wire RuleOffer
	var value wire
	if err := DecodeModelObject(data, map[string]string{
		"event":      "trigger",
		"channel_id": "",
	}, &value); err != nil {
		return err
	}
	*offer = RuleOffer(value)
	return nil
}

type StandingRule struct {
	ID           string
	ChannelID    string
	Repository   string
	Trigger      string
	Action       string
	SourceKind   string
	WorkflowName string
	Workflow     StandingWorkflow
	Enabled      bool
	SourceRef    string
	ActorID      string
	TriggerCount int
	// ActedCount and QuietCount split the fires by what they produced, and they
	// are durable: a fire count alone cannot tell a rule that works from one that
	// matches constantly and answers nothing. They sum to the number of fires
	// whose outcome was recorded, which is not TriggerCount — everything that
	// fired before migration 53 is uncounted, and a surface presenting the two as
	// a ratio would be claiming observations nobody kept.
	ActedCount int
	QuietCount int
	// LastActed is read from the retained runs rather than stored, so an empty
	// value means "not inside the retention window" rather than "never".
	LastActed     time.Time
	LastTriggered time.Time
	ExpiresAt     time.Time
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// ScheduleOffer is model-produced but inert until a configured operator confirms it.
// StartAt anchors the first occurrence when supplied. Calendar schedules keep wall-clock
// semantics in Timezone; interval schedules use IntervalSeconds after the first occurrence.
type ScheduleOffer struct {
	Title           string   `json:"title"`
	Prompt          string   `json:"prompt"`
	Repository      string   `json:"repository"`
	DeliveryChannel string   `json:"delivery_channel_id,omitempty"`
	Recurrence      string   `json:"recurrence"`
	StartAt         string   `json:"start_at"`
	IntervalSeconds int64    `json:"interval_seconds,omitempty"`
	Weekdays        []string `json:"weekdays,omitempty"`
	DayOfMonth      int      `json:"day_of_month,omitempty"`
	LocalTime       string   `json:"local_time,omitempty"`
	Timezone        string   `json:"timezone,omitempty"`
	CatchUp         string   `json:"catch_up,omitempty"`
	ExpiresIn       string   `json:"expires_in,omitempty"`
}

type ScheduledTask struct {
	ID              string
	TeamID          string
	ChannelID       string
	ThreadTS        string
	DeliveryChannel string
	Repository      string
	Title           string
	Prompt          string
	Recurrence      string
	StartAt         time.Time
	IntervalSeconds int64
	Weekdays        []string
	DayOfMonth      int
	LocalTime       string
	Timezone        string
	CatchUp         string
	Enabled         bool
	ActorID         string
	SourceRef       string
	NextRunAt       time.Time
	LastRunAt       time.Time
	LastOutcome     string
	ExpiresAt       time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// ScheduleProposal keeps the complete normalized task on the server while
// Slack carries only its opaque ID. A proposal is inert until its actor accepts
// it, at which point AcceptedTaskID makes retries idempotent.
type ScheduleProposal struct {
	ID             string
	TeamID         string
	ChannelID      string
	ThreadTS       string
	ActorID        string
	SourceRef      string
	Task           ScheduledTask
	ReplaceTaskID  string
	Status         string
	AcceptedTaskID string
	ExpiresAt      time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type ScheduledTaskRun struct {
	TaskID       string
	ScheduledFor time.Time
	SourceInput  string
	AgentRunID   string
	EpisodeID    string
	Outcome      string
	LastError    string
	StartedAt    time.Time
	CompletedAt  time.Time
	CreatedAt    time.Time
	UpdatedAt    time.Time
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
			"evidence_refs", "knowledge":
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
	if value := fields["knowledge"]; len(value) != 0 {
		if err := json.Unmarshal(value, &m.Knowledge); err != nil {
			return fmt.Errorf("decode memory knowledge: %w", err)
		}
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
	ChannelID      string
	ChannelName    string
	ThreadTS       string
	Repository     string
	LastMessage    string
	State          AgentMemory
	LastRecalledAt time.Time
	RecallCount    int
	UpdatedAt      time.Time
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

// EffortContract describes how complete a work episode must be before the host
// accepts its result. It is intentionally independent from AuthorityBoundary.
type EffortContract string

const (
	EffortConversational        EffortContract = "conversational"
	EffortFocusedCheck          EffortContract = "focused_check"
	EffortOperationalAssessment EffortContract = "operational_assessment"
	EffortIncidentInvestigation EffortContract = "incident_investigation"
	EffortEngineeringTask       EffortContract = "engineering_task"
)

type AuthorityBoundary string

const (
	AuthorityReadOnly          AuthorityBoundary = "read_only"
	AuthorityRepositoryWrite   AuthorityBoundary = "repository_write"
	AuthorityGovernedOperation AuthorityBoundary = "governed_operation"
)

type EpisodeActivity string

const (
	ActivityInvestigating EpisodeActivity = "investigating"
	ActivityExplaining    EpisodeActivity = "explaining"
	ActivityScheduling    EpisodeActivity = "scheduling"
	ActivityEngineering   EpisodeActivity = "engineering"
	ActivityOperating     EpisodeActivity = "operating"
)

type WorkEpisodeState string

const (
	EpisodeAccepted        WorkEpisodeState = "accepted"
	EpisodeAcknowledged    WorkEpisodeState = "acknowledged"
	EpisodePlanning        WorkEpisodeState = "planning"
	EpisodeWorking         WorkEpisodeState = "working"
	EpisodeBlocked         WorkEpisodeState = "blocked"
	EpisodeWaitingOperator WorkEpisodeState = "waiting_operator"
	EpisodeWaitingExternal WorkEpisodeState = "waiting_external"
	EpisodeWaitingApproval WorkEpisodeState = "waiting_approval"
	EpisodeRetrying        WorkEpisodeState = "retrying"
	EpisodeVerifying       WorkEpisodeState = "verifying"
	EpisodeCompleted       WorkEpisodeState = "completed"
	EpisodeFailed          WorkEpisodeState = "failed"
	EpisodeRefused         WorkEpisodeState = "refused"
	EpisodeCancelled       WorkEpisodeState = "cancelled"
	EpisodeSuperseded      WorkEpisodeState = "superseded"
)

type EpisodeMode string

const (
	EpisodeConversation          EpisodeMode = "conversation"
	EpisodeCheck                 EpisodeMode = "check"
	EpisodeIncident              EpisodeMode = "incident"
	EpisodeEngineering           EpisodeMode = "engineering"
	EpisodeScheduledVerification EpisodeMode = "scheduled_verification"
	EpisodeStandingAssignment    EpisodeMode = "standing_assignment"
)

// ConversationRef identifies the platform conversation in which work was
// accepted. It is a value object: lifecycle state belongs to WorkEpisode.
type ConversationRef struct {
	Platform    string `json:"platform"`
	WorkspaceID string `json:"workspace_id"`
	ChannelID   string `json:"channel_id"`
	ThreadTS    string `json:"thread_ts,omitempty"`
	AnchorTS    string `json:"anchor_ts,omitempty"`
	Visibility  string `json:"visibility"`
}

type BoundDestination struct {
	ChannelID string `json:"channel_id"`
	ThreadTS  string `json:"thread_ts,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

// WorkEpisode is the host-owned execution contract for one accepted unit of
// work. AgentRun remains the transport record; this record says what must be
// accomplished, what authority is available, and what the team is waiting for.
type WorkEpisode struct {
	ID                  string
	WorkspaceID         string
	ParentEpisodeID     string
	Mode                EpisodeMode
	Conversation        ConversationRef
	Destination         BoundDestination
	DestinationRevision int
	Revision            int
	LatestAttemptID     string
	AuthoritySnapshot   string
	// AgentRunID is the first attempt retained for compatibility while callers
	// migrate to EpisodeAttempt. It is not the lifecycle owner.
	AgentRunID         string
	Effort             EffortContract
	Authority          AuthorityBoundary
	Activity           EpisodeActivity
	State              WorkEpisodeState
	Objective          string
	RequiredCoverage   []string
	CompletionCriteria []string
	Phase              string
	Status             string
	NextAction         string
	EventSequence      int
	ProgressSequence   int
	LastProgressAt     time.Time
	ProgressDueAt      time.Time
	CreatedAt          time.Time
	UpdatedAt          time.Time
	CompletedAt        time.Time
}

type EpisodeGoalState string

const (
	GoalPlanned   EpisodeGoalState = "planned"
	GoalReady     EpisodeGoalState = "ready"
	GoalWorking   EpisodeGoalState = "working"
	GoalWaiting   EpisodeGoalState = "waiting"
	GoalCompleted EpisodeGoalState = "completed"
	GoalBlocked   EpisodeGoalState = "blocked"
	GoalExcluded  EpisodeGoalState = "excluded"
	GoalCancelled EpisodeGoalState = "cancelled"
)

type EpisodeGoal struct {
	ID                   string
	EpisodeID            string
	ParentGoalID         string
	PrerequisiteGoalIDs  []string
	Kind                 string
	RequestedOutcome     string
	CompletionContract   string
	WritableRepository   string
	ReadOnlyRepositories []string
	AuthorityRequirement AuthorityBoundary
	Required             bool
	State                EpisodeGoalState
	Blocker              string
	CreatedAt            time.Time
	UpdatedAt            time.Time
	CompletedAt          time.Time
}

type EpisodeAttemptState string

const (
	AttemptPending   EpisodeAttemptState = "pending"
	AttemptLeased    EpisodeAttemptState = "leased"
	AttemptRunning   EpisodeAttemptState = "running"
	AttemptSucceeded EpisodeAttemptState = "succeeded"
	AttemptFailed    EpisodeAttemptState = "failed"
	AttemptCancelled EpisodeAttemptState = "cancelled"
)

type EpisodeAttempt struct {
	ID                string
	EpisodeID         string
	AgentRunID        string
	Number            int
	State             EpisodeAttemptState
	FailureClass      string
	FailureGeneration int
	LeaseOwner        string
	FencingToken      int64
	LeaseExpiresAt    time.Time
	ContextManifestID string
	StartedAt         time.Time
	CompletedAt       time.Time
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// ContextManifest is immutable. ContextReference values point at
// content-addressed or source-addressed inputs instead of duplicating payloads.
//
// Usage is the one exception, and it does not contradict that. The envelope is
// frozen when the attempt starts; what the provider charged for it is only
// known when the turn ends, so it is written afterwards by
// RecordContextManifestUsage. Nothing about the context itself changes.
type ContextManifest struct {
	ID                string
	EpisodeID         string
	AttemptID         string
	ParentManifestID  string
	Version           int
	PromptVersion     string
	ContractVersion   string
	ToolSchemaVersion string
	Preset            string
	Provider          string
	Model             string
	ReasoningEffort   string
	SubmittedPrompt   string
	Omissions         []string
	CreatedAt         time.Time
	References        []ContextReference
	Usage             ContextUsage
	Latency           ContextLatency
}

// ContextArtifact is the retained body of one bounded input artifact handed
// to a turn — a rendered pull-request snapshot, a Slack file — keyed by the
// digest its manifest reference records, so "what exactly did the model see"
// stays answerable for artifacts the same way it is for the prompt.
type ContextArtifact struct {
	Digest    string
	Name      string
	MediaType string
	Body      []byte
	CreatedAt time.Time
}

// MaxRetainedArtifactBytes bounds what an artifact body may cost the state
// database. The transport accepts artifacts far larger; retention is for the
// text-sized ones a person would open from a trace.
const MaxRetainedArtifactBytes = 1 << 20

// RetainableArtifact reports whether an input artifact's body is worth
// keeping: bounded, and a text shape a trace can render.
func RetainableArtifact(mediaType string, size int) bool {
	if size <= 0 || size > MaxRetainedArtifactBytes {
		return false
	}
	mediaType = strings.ToLower(strings.TrimSpace(mediaType))
	return strings.HasPrefix(mediaType, "text/") || mediaType == "application/json"
}

// ContextUsage is what one attempt spent, totalled over every Coop turn that
// attempt took. CostUSD is provider-reported; token pricing remains an estimate.
//
// It is a total rather than a single turn's figure because one attempt can run
// several turns: a result the host refuses is sent back as a correction, which
// reuses the same attempt and the same manifest. Recording only the last turn
// would report the cheapest number for the attempts that cost the most, which
// is precisely backwards for anyone reading a usage page to find spend.
//
// Cached input is kept apart from the input total because Coop reports it
// apart, and every provider prices a cache read differently. CostedTurns keeps
// an exact zero distinguishable from an adapter that reported no money.
type ContextUsage struct {
	InputTokens       int
	CachedInputTokens int
	OutputTokens      int
	ReasoningTokens   int
	CostUSD           float64
	CostedTurns       int
}

// Recorded reports whether any provider ever measured this attempt.
//
// Zero is a real answer for a trivial turn, so absence stays distinguishable
// from free: ACP does not require an adapter to report usage, and an attempt
// nobody measured must read as "not recorded" rather than as a free one.
func (u ContextUsage) Recorded() bool {
	return u.InputTokens > 0 || u.CachedInputTokens > 0 ||
		u.OutputTokens > 0 || u.ReasoningTokens > 0
}

func (u ContextUsage) CostRecorded() bool { return u.CostedTurns > 0 }

// ContextLatency is how long an attempt waited, totalled over every Coop turn
// it took and split by who was doing the waiting.
//
// Three spans rather than one duration, because "the answer took four minutes"
// and "the model took four minutes" are different faults with different fixes.
// Queued is Coop holding the turn before a provider picked it up, Provider is
// the provider working, and Host is Responder not yet having noticed that the
// turn finished — it polls, so that gap is real and is nobody else's.
//
// Provider is not split into inference and tool calls. Coop's turn record
// carries queued_at, started_at and finished_at and nothing between them, and
// its activity states are session lifecycle rather than what the model is
// doing, so that split would have to be invented. An invented split in a
// latency report is a guess wearing a measurement's clothes.
type ContextLatency struct {
	Turns    int
	Queued   time.Duration
	Provider time.Duration
	Host     time.Duration
}

// Recorded reports whether any turn of this attempt was timed at all.
//
// Turns counts only turns Coop timestamped, so zero means nobody measured
// rather than "it was instant" — the same distinction ContextUsage.Recorded
// keeps, and for the same reason. It also keeps an average over Turns honest:
// a turn that failed before it started has no started_at, contributes no span,
// and so must not be in the divisor either.
func (l ContextLatency) Recorded() bool { return l.Turns > 0 }

// NewContextLatency measures one finished turn. observedAt is when the host
// saw it finish, which is what makes the poll lag visible.
//
// A turn missing either endpoint measures nothing rather than zero: Coop
// leaves started_at unset on a turn that failed while queued, and subtracting
// from a zero time would report a span since year one.
//
// Negative spans are clamped away rather than recorded. Coop runs on the same
// host and shares its clock, so a negative here is a rounding artifact at a
// boundary, not a fact about a turn that finished before it began.
func NewContextLatency(queuedAt, startedAt, finishedAt, observedAt time.Time) ContextLatency {
	if startedAt.IsZero() || finishedAt.IsZero() {
		return ContextLatency{}
	}
	// A missing endpoint measures nothing. Subtracting a zero time would
	// otherwise report two millennia of queueing as though it were a fact.
	span := func(from, to time.Time) time.Duration {
		if from.IsZero() || to.IsZero() {
			return 0
		}
		return max(to.Sub(from), 0)
	}
	return ContextLatency{
		Turns:    1,
		Queued:   span(queuedAt, startedAt),
		Provider: span(startedAt, finishedAt),
		Host:     span(finishedAt, observedAt),
	}
}

type ContextReference struct {
	ID             string
	ManifestID     string
	Kind           string
	SourceRef      string
	ContentDigest  string
	SourceRevision string
	Visibility     string
	Ordinal        int
	OmittedReason  string
	Metadata       map[string]string
}

// ContextOmission is one thing the assembler decided not to put in a prompt.
//
// It is recorded because "what was NOT in the prompt" is usually the answer to
// "why did it say that". A prompt trimmed to a third of its context and a
// complete one otherwise leave identical manifests: the references list what
// went in, and nothing anywhere listed what did not. All 2,825 reference rows
// and all 351 manifests on the deployed database say nothing was ever dropped,
// which is not what happened — it is what nobody wrote down.
//
// Kind and SourceRef mirror ContextReference so an omission is stored beside
// the references it displaced, rather than in a parallel shape a reader has to
// know to go looking in.
type ContextOmission struct {
	Kind      string
	SourceRef string
	Reason    string
}

// DroppedContextLayer names a bounded context layer the assembler left out
// whole, addressed by layer rather than by content — the point of the record is
// that the content is precisely what there is no reference to.
func DroppedContextLayer(kind, reason string) ContextOmission {
	return ContextOmission{Kind: kind, SourceRef: "context-layer:" + kind, Reason: reason}
}

// AppendElidedPrompt adds the omission for a prompt the transport will have to
// cut, and adds nothing when it fits.
//
// The host knows this before the turn is sent — it holds both the prompt and
// the cap — so it is recorded against the attempt that suffered it. The Coop
// client's own truncation counter only ever knew how many prompts had been
// elided in this process and never which episode's, so an operator holding one
// bad answer could not find out whether its prompt had been cut in half.
func AppendElidedPrompt(
	omissions []ContextOmission,
	sourceRef string,
	promptBytes, capBytes int,
) []ContextOmission {
	if capBytes <= 0 || promptBytes <= capBytes {
		return omissions
	}
	return append(omissions, ContextOmission{
		Kind: "compiled_prompt", SourceRef: sourceRef,
		Reason: fmt.Sprintf(
			"the transport elided %d bytes from the middle of this %d-byte prompt to fit the %d-byte Coop turn limit",
			promptBytes-capBytes, promptBytes, capBytes,
		),
	})
}

// OmittedContextReferences turns omissions into the reference rows that record
// them.
//
// Visibility is "omitted" rather than "eligible" or "private". Those two say
// what may be shown of something that was sent; this was not sent, and calling
// it private would hide a gap behind a word that means the opposite.
func OmittedContextReferences(omissions []ContextOmission) []ContextReference {
	references := make([]ContextReference, 0, len(omissions))
	for _, omission := range omissions {
		references = append(references, ContextReference{
			Kind: omission.Kind, SourceRef: omission.SourceRef,
			Visibility: "omitted", OmittedReason: omission.Reason,
		})
	}
	return references
}

// ContextOmissionReasons is the same facts as the manifest-level summary, in
// the order the assembler decided them, which is also the order of increasing
// desperation: the first thing dropped was the least load-bearing.
func ContextOmissionReasons(omissions []ContextOmission) []string {
	reasons := make([]string, 0, len(omissions))
	for _, omission := range omissions {
		reasons = append(reasons, omission.Reason)
	}
	return reasons
}

type EpisodeWakeupState string

const (
	WakeupPending   EpisodeWakeupState = "pending"
	WakeupLeased    EpisodeWakeupState = "leased"
	WakeupResolved  EpisodeWakeupState = "resolved"
	WakeupExpired   EpisodeWakeupState = "expired"
	WakeupCancelled EpisodeWakeupState = "cancelled"
)

type EpisodeWakeup struct {
	ID              string
	EpisodeID       string
	Kind            string
	EventMatcher    []byte
	DueAt           time.Time
	PollAfter       time.Time
	Deadline        time.Time
	State           EpisodeWakeupState
	LastObservation []byte
	LeaseOwner      string
	FencingToken    int64
	LeaseExpiresAt  time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time
	ResolvedAt      time.Time
}

type WorkEpisodeEvent struct {
	ID             string          `json:"id"`
	EpisodeID      string          `json:"episode_id"`
	Sequence       int             `json:"sequence"`
	Kind           string          `json:"kind"`
	Actor          string          `json:"actor"`
	IdempotencyKey string          `json:"idempotency_key"`
	Payload        json.RawMessage `json:"payload"`
	CreatedAt      time.Time       `json:"created_at"`
}

type WorkEpisodeProgress struct {
	ID        string
	EpisodeID string
	Sequence  int
	Phase     string
	Summary   string
	CreatedAt time.Time
}

type AgentRun struct {
	ID                string
	EpisodeID         string
	AttemptID         string
	AttemptNumber     int
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
	Episode           *WorkEpisode
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
	URL         string
	EvidenceIDs []string
	CreatedAt   time.Time
}

// RemediationRecord is the durable, evidence-backed view of one incident.
// Its members remain canonical in their own tables; the timeline and
// postmortem are projections over this record rather than copied state.
type RemediationRecord struct {
	Incident    Incident
	Signals     []Signal
	AgentRuns   []AgentRun
	Evidence    []Evidence
	Coverage    []Coverage
	Events      []TimelineEvent
	Approvals   []EmisarApproval
	Publication Publication
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
	ID               string
	EpisodeID        string
	AgentRunID       string
	AgentRunKey      string
	ChannelID        string
	SessionChannelID string
	ThreadTS         string
	MessageTS        string
	Repository       string
	SourceInput      string
	Mode             string
	Action           string
	Reason           string
	Evidence         int
	Coverage         int
	CreatedAt        time.Time
}

type PublicationState string

type PublicationFailureCode string

const (
	PublicationReviewing  PublicationState = "reviewing"
	PublicationPublishing PublicationState = "publishing"
	PublicationRetrying   PublicationState = "retrying"
	PublicationFailed     PublicationState = "failed"
	PublicationPublished  PublicationState = "published"
	PublicationStale      PublicationState = "stale"

	PublicationFailureNoChanges      PublicationFailureCode = "no_changes"
	PublicationFailureSessionBinding PublicationFailureCode = "session_binding"
)

type Publication struct {
	IncidentID     string
	AttemptInputID string
	Generation     int64
	Repository     string
	BaseBranch     string
	HeadBranch     string
	ParentHead     string
	CandidateTree  string
	CommitSHA      string
	RemoteSHA      string
	PRNumber       int
	PRURL          string
	State          PublicationState
	FailureCode    PublicationFailureCode
	LastError      string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	PublishedAt    time.Time
}

// PullRequestTarget is the authenticated, operator-approved source and
// publication destination for an engineering task that edits an existing PR.
// The exact head commit is the admitted workspace baseline and the first
// force-with-lease value, so neither session creation nor publication can
// silently cross a concurrent PR update.
type PullRequestTarget struct {
	Repository string `json:"repository"`
	Number     int    `json:"number"`
	URL        string `json:"url"`
	BaseBranch string `json:"base_branch"`
	HeadBranch string `json:"head_branch"`
	HeadCommit string `json:"head_commit"`
}

func (p PullRequestTarget) Valid() bool {
	return p.Repository != "" && p.Number > 0 && p.URL != "" &&
		p.BaseBranch != "" && p.HeadBranch != "" && p.HeadCommit != ""
}

func (p Publication) Published() bool {
	return p.State == PublicationPublished && p.PRNumber > 0 && p.PRURL != ""
}

func (p Publication) HasPR() bool {
	return p.PRNumber > 0 && p.PRURL != ""
}

func (p Publication) NeedsUpdate() bool {
	return p.State == PublicationStale && p.HasPR()
}

func (p Publication) InProgress() bool {
	switch p.State {
	case PublicationReviewing, PublicationPublishing, PublicationRetrying:
		return true
	default:
		return false
	}
}

type PublicationFollowup struct {
	IncidentID   string
	PRState      string
	ChecksState  string
	MergeSHA     string
	MergedAt     time.Time
	NextCheckAt  time.Time
	FailureCount int
	LastError    string
	LastEventKey string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

func (p PublicationFollowup) Terminal() bool {
	return p.PRState == "merged" || p.PRState == "closed"
}

type PublicationContext struct {
	IncidentID    string `json:"incident_id"`
	RepositoryKey string `json:"repository_key"`
	Repository    string `json:"repository"`
	Title         string `json:"title"`
	PRNumber      int    `json:"pr_number"`
	PRURL         string `json:"pr_url"`
	HeadBranch    string `json:"head_branch"`
	HeadSHA       string `json:"head_sha"`
	MergeSHA      string `json:"merge_sha,omitempty"`
	PRState       string `json:"pr_state"`
	ChecksState   string `json:"checks_state"`
	ChannelID     string `json:"channel_id"`
	ThreadTS      string `json:"thread_ts"`
}

type PublicationLifecycleEvent struct {
	ID              string
	IncidentID      string
	Kind            string
	State           string
	Summary         string
	SourceChannelID string
	SourceMessageTS string
	CreatedAt       time.Time
}

type PublicationLifecycleStatus struct {
	PRState      string
	Draft        bool
	HeadSHA      string
	MergeSHA     string
	ChecksState  string
	ChecksTotal  int
	ChecksPassed int
	ChecksFailed int
	MergedAt     time.Time
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
	MemoryRollups         int64
	MemoryReviews         int64
	MemorySupersessions   int64
	Preferences           int64
	StandingRules         int64
	StandingRuleRuns      int64
	ScheduledTasks        int64
	ScheduledTaskRuns     int64
	EmisarApprovals       int64
	ConfigurationSessions int64
	ClosedIncidents       int64
	// Episodes is how many finished episodes expired. Each one takes its event
	// stream, progress, attempts, manifests, claim assessments, goals and
	// commitments with it through ON DELETE CASCADE, so this single number
	// stands for a great many rows.
	Episodes int64
	// AgentRunContexts counts assembled prompt inputs emptied out of terminal
	// runs. Not a deletion — the run row, and so the episode hanging off it,
	// stays readable — which is why it is reported separately and left out of
	// Total rather than inflating a count of records removed.
	AgentRunContexts int64
	// ContextArtifacts counts retained input artifact bodies deleted once the
	// prompts that referenced them were themselves emptied; the digest on the
	// manifest reference remains for audit.
	ContextArtifacts int64
	// Retention counts rows removed by the table sweeps that live in
	// internal/store/retention rather than in Prune's own body — the tables
	// that had no policy at all until they were given one.
	Retention   int64
	AuditEvents int64
}

func (r PruneResult) Total() int64 {
	return r.SlackInputs + r.WebhookEvents + r.SlackDeliveries + r.AgentRuns +
		r.EvaluationDecisions + r.ChannelIntelligence + r.ConversationMemories +
		r.MemoryEntries + r.MemoryRollups + r.MemoryReviews + r.MemorySupersessions +
		r.Preferences + r.StandingRules +
		r.StandingRuleRuns + r.ScheduledTasks + r.ScheduledTaskRuns +
		r.EmisarApprovals + r.ConfigurationSessions +
		r.ClosedIncidents + r.Episodes + r.Retention + r.AuditEvents
}

// StoredAgentResult is one historical model output, for replaying the result
// protocol against traffic that already happened.
type StoredAgentResult struct {
	RunID     string    `json:"run_id"`
	Mode      string    `json:"mode"`
	Message   string    `json:"message"`
	CreatedAt time.Time `json:"created_at"`
}

// StandingAssignmentChangeClasses is the closed set of changes an operator can
// delegate to a standing assignment.
//
// It is an allowlist rather than free text because free text means "Responder
// may change anything". Each entry is deliberately a class where a wrong change
// is visible in review and cheap to discard — none of them touch business
// logic, and none of them are things a reviewer would wave through.
var StandingAssignmentChangeClasses = []string{
	"dependency_upgrade",
	"alert_threshold",
	"flaky_test_quarantine",
	"observability",
	"documentation",
}

// StandingAssignment is scoped authority to act without a per-action click.
//
// The confirmation is not removed, only moved earlier: an operator agrees once
// to a bounded shape of work. Every field except the identifiers is a bound on
// what that agreement covers.
type StandingAssignment struct {
	ID            string    `json:"id"`
	ChannelID     string    `json:"channel_id"`
	SignalPattern string    `json:"signal_pattern"`
	Repository    string    `json:"repository"`
	PathGlobs     []string  `json:"path_globs,omitempty"`
	ChangeClass   string    `json:"change_class"`
	DailyBudget   int       `json:"daily_budget"`
	ActorID       string    `json:"actor_id"`
	Enabled       bool      `json:"enabled"`
	ConfirmedAt   time.Time `json:"confirmed_at"`
	ExpiresAt     time.Time `json:"expires_at"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// Live reports whether an assignment may act right now.
func (a StandingAssignment) Live(now time.Time) bool {
	return a.Enabled && a.ExpiresAt.After(now)
}

// FixtureCandidate is a correction waiting to become a regression fixture.
//
// The host already decided the model was wrong and said why, so the label costs
// nothing to produce. What it still needs is a human deciding the lesson is
// worth keeping — both because the design document requires review before
// anything enters a release gate, and because unreviewed corrections would fill
// the corpus with the same few mistakes.
type FixtureCandidate struct {
	ID              string    `json:"id"`
	EpisodeID       string    `json:"episode_id"`
	RunID           string    `json:"run_id"`
	Capability      string    `json:"capability,omitempty"`
	CorrectionClass string    `json:"correction_class"`
	Correction      string    `json:"correction"`
	Status          string    `json:"status"`
	ReviewedBy      string    `json:"reviewed_by,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
	ExpiresAt       time.Time `json:"expires_at"`
}
