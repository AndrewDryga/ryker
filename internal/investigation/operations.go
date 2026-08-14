package investigation

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"slices"
)

type CompletionAssessment struct {
	Status         string            `json:"status"`
	Verdict        string            `json:"verdict,omitempty"`
	Summary        string            `json:"summary"`
	MaterialGaps   []string          `json:"material_gaps,omitempty"`
	BlockerKind    string            `json:"blocker_kind,omitempty"`
	Blocker        string            `json:"blocker,omitempty"`
	Attempts       []string          `json:"attempts,omitempty"`
	NextAction     string            `json:"next_action,omitempty"`
	Recheck        *RecheckDirective `json:"recheck,omitempty"`
	CapabilityGaps []CapabilityGap   `json:"capability_gaps,omitempty"`
}

// CapabilityGap is an evidence-bound recommendation for adding a governed
// operational capability. PackID is deliberately optional: when discovery
// finds no matching pack, the model must report that result instead of
// inventing a plausible package name.
type CapabilityGap struct {
	Capability     string   `json:"capability"`
	Status         string   `json:"status"`
	PackID         string   `json:"pack_id,omitempty"`
	PackRef        string   `json:"pack_ref,omitempty"`
	EvidenceRefs   []string `json:"evidence_refs"`
	Recommendation string   `json:"recommendation"`
}

// RecheckDirective identifies a short-lived external condition that the host
// can revisit without asking the operator to repeat the request. It grants no
// additional authority.
type RecheckDirective struct {
	Key                string `json:"key"`
	Reason             string `json:"reason"`
	AfterSeconds       int    `json:"after_seconds"`
	AdditionalAttempts int    `json:"additional_attempts"`
}

type AlertAssessment struct {
	Verdict          string   `json:"verdict"`
	Impact           string   `json:"impact"`
	CauseStatus      string   `json:"cause_status,omitempty"`
	Cause            string   `json:"cause,omitempty"`
	CauseClaimIDs    []string `json:"cause_claim_ids,omitempty"`
	EvidenceRefs     []string `json:"evidence_refs,omitempty"`
	ImmediateAction  string   `json:"immediate_action,omitempty"`
	Verification     string   `json:"verification,omitempty"`
	LongTermSolution string   `json:"long_term_solution,omitempty"`
}

// UnmarshalJSON accepts a small set of previously emitted semantic aliases so
// one naming mismatch cannot discard an otherwise valid investigation. The
// canonical serialized contract remains the fields on AlertAssessment.
func (assessment *AlertAssessment) UnmarshalJSON(data []byte) error {
	var value struct {
		Verdict          string   `json:"verdict"`
		Impact           string   `json:"impact"`
		CauseStatus      string   `json:"cause_status,omitempty"`
		Cause            string   `json:"cause,omitempty"`
		CauseClaimIDs    []string `json:"cause_claim_ids,omitempty"`
		ImmediateAction  string   `json:"immediate_action,omitempty"`
		Verification     string   `json:"verification,omitempty"`
		LongTermSolution string   `json:"long_term_solution,omitempty"`
		DurableSolution  string   `json:"durable_solution,omitempty"`
		Alert            string   `json:"alert,omitempty"`
		Component        string   `json:"component,omitempty"`
		State            string   `json:"state,omitempty"`
		EvidenceRefs     []string `json:"evidence_refs,omitempty"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	if value.LongTermSolution == "" {
		value.LongTermSolution = value.DurableSolution
	}
	*assessment = AlertAssessment{
		Verdict:          value.Verdict,
		Impact:           value.Impact,
		CauseStatus:      value.CauseStatus,
		Cause:            value.Cause,
		CauseClaimIDs:    value.CauseClaimIDs,
		EvidenceRefs:     value.EvidenceRefs,
		ImmediateAction:  value.ImmediateAction,
		Verification:     value.Verification,
		LongTermSolution: value.LongTermSolution,
	}
	return nil
}

type ProgressOperation struct {
	Phase     string `json:"phase"`
	Summary   string `json:"summary"`
	NextDueAt string `json:"next_due_at,omitempty"`
}

type TaskOffer struct {
	Kind       string `json:"kind"`
	Title      string `json:"title"`
	Repository string `json:"repository,omitempty"`
	Prompt     string `json:"prompt,omitempty"`
}

type GoalOperation struct {
	ID                   string                 `json:"id"`
	Kind                 string                 `json:"kind"`
	RequestedOutcome     string                 `json:"requested_outcome"`
	CompletionContract   string                 `json:"completion_contract"`
	Required             bool                   `json:"required"`
	PrerequisiteGoalIDs  []string               `json:"prerequisite_goal_ids,omitempty"`
	WritableRepository   string                 `json:"writable_repository,omitempty"`
	ReadOnlyRepositories []string               `json:"read_only_repositories,omitempty"`
	Authority            core.AuthorityBoundary `json:"authority"`
}

type GoalStateOperation struct {
	GoalID string                `json:"goal_id"`
	State  core.EpisodeGoalState `json:"state"`
	Detail string                `json:"detail,omitempty"`
}

type OperatorInputOperation struct {
	Question string   `json:"question"`
	Choices  []string `json:"choices,omitempty"`
}

type ExternalWaitOperation struct {
	ID           string          `json:"id"`
	Kind         string          `json:"kind"`
	EventMatcher json.RawMessage `json:"event_matcher,omitempty"`
	DueAt        string          `json:"due_at,omitempty"`
	PollAfter    string          `json:"poll_after,omitempty"`
	Deadline     string          `json:"deadline,omitempty"`
}

// FeedbackOperation records product feedback about Responder itself. It is
// deliberately separate from operational evidence: frustration with an
// incident, provider, or repository is not automatically criticism of the
// assistant.
type FeedbackOperation struct {
	Category         string `json:"category"`
	Sentiment        string `json:"sentiment"`
	Summary          string `json:"summary"`
	Details          string `json:"details,omitempty"`
	TargetMessageTS  string `json:"target_message_ts,omitempty"`
	NeedsFollowup    bool   `json:"needs_followup,omitempty"`
	FollowupQuestion string `json:"followup_question,omitempty"`
}

// MaxRepositoryContentsBytes bounds the repository map to one readable line per
// repository. The map's job is to route a question to the repository that owns
// it, and a paragraph does that no better than a sentence while costing every
// turn the whole set is listed. The bound is also what stops the slot drifting
// into a changelog: anything that needs more room is evidence or guidance, both
// of which already have somewhere to go.
const MaxRepositoryContentsBytes = 240

// RepositoryContentsOperation revises which part of the product a repository
// holds. It carries no version, health, or ownership claim — those change
// without telling Responder, and this row never expires.
type RepositoryContentsOperation struct {
	Repository string `json:"repository"`
	Contents   string `json:"contents"`
}

type CompleteEpisode struct {
	Message          string                 `json:"message"`
	FollowupMessages []string               `json:"followup_messages,omitempty"`
	Visuals          []core.GeneratedVisual `json:"visuals,omitempty"`
	Coverage         []core.Coverage        `json:"coverage,omitempty"`
	Memory           core.AgentMemory       `json:"memory,omitempty"`
	MemoryOffer      *core.MemoryOffer      `json:"memory_offer,omitempty"`
	PreferenceOffer  *core.PreferenceOffer  `json:"preference_offer,omitempty"`
	RuleOffer        *core.RuleOffer        `json:"rule_offer,omitempty"`
	ScheduleOffer    *core.ScheduleOffer    `json:"schedule_offer,omitempty"`
	AlertAssessment  *AlertAssessment       `json:"alert_assessment,omitempty"`
	Completion       *CompletionAssessment  `json:"completion,omitempty"`
}

type ResultOperation struct {
	ID              string                  `json:"id"`
	Type            string                  `json:"type"`
	Evidence        *core.Evidence          `json:"evidence,omitempty"`
	Coverage        *core.Coverage          `json:"coverage,omitempty"`
	Progress        *ProgressOperation      `json:"progress,omitempty"`
	Goal            *GoalOperation          `json:"goal,omitempty"`
	GoalState       *GoalStateOperation     `json:"goal_state,omitempty"`
	OperatorInput   *OperatorInputOperation `json:"operator_input,omitempty"`
	ExternalWait    *ExternalWaitOperation  `json:"external_wait,omitempty"`
	Feedback        *FeedbackOperation      `json:"feedback,omitempty"`
	Approval        *core.EmisarApproval    `json:"approval,omitempty"`
	Task            *TaskOffer              `json:"task,omitempty"`
	Visual          *core.GeneratedVisual   `json:"visual,omitempty"`
	Memory          *core.AgentMemory       `json:"memory,omitempty"`
	MemoryOffer     *core.MemoryOffer       `json:"memory_offer,omitempty"`
	PreferenceOffer *core.PreferenceOffer   `json:"preference_offer,omitempty"`
	RuleOffer       *core.RuleOffer         `json:"rule_offer,omitempty"`
	ScheduleOffer   *core.ScheduleOffer     `json:"schedule_offer,omitempty"`
	AlertAssessment *AlertAssessment        `json:"alert_assessment,omitempty"`
	// RepositoryContents is the one memory an agent maintains without an
	// operator confirming it. It answers only "which part of the product lives
	// in this repository", it is one permanent row per repository, and writing
	// it again replaces the previous sentence rather than accumulating.
	RepositoryContents *RepositoryContentsOperation `json:"repository_contents,omitempty"`
	// Proposal is the payload of propose_action, which no longer exists.
	//
	// The operation is out of the prompt and the host has nothing left to do
	// with a proposal, so the honest answer to one is a refusal. This field is
	// what makes the refusal readable. Without it the strict decoder rejects
	// the whole response with `unknown field "proposal"`, and that text is what
	// the correction turn hands back to the model — an invitation to guess at
	// another field name rather than to stop proposing actions.
	//
	// Raw because nothing reads it. It exists to be counted as the operation's
	// one payload so validation reaches the refusal below instead of failing
	// first on "requires exactly one typed payload".
	Proposal   json.RawMessage  `json:"proposal,omitempty"`
	Completion *CompleteEpisode `json:"completion,omitempty"`
}

// resultOperationPayloadAliases maps the payload names this prompt's own
// operation list used to imply onto the fields that actually carry them.
//
// The list told the model that offer_preference, offer_rule and offer_schedule
// "carry the same named typed payload that their operation name describes",
// and every other operation in it really does: record_evidence carries
// evidence, report_progress carries progress, attach_visual carries visual.
// Read that way offer_preference carries "preference", so a model obeyed the
// instruction and the host rejected the entire response over the field name.
// The list now states each key, and these three stay accepted anyway because
// each names exactly one real field and nothing else in a result operation
// claims those names. "memory" is deliberately absent: update_memory already
// uses it for conversation memory, so it is the one name here that would be
// ambiguous.
var resultOperationPayloadAliases = map[string]string{
	"preference": "preference_offer",
	"rule":       "rule_offer",
	"schedule":   "schedule_offer",
}

func (operation *ResultOperation) UnmarshalJSON(data []byte) error {
	type wire ResultOperation
	var value wire
	if err := core.DecodeModelObject(data, resultOperationPayloadAliases, &value); err != nil {
		return err
	}
	*operation = ResultOperation(value)
	// Normalized here rather than at validation, because everything downstream
	// switches on this string: folding, suppression, completion. Accepting a
	// name only to have the fold not recognise it would be worse than
	// rejecting it.
	operation.Type = resolveOperationType(strings.TrimSpace(operation.Type))
	return nil
}

// resultOperationPayloads lists every typed payload a result operation may
// carry. It is the single source for the "exactly one payload" rule, so adding
// a payload to ResultOperation is one line here rather than a second list to
// keep in step with the validators below.
var resultOperationPayloads = []func(ResultOperation) bool{
	func(o ResultOperation) bool { return o.Evidence != nil },
	func(o ResultOperation) bool { return o.Coverage != nil },
	func(o ResultOperation) bool { return o.Progress != nil },
	func(o ResultOperation) bool { return o.Goal != nil },
	func(o ResultOperation) bool { return o.GoalState != nil },
	func(o ResultOperation) bool { return o.OperatorInput != nil },
	func(o ResultOperation) bool { return o.ExternalWait != nil },
	func(o ResultOperation) bool { return o.Approval != nil },
	func(o ResultOperation) bool { return o.Task != nil },
	func(o ResultOperation) bool { return o.Feedback != nil },
	func(o ResultOperation) bool { return o.Visual != nil },
	func(o ResultOperation) bool { return o.Memory != nil },
	func(o ResultOperation) bool { return o.MemoryOffer != nil },
	func(o ResultOperation) bool { return o.PreferenceOffer != nil },
	func(o ResultOperation) bool { return o.RuleOffer != nil },
	func(o ResultOperation) bool { return o.ScheduleOffer != nil },
	func(o ResultOperation) bool { return o.AlertAssessment != nil },
	func(o ResultOperation) bool { return o.RepositoryContents != nil },
	func(o ResultOperation) bool { return len(o.Proposal) > 0 },
	func(o ResultOperation) bool { return o.Completion != nil },
}

// requirePayload builds the common validator: the named payload must be
// present, and any extra condition on it must hold.
// coverageStatuses is the set a coverage assessment may report, named here so
// the rejection can quote it back.
var coverageStatuses = []string{"healthy", "degraded", "unhealthy", "unknown", "not_applicable"}

// validateCoverageOperation rejects an unsupported coverage status where the
// model can act on it.
//
// An entry whose status was not in the set used to be dropped in silence
// during sanitization, and the layer it assessed was then reported back as
// never assessed at all. The model was told to go and check something it had
// just checked, with no hint that the answer had been thrown away for its
// spelling — so it checked again, wrote the same word, and the turn spent its
// rechecks on a validation failure nothing in the record explained.
func validateCoverageOperation(o ResultOperation) error {
	if o.Coverage == nil {
		return fmt.Errorf("result operation %q requires coverage", o.ID)
	}
	status := NormalizeCoverageStatus(strings.ToLower(strings.TrimSpace(o.Coverage.Status)))
	if status == "" {
		return fmt.Errorf(
			"result operation %q coverage for layer %q requires a status, one of: %s",
			o.ID, o.Coverage.Layer, strings.Join(coverageStatuses, ", "),
		)
	}
	if !slices.Contains(coverageStatuses, status) {
		return fmt.Errorf(
			"result operation %q reports coverage status %q for layer %q, which is not one of: %s",
			o.ID, o.Coverage.Status, o.Coverage.Layer, strings.Join(coverageStatuses, ", "),
		)
	}
	return nil
}

// resolveOperationType accepts an operation named after its payload.
//
// Every operation in the prompt's list is a verb and a noun — record_evidence,
// record_coverage, report_progress — and a model that reaches for the noun
// alone writes alert_assessment where record_alert_assessment was meant. The
// whole response was rejected for it, three times in the recorded history, on
// results that were otherwise complete.
//
// A rule rather than a list, and safe by construction: the prefixed name is
// accepted only if it is itself a real operation, so nothing is invented. An
// exact match always wins, so this can never shadow a real type.
func resolveOperationType(kind string) string {
	if _, ok := resultOperationValidators[kind]; ok {
		return kind
	}
	for _, verb := range []string{"record_", "report_", "update_", "offer_", "request_"} {
		if _, ok := resultOperationValidators[verb+kind]; ok {
			return verb + kind
		}
	}
	return kind
}

func requirePayload(
	requirement string,
	complete func(ResultOperation) bool,
) func(ResultOperation) error {
	return func(o ResultOperation) error {
		if !complete(o) {
			return fmt.Errorf("result operation %q requires %s", o.ID, requirement)
		}
		return nil
	}
}

// resultOperationValidators maps an operation type to the check that its
// payload is complete. A table rather than a switch keeps the supported types
// and their requirements in one readable place, and makes an unsupported type
// a missing key instead of a forgotten branch.
// validateRepositoryContentsOperation is stricter than the offer validators
// around it because nothing downstream asks an operator whether this is right.
// The rejection names the bound so a model that wrote a paragraph can shorten
// it rather than guess why the operation vanished.
func validateRepositoryContentsOperation(o ResultOperation) error {
	if o.RepositoryContents == nil {
		return fmt.Errorf("result operation %q requires repository_contents", o.ID)
	}
	repository := strings.TrimSpace(o.RepositoryContents.Repository)
	contents := strings.TrimSpace(o.RepositoryContents.Contents)
	if repository == "" || contents == "" {
		return fmt.Errorf(
			"result operation %q requires a repository and one sentence of contents", o.ID,
		)
	}
	if len(contents) > MaxRepositoryContentsBytes {
		return fmt.Errorf(
			"result operation %q describes repository %q in %d bytes; the repository map holds "+
				"one sentence of at most %d naming which part of the product lives there",
			o.ID, repository, len(contents), MaxRepositoryContentsBytes,
		)
	}
	return nil
}

var resultOperationValidators = map[string]func(ResultOperation) error{
	"record_evidence": requirePayload("evidence", func(o ResultOperation) bool {
		return o.Evidence != nil
	}),
	"record_coverage": validateCoverageOperation,
	"report_progress": requirePayload("progress phase and summary", func(o ResultOperation) bool {
		return o.Progress != nil && strings.TrimSpace(o.Progress.Phase) != "" &&
			strings.TrimSpace(o.Progress.Summary) != ""
	}),
	"plan_goal": requirePayload("a typed goal", func(o ResultOperation) bool {
		return o.Goal != nil && strings.TrimSpace(o.Goal.ID) != "" &&
			strings.TrimSpace(o.Goal.Kind) != "" &&
			strings.TrimSpace(o.Goal.RequestedOutcome) != "" &&
			strings.TrimSpace(o.Goal.CompletionContract) != ""
	}),
	"update_goal": requirePayload("goal id and state", func(o ResultOperation) bool {
		return o.GoalState != nil && strings.TrimSpace(o.GoalState.GoalID) != "" &&
			strings.TrimSpace(string(o.GoalState.State)) != ""
	}),
	"request_operator_input": requirePayload("an operator question", func(o ResultOperation) bool {
		return o.OperatorInput != nil && strings.TrimSpace(o.OperatorInput.Question) != ""
	}),
	"wait_external": requirePayload("an external wait and observation time", func(o ResultOperation) bool {
		return o.ExternalWait != nil && strings.TrimSpace(o.ExternalWait.ID) != "" &&
			strings.TrimSpace(o.ExternalWait.Kind) != "" &&
			(o.ExternalWait.DueAt != "" || o.ExternalWait.PollAfter != "")
	}),
	"record_feedback":            validateFeedbackOperation,
	"offer_task":                 validateTaskOperation,
	"request_approval":           requirePayload("approval", func(o ResultOperation) bool { return o.Approval != nil }),
	"attach_visual":              requirePayload("a visual artifact", func(o ResultOperation) bool { return o.Visual != nil && strings.TrimSpace(o.Visual.Artifact) != "" }),
	"update_memory":              requirePayload("memory", func(o ResultOperation) bool { return o.Memory != nil }),
	"offer_memory":               requirePayload("a memory offer", func(o ResultOperation) bool { return o.MemoryOffer != nil }),
	"offer_preference":           requirePayload("a preference offer", func(o ResultOperation) bool { return o.PreferenceOffer != nil }),
	"offer_rule":                 requirePayload("a rule offer", func(o ResultOperation) bool { return o.RuleOffer != nil }),
	"offer_schedule":             requirePayload("a schedule offer", func(o ResultOperation) bool { return o.ScheduleOffer != nil }),
	"record_alert_assessment":    requirePayload("an alert assessment", func(o ResultOperation) bool { return o.AlertAssessment != nil }),
	"record_repository_contents": validateRepositoryContentsOperation,
	// propose_action is refused rather than absent. The operation is gone from
	// ResultOperationsPrompt, so a model working from the current contract will
	// not emit one; a model working from anything older would otherwise get a
	// decoder complaint about a field name.
	//
	// The guidance lives here rather than in the prompt on purpose. Telling
	// every turn not to do something it has no reason to do costs context on
	// every turn; saying it in the refusal costs nothing until it is needed,
	// and lands in the correction the model actually reads.
	"propose_action": func(o ResultOperation) error {
		return fmt.Errorf(
			"result operation %q proposes an operational action, which this host no longer "+
				"carries; request the action through Emisar and report the pending run with "+
				"request_approval, or state the recommendation in the completion message",
			o.ID,
		)
	},
	"complete_episode": requirePayload("a completion message", func(o ResultOperation) bool {
		return o.Completion != nil && strings.TrimSpace(o.Completion.Message) != ""
	}),
}

// validateFeedbackOperation checks the enums that only feedback carries.
func validateFeedbackOperation(operation ResultOperation) error {
	if operation.Feedback == nil || strings.TrimSpace(operation.Feedback.Summary) == "" {
		return fmt.Errorf("result operation %q requires a feedback summary", operation.ID)
	}
	switch operation.Feedback.Category {
	case "ux", "correctness", "tone", "latency", "reliability", "feature_request", "other":
	default:
		return fmt.Errorf("result operation %q has unsupported feedback category %q", operation.ID, operation.Feedback.Category)
	}
	switch operation.Feedback.Sentiment {
	// "positive" is here because a vocabulary of negative, suggestion and mixed
	// can only ever record what went wrong. The corpus of what a good answer
	// looks like then has to be assembled from complaints, and complaints are
	// rare: nine days of traffic produced zero feedback rows on the busy
	// deployment. An operator saying "this one was right" is the cheapest
	// example of the target behaviour there is, and it had nowhere to go.
	case "negative", "positive", "suggestion", "mixed":
	default:
		return fmt.Errorf("result operation %q has unsupported feedback sentiment %q", operation.ID, operation.Feedback.Sentiment)
	}
	if operation.Feedback.NeedsFollowup && strings.TrimSpace(operation.Feedback.FollowupQuestion) == "" {
		return fmt.Errorf("result operation %q requires a follow-up question", operation.ID)
	}
	return nil
}

// validateTaskOperation checks a task offer's title and kind.
func validateTaskOperation(operation ResultOperation) error {
	if operation.Task == nil || strings.TrimSpace(operation.Task.Title) == "" {
		return fmt.Errorf("result operation %q requires a task title", operation.ID)
	}
	switch operation.Task.Kind {
	case "engineering", "incident":
	default:
		return fmt.Errorf("result operation %q has unsupported task kind %q", operation.ID, operation.Task.Kind)
	}
	return nil
}

func (operation ResultOperation) Validate() error {
	if strings.TrimSpace(operation.ID) == "" || len(operation.ID) > 80 {
		return fmt.Errorf("result operation requires a bounded id")
	}
	payloads := 0
	for _, present := range resultOperationPayloads {
		if present(operation) {
			payloads++
		}
	}
	if payloads != 1 {
		return fmt.Errorf("result operation %q requires exactly one typed payload", operation.ID)
	}
	validate, ok := resultOperationValidators[operation.Type]
	if !ok {
		return fmt.Errorf("result operation %q has unsupported type %q", operation.ID, operation.Type)
	}
	return validate(operation)
}

func ResultOperationsPrompt() string {
	return `Return results as a bounded ordered operations array. Each operation has a unique stable id
and exactly one payload matching its type. The host validates operations independently and records
accepted operations in the episode event stream.

- record_evidence: {"id":"evidence-1","type":"record_evidence","evidence":{"claim_id":"exact required_claims id from the host contract","claim":"short claim","observation":"what the source established","relation":"supports|contradicts","health_effect":"none|risk|degraded|unhealthy|unknown","source_type":"repository|emisar|monitoring|slack|other","source_id":"stable provider or result id","source_name":"human-readable source","observed_at":"RFC3339 source time","freshness":"source-relative age or revision","confidence":"high|medium|low","dimensions":{"service":"api","environment":"production","replicas":3},"scope_note":"optional bounded limitation"}}
- record_coverage: {"id":"coverage-host","type":"record_coverage","coverage":{"layer":"host","claim_ids":["host.current_state"],"status":"healthy|degraded|unhealthy|unknown|not_applicable","source":"short source label","detail":"bounded assessment","observed_at":"RFC3339 source time"}}
- report_progress: {"id":"progress-1","type":"report_progress","progress":{"phase":"investigating","summary":"meaningful operator-facing update","next_due_at":"optional RFC3339"}}
- plan_goal: {"id":"goal-plan-1","type":"plan_goal","goal":{"id":"goal-1","kind":"check|engineering|operation|schedule","requested_outcome":"...","completion_contract":"observable done condition","required":true,"prerequisite_goal_ids":[],"authority":"read_only|repository_write|governed_operation"}}
- update_goal: {"id":"goal-done-1","type":"update_goal","goal_state":{"goal_id":"goal-1","state":"ready|working|waiting|completed|blocked|excluded|cancelled","detail":"optional blocker"}}
- request_operator_input: {"id":"input-1","type":"request_operator_input","operator_input":{"question":"one exact question","choices":["optional choice"]}}
- wait_external: {"id":"wait-1","type":"wait_external","external_wait":{"id":"wakeup-1","kind":"github_checks|deployment|terraform_run|emisar_approval|scheduled_verification|other","event_matcher":{"provider":"github","pr":42},"poll_after":"RFC3339","deadline":"RFC3339"}}
- record_feedback: {"id":"feedback-1","type":"record_feedback","feedback":{"category":"ux|correctness|tone|latency|reliability|feature_request|other","sentiment":"negative|positive|suggestion|mixed","summary":"one actionable sentence","details":"optional concise context","target_message_ts":"optional target reply timestamp","needs_followup":false,"followup_question":"required when needs_followup"}}
- request_approval: {"id":"approval-1","type":"request_approval","approval":{...exact Emisar approval...}}
- offer_task: {"id":"task-1","type":"offer_task","task":{"kind":"engineering|incident","title":"...","repository":"...","prompt":"..."}}
- record_alert_assessment: {"id":"alert-1","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue|likely_issue|not_issue|unverified","impact":"current impact","cause_status":"identified|bounded when required","cause":"bounded cause","cause_claim_ids":["claim_id"],"evidence_refs":["evidence id for claim"],"immediate_action":"safe next step","verification":"success check","long_term_solution":"durable fix"}}
- record_repository_contents: {"id":"repo-contents-1","type":"record_repository_contents","repository_contents":{"repository":"exact alias from the repository set","contents":"one sentence naming which part of the product lives there"}}
- attach_visual{visual}, update_memory{memory}: one payload under the braced key. Offers use offer_memory{memory_offer: scope,subject,predicate,value,visibility}, offer_preference{preference_offer: scope,name,value}, offer_rule{rule_offer: scope,repository,trigger,action}, offer_schedule{schedule_offer: title,prompt,repository,recurrence,start_at}.
- complete_episode decision-ready example: {"id":"complete-1","type":"complete_episode","completion":{"message":"Slack Markdown answer","followup_messages":[],"completion":{"status":"decision_ready","verdict":"one exact completion.allowed_verdicts value when required","summary":"concise decision"}}}
- complete_episode blocked example: {"id":"complete-1","type":"complete_episode","completion":{"message":"exact blocker and useful result so far","coverage":[{"layer":"application","claim_ids":["application.functional_behavior"],"status":"unknown","detail":"exact evidence gap"}],"completion":{"status":"blocked","summary":"what cannot yet be decided","material_gaps":["missing material claim"],"blocker_kind":"source_unavailable|access_denied|operator_input_required|authority_boundary|tool_failure|capability_unavailable","attempts":["route already attempted"],"next_action":"exact action that unblocks it","capability_gaps":[{"capability":"GitHub Actions run and job inspection","status":"not_installed|not_trusted|not_advertised|incompatible|not_found","pack_id":"github-cli when an evidence source identifies it; omit for not_found","pack_ref":"optional observed immutable ref","evidence_refs":["source_id or source_name from a record_evidence operation"],"recommendation":"one concise operator-facing installation, trust, deployment, or compatibility step"}],"recheck":{"key":"provider:capability:identifier","reason":"why this exact external condition is expected to change shortly","after_seconds":120,"additional_attempts":3}}}}

Use record_repository_contents only for a repository you read this turn, and only to name which part
of the product it holds; it never expires, so it carries no version, health, or ownership claim. Send
it when the repository set marks one undescribed, or when what you read contradicts what it shows.

Use record_evidence once per atomic claim and record_coverage once per assessed claim group. Put
each memory update, visual, durable behavior offer, and alert assessment in its own
operation so one rejected item does not discard other accepted work. Use request_approval only for
an exact pending Emisar run. Use offer_task only for inert engineering or incident transitions. Outside
an engineering task, a concrete repository change recommendation MUST include an engineering offer_task
with repository and a bounded edit-and-validation prompt; do not merely tell the operator to start one.
Emisar MCP/control-plane operations such as runbook publication are not engineering tasks.
report_progress is for meaningful findings, never hidden reasoning or status noise. Exactly one complete_episode operation is
required for a reply or completed task report. A silent external wait uses ignore with
wait_external and no completion. Every non-conversational contract with required_claims
MUST emit at least one record_evidence operation bound to an exact required claim before complete_episode;
describing sources only in the message, memory, or coverage is invalid. Every required coverage item
MUST include its nonempty exact claim_ids entry from the contract. Evidence source_type must be
exactly one of repository, emisar, monitoring, slack, or other. Every coverage.layer must be one of
task, hardware, host, runtime, scheduler, workload, dependency, application, slo, or change. Emit one
coverage item for every required claim in the host investigation contract and use its exact layer
and claim id; never invent aliases such as configuration, rollout, or endpoint. When approval is
pending, include the exact pending_approval object returned by Emisar as the request_approval payload.`
}

func WatchEnvelopePrompt() string {
	return `The final watch response uses this outer envelope:
{"action":"ignore|react|reply|incident|escalate","reaction":"eyes for react only","title":"incident title for incident only","attention":{"addressee":"responder|channel|human|unclear","urgency":0,"confidence":0,"novelty":0,"ownership":0,"contribution":"none|material_correction|new_evidence|decision|completed_action|necessary_question","material":false},"reason":"concise classification reason","task_pull_request":"exact existing PR URL only","publication_updates":[],"operations":[]}

Every attention score is an integer from 0 through 3 inclusive. For ambient messages, name the
contribution and set material=true only when speaking changes understanding, a decision, or the next
action. Restatements, known blockers, generic advice, and unavailable access are none/false and ignore.

The outer JSON is only the transport envelope. Its whole field set is action, reaction, title,
attention, reason, task_pull_request, publication_updates and operations; nothing else may appear
beside them. Every part of a result — message, completion, evidence, coverage, memory, approvals,
task offers, durable behavior offers — is an operation from the list below. A legacy top-level
result field is read, then sent back once to be re-emitted as operations.
Background learning is independent of the Slack action. Ignore may have no operations, one update_memory,
or evidence/coverage/goal operations plus wait_external without completion. For
react, operations must be empty. For incident, use title and no operations. Recording a decision as
evidence is not a substitute for updating conversation memory. ` + ResultOperationsPrompt()
}
