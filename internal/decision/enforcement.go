package decision

import (
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/evidencepolicy"
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
	Lane             string                `json:"lane,omitempty"`
	AlertPolicy      string                `json:"alert_policy,omitempty"`
	SessionID        string                `json:"session_id"`
	SessionChannelID string                `json:"session_channel_id,omitempty"`
	Repository       string                `json:"repository,omitempty"`
	RepositoryPinned bool                  `json:"repository_pinned,omitempty"`
	Generation       int                   `json:"generation,omitempty"`
	ExpectedRevision int64                 `json:"expected_revision,omitempty"`
	TurnID           string                `json:"turn_id,omitempty"`
	ContextCaptured  bool                  `json:"context_captured,omitempty"`
	RecentMessages   []WatchContextMessage `json:"recent_messages,omitempty"`
	// ChannelAroundRoot is the channel-level transcript around a thread's root,
	// carried beside the in-thread one rather than inside it. A thread turn can
	// otherwise see nothing outside its own thread, and "see above" resolves
	// exactly there. Separate from RecentMessages on purpose: that list is
	// captured once and deduplicated against the resolved mention, and neither
	// rule should ever be applied to messages from outside the thread.
	ChannelAroundRoot      []WatchContextMessage          `json:"channel_around_root,omitempty"`
	Memory                 core.AgentMemory               `json:"memory,omitempty"`
	RelatedSituations      []ConversationSituationContext `json:"related_situations,omitempty"`
	ReferencedThread       *ReferencedThreadContext       `json:"referenced_thread,omitempty"`
	ResponseThreadTS       string                         `json:"response_thread_ts,omitempty"`
	ReferencedChannelID    string                         `json:"referenced_channel_id,omitempty"`
	ReferencedThreadTS     string                         `json:"referenced_thread_ts,omitempty"`
	ReferencedMessageTS    string                         `json:"referenced_message_ts,omitempty"`
	ReferenceCaptured      bool                           `json:"reference_captured,omitempty"`
	RouteCaptured          bool                           `json:"route_captured,omitempty"`
	EscalationReason       string                         `json:"escalation_reason,omitempty"`
	Prior                  OperationalMemoryContext       `json:"prior_operational_context,omitempty"`
	SimilarPastEpisodes    []core.SimilarEpisode          `json:"similar_past_episodes,omitempty"`
	RecentChanges          []core.RecentChange            `json:"recent_changes,omitempty"`
	PriorCaptured          bool                           `json:"prior_captured,omitempty"`
	RulesCaptured          bool                           `json:"rules_captured,omitempty"`
	MatchedRules           []core.StandingRule            `json:"matched_rules,omitempty"`
	RuleEvaluationCaptured bool                           `json:"rule_evaluation_captured,omitempty"`
	RuleAcknowledged       bool                           `json:"rule_acknowledged,omitempty"`
	RuleAcknowledgement    string                         `json:"rule_acknowledgement,omitempty"`
	ConversationFollowup   bool                           `json:"conversation_followup,omitempty"`
	OfferedIncidentTitle   string                         `json:"offered_incident_title,omitempty"`
	OfferedTaskTitle       string                         `json:"offered_task_title,omitempty"`
	OfferedTaskRepository  string                         `json:"offered_task_repository,omitempty"`
	OfferedTaskPrompt      string                         `json:"offered_task_prompt,omitempty"`
	OfferedTaskPullRequest *core.PullRequestTarget        `json:"offered_task_pull_request,omitempty"`
	StructuredCorrections  int                            `json:"structured_corrections,omitempty"`
	ReplyShapeCorrections  int                            `json:"reply_shape_corrections,omitempty"`
	// CorrectionClasses counts the corrections this run has had of each class,
	// and MinTargetIndex is the rung of the session policy's target ladder its
	// next turn may not be answered below. Both are written by the store, which
	// edits the envelope as raw fields; they are declared here because this
	// struct is decoded strictly and re-encoded whole, so a field it does not
	// name is first a decode error and then, once tolerated, silently dropped.
	CorrectionClasses      map[string]int            `json:"correction_classes,omitempty"`
	MinTargetIndex         int                       `json:"min_target_index,omitempty"`
	PendingStatusSet       bool                      `json:"pending_status_set,omitempty"`
	PendingStatusAt        int64                     `json:"pending_status_at,omitempty"`
	FailureDetail          string                    `json:"failure_detail,omitempty"`
	ApprovalContinuation   bool                      `json:"approval_continuation,omitempty"`
	DecisionSourceID       string                    `json:"decision_source_id,omitempty"`
	ReplyDeliveryID        string                    `json:"reply_delivery_id,omitempty"`
	PublicationsCaptured   bool                      `json:"publications_captured,omitempty"`
	ActivePublications     []core.PublicationContext `json:"active_publications,omitempty"`
	RecheckOriginRunID     string                    `json:"recheck_origin_run_id,omitempty"`
	RecheckKey             string                    `json:"recheck_key,omitempty"`
	RecheckAttempt         int                       `json:"recheck_attempt,omitempty"`
	ResolvedMentionRequest *core.SlackInput          `json:"resolved_mention_request,omitempty"`
	// CarriedEvidence and CarriedCoverage are what this run has already had
	// accepted, kept so a correction round is judged against the investigation
	// rather than against the fragment of it that round resubmitted. See
	// CarryEvidence.
	CarriedEvidence []core.Evidence `json:"carried_evidence,omitempty"`
	CarriedCoverage []core.Coverage `json:"carried_coverage,omitempty"`
	// CarriedFindings is the same accumulation for typed findings, and it is the
	// one this envelope cannot do without: an unexplained finding refuses the
	// completion, so a round that dropped the finding it was not asked about
	// would be judged as having discovered nothing.
	CarriedFindings []investigation.FindingOperation `json:"carried_findings,omitempty"`
}

// CarryEvidence and CarryCoverage fold a round's rows into what the run already
// established, newest row winning for the same id or layer.
//
// A correction round returns only the operations the correction named — ids
// literally suffixed "-corrected" — and drops the record_evidence and
// record_coverage rows an earlier round emitted and the host accepted. Nothing
// persists those rows: a correction requeues the run before the decision is
// applied, so the store holds nothing and every validator that reads
// accumulated state sees one round's fragment.
//
// The result is a loop where each round answers the last complaint and
// manufactures the next. One recorded episode ran it three times: round 1 was
// told its change coverage did not establish change.recent, round 2 dropped
// every operation but the completion and was told it had no
// record_alert_assessment, round 3 restored the assessment citing
// evidence-current-metrics and evidence-user-paths by the exact ids round 1 had
// recorded, and was told the active issue "cites absent or unrelated cause
// evidence". Three chronically flappy eval cases spent a day failing on the
// coverage half of the same defect, "has not assessed required coverage layers:
// change, application, slo", a complaint round 1 had already answered.
func CarryEvidence(prior, current []core.Evidence) []core.Evidence {
	return carryForward(prior, current, func(item core.Evidence) string { return item.ID })
}

func CarryCoverage(prior, current []core.Coverage) []core.Coverage {
	return carryForward(prior, current, func(item core.Coverage) string { return item.Layer })
}

// CarryFindings does the same for findings, keyed on the failure state named
// rather than on an operation id.
//
// The id would be the obvious key and it is the wrong one here. A correction
// round re-emits its operations with ids literally suffixed "-corrected", so
// keying on the id folds nothing: the round that finally explains a failure
// would land beside the unexplained record of the same failure and the
// completion would stay refused forever. What a finding IS is the failure state
// it names, so that is its identity, and a later round naming the same state
// replaces the earlier verdict about it.
func CarryFindings(
	prior, current []investigation.FindingOperation,
) []investigation.FindingOperation {
	return carryForward(prior, current, func(item investigation.FindingOperation) string {
		return strings.ToLower(strings.TrimSpace(item.What))
	})
}

// findingFailurePhrases is the vocabulary that turns a reply into a report of a
// failure state. It is deliberately conservative and literal: every phrase is
// one an operator would read as "something broke", and the cost of missing one
// is a finding nobody recorded, while the cost of a wrong one is a correction
// round spent on an answer that was already right.
var findingFailurePhrases = []string{
	"rolled back", "rollback", "did not deploy", "failed with", "crash loop", "crashloop",
	"exhausted their retries", "exhausted retries", "missed the progress deadline",
	"failing", "keeps failing",
}

// findingRecoveryPhrases take the sentence back. Two real completions are why
// they are here: "**Sentry recovered.** ... The durable fix is redundancy or a
// health-gated rollout and rollback procedure" carries the failure vocabulary
// inside a recommendation about the future, and "Zot's Artifact Registry
// authentication issue is **not recurring**. The last 24 hours contain no
// matching auth or upstream-sync failures" reports an absence. Demanding a
// finding for either is how a correction becomes noise.
var findingRecoveryPhrases = []string{
	"not recurring", "no matching", "recovered", "back to baseline", "resolved",
	"is healthy", "zero ",
}

// findingContinuationOperations are the operations that say the work carries on
// in this same episode rather than concluding here.
var findingContinuationOperations = []string{"plan_goal", "wait_external"}

// ReplyReportsFailure reads whether a reply tells an operator that something is
// broken, without a recovery or closure sentence taking it back.
func ReplyReportsFailure(parts ...string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(strings.Join(parts, " ")), " "))
	return EpisodeContainsAny(normalized, findingFailurePhrases...) &&
		!EpisodeContainsAny(normalized, findingRecoveryPhrases...)
}

// FindingCorrection holds a turn to the invariant an unexplained failure implies:
// the episode is not done.
//
// Three rules, in the order a turn fails them. It runs before
// CompletionCorrection because all three are about whether there is anything
// left to do, and asking "is the completion well formed" first would accept a
// perfectly shaped completion of work that had not finished — which is precisely
// what the 12:16 Zot triage was.
//
// The cost: on 2026-08-11 episode_run_ebbee0227d72743cc4aee48ef01113ba closed
// decision_ready/succeeded on a Terraform Run-Applied event while its own reply
// said VA1 pyke "did not deploy: its rollout missed the progress deadline and
// automatically rolled back to job version 5 ... avoid retrying until the failed
// allocation or health check is identified". The discovered failure lived only
// in prose. Three human nudges and 88 minutes bought the root cause a deep dive
// then found in four.
func FindingCorrection(
	episode core.WorkEpisode,
	decision WatchDecision,
	findings []investigation.FindingOperation,
) string {
	if decision.Action != "reply" {
		return ""
	}
	blocked := decision.Completion != nil && decision.Completion.Status == "blocked"
	// A reply that reports a failure must record it as a typed finding. Prose is
	// where the Zot rollback went, and prose is the one place no contract reads.
	if !blocked && len(findings) == 0 && ReplyReportsFailure(
		ReplySequence(decision.Message, decision.FollowupMessages)...,
	) {
		return "the reply reports a failure state; record it as a typed finding — status " +
			"unexplained unless evidence identifies the cause — or classify it expected with the reason"
	}
	// An unexplained finding cannot rest at decision_ready. Blocked has already
	// named its obstacle in the shape the host validates, and a continuation says
	// the work carries on in this same episode, which is the delta-update shape
	// the prompt asks for rather than a way to stop. A turn with no completion at
	// all is not resting on anything yet — CompletionCorrection has the useful
	// thing to say about it, and saying this first would cost a round.
	if decision.Completion != nil && !blocked && !ContinuesThisEpisode(decision) {
		for _, item := range findings {
			if item.Status != "unexplained" {
				continue
			}
			return "finding " + strconv.Quote(item.What) + " is unexplained; identify its cause " +
				"with evidence ids, keep investigating with a goal or recheck, return blocked with " +
				"the exact obstacle, or classify it expected or out_of_scope with the reason"
		}
	}
	// An identified cause must survive its strongest alternative, on the lanes
	// that were sent to find one. The fast lanes are deliberately exempt: depth
	// is triggered by anomaly, and charging a focused check for adversarial
	// residue would be the rule eating the latency it exists to justify.
	if episode.Effort != core.EffortOperationalAssessment &&
		episode.Effort != core.EffortIncidentInvestigation {
		return ""
	}
	for _, item := range findings {
		if item.Status == "explained" && len(item.Alternatives) == 0 {
			return "the cause is asserted but never attacked; name the strongest alternative " +
				"hypothesis and the evidence id that discriminates against it, or say why no " +
				"discriminating check is available"
		}
	}
	return ""
}

// ContinuesThisEpisode reports whether the turn left work running rather than
// concluding. A planned goal, a scheduled external wait, and a recheck directive
// each say the same thing in the host's own vocabulary: post the fast status
// now, deliver the cause as a delta update when the evidence lands.
func ContinuesThisEpisode(decision WatchDecision) bool {
	if decision.Completion != nil && decision.Completion.Recheck != nil {
		return true
	}
	return slices.ContainsFunc(decision.AppliedOperations,
		func(operation investigation.ResultOperation) bool {
			return slices.Contains(findingContinuationOperations, operation.Type)
		})
}

func carryForward[T any](prior, current []T, key func(T) string) []T {
	merged := make([]T, 0, len(prior)+len(current))
	at := make(map[string]int, len(prior)+len(current))
	for _, item := range append(append([]T{}, prior...), current...) {
		identity := key(item)
		// An item with no stable identity is never folded into another. Two
		// observations may support one claim without being the same row, and
		// keying those together silently deleted one of every such pair — three
		// golden corpus cases went to "evidence = 1, want at least 2" the first
		// time this keyed on the claim as well as the id.
		if identity == "" {
			merged = append(merged, item)
			continue
		}
		if index, ok := at[identity]; ok {
			merged[index] = item
			continue
		}
		at[identity] = len(merged)
		merged = append(merged, item)
	}
	return merged
}

func (state *WatchTurnState) RemoveResolvedMentionDuplicate() {
	if state.ResolvedMentionRequest == nil {
		return
	}
	filtered := state.RecentMessages[:0]
	for _, message := range state.RecentMessages {
		if !message.Target && message.MessageTS == state.ResolvedMentionRequest.MessageTS {
			continue
		}
		filtered = append(filtered, message)
	}
	state.RecentMessages = filtered
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

func SuppressWatchDecision(decision WatchDecision, reason string) WatchDecision {
	_ = applySuppression(&decision)
	// Recorded on the decision, not only in the prose reason, because the
	// reason is free text nothing can branch on and this has to be readable
	// after the decision has been through the database. See WatchDecision.
	decision.Suppressed = strings.TrimSpace(reason)
	if decision.Suppressed == "" {
		decision.Suppressed = "host policy"
	}
	decision.Reason = strings.TrimSpace(
		decision.Reason + "; " + reason,
	)
	return decision
}

// applySuppression clears everything a decision would say out loud, leaving
// what it learned. Shared with the finalization path so that silencing a
// decision and reading a silenced one back agree on what silence means.
func applySuppression(decision *WatchDecision) error {
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
	decision.ScheduleOffers = nil
	decision.PendingApproval = nil
	decision.AlertAssessment = nil
	decision.Completion = nil
	return nil
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
			Contribution: "decision", Material: true,
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
			return "the alert reply has no record_alert_assessment result; continue the read-only investigation " +
				"until you can state a verdict, impact, immediate action, and durable solution"
		}
		if correction := evidencepolicy.AlertCauseCorrection(
			decision.AlertAssessment,
			SanitizeEvidence(decision.Evidence, "", "", "", now),
		); correction != "" {
			return correction
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
		// A resolution notification confirms an incident happened. It is not
		// evidence that the problem is still happening, and the two were being
		// conflated: the recovery check above only ever ran when the model had
		// already said not_issue, so a confirmed_issue verdict on a cleared
		// alert went straight through. Responder published active degradation
		// and recommended halting a rollout for a condition that had already
		// recovered, on evidence that was fresh only in the sense of having
		// been retrieved a moment ago — it described the incident, not the
		// present.
		if OperationalAlertResolvedEvent(input.Text) &&
			(decision.AlertAssessment.Verdict == "confirmed_issue" ||
				decision.AlertAssessment.Verdict == "likely_issue") &&
			!HasActiveDegradationEvidence(evidence, now) {
			return "this alert condition has already cleared and nothing observed since shows " +
				"the problem is still active; close the exact alert condition, say plainly that " +
				"the signal recovered, mark broader recovery unknown where you did not verify it, " +
				"and do not claim current degradation or recommend containment without a fresh " +
				"observation that finds the failure still present"
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
	if decision.Action == "reply" && state.ConversationFollowup &&
		decision.Attention.Addressee == "human" &&
		decision.Completion != nil && decision.Completion.Status == "decision_ready" &&
		len(decision.Evidence) > 0 {
		return "the result contains a completed evidence-backed reply for the active conversation, " +
			"but attention.addressee says human; return the same supported answer with " +
			"attention.addressee=responder instead of misclassifying it as human-to-human chatter"
	}
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
	// Not a synthetic recheck. The host generates those, marks them as
	// conversation follow-ups so the turn carries its thread, and then tells the
	// model in as many words to return ignore when the blocker and the useful
	// result are unchanged. This rule read that obedience as an unanswered
	// operator and rejected it, so the only way a recheck could pass validation
	// was to say something — which is the opposite of what a quiet recheck is
	// for. Nobody is waiting on the other end of a timer Responder set itself.
	if decision.Action == "ignore" && input.Kind != "recheck" &&
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

// AlertReplyLanguageCorrectionWithContext judges the LANGUAGE of an alert
// reply — its opener, its verdict labels, its monitoring shorthand, its
// technical-term density, and whether a recovery links the message it closes.
//
// It deliberately does not judge length. It used to: 90 words active, 60 words
// recovered, against a prompt that asked for "under 100 words". A model
// obeying its instructions was still sent back, and on 2026-08-16 one episode
// spent eight correction rounds, ~$3.60 and fourteen minutes producing updates
// of 98, 91, 96, 98 and 94 words. Trimming ten words never changed what an
// operator did next. Concision is asked for in the prompt now, and
// replypolicy.ReplyWordBudget still catches an answer that blows the
// corpus-measured budget several times over — that bound is measured against
// the trigger, not guessed at.
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

// HasActiveDegradationEvidence reports a fresh operational observation that
// actually found something wrong, as opposed to one that merely arrived
// recently. Freshness says when Responder looked; the health effect says what
// it saw, and only the second can support a claim that a problem is ongoing.
func HasActiveDegradationEvidence(evidence []core.Evidence, now time.Time) bool {
	for _, item := range evidence {
		if item.HealthEffect != "degraded" && item.HealthEffect != "unhealthy" {
			continue
		}
		if HasFreshOperationalEvidence([]core.Evidence{item}, now) {
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
	evidence []core.Evidence,
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
	if correction := evidencepolicy.AlertCauseCorrection(assessment, evidence); correction != "" {
		return correction
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
	// ChannelID and ChannelName say where the transcript came from, and
	// Elsewhere says whether that is somewhere other than here.
	//
	// A permalink to another channel was resolved, fetched and handed to the
	// model as "an older thread the operator referred to", with nothing saying
	// it belonged to a different room. The model's other instructions tell it
	// to treat the current thread as the referent of "it" and "that", so an
	// unlabelled transcript from #frontend-ops read as more of #ask-devops —
	// and a link to the exact thread that answered the question was treated as
	// though it had not resolved at all.
	ChannelID      string                `json:"channel_id,omitempty"`
	ChannelName    string                `json:"channel_name,omitempty"`
	Elsewhere      bool                  `json:"from_another_channel,omitempty"`
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

// locationCueWindow is how many words in front of "thread" or "channel" are
// read for the request. Five rather than three because the apostrophe is
// normalized to a space, so "don't post in the channel" spends two of them on
// "don" and "t".
const locationCueWindow = 5

// locationCues are the verbs that turn a mention of a thread or a channel into
// a request to put the reply in one. Prefix-matched, so one entry covers
// "post", "posting" and "posted".
var locationCues = []string{
	"switch", "mov", "tak", "continu", "repl", "respond", "answer", "post",
	"put", "keep", "use", "comment", "send", "writ", "back", "get", "start",
	"stay", "stick", "pollut", "spam",
}

// locationNegations flip a request inside out. "Not in the channel" asks for a
// thread; "stop posting in the channel" is the same sentence with feeling.
// "No" is absent on purpose: "no, back to the channel" rejects the previous
// suggestion, not the channel.
var locationNegations = []string{
	"not", "dont", "don", "cant", "stop", "avoid", "quit", "never",
	"instead", "rather", "without",
}

// RequestedConversationLocation reads where the operator asked the answer to
// go.
//
// This used to be a list of literal phrases, and a list of literal phrases is
// wrong the first time somebody phrases it differently. It did not contain
// "comment in a thread" or "answer in thread" until the week a reply landed in
// the channel and the operator had to say so twice, and even after that repair
// it still missed "post in a thread", "thread this", "keep it threaded" and
// "stop posting in the channel". The routing underneath was never the problem.
//
// So it reads intent instead: find each place word, decide from the few words
// in front of it whether this is a request to put the reply there, and whether
// that request is negated. The last clear intent wins, because an operator who
// names both places is correcting themselves as they type.
func RequestedConversationLocation(text string) ConversationLocation {
	location := ConversationLocationFollow
	words := strings.Fields(NormalizeLocationRequest(text))
	for index, word := range words {
		place := ConversationLocationFollow
		switch {
		case strings.HasPrefix(word, "thread"):
			place = ConversationLocationThread
		case strings.HasPrefix(word, "channel"):
			place = ConversationLocationChannel
		default:
			continue
		}
		// A leading "thread this" is its own verb. Anywhere else the request
		// has to be marked by one, or every mention of the ops channel would
		// reroute the answer.
		window := words[max(0, index-locationCueWindow):index]
		if index > 0 && !anyWordStartsWith(window, locationCues) {
			continue
		}
		if anyWordIn(window, locationNegations) {
			place = oppositeLocation(place)
		}
		location = place
	}
	return location
}

func oppositeLocation(location ConversationLocation) ConversationLocation {
	if location == ConversationLocationThread {
		return ConversationLocationChannel
	}
	return ConversationLocationThread
}

func anyWordStartsWith(words, prefixes []string) bool {
	for _, word := range words {
		for _, prefix := range prefixes {
			if strings.HasPrefix(word, prefix) {
				return true
			}
		}
	}
	return false
}

func anyWordIn(words, set []string) bool {
	for _, word := range words {
		if slices.Contains(set, word) {
			return true
		}
	}
	return false
}

// locationVocabulary is every word a message may contain while still being
// nothing but "put it over there".
//
// Durable-preference words — always, prefer, default, from now on — are
// deliberately absent: "always reply in thread" is a preference to store, and
// it has to reach the code that stores it rather than being answered with an
// acknowledgement. Greetings are absent for the same reason in the other
// direction: "post hi back to that thread" is a request to post the word "hi".
var locationVocabulary = locationWordSet(
	"lets please ok okay no and so but to into in on at back over here there from",
	"can could would you we i it this that the a an my our of than",
	"not don t dont cant stop avoid quit never instead rather",
	"switch switching move moving take taking continue continuing",
	"reply replying replies respond responding answer answering",
	"post posting put putting keep keeping use using comment commenting",
	"send sending write writing get getting stay staying start starting stick",
	"pollute polluting spam spamming",
	"thread threads threaded threading channel channels",
)

func locationWordSet(groups ...string) map[string]bool {
	set := make(map[string]bool)
	for _, group := range groups {
		for _, word := range strings.Fields(group) {
			set[word] = true
		}
	}
	return set
}

// LocationOnlyRequest reports whether the message asks for nothing but a
// change of place. Responder answers those itself with an acknowledgement and
// never involves the model, so a false positive swallows real work — which is
// why this is a closed vocabulary and not a guess. Any word outside it means
// there is something else in the message.
func LocationOnlyRequest(text string) bool {
	if RequestedConversationLocation(text) == ConversationLocationFollow {
		return false
	}
	for _, word := range strings.Fields(NormalizeLocationRequest(text)) {
		if !locationVocabulary[word] {
			return false
		}
	}
	return true
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
