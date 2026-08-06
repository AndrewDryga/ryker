package investigation

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
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
	Verdict          string `json:"verdict"`
	Impact           string `json:"impact"`
	CauseStatus      string `json:"cause_status,omitempty"`
	Cause            string `json:"cause,omitempty"`
	ImmediateAction  string `json:"immediate_action,omitempty"`
	Verification     string `json:"verification,omitempty"`
	LongTermSolution string `json:"long_term_solution,omitempty"`
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
	Proposals        []core.ActionProposal  `json:"proposals,omitempty"`
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
	Proposal        *core.ActionProposal    `json:"proposal,omitempty"`
	Completion      *CompleteEpisode        `json:"completion,omitempty"`
}

func (operation ResultOperation) Validate() error {
	if strings.TrimSpace(operation.ID) == "" || len(operation.ID) > 80 {
		return fmt.Errorf("result operation requires a bounded id")
	}
	payloads := 0
	for _, present := range []bool{
		operation.Evidence != nil, operation.Coverage != nil, operation.Progress != nil,
		operation.Goal != nil, operation.GoalState != nil, operation.OperatorInput != nil,
		operation.ExternalWait != nil, operation.Approval != nil, operation.Task != nil,
		operation.Feedback != nil,
		operation.Visual != nil, operation.Memory != nil, operation.MemoryOffer != nil,
		operation.PreferenceOffer != nil, operation.RuleOffer != nil,
		operation.ScheduleOffer != nil, operation.AlertAssessment != nil,
		operation.Proposal != nil, operation.Completion != nil,
	} {
		if present {
			payloads++
		}
	}
	if payloads != 1 {
		return fmt.Errorf("result operation %q requires exactly one typed payload", operation.ID)
	}
	switch operation.Type {
	case "record_evidence":
		if operation.Evidence == nil {
			return fmt.Errorf("result operation %q requires evidence", operation.ID)
		}
	case "report_progress":
		if operation.Progress == nil || strings.TrimSpace(operation.Progress.Phase) == "" ||
			strings.TrimSpace(operation.Progress.Summary) == "" {
			return fmt.Errorf("result operation %q requires progress phase and summary", operation.ID)
		}
	case "record_coverage":
		if operation.Coverage == nil {
			return fmt.Errorf("result operation %q requires coverage", operation.ID)
		}
	case "plan_goal":
		if operation.Goal == nil || strings.TrimSpace(operation.Goal.ID) == "" ||
			strings.TrimSpace(operation.Goal.Kind) == "" ||
			strings.TrimSpace(operation.Goal.RequestedOutcome) == "" ||
			strings.TrimSpace(operation.Goal.CompletionContract) == "" {
			return fmt.Errorf("result operation %q requires a typed goal", operation.ID)
		}
	case "update_goal":
		if operation.GoalState == nil || strings.TrimSpace(operation.GoalState.GoalID) == "" ||
			strings.TrimSpace(string(operation.GoalState.State)) == "" {
			return fmt.Errorf("result operation %q requires goal id and state", operation.ID)
		}
	case "request_operator_input":
		if operation.OperatorInput == nil || strings.TrimSpace(operation.OperatorInput.Question) == "" {
			return fmt.Errorf("result operation %q requires an operator question", operation.ID)
		}
	case "wait_external":
		if operation.ExternalWait == nil || strings.TrimSpace(operation.ExternalWait.ID) == "" ||
			strings.TrimSpace(operation.ExternalWait.Kind) == "" ||
			(operation.ExternalWait.DueAt == "" && operation.ExternalWait.PollAfter == "") {
			return fmt.Errorf("result operation %q requires an external wait and observation time", operation.ID)
		}
	case "record_feedback":
		if operation.Feedback == nil || strings.TrimSpace(operation.Feedback.Summary) == "" {
			return fmt.Errorf("result operation %q requires a feedback summary", operation.ID)
		}
		switch operation.Feedback.Category {
		case "ux", "correctness", "tone", "latency", "reliability", "feature_request", "other":
		default:
			return fmt.Errorf("result operation %q has unsupported feedback category %q", operation.ID, operation.Feedback.Category)
		}
		switch operation.Feedback.Sentiment {
		case "negative", "suggestion", "mixed":
		default:
			return fmt.Errorf("result operation %q has unsupported feedback sentiment %q", operation.ID, operation.Feedback.Sentiment)
		}
		if operation.Feedback.NeedsFollowup && strings.TrimSpace(operation.Feedback.FollowupQuestion) == "" {
			return fmt.Errorf("result operation %q requires a follow-up question", operation.ID)
		}
	case "request_approval":
		if operation.Approval == nil {
			return fmt.Errorf("result operation %q requires approval", operation.ID)
		}
	case "offer_task":
		if operation.Task == nil || strings.TrimSpace(operation.Task.Title) == "" {
			return fmt.Errorf("result operation %q requires a task title", operation.ID)
		}
		switch operation.Task.Kind {
		case "engineering", "incident":
		default:
			return fmt.Errorf("result operation %q has unsupported task kind %q", operation.ID, operation.Task.Kind)
		}
	case "attach_visual":
		if operation.Visual == nil || strings.TrimSpace(operation.Visual.Artifact) == "" {
			return fmt.Errorf("result operation %q requires a visual artifact", operation.ID)
		}
	case "update_memory":
		if operation.Memory == nil {
			return fmt.Errorf("result operation %q requires memory", operation.ID)
		}
	case "offer_memory":
		if operation.MemoryOffer == nil {
			return fmt.Errorf("result operation %q requires a memory offer", operation.ID)
		}
	case "offer_preference":
		if operation.PreferenceOffer == nil {
			return fmt.Errorf("result operation %q requires a preference offer", operation.ID)
		}
	case "offer_rule":
		if operation.RuleOffer == nil {
			return fmt.Errorf("result operation %q requires a rule offer", operation.ID)
		}
	case "offer_schedule":
		if operation.ScheduleOffer == nil {
			return fmt.Errorf("result operation %q requires a schedule offer", operation.ID)
		}
	case "record_alert_assessment":
		if operation.AlertAssessment == nil {
			return fmt.Errorf("result operation %q requires an alert assessment", operation.ID)
		}
	case "propose_action":
		if operation.Proposal == nil {
			return fmt.Errorf("result operation %q requires an action proposal", operation.ID)
		}
	case "complete_episode":
		if operation.Completion == nil || strings.TrimSpace(operation.Completion.Message) == "" {
			return fmt.Errorf("result operation %q requires a completion message", operation.ID)
		}
	default:
		return fmt.Errorf("result operation %q has unsupported type %q", operation.ID, operation.Type)
	}
	return nil
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
- record_feedback: {"id":"feedback-1","type":"record_feedback","feedback":{"category":"ux|correctness|tone|latency|reliability|feature_request|other","sentiment":"negative|suggestion|mixed","summary":"one actionable sentence","details":"optional concise context","target_message_ts":"optional Slack timestamp of the Responder reply being criticized","needs_followup":false,"followup_question":"required only when needs_followup is true"}}
- request_approval: {"id":"approval-1","type":"request_approval","approval":{...exact Emisar approval...}}
- offer_task: {"id":"task-1","type":"offer_task","task":{"kind":"engineering|incident","title":"...","repository":"...","prompt":"..."}}
- record_alert_assessment: {"id":"alert-1","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue|likely_issue|not_issue|unverified","impact":"current operator impact","cause_status":"identified|bounded when required","cause":"bounded cause when required","immediate_action":"what to do now","verification":"observable success condition","long_term_solution":"durable fix when required"}}
- attach_visual, update_memory, offer_memory, offer_preference, offer_rule, offer_schedule, and propose_action carry the same named typed payload that their operation name describes.
- complete_episode decision-ready example: {"id":"complete-1","type":"complete_episode","completion":{"message":"Slack Markdown answer","followup_messages":[],"completion":{"status":"decision_ready","verdict":"one exact completion.allowed_verdicts value when required","summary":"concise decision"}}}
- complete_episode blocked example: {"id":"complete-1","type":"complete_episode","completion":{"message":"exact blocker and useful result so far","coverage":[{"layer":"application","claim_ids":["application.functional_behavior"],"status":"unknown","detail":"exact evidence gap"}],"completion":{"status":"blocked","summary":"what cannot yet be decided","material_gaps":["missing material claim"],"blocker_kind":"source_unavailable|access_denied|operator_input_required|authority_boundary|tool_failure|capability_unavailable","attempts":["route already attempted"],"next_action":"exact action that unblocks it","capability_gaps":[{"capability":"GitHub Actions run and job inspection","status":"not_installed|not_trusted|not_advertised|incompatible|not_found","pack_id":"github-cli when an evidence source identifies it; omit for not_found","pack_ref":"optional observed immutable ref","evidence_refs":["source_id or source_name from a record_evidence operation"],"recommendation":"one concise operator-facing installation, trust, deployment, or compatibility step"}],"recheck":{"key":"provider:capability:identifier","reason":"why this exact external condition is expected to change shortly","after_seconds":120,"additional_attempts":3}}}}

Use record_evidence once per atomic claim and record_coverage once per assessed claim group. Put
each memory update, visual, durable behavior offer, alert assessment, and action proposal in its own
operation so one rejected item does not discard other accepted work. Use request_approval only for
an exact pending Emisar run. Use offer_task
only for an inert engineering or incident transition. Outside an existing engineering task, whenever
the response recommends a concrete change to versioned repository files, emit an engineering offer_task
in that same response instead of merely telling the operator to start a task. Include the resolved
repository and a bounded task.prompt covering the intended edit and validation. Do not use an
engineering task for an Emisar MCP/control-plane operation such as creating or publishing a runbook.
report_progress is for a meaningful interim
finding, not hidden reasoning or repetitive status. Exactly one complete_episode operation is
required for a reply or completed task report. Every non-conversational contract with required_claims
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
{"action":"ignore|react|reply|incident|escalate","reaction":"eyes for react only","title":"incident title for incident only","attention":{"addressee":"responder|channel|human|unclear","urgency":0,"confidence":0,"novelty":0,"ownership":0},"reason":"concise classification reason","publication_updates":[],"operations":[]}

Every attention score is an integer from 0 through 3 inclusive. Never emit 4 or a larger value.

The outer JSON is only the transport envelope; typed result operations carry the investigated result.
Background learning is independent of the Slack action. For ignore, operations may be empty or contain
exactly one update_memory operation so a settled human conversation can be learned without posting. For
react, operations must be empty. For incident, use title and no operations. For reply, put all evidence,
progress, approvals, inert task offers, any required update_memory, and the final response in operations;
do not duplicate their legacy top-level fields. Recording a decision as evidence is not a substitute for
updating conversation memory. ` + ResultOperationsPrompt()
}
