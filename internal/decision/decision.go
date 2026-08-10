// Package decision owns the shapes a model result arrives in and the rules for
// reading one: the watch decision, the agent report, their typed operation
// stream, and every validator that decides whether a result may be acted on.
//
// It exists so those rules can be reached without depending on the runtime.
// They were unexported inside internal/service, which meant the offline
// evaluation family had to live in the runtime package to use them — the
// coupling that kept internal/service from being split.
//
// Nothing here touches a store, a Slack client, or a clock it did not receive.
// A decision is read the same way whether it came from a live turn or a
// recorded fixture, which is the property that makes replay meaningful.
package decision

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// NoConversationReply is the sentinel a model emits to say a human teammate
// would reasonably stay silent here. It lives with the decision shapes because
// reading it is part of reading a result, not part of building a prompt.
const NoConversationReply = "<responder-no-reply/>"

// Reply bounds. A Slack message has hard limits and a reply sequence that
// exceeds them is rejected at delivery, after the work is done.
const (
	MaxFollowupMessages   = 5
	MaxReplyPartBytes     = 12 << 10
	MaxReplySequenceBytes = 48 << 10
)

func (a AttentionAssessment) Score() int {
	return a.Urgency + a.Confidence + a.Novelty + a.Ownership
}

func (a AttentionAssessment) Present() bool {
	return a.Addressee != "" || a.Urgency != 0 || a.Confidence != 0 ||
		a.Novelty != 0 || a.Ownership != 0
}

func EpisodeContainsAny(value string, terms ...string) bool {
	for _, term := range terms {
		if strings.Contains(value, term) {
			return true
		}
	}
	return false
}

var SlackReactionNamePattern = regexp.MustCompile(
	`^[a-z0-9_+\-]{1,255}(?:::skin-tone-[2-6])?$`,
)

type WatchDecision struct {
	Action             string                              `json:"action"`
	Reaction           string                              `json:"reaction,omitempty"`
	Attention          AttentionAssessment                 `json:"attention,omitempty"`
	Message            string                              `json:"message,omitempty"`
	FollowupMessages   []string                            `json:"followup_messages,omitempty"`
	Visuals            []core.GeneratedVisual              `json:"visuals,omitempty"`
	Title              string                              `json:"title,omitempty"`
	IncidentTitle      string                              `json:"incident_title,omitempty"`
	TaskTitle          string                              `json:"task_title,omitempty"`
	TaskRepository     string                              `json:"task_repository,omitempty"`
	TaskPrompt         string                              `json:"task_prompt,omitempty"`
	Evidence           []core.Evidence                     `json:"evidence,omitempty"`
	Coverage           []core.Coverage                     `json:"coverage,omitempty"`
	Memory             core.AgentMemory                    `json:"memory,omitempty"`
	MemoryOffer        *core.MemoryOffer                   `json:"memory_offer,omitempty"`
	PreferenceOffer    *core.PreferenceOffer               `json:"preference_offer,omitempty"`
	RuleOffer          *core.RuleOffer                     `json:"rule_offer,omitempty"`
	ScheduleOffer      *core.ScheduleOffer                 `json:"schedule_offer,omitempty"`
	PendingApproval    *core.EmisarApproval                `json:"pending_approval,omitempty"`
	AlertAssessment    *AlertAssessment                    `json:"alert_assessment,omitempty"`
	Completion         *investigation.CompletionAssessment `json:"completion,omitempty"`
	PublicationUpdates []PublicationUpdate                 `json:"publication_updates,omitempty"`
	Reason             string                              `json:"reason,omitempty"`
	Operations         []investigation.ResultOperation     `json:"operations,omitempty"`
	AppliedOperations  []investigation.ResultOperation     `json:"-"`

	// See AgentReport: these record whether the typed protocol was actually
	// used, so the legacy path can be deleted on evidence rather than hope.
	LegacyShape bool `json:"-"`
}

// MarshalWatchDecisionResult persists the same transport shape accepted from
// Coop. Typed operations are folded into legacy fields for validation and
// rendering, but those projections must not be serialized beside operations.

// MarshalWatchDecisionResult persists the same transport shape accepted from
// Coop. Typed operations are folded into legacy fields for validation and
// rendering, but those projections must not be serialized beside operations.
func MarshalWatchDecisionResult(decision WatchDecision) ([]byte, error) {
	if len(decision.Operations) == 0 {
		return json.Marshal(decision)
	}
	type operationsEnvelope struct {
		Action             string                          `json:"action"`
		Attention          AttentionAssessment             `json:"attention,omitempty"`
		Reason             string                          `json:"reason,omitempty"`
		PublicationUpdates []PublicationUpdate             `json:"publication_updates,omitempty"`
		Operations         []investigation.ResultOperation `json:"operations"`
	}
	return json.Marshal(operationsEnvelope{
		Action: decision.Action, Attention: decision.Attention, Reason: decision.Reason,
		PublicationUpdates: decision.PublicationUpdates, Operations: decision.Operations,
	})
}

type PublicationUpdate struct {
	IncidentID string `json:"incident_id"`
	Kind       string `json:"kind"`
	State      string `json:"state"`
	Reference  string `json:"reference"`
	Summary    string `json:"summary"`
}

type AlertAssessment = investigation.AlertAssessment

type AttentionAssessment struct {
	Addressee  string `json:"addressee,omitempty"`
	Urgency    int    `json:"urgency,omitempty"`
	Confidence int    `json:"confidence,omitempty"`
	Novelty    int    `json:"novelty,omitempty"`
	Ownership  int    `json:"ownership,omitempty"`
}

func OperationalAlertEvent(text string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(text), " "))
	return EpisodeContainsAny(
		normalized, " alert", "alert ", "firing", "resolved", "critical", "warning",
	)
}

func WatchDecisionHasEvidenceSource(evidence []core.Evidence, sourceType string) bool {
	for _, item := range evidence {
		if item.SourceType == sourceType {
			return true
		}
	}
	return false
}

func StructuredResultFailure(detail string) bool {
	detail = strings.ToLower(strings.TrimSpace(detail))
	return strings.Contains(detail, "structured slack response is invalid") ||
		strings.Contains(detail, "structured agent report is invalid") ||
		strings.Contains(detail, "completion assessment") ||
		strings.Contains(detail, "blocked completion")
}

func ParseWatchDecision(message string, now time.Time) (WatchDecision, error) {
	trimmed := strings.TrimSpace(message)
	if err := RejectMultipleJSONObjects(trimmed); err != nil {
		return WatchDecision{}, err
	}
	decision, err := DecodeWatchDecision(trimmed, now)
	if err == nil {
		return decision, nil
	}
	if strings.HasPrefix(trimmed, "{") {
		if object, objectErr := FirstJSONObject(trimmed); objectErr == nil {
			if recovered, recoverErr := DecodeWatchDecision(object, now); recoverErr == nil {
				return recovered, nil
			}
		}
	}
	if start := strings.Index(trimmed, "{"); start >= 0 {
		if object, objectErr := FirstJSONObject(trimmed[start:]); objectErr == nil {
			if recovered, recoverErr := DecodeWatchDecision(object, now); recoverErr == nil {
				return recovered, nil
			}
		}
	}
	candidateErr := err
	for end := len(trimmed); end > 0; {
		index := strings.LastIndex(trimmed[:end], "{")
		if index < 0 {
			break
		}
		candidate := strings.TrimSpace(trimmed[index:])
		decision, err = DecodeWatchDecision(candidate, now)
		if err == nil {
			return decision, nil
		}
		// Decoding the cleanly extracted object says why the DECISION is bad;
		// decoding the raw candidate only says the text around it is not JSON.
		// Prefer the former. A model that fenced its reply and also invented a
		// field was reported as 'invalid character ...' — true of the fence,
		// useless about the field, and the correction retry that reads this
		// then asks the model to fix the wrong thing.
		if object, objectErr := FirstJSONObject(candidate); objectErr == nil {
			recovered, recoverErr := DecodeWatchDecision(object, now)
			if recoverErr == nil {
				return recovered, nil
			}
			if strings.Contains(object, `"action"`) {
				err = recoverErr
			}
		}
		if strings.Contains(candidate, `"action"`) {
			candidateErr = err
		}
		end = index
	}
	return WatchDecision{}, candidateErr
}

// WatchDecisionAction validates a persisted Coop transcript with the same
// production parser used during finalization and returns its terminal action.
// Local replay verification uses this instead of maintaining a second parser.

// WatchDecisionAction validates a persisted Coop transcript with the same
// production parser used during finalization and returns its terminal action.
// Local replay verification uses this instead of maintaining a second parser.
func WatchDecisionAction(message string) (string, error) {
	decision, err := ParseWatchDecision(message, time.Now().UTC())
	if err != nil {
		return "", err
	}
	return decision.Action, nil
}

func DecodeWatchDecision(message string, now time.Time) (WatchDecision, error) {
	normalized, err := NormalizeEmptyStructuredTimestamps(message)
	if err != nil {
		return WatchDecision{}, err
	}
	var decision WatchDecision
	if err := DecodeStrictJSON(normalized, &decision); err != nil {
		return WatchDecision{}, err
	}
	if err := ApplyWatchResultOperations(&decision); err != nil {
		return WatchDecision{}, err
	}
	NormalizeWatchDecisionCompletion(&decision)
	switch decision.Action {
	case "escalate":
		decision.Reason = strings.TrimSpace(decision.Reason)
		if decision.Reason == "" {
			return WatchDecision{}, errors.New("escalation decision has no reason")
		}
	case "ignore", "react":
	case "reply":
		if err := ValidateReplyDecision(&decision, now); err != nil {
			return WatchDecision{}, err
		}
	case "incident":
		decision.Title = strings.TrimSpace(decision.Title)
		if decision.Title == "" {
			return WatchDecision{}, errors.New("incident decision has no title")
		}
		if len(decision.Title) > 200 {
			return WatchDecision{}, errors.New("incident title exceeds 200 bytes")
		}
	default:
		return WatchDecision{}, fmt.Errorf("unknown action %q", decision.Action)
	}
	if decision.Action == "react" {
		reaction, err := NormalizeSlackReactionName(decision.Reaction)
		if err != nil {
			return WatchDecision{}, err
		}
		decision.Reaction = reaction
	}
	if err := RejectUnexpectedWatchFields(decision); err != nil {
		return WatchDecision{}, err
	}
	if err := ValidateWatchPublicationUpdates(&decision); err != nil {
		return WatchDecision{}, err
	}
	if err := ValidateAttentionAssessment(decision.Attention); err != nil {
		return WatchDecision{}, err
	}
	return decision, nil
}

// WatchDecisionPayload names every optional field a watch decision may carry.
// Each action declares which of them it may use, and anything else present is
// rejected. Keeping that in one table means adding a field to WatchDecision is
// a single-line change that every action is then checked against, instead of
// four hand-maintained boolean chains that quietly drift apart.

// WatchDecisionPayload names every optional field a watch decision may carry.
// Each action declares which of them it may use, and anything else present is
// rejected. Keeping that in one table means adding a field to WatchDecision is
// a single-line change that every action is then checked against, instead of
// four hand-maintained boolean chains that quietly drift apart.
var WatchDecisionPayload = []struct {
	name    string
	present func(WatchDecision) bool
}{
	{"reaction", func(d WatchDecision) bool { return d.Reaction != "" }},
	{"message", func(d WatchDecision) bool { return d.Message != "" }},
	{"followup_messages", func(d WatchDecision) bool { return len(d.FollowupMessages) != 0 }},
	{"title", func(d WatchDecision) bool { return d.Title != "" }},
	{"incident_title", func(d WatchDecision) bool { return d.IncidentTitle != "" }},
	{"task_title", func(d WatchDecision) bool { return d.TaskTitle != "" }},
	{"task_repository", func(d WatchDecision) bool { return d.TaskRepository != "" }},
	{"task_prompt", func(d WatchDecision) bool { return d.TaskPrompt != "" }},
	{"memory_offer", func(d WatchDecision) bool { return d.MemoryOffer != nil }},
	{"preference_offer", func(d WatchDecision) bool { return d.PreferenceOffer != nil }},
	{"rule_offer", func(d WatchDecision) bool { return d.RuleOffer != nil }},
	{"schedule_offer", func(d WatchDecision) bool { return d.ScheduleOffer != nil }},
	{"pending_approval", func(d WatchDecision) bool { return d.PendingApproval != nil }},
	{"alert_assessment", func(d WatchDecision) bool { return d.AlertAssessment != nil }},
	{"completion", func(d WatchDecision) bool { return d.Completion != nil }},
	{"evidence", func(d WatchDecision) bool { return len(d.Evidence) != 0 }},
	{"coverage", func(d WatchDecision) bool { return len(d.Coverage) != 0 }},
	{"visuals", func(d WatchDecision) bool { return len(d.Visuals) != 0 }},
	{"publication_updates", func(d WatchDecision) bool { return len(d.PublicationUpdates) != 0 }},
}

// WatchActionPayload declares the fields each action may carry, and the noun
// used when rejecting anything else. A reply carries almost everything and has
// its own richer rules, so it is validated separately.

// WatchActionPayload declares the fields each action may carry, and the noun
// used when rejecting anything else. A reply carries almost everything and has
// its own richer rules, so it is validated separately.
var WatchActionPayload = map[string]struct {
	noun    string
	allowed map[string]bool
}{
	"escalate": {noun: "escalation", allowed: map[string]bool{}},
	"ignore": {noun: "ignore", allowed: map[string]bool{
		"evidence": true, "coverage": true, "publication_updates": true,
	}},
	"react":    {noun: "react", allowed: map[string]bool{"reaction": true}},
	"incident": {noun: "incident", allowed: map[string]bool{"title": true, "evidence": true, "coverage": true}},
	"reply": {noun: "reply", allowed: map[string]bool{
		"message": true, "followup_messages": true, "incident_title": true,
		"task_title": true, "task_repository": true, "task_prompt": true,
		"memory_offer": true, "preference_offer": true, "rule_offer": true,
		"schedule_offer": true, "pending_approval": true, "alert_assessment": true,
		"completion": true, "evidence": true, "coverage": true, "visuals": true,
		"publication_updates": true,
	}},
}

func RejectUnexpectedWatchFields(decision WatchDecision) error {
	action, ok := WatchActionPayload[decision.Action]
	if !ok {
		return fmt.Errorf("unknown action %q", decision.Action)
	}
	for _, field := range WatchDecisionPayload {
		if action.allowed[field.name] || !field.present(decision) {
			continue
		}
		// An ignore decision may carry a completion only when it is a durable
		// background block that schedules its own recheck.
		if decision.Action == "ignore" && field.name == "completion" &&
			decision.Completion.Status == "blocked" && decision.Completion.Recheck != nil {
			continue
		}
		if decision.Action == "reply" {
			return fmt.Errorf("reply decision has an unexpected %s", field.name)
		}
		return fmt.Errorf("%s decision has unexpected fields", action.noun)
	}
	return nil
}

// BoundReplyDecisionFields enforces the size limits and the dependencies
// between the engineering-task fields. A task offer with a prompt but no
// repository is not something a person can accept — there is nowhere to run it.
func BoundReplyDecisionFields(d *WatchDecision) error {
	if len(d.Visuals) > 4 {
		return errors.New("reply decision references too many generated visuals")
	}
	if len(d.IncidentTitle) > 200 {
		return errors.New("incident offer title exceeds 200 bytes")
	}
	if len(d.TaskTitle) > 200 {
		return errors.New("engineering task offer title exceeds 200 bytes")
	}
	if len(d.TaskRepository) > 63 {
		return errors.New("engineering task repository exceeds 63 bytes")
	}
	if len(d.TaskPrompt) > 4000 {
		return errors.New("engineering task prompt exceeds 4000 bytes")
	}
	if d.TaskTitle == "" && d.TaskRepository != "" {
		return errors.New("task_repository requires task_title")
	}
	if d.TaskTitle == "" && d.TaskPrompt != "" {
		return errors.New("task_prompt requires task_title")
	}
	if d.TaskPrompt != "" && d.TaskRepository == "" {
		return errors.New("suggested engineering task requires task_repository")
	}
	return nil
}

// ValidateReplyOfferExclusivity keeps one reply from asking for two unrelated
// confirmations at once.
//
// The rule is about what a person can actually answer. "Should I open an
// incident, and also should I remember that you prefer thread replies?" has one
// button and two questions, so whichever they press means something Responder
// cannot determine. A pending approval is the strictest case: it is a governed
// action waiting on a decision, and nothing else belongs in that message.

// ValidateReplyOfferExclusivity keeps one reply from asking for two unrelated
// confirmations at once.
//
// The rule is about what a person can actually answer. "Should I open an
// incident, and also should I remember that you prefer thread replies?" has one
// button and two questions, so whichever they press means something Responder
// cannot determine. A pending approval is the strictest case: it is a governed
// action waiting on a decision, and nothing else belongs in that message.
func ValidateReplyOfferExclusivity(d *WatchDecision) error {
	if d.PendingApproval != nil &&
		(d.IncidentTitle != "" || d.TaskTitle != "" ||
			d.MemoryOffer != nil || d.PreferenceOffer != nil ||
			d.RuleOffer != nil || len(d.Visuals) != 0) {
		return errors.New(
			"pending approval cannot be combined with another offer or generated visual",
		)
	}
	if d.MemoryOffer != nil &&
		(d.IncidentTitle != "" || d.TaskTitle != "") {
		return errors.New(
			"reply decision cannot offer memory and work in the same response",
		)
	}
	offerCount := 0
	for _, present := range []bool{
		d.MemoryOffer != nil,
		d.PreferenceOffer != nil,
		d.RuleOffer != nil,
		d.ScheduleOffer != nil,
	} {
		if present {
			offerCount++
		}
	}
	if offerCount > 0 && d.IncidentTitle != "" {
		return errors.New(
			"reply decision cannot offer durable behavior and work in the same response",
		)
	}
	if d.TaskTitle != "" &&
		(d.MemoryOffer != nil || d.PreferenceOffer != nil ||
			d.RuleOffer != nil) {
		return errors.New(
			"reply decision cannot offer durable behavior and work in the same response",
		)
	}
	if offerCount > 0 && len(d.Visuals) > 0 {
		return errors.New("reply decision cannot combine durable behavior and generated visuals")
	}
	return nil
}

// ValidateReplyDecision owns the rules that only apply to a reply: the offer
// and visual exclusivity matrix, the engineering-task boundary, and the
// assessment validators. A reply is the only action that can carry all of
// them, which is why they are checked in one place rather than spread across
// the decoders.
func ValidateReplyDecision(d *WatchDecision, now time.Time) error {
	var err error
	d.Message, d.FollowupMessages, err = NormalizeReplySequence(
		d.Message,
		d.FollowupMessages,
	)
	if err != nil {
		return err
	}
	d.IncidentTitle = strings.TrimSpace(d.IncidentTitle)
	d.TaskTitle = strings.TrimSpace(d.TaskTitle)
	d.TaskRepository = strings.TrimSpace(d.TaskRepository)
	d.TaskPrompt = strings.TrimSpace(d.TaskPrompt)
	if d.Reaction != "" || d.Title != "" {
		return errors.New("reply decision has an unexpected title")
	}
	if err := BoundReplyDecisionFields(d); err != nil {
		return err
	}
	if err := ValidateReplyOfferExclusivity(d); err != nil {
		return err
	}
	if d.AlertAssessment != nil {
		if err := ValidateAlertAssessment(d.AlertAssessment); err != nil {
			return err
		}
	}
	if err := investigation.ValidateCompletion(d.Completion); err != nil {
		return err
	}
	if err := investigation.ValidateCapabilityGapEvidence(d.Completion, d.Evidence); err != nil {
		return err
	}
	d.Message, d.FollowupMessages = investigation.AppendCapabilityGuidance(
		d.Message,
		d.FollowupMessages,
		d.Completion,
	)
	d.Message, d.FollowupMessages, err = NormalizeReplySequence(
		d.Message,
		d.FollowupMessages,
	)
	if err != nil {
		return err
	}
	if d.TaskPrompt != "" {
		if !ValidSuggestedEngineeringTaskBoundary(*d) {
			return errors.New(
				"suggested engineering task requires a decision-ready result or an exact tool-failure blocker",
			)
		}
		if !WatchDecisionHasEvidenceSource(
			SanitizeEvidence(d.Evidence, "", "", "", now),
			"repository",
		) {
			return errors.New(
				"suggested engineering task requires repository evidence",
			)
		}
	}
	return nil
}

// ValidateWatchPublicationUpdates bounds and normalizes the external lifecycle
// events a decision may report.

// ValidateWatchPublicationUpdates bounds and normalizes the external lifecycle
// events a decision may report.
func ValidateWatchPublicationUpdates(d *WatchDecision) error {
	if len(d.PublicationUpdates) > 4 {
		return errors.New("decision contains too many publication updates")
	}
	for index := range d.PublicationUpdates {
		item := &d.PublicationUpdates[index]
		item.IncidentID = strings.TrimSpace(item.IncidentID)
		item.Kind = strings.TrimSpace(item.Kind)
		item.State = strings.TrimSpace(item.State)
		item.Reference = strings.TrimSpace(item.Reference)
		item.Summary = strings.TrimSpace(item.Summary)
		switch item.Kind {
		case "deployment", "terraform":
		default:
			return fmt.Errorf("publication update kind %q is invalid", item.Kind)
		}
		switch item.State {
		case "pending", "succeeded", "failed":
		default:
			return fmt.Errorf("publication update state %q is invalid", item.State)
		}
		if item.IncidentID == "" || item.Reference == "" || item.Summary == "" {
			return errors.New("publication update is incomplete")
		}
		if len(item.Reference) > 300 || len(item.Summary) > 1200 {
			return errors.New("publication update exceeds its bound")
		}
	}
	return nil
}

// NormalizeWatchDecisionCompletion repairs two common, unambiguous transport
// mistakes before strict validation. Alert verdicts describe the signal while
// completion verdicts describe the episode; confusing those enums must not
// discard an otherwise usable investigation. A blocked result cannot carry a
// verdict, so the verdict is simply ignored until host correction resolves the
// blocker or asks the model for a decision-ready completion.

// NormalizeWatchDecisionCompletion repairs two common, unambiguous transport
// mistakes before strict validation. Alert verdicts describe the signal while
// completion verdicts describe the episode; confusing those enums must not
// discard an otherwise usable investigation. A blocked result cannot carry a
// verdict, so the verdict is simply ignored until host correction resolves the
// blocker or asks the model for a decision-ready completion.
func NormalizeWatchDecisionCompletion(decision *WatchDecision) {
	if decision == nil || decision.Completion == nil {
		return
	}
	completion := decision.Completion
	completion.Status = strings.TrimSpace(completion.Status)
	completion.Verdict = strings.TrimSpace(completion.Verdict)
	if completion.Status == "blocked" {
		completion.Verdict = ""
		return
	}
	if completion.Status != "decision_ready" || decision.AlertAssessment == nil {
		return
	}
	switch completion.Verdict {
	case "confirmed_issue", "likely_issue":
		completion.Verdict = "degraded"
	case "not_issue":
		completion.Verdict = "healthy"
	case "unverified":
		completion.Verdict = "inconclusive"
	}
}

// NormalizeAppAlertCompletion fills the episode verdict only when the source
// is an external app alert. Human requests may carry an alert assessment while
// still using a direct-answer or task contract, so this inference must remain
// context-aware rather than living in the transport parser.

// NormalizeAppAlertCompletion fills the episode verdict only when the source
// is an external app alert. Human requests may carry an alert assessment while
// still using a direct-answer or task contract, so this inference must remain
// context-aware rather than living in the transport parser.
func NormalizeAppAlertCompletion(input core.SlackInput, decision *WatchDecision) {
	if decision == nil || input.Kind != "bot_message" ||
		!OperationalAlertEvent(input.Text) || decision.AlertAssessment == nil ||
		decision.Completion == nil || decision.Completion.Status != "decision_ready" ||
		strings.TrimSpace(decision.Completion.Verdict) != "" {
		return
	}
	switch decision.AlertAssessment.Verdict {
	case "confirmed_issue", "likely_issue":
		decision.Completion.Verdict = "degraded"
	case "not_issue":
		decision.Completion.Verdict = "healthy"
	case "unverified":
		decision.Completion.Verdict = "inconclusive"
	}
}

func ValidSuggestedEngineeringTaskBoundary(decision WatchDecision) bool {
	if decision.Completion == nil {
		return false
	}
	if decision.Completion.Status == "blocked" {
		return decision.Completion.BlockerKind == "tool_failure"
	}
	return decision.Completion.Status == "decision_ready"
}

func ValidateAlertAssessment(assessment *AlertAssessment) error {
	assessment.Verdict = strings.TrimSpace(assessment.Verdict)
	assessment.Impact = strings.TrimSpace(assessment.Impact)
	assessment.CauseStatus = strings.TrimSpace(assessment.CauseStatus)
	assessment.Cause = strings.TrimSpace(assessment.Cause)
	assessment.ImmediateAction = strings.TrimSpace(assessment.ImmediateAction)
	assessment.Verification = strings.TrimSpace(assessment.Verification)
	assessment.LongTermSolution = strings.TrimSpace(assessment.LongTermSolution)
	if len(assessment.Verdict) > 32 || len(assessment.Impact) > 2000 ||
		len(assessment.CauseStatus) > 32 || len(assessment.Cause) > 2000 ||
		len(assessment.ImmediateAction) > 2000 || len(assessment.Verification) > 2000 ||
		len(assessment.LongTermSolution) > 2000 {
		return errors.New("alert assessment exceeds its field bounds")
	}
	switch assessment.Verdict {
	case "confirmed_issue", "likely_issue":
		if assessment.Impact == "" || assessment.Cause == "" ||
			assessment.ImmediateAction == "" || assessment.Verification == "" ||
			assessment.LongTermSolution == "" {
			return errors.New(
				"confirmed or likely alert assessment requires impact, cause, immediate_action, verification, and long_term_solution",
			)
		}
		if assessment.CauseStatus != "identified" && assessment.CauseStatus != "bounded" {
			return errors.New(
				"confirmed or likely alert assessment requires cause_status identified or bounded",
			)
		}
	case "not_issue":
		if assessment.Impact == "" {
			return errors.New("not_issue alert assessment requires impact")
		}
	case "unverified":
		if assessment.Impact == "" || assessment.ImmediateAction == "" {
			return errors.New(
				"unverified alert assessment requires impact and the next verification in immediate_action",
			)
		}
	default:
		return errors.New(
			"alert assessment verdict must be confirmed_issue, likely_issue, not_issue, or unverified",
		)
	}
	return nil
}

func NormalizeSlackReactionName(name string) (string, error) {
	name = strings.ToLower(strings.TrimSpace(name))
	if len(name) >= 2 && strings.HasPrefix(name, ":") && strings.HasSuffix(name, ":") {
		name = name[1 : len(name)-1]
	}
	if !SlackReactionNamePattern.MatchString(name) {
		return "", errors.New(
			"react decision requires a valid Slack emoji name",
		)
	}
	return name, nil
}

func ValidateAttentionAssessment(value AttentionAssessment) error {
	if !value.Present() {
		return nil
	}
	switch value.Addressee {
	case "responder", "channel", "human", "unclear":
	default:
		return fmt.Errorf("unsupported attention addressee %q", value.Addressee)
	}
	for name, score := range map[string]int{
		"urgency": value.Urgency, "confidence": value.Confidence,
		"novelty": value.Novelty, "ownership": value.Ownership,
	} {
		if score < 0 || score > 3 {
			return fmt.Errorf("attention %s must be between 0 and 3", name)
		}
	}
	return nil
}

func DecodeStrictJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

type AgentReport struct {
	Message           string                              `json:"message"`
	FollowupMessages  []string                            `json:"followup_messages,omitempty"`
	Visuals           []core.GeneratedVisual              `json:"visuals,omitempty"`
	Evidence          []core.Evidence                     `json:"evidence,omitempty"`
	Coverage          []core.Coverage                     `json:"coverage,omitempty"`
	Memory            core.AgentMemory                    `json:"memory,omitempty"`
	MemoryOffer       *core.MemoryOffer                   `json:"memory_offer,omitempty"`
	PreferenceOffer   *core.PreferenceOffer               `json:"preference_offer,omitempty"`
	RuleOffer         *core.RuleOffer                     `json:"rule_offer,omitempty"`
	ScheduleOffer     *core.ScheduleOffer                 `json:"schedule_offer,omitempty"`
	PendingApproval   *core.EmisarApproval                `json:"pending_approval,omitempty"`
	Completion        *investigation.CompletionAssessment `json:"completion,omitempty"`
	Operations        []investigation.ResultOperation     `json:"operations,omitempty"`
	AppliedOperations []investigation.ResultOperation     `json:"-"`

	// LegacyShape
	// records a response that never used the typed protocol at all. Both exist
	// to answer one question before the legacy path is deleted: does anything
	// still depend on it?
	LegacyShape bool `json:"-"`
}

func NormalizeReplySequence(message string, followups []string) (string, []string, error) {
	message = strings.TrimSpace(message)
	if message == "" {
		return "", nil, errors.New("structured agent response has no message")
	}
	if len(followups) > MaxFollowupMessages {
		return "", nil, fmt.Errorf(
			"structured agent response has more than %d follow-up messages",
			MaxFollowupMessages,
		)
	}
	total := len(message)
	if len(message) > MaxReplyPartBytes {
		return "", nil, errors.New("structured agent response message exceeds 12 KiB")
	}
	normalized := make([]string, 0, len(followups))
	for _, followup := range followups {
		followup = strings.TrimSpace(followup)
		if followup == "" {
			return "", nil, errors.New("structured agent response has an empty follow-up message")
		}
		if len(followup) > MaxReplyPartBytes {
			return "", nil, errors.New("structured agent response follow-up exceeds 12 KiB")
		}
		total += len(followup)
		if total > MaxReplySequenceBytes {
			return "", nil, errors.New("structured agent response sequence exceeds 48 KiB")
		}
		normalized = append(normalized, followup)
	}
	return message, normalized, nil
}

func ReplySequence(message string, followups []string) []string {
	result := make([]string, 0, 1+len(followups))
	result = append(result, message)
	return append(result, followups...)
}

func ParseAgentReport(message string) (AgentReport, bool, error) {
	trimmed := strings.TrimSpace(message)
	if trimmed == "" {
		return AgentReport{}, false, errors.New("agent response is empty")
	}
	if err := RejectMultipleJSONObjects(trimmed); err != nil {
		return AgentReport{}, true, err
	}
	if strings.HasPrefix(trimmed, "{") {
		report, err := DecodeAgentReport(trimmed)
		if err == nil {
			return report, true, nil
		}
		if object, objectErr := FirstJSONObject(trimmed); objectErr == nil {
			if recovered, recoverErr := DecodeAgentReport(object); recoverErr == nil {
				return recovered, true, nil
			}
		}
		// Prose recovery is for broken JSON, not for a well-formed envelope
		// whose operation stream is invalid. Recovering there would accept the
		// turn while leaving the model believing its operations applied.
		if !errors.Is(err, ErrInvalidOperations) {
			if recovered, recoverErr := DecodeAgentMessage(trimmed); recoverErr == nil {
				return AgentReport{Message: recovered}, false, nil
			}
		}
		return AgentReport{}, true, err
	}
	// Prose-wrapped structured output must recover the outer result object. A
	// backwards scan can otherwise decode an inner completion payload as a full
	// report and silently lose its evidence and typed operation stream.
	if start := strings.Index(trimmed, "{"); start >= 0 {
		if object, objectErr := FirstJSONObject(trimmed[start:]); objectErr == nil {
			if recovered, recoverErr := DecodeAgentReport(object); recoverErr == nil {
				return recovered, true, nil
			}
		}
	}
	var candidateErr error
	for end := len(trimmed); end > 0; {
		index := strings.LastIndex(trimmed[:end], "{")
		if index < 0 {
			break
		}
		candidate := strings.TrimSpace(trimmed[index:])
		report, err := DecodeAgentReport(candidate)
		if err == nil {
			return report, true, nil
		}
		if object, objectErr := FirstJSONObject(candidate); objectErr == nil {
			if recovered, recoverErr := DecodeAgentReport(object); recoverErr == nil {
				return recovered, true, nil
			}
		}
		if recovered, recoverErr := DecodeAgentMessage(candidate); recoverErr == nil {
			return AgentReport{Message: recovered}, false, nil
		}
		if strings.Contains(candidate, `"message"`) {
			candidateErr = err
		}
		end = index
	}
	if candidateErr != nil {
		return AgentReport{}, true, candidateErr
	}
	return AgentReport{Message: trimmed}, false, nil
}

func FirstJSONObject(message string) (string, error) {
	decoder := json.NewDecoder(strings.NewReader(message))
	var value json.RawMessage
	if err := decoder.Decode(&value); err != nil {
		return "", err
	}
	remainder := strings.TrimSpace(message[decoder.InputOffset():])
	if strings.HasPrefix(remainder, "{") || strings.HasPrefix(remainder, "[") {
		return "", errors.New("response contains multiple JSON values")
	}
	trimmed := bytes.TrimSpace(value)
	if len(trimmed) == 0 || trimmed[0] != '{' || !json.Valid(trimmed) {
		return "", errors.New("first JSON value is not an object")
	}
	return string(trimmed), nil
}

func RejectMultipleJSONObjects(message string) error {
	start := strings.Index(message, "{")
	if start < 0 {
		return nil
	}
	_, err := FirstJSONObject(message[start:])
	if err != nil && strings.Contains(err.Error(), "multiple JSON values") {
		return err
	}
	return nil
}

func DecodeAgentReport(message string) (AgentReport, error) {
	normalized, err := NormalizeEmptyStructuredTimestamps(message)
	if err != nil {
		return AgentReport{}, fmt.Errorf("decode structured agent response: %w", err)
	}
	var report AgentReport
	if err := DecodeStrictJSON(normalized, &report); err != nil {
		return AgentReport{}, fmt.Errorf("decode structured agent response: %w", err)
	}
	if err := ApplyAgentResultOperations(&report); err != nil {
		return AgentReport{}, err
	}
	report.Message, report.FollowupMessages, err = NormalizeReplySequence(
		report.Message,
		report.FollowupMessages,
	)
	if err != nil {
		return AgentReport{}, err
	}
	if report.Message == NoConversationReply && len(report.FollowupMessages) > 0 {
		return AgentReport{}, errors.New(
			"structured agent response cannot combine no-reply with follow-up messages",
		)
	}
	offerCount := 0
	for _, present := range []bool{
		report.MemoryOffer != nil,
		report.PreferenceOffer != nil,
		report.RuleOffer != nil,
		report.ScheduleOffer != nil,
	} {
		if present {
			offerCount++
		}
	}
	if offerCount > 0 && len(report.Visuals) > 0 {
		return AgentReport{}, errors.New("structured agent response cannot combine a durable behavior offer with generated visuals")
	}
	if err := investigation.ValidateCompletion(report.Completion); err != nil {
		return AgentReport{}, err
	}
	if err := investigation.ValidateCapabilityGapEvidence(report.Completion, report.Evidence); err != nil {
		return AgentReport{}, err
	}
	report.Message, report.FollowupMessages = investigation.AppendCapabilityGuidance(
		report.Message,
		report.FollowupMessages,
		report.Completion,
	)
	report.Message, report.FollowupMessages, err = NormalizeReplySequence(
		report.Message,
		report.FollowupMessages,
	)
	if err != nil {
		return AgentReport{}, err
	}
	return report, nil
}

func NormalizeEmptyStructuredTimestamps(message string) ([]byte, error) {
	decoder := json.NewDecoder(strings.NewReader(message))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple JSON values")
		}
		return nil, err
	}
	// `verdict` belongs to completion (or alert_assessment), not the response
	// envelope. Older prompts and some models occasionally emit it at the root.
	// It carries no additional authority there, so discard it rather than
	// retrying an otherwise valid result until the episode disappears.
	if root, ok := value.(map[string]any); ok {
		delete(root, "verdict")
	}
	var visit func(any)
	visit = func(current any) {
		switch typed := current.(type) {
		case map[string]any:
			for key, child := range typed {
				if (key == "observed_at" || key == "created_at" || key == "expires_at") &&
					child == "" {
					delete(typed, key)
					continue
				}
				visit(child)
			}
		case []any:
			for _, child := range typed {
				visit(child)
			}
		}
	}
	visit(value)
	return json.Marshal(value)
}

func DecodeAgentMessage(message string) (string, error) {
	var fields map[string]json.RawMessage
	decoder := json.NewDecoder(strings.NewReader(message))
	if err := decoder.Decode(&fields); err != nil {
		return "", err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return "", errors.New("multiple JSON values")
		}
		return "", err
	}
	var result string
	if err := json.Unmarshal(fields["message"], &result); err != nil {
		return "", err
	}
	result = strings.TrimSpace(result)
	if result == "" {
		return "", errors.New("structured agent response has no message")
	}
	return result, nil
}

// recordResultProtocol notes whether a model result actually used the typed
// operation protocol.
//
// The fallback that silently re-read a failed typed fold as legacy free text
// is gone: an invalid operation stream is now a correction the model is told
// about. What remains worth counting is the plain-prose reply, which is a valid
// answer rather than a failure — Responder is in these channels to talk, and
// not every turn needs a typed envelope.

func SanitizeEvidence(
	items []core.Evidence,
	incidentID string,
	channelID string,
	sourceInput string,
	now time.Time,
) []core.Evidence {
	result := make([]core.Evidence, 0, min(len(items), 50))
	for _, item := range items[:min(len(items), 50)] {
		item.IncidentID = incidentID
		item.ChannelID = channelID
		item.SourceInput = sourceInput
		item.ClaimID = BoundedField(item.ClaimID, 120)
		item.Claim = BoundedField(item.Claim, 1000)
		item.Observation = BoundedField(item.Observation, 2000)
		item.Relation = strings.ToLower(BoundedField(item.Relation, 20))
		if item.Relation == "" {
			item.Relation = "supports"
		}
		item.HealthEffect = strings.ToLower(BoundedField(item.HealthEffect, 20))
		if item.HealthEffect == "" {
			item.HealthEffect = "none"
		}
		if !ValidEvidenceHealthEffect(item.HealthEffect) {
			item.HealthEffect = "unknown"
		}
		item.SourceType = BoundedField(item.SourceType, 80)
		item.SourceName = BoundedField(item.SourceName, 200)
		item.Target = BoundedField(item.Target, 300)
		item.ScopeNote = BoundedField(item.ScopeNote, 1000)
		item.Freshness = BoundedField(item.Freshness, 120)
		item.Confidence = BoundedField(item.Confidence, 40)
		item.SourceURL = SafeEvidenceURL(item.SourceURL)
		item.Metadata = BoundedMetadata(item.Metadata)
		item.Dimensions = BoundedMetadata(item.Dimensions)
		if !ValidEvidenceSourceType(item.SourceType) {
			item.SourceType = "other"
		}
		if !ValidConfidence(item.Confidence) {
			item.Confidence = ""
		}
		if item.ObservedAt.After(now.Add(5 * time.Minute)) {
			item.ObservedAt = time.Time{}
		}
		if (item.ClaimID == "" && item.Claim == "") ||
			(item.Observation == "" && len(item.Dimensions) == 0) ||
			item.SourceType == "" || item.SourceName == "" {
			continue
		}
		result = append(result, item)
	}
	return result
}

func ValidEvidenceHealthEffect(value string) bool {
	switch value {
	case "none", "risk", "degraded", "unhealthy", "unknown":
		return true
	default:
		return false
	}
}

func SanitizeCoverage(
	items []core.Coverage,
	incidentID string,
	channelID string,
	sourceInput string,
	now time.Time,
) []core.Coverage {
	result := make([]core.Coverage, 0, min(len(items), 30))
	for _, item := range items[:min(len(items), 30)] {
		item.IncidentID = incidentID
		item.ChannelID = channelID
		item.SourceInput = sourceInput
		item.Layer = BoundedField(item.Layer, 100)
		item.Status = BoundedField(item.Status, 40)
		item.Source = BoundedField(item.Source, 200)
		item.Detail = BoundedField(item.Detail, 1000)
		item.ClaimIDs = BoundedUniqueFields(item.ClaimIDs, 20, 120)
		if !ValidCoverageLayer(item.Layer) || !ValidCoverageStatus(item.Status) {
			continue
		}
		if item.ObservedAt.After(now.Add(5 * time.Minute)) {
			item.ObservedAt = time.Time{}
		}
		if item.Layer == "" || item.Status == "" {
			continue
		}
		result = append(result, item)
	}
	return result
}

func BoundedUniqueFields(values []string, limit int, bound int) []string {
	result := make([]string, 0, min(len(values), limit))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = BoundedField(value, bound)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
		if len(result) == limit {
			break
		}
	}
	return result
}

func ValidEvidenceSourceType(value string) bool {
	switch value {
	case "repository", "emisar", "monitoring", "slack", "other":
		return true
	default:
		return false
	}
}

func ValidConfidence(value string) bool {
	switch value {
	case "", "high", "medium", "low":
		return true
	default:
		return false
	}
}

func ValidCoverageLayer(value string) bool {
	return investigation.ValidCoverageLayer(value)
}

func ValidCoverageStatus(value string) bool {
	switch value {
	case "healthy", "degraded", "unhealthy", "unknown", "not_applicable":
		return true
	default:
		return false
	}
}

func BoundedField(value string, limit int) string {
	return core.BoundedText(value, limit)
}

func BoundedMetadata(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string)
	count := 0
	for key, value := range values {
		if count >= 30 {
			break
		}
		key = BoundedField(key, 100)
		value = BoundedField(value, 1000)
		if key != "" {
			result[key] = value
			count++
		}
	}
	return result
}

func SafeEvidenceURL(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return ""
	}
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String()
}

const MaxResultOperations = 100

// ErrInvalidOperations marks a failure to read the typed operation stream, as
// distinct from a failure to decode the surrounding JSON.
//
// The difference decides whether prose recovery is appropriate. A model that
// emitted broken JSON around a plain answer should still have its answer read.
// A model that emitted a well-formed envelope with an invalid operation stream
// must be told so — recovering its prose instead would read the same turn a
// second way and leave the model believing its operations were accepted.

// ErrInvalidOperations marks a failure to read the typed operation stream, as
// distinct from a failure to decode the surrounding JSON.
//
// The difference decides whether prose recovery is appropriate. A model that
// emitted broken JSON around a plain answer should still have its answer read.
// A model that emitted a well-formed envelope with an invalid operation stream
// must be told so — recovering its prose instead would read the same turn a
// second way and leave the model believing its operations were accepted.
var ErrInvalidOperations = errors.New("invalid typed operation stream")

func ApplyAgentResultOperations(report *AgentReport) error {
	if len(report.Operations) == 0 {
		report.LegacyShape = true
		return nil
	}
	// Operations are the authoritative transport. Models sometimes repeat their
	// final projection in the legacy fields as well; that redundancy is
	// harmless and simply discarded.
	report.Message = ""
	report.FollowupMessages = nil
	report.Visuals = nil
	report.Evidence = nil
	report.Coverage = nil
	report.Memory = core.AgentMemory{}
	report.MemoryOffer = nil
	report.PreferenceOffer = nil
	report.RuleOffer = nil
	report.ScheduleOffer = nil
	report.PendingApproval = nil
	report.Completion = nil
	err := FoldResultOperations(report.Operations, OperationTargets{
		message: &report.Message, followups: &report.FollowupMessages, visuals: &report.Visuals,
		evidence: &report.Evidence, coverage: &report.Coverage, memory: &report.Memory,
		memoryOffer: &report.MemoryOffer, preferenceOffer: &report.PreferenceOffer,
		ruleOffer: &report.RuleOffer, scheduleOffer: &report.ScheduleOffer,
		approval:   &report.PendingApproval,
		completion: &report.Completion,
	}, &report.AppliedOperations)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidOperations, err)
	}
	return nil
}

func ApplyWatchResultOperations(decision *WatchDecision) error {
	if len(decision.Operations) == 0 {
		decision.LegacyShape = true
		return nil
	}
	if decision.Action == "ignore" {
		for _, operation := range decision.Operations {
			if operation.Type == "update_memory" {
				return ApplySilentWatchMemoryOperation(decision)
			}
		}
	}
	// A complete_episode operation is itself an unambiguous reply decision. The
	// host owns that projection even if the model omitted action or left an old
	// ignore value beside the operation stream.
	decision.Action = "reply"
	decision.Message = ""
	decision.FollowupMessages = nil
	decision.Visuals = nil
	decision.IncidentTitle = ""
	decision.TaskTitle = ""
	decision.TaskRepository = ""
	decision.TaskPrompt = ""
	decision.Evidence = nil
	decision.Coverage = nil
	decision.Memory = core.AgentMemory{}
	decision.MemoryOffer = nil
	decision.PreferenceOffer = nil
	decision.RuleOffer = nil
	decision.ScheduleOffer = nil
	decision.PendingApproval = nil
	decision.AlertAssessment = nil
	decision.Completion = nil
	err := FoldResultOperations(decision.Operations, OperationTargets{
		message: &decision.Message, followups: &decision.FollowupMessages, visuals: &decision.Visuals,
		evidence: &decision.Evidence, coverage: &decision.Coverage, memory: &decision.Memory,
		memoryOffer: &decision.MemoryOffer, preferenceOffer: &decision.PreferenceOffer,
		ruleOffer: &decision.RuleOffer, scheduleOffer: &decision.ScheduleOffer,
		approval: &decision.PendingApproval, alert: &decision.AlertAssessment,
		completion:    &decision.Completion,
		incidentTitle: &decision.IncidentTitle, taskTitle: &decision.TaskTitle,
		taskRepository: &decision.TaskRepository, taskPrompt: &decision.TaskPrompt,
	}, &decision.AppliedOperations)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidOperations, err)
	}
	decision.Message = AppendFeedbackFollowup(decision.Message, decision.AppliedOperations)
	return nil
}

func ApplySilentWatchMemoryOperation(decision *WatchDecision) error {
	if len(decision.Operations) != 1 {
		return errors.New("ignore decision may contain exactly one update_memory operation")
	}
	operation := decision.Operations[0]
	if err := operation.Validate(); err != nil {
		return fmt.Errorf("result operation 1: %w", err)
	}
	if operation.Type != "update_memory" || operation.Memory == nil {
		return errors.New("ignore decision operations may only update conversation memory")
	}
	if strings.TrimSpace(decision.Message) != "" || len(decision.FollowupMessages) != 0 ||
		len(decision.Visuals) != 0 || strings.TrimSpace(decision.IncidentTitle) != "" ||
		strings.TrimSpace(decision.TaskTitle) != "" || len(decision.Evidence) != 0 ||
		len(decision.Coverage) != 0 || decision.MemoryOffer != nil ||
		decision.PreferenceOffer != nil || decision.RuleOffer != nil ||
		decision.ScheduleOffer != nil || decision.PendingApproval != nil ||
		decision.AlertAssessment != nil || decision.Completion != nil ||
		len(decision.PublicationUpdates) != 0 {
		return errors.New("silent memory update cannot include reply content or other result fields")
	}
	decision.Memory = *operation.Memory
	decision.AppliedOperations = []investigation.ResultOperation{operation}
	return nil
}

func AppendFeedbackFollowup(message string, operations []investigation.ResultOperation) string {
	for _, operation := range operations {
		if operation.Type != "record_feedback" || operation.Feedback == nil ||
			!operation.Feedback.NeedsFollowup {
			continue
		}
		question := strings.TrimSpace(operation.Feedback.FollowupQuestion)
		if question != "" && !strings.Contains(message, question) {
			message = strings.TrimSpace(message)
			if message == "" {
				return question
			}
			return message + "\n\n" + question
		}
	}
	return message
}

type OperationTargets struct {
	message         *string
	followups       *[]string
	visuals         *[]core.GeneratedVisual
	evidence        *[]core.Evidence
	coverage        *[]core.Coverage
	memory          *core.AgentMemory
	memoryOffer     **core.MemoryOffer
	preferenceOffer **core.PreferenceOffer
	ruleOffer       **core.RuleOffer
	scheduleOffer   **core.ScheduleOffer
	approval        **core.EmisarApproval
	alert           **AlertAssessment
	completion      **investigation.CompletionAssessment
	incidentTitle   *string
	taskTitle       *string
	taskRepository  *string
	taskPrompt      *string
}

func FoldResultOperations(
	operations []investigation.ResultOperation,
	target OperationTargets,
	applied *[]investigation.ResultOperation,
) error {
	if len(operations) > MaxResultOperations {
		return fmt.Errorf("result contains more than %d operations", MaxResultOperations)
	}
	seen := make(map[string]struct{}, len(operations))
	completed := false
	memoryUpdated := false
	for index, operation := range operations {
		operation.ID = strings.TrimSpace(operation.ID)
		operation.Type = strings.TrimSpace(operation.Type)
		if _, duplicate := seen[operation.ID]; duplicate {
			return fmt.Errorf("result operation %d has duplicate id %q", index+1, operation.ID)
		}
		seen[operation.ID] = struct{}{}
		if err := operation.Validate(); err != nil {
			return fmt.Errorf("result operation %d: %w", index+1, err)
		}
		switch operation.Type {
		case "record_evidence":
			if err := investigation.ValidateEvidence(*operation.Evidence); err != nil {
				return fmt.Errorf("result operation %q: %w", operation.ID, err)
			}
			*target.evidence = append(*target.evidence, *operation.Evidence)
		case "record_coverage":
			*target.coverage = append(*target.coverage, *operation.Coverage)
		case "report_progress":
			// Progress is projected from the episode event stream. It is not copied
			// into the final Slack report.
		case "plan_goal", "update_goal", "request_operator_input", "wait_external", "record_feedback":
			// These operations project from the episode event stream rather than
			// becoming fields in the final Slack response.
		case "request_approval":
			if *target.approval != nil {
				return fmt.Errorf("result operation %q duplicates request_approval", operation.ID)
			}
			*target.approval = operation.Approval
		case "offer_task":
			if operation.Task.Kind == "incident" {
				if target.incidentTitle == nil || *target.incidentTitle != "" {
					return fmt.Errorf("result operation %q duplicates or cannot offer an incident", operation.ID)
				}
				*target.incidentTitle = operation.Task.Title
			} else {
				if target.taskTitle == nil || *target.taskTitle != "" {
					return fmt.Errorf("result operation %q duplicates or cannot offer engineering work", operation.ID)
				}
				*target.taskTitle = operation.Task.Title
				*target.taskRepository = operation.Task.Repository
				*target.taskPrompt = operation.Task.Prompt
			}
		case "attach_visual":
			*target.visuals = append(*target.visuals, *operation.Visual)
		case "update_memory":
			if memoryUpdated {
				return fmt.Errorf("result operation %q duplicates update_memory", operation.ID)
			}
			memoryUpdated = true
			*target.memory = *operation.Memory
		case "offer_memory":
			if *target.memoryOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_memory", operation.ID)
			}
			*target.memoryOffer = operation.MemoryOffer
		case "offer_preference":
			if *target.preferenceOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_preference", operation.ID)
			}
			*target.preferenceOffer = operation.PreferenceOffer
		case "offer_rule":
			if *target.ruleOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_rule", operation.ID)
			}
			*target.ruleOffer = operation.RuleOffer
		case "offer_schedule":
			if *target.scheduleOffer != nil {
				return fmt.Errorf("result operation %q duplicates offer_schedule", operation.ID)
			}
			*target.scheduleOffer = operation.ScheduleOffer
		case "record_alert_assessment":
			if target.alert == nil || *target.alert != nil {
				return fmt.Errorf("result operation %q duplicates or cannot record an alert assessment", operation.ID)
			}
			*target.alert = operation.AlertAssessment
		case "complete_episode":
			if completed {
				return fmt.Errorf("result operation %q duplicates complete_episode", operation.ID)
			}
			completed = true
			value := operation.Completion
			*target.message = value.Message
			*target.followups = value.FollowupMessages
			*target.visuals = append(*target.visuals, value.Visuals...)
			*target.coverage = append(*target.coverage, value.Coverage...)
			if !memoryUpdated {
				*target.memory = value.Memory
			}
			if *target.memoryOffer == nil {
				*target.memoryOffer = value.MemoryOffer
			}
			if *target.preferenceOffer == nil {
				*target.preferenceOffer = value.PreferenceOffer
			}
			if *target.ruleOffer == nil {
				*target.ruleOffer = value.RuleOffer
			}
			if *target.scheduleOffer == nil {
				*target.scheduleOffer = value.ScheduleOffer
			}
			if target.alert != nil {
				if *target.alert == nil {
					*target.alert = value.AlertAssessment
				}
			}
			*target.completion = value.Completion
		}
		*applied = append(*applied, operation)
	}
	if !completed {
		return errors.New("typed result operations require exactly one complete_episode")
	}
	return nil
}
