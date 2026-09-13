package investigation

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/AndrewDryga/ryker/internal/assignments"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/knowledgeoffer"
	"github.com/AndrewDryga/ryker/internal/operationalscope"
	"github.com/AndrewDryga/ryker/internal/resultcontract"
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

type AlertAssessment = operationalscope.Assessment
type OperationalScope = operationalscope.Scope

// FindingOperation is a failure state the turn discovered, written where a
// contract can see it.
//
// On 2026-08-11 the 12:16 Zot triage (episode_run_ebbee0227d72743cc4aee48ef01113ba)
// closed decision_ready/succeeded on a Terraform Run-Applied event while its own
// reply said VA1 pyke "did not deploy: its rollout missed the progress deadline
// and automatically rolled back to job version 5 ... avoid retrying until the
// failed allocation or health check is identified". The rollback the turn had
// DISCOVERED lived only in prose, invisible to every validator the host owns, so
// nothing refused the completion. Three human nudges and 88 minutes later a deep
// dive found the root cause in four.
//
// unexplained is the honest default. explained is a claim, so it must name the
// evidence that identifies the cause; expected and out_of_scope are the two ways
// to stop, and both are classifications an operator can audit later rather than
// silences nobody can find.
type FindingOperation struct {
	// ID is the operation id the finding was recorded under, carried host-side
	// and deliberately kept out of the JSON contract: it is an identity signal
	// for CarryFindings, not a field the model fills or the envelope ships.
	ID string `json:"-"`
	// Key is a legacy wire field accepted for recorded-result compatibility.
	// The host always overwrites it from the operation id, so model output cannot
	// select or merge into another finding's identity.
	Key           string               `json:"key,omitempty"`
	What          string               `json:"what"`
	Scope         string               `json:"scope,omitempty"`
	Status        string               `json:"status"`
	CauseEvidence []string             `json:"cause_evidence,omitempty"`
	Alternatives  []FindingAlternative `json:"alternatives,omitempty"`
	Reason        string               `json:"reason,omitempty"`
}

// FindingAlternative is the adversarial residue of an identified cause: the
// strongest rival explanation, and what rules it out.
//
// The host never watches the model attack its own conclusion — prompts drift,
// and a process nothing checks is a process that quietly stops happening — so it
// checks the residue instead. Exactly one of DiscriminatedBy and NotCheckable is
// required, because "I considered it" with neither is the shape that proves
// nothing.
type FindingAlternative struct {
	Hypothesis      string `json:"hypothesis"`
	ClaimID         string `json:"claim_id,omitempty"`
	DiscriminatedBy string `json:"discriminated_by,omitempty"`
	NotCheckable    string `json:"not_checkable,omitempty"`
}

// FindingStatuses is the set a finding may report, named here so a rejection can
// quote it back rather than leaving the model to guess a fifth word.
var FindingStatuses = []string{"unexplained", "explained", "expected", "out_of_scope"}

// MaxFindingAlternatives and MaxFindingCauseEvidence bound the two lists a
// finding carries, on the same reasoning as MaxSupersededRecords: one failure
// state has a strongest rival and a runner-up, not a catalogue.
const (
	MaxFindingAlternatives  = 5
	MaxFindingCauseEvidence = 10
)

// ValidFindingStatus reports whether a normalized status is one the contract
// recognises.
func ValidFindingStatus(status string) bool {
	return slices.Contains(FindingStatuses, status)
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
	Verification string          `json:"verification,omitempty"`
	EventMatcher json.RawMessage `json:"event_matcher,omitempty"`
	DueAt        string          `json:"due_at,omitempty"`
	PollAfter    string          `json:"poll_after,omitempty"`
	Deadline     string          `json:"deadline,omitempty"`
}

func validateExternalWaitOperation(operation ResultOperation) error {
	wait := operation.ExternalWait
	if wait == nil {
		return fmt.Errorf(
			"result operation %q of type wait_external requires an external wait and observation time",
			operation.ID,
		)
	}
	wait.ID = strings.TrimSpace(wait.ID)
	wait.Kind = strings.TrimSpace(wait.Kind)
	wait.Verification = strings.TrimSpace(wait.Verification)
	wait.DueAt = strings.TrimSpace(wait.DueAt)
	wait.PollAfter = strings.TrimSpace(wait.PollAfter)
	wait.Deadline = strings.TrimSpace(wait.Deadline)
	if wait.ID == "" || wait.Kind == "" ||
		(wait.DueAt == "" && wait.PollAfter == "") {
		return fmt.Errorf(
			"result operation %q of type wait_external requires an external wait and observation time",
			operation.ID,
		)
	}
	if wait.Kind == "scheduled_verification" && wait.Verification == "" {
		return fmt.Errorf(
			"result operation %q scheduled_verification requires verification naming the observable success check",
			operation.ID,
		)
	}
	if len(wait.Verification) > 500 {
		return fmt.Errorf("result operation %q verification exceeds 500 bytes", operation.ID)
	}
	return nil
}

// FeedbackOperation records product feedback about Ryker itself. It is
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

// RecordKinds are the durable reads the host renders from the stored
// remediation record. They are named here rather than in the host so the
// rejection can quote the set back to a model that asked for "summary".
var RecordKinds = []string{"timeline", "evidence", "handoff", "postmortem"}

// RecordRequestOperation asks the host to publish one of its own reports.
//
// It carries no content, and that is the point. "Give me a handoff summary" is
// a request for the record, and a model answering it in prose writes a
// plausible timeline from whatever is in its context — which is the model's
// account of the work rather than the work's own. The host renders these four
// from the durable record, the same renderer the card's Record menu reaches, so
// asking in words and pressing the button produce the identical document.
type RecordRequestOperation struct {
	Kind string `json:"kind"`
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
// without telling Ryker, and this row never expires.
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
	Finding         *FindingOperation       `json:"finding,omitempty"`
	Progress        *ProgressOperation      `json:"progress,omitempty"`
	Goal            *GoalOperation          `json:"goal,omitempty"`
	GoalState       *GoalStateOperation     `json:"goal_state,omitempty"`
	OperatorInput   *OperatorInputOperation `json:"operator_input,omitempty"`
	ExternalWait    *ExternalWaitOperation  `json:"external_wait,omitempty"`
	Feedback        *FeedbackOperation      `json:"feedback,omitempty"`
	Record          *RecordRequestOperation `json:"record,omitempty"`
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
	// GrantOffer is the payload of offer_grant_promotion: a proposal that one
	// exact Emisar action has earned the next rung of the trust ladder. It
	// proposes and nothing more — the host recomputes the evidence and an
	// operator confirms. See core.GrantPromotionOffer for what it deliberately
	// cannot say.
	GrantOffer *core.GrantPromotionOffer `json:"grant_promotion,omitempty"`
	// RunbookOffer and CardOffer are the payloads of offer_runbook_draft and
	// offer_kb_card: proposals that a verified remediation should outlive the
	// episode that produced it, as an Emisar runbook draft or a committed
	// knowledge card. Both propose and nothing more — the host checks the
	// episode actually verified, rebuilds the runbook's action identity from
	// its own approval rows, and an operator confirms before anything exists.
	RunbookOffer *core.RunbookDraftOffer  `json:"runbook_draft,omitempty"`
	CardOffer    *core.KnowledgeCardOffer `json:"kb_card,omitempty"`
	// AssignmentOffer is the payload of offer_assignment, and it asks for more
	// than any other payload in this struct: standing authority to open pull
	// requests in one repository without a per-action click. It is a proposal
	// of BOUNDS and nothing else — the host normalizes every one of them, sets
	// shadow itself, derives the expiry from its own clock, and shows the
	// operator the normalized grant rather than these words. See
	// core.StandingAssignmentOffer for what it deliberately cannot say.
	AssignmentOffer *core.StandingAssignmentOffer `json:"assignment,omitempty"`
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
	func(o ResultOperation) bool { return o.Finding != nil },
	func(o ResultOperation) bool { return o.Progress != nil },
	func(o ResultOperation) bool { return o.Goal != nil },
	func(o ResultOperation) bool { return o.GoalState != nil },
	func(o ResultOperation) bool { return o.OperatorInput != nil },
	func(o ResultOperation) bool { return o.ExternalWait != nil },
	func(o ResultOperation) bool { return o.Approval != nil },
	func(o ResultOperation) bool { return o.Task != nil },
	func(o ResultOperation) bool { return o.Feedback != nil },
	func(o ResultOperation) bool { return o.Record != nil },
	func(o ResultOperation) bool { return o.Visual != nil },
	func(o ResultOperation) bool { return o.Memory != nil },
	func(o ResultOperation) bool { return o.MemoryOffer != nil },
	func(o ResultOperation) bool { return o.PreferenceOffer != nil },
	func(o ResultOperation) bool { return o.RuleOffer != nil },
	func(o ResultOperation) bool { return o.ScheduleOffer != nil },
	func(o ResultOperation) bool { return o.AlertAssessment != nil },
	func(o ResultOperation) bool { return o.RepositoryContents != nil },
	func(o ResultOperation) bool { return o.GrantOffer != nil },
	func(o ResultOperation) bool { return o.RunbookOffer != nil },
	func(o ResultOperation) bool { return o.CardOffer != nil },
	func(o ResultOperation) bool { return o.AssignmentOffer != nil },
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

// validateEvidenceOperation checks the record and the ids it retires.
//
// supersedes is the typed form of the move the contradiction correction
// prescribes, so its shape is refused where the model reads the answer. What
// this cannot check is whether the named record exists: one operation does not
// see the ledger. That half belongs to BuildLedger, which names the refusal in
// the correction rather than dropping it in silence.
func validateEvidenceOperation(o ResultOperation) error {
	if o.Evidence == nil {
		return fmt.Errorf("result operation %q requires evidence", o.ID)
	}
	if len(o.Evidence.Supersedes) > MaxSupersededRecords {
		return fmt.Errorf(
			"result operation %q supersedes %d records; one statement retires at most %d",
			o.ID, len(o.Evidence.Supersedes), MaxSupersededRecords,
		)
	}
	for _, id := range o.Evidence.Supersedes {
		if strings.TrimSpace(id) == "" {
			return fmt.Errorf(
				"result operation %q supersedes an unnamed record; supersedes carries the "+
					"exact evidence id of every record it retires",
				o.ID,
			)
		}
		// A record naming ITSELF is deliberately not an error. Re-emitting an
		// id already replaces the older record, so the self-entry is redundant
		// rather than wrong — and rejecting the whole response for it cost
		// eight blitz episodes a correction round each on 2026-08-15, every
		// one of them renaming an id to unsay a sentence the ledger was going
		// to skip anyway. SanitizeEvidence drops the entry before it persists.
	}
	return nil
}

var resultOperationValidators = map[string]func(ResultOperation) error{
	"record_evidence": validateEvidenceOperation,
	"record_coverage": validateCoverageOperation,
	"record_finding":  validateFindingOperation,
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
	"wait_external":              validateExternalWaitOperation,
	"record_feedback":            validateFeedbackOperation,
	"request_record":             validateRecordRequestOperation,
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
	// offer_grant_promotion is the one operation whose payload the host treats
	// as an argument rather than a result. Everything it claims is recomputed —
	// see internal/remediation.EvaluateOffer — and everything it does not say,
	// which is the whole scope, the expiry and the operator, the host fills in
	// itself. The validator's job is only to make sure the offer names one
	// complete immutable action identity and one reachable rung, so the deeper
	// refusals are about evidence rather than spelling.
	"offer_grant_promotion": validateGrantPromotionOperation,
	// The two knowledge offers delegate to internal/knowledgeoffer rather than
	// checking their shapes here, so the rule a model reads in a correction is
	// literally the rule the operator's confirmation click will be measured
	// against. Two copies of a slug pattern is two chances for an offer to be
	// accepted at result time and refused at confirm time for a reason nobody
	// was ever told.
	"offer_runbook_draft": func(o ResultOperation) error {
		return knowledgeoffer.ValidateRunbookOffer(o.ID, o.RunbookOffer)
	},
	"offer_kb_card": func(o ResultOperation) error {
		return knowledgeoffer.ValidateCardOffer(o.ID, o.CardOffer)
	},
	// offer_assignment delegates for the same reason, and the stakes make it
	// the least optional of the three. Every field it carries is a bound on
	// unattended pull-request authority, so a bound checked here and normalized
	// differently in internal/assignments would be an offer an operator
	// confirmed and a grant that says something else. One validator, reached by
	// the result, the card and the click.
	"offer_assignment": func(o ResultOperation) error {
		return assignments.ValidateOffer(o.ID, o.AssignmentOffer)
	},
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

// validateGrantPromotionOperation checks that a promotion offer names one
// complete, immutable Emisar identity and one reachable rung.
//
// It is strict about the action ref for the reason the whole ladder is: a grant
// is authority over exactly one action id, from exactly one pack, on exactly one
// runner, and an offer missing any of the three would either be refused later or
// — worse — be stored as a grant that matches whatever else is missing the same
// field. The rejection names the missing part so the next turn can supply it
// rather than guess.
//
// The rung check refuses "auto" here rather than deeper in, because that is
// where the model reads the answer. The auto rung is specified and not built,
// and a model that keeps asking for it should be told why once, in the
// correction it actually reads, instead of having the offer accepted and
// silently downgraded.
func validateGrantPromotionOperation(o ResultOperation) error {
	if o.GrantOffer == nil {
		return fmt.Errorf("result operation %q requires a grant promotion offer", o.ID)
	}
	offer := o.GrantOffer
	for _, part := range []struct{ name, value string }{
		{"action_id", offer.ActionID},
		{"pack_ref", offer.PackRef},
		{"runner_ref", offer.RunnerRef},
	} {
		if strings.TrimSpace(part.value) == "" {
			return fmt.Errorf(
				"result operation %q requires %s; a grant covers one exact Emisar action "+
					"identity — action id, pack ref and runner ref together — and never a "+
					"partial one",
				o.ID, part.name,
			)
		}
	}
	switch strings.TrimSpace(offer.Rung) {
	case "propose", "one_click":
	case "auto":
		return fmt.Errorf(
			"result operation %q asks for the auto rung, which this host cannot supervise; "+
				"the highest rung an operator can be offered is one_click",
			o.ID,
		)
	default:
		return fmt.Errorf(
			"result operation %q has unsupported rung %q; offer propose or one_click",
			o.ID, offer.Rung,
		)
	}
	if offer.VerifiedSuccesses < 0 {
		return fmt.Errorf("result operation %q reports a negative verified success count", o.ID)
	}
	return nil
}

// validateFindingOperation refuses a finding that claims more than it records.
//
// Each rule closes one way the Zot triage could have been written and still said
// nothing a contract can read. A status outside the set is quoted back with the
// whole set, because the worst recorded correction loop — 6.6 repeats on one
// episode — was a model picking from a list it could not see. "explained" must
// name the evidence, since an unbacked cause is the prose claim this operation
// replaces. "expected" and "out_of_scope" must carry the sentence an operator
// reviews later, or they are silences with a label on them. And an alternative
// carries exactly one of discriminated_by and not_checkable, because listing a
// rival hypothesis with neither is the residue that proves the attack did not
// happen.
func validateFindingOperation(o ResultOperation) error {
	if o.Finding == nil || strings.TrimSpace(o.Finding.What) == "" {
		return fmt.Errorf(
			"result operation %q requires a finding whose what names, in one line, what failed",
			o.ID,
		)
	}
	finding := o.Finding
	// Identity belongs to the host. Older results may carry a model-authored
	// key, so accept the field for wire compatibility but replace it before it
	// can match or retire a carried finding.
	finding.Key = FindingKeyForOperationID(o.ID)
	status := strings.ToLower(strings.TrimSpace(finding.Status))
	if !ValidFindingStatus(status) {
		return fmt.Errorf(
			"result operation %q reports finding status %q, which is not one of: %s",
			o.ID, finding.Status, strings.Join(FindingStatuses, ", "),
		)
	}
	named := func(value string) bool { return strings.TrimSpace(value) != "" }
	switch {
	case status == "explained" && !slices.ContainsFunc(finding.CauseEvidence, named):
		return fmt.Errorf(
			"result operation %q explains %q without naming what identified the cause; cite the "+
				"exact record_evidence id in cause_evidence, or report the finding as unexplained",
			o.ID, finding.What,
		)
	case (status == "expected" || status == "out_of_scope") && !named(finding.Reason):
		return fmt.Errorf(
			"result operation %q classifies %q as %s with no reason; that classification is the "+
				"record an operator reviews later, so it carries the sentence that justifies it",
			o.ID, finding.What, status,
		)
	}
	for _, alternative := range finding.Alternatives {
		if !named(alternative.Hypothesis) {
			return fmt.Errorf(
				"result operation %q lists an alternative with no hypothesis; an alternative is "+
					"the strongest rival cause, stated",
				o.ID,
			)
		}
		if named(alternative.DiscriminatedBy) == named(alternative.NotCheckable) {
			return fmt.Errorf(
				"result operation %q attacks %q without exactly one of discriminated_by and "+
					"not_checkable; give the evidence id that rules the alternative out, or say "+
					"why no available check discriminates",
				o.ID, alternative.Hypothesis,
			)
		}
	}
	return nil
}

// FindingKeyForOperationID is the host-owned identity rule for finding
// corrections. The model may add the documented correction suffix, but it
// cannot choose the key of another open finding and retire that record.
func FindingKeyForOperationID(id string) string {
	id = strings.ToLower(strings.TrimSpace(id))
	for strings.HasSuffix(id, "-corrected") {
		id = strings.TrimSuffix(id, "-corrected")
	}
	return id
}

// validateRecordRequestOperation checks the one enum a record request carries.
//
// The rejection lists the four kinds because there is no partial credit here:
// an unrecognised kind renders nothing, and a model that guessed "summary" has
// no way to learn the real set from silence.
func validateRecordRequestOperation(operation ResultOperation) error {
	if operation.Record == nil {
		return fmt.Errorf("result operation %q requires a record request", operation.ID)
	}
	kind := strings.ToLower(strings.TrimSpace(operation.Record.Kind))
	if !slices.Contains(RecordKinds, kind) {
		return fmt.Errorf(
			"result operation %q requests record %q, which is not one of: %s",
			operation.ID, operation.Record.Kind, strings.Join(RecordKinds, ", "),
		)
	}
	return nil
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

// CountGoalOperations counts what a result did about its plan.
//
// It exists so the host can meter adoption of an instruction it has just
// started giving: plan_goal and update_goal have been valid operations since
// this file was written and no result has ever carried one, so "did the ask
// land" is a question with a number behind it rather than an impression.
func CountGoalOperations(operations []ResultOperation) (planned, updated int) {
	for _, operation := range operations {
		switch operation.Type {
		case "plan_goal":
			planned++
		case "update_goal":
			updated++
		}
	}
	return planned, updated
}

func ResultOperationsPrompt() string {
	return resultcontract.SelfValidationPrompt() + `

Return results as a bounded ordered operations array. Each operation has a unique stable id
and exactly one payload matching its type. The host validates operations independently and records
accepted operations in the episode stream.

- record_evidence: {"id":"e1","type":"record_evidence","evidence":{"claim_id":"required id or stable slug","claim":"claim","observation":"the finding in one sentence an on-call can read","relation":"supports|contradicts","health_effect":"none|risk|degraded|unhealthy|unknown","source_type":"repository|emisar|monitoring|slack|other","source_id":"provider id","source_name":"source","observed_at":"RFC3339","freshness":"age/revision","confidence":"high|medium|low","dimensions":{"service":"api"},"target":"checked target","supersedes":["retired id"],"scope_note":"limit"}} — observation reaches Slack verbatim: write what the check showed, not the transcript that showed it. Ids, timings, headers, and filters go in source_id, freshness, and dimensions. Not "GET returned http_code=200 in 25.5 ms (DNS 0.8, TLS 20.1), etag W/2360cc, cdn-cache HIT"; instead "The CDN served every request from cache, with no 5xx."
- record_coverage: {"id":"coverage-host","type":"record_coverage","coverage":{"layer":"host","claim_ids":["host.current_state"],"status":"healthy|degraded|unhealthy|unknown|not_applicable","source":"short source label","detail":"bounded assessment","observed_at":"RFC3339 source time"}}
- record_finding: {"id":"f1","type":"record_finding","finding":{"what":"failure","scope":"system","status":"unexplained|explained|expected|out_of_scope","cause_evidence":["if explained"],"alternatives":[{"hypothesis":"rival","claim_id":"claim contradicted","discriminated_by":"evidence id"|"not_checkable":"why unavailable"}],"reason":"for expected|out_of_scope"}} — one per failure. Keep the same id for a rewrite, or add only the -corrected suffix; the host owns the stable key. A discriminator contradicts claim_id. unexplained is the honest default; close with not_checkable.
- report_progress: {"id":"progress-1","type":"report_progress","progress":{"phase":"investigating","summary":"meaningful operator-facing update","next_due_at":"optional RFC3339"}}
- plan_goal: {"id":"goal-plan-1","type":"plan_goal","goal":{"id":"goal-1","kind":"check|engineering|operation|schedule","requested_outcome":"...","completion_contract":"observable done condition","required":true,"prerequisite_goal_ids":[],"authority":"read_only|repository_write|governed_operation"}}
- update_goal: {"id":"goal-done-1","type":"update_goal","goal_state":{"goal_id":"goal-1","state":"ready|working|waiting|completed|blocked|excluded|cancelled","detail":"optional blocker"}}
- request_operator_input: {"id":"input-1","type":"request_operator_input","operator_input":{"question":"one exact question","choices":["optional choice"]}}
- wait_external: {"id":"w","type":"wait_external","external_wait":{"id":"wakeup","kind":"github_checks|deployment|terraform_run|emisar_approval|scheduled_verification|other","verification":"success check","event_matcher":{},"poll_after":"RFC3339","deadline":"RFC3339"}}
- request_record: {"id":"record-1","type":"request_record","record":{"kind":"timeline|evidence|handoff|postmortem"}}
- record_feedback: {"id":"feedback-1","type":"record_feedback","feedback":{"category":"ux|correctness|tone|latency|reliability|feature_request|other","sentiment":"negative|positive|suggestion|mixed","summary":"one actionable sentence","details":"optional concise context","target_message_ts":"optional target reply timestamp","needs_followup":false,"followup_question":"required when needs_followup"}}
- request_approval: {"id":"approval-1","type":"request_approval","approval":{...exact Emisar approval...}}
- offer_task: {"id":"task-1","type":"offer_task","task":{"kind":"engineering|incident","title":"...","repository":"...","prompt":"..."}}
- record_alert_assessment: {"id":"a1","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue|likely_issue|not_issue|unverified","impact":"impact within checked scope","cause_status":"identified|bounded","cause":"cause","cause_claim_ids":["claim id"],"evidence_refs":["cause evidence id"],"immediate_action_kind":"mitigation|monitor|investigation|none","immediate_action":"next step","verification":"success check","long_term_solution":"durable fix","scope":{"status":"bounded|exhaustive","checked_targets":["exact evidence.target"],"unverified_targets":["required when bounded"],"evidence_refs":["per-target and boundary evidence"],"universe_evidence_ref":"required when exhaustive"}}} — confirmed/likely requires cause_status. Top-level evidence_refs is CAUSE evidence only and every item must belong to cause_claim_ids. Put change, impact, and other boundary evidence in scope.evidence_refs. checked_targets copies exact evidence.target strings without paraphrasing. Firing source alerts cannot be not_issue before their matching resolution. A bounded cause continues via wait/recheck or blocks. Exhaustive requires host-attested complete target universe; otherwise use bounded. The host writes Slack scope prose.
- record_repository_contents: {"id":"repo-contents-1","type":"record_repository_contents","repository_contents":{"repository":"exact alias from the repository set","contents":"one sentence naming which part of the product lives there"}}
- offer_grant_promotion: {"id":"grant-1","type":"offer_grant_promotion","grant_promotion":{"action_id":"exact Emisar action id","pack_ref":"exact pack ref","runner_ref":"exact runner ref","rung":"propose|one_click","verified_successes":3,"rationale":"one sentence for the operator"}} — the host sets the scope itself and never widens it.
- offer_runbook_draft: {"id":"rb-1","type":"offer_runbook_draft","runbook_draft":{"title":"<=80 chars","slug":"lowercase-slug","summary":"when to run it","action_id":"exact Emisar action id","pack_ref":"exact pack ref","runner_ref":"exact runner ref"}} — the host rebuilds the step from its own approval record.
- offer_kb_card: {"id":"kb-1","type":"offer_kb_card","kb_card":{"slug":"lowercase-slug","title":"<=80 chars","body":"Markdown <4096 bytes, no top heading"}} — durable behavior; confirmed, it becomes a draft PR nobody merges.
- offer_assignment: {"id":"assign-1","type":"offer_assignment","assignment":{"repository":"exact alias","change_class":"dependency_upgrade|alert_threshold|flaky_test_quarantine|observability|documentation","signal_pattern":"words to watch for","path_globs":["optional, <=10"],"daily_budget":1-20,"expiry_days":1-90}} — ONLY when an operator asks for standing unattended work in one of those change classes; a time-driven recurring check is offer_schedule, not an assignment. Emit it BESIDE your one complete_episode whose message says the card follows.
Those four propose only — the host recomputes or normalizes, refuses what it cannot reproduce, and an operator confirms; each takes an optional rationale. The first three are for work THIS episode ran and verified; an assignment is always created shadowed.
- attach_visual{visual}, update_memory{memory}: one payload under the braced key. Offers use offer_memory{memory_offer: scope,subject,predicate,value,visibility}, offer_preference{preference_offer: scope,name,value}, offer_rule{rule_offer: scope,repository,trigger,action}, offer_schedule{schedule_offer: title,prompt,repository,recurrence,start_at,interval_seconds,weekdays,local_time,timezone,day_of_month} — recurrence is one word (once|interval|daily|weekly|monthly). once requires RFC3339 start_at; interval requires interval_seconds from 300 to 31536000; daily/weekly/monthly require local_time and timezone; weekly also requires weekdays and monthly day_of_month. start_at is optional for recurring schedules. Never put cadence detail inside recurrence.
- complete_episode decision-ready example: {"id":"complete-1","type":"complete_episode","completion":{"message":"Slack Markdown answer","followup_messages":[],"completion":{"status":"decision_ready","verdict":"one exact completion.allowed_verdicts value when required","summary":"concise decision"}}}
- complete_episode blocked example: {"id":"complete-1","type":"complete_episode","completion":{"message":"exact blocker and useful result so far","completion":{"status":"blocked","summary":"what cannot yet be decided","material_gaps":["missing material claim"],"blocker_kind":"source_unavailable|access_denied|operator_input_required|authority_boundary|tool_failure|capability_unavailable","attempts":["route already attempted"],"next_action":"exact action that unblocks it","capability_gaps":[{"capability":"GitHub Actions run and job inspection","status":"not_installed|not_trusted|not_advertised|incompatible|not_found","pack_id":"github-cli when an evidence source identifies it; omit for not_found","pack_ref":"optional observed immutable ref","evidence_refs":["source_id or source_name from a record_evidence operation"],"recommendation":"one concise operator-facing installation, trust, deployment, or compatibility step"}],"recheck":{"key":"provider:capability:identifier","reason":"why this exact external condition is expected to change shortly","after_seconds":120,"additional_attempts":3}}}}

Use record_repository_contents only for a repository you read this turn, and only to name which part
of the product it holds; it never expires, so it carries no version, health, or ownership claim. Send
it when the repository set marks one undescribed, or when what you read contradicts what it shows.

Use record_evidence once per atomic claim and record_coverage once per assessed claim group. Only
supersedes retires a recorded statement, naming its exact id on the same claim with a later
observed_at; saying so in the observation does not. Put
each memory update, visual, durable behavior offer, and alert assessment in its own
operation so one rejected item does not discard other accepted work. Use request_approval only for
an exact pending Emisar run. Use offer_task only for inert engineering or incident transitions. Outside
an engineering task, a concrete repository change recommendation MUST include an engineering offer_task
with repository and a bounded edit-and-validation prompt; do not merely tell the operator to start one.
Emisar MCP/control-plane operations such as runbook publication are not engineering tasks.
Asked for the timeline, evidence, a handoff or a postmortem, emit request_record BESIDE your one
complete_episode — the completion message is one line saying the record follows, and the record
itself is never yours to write; the host renders those four from the durable record.
report_progress is for meaningful findings, never hidden reasoning or status noise. Exactly one complete_episode operation is
required for a reply or completed task report. Answering a host correction, send only the operations you
are changing beside that one complete_episode: a record_evidence, record_coverage or record_finding you
omit is kept exactly as it was, and re-sending one under the same id replaces it. A silent external wait uses ignore with
wait_external and no completion. Every non-conversational contract with required_claims
MUST emit at least one record_evidence operation bound to an exact required claim before complete_episode;
describing sources only in the message, memory, or coverage is invalid. Every required coverage item
MUST include its nonempty exact claim_ids entry from the contract. Evidence source_type must be
exactly one of repository, emisar, monitoring, slack, or other. Every coverage.layer must be one of
task, hardware, host, runtime, scheduler, workload, dependency, application, slo, or change. Emit one
coverage item for every required claim in the host investigation contract and use its exact layer
and claim id; never invent aliases such as configuration, rollout, or endpoint. When approval is
pending, include the exact pending_approval object returned by Emisar as the request_approval payload.

Final shape check, before returning:
- one JSON object, no code fence, no prose outside it;
- every enum is one exact listed string; every operation type is the full verb form
  (record_alert_assessment), never the bare payload noun;
- evidence confidence is high, medium, or low — the 0-3 integers belong to attention scores alone;
- exactly one complete_episode for a reply or completed report; ignore omits it only for silence
  or a wait_external;
- a blocked completion carries summary, material_gaps, blocker_kind, attempts, and next_action
  together — a partial blocker is rejected whole;
- a capability_unavailable blocker always carries completion.capability_gaps; record the
  find_actions or list_packs observation as record_evidence (an emisar or repository source, never
  your own tool inventory) and cite its id in the gap's evidence_refs; pack_id only when that
  evidence names the exact pack, else status not_found and no pack_id;
- every required claim has record_evidence bound to its exact claim_id before complete_episode.`
}

func WatchEnvelopePrompt() string {
	return `The final watch response uses this outer envelope:
{"action":"ignore|react|reply|incident|escalate","reaction":"eyes for react only","title":"incident title for incident only","attention":{"addressee":"ryker|channel|human|unclear","urgency":0,"confidence":0,"novelty":0,"ownership":0,"contribution":"none|material_correction|new_evidence|decision|completed_action|necessary_question","material":false},"reason":"concise classification reason","task_pull_request":"exact existing PR URL only","publication_updates":[],"operations":[]}

Every attention score is an integer from 0 through 3 inclusive. For ambient messages, name the
contribution and set material=true only when speaking changes understanding, a decision, or the next
action. Restatements, known blockers, generic advice, and unavailable access are none/false and ignore.

The outer JSON is only the transport envelope. Its whole field set is action, reaction, title,
attention, reason, task_pull_request, publication_updates and operations; nothing else may appear
beside them. Every part of a result — message, completion, evidence, coverage, memory, approvals,
task offers, durable behavior offers — is an operation from the list below.
Background learning is independent of the Slack action. Ignore may have no operations, one update_memory,
or evidence/coverage/goal operations plus wait_external without completion. For
react, operations must be empty. For incident, use title and no operations. Recording a decision as
evidence is not a substitute for updating conversation memory. ` + ResultOperationsPrompt()
}
