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
	Summary      string   `json:"summary"`
	MaterialGaps []string `json:"material_gaps,omitempty"`
	NextAction   string   `json:"next_action,omitempty"`
}

func validateCompletionAssessment(completion *completionAssessment) error {
	if completion == nil {
		return nil
	}
	completion.Status = strings.TrimSpace(completion.Status)
	completion.Summary = strings.TrimSpace(completion.Summary)
	completion.NextAction = strings.TrimSpace(completion.NextAction)
	if len(completion.MaterialGaps) > 20 {
		return errors.New("completion assessment has too many material gaps")
	}
	for _, gap := range completion.MaterialGaps {
		if len(strings.TrimSpace(gap)) > 500 {
			return errors.New("completion assessment material gap exceeds 500 bytes")
		}
	}
	completion.MaterialGaps = normalizedCompletionGaps(completion.MaterialGaps)
	if len(completion.Status) > 32 || len(completion.Summary) > 1000 ||
		len(completion.NextAction) > 1000 {
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
	case "blocked":
		if completion.Summary == "" || len(completion.MaterialGaps) == 0 ||
			completion.NextAction == "" {
			return errors.New(
				"blocked completion requires summary, material_gaps, and next_action",
			)
		}
	default:
		return fmt.Errorf("unsupported completion status %q", completion.Status)
	}
	return nil
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
	if explicitBehaviorRequest(input.Text) {
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
		"deep health", "deep check", "full assessment", "overall health",
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
unavailable. Return completion.status=decision_ready only when no material gap could change the
decision. Otherwise return completion.status=blocked with every material gap and the concrete next
action. Never broaden the authority boundary.
</host-work-episode>`
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
		return "the result claims decision_ready while material coverage remains unknown; either continue the investigation or return blocked with the exact next action"
	}
	if completion.Status == "blocked" {
		if len(completion.MaterialGaps) == 0 {
			return "a blocked completion must list the material evidence or authority gaps"
		}
		if strings.TrimSpace(completion.NextAction) == "" {
			return "a blocked completion must state the concrete next action that unblocks the work"
		}
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
