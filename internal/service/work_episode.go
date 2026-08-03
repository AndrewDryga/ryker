package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

type completionAssessment struct {
	Status       string   `json:"status"`
	Verdict      string   `json:"verdict,omitempty"`
	Summary      string   `json:"summary"`
	MaterialGaps []string `json:"material_gaps,omitempty"`
	BlockerKind  string   `json:"blocker_kind,omitempty"`
	Attempts     []string `json:"attempts,omitempty"`
	NextAction   string   `json:"next_action,omitempty"`
}

func validateCompletionAssessment(completion *completionAssessment) error {
	if completion == nil {
		return nil
	}
	completion.Status = strings.TrimSpace(completion.Status)
	completion.Verdict = strings.TrimSpace(completion.Verdict)
	completion.Summary = strings.TrimSpace(completion.Summary)
	completion.BlockerKind = strings.TrimSpace(completion.BlockerKind)
	completion.NextAction = strings.TrimSpace(completion.NextAction)
	if len(completion.MaterialGaps) > 20 {
		return errors.New("completion assessment has too many material gaps")
	}
	if len(completion.Attempts) > 12 {
		return errors.New("completion assessment has too many blocker attempts")
	}
	for _, gap := range completion.MaterialGaps {
		if len(strings.TrimSpace(gap)) > 500 {
			return errors.New("completion assessment material gap exceeds 500 bytes")
		}
	}
	completion.MaterialGaps = normalizedCompletionGaps(completion.MaterialGaps)
	completion.Attempts = normalizedCompletionAttempts(completion.Attempts)
	if len(completion.Status) > 32 || len(completion.Verdict) > 32 || len(completion.Summary) > 1000 ||
		len(completion.BlockerKind) > 64 || len(completion.NextAction) > 1000 {
		return errors.New("completion assessment exceeds its field bounds")
	}
	switch completion.Status {
	case "decision_ready":
		if completion.Summary == "" {
			return errors.New("decision-ready completion requires a summary")
		}
		if len(completion.MaterialGaps) > 0 {
			return errors.New("decision-ready completion cannot contain material gaps")
		}
		if completion.BlockerKind != "" || len(completion.Attempts) > 0 {
			return errors.New("decision-ready completion cannot contain blocker fields")
		}
	case "blocked":
		if completion.Verdict != "" {
			return errors.New("blocked completion cannot contain an operational verdict")
		}
		if completion.Summary == "" || len(completion.MaterialGaps) == 0 ||
			completion.BlockerKind == "" || len(completion.Attempts) == 0 ||
			completion.NextAction == "" {
			return errors.New(
				"blocked completion requires summary, material_gaps, blocker_kind, attempts, and next_action",
			)
		}
		if !validCompletionBlockerKind(completion.BlockerKind) {
			return fmt.Errorf("unsupported completion blocker kind %q", completion.BlockerKind)
		}
	default:
		return fmt.Errorf("unsupported completion status %q", completion.Status)
	}
	if completion.Verdict != "" && !validOperationalHealthVerdict(completion.Verdict) {
		return fmt.Errorf("unsupported completion verdict %q", completion.Verdict)
	}
	return nil
}

func validOperationalHealthVerdict(value string) bool {
	switch value {
	case "healthy", "degraded", "unhealthy":
		return true
	default:
		return false
	}
}

func validCompletionBlockerKind(value string) bool {
	switch value {
	case "source_unavailable", "access_denied", "operator_input_required",
		"authority_boundary", "tool_failure":
		return true
	default:
		return false
	}
}

func normalizedCompletionGaps(values []string) []string {
	result := make([]string, 0, min(len(values), 20))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || len(value) > 500 {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
		if len(result) == 20 {
			break
		}
	}
	return result
}

func normalizedCompletionAttempts(values []string) []string {
	result := make([]string, 0, min(len(values), 12))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || len(value) > 500 {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
		if len(result) == 12 {
			break
		}
	}
	return result
}

func (s *Service) episodeForIncident(
	incident core.Incident,
	mode core.AgentRunMode,
	sourceKind string,
	objective string,
) *core.WorkEpisode {
	episode := &core.WorkEpisode{
		Effort:    core.EffortIncidentInvestigation,
		Authority: core.AuthorityReadOnly,
		Objective: strings.TrimSpace(objective),
		RequiredCoverage: []string{
			"change", "host", "runtime", "workload", "dependency", "application", "slo",
		},
		CompletionCriteria: []string{
			"reconcile declared topology with fresh operational evidence",
			"state current impact and the safest immediate action",
			"identify the durable solution or the exact blocker",
		},
	}
	if mode == core.AgentRunEngineeringTask {
		episode.Effort = core.EffortEngineeringTask
		episode.Authority = core.AuthorityRepositoryWrite
		episode.RequiredCoverage = nil
		episode.CompletionCriteria = []string{
			"inspect the relevant implementation and constraints",
			"make only the justified repository change",
			"run the strongest available focused validation",
			"report the exact diff, validation, and remaining gaps",
		}
	} else if sourceKind == "proposal" || strings.HasPrefix(sourceKind, "emisar_approval:") {
		episode.Authority = core.AuthorityGovernedOperation
	}
	if episode.Objective == "" {
		episode.Objective = incident.Title
	}
	return episode
}

func approvalContinuationEpisode(actionID string) *core.WorkEpisode {
	return &core.WorkEpisode{
		Effort:    core.EffortFocusedCheck,
		Authority: core.AuthorityGovernedOperation,
		Objective: "Verify " + actionID + " after the Emisar decision",
		CompletionCriteria: []string{
			"inspect the exact terminal Emisar run",
			"verify the intended live effect with read-only evidence when possible",
			"separate execution status from independently verified outcome",
		},
	}
}

func (s *Service) episodeForWatchedInput(
	input core.SlackInput,
	state watchTurnState,
) *core.WorkEpisode {
	text := strings.ToLower(strings.Join(strings.Fields(input.Text), " "))
	episode := &core.WorkEpisode{
		Effort:    core.EffortConversational,
		Authority: core.AuthorityReadOnly,
		Objective: commitmentTitleForInput(input),
		CompletionCriteria: []string{
			"answer the current request directly",
			"separate verified facts from uncertainty",
		},
	}
	// Configuration is accepted work, but it is not an operational assessment even
	// when the requested preference happens to mention health checks or alerts.
	if input.Kind != "scheduled" && explicitBehaviorRequest(input.Text) {
		return episode
	}
	if isOperationalAssessmentRequest(text) {
		episode.Effort = core.EffortOperationalAssessment
		episode.RequiredCoverage = operationalAssessmentCoverage(text)
		episode.CompletionCriteria = []string{
			"cover every relevant system layer",
			"reconcile repository topology with fresh live evidence",
			"state a decision-ready conclusion or an exact blocker",
		}
	} else if isFocusedCheckRequest(text) || len(input.Attachments) > 0 ||
		input.Kind == "shortcut" || input.Kind == "bot_message" {
		episode.Effort = core.EffortFocusedCheck
		episode.RequiredCoverage = focusedCoverage(text)
		episode.CompletionCriteria = []string{
			"verify the named claim with the best available source",
			"state the result, material gap, and next action",
		}
	}
	if matchedOperationalAlertRule(state.MatchedRules) {
		episode.Effort = core.EffortIncidentInvestigation
		episode.RequiredCoverage = alertInvestigationCoverage(text)
		episode.CompletionCriteria = []string{
			"decide whether the signal is a real current issue",
			"verify impact with fresh operational evidence",
			"recommend the safest immediate action and durable solution",
		}
	}
	if explicitGovernedOperationRequest(text) {
		if episode.Effort == core.EffortConversational {
			episode.Effort = core.EffortFocusedCheck
			episode.RequiredCoverage = focusedCoverage(text)
			episode.CompletionCriteria = []string{
				"verify the exact target and current state",
				"state whether policy permits the requested operation",
				"report the result or exact approval boundary",
			}
		}
		if s.cfg.IsOperator(input.UserID) {
			episode.Authority = core.AuthorityGovernedOperation
		}
	}
	return episode
}

func isOperationalAssessmentRequest(text string) bool {
	broadScope := episodeContainsAny(text,
		"infrastructure health", "infra health", "production health", "system health",
		"health of our", "health of everything", "end-to-end", "end to end",
		"deep health", "deep check", "health review", "health assessment",
		"platform healthy", "full assessment", "overall health",
	)
	return broadScope ||
		(episodeContainsAny(text, "assess", "assessment", "investigate") &&
			episodeContainsAny(text, "production", "infrastructure", "platform", "service"))
}

func isFocusedCheckRequest(text string) bool {
	return episodeContainsAny(text,
		"check ", "review ", "verify ", "look into", "investigate", "is it green",
		"is it healthy", "what failed", "what changed", "explain this alert",
	)
}

func operationalAssessmentCoverage(text string) []string {
	result := []string{"change", "host", "runtime", "workload", "dependency", "application", "slo"}
	if episodeContainsAny(text, "hardware", "disk", "cpu", "memory", "thermal") {
		result = append([]string{"hardware"}, result...)
	}
	if episodeContainsAny(text, "nomad", "kubernetes", "scheduler", "allocation") {
		result = append(result, "scheduler")
	}
	return result
}

func alertInvestigationCoverage(text string) []string {
	result := []string{"change", "application", "slo"}
	if episodeContainsAny(text,
		"host", "node", "vm", "disk", "i/o", "io latency", "cpu", "memory",
		"oom", "systemd", "nvme", "filesystem",
	) {
		result = append(result, "host")
	}
	if episodeContainsAny(text,
		"workload", "job", "process", "service", "container", "pod", "task",
	) {
		result = append(result, "workload")
	}
	if episodeContainsAny(text, "nomad", "kubernetes", "scheduler", "alloc") {
		result = append(result, "scheduler")
	}
	if episodeContainsAny(text, "database", "postgres", "cassandra", "redis", "dependency", "upstream") {
		result = append(result, "dependency")
	}
	return result
}

func focusedCoverage(text string) []string {
	result := make([]string, 0, 4)
	for _, candidate := range []struct {
		layer string
		terms []string
	}{
		{"change", []string{"ci", "cd", "deploy", "release", "terraform", "plan", "diff", "change"}},
		{"host", []string{"host", "vm", "disk", "cpu", "memory", "systemd"}},
		{"runtime", []string{"runtime", "docker", "container"}},
		{"scheduler", []string{"nomad", "kubernetes", "scheduler", "allocation"}},
		{"workload", []string{"workload", "job", "process", "service"}},
		{"dependency", []string{"database", "postgres", "cassandra", "redis", "dependency", "upstream"}},
		{"application", []string{"application", "api", "endpoint", "request", "error"}},
		{"slo", []string{"slo", "customer", "impact", "latency", "availability"}},
	} {
		if episodeContainsAny(text, candidate.terms...) {
			result = append(result, candidate.layer)
		}
	}
	return result
}

func explicitGovernedOperationRequest(text string) bool {
	if !episodeContainsAny(text, "enable", "disable", "restart", "apply", "retry", "drain", "failover", "roll back", "rollback") {
		return false
	}
	return episodeContainsAny(text, "can you", "please", "do it", "go ahead", "i want you to", "now")
}

func episodeContainsAny(value string, terms ...string) bool {
	for _, term := range terms {
		if strings.Contains(value, term) {
			return true
		}
	}
	return false
}

func workEpisodePrompt(episode core.WorkEpisode) string {
	data, err := json.Marshal(struct {
		Effort             core.EffortContract    `json:"effort"`
		Authority          core.AuthorityBoundary `json:"authority"`
		Objective          string                 `json:"objective"`
		RequiredCoverage   []string               `json:"required_coverage"`
		CompletionCriteria []string               `json:"completion_criteria"`
	}{
		Effort: episode.Effort, Authority: episode.Authority,
		Objective: episode.Objective, RequiredCoverage: episode.RequiredCoverage,
		CompletionCriteria: episode.CompletionCriteria,
	})
	if err != nil {
		return ""
	}
	return `<host-work-episode>
` + string(data) + `
This contract controls effort, not permission. Work until its completion criteria are satisfied or
you are genuinely blocked. For operational_assessment and incident_investigation, assess every
required coverage layer; use status unknown with a precise detail when authoritative evidence is
unavailable. For an operational_assessment, return completion.verdict as exactly healthy, degraded,
or unhealthy. Formal SLOs are not required for that verdict: when the organization has none, use
fresh functional behavior, errors and timeouts, alerts, failures, saturation, dependencies, and
recent-change evidence, and mark slo coverage not_applicable. Never use unknown as the overall
health verdict. Treat a pinned or scheduled runbook as a reproducible baseline rather than the whole
assessment: inspect what it proved, then continue through all relevant read-only routes for material
claims it did not cover. Discover evidence by claim and retry with narrower operational language when
the first discovery result is empty or indirect. Explicitly seek functional or synthetic behavior,
current error and timeout trends against a recent baseline, active alerts, workload failures,
dependency health, saturation or capacity pressure, and recent deployments or configuration changes.
Do not declare a source unavailable merely because a preferred connector is absent when an equivalent
repository, log, metric, trace, provider, or Emisar route exists. Missing evidence alone is not
degradation. Do not generalize one shallow probe, one CDN aggregate, an empty alert list, or running
workloads into platform-wide healthy application behavior. Combine representative functional checks
with the broadest available application error and timeout trend, reconcile service-specific anomalies,
and compare rates only across equivalent time windows, populations, and denominators. Separate
observation, correlation, bounded cause, and proven causation: concurrent upstream and downstream
errors bound a failure path but do not prove an implementation mapping without code, trace, or other
direct evidence. Preserve metric window and aggregation semantics, and quote an exact maximum, rate,
or comparison only when the cited result directly supports it. Scope functional claims exactly to
the tested workflows and endpoints; a few successful URLs do not prove that the whole website,
application, or platform is functional. Recommend rollback only after identifying an exact candidate
version and evidence that it was previously healthy; otherwise state a bounded containment option and
what must be verified before any version-changing action. Keep evidence claims atomic: every clause
must be supported by the cited source, without joining a verified parser error, timeout, status code,
deployment, or dependency event to an inferred surrounding event. The overall verdict is a
classification, not proof that every unnamed component works. In degraded or unhealthy reports, lead
with the verified failing scope and impact; do not broadly reassure that the platform, website, or
users are otherwise being served without direct user-facing evidence. Metrics can establish impact,
but not by themselves a cause or safe containment control. For an active issue, use at least one
diagnostic source such as logs, traces, an affected functional check, dependency evidence, or owning
repository code before stating a cause boundary or mitigation. Do not invent rollback, edge shedding,
caching, failover, throttling, or another control unless evidence proves it exists and applies. If no
safe containment is established after available diagnosis, say so and recommend freezing related
nonessential changes plus the exact owner or evidence route needed next. Return
completion.status=decision_ready only when no material gap could change the decision.
Set completion.verdict only for decision_ready; a blocked result has no operational verdict. Keep its
Slack synthesis decision-first and compact, normally one short verdict paragraph and at most six
evidence-rich bullets. For decision_ready, return material_gaps as an empty list; keep non-blocking
uncertainty in the relevant coverage detail and mention it only when it changes how the verdict should
be used. material_gaps is reserved for external blockers that make completion.status=blocked.
Discovering confirmed or likely active degradation expands the episode: do not stop at
symptom counts, broad service names, or a recommendation that somebody investigate next. Use the
available repository, logs, metrics, traces, and operational tools to identify the affected request
paths, users or blast radius, correlate likely changes and dependencies, and establish either a
verified root cause or an actionable cause boundary. A decision-ready active issue must include an
alert_assessment with cause_status identified or bounded, the cause boundary, a concrete immediate
mitigation, the fresh verification that would prove it worked, and the durable solution. If an
authoritative route needed for that diagnosis is externally unavailable, return blocked and name it
exactly. A blocker is an external boundary, not unfinished work: use completion.status=blocked only
after relevant available evidence routes were attempted and access, unavailable telemetry, required
operator input, an authority boundary, or a tool failure prevents further progress. Include the typed
blocker_kind, the attempts already made, every material gap, and the external action that unblocks
the work. "Query", "inspect", "check", or "investigate" is work to continue now when it is within
the current authority, not a valid next_action for a blocked result. Never broaden the authority
boundary.
</host-work-episode>`
}

func episodeDiagnosisCorrection(
	episode core.WorkEpisode,
	action string,
	coverage []core.Coverage,
	assessment *alertAssessment,
	completion *completionAssessment,
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
	return ""
}

func episodeCompletionCorrection(
	episode core.WorkEpisode,
	action string,
	coverage []core.Coverage,
	completion *completionAssessment,
) string {
	if action != "reply" || (episode.Effort != core.EffortOperationalAssessment &&
		episode.Effort != core.EffortIncidentInvestigation) {
		return ""
	}
	if completion == nil {
		return "the deep work episode has no completion assessment; continue until the result is decision-ready or return an exact blocker"
	}
	if completion.Status != "decision_ready" && completion.Status != "blocked" {
		return "completion.status must be decision_ready or blocked; partial work must continue instead of being presented as final"
	}
	if strings.TrimSpace(completion.Summary) == "" {
		return "the completion assessment has no concise decision summary"
	}
	covered := make(map[string]core.Coverage, len(coverage))
	for _, item := range coverage {
		covered[item.Layer] = item
	}
	missing := make([]string, 0)
	unknown := make([]string, 0)
	for _, layer := range episode.RequiredCoverage {
		item, ok := covered[layer]
		if !ok {
			missing = append(missing, layer)
			continue
		}
		if item.Status == "unknown" {
			if strings.TrimSpace(item.Detail) == "" {
				return fmt.Sprintf("coverage layer %s is unknown without explaining the evidence gap", layer)
			}
			unknown = append(unknown, layer)
		}
	}
	if len(missing) > 0 {
		return "the deep work episode has not assessed required coverage layers: " + strings.Join(missing, ", ")
	}
	if completion.Status == "decision_ready" && (len(completion.MaterialGaps) > 0 || len(unknown) > 0) {
		if episode.Effort != core.EffortOperationalAssessment || len(completion.MaterialGaps) > 0 {
			return "the result claims decision_ready while material coverage remains unknown; either continue the investigation or return blocked with the exact next action"
		}
	}
	if completion.Status == "decision_ready" && episode.Effort == core.EffortOperationalAssessment {
		if !validOperationalHealthVerdict(completion.Verdict) {
			return "an operational assessment must set completion.verdict to healthy, degraded, or unhealthy; unknown is not an operational verdict"
		}
		if correction := operationalHealthVerdictCorrection(completion.Verdict, covered, unknown); correction != "" {
			return correction
		}
	}
	if completion.Status == "blocked" {
		if len(completion.MaterialGaps) == 0 {
			return "a blocked completion must list the material evidence or authority gaps"
		}
		if !validCompletionBlockerKind(completion.BlockerKind) {
			return "a blocked completion must identify an external blocker_kind: source_unavailable, access_denied, operator_input_required, authority_boundary, or tool_failure"
		}
		if len(completion.Attempts) == 0 {
			return "a blocked completion must state which relevant evidence routes or actions were already attempted"
		}
		if strings.TrimSpace(completion.NextAction) == "" {
			return "a blocked completion must state the concrete next action that unblocks the work"
		}
	}
	return ""
}

func operationalHealthVerdictCorrection(
	verdict string,
	covered map[string]core.Coverage,
	unknown []string,
) string {
	hasDegraded := false
	hasUnhealthy := false
	for _, item := range covered {
		switch item.Status {
		case "degraded":
			hasDegraded = true
		case "unhealthy":
			hasUnhealthy = true
		}
	}
	if hasUnhealthy && verdict != "unhealthy" {
		return "unhealthy coverage requires the overall completion verdict unhealthy"
	}
	if !hasUnhealthy && hasDegraded && verdict != "degraded" {
		return "degraded coverage requires the overall completion verdict degraded"
	}
	if !hasUnhealthy && !hasDegraded && verdict != "healthy" {
		return "a degraded or unhealthy verdict requires matching verified coverage"
	}
	if verdict != "healthy" {
		return ""
	}
	for _, layer := range unknown {
		if layer != "slo" {
			return "a healthy verdict cannot leave material operational coverage unknown; continue the available checks or return an exact blocker"
		}
	}
	application, ok := covered["application"]
	if !ok || application.Status != "healthy" {
		return "a healthy platform verdict requires fresh application or functional behavior evidence, not only healthy infrastructure inventory"
	}
	return ""
}

func completionEpisodePhase(
	completion *completionAssessment,
	pendingApproval *core.EmisarApproval,
) (core.WorkEpisodeState, string, string, string) {
	if pendingApproval != nil {
		return core.EpisodeWaitingApproval, "waiting_for_approval",
			"Waiting for Emisar approval", "Continue automatically after the Emisar decision"
	}
	if completion != nil && completion.Status == "blocked" {
		return core.EpisodeBlocked, "blocked", completion.Summary, completion.NextAction
	}
	return core.EpisodeCompleted, "finished", "Completed", ""
}

func episodeProgressDue(interval time.Duration) time.Time {
	if interval <= 0 {
		return time.Time{}
	}
	return time.Now().UTC().Add(interval)
}

func (s *Service) refreshWorkEpisodeProgress(
	ctx context.Context,
	run core.AgentRun,
) error {
	episode, err := s.store.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		return err
	}
	if episode.State != core.EpisodeWorking {
		return nil
	}
	now := time.Now().UTC()
	interval := s.cfg.Limits.EpisodeProgressInterval.Duration
	if !episode.ProgressDueAt.IsZero() && episode.ProgressDueAt.After(now) {
		return nil
	}
	if episode.ProgressDueAt.IsZero() && !episode.LastProgressAt.IsZero() &&
		now.Sub(episode.LastProgressAt) < interval {
		return nil
	}
	summary := "Still working; completing the requested checks"
	switch episode.Effort {
	case core.EffortOperationalAssessment:
		summary = "Still working; checking every required system layer"
	case core.EffortIncidentInvestigation:
		summary = "Still investigating; verifying impact and the safest response"
	case core.EffortEngineeringTask:
		summary = "Still working; implementing and validating the focused change"
	}
	_, err = s.store.RecordWorkEpisodeProgress(
		ctx,
		run.ID,
		"investigating",
		summary,
		episodeProgressDue(interval),
	)
	if err != nil {
		return err
	}
	if run.Mode != core.AgentRunTriage && run.IncidentID != "" {
		incident, getErr := s.store.GetIncident(ctx, run.IncidentID)
		if getErr == nil {
			s.setNativeStatus(ctx, incident, s.agentRunNativeStatus(ctx, run))
		}
	}
	return nil
}
