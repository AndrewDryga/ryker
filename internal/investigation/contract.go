package investigation

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const Version = "2026-08-02.2"

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
	AllowedStatuses     []string `json:"allowed_statuses"`
	OperationalVerdicts []string `json:"operational_verdicts,omitempty"`
	RequireDiagnosis    bool     `json:"require_diagnosis_for_active_issue"`
	AllowUnknownSLO     bool     `json:"allow_not_applicable_slo"`
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

func Compile(episode core.WorkEpisode) InvestigationContract {
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
		claim.Required = true
		claims = append(claims, claim)
	}
	contract := InvestigationContract{
		Version: Version, Effort: episode.Effort, Authority: episode.Authority,
		Objective: strings.TrimSpace(episode.Objective), Claims: claims,
		CompletionCriteria: slices.Clone(episode.CompletionCriteria),
		Completion:         CompletionRule{AllowedStatuses: []string{"decision_ready", "blocked"}},
		ResultOperations: []string{
			"record_evidence", "report_progress", "request_approval",
			"offer_task", "complete_episode",
		},
	}
	if episode.Effort == core.EffortOperationalAssessment {
		contract.Completion.OperationalVerdicts = []string{"healthy", "degraded", "unhealthy"}
		contract.Completion.AllowUnknownSLO = true
	}
	contract.Completion.RequireDiagnosis = episode.Effort == core.EffortOperationalAssessment ||
		episode.Effort == core.EffortIncidentInvestigation
	return contract
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

func (contract InvestigationContract) Prompt() string {
	data, err := json.Marshal(contract)
	if err != nil {
		return ""
	}
	return `<host-investigation-contract>
` + string(data) + `
This contract controls effort, never permission. Investigate each required claim with the strongest
available repository and live evidence. Keep evidence atomic and bind it to claim_id, dimensions,
source time, freshness, confidence, and whether it supports or contradicts the claim. Reconcile
contradictions instead of silently choosing a source. Repository state proves declared intent; only
fresh operational evidence proves current behavior.

Evidence relation is relative to each required claim's positive proposition. Negative evidence must
contradict that proposition. A contradicted or mixed proposition can support a decision-ready degraded
or unhealthy conclusion when coverage uses that status and its detail explicitly reconciles the evidence.
Contradictory evidence paired with healthy coverage remains unresolved.

For operational assessments, set completion.verdict to exactly healthy, degraded, or unhealthy. Formal SLOs are
optional: use functional behavior, errors and timeouts versus a comparable baseline, active alerts,
failures, dependencies, saturation, and recent changes. Missing evidence alone is not degradation,
and healthy infrastructure alone does not prove application health. A healthy verdict requires fresh
representative functional or application evidence. A verified reduced capability is degraded;
material unavailability or broad impact is unhealthy.

Finish with one practical overall verdict: healthy, degraded, or unhealthy. A formal SLO is optional;
when none exists, use current errors, failures, saturation, alerts, dependencies, and user-path evidence.
Do not call the whole platform unknown merely because one optional source is missing. State the bounded
unknown beneath the practical verdict, and keep the synthesis to no more than six evidence-rich bullets.

An active issue is not decision-ready until the affected scope, impact, identified or bounded cause,
safe immediate action, verification, and durable solution are established, or an exact external
blocker is returned. Do not stop at symptom counts or assign available investigation back to the
operator. Keep the final Slack synthesis decision-first: one short verdict paragraph and at most six
evidence-rich bullets. Emit only the result operations listed by the contract. The host validates
each operation and completion against this contract.

A blocker is an external boundary, not unfinished work. Exhaust available read-only routes before
returning one, then name the exact source, access, operator input, authority, or tool failure required.
Completion evaluates the requested objective at the latest recorded observation. Missing evidence for
a future remediation does not make a completed assessment blocked when the requested objective itself
has a decisive answer; record the remediation gap as a next action and complete with the supported verdict.
</host-investigation-contract>`
}

func SourcePolicy() string {
	return `Choose evidence sources by the claim being answered. Consider the full set of repository, MCP, and other tools available in the turn, including observability, source-control, deployment, and provider tools needed for a defensible result.
Use the checked-out repository for declared intent and expected topology, then corroborate current state
with fresh live evidence. Prefer Emisar MCP for current private infrastructure state and governed actions.
Inspect and use other available MCP servers and tools when they directly own a claim; do not ignore a
relevant configured tool merely because Emisar is available. Use the MCP tools directly, not curl against the MCP endpoint.
Fall back from Emisar only after an Emisar MCP tool call fails in the current turn, and
never say Emisar is unavailable merely because a local CLI or binary is absent.
Do not ignore a relevant configured tool merely because Emisar is available. Never say Emisar is unavailable merely because a local CLI or binary is absent.

Reconcile declared topology with observed runtime entities, including identities, cardinality, timestamps,
windows, populations, and denominators. Never equate or count runner records, hosts, VMs, nodes, allocations, containers, or services as the same thing without an explicit mapping.
Treat runner-list results only as runner identities and connection state. A successful readiness probe does not prove runner, fleet, workload, or infrastructure health; neither does a running workload, empty alert list, or single
aggregate. When sources disagree, do not silently pick one: preserve the contradiction and investigate it.
When Emisar lists runners, treat its results only as runner identities and connection state.

Scope claims to what was actually observed, preserve source timestamps, and state material contradictions
or unavailable evidence. Continue read-only investigation while a material claim is answerable; stop only
when the contract is decision-ready, further checks are duplicative, authority is missing, or an exact
external blocker requires operator input. Finish with one practical overall verdict: healthy, degraded, or unhealthy.
A formal SLO is optional; use functional evidence when none is defined, and do not call the whole platform unknown.
Keep the final report to no more than six evidence-rich bullets.`
}

func ClaimForLayer(layer string) (ClaimRequirement, error) {
	claim, ok := layerClaims[layer]
	if !ok {
		return ClaimRequirement{}, fmt.Errorf("unsupported investigation layer %q", layer)
	}
	return claim, nil
}
