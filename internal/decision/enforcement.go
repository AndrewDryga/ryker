package decision

import (
	"errors"
	"strings"
	"time"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// The turn state a decision is read against, and the rules that correct a
// decision before it is acted on.
//
// A correction is the host telling the model its result cannot be used and
// why. Keeping them beside the shapes they correct means the offline evaluation
// harness can check the same rules the runtime applies, against the same types,
// without importing the runtime.

type WatchTurnState struct {
	Lane                  string                         `json:"lane,omitempty"`
	AlertPolicy           string                         `json:"alert_policy,omitempty"`
	SessionID             string                         `json:"session_id"`
	SessionChannelID      string                         `json:"session_channel_id,omitempty"`
	Repository            string                         `json:"repository,omitempty"`
	RepositoryPinned      bool                           `json:"repository_pinned,omitempty"`
	Generation            int                            `json:"generation,omitempty"`
	ExpectedRevision      int64                          `json:"expected_revision,omitempty"`
	TurnID                string                         `json:"turn_id,omitempty"`
	ContextCaptured       bool                           `json:"context_captured,omitempty"`
	RecentMessages        []WatchContextMessage          `json:"recent_messages,omitempty"`
	Memory                core.AgentMemory               `json:"memory,omitempty"`
	RelatedSituations     []ConversationSituationContext `json:"related_situations,omitempty"`
	ReferencedThread      *ReferencedThreadContext       `json:"referenced_thread,omitempty"`
	ResponseThreadTS      string                         `json:"response_thread_ts,omitempty"`
	ReferencedThreadTS    string                         `json:"referenced_thread_ts,omitempty"`
	RouteCaptured         bool                           `json:"route_captured,omitempty"`
	EscalationReason      string                         `json:"escalation_reason,omitempty"`
	Prior                 OperationalMemoryContext       `json:"prior_operational_context,omitempty"`
	PriorCaptured         bool                           `json:"prior_captured,omitempty"`
	RulesCaptured         bool                           `json:"rules_captured,omitempty"`
	MatchedRules          []core.StandingRule            `json:"matched_rules,omitempty"`
	RuleAcknowledged      bool                           `json:"rule_acknowledged,omitempty"`
	ConversationFollowup  bool                           `json:"conversation_followup,omitempty"`
	OfferedIncidentTitle  string                         `json:"offered_incident_title,omitempty"`
	OfferedTaskTitle      string                         `json:"offered_task_title,omitempty"`
	OfferedTaskRepository string                         `json:"offered_task_repository,omitempty"`
	OfferedTaskPrompt     string                         `json:"offered_task_prompt,omitempty"`
	StructuredCorrections int                            `json:"structured_corrections,omitempty"`
	PendingStatusSet      bool                           `json:"pending_status_set,omitempty"`
	PendingStatusAt       int64                          `json:"pending_status_at,omitempty"`
	FailureDetail         string                         `json:"failure_detail,omitempty"`
	ApprovalContinuation  bool                           `json:"approval_continuation,omitempty"`
	DecisionSourceID      string                         `json:"decision_source_id,omitempty"`
	ReplyDeliveryID       string                         `json:"reply_delivery_id,omitempty"`
	PublicationsCaptured  bool                           `json:"publications_captured,omitempty"`
	ActivePublications    []core.PublicationContext      `json:"active_publications,omitempty"`
	RecheckOriginRunID    string                         `json:"recheck_origin_run_id,omitempty"`
	RecheckKey            string                         `json:"recheck_key,omitempty"`
	RecheckAttempt        int                            `json:"recheck_attempt,omitempty"`
}

type WatchContextMessage struct {
	MessageTS         string                   `json:"message_ts"`
	ThreadTS          string                   `json:"thread_ts,omitempty"`
	MessageLink       string                   `json:"message_link,omitempty"`
	SenderID          string                   `json:"sender_id"`
	SenderType        string                   `json:"sender_type"`
	Text              string                   `json:"text"`
	Attachments       []WatchContextAttachment `json:"attachments,omitempty"`
	Reactions         []WatchContextReaction   `json:"reactions,omitempty"`
	MentionsResponder bool                     `json:"mentions_responder,omitempty"`
	RequestedBy       string                   `json:"requested_by,omitempty"`
	Continuation      bool                     `json:"conversation_continuation,omitempty"`
	Target            bool                     `json:"target,omitempty"`
}

type WatchContextReaction struct {
	Name            string   `json:"name"`
	Count           int      `json:"count"`
	UserIDs         []string `json:"user_ids,omitempty"`
	Change          string   `json:"change,omitempty"`
	TargetMessageTS string   `json:"target_message_ts,omitempty"`
}

type WatchContextAttachment struct {
	Name      string `json:"name"`
	MediaType string `json:"media_type"`
	Size      int64  `json:"size"`
}

func EnforceAttentionPolicy(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
	replyThreshold int,
	reactionThreshold int,
) WatchDecision {
	// Once an app alert has been investigated into a typed assessment, its
	// result is the reason the channel policy exists. In particular, recovery
	// updates are naturally low urgency and must not disappear just because the
	// generic ambient-conversation threshold is higher than their attention
	// score. Non-actionable lifecycle noise is suppressed before this point.
	if input.Kind == "bot_message" && state.AlertPolicy != "" &&
		decision.Action == "reply" && decision.AlertAssessment != nil &&
		OperationalAlertEvent(input.Text) {
		return decision
	}
	if !decision.Attention.Present() {
		switch {
		case decision.Action == "react":
			return SuppressWatchDecision(
				decision,
				"host attention policy suppressed a reaction without an assessment",
			)
		case decision.Action == "reply" && !WatchInputTargeted(input, state):
			return SuppressWatchDecision(
				decision,
				"host attention policy suppressed an ambient reply without an assessment",
			)
		default:
			return decision
		}
	}
	targeted := WatchInputTargeted(input, state)
	explicitlyTargeted := WatchInputExplicitlyTargeted(input, state)
	humanAddressee := decision.Attention.Addressee == "human"
	insufficient := false
	switch decision.Action {
	case "reply":
		insufficient = (!explicitlyTargeted && humanAddressee) ||
			(!targeted && decision.Attention.Score() < replyThreshold)
	case "react":
		insufficient = humanAddressee ||
			decision.Attention.Score() < reactionThreshold
	}
	if !insufficient {
		return decision
	}
	return SuppressWatchDecision(
		decision,
		"host attention policy suppressed a low-value interruption",
	)
}

func SuppressWatchDecision(decision WatchDecision, reason string) WatchDecision {
	decision.Action = "ignore"
	decision.Reaction = ""
	decision.Message = ""
	decision.FollowupMessages = nil
	decision.Visuals = nil
	decision.Title = ""
	decision.IncidentTitle = ""
	decision.TaskTitle = ""
	decision.TaskRepository = ""
	decision.TaskPrompt = ""
	decision.MemoryOffer = nil
	decision.PreferenceOffer = nil
	decision.RuleOffer = nil
	decision.ScheduleOffer = nil
	decision.PendingApproval = nil
	decision.AlertAssessment = nil
	decision.Completion = nil
	decision.Reason = strings.TrimSpace(
		decision.Reason + "; " + reason,
	)
	return decision
}

func StandingRuleIncidentAsReply(decision WatchDecision, offerIncident bool) WatchDecision {
	title := strings.TrimSpace(decision.Title)
	message := strings.TrimSpace(decision.Reason)
	if message == "" {
		message = title
	}
	if title != "" && !strings.Contains(strings.ToLower(message), strings.ToLower(title)) {
		message = "**" + title + "**\n\n" + message
	}
	decision.Action = "reply"
	decision.Message = message
	if !decision.Attention.Present() {
		decision.Attention = AttentionAssessment{
			Addressee: "channel", Urgency: 3, Confidence: 3, Novelty: 3, Ownership: 2,
		}
	}
	if offerIncident {
		decision.IncidentTitle = title
	}
	decision.Title = ""
	decision.Memory.SituationSummary = title
	decisions := make([]string, 0, len(decision.Memory.Decisions)+1)
	for _, item := range decision.Memory.Decisions {
		if !strings.Contains(strings.ToLower(item), "incident") {
			decisions = append(decisions, item)
		}
	}
	if offerIncident {
		decisions = append(decisions,
			"Offer incident coordination for operator confirmation.",
		)
	} else {
		decisions = append(decisions,
			"Continue this alert's investigation in its source thread.",
		)
	}
	decision.Memory.Decisions = decisions
	decision.Reason = strings.TrimSpace(
		decision.Reason + "; host routed the matched standing-rule result through the channel alert policy",
	)
	return decision
}

func WatchDecisionCorrection(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
	correlate Correlator,
) string {
	return WatchDecisionCorrectionAt(input, state, decision, time.Now().UTC(), correlate)
}

// AlertAssessmentCorrection holds a matched operational alert to the standard
// an operator needs: a verdict backed by a fresh observation, reconciled
// against the repository that declares what should be running.
//
// The recovery case is the one worth reading twice. A resolved alert with fresh
// evidence that the condition cleared must be reported as decision-ready, not
// blocked — "the alert recovered but I could not fully investigate" is
// technically honest and practically useless, and it leaves the earlier failure
// message open forever.

// AlertAssessmentCorrection holds a matched operational alert to the standard
// an operator needs: a verdict backed by a fresh observation, reconciled
// against the repository that declares what should be running.
//
// The recovery case is the one worth reading twice. A resolved alert with fresh
// evidence that the condition cleared must be reported as decision-ready, not
// blocked — "the alert recovered but I could not fully investigate" is
// technically honest and practically useless, and it leaves the earlier failure
// message open forever.
func AlertAssessmentCorrection(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
	now time.Time,
) string {
	if state.FailureDetail != "" && decision.Action != "reply" {
		return "the prior alert assessment was incomplete; continue that investigation and " +
			"return its decision-ready reply instead of abandoning it"
	}
	if decision.Action == "incident" {
		return "a matched operational-alert rule requires an in-place read-only investigation; " +
			"return reply with a decision-ready alert assessment, never incident"
	}
	if decision.Action == "reply" {
		if decision.AlertAssessment == nil {
			return "the alert reply has no alert_assessment; continue the read-only investigation " +
				"until you can state a verdict, impact, immediate action, and durable solution"
		}
		evidence := SanitizeEvidence(decision.Evidence, "", "", "", now)
		recovered := decision.AlertAssessment.Verdict == "not_issue" &&
			OperationalAlertResolvedEvent(input.Text)
		if recovered && HasFreshOperationalEvidence(evidence, now) &&
			decision.Completion != nil && decision.Completion.Status == "blocked" {
			return "fresh evidence verifies that the exact alert condition recovered; return " +
				"decision_ready with the healthy verdict, say plainly what completed, and close " +
				"the earlier alert without broadening this into a platform-health assessment"
		}
		if !recovered && !WatchDecisionHasEvidenceSource(evidence, "repository") {
			return "the alert reply does not reconcile the live signal with declared repository " +
				"topology; inspect the configured repository before deciding"
		}
		if !HasFreshOperationalEvidence(evidence, now) {
			return "the alert reply has no fresh Emisar or monitoring observation; use the " +
				"available read-only operational tools and verify the current state before deciding"
		}
	}
	return ""
}

// AlertPolicyCorrection applies the extra standard a channel opts into when its
// alert policy is anything other than automatic: terminal app events get an
// investigated reply with a verdict, not a reaction and not an incident room.

// AlertPolicyCorrection applies the extra standard a channel opts into when its
// alert policy is anything other than automatic: terminal app events get an
// investigated reply with a verdict, not a reaction and not an incident room.
func AlertPolicyCorrection(input core.SlackInput, decision WatchDecision) string {
	if ExternalAppEventRequiresDecision(input.Text) && decision.Action != "reply" {
		return "this terminal or actionable app event requires an evidence-backed in-place " +
			"alert assessment and reply; investigate the exact event instead of ignoring it " +
			"or reducing it to a reaction"
	}
	if decision.Action == "incident" {
		return "this channel requires an evidence-backed in-place alert assessment; " +
			"continue the read-only investigation and return reply with typed evidence, " +
			"coverage, and a completion verdict instead of reducing the result to incident admission"
	}
	if ExternalAppEventRequiresDecision(input.Text) && decision.Action == "reply" &&
		(decision.Completion == nil || strings.TrimSpace(decision.Completion.Verdict) == "") {
		return "this terminal or actionable app event has no completion verdict; establish " +
			"the exact state, impact, cause or boundary, and concrete next action before finishing"
	}
	return ""
}

func WatchDecisionCorrectionAt(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
	now time.Time,
	correlate Correlator,
) string {
	if input.Kind == "bot_message" && decision.Action == "ignore" &&
		OperationalAlertResolvedEvent(input.Text) &&
		HasPriorCorrelatedFiringAlert(input, state.RecentMessages, correlate) {
		return "this resolved update closes a firing alert whose investigation was already admitted; " +
			"finish that investigation and return one concise evidence-backed closure that distinguishes " +
			"metric recovery from service recovery instead of discarding the earlier failure"
	}
	requiresAlertAssessment := MatchedOperationalAlertRule(state.MatchedRules) ||
		(input.Kind == "bot_message" && state.AlertPolicy != "" &&
			OperationalAlertEvent(input.Text) && !ExternalCoordinationOnlyEvent(input.Text))
	if requiresAlertAssessment {
		if correction := AlertAssessmentCorrection(input, state, decision, now); correction != "" {
			return correction
		}
	}
	if input.Kind == "bot_message" && state.AlertPolicy != "" &&
		state.AlertPolicy != "automatic" {
		if correction := AlertPolicyCorrection(input, decision); correction != "" {
			return correction
		}
	}
	if RequestedConversationLocation(input.Text) != ConversationLocationFollow &&
		!LocationOnlyRequest(input.Text) &&
		decision.Action != "reply" &&
		decision.Action != "incident" &&
		!(state.Lane == "conversation" && decision.Action == "escalate") {
		return "the operator combined a conversation-location change with new work; " +
			"answer the new work and honor the requested response location"
	}
	if decision.Action == "ignore" &&
		WatchInputTargeted(input, state) &&
		decision.Attention.Addressee == "responder" {
		return "the target is an active conversation follow-up addressed to Emisar; " +
			"answer the current message instead of treating it as a duplicate of an earlier turn"
	}
	return ""
}

// Correlator maps an inbound message to the stable identity of the operational
// stream it belongs to. It is injected rather than implemented here: how two
// alerts are recognized as the same stream is a routing concern, and the
// decision layer only needs to be told the answer.
type Correlator func(core.SlackInput) string

// HasPriorCorrelatedFiringAlert reports whether an earlier message in this
// conversation was a firing alert for the same operational stream.
func HasPriorCorrelatedFiringAlert(
	input core.SlackInput,
	messages []WatchContextMessage,
	correlate Correlator,
) bool {
	key := correlate(input)
	if key == "" {
		return false
	}
	for index := len(messages) - 1; index >= 0; index-- {
		message := messages[index]
		if message.Target || message.SenderType != "external_app" ||
			!OperationalAlertEvent(message.Text) ||
			OperationalAlertResolvedEvent(message.Text) {
			continue
		}
		candidate := core.SlackInput{
			Kind: "bot_message", UserID: message.SenderID, Text: message.Text,
		}
		if correlate(candidate) == key {
			return true
		}
	}
	return false
}

func AlertReplyLanguageCorrectionWithContext(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
) string {
	if input.Kind != "bot_message" || decision.Action != "reply" ||
		!OperationalAlertEvent(input.Text) {
		return ""
	}
	message := strings.TrimSpace(decision.Message)
	opening := strings.ToLower(strings.TrimLeft(message, "#*_>` \t\r\n"))
	for _, prefix := range []string{
		"this alert", "the alert", "this resolution", "the resolution",
		"this notification", "the notification", "this signal", "the signal",
	} {
		if strings.HasPrefix(opening, prefix) {
			return "rewrite the alert reply for an operator: open with the affected service or " +
				"component and its plain current state, then explain any mismatch with the app's " +
				"status and give one concrete next action with its success check"
		}
	}
	normalized := strings.ToLower(strings.Join(strings.Fields(message), " "))
	if strings.Contains(normalized, "acknowledg") && EpisodeContainsAny(
		normalized,
		"did not restore", "didn't restore", "did not fix", "does not fix", "did not recover",
	) {
		return "remove the acknowledgement narration; acknowledgement is coordination metadata, " +
			"not remediation, so say only what fresh evidence establishes about the service and what " +
			"useful action follows"
	}
	if EpisodeContainsAny(normalized, "confirmed issue", "likely issue", "not an issue") {
		return "remove the typed alert-verdict label from the Slack prose; open with the exact " +
			"plain condition, such as behind schedule, still down, or recovered, then say whether " +
			"anyone needs to act now"
	}
	for _, phrase := range []string{
		"alert split", "alert family", "alert families", "workload recovery",
		"exporter-deficit", "lifecycle boundary", "terminal notification",
		"alert path", "host, scheduler, and workload", "scheduler and workload layers",
		"control-plane state", "exporter registrations", "fault remains bounded",
		"remains bounded to", "allocation state",
	} {
		if strings.Contains(normalized, phrase) {
			return "rewrite the alert reply in common operational language; remove monitoring and " +
				"workflow shorthand such as `" + phrase + "`, say what is actually broken, why the " +
				"visible status may be misleading, and what to do next"
		}
	}
	technicalTerms := 0
	for _, term := range []string{
		"consul", "registration", "nomad allocation", "service discovery",
		"exporter", "scheduler", "control plane", "control-plane",
	} {
		if strings.Contains(normalized, term) {
			technicalTerms++
		}
	}
	if technicalTerms > 1 {
		return "rewrite the alert reply for a teammate, not an infrastructure diagram: use at " +
			"most one necessary technical term and explain it in common words; say whether the " +
			"service works, what monitoring can see, and whether anyone needs to act"
	}
	wordCount := len(strings.Fields(message))
	resolved := strings.Contains(
		strings.ToLower(strings.Join(strings.Fields(input.Text), " ")), "resolved",
	)
	recovered := decision.AlertAssessment != nil &&
		decision.AlertAssessment.Verdict == "not_issue"
	if decision.Completion != nil && decision.Completion.Verdict == "healthy" {
		recovered = true
	}
	if resolved && recovered {
		if link := PriorFiringMessageLink(state.RecentMessages); link != "" &&
			!strings.Contains(message, link) {
			return "rewrite this recovered-alert update as a compact closure and link the earlier " +
				"firing message using its exact message_link `" + link + "`; say plainly what " +
				"completed and omit unrelated healthy inventory"
		}
		if wordCount > 60 {
			return "rewrite this recovered-alert update as a compact closure: say what recovered and " +
				"link the earlier firing message when its exact message_link is present in recent context; " +
				"remove the normal-system inventory, no-op instructions, and hypothetical future tuning"
		}
	}
	if !resolved && wordCount > 90 {
		return "edit this active-alert update down to the decision-useful delta: current impact, the " +
			"evidence that changes the decision, a relevant known fix or rollout, and only the action " +
			"needed now; keep background healthy evidence in the ledger"
	}
	return ""
}

func PriorFiringMessageLink(messages []WatchContextMessage) string {
	for index := len(messages) - 1; index >= 0; index-- {
		message := messages[index]
		if message.SenderType != "external_app" || message.MessageLink == "" ||
			!OperationalAlertEvent(message.Text) || OperationalAlertResolvedEvent(message.Text) {
			continue
		}
		return message.MessageLink
	}
	return ""
}

func EnforceRecoveredAlertLink(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
) (WatchDecision, bool) {
	if input.Kind != "bot_message" || decision.Action != "reply" ||
		!OperationalAlertResolvedEvent(input.Text) || decision.AlertAssessment == nil ||
		decision.AlertAssessment.Verdict != "not_issue" {
		return decision, false
	}
	link := PriorFiringMessageLink(state.RecentMessages)
	if link == "" || strings.Contains(decision.Message, link) {
		return decision, false
	}
	decision.Message = strings.TrimSpace(decision.Message) +
		"\n\nClosing [the earlier alert](" + link + ")."
	return decision, true
}

func OperationalAlertResolvedEvent(text string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(text), " "))
	return EpisodeContainsAny(
		normalized,
		"resolved", "recovered", "recovery", "returned to normal", "alert closed",
	)
}

func ExternalAppEventRequiresDecision(text string) bool {
	text = strings.ToLower(strings.Join(strings.Fields(text), " "))
	return EpisodeContainsAny(
		text, "errored", "failed", "failure", "firing", "critical", "warning",
	)
}

func MatchedOperationalAlertRule(rules []core.StandingRule) bool {
	for _, rule := range rules {
		if rule.Trigger == "operational_alert" && rule.Action == "triage_alert" {
			return true
		}
	}
	return false
}

func HasFreshOperationalEvidence(evidence []core.Evidence, now time.Time) bool {
	for _, item := range evidence {
		if item.SourceType != "emisar" && item.SourceType != "monitoring" {
			continue
		}
		if item.ObservedAt.IsZero() || item.ObservedAt.After(now.Add(5*time.Minute)) {
			continue
		}
		if now.Sub(item.ObservedAt) <= 30*time.Minute {
			return true
		}
	}
	return false
}

func DecodeWatchState(data []byte) (WatchTurnState, error) {
	if len(data) == 0 {
		return WatchTurnState{}, nil
	}
	var state WatchTurnState
	if err := DecodeStrictJSON(data, &state); err != nil {
		return WatchTurnState{}, err
	}
	if state.SessionID == "" && (state.ExpectedRevision != 0 || state.TurnID != "") {
		return WatchTurnState{}, errors.New("watch turn state has no session ID")
	}
	return state, nil
}

func WatchInputTargeted(input core.SlackInput, state WatchTurnState) bool {
	return WatchInputExplicitlyTargeted(input, state) || state.ConversationFollowup
}

func WatchInputExplicitlyTargeted(input core.SlackInput, state WatchTurnState) bool {
	return input.Kind == "direct" || input.Kind == "mention" ||
		input.Kind == "shortcut" || len(state.MatchedRules) > 0 ||
		RequestedConversationLocation(input.Text) != ConversationLocationFollow
}

func EpisodeDiagnosisCorrection(
	episode core.WorkEpisode,
	action string,
	coverage []core.Coverage,
	assessment *AlertAssessment,
	completion *investigation.CompletionAssessment,
) string {
	if action != "reply" || (episode.Effort != core.EffortOperationalAssessment &&
		episode.Effort != core.EffortIncidentInvestigation) {
		return ""
	}
	activeDegradation := false
	for _, item := range coverage {
		if item.Status == "degraded" || item.Status == "unhealthy" {
			activeDegradation = true
			break
		}
	}
	if !activeDegradation {
		return ""
	}
	if completion != nil && completion.Status == "blocked" {
		return ""
	}
	if assessment == nil {
		return "the deep work episode found active degradation but has no diagnostic closure; continue until the affected scope, cause boundary, mitigation, and verification are established"
	}
	if assessment.Verdict != "confirmed_issue" && assessment.Verdict != "likely_issue" {
		return "degraded or unhealthy coverage conflicts with an alert assessment that does not identify an active issue; reconcile the evidence before finishing"
	}
	if assessment.CauseStatus != "identified" && assessment.CauseStatus != "bounded" {
		return "the active issue has no identified or bounded cause; continue through available logs, metrics, traces, repository context, and dependencies instead of assigning that investigation to the operator"
	}
	if strings.TrimSpace(assessment.Cause) == "" {
		return "the active issue has no actionable cause boundary; continue the diagnosis or return an exact external blocker"
	}
	if strings.TrimSpace(assessment.Verification) == "" {
		return "the active issue has no fresh verification plan for its mitigation; continue until the result is operationally testable"
	}
	if AlertActionIsUnfinishedInvestigation(assessment.ImmediateAction) {
		return "the active alert's immediate action is still an investigative handoff; perform the available read-only inspection now, then recommend an actual mitigation or return an exact external blocker"
	}
	return ""
}

func AlertActionIsUnfinishedInvestigation(action string) bool {
	action = strings.ToLower(strings.TrimSpace(action))
	action = strings.TrimLeft(action, "*_>` -")
	for _, prefix := range []string{
		"check ", "inspect ", "investigate ", "look at ", "query ", "review ",
		"trace ", "determine ", "identify ",
	} {
		if strings.HasPrefix(action, prefix) {
			return true
		}
	}
	return false
}

type ReferencedThreadContext struct {
	ThreadTS       string                `json:"thread_ts"`
	LastMessageTS  string                `json:"last_message_ts,omitempty"`
	Summary        core.AgentMemory      `json:"summary,omitempty"`
	RecentMessages []WatchContextMessage `json:"recent_messages,omitempty"`
}

type ConversationSituationContext struct {
	ChannelID    string           `json:"channel_id"`
	ChannelName  string           `json:"channel_name,omitempty"`
	ThreadTS     string           `json:"thread_ts,omitempty"`
	Repository   string           `json:"repository"`
	Relationship string           `json:"relationship"`
	Summary      core.AgentMemory `json:"summary"`
	UpdatedAt    string           `json:"updated_at"`
}

type OperationalMemoryContext struct {
	ConfirmedMemory []MemoryPromptEntry        `json:"operator_confirmed_memory,omitempty"`
	DreamedMemory   []DreamedMemoryPromptEntry `json:"automatically_synthesized_continuity,omitempty"`
	RecentEvidence  []EvidencePromptEntry      `json:"recent_same_channel_evidence,omitempty"`
	Preferences     []PreferencePromptEntry    `json:"responder_preferences,omitempty"`
}

func RequestedConversationLocation(text string) ConversationLocation {
	normalized := NormalizeLocationRequest(text)
	for _, phrase := range []string{
		"switch to channel",
		"switch to the channel",
		"continue in channel",
		"continue in the channel",
		"back to channel",
		"back to the channel",
		"reply in channel",
		"reply in the channel",
		"move this to channel",
		"move this to the channel",
	} {
		if strings.Contains(normalized, phrase) {
			return ConversationLocationChannel
		}
	}
	for _, phrase := range []string{
		"switch to thread",
		"switch to a thread",
		"continue in thread",
		"continue in the thread",
		"continue in a thread",
		"reply in thread",
		"reply in the thread",
		"move this to thread",
		"move this to a thread",
		"take this to thread",
		"take this to a thread",
		"use a thread",
		"back to that thread",
		"reply in that thread",
		"post back to that thread",
		"post it back to that thread",
		"post hi back to that thread",
		"not pollute the channel",
		"not pollute channel",
	} {
		if strings.Contains(normalized, phrase) {
			return ConversationLocationThread
		}
	}
	return ConversationLocationFollow
}

func LocationOnlyRequest(text string) bool {
	normalized := NormalizeLocationRequest(text)
	normalized = strings.TrimPrefix(normalized, "lets ")
	normalized = strings.TrimPrefix(normalized, "please ")
	normalized = strings.TrimSuffix(normalized, " please")
	switch normalized {
	case "switch to channel",
		"switch to the channel",
		"continue in channel",
		"continue in the channel",
		"back to channel",
		"back to the channel",
		"reply in channel",
		"reply in the channel",
		"switch to thread",
		"switch to a thread",
		"continue in thread",
		"continue in the thread",
		"continue in a thread",
		"reply in thread",
		"reply in the thread",
		"move this to thread",
		"move this to a thread",
		"take this to thread",
		"take this to a thread",
		"use a thread",
		"switch to thread not to pollute channel",
		"switch to a thread not to pollute the channel",
		"continue in thread not to pollute channel",
		"continue in a thread not to pollute the channel",
		"not pollute the channel",
		"not pollute channel":
		return true
	default:
		return false
	}
}

// ExternalCoordinationOnlyEvent identifies app updates that change who owns or
// has seen an incident without changing the underlying system state. They remain
// available in Slack context and the audit log, but do not deserve a second
// investigation or a public explanation of what acknowledgement means.
func ExternalCoordinationOnlyEvent(text string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(text), " "))
	if normalized == "" {
		return false
	}
	return strings.Contains(normalized, "incident acknowledged") ||
		strings.Contains(normalized, "incident was acknowledged") ||
		(strings.Contains(normalized, " acknowledged ") &&
			strings.Contains(normalized, " incident"))
}

type DreamedMemoryPromptEntry struct {
	Scope       string           `json:"scope"`
	PeriodStart string           `json:"period_start"`
	PeriodEnd   string           `json:"period_end"`
	Sources     int              `json:"source_summary_count"`
	SourceRefs  []string         `json:"source_refs,omitempty"`
	Summary     core.AgentMemory `json:"summary"`
}

type MemoryPromptEntry struct {
	Scope          string `json:"scope"`
	Subject        string `json:"subject"`
	Predicate      string `json:"predicate"`
	Value          string `json:"value"`
	SourceRevision string `json:"source_revision,omitempty"`
	ExpiresAt      string `json:"expires_at"`
}

type EvidencePromptEntry struct {
	ID          string `json:"id"`
	Claim       string `json:"claim"`
	Observation string `json:"observation"`
	SourceType  string `json:"source_type"`
	SourceName  string `json:"source_name"`
	Target      string `json:"target,omitempty"`
	ObservedAt  string `json:"observed_at,omitempty"`
	Freshness   string `json:"freshness,omitempty"`
	Confidence  string `json:"confidence,omitempty"`
}

type PreferencePromptEntry struct {
	Scope     string `json:"scope"`
	Name      string `json:"name"`
	Value     string `json:"value"`
	ExpiresAt string `json:"expires_at"`
}

type ConversationLocation int

const (
	ConversationLocationFollow ConversationLocation = iota
	ConversationLocationChannel
	ConversationLocationThread
)

func NormalizeLocationRequest(value string) string {
	value = strings.ToLower(value)
	value = strings.ReplaceAll(value, "let's", "lets")
	value = strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsSpace(r) {
			return r
		}
		return ' '
	}, value)
	return strings.Join(strings.Fields(value), " ")
}
