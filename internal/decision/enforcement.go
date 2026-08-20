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
	"github.com/AndrewDryga/responder/internal/findingpolicy"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/taskoffercarry"
	"github.com/AndrewDryga/responder/internal/taskofferclaims"
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
	ChannelAroundRoot       []WatchContextMessage          `json:"channel_around_root,omitempty"`
	Memory                  core.AgentMemory               `json:"memory,omitempty"`
	RelatedSituations       []ConversationSituationContext `json:"related_situations,omitempty"`
	ReferencedThread        *ReferencedThreadContext       `json:"referenced_thread,omitempty"`
	ResponseThreadTS        string                         `json:"response_thread_ts,omitempty"`
	ReferencedChannelID     string                         `json:"referenced_channel_id,omitempty"`
	ReferencedThreadTS      string                         `json:"referenced_thread_ts,omitempty"`
	ReferencedMessageTS     string                         `json:"referenced_message_ts,omitempty"`
	ReferenceCaptured       bool                           `json:"reference_captured,omitempty"`
	RouteCaptured           bool                           `json:"route_captured,omitempty"`
	EscalationReason        string                         `json:"escalation_reason,omitempty"`
	Prior                   OperationalMemoryContext       `json:"prior_operational_context,omitempty"`
	SimilarPastEpisodes     []core.SimilarEpisode          `json:"similar_past_episodes,omitempty"`
	RelatedTasks            []core.RelatedTask             `json:"related_engineering_tasks,omitempty"`
	RecentChanges           []core.RecentChange            `json:"recent_changes,omitempty"`
	PriorCaptured           bool                           `json:"prior_captured,omitempty"`
	RulesCaptured           bool                           `json:"rules_captured,omitempty"`
	MatchedRules            []core.StandingRule            `json:"matched_rules,omitempty"`
	RuleEvaluationCaptured  bool                           `json:"rule_evaluation_captured,omitempty"`
	RuleAcknowledged        bool                           `json:"rule_acknowledged,omitempty"`
	RuleAcknowledgement     string                         `json:"rule_acknowledgement,omitempty"`
	ConversationFollowup    bool                           `json:"conversation_followup,omitempty"`
	OfferedIncidentTitle    string                         `json:"offered_incident_title,omitempty"`
	OfferedTaskTitle        string                         `json:"offered_task_title,omitempty"`
	OfferedTaskRepository   string                         `json:"offered_task_repository,omitempty"`
	OfferedTaskPrompt       string                         `json:"offered_task_prompt,omitempty"`
	OfferedTaskPullRequest  *core.PullRequestTarget        `json:"offered_task_pull_request,omitempty"`
	StructuredCorrections   int                            `json:"structured_corrections,omitempty"`
	ReplyShapeCorrections   int                            `json:"reply_shape_corrections,omitempty"`
	TurnTimeoutReplays      int                            `json:"turn_timeout_replays,omitempty"`
	TransientSessionReplays int                            `json:"transient_session_replays,omitempty"`
	// CorrectionClasses counts the corrections this run has had of each class,
	// MinTargetIndex is the rung of the session policy's target ladder its next
	// turn may not be answered below, RefusedTargetFloor is the lowest rung Coop
	// has refused to deliver, and DegradedTargetFallbackPending remembers that
	// provider limits require the next admission to ignore the desired floor.
	// All four are written by the store, which edits the envelope as raw fields;
	// they are declared here because this struct is decoded strictly and
	// re-encoded whole, so a field it does not name is first a decode error and
	// then, once tolerated, silently dropped.
	CorrectionClasses             map[string]int            `json:"correction_classes,omitempty"`
	MinTargetIndex                int                       `json:"min_target_index,omitempty"`
	RefusedTargetFloor            int                       `json:"refused_target_floor,omitempty"`
	DegradedTargetFallbackPending bool                      `json:"degraded_target_fallback_pending,omitempty"`
	PendingStatusSet              bool                      `json:"pending_status_set,omitempty"`
	PendingStatusAt               int64                     `json:"pending_status_at,omitempty"`
	FailureDetail                 string                    `json:"failure_detail,omitempty"`
	ApprovalContinuation          bool                      `json:"approval_continuation,omitempty"`
	DecisionSourceID              string                    `json:"decision_source_id,omitempty"`
	ReplyDeliveryID               string                    `json:"reply_delivery_id,omitempty"`
	PublicationsCaptured          bool                      `json:"publications_captured,omitempty"`
	ActivePublications            []core.PublicationContext `json:"active_publications,omitempty"`
	RecheckOriginRunID            string                    `json:"recheck_origin_run_id,omitempty"`
	RecheckKey                    string                    `json:"recheck_key,omitempty"`
	RecheckAttempt                int                       `json:"recheck_attempt,omitempty"`
	// StreamAnsweredAt, StreamAnsweredVerdict and StreamAnsweredAction are what
	// Responder has already posted about THIS operational stream, in this
	// thread: when, what it concluded, and what it told the channel to do.
	//
	// They exist so that "nothing has changed" is a decision the model can make
	// and the host can check. Without them a repeat card is indistinguishable
	// from a first one, which on 2026-08-16 was five replies restating one
	// unchanged assessment of a memory alert oscillating around its threshold.
	// Empty on the first card of a stream, which is exactly when silence is not
	// allowed.
	StreamAnsweredAt       string           `json:"stream_answered_at,omitempty"`
	StreamAnsweredVerdict  string           `json:"stream_answered_verdict,omitempty"`
	StreamAnsweredAction   string           `json:"stream_answered_action,omitempty"`
	ResolvedMentionRequest *core.SlackInput `json:"resolved_mention_request,omitempty"`
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
	// CarriedTaskOffer preserves the governed action a correction round is
	// refining. Without it, a later evidence-only correction can post the
	// explanation while silently dropping the only control that lets the
	// operator start the writable work.
	CarriedTaskOffer *taskoffercarry.Offer `json:"carried_task_offer,omitempty"`
}

func (state *WatchTurnState) ReconcileCarriedTaskOffer(decision *WatchDecision) {
	state.CarriedTaskOffer = taskoffercarry.Reconcile(state.CarriedTaskOffer, taskoffercarry.Round{Operations: &decision.Operations, Applied: &decision.AppliedOperations, Title: &decision.TaskTitle, Repository: &decision.TaskRepository, Prompt: &decision.TaskPrompt, PullRequest: &decision.TaskPullRequest})
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

// CarryFindings does the same for findings, keyed on their stable structured
// identity. A correction suffix on an operation id is transport bookkeeping,
// not a new failure state, so canonicalFindingKey removes those suffixes once
// and the serialized Key survives the next context envelope.
func CarryFindings(
	prior, current []investigation.FindingOperation,
) []investigation.FindingOperation {
	unanswered := make([]investigation.FindingOperation, 0, len(prior))
	for _, earlier := range prior {
		if slices.ContainsFunc(current, func(item investigation.FindingOperation) bool {
			return sameFinding(earlier, item)
		}) {
			continue
		}
		unanswered = append(unanswered, earlier)
	}
	return carryForward(unanswered, current, func(item investigation.FindingOperation) string {
		if key := strings.TrimSpace(item.Key); key != "" {
			return "key:" + key
		}
		// Compatibility for findings persisted before Key existed. Exact text is
		// safe; interpreting similar prose as identity is not.
		return "legacy-what:" + strings.ToLower(strings.TrimSpace(item.What))
	})
}

// sameFinding deliberately reads no generated prose. A false fuzzy match can
// retire an open production finding, while an exact stable key is both cheaper
// and auditable.
func sameFinding(prior, current investigation.FindingOperation) bool {
	priorKey, currentKey := strings.TrimSpace(prior.Key), strings.TrimSpace(current.Key)
	if priorKey != "" || currentKey != "" {
		if priorKey != "" && currentKey != "" {
			return priorKey == currentKey
		}
		// One side may be a context record persisted before finding keys
		// existed. Migrate only an exact sentence; paraphrase similarity is not
		// identity and must never retire an open finding.
		return strings.TrimSpace(prior.What) != "" &&
			strings.EqualFold(strings.TrimSpace(prior.What), strings.TrimSpace(current.What))
	}
	if prior.ID != "" && investigation.FindingKeyForOperationID(prior.ID) == investigation.FindingKeyForOperationID(current.ID) {
		return true
	}
	// Compatibility for records written before Key existed. Do not infer that
	// paraphrases are equal; the model must carry the stable key to say so.
	return strings.TrimSpace(prior.What) != "" &&
		strings.EqualFold(strings.TrimSpace(prior.What), strings.TrimSpace(current.What))
}

// findingContinuationOperations are the operations that say the work carries on
// in this same episode rather than concluding here.
var findingContinuationOperations = []string{"plan_goal", "wait_external"}

// evidenceDiscriminatesAlternative validates adversarial residue from typed
// evidence. The cited row must contradict the exact claim represented by the
// alternative; generated observation prose is never interpreted as a verdict.
func evidenceDiscriminatesAlternative(
	evidence []core.Evidence, alternative investigation.FindingAlternative,
) bool {
	if strings.TrimSpace(alternative.ClaimID) == "" ||
		strings.TrimSpace(alternative.DiscriminatedBy) == "" {
		return false
	}
	for _, item := range evidence {
		if item.ID != alternative.DiscriminatedBy {
			continue
		}
		return item.ClaimID == alternative.ClaimID && item.Relation == "contradicts"
	}
	return false
}

// decisionReportsFailure reads only typed result fields. Model-written prose is
// presentation data and cannot decide whether another structured record is
// required.
func decisionReportsFailure(decision WatchDecision) bool {
	if decision.AlertAssessment != nil &&
		(decision.AlertAssessment.Verdict == "confirmed_issue" ||
			decision.AlertAssessment.Verdict == "likely_issue") {
		return true
	}
	if decision.Completion != nil {
		// confirmed belongs to the factual-assessment contract: it says the
		// answer was established, not that the established fact is a failure.
		// Negative evidence is represented by alert, coverage, or health fields
		// below and above; treating this overloaded verdict as negative made a
		// healthy repository-inspection canary pay a correction round.
		switch decision.Completion.Verdict {
		case "degraded", "unhealthy", "failed", "partial":
			return true
		}
	}
	return slices.ContainsFunc(decision.Coverage, func(item core.Coverage) bool {
		return item.Status == "degraded" || item.Status == "unhealthy"
	})
}

// findingRestsOnAnUncheckableRival reports whether a finding has named the rival
// explanation it cannot separate and said why it cannot separate it now. It is
// the model's own sentence about the limits of what it can reach, and it is the
// only exit from the unexplained rule that a session with no Nomad diagnostic
// and no load-balancer log can actually take.
func findingRestsOnAnUncheckableRival(finding investigation.FindingOperation) bool {
	return slices.ContainsFunc(finding.Alternatives,
		func(alternative investigation.FindingAlternative) bool {
			return strings.TrimSpace(alternative.NotCheckable) != ""
		})
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
	if correction, stop := findingpolicy.InitialCorrection(decision.Action, findings); stop {
		return correction
	}
	blocked := decision.Completion != nil && decision.Completion.Status == "blocked"
	// A typed failure must record its failure state as a typed finding. The
	// completion, assessment and coverage are the contract; arbitrary prose is
	// never re-parsed to guess whether this rule applies.
	if !blocked && len(findings) == 0 && decisionReportsFailure(decision) {
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
			// "Unexplained, and nothing available can settle it now" is an honest
			// final state, and the rule is unsatisfiable without a shape for it.
			// Two eval-prompts cases failed on 2026-08-16 trying to say exactly
			// that: a Nomad rollback whose own reply read "the current Emisar
			// catalog has no Nomad diagnostic" put the check that would settle it
			// into discriminated_by, which takes an evidence id, and a recovered
			// portal 503 said in prose that "current evidence can't distinguish a
			// brief no-healthy-backend interval from an application-generated
			// 503". Neither could identify a cause, continue, block, or honestly
			// call the failure expected or out_of_scope. This is the same third
			// exit BoundedCauseCorrection already accepts, in the same field.
			if findingRestsOnAnUncheckableRival(item) {
				continue
			}
			return "finding " + strconv.Quote(item.What) + " is unexplained: identify its cause " +
				"with evidence ids; or keep investigating with a goal, recheck or wait_external; " +
				"or say in an alternative what check would settle it and why it is not available " +
				"now (not_checkable); or return blocked with the exact obstacle; or classify it " +
				"expected or out_of_scope with the reason"
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
	// A discriminator has to contradict the rival's typed claim. Merely citing
	// an evidence id does not establish that relationship.
	//
	// On 2026-08-16 finding-1 of the VA1 Traefik investigation was "explained"
	// and named evidence-impact-growth as ruling out "a pure in-process leak
	// independent of load". That observation ends "Heap grew faster than the
	// connection count, so a leak component on top of the load-driven growth is
	// not excluded." The assessment's cause went out bounded, the completion
	// closed decision_ready, and the operator read "Memory tracks load ... raise
	// the cap and roll the job" with no caveat. The exemptions are the
	// unexplained rule's: a turn that is still working may hold a provisional
	// explanation, and a blocked one has already named its obstacle.
	if decision.Completion != nil && !blocked && !ContinuesThisEpisode(decision) {
		for _, item := range findings {
			if item.Status != "explained" {
				continue
			}
			for _, alternative := range item.Alternatives {
				if alternative.DiscriminatedBy == "" ||
					evidenceDiscriminatesAlternative(decision.Evidence, alternative) {
					continue
				}
				identity := "finding " + strconv.Quote(item.What)
				if item.Key != "" {
					identity += " (key " + strconv.Quote(item.Key) + ")"
				}
				return identity + " names " +
					alternative.DiscriminatedBy + " as ruling out " +
					strconv.Quote(alternative.Hypothesis) + ", but it does not contradict the " +
					"alternative's typed claim_id; replace that finding with the same key, then add the claim and evidence that actually " +
					"discriminate, or mark the " +
					"finding unexplained and keep investigating with a goal, recheck or " +
					"wait_external, or return blocked with the exact obstacle"
			}
		}
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

// BoundedCauseCorrection refuses to let a confirmed or likely issue whose cause
// is only bounded close as decision_ready with nothing that continues the
// investigation. Bounded is a legitimate intermediate state — "it is Traefik
// and it is the cap" — but on 2026-08-16 it was accepted as a final one, and the
// question the model itself had written down (heap profile: leak or load?) was
// never asked again in five episodes. The ways out are all the model's: keep
// the episode open with a recheck, goal or wait_external that runs the
// discriminating check; return blocked with that check as the exact obstacle;
// or state in the finding's alternative that no discriminating check exists.
func BoundedCauseCorrection(episode core.WorkEpisode, decision WatchDecision) string {
	if decision.Action != "reply" {
		return ""
	}
	if episode.Effort != core.EffortOperationalAssessment &&
		episode.Effort != core.EffortIncidentInvestigation {
		return ""
	}
	if decision.Completion == nil || decision.Completion.Status != "decision_ready" {
		return ""
	}
	assessment := decision.AlertAssessment
	if assessment == nil ||
		(assessment.Verdict != "confirmed_issue" && assessment.Verdict != "likely_issue") ||
		!strings.EqualFold(strings.TrimSpace(assessment.CauseStatus), "bounded") {
		return ""
	}
	if ContinuesThisEpisode(decision) {
		return ""
	}
	// The model saying plainly that nothing available discriminates is the third
	// exit, and it is the one that makes the rule satisfiable inside a session
	// with no profiler. Asking again after that answer spends a round to be told
	// the same thing.
	if slices.ContainsFunc(decision.Findings, findingRestsOnAnUncheckableRival) {
		return ""
	}
	return "the alert assessment's cause is bounded, not identified, and nothing continues the " +
		"investigation: name the check that would identify it — a heap profile at high RSS, a " +
		"reload counter, connection age, whatever discriminates — and keep this episode open " +
		"with a recheck or wait_external that runs it, or return blocked with that check as the " +
		"exact obstacle, or say in the finding's alternative why no discriminating check is " +
		"available"
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
	if title != "" && !strings.EqualFold(message, title) {
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
		switch strings.TrimSpace(item) {
		case "Offer incident coordination for operator confirmation.",
			"Continue this alert's investigation in its source thread.":
			continue
		default:
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
		evidence := SanitizeEvidence(decision.Evidence, "", "", "", now)
		if correction := evidencepolicy.AlertCauseCorrection(
			decision.AlertAssessment, evidence,
		); correction != "" {
			return correction
		}
		recovered := decision.AlertAssessment.Verdict == "not_issue" &&
			OperationalAlertResolvedEvent(input.Text)
		if decision.AlertAssessment.Verdict == "not_issue" && !recovered {
			// A live Grafana firing state is host-observed input. Evidence rows and
			// their dimensions are model output, so they may bound the impact or
			// justify an unverified verdict but cannot attest that the source alert
			// itself cleared. Only a matching resolved lifecycle event can do that.
			return "the source alert is still firing; model-authored evidence cannot classify " +
				"that host-observed condition as not_issue — return unverified with the checked " +
				"scope, or wait for the matching resolved event"
		}
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
			!HasActiveDegradationEvidence(
				evidence, decision.AlertAssessment.EvidenceRefs, now,
			) {
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
		if correction := OperationalScopeCorrection(decision.AlertAssessment, evidence); correction != "" {
			return correction
		}
	}
	return ""
}

// AlertPolicyCorrection applies the extra standard a channel opts into when its
// alert policy is anything other than automatic: terminal app events get an
// investigated reply with a verdict, not a reaction and not an incident room.
//
// The standard is "every alert gets an answer", not "every card gets a post".
// It read the card's own words — firing, warning, failed — and forced a reply
// from any of them, so a stream that flapped across one threshold owed the
// channel one post per crossing. On 2026-08-16 that was five replies in ninety
// minutes for a single unchanged assessment, each restating that Traefik memory
// was near its cap, two of them saying only that a node had crossed back over
// the line. The prompt told the model to stay silent unless it had something
// new; this rule made obeying it impossible.
//
// So a card on a stream Responder has ALREADY answered in this thread may be
// ignored. A recovery may not: a stream answered while it was firing still owes
// the channel its closure, and OperationalAlertResolvedEvent is what tells the
// two apart.
func AlertPolicyCorrection(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
) string {
	answered := strings.TrimSpace(state.StreamAnsweredAt) != "" &&
		!OperationalAlertResolvedEvent(input.Text)
	if !answered && ExternalAppEventRequiresDecision(input.Text) && decision.Action != "reply" {
		return "this terminal or actionable app event requires an evidence-backed in-place " +
			"alert assessment and reply; investigate the exact event instead of ignoring it " +
			"or reducing it to a reaction"
	}
	if decision.Action == "incident" {
		return "this channel requires an evidence-backed in-place alert assessment; " +
			"continue the read-only investigation and return reply with typed evidence, " +
			"coverage, and a completion verdict instead of reducing the result to incident admission"
	}
	// A terminal SUCCESS joins the failure vocabulary here and only here. The
	// card may still be ignored or reacted to above — the reply policy tells the
	// model to stay quiet about a routine applied run — but a reply the model
	// chose to post about a finished apply is recording an outcome, and an
	// outcome without a verdict is news.
	if (ExternalAppEventRequiresDecision(input.Text) ||
		ExternalAppEventIsTerminalSuccess(input.Text)) && decision.Action == "reply" &&
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
	// Task-offer safety is an episode-aware rule, not a transport parsing rule.
	// A correction round normally returns only the fields it changes, while the
	// service restores the evidence and coverage accepted from earlier rounds
	// before calling this function. Enforcing these requirements in the parser
	// rejected that partial round before its carried records could be restored,
	// creating an impossible loop between boundary, evidence, and coverage
	// corrections.
	if decision.TaskPrompt != "" {
		if !ValidSuggestedEngineeringTaskBoundary(decision) {
			return "suggested engineering task requires a decision-ready result or an exact tool-failure blocker"
		}
		sanitizedEvidence := SanitizeEvidence(decision.Evidence, "", "", "", now)
		if !WatchDecisionHasEvidenceSource(sanitizedEvidence, "repository") {
			return "suggested engineering task requires repository evidence"
		}
		if correction := taskofferclaims.RepositoryCorrection(sanitizedEvidence, decision.TaskRepository); correction != "" {
			return correction
		}
	}
	if input.Kind == "recheck" && decision.Action == "ignore" &&
		strings.HasPrefix(state.RecheckKey, "structured:") &&
		strings.TrimSpace(state.FailureDetail) != "" {
		return "this recheck was scheduled because the prior structured result was rejected: " +
			BoundedField(state.FailureDetail, 500) +
			"; return a corrected complete result instead of ignoring the validation failure"
	}
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
		if correction := AlertPolicyCorrection(input, state, decision); correction != "" {
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

// AlertReplyLanguageCorrectionWithContext is an offline evaluation warning for
// alert-reply style. Runtime acceptance does not call it: generated prose is
// presentation data, while typed alert fields and host rendering own
// correctness and recovery links.
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
	setDecisionReply(
		&decision,
		strings.TrimSpace(decision.Message)+"\n\nClosing [the earlier alert]("+link+").",
		decision.FollowupMessages,
	)
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

// externalLifecycleSubjects and externalTerminalSuccessStates are
// lifecycle.Classify's own subject words and Succeeded states. They are copied
// rather than imported because internal/lifecycle imports this package, and
// they are the vocabulary a Terraform, deploy or CI card actually uses.
var (
	externalLifecycleSubjects = []string{
		"run", "deployment", "job", "workflow", "build", "release", "plan", "apply",
	}
	externalTerminalSuccessStates = []string{
		"applied", "success", "succeeded", "successful", "completed", "finished",
	}
)

// ExternalAppEventIsTerminalSuccess reports an app card whose own status line
// says the work reached a terminal successful state: `Run Applied`,
// `Deployment succeeded`, `Run Planned and Finished`. It is the other half of
// ExternalAppEventRequiresDecision, which knows only the failure words.
//
// Like lifecycle.Classify it reads explicit status lines and not prose, so an
// operator writing that a migration "completed last night" is not a lifecycle
// event; and an intermediate status — `Run Planning`, `Run Planned - Needs
// Confirmation` — is not terminal, so a plan awaiting a human owes no verdict.
func ExternalAppEventIsTerminalSuccess(text string) bool {
	for _, raw := range strings.Split(strings.ToLower(text), "\n") {
		line := strings.Join(strings.Fields(strings.ReplaceAll(raw, "*", "")), " ")
		if !externalLifecycleStatusLine(line) {
			continue
		}
		for _, state := range externalTerminalSuccessStates {
			if line == state || strings.Contains(line, " "+state) ||
				strings.Contains(line, state+" ") || strings.Contains(line, state+":") {
				return true
			}
		}
	}
	return false
}

func externalLifecycleStatusLine(line string) bool {
	if strings.HasPrefix(line, "status:") || strings.HasPrefix(line, "state:") {
		return true
	}
	for _, subject := range externalLifecycleSubjects {
		if strings.HasPrefix(line, subject+" ") || strings.HasPrefix(line, subject+":") {
			return true
		}
	}
	return false
}

func MatchedOperationalAlertRule(rules []core.StandingRule) bool {
	for _, rule := range rules {
		if rule.Trigger == "operational_alert" && rule.Action == "triage_alert" {
			return true
		}
	}
	return false
}

// HasActiveDegradationEvidence reports a fresh operational observation cited by
// this assessment that actually found something wrong, as opposed to one that
// merely arrived recently or describes an unrelated service. Freshness says
// when Responder looked; the health effect and explicit assessment reference
// say what it saw and which alert the observation supports.
func HasActiveDegradationEvidence(
	evidence []core.Evidence,
	assessmentRefs []string,
	now time.Time,
) bool {
	referenced := make(map[string]struct{}, len(assessmentRefs))
	for _, ref := range assessmentRefs {
		referenced[ref] = struct{}{}
	}
	for _, item := range evidence {
		if _, ok := referenced[item.ID]; !ok {
			continue
		}
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
		return evidencepolicy.CauseBoundaryCorrection(assessment)
	}
	if correction := evidencepolicy.AlertCauseCorrection(assessment, evidence); correction != "" {
		return correction
	}
	if strings.TrimSpace(assessment.Verification) == "" {
		return evidencepolicy.VerificationPlanCorrection(assessment)
	}
	if assessment.ImmediateActionKind == "investigation" {
		return "the active alert's immediate action is still an investigative handoff; perform the available read-only inspection now, then recommend an actual mitigation or return an exact external blocker"
	}
	if correction := OperationalScopeCorrection(assessment, evidence); correction != "" {
		return correction
	}
	return ""
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
