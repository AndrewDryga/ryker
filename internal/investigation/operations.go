package investigation

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

type CompletionAssessment struct {
	Status       string   `json:"status"`
	Verdict      string   `json:"verdict,omitempty"`
	Summary      string   `json:"summary"`
	MaterialGaps []string `json:"material_gaps,omitempty"`
	BlockerKind  string   `json:"blocker_kind,omitempty"`
	Blocker      string   `json:"blocker,omitempty"`
	Attempts     []string `json:"attempts,omitempty"`
	NextAction   string   `json:"next_action,omitempty"`
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
	ID         string               `json:"id"`
	Type       string               `json:"type"`
	Evidence   *core.Evidence       `json:"evidence,omitempty"`
	Progress   *ProgressOperation   `json:"progress,omitempty"`
	Approval   *core.EmisarApproval `json:"approval,omitempty"`
	Task       *TaskOffer           `json:"task,omitempty"`
	Completion *CompleteEpisode     `json:"completion,omitempty"`
}

func (operation ResultOperation) Validate() error {
	if strings.TrimSpace(operation.ID) == "" || len(operation.ID) > 80 {
		return fmt.Errorf("result operation requires a bounded id")
	}
	payloads := 0
	for _, present := range []bool{
		operation.Evidence != nil, operation.Progress != nil, operation.Approval != nil,
		operation.Task != nil, operation.Completion != nil,
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

- record_evidence: {"id":"evidence-1","type":"record_evidence","evidence":{"claim_id":"exact required_claims id from the host contract","claim":"short claim","observation":"what the source established","relation":"supports|contradicts","source_type":"repository|emisar|monitoring|slack|other","source_id":"stable provider or result id","source_name":"human-readable source","observed_at":"RFC3339 source time","freshness":"source-relative age or revision","confidence":"high|medium|low","dimensions":{"service":"api","environment":"production","replicas":3},"scope_note":"optional bounded limitation"}}
- report_progress: {"id":"progress-1","type":"report_progress","progress":{"phase":"investigating","summary":"meaningful operator-facing update","next_due_at":"optional RFC3339"}}
- request_approval: {"id":"approval-1","type":"request_approval","approval":{...exact Emisar approval...}}
- offer_task: {"id":"task-1","type":"offer_task","task":{"kind":"engineering|incident","title":"...","repository":"...","prompt":"..."}}
- complete_episode decision-ready example: {"id":"complete-1","type":"complete_episode","completion":{"message":"Slack Markdown answer","followup_messages":[],"coverage":[{"layer":"host","claim_ids":["host.current_state"],"status":"healthy|degraded|unhealthy|unknown|not_applicable","source":"short source label","detail":"bounded assessment","observed_at":"RFC3339 source time"}],"memory":{"topology":["two production hosts"]},"completion":{"status":"decision_ready","verdict":"healthy|degraded|unhealthy","summary":"concise decision"}}}
- complete_episode blocked example: {"id":"complete-1","type":"complete_episode","completion":{"message":"exact blocker and useful result so far","coverage":[{"layer":"application","claim_ids":["application.functional_behavior"],"status":"unknown","detail":"exact evidence gap"}],"completion":{"status":"blocked","summary":"what cannot yet be decided","material_gaps":["missing material claim"],"blocker_kind":"source_unavailable|access_denied|operator_input_required|authority_boundary|tool_failure","attempts":["route already attempted"],"next_action":"exact action that unblocks it"}}}

Use record_evidence once per atomic claim. Put presentation, coverage, memory, visuals, durable
behavior offers, alert assessment, completion assessment, and action proposals only in the final
complete_episode payload. Use request_approval only for an exact pending Emisar run. Use offer_task
only for an inert engineering or incident transition. report_progress is for a meaningful interim
finding, not hidden reasoning or repetitive status. Exactly one complete_episode operation is
required for a reply or completed task report. Every non-conversational contract with required_claims
MUST emit at least one record_evidence operation bound to an exact required claim before complete_episode;
describing sources only in the message, memory, or coverage is invalid. Every required coverage item
MUST include its nonempty exact claim_ids entry from the contract. Evidence source_type must be
exactly one of repository, emisar, monitoring, slack, or other. Every coverage.layer must be one of
hardware, host, runtime, scheduler, workload, dependency, application, slo, or change. Emit one
coverage item for every required claim in the host investigation contract and use its exact layer
and claim id; never invent aliases such as configuration, rollout, or endpoint. When approval is
pending, include the exact pending_approval object returned by Emisar as the request_approval payload.`
}

func WatchEnvelopePrompt() string {
	return `The final watch response uses this outer envelope:
{"action":"ignore|react|reply|incident|escalate","reaction":"eyes for react only","title":"incident title for incident only","attention":{"addressee":"responder|channel|human|unclear","urgency":0,"confidence":0,"novelty":0,"ownership":0},"reason":"concise classification reason","publication_updates":[],"operations":[]}

Every attention score is an integer from 0 through 3 inclusive. Never emit 4 or a larger value.

The outer JSON is only the transport envelope; typed result operations carry the investigated result.
For ignore or react, operations must be empty. For incident, use title and no operations. For reply,
put all evidence, progress, approvals, inert task offers, and the final response in operations; do not
duplicate their legacy top-level fields. ` + ResultOperationsPrompt()
}
