package service

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

type completionAssessment = investigation.CompletionAssessment

var transientRecheckKeyPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9:._/@-]{0,159}$`)

func validateCompletionAssessment(completion *completionAssessment) error {
	if completion == nil {
		return nil
	}
	completion.Status = strings.TrimSpace(completion.Status)
	completion.Verdict = strings.TrimSpace(completion.Verdict)
	completion.Summary = strings.TrimSpace(completion.Summary)
	completion.BlockerKind = strings.TrimSpace(completion.BlockerKind)
	completion.Blocker = strings.TrimSpace(completion.Blocker)
	completion.NextAction = strings.TrimSpace(completion.NextAction)
	if completion.Recheck != nil {
		completion.Recheck.Key = strings.TrimSpace(completion.Recheck.Key)
		completion.Recheck.Reason = strings.TrimSpace(completion.Recheck.Reason)
	}
	if len(completion.MaterialGaps) > 20 {
		return errors.New("completion assessment has too many material gaps")
	}
	if len(completion.Attempts) > 12 {
		return errors.New("completion assessment has too many blocker attempts")
	}
	if len(completion.CapabilityGaps) > 8 {
		return errors.New("completion assessment has too many capability gaps")
	}
	for _, gap := range completion.MaterialGaps {
		if len(strings.TrimSpace(gap)) > 500 {
			return errors.New("completion assessment material gap exceeds 500 bytes")
		}
	}
	completion.MaterialGaps = normalizedCompletionGaps(completion.MaterialGaps)
	completion.Attempts = normalizedCompletionAttempts(completion.Attempts)
	for index := range completion.CapabilityGaps {
		gap := &completion.CapabilityGaps[index]
		gap.Capability = strings.TrimSpace(gap.Capability)
		gap.Status = strings.TrimSpace(gap.Status)
		gap.PackID = strings.TrimSpace(gap.PackID)
		gap.PackRef = strings.TrimSpace(gap.PackRef)
		gap.Recommendation = strings.TrimSpace(gap.Recommendation)
		gap.EvidenceRefs = normalizedCompletionAttempts(gap.EvidenceRefs)
		if err := validateCapabilityGap(*gap); err != nil {
			return fmt.Errorf("completion capability gap %d: %w", index+1, err)
		}
	}
	if len(completion.Status) > 32 || len(completion.Verdict) > 32 || len(completion.Summary) > 1000 ||
		len(completion.BlockerKind) > 64 || len(completion.Blocker) > 1000 || len(completion.NextAction) > 1000 {
		return errors.New("completion assessment exceeds its field bounds")
	}
	if completion.Blocker != "" {
		return errors.New("completion.blocker is descriptive but incomplete; use summary, material_gaps, blocker_kind, attempts, and next_action")
	}
	switch completion.Status {
	case "decision_ready":
		if completion.Summary == "" {
			return errors.New("decision-ready completion requires a summary")
		}
		boundedFailure := completion.Verdict == "failed" && completion.NextAction != ""
		if len(completion.MaterialGaps) > 0 && !boundedFailure {
			return errors.New("decision-ready completion cannot contain material gaps")
		}
		if completion.BlockerKind != "" || len(completion.Attempts) > 0 {
			return errors.New("decision-ready completion cannot contain blocker fields")
		}
		if completion.Recheck != nil {
			return errors.New("decision-ready completion cannot request a recheck")
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
		if completion.BlockerKind == "capability_unavailable" && len(completion.CapabilityGaps) == 0 {
			return errors.New("capability_unavailable blocker requires capability_gaps")
		}
		if completion.Recheck != nil {
			if completion.BlockerKind != "source_unavailable" && completion.BlockerKind != "tool_failure" {
				return errors.New("only a transient source or tool blocker can request a recheck")
			}
			if !transientRecheckKeyPattern.MatchString(completion.Recheck.Key) {
				return errors.New("completion recheck requires a bounded stable key")
			}
			if completion.Recheck.Reason == "" || len(completion.Recheck.Reason) > 500 {
				return errors.New("completion recheck requires a bounded reason")
			}
			if completion.Recheck.AfterSeconds < 30 || completion.Recheck.AfterSeconds > 1800 {
				return errors.New("completion recheck delay must be between 30 and 1800 seconds")
			}
			if completion.Recheck.AdditionalAttempts < 1 || completion.Recheck.AdditionalAttempts > 4 {
				return errors.New("completion recheck attempts must be between 1 and 4")
			}
		}
	default:
		return fmt.Errorf("unsupported completion status %q", completion.Status)
	}
	if completion.Verdict != "" && !validCompletionVerdict(completion.Verdict) {
		return fmt.Errorf("unsupported completion verdict %q", completion.Verdict)
	}
	return nil
}

func validCompletionVerdict(value string) bool {
	switch value {
	case "healthy", "degraded", "unhealthy",
		"in_progress", "needs_review", "succeeded", "failed", "inconclusive",
		"confirmed", "not_confirmed", "completed", "no_change", "partial":
		return true
	default:
		return false
	}
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
		"authority_boundary", "tool_failure", "capability_unavailable":
		return true
	default:
		return false
	}
}

func validateCapabilityGap(gap investigation.CapabilityGap) error {
	if gap.Capability == "" || len(gap.Capability) > 240 {
		return errors.New("requires a bounded capability")
	}
	if len(gap.EvidenceRefs) == 0 || len(gap.EvidenceRefs) > 8 {
		return errors.New("requires evidence_refs from pack discovery")
	}
	for _, ref := range gap.EvidenceRefs {
		if len(ref) > 240 {
			return errors.New("has an oversized evidence reference")
		}
	}
	if gap.Recommendation == "" || len(gap.Recommendation) > 500 {
		return errors.New("requires a bounded recommendation")
	}
	if len(gap.PackID) > 120 || len(gap.PackRef) > 300 {
		return errors.New("has an oversized pack identity")
	}
	switch gap.Status {
	case "not_installed", "not_trusted", "not_advertised", "incompatible":
		if gap.PackID == "" {
			return errors.New("requires an evidence-backed pack_id")
		}
	case "not_found":
		if gap.PackID != "" || gap.PackRef != "" {
			return errors.New("not_found cannot name a pack")
		}
	default:
		return fmt.Errorf("has unsupported status %q", gap.Status)
	}
	return nil
}

func validateCapabilityGapEvidence(
	completion *completionAssessment,
	evidence []core.Evidence,
) error {
	if completion == nil {
		return nil
	}
	for index, gap := range completion.CapabilityGaps {
		packObserved := gap.PackID == ""
		for _, ref := range gap.EvidenceRefs {
			matched := false
			for _, item := range evidence {
				if ref != item.ID && ref != item.SourceID && ref != item.SourceName {
					continue
				}
				if item.SourceType != "emisar" && item.SourceType != "repository" {
					return fmt.Errorf(
						"completion capability gap %d evidence %q must come from Emisar or a repository catalog",
						index+1,
						ref,
					)
				}
				matched = true
				if gap.PackID != "" && containsFold(
					strings.Join([]string{
						item.Claim, item.Observation, item.SourceName, item.Target,
					}, " "),
					gap.PackID,
				) {
					packObserved = true
				}
			}
			if !matched {
				return fmt.Errorf(
					"completion capability gap %d references unknown evidence %q",
					index+1,
					ref,
				)
			}
		}
		if !packObserved {
			return fmt.Errorf(
				"completion capability gap %d pack %q is not identified by its evidence",
				index+1,
				gap.PackID,
			)
		}
	}
	return nil
}

func appendCapabilityGuidance(
	message string,
	followups []string,
	completion *completionAssessment,
) (string, []string) {
	if completion == nil || len(completion.CapabilityGaps) == 0 {
		return message, followups
	}
	target := &message
	if len(followups) > 0 {
		target = &followups[len(followups)-1]
	}
	var recommendations []string
	allNotFound := true
	for _, gap := range completion.CapabilityGaps {
		recommendation := gap.Recommendation
		if gap.PackID != "" && !containsFold(recommendation, gap.PackID) {
			recommendation = "`" + gap.PackID + "`: " + recommendation
		}
		if containsFold(*target, recommendation) {
			continue
		}
		if gap.Status != "not_found" {
			allNotFound = false
		}
		recommendations = append(recommendations, recommendation)
	}
	if len(recommendations) == 0 {
		return message, followups
	}
	prefix := "**Capability to add:** "
	if allNotFound {
		prefix = "**Capability gap:** "
	}
	if len(recommendations) > 1 {
		prefix = "**Capability gaps**\n- "
		recommendations = []string{strings.Join(recommendations, "\n- ")}
	}
	*target = strings.TrimSpace(*target) + "\n\n" + prefix + recommendations[0]
	return message, followups
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
		Activity:  core.ActivityInvestigating,
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
		episode.Activity = core.ActivityEngineering
		episode.RequiredCoverage = nil
		episode.CompletionCriteria = []string{
			"inspect the relevant implementation and constraints",
			"make only the justified repository change",
			"run the strongest available focused validation",
			"report the exact diff, validation, and remaining gaps",
		}
	} else if sourceKind == "proposal" || strings.HasPrefix(sourceKind, "emisar_approval:") {
		episode.Authority = core.AuthorityGovernedOperation
		episode.Activity = core.ActivityOperating
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
		Activity:  core.ActivityOperating,
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
		WorkspaceID: input.TeamID,
		Effort:      core.EffortConversational,
		Authority:   core.AuthorityReadOnly,
		Activity:    requestEpisodeActivity(input.Text),
		Objective:   commitmentTitleForInput(input),
		CompletionCriteria: []string{
			"answer the current request directly",
			"separate verified facts from uncertainty",
		},
	}
	if input.Kind == "scheduled" {
		episode.Mode = core.EpisodeScheduledVerification
		episode.Activity = core.ActivityScheduling
	} else if len(state.MatchedRules) > 0 {
		episode.Mode = core.EpisodeStandingAssignment
	}
	// Configuration is accepted work, but it is not an operational assessment even
	// when the requested preference happens to mention health checks or alerts.
	if input.Kind != "scheduled" && explicitBehaviorRequest(input.Text) {
		if explicitPreferenceRequestPattern.MatchString(input.Text) ||
			explicitRuleRequestPattern.MatchString(input.Text) ||
			!isFocusedCheckRequest(text) {
			return episode
		}
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
		episode.Activity = core.ActivityInvestigating
		episode.RequiredCoverage = focusedCoverage(text)
		if investigation.Compile(*episode).Completion.ConclusionKind == "operational_health" &&
			!slices.Contains(episode.RequiredCoverage, "application") {
			episode.RequiredCoverage = append(episode.RequiredCoverage, "application")
		}
		if input.Kind == "bot_message" && externalChangeLifecycleEvent(text) {
			// Lifecycle words such as "errored" are not application-health evidence.
			// Keep the required claim on the exact change; impact may still be added
			// when an authoritative source establishes it.
			episode.RequiredCoverage = []string{"change"}
		}
		episode.CompletionCriteria = []string{
			"verify the named claim with the best available source",
			"state the result, material gap, and next action",
		}
		if input.Kind == "bot_message" && state.AlertPolicy != "automatic" {
			episode.CompletionCriteria = []string{
				"establish the exact current or terminal state from an authoritative source",
				"determine what failed, what may have partially changed, and the current impact",
				"state the safest concrete next action and how its result will be verified",
			}
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

func externalChangeLifecycleEvent(text string) bool {
	text = strings.ToLower(strings.Join(strings.Fields(text), " "))
	if !strings.Contains(text, "run ") && !strings.Contains(text, "apply ") &&
		!strings.Contains(text, "deployment ") && !strings.Contains(text, "build ") {
		return false
	}
	return episodeContainsAny(
		text,
		"planning", "planned", "applying", "applied", "errored", "failed",
		"discarded", "canceled", "cancelled",
	)
}

func requestEpisodeActivity(text string) core.EpisodeActivity {
	switch {
	case simpleExplanationRequest(text):
		return core.ActivityExplaining
	case explicitScheduleRequest(text):
		return core.ActivityScheduling
	default:
		return core.ActivityInvestigating
	}
}

func isOperationalAssessmentRequest(text string) bool {
	return episodeContainsAny(text,
		"infrastructure health", "infra health", "production health", "system health",
		"health of our", "health of everything", "end-to-end", "end to end",
		"deep health", "deep check", "health review", "health assessment",
		"platform healthy", "full assessment", "overall health",
	)
}

func isFocusedCheckRequest(text string) bool {
	return episodeContainsAny(text,
		"check ", "review ", "verify ", "inspect ", "look into", "investigate", "analyze", "analyse",
		"assess", "assessment",
		"rollout", "recovered", "recovery", "is it green", "is it healthy", "what failed",
		"what changed", "explain this alert", "extend ", "test ", "validate ",
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
		{"task", []string{"runbook", "publish", "draft", "cost", "billing", "spend"}},
		{"change", []string{"ci", "cd", "deploy", "release", "rollout", "revision", "terraform", "plan", "diff", "change", "repository", "validation command"}},
		{"host", []string{"host", "vm", "disk", "cpu", "memory", "systemd"}},
		{"runtime", []string{"runtime", "docker", "container"}},
		{"scheduler", []string{"nomad", "kubernetes", "scheduler", "allocation"}},
		{"workload", []string{"workload", "job", "process", "service"}},
		{"dependency", []string{"database", "postgres", "cassandra", "redis", "dependency", "upstream"}},
		{"application", []string{"application", "api", "endpoint", "request", "error", "timeout", "user path"}},
		{"slo", []string{"slo", "customer", "impact", "latency", "availability"}},
	} {
		if episodeContainsAny(text, candidate.terms...) {
			result = append(result, candidate.layer)
		}
	}
	if slices.Contains(result, "task") && slices.Contains(result, "change") &&
		episodeContainsAny(text, "cost", "billing", "spend") &&
		!episodeContainsAny(text,
			"ci ", "cd ", "deploy", "release", "rollout", "revision", "terraform",
			"plan ", "diff ", "repository", "validation command",
		) {
		result = slices.DeleteFunc(result, func(layer string) bool { return layer == "change" })
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
	return investigation.Compile(episode).Prompt()
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
	if action != "reply" {
		return ""
	}
	contract := investigation.Compile(episode)
	requireCompletion := contract.Completion.RequireVerdict ||
		episode.Effort == core.EffortOperationalAssessment ||
		episode.Effort == core.EffortIncidentInvestigation
	if completion == nil {
		if !requireCompletion {
			return ""
		}
		return "the deep work episode has no completion assessment; continue until the result is decision-ready or return an exact blocker"
	}
	if completion.Status != "decision_ready" && completion.Status != "blocked" {
		return "completion.status must be decision_ready or blocked; partial work must continue instead of being presented as final"
	}
	if strings.TrimSpace(completion.Summary) == "" {
		return "the completion assessment has no concise decision summary"
	}
	if completion.Status == "decision_ready" {
		if contract.Completion.RequireVerdict && strings.TrimSpace(completion.Verdict) == "" {
			return "completion.verdict is required and must be one of: " +
				strings.Join(contract.Completion.AllowedVerdicts, ", ")
		}
		if completion.Verdict != "" &&
			!slices.Contains(contract.Completion.AllowedVerdicts, completion.Verdict) {
			return fmt.Sprintf(
				"completion.verdict %q does not match the %s contract; use one of: %s",
				completion.Verdict,
				contract.Completion.ConclusionKind,
				strings.Join(contract.Completion.AllowedVerdicts, ", "),
			)
		}
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
		change := covered["change"]
		boundedTerminalFailure := contract.Completion.ConclusionKind == "change_review" &&
			completion.Verdict == "failed" && change.Status == "unhealthy" &&
			strings.TrimSpace(completion.NextAction) != ""
		unknownAllowed := contract.Completion.ConclusionKind == "operational_health" ||
			(contract.Completion.ConclusionKind == "change_review" &&
				(completion.Verdict == "in_progress" || completion.Verdict == "needs_review" ||
					completion.Verdict == "inconclusive" || boundedTerminalFailure)) ||
			(contract.Completion.ConclusionKind == "factual_assessment" &&
				(completion.Verdict == "" || completion.Verdict == "not_confirmed" ||
					completion.Verdict == "inconclusive"))
		if !unknownAllowed || (len(completion.MaterialGaps) > 0 && !boundedTerminalFailure) {
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
	if completion.Status == "decision_ready" && contract.Completion.ConclusionKind == "change_review" {
		change, ok := covered["change"]
		if !ok {
			return "a change review must assess the change coverage layer"
		}
		switch completion.Verdict {
		case "succeeded":
			if change.Status != "healthy" {
				return "a succeeded change verdict requires healthy terminal change evidence"
			}
		case "failed":
			if change.Status != "unhealthy" {
				return "a failed change verdict requires terminal failed change evidence"
			}
		case "in_progress":
			if change.Status != "unknown" {
				return "an in_progress change verdict must keep the terminal outcome unknown"
			}
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

func episodeConclusionLanguageCorrection(
	episode core.WorkEpisode,
	action string,
	message string,
) string {
	if action != "reply" || investigation.Compile(episode).Completion.ConclusionKind == "operational_health" {
		return ""
	}
	opening := strings.ToLower(strings.TrimSpace(message))
	if newline := strings.IndexByte(opening, '\n'); newline >= 0 {
		opening = opening[:newline]
	}
	opening = strings.NewReplacer("**", "", "__", "", "`", "").Replace(opening)
	opening = strings.TrimLeft(opening, "*_> ")
	for _, label := range []string{"healthy", "degraded", "unhealthy"} {
		if opening == label || strings.HasPrefix(opening, label+":") ||
			strings.HasPrefix(opening, label+" -") || strings.HasPrefix(opening, label+" --") ||
			strings.HasPrefix(opening, label+" \u2014") {
			return "this episode is not an operational health assessment; report its task, change, publication, schedule, or factual result directly instead of opening with " + label
		}
	}
	return ""
}

func episodeClaimCorrection(
	episode core.WorkEpisode,
	action string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	completion *completionAssessment,
	now time.Time,
	strict bool,
) string {
	if action != "reply" || completion == nil || completion.Status == "blocked" {
		return ""
	}
	contract := investigation.Compile(episode)
	typed := false
	for _, item := range evidence {
		if claimRequired(contract, item.ClaimID) {
			typed = true
			break
		}
	}
	if strict && len(contract.Claims) > 0 && !typed {
		return "the completed episode has no typed evidence bound to a required claim; emit record_evidence with an exact required claim_id before completing"
	}
	if !typed {
		return ""
	}
	for _, requirement := range contract.Claims {
		if !requirement.Required {
			continue
		}
		matched := false
		for _, item := range coverage {
			if item.Layer == requirement.Layer && slices.Contains(item.ClaimIDs, requirement.ID) {
				matched = true
				break
			}
		}
		if !matched {
			return "coverage for required claim " + requirement.ID + " must include its exact claim_id"
		}
	}
	ledger := investigation.BuildLedger(contract, evidence, coverage, now.UTC())
	return ledger.CompletionCorrectionFor(completion.Status, completion.Verdict)
}

func claimRequired(contract investigation.InvestigationContract, claimID string) bool {
	for _, requirement := range contract.Claims {
		if requirement.Required && requirement.ID == strings.TrimSpace(claimID) {
			return true
		}
	}
	return false
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
	operations []investigation.ResultOperation,
) (core.WorkEpisodeState, string, string, string) {
	if pendingApproval != nil {
		return core.EpisodeWaitingApproval, "waiting_for_approval",
			"Waiting for Emisar approval", "Continue automatically after the Emisar decision"
	}
	for _, operation := range operations {
		switch operation.Type {
		case "request_operator_input":
			return core.EpisodeWaitingOperator, "waiting_for_operator",
				"Waiting for your answer", operation.OperatorInput.Question
		case "wait_external":
			return core.EpisodeWaitingExternal, "waiting_for_external_event",
				"Waiting for an external update", "Resume when the matching event arrives"
		}
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
