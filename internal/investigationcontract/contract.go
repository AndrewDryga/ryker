// Package investigationcontract owns the durable investigation vocabulary,
// contract compilation, and the prompt text that explains that contract.
package investigationcontract

import (
	"encoding/json"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const Version = "2026-08-10.1"

type FreshnessRequirement struct {
	Class  string        `json:"class"`
	MaxAge time.Duration `json:"-"`
}

func (requirement FreshnessRequirement) MarshalJSON() ([]byte, error) {
	type wire struct {
		Class  string `json:"class"`
		MaxAge string `json:"max_age,omitempty"`
	}
	value := wire{Class: requirement.Class}
	if requirement.MaxAge > 0 {
		value.MaxAge = requirement.MaxAge.String()
	}
	return json.Marshal(value)
}

type ClaimRequirement struct {
	ID          string               `json:"id"`
	Layer       string               `json:"layer"`
	Question    string               `json:"question"`
	Proposition string               `json:"proposition"`
	Required    bool                 `json:"required"`
	Freshness   FreshnessRequirement `json:"freshness"`
	Dimensions  []string             `json:"dimensions,omitempty"`
}

type CompletionRule struct {
	AllowedStatuses  []string `json:"allowed_statuses"`
	ConclusionKind   string   `json:"conclusion_kind"`
	AllowedVerdicts  []string `json:"allowed_verdicts,omitempty"`
	RequireVerdict   bool     `json:"require_verdict"`
	RequireDiagnosis bool     `json:"require_diagnosis_for_active_issue"`
	AllowUnknownSLO  bool     `json:"allow_not_applicable_slo"`
}

type InvestigationContract struct {
	Version            string                 `json:"version"`
	Effort             core.EffortContract    `json:"effort"`
	Authority          core.AuthorityBoundary `json:"authority"`
	Objective          string                 `json:"objective"`
	Claims             []ClaimRequirement     `json:"required_claims,omitempty"`
	CompletionCriteria []string               `json:"completion_criteria"`
	Completion         CompletionRule         `json:"completion"`
	ResultOperations   []string               `json:"result_operations"`
}

var layerClaims = map[string]ClaimRequirement{
	"task": {
		ID: "task.requested_outcome", Layer: "task",
		Question:    "What requested task result is complete, and what concrete step remains?",
		Proposition: "The requested task outcome is complete within the stated boundary.",
		Freshness:   FreshnessRequirement{Class: "current_revision"},
		Dimensions:  []string{"artifact", "revision"},
	},
	"hardware": {
		ID: "hardware.current_condition", Layer: "hardware",
		Question:    "Are physical components or storage paths unhealthy or saturated?",
		Proposition: "Physical components and storage paths are healthy and not saturated.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 15 * time.Minute},
		Dimensions:  []string{"physical_target", "component"},
	},
	"change": {
		ID: "change.recent", Layer: "change",
		Question:    "What recent deployed or configured changes could affect the current result?",
		Proposition: "The observed state is consistent with the intended current revision and recent rollout.",
		Freshness:   FreshnessRequirement{Class: "current_revision"},
		Dimensions:  []string{"repository", "environment", "revision"},
	},
	"host": {
		ID: "host.current_state", Layer: "host",
		Question:    "Are expected hosts present, responsive, and free of material failure or pressure?",
		Proposition: "Expected hosts are present, responsive, and free of material failure or pressure.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 15 * time.Minute},
		Dimensions:  []string{"host", "environment"},
	},
	"runtime": {
		ID: "runtime.current_state", Layer: "runtime",
		Question:    "Are required runtimes healthy and reporting current state?",
		Proposition: "Required runtimes are healthy and reporting current state.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 15 * time.Minute},
		Dimensions:  []string{"runtime", "host"},
	},
	"scheduler": {
		ID: "scheduler.desired_state", Layer: "scheduler",
		Question:    "Does observed scheduler state satisfy declared desired state?",
		Proposition: "Observed scheduler state satisfies the declared desired state.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 10 * time.Minute},
		Dimensions:  []string{"scheduler", "node", "environment"},
	},
	"workload": {
		ID: "workload.desired_state", Layer: "workload",
		Question:    "Are required workloads running at desired capacity without current failures?",
		Proposition: "Required workloads run at desired capacity without current failures.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 10 * time.Minute},
		Dimensions:  []string{"service", "workload", "environment"},
	},
	"dependency": {
		ID: "dependency.current_health", Layer: "dependency",
		Question:    "Are critical dependencies available and behaving within their operational bounds?",
		Proposition: "Critical dependencies are available and behaving within their operational bounds.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 10 * time.Minute},
		Dimensions:  []string{"dependency", "service", "environment"},
	},
	"application": {
		ID: "application.functional_behavior", Layer: "application",
		Question:    "Do representative user paths work without a current error or timeout spike?",
		Proposition: "Representative user paths work without a current error or timeout spike.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 10 * time.Minute},
		Dimensions:  []string{"service", "endpoint", "environment", "window"},
	},
	"slo": {
		ID: "impact.current", Layer: "slo",
		Question:    "What current service indicator, alert, or user-impact evidence changes the decision?",
		Proposition: "Current service indicators and user-impact evidence show no material degradation.",
		Freshness:   FreshnessRequirement{Class: "live", MaxAge: 10 * time.Minute},
		Dimensions:  []string{"service", "indicator", "environment", "window"},
	},
}

// ValidCoverageLayer is the single vocabulary check for contract claims and
// result coverage. Callers must not maintain a second list: doing so can make
// valid model evidence disappear between parsing and completion validation.
func ValidCoverageLayer(value string) bool {
	_, ok := layerClaims[strings.TrimSpace(value)]
	return ok
}

func Compile(episode core.WorkEpisode) InvestigationContract {
	conclusionKind := episodeConclusionKind(episode)
	claims := make([]ClaimRequirement, 0, len(episode.RequiredCoverage))
	for _, layer := range episode.RequiredCoverage {
		claim, ok := layerClaims[layer]
		if !ok {
			claim = ClaimRequirement{
				ID: layer + ".current", Layer: layer,
				Question:    "What current evidence establishes the " + layer + " claim?",
				Proposition: "The current " + layer + " state is healthy within the requested scope.",
				Freshness:   FreshnessRequirement{Class: "claim_appropriate"},
			}
		}
		if conclusionKind == "change_review" && layer == "change" {
			claim.Question = "What is the exact lifecycle state, material diff, risk, and verification boundary of this change?"
			claim.Proposition = "The exact change lifecycle state, material diff, risk, and verification boundary are established."
		}
		claim.Required = true
		claims = append(claims, claim)
	}
	contract := InvestigationContract{
		Version: Version, Effort: episode.Effort, Authority: episode.Authority,
		Objective: strings.TrimSpace(episode.Objective), Claims: claims,
		CompletionCriteria: slices.Clone(episode.CompletionCriteria),
		Completion: CompletionRule{
			AllowedStatuses: []string{"decision_ready", "blocked"},
			ConclusionKind:  conclusionKind,
		},
		// The prompt tells the model to emit only the operations this list
		// names, so anything missing from it is forbidden by the contract
		// however well the host supports it.
		//
		// record_coverage was missing while the same prompt required a coverage
		// item for every required claim, which is a contract that forbids what
		// it mandates. request_operator_input was missing too, and it is the
		// host's only way to ask a question: the episode lifecycle has a
		// waiting_for_operator state that nothing listed here can reach. A
		// model that genuinely needed the operator to finish a sentence had no
		// listed exit, so it invented completion.status "needs_input" and lost
		// the response.
		ResultOperations: []string{
			"record_evidence", "record_coverage", "report_progress", "plan_goal", "update_goal",
			"request_operator_input", "wait_external", "record_feedback", "request_record",
			"request_approval",
			"offer_task", "attach_visual", "update_memory", "offer_memory", "offer_preference",
			"offer_rule", "offer_schedule", "record_alert_assessment",
			"record_repository_contents", "offer_grant_promotion",
			"offer_runbook_draft", "offer_kb_card", "offer_assignment", "complete_episode",
		},
	}
	switch conclusionKind {
	case "operational_health":
		contract.Completion.AllowedVerdicts = []string{"healthy", "degraded", "unhealthy"}
		contract.Completion.RequireVerdict = episode.Effort == core.EffortOperationalAssessment
		contract.Completion.AllowUnknownSLO = true
	case "change_review":
		contract.Completion.AllowedVerdicts = []string{
			"in_progress", "needs_review", "succeeded", "failed", "inconclusive",
		}
	case "engineering_result":
		contract.Completion.AllowedVerdicts = []string{"completed", "no_change", "partial"}
	case "factual_assessment":
		contract.Completion.AllowedVerdicts = []string{"confirmed", "not_confirmed", "inconclusive"}
	}
	contract.Completion.RequireDiagnosis = episode.Effort == core.EffortOperationalAssessment ||
		episode.Effort == core.EffortIncidentInvestigation
	return contract
}

func episodeConclusionKind(episode core.WorkEpisode) string {
	switch episode.Effort {
	case core.EffortOperationalAssessment, core.EffortIncidentInvestigation:
		return "operational_health"
	case core.EffortEngineeringTask:
		return "engineering_result"
	case core.EffortFocusedCheck:
		if focusedOperationalHealthObjective(episode.Objective) {
			return "operational_health"
		}
		if slices.Contains(episode.RequiredCoverage, "change") && focusedChangeReviewObjective(episode.Objective) {
			return "change_review"
		}
		return "factual_assessment"
	default:
		return "direct_answer"
	}
}

// ReusableArtifactAuthoring reports whether a request writes or revises a
// reusable operational artifact rather than assessing current state.
//
// The two read almost identically, because an artifact is named after the
// assessment it performs. "Create reusable deep infrastructure health review
// runbook" contains every word an infrastructure health request does, and the
// host duly compiled it as one: seven required coverage layers and a mandatory
// healthy, degraded or unhealthy verdict, for a request to write a document.
// The model had created, validated and tested the draft — a good result — but
// no platform to grade and no verdict it could honestly give, so it returned a
// bare blocked completion, and that failed validation for having none of the
// five fields a blocker needs. The reported error was about missing blocker
// fields; the actual mistake was made before the model ever saw the request.
//
// The verbs are deliberately restricted to authoring, and matched on whole
// words. "Run the published health review runbook and tell me if production is
// healthy" names the same artifact and is a genuine health assessment, so
// execution words must not match. Neither may "build", which is what CI calls a
// run, nor "make", which is mostly the filler in "make sure".
//
// The word boundaries are not decoration. Matching these as substrings read
// "authorized" as "author" and demoted a real whole-platform health assessment
// — a scheduled review whose prompt says "Decide healthy, degraded, or
// unhealthy" — to a factual assessment, because it also mentioned running
// "equivalent authorized read-only checks". "credit" contains "edit" the same
// way. A guard against misreading a title must not itself misread a word.
var reusableArtifactAuthoringVerbs = regexp.MustCompile(
	`\b(creat(e|es|ed|ing)|author(s|ed|ing)?|writ(e|es|ing)|rewrit(e|es|ing)|` +
		`draft(s|ed|ing)?|revis(e|es|ing)|extend(s|ed|ing)?|edit(s|ed|ing)?|reusable)\b`,
)

func ReusableArtifactAuthoring(text string) bool {
	text = strings.ToLower(strings.Join(strings.Fields(text), " "))
	if !containsAny(text, "runbook", "playbook", "workflow") {
		return false
	}
	return reusableArtifactAuthoringVerbs.MatchString(text)
}

func focusedOperationalHealthObjective(objective string) bool {
	objective = strings.ToLower(strings.Join(strings.Fields(objective), " "))
	if focusedChangeReviewObjective(objective) || ReusableArtifactAuthoring(objective) {
		return false
	}
	return containsAny(objective,
		" healthy", "health ", "health?", "health of", "recovered", "recovery",
		"degraded", "unhealthy", "still broken", "still failing",
	)
}

func focusedChangeReviewObjective(objective string) bool {
	objective = strings.ToLower(strings.Join(strings.Fields(objective), " "))
	return containsAny(objective,
		"terraform plan", "terraform run", "review this plan", "review the plan",
		"plan notification", "run notification", "pull request", "review this pr", "review the pr",
		"review this diff", "review the diff", "ci run", "cd run", "build run",
	)
}

func containsAny(value string, terms ...string) bool {
	for _, term := range terms {
		if strings.Contains(value, term) {
			return true
		}
	}
	return false
}

func (contract InvestigationContract) RequiredLayers() []string {
	result := make([]string, 0, len(contract.Claims))
	for _, claim := range contract.Claims {
		if claim.Required {
			result = append(result, claim.Layer)
		}
	}
	return result
}

func (contract InvestigationContract) RequiredClaimIDs() []string {
	result := make([]string, 0, len(contract.Claims))
	for _, claim := range contract.Claims {
		if claim.Required {
			result = append(result, claim.ID)
		}
	}
	return result
}

// ResolveClaimID maps a model-authored claim id onto the exact required claim
// it can only be naming, and refuses everything else.
//
// Compile builds exactly one required claim per required coverage layer, so
// within a single contract a required claim owns its layer name and its own
// dotted namespace outright. "task", "task.completion" and "task.current_state"
// can only be about task.requested_outcome, because that is the only required
// claim in scope carrying that layer or that prefix. Binding them to it does
// not let evidence answer a question it was never scoped to, which is what the
// exact-id rule protects: there is no second question in scope for it to be
// answering.
//
// This is not politeness. Three consecutive real regression runs each invented
// a different spelling in that one namespace and lost an otherwise complete,
// correct investigation to it — a validated runbook draft with the right
// source, the right observation and the right coverage layer, discarded over
// the word after the dot. The rejection cost a whole correction turn and, three
// corrections later, the model still had not guessed the exact string out of a
// serialized contract.
//
// Ambiguity is still refused, and so is a namespace the contract does not
// require: the guarantee is that the contract leaves no room for doubt, not
// that near-misses are forgiven.
func (contract InvestigationContract) ResolveClaimID(candidate string) (string, bool) {
	candidate = strings.ToLower(strings.TrimSpace(candidate))
	if candidate == "" {
		return "", false
	}
	for _, requirement := range contract.Claims {
		if requirement.Required && strings.ToLower(requirement.ID) == candidate {
			return requirement.ID, true
		}
	}
	matched := ""
	for _, requirement := range contract.Claims {
		if !requirement.Required {
			continue
		}
		if claimNamespace(candidate) != strings.ToLower(requirement.Layer) &&
			claimNamespace(candidate) != claimNamespace(strings.ToLower(requirement.ID)) {
			continue
		}
		if matched != "" && matched != requirement.ID {
			return "", false
		}
		matched = requirement.ID
	}
	return matched, matched != ""
}

// ClaimIDsAnswer reports whether any of these model-authored claim ids resolves
// to the required claim. Coverage carries a list, and one entry naming the
// claim unambiguously is what the host needs to know the layer was answered.
func (contract InvestigationContract) ClaimIDsAnswer(ids []string, requirementID string) bool {
	for _, id := range ids {
		if resolved, ok := contract.ResolveClaimID(id); ok && resolved == requirementID {
			return true
		}
	}
	return false
}

func claimNamespace(value string) string {
	if index := strings.IndexByte(value, '.'); index >= 0 {
		return value[:index]
	}
	return value
}

func (contract InvestigationContract) Prompt() string {
	data, err := json.Marshal(contract)
	if err != nil {
		return ""
	}
	result := `<host-investigation-contract>
` + string(data) + `
This contract controls effort, never permission. Investigate each required claim with the strongest
available repository and live evidence. Keep evidence atomic and bind it to claim_id, a dimensions
object carrying a key for every dimension that required claim lists, source time, freshness,
confidence, and whether it supports or contradicts the claim. Repository state proves declared intent; only
fresh operational evidence proves current behavior.

When a claim conflicts with something already recorded, do not rephrase the claim. Rewording it only
moves the conflict to the next recorded statement, and the host will name that one instead. Pick the
losing side and retire it explicitly, exactly one of three ways: retract it, supersede it with a
record_evidence carrying supersedes:[its evidence id] and a later observed_at — only that field
retires a record, prose naming it does not — or reconcile both with new evidence that names both
evidence ids and says how they fit together. The host's correction lists every conflicting statement
with its evidence id, so the record to retire is always named; say which one you are retiring and
why.

One evidence record must describe one source. When a conclusion compares repository intent with live
state, emit separate repository and operational evidence records rather than combining their observations
under one source_type.

Evidence relation is relative to each required claim's positive proposition. Record health_effect
separately as none, risk, degraded, unhealthy, or unknown. Negative evidence must contradict the
proposition, but contradiction is not automatically degradation. A replacement, drift, elevated
utilization, an in-progress operation, or an unknown outcome is risk or unknown unless fresh evidence
shows reduced capability, errors, failures, or impact. Coverage may be degraded or unhealthy only when
bound evidence carries that material health_effect. Contradictory evidence paired with healthy coverage
remains unresolved.

Use only a verdict listed in completion.allowed_verdicts. Do not introduce an operational health verdict
for a change review, engineering result, factual assessment, schedule, configuration change, runbook
draft, or publication workflow. Incomplete work, an unpublished draft, pending verification, risk, and
missing authorization are not operational degradation. Describe them with the contract's own result state.
`
	result += contract.conclusionGuidance()
	result += contract.planGuidance()
	result += `
Keep the final Slack synthesis decision-first and concise. Emit only the result operations listed by the
contract. The host validates each operation and completion against this contract.

completion.status is decision_ready or blocked and nothing else. Needing the operator to decide,
choose, or supply missing text is a blocked completion, not a third status: emit request_operator_input
carrying the exact question, then complete with blocker_kind operator_input_required and all five
blocked fields. Every one of them is answerable for a question — what was already read or attempted is
the attempts list, and the answer you need is the next action.

A blocker is an external boundary, not unfinished work. Exhaust available read-only routes before
returning one, then name the exact source, access, operator input, authority, or tool failure required.
Every blocked completion carries summary, material_gaps, blocker_kind, attempts and next_action
together. A status and a summary alone is not a blocker: it is a result nobody can act on, and the host
rejects the whole response rather than post it.
An unavailable named runbook, saved query, dashboard, or other reusable workflow is not itself a blocker
when the requested read-only outcome can still be established from authorized underlying tools. Search
for a published semantic replacement, inspect its exact scope, and use it when it is read-only and covers
the same objective. Otherwise perform the equivalent read-only checks directly. Record the missing
reusable workflow as a reproducibility or maintenance gap, but block only when the underlying material
evidence or capability is actually unavailable. Never substitute a workflow that broadens scope or can
mutate state.
When a governed operational capability is missing, do not stop at "send me a link" or "the tool is
unavailable." Search Emisar with find_actions using the capability and useful synonyms, then inspect
list_packs with availability=all. Also inspect an available repository or published pack catalog when
it can establish whether a matching pack exists. Distinguish missing message input from missing
capability: request an identifier only when no configured source can identify it. For a real capability
gap, emit completion.capability_gaps. Recommend an exact pack only when an Emisar or repository evidence
record identifies that pack; otherwise use status not_found and say no matching pack was discovered.
Choose the next step from observed state: install an absent pack, trust an installed untrusted pack,
deploy or reload a trusted pack that is not advertised, or update an incompatible pack. Do not invent
pack names, immutable refs, install commands, or availability. Keep the recommendation out of the main
message because the host renders one concise evidence-bound capability line.
When an exact source or tool capability is expected to propagate shortly, include completion.recheck
with a stable dependency key, a concrete reason, a 30-1800 second delay, and 1-4 additional attempts.
Do not request a recheck for missing credentials, denied access, operator decisions, permanent setup,
or open-ended monitoring. The host owns timing and deduplication; a recheck grants no authority.
Completion evaluates the requested objective at the latest recorded observation. Missing evidence for
a future remediation does not make a completed assessment blocked when the requested objective itself
has a decisive answer. Likewise, a fresh degraded or unhealthy result may remain decision-ready when
secondary coverage is explicitly unknown but cannot reverse that negative verdict. Preserve the bounded
unknown beneath the result, record the next action, and complete with the supported verdict.
decision_ready means every gap left cannot change the decision, and material_gaps is where a gap goes
only under a verdict it cannot reverse. Under healthy, succeeded, confirmed, completed, no_change, or no
verdict at all, list none: a gap that could change the verdict makes the result blocked or lowers the
verdict, and one that could not belongs beneath the result in the completion message.
</host-investigation-contract>`
	return result
}

// planGuidance asks long work to say what it is going to do before it does it.
//
// plan_goal and update_goal have been in the operation list since the contract
// existed and no model has ever emitted one: zero rows in episode_goals, across
// every episode ever run. An operation named in a list and asked for nowhere is
// an operation that does not happen, so this is the ask — instruction only, no
// correction rung. Whether it lands is measured from the audit trail rather
// than assumed, and if it does not, the pressure goes up from there.
//
// Only the two efforts whose work has steps. An engineering task and an
// incident investigation run long enough that an operator watching the card
// wants to know which part is finished; a question and a focused check are one
// act, and goals on them would be a project plan for a sentence — five rows of
// ceremony under a card whose whole work is a lookup. The boundary is stated
// inside the text as well as enforced by this switch, because the model reading
// it is the one deciding how far to break the work down.
func (contract InvestigationContract) planGuidance() string {
	switch contract.Effort {
	case core.EffortEngineeringTask, core.EffortIncidentInvestigation:
		return `
Plan this work where the operator can watch it. In the first substantive result of this episode, emit
2-5 plan_goal operations naming the steps the work breaks into, each requested_outcome under 80
characters and each completion_contract an observable done condition. In later turns emit update_goal
as each goal starts, completes, or blocks, so the card tracks the work instead of restating it. Plan
once per episode: never re-plan a goal an earlier turn already opened. A question, a focused check, or
a single lookup gets no goals at all.
`
	default:
		return ""
	}
}

func (contract InvestigationContract) conclusionGuidance() string {
	switch contract.Completion.ConclusionKind {
	case "operational_health":
		return `
This is an operational health assessment. Set completion.verdict to exactly healthy, degraded, or
unhealthy. Use functional behavior, errors and timeouts versus comparable baselines, active alerts,
failures, dependencies, saturation, and recent changes. Missing evidence alone is not degradation,
and healthy infrastructure alone does not prove application health. A verified reduced capability is
degraded; material unavailability or broad impact is unhealthy. Formal SLOs are optional. When none
exists, use current operational indicators and mark the SLO layer not_applicable. Finish with one
practical health verdict, preserve bounded unknowns beneath it, and use at most six evidence-rich bullets.

An active issue is not decision-ready until the affected scope, impact, identified or bounded cause,
safe immediate action, verification, and durable solution are established, or an exact external blocker
is returned. Do not stop at symptom counts or assign available investigation back to the operator.
`
	case "change_review":
		return `
This is a change review. Report lifecycle state rather than platform health. Use in_progress while an
operation is executing and its result is not terminal, needs_review when the exact plan is available but
needs a decision, succeeded or failed only from terminal evidence, and inconclusive only when the current
state cannot be established. State any observed operational impact separately; change risk alone is not
degradation.
`
	case "engineering_result":
		return `
This is engineering work. Report completed when the requested implementation and validation are done,
no_change when evidence shows no change is justified, or partial when useful work completed but a named
task step remains. Do not translate validation, publication, review, or delivery state into health language.
`
	case "factual_assessment":
		return `
This is a bounded factual or operational-task assessment. A verdict answers the operator's question, not
your work on it: confirmed when the asserted condition holds, not_confirmed when evidence shows it does
not, inconclusive when it cannot be established. Diagnosing a failure is not confirmation — a proven
blocker is not_confirmed. Omit the verdict when none of the three answers the question. Report what was
completed, what remains, and the next action in the task's own language. Do not translate draft, validation, publication, scheduling, or approval state
into health language. A known incomplete, draft, or unpublished artifact state is a decision-ready result,
not a blocker. Treat publication or adoption as a next action unless the operator explicitly requested it
as part of this episode.
`
	default:
		return `
Answer the request directly in its own language. Do not add a health verdict unless the operator actually
asked for an operational health assessment.
`
	}
}

func SourcePolicy() string {
	return `Choose evidence sources by the claim being answered. Consider the full set of repository, MCP, and other tools available in the turn, including observability, source-control, deployment, and provider tools needed for a defensible result.
Use the checked-out repository for declared intent and expected topology, then corroborate current state
with fresh live evidence. Prefer Emisar MCP for current private infrastructure state and governed actions.
Inspect and use other available MCP servers and tools when they directly own a claim; do not ignore a
relevant configured tool merely because Emisar is available. Use the MCP tools directly, not curl against the MCP endpoint.
Fall back from Emisar only after an Emisar MCP tool call fails in the current turn, and
never say Emisar is unavailable merely because a local CLI or binary is absent.

Before declaring that an operational capability is missing, search Emisar find_actions with the
capability and useful synonyms and inspect list_packs with availability=all. If those live results or
an available repository or published catalog identify a matching pack, return an evidence-bound
completion.capability_gaps recommendation for the exact observed state: install, trust, deploy or reload,
or update it. If no matching pack is found, say so without inventing one. Missing text or an identifier
in one Slack message is not a capability gap when another configured source can resolve it.

Reconcile declared topology with observed runtime entities, including identities, cardinality, timestamps,
windows, populations, and denominators. Never equate or count runner records, hosts, VMs, nodes, allocations, containers, or services as the same thing without an explicit mapping.
Treat runner-list results only as runner identities and connection state. A successful readiness probe does not prove runner, fleet, workload, or infrastructure health; neither does a running workload, empty alert list, or single
aggregate. When sources disagree, do not silently pick one: preserve the contradiction and investigate it.

Scope claims to what was actually observed, preserve source timestamps, and state material contradictions
or unavailable evidence. Continue read-only investigation while a material claim is answerable; stop only
when the contract is decision-ready, further checks are duplicative, authority is missing, or an exact
external blocker requires operator input. Use the investigation contract's conclusion kind and verdict
vocabulary; do not default unrelated work to a health assessment.

This evidence policy is mandatory for current operational questions.`
}
