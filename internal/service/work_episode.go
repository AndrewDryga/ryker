package service

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	schedulepkg "github.com/AndrewDryga/responder/internal/schedule"
)

type completionAssessment = investigation.CompletionAssessment

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
	state decisionpkg.WatchTurnState,
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
	if decisionpkg.MatchedOperationalAlertRule(state.MatchedRules) ||
		(input.Kind == "bot_message" && state.AlertPolicy != "" &&
			decisionpkg.OperationalAlertEvent(input.Text) && !decisionpkg.ExternalCoordinationOnlyEvent(input.Text)) {
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
	return decisionpkg.EpisodeContainsAny(
		text,
		"planning", "planned", "applying", "applied", "errored", "failed",
		"discarded", "canceled", "cancelled",
	)
}

func requestEpisodeActivity(text string) core.EpisodeActivity {
	switch {
	case simpleExplanationRequest(text):
		return core.ActivityExplaining
	case schedulepkg.ExplicitScheduleRequest(text):
		return core.ActivityScheduling
	default:
		return core.ActivityInvestigating
	}
}

func isOperationalAssessmentRequest(text string) bool {
	return decisionpkg.EpisodeContainsAny(text,
		"infrastructure health", "infra health", "production health", "system health",
		"health of our", "health of everything", "end-to-end", "end to end",
		"deep health", "deep check", "health review", "health assessment",
		"platform healthy", "full assessment", "overall health",
	)
}

func isFocusedCheckRequest(text string) bool {
	return decisionpkg.EpisodeContainsAny(text,
		"check ", "review ", "verify ", "inspect ", "look into", "investigate", "analyze", "analyse",
		"assess", "assessment",
		"rollout", "recovered", "recovery", "is it green", "is it healthy", "what failed",
		"what changed", "explain this alert", "extend ", "test ", "validate ",
	)
}

func operationalAssessmentCoverage(text string) []string {
	result := []string{"change", "host", "runtime", "workload", "dependency", "application", "slo"}
	if decisionpkg.EpisodeContainsAny(text, "hardware", "disk", "cpu", "memory", "thermal") {
		result = append([]string{"hardware"}, result...)
	}
	if decisionpkg.EpisodeContainsAny(text, "nomad", "kubernetes", "scheduler", "allocation") {
		result = append(result, "scheduler")
	}
	return result
}

func alertInvestigationCoverage(text string) []string {
	result := []string{"change", "application", "slo"}
	if decisionpkg.EpisodeContainsAny(text,
		"host", "node", "vm", "disk", "i/o", "io latency", "cpu", "memory",
		"oom", "systemd", "nvme", "filesystem",
	) {
		result = append(result, "host")
	}
	if decisionpkg.EpisodeContainsAny(text,
		"workload", "job", "process", "service", "container", "pod", "task",
	) {
		result = append(result, "workload")
	}
	if decisionpkg.EpisodeContainsAny(text, "nomad", "kubernetes", "scheduler", "alloc") {
		result = append(result, "scheduler")
	}
	if decisionpkg.EpisodeContainsAny(text, "database", "postgres", "cassandra", "redis", "dependency", "upstream") {
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
		if decisionpkg.EpisodeContainsAny(text, candidate.terms...) {
			result = append(result, candidate.layer)
		}
	}
	if slices.Contains(result, "task") && slices.Contains(result, "change") &&
		decisionpkg.EpisodeContainsAny(text, "cost", "billing", "spend") &&
		!decisionpkg.EpisodeContainsAny(text,
			"ci ", "cd ", "deploy", "release", "rollout", "revision", "terraform",
			"plan ", "diff ", "repository", "validation command",
		) {
		result = slices.DeleteFunc(result, func(layer string) bool { return layer == "change" })
	}
	return result
}

func explicitGovernedOperationRequest(text string) bool {
	if !decisionpkg.EpisodeContainsAny(text, "enable", "disable", "restart", "apply", "retry", "drain", "failover", "roll back", "rollback") {
		return false
	}
	return decisionpkg.EpisodeContainsAny(text, "can you", "please", "do it", "go ahead", "i want you to", "now")
}

func workEpisodePrompt(episode core.WorkEpisode) string {
	return investigation.Compile(episode).Prompt()
}

func unsupportedOperationalClaimCorrection(
	action string,
	message string,
	evidence []core.Evidence,
) string {
	if action != "reply" {
		return ""
	}
	normalized := strings.ToLower(strings.Join(strings.Fields(message), " "))
	noImpactClaim := decisionpkg.EpisodeContainsAny(normalized,
		"no current user impact", "no user impact", "no customer impact",
		"customers are unaffected", "users are unaffected",
	)
	recoveryClaim := decisionpkg.EpisodeContainsAny(normalized,
		"service recovered", "service has recovered", "fully recovered",
	)
	if !noImpactClaim && !recoveryClaim {
		return ""
	}
	hasImpactEvidence := false
	hasServiceEvidence := false
	for _, item := range evidence {
		switch strings.TrimSpace(item.ClaimID) {
		case "impact.current":
			hasImpactEvidence = true
		case "application.functional_behavior":
			hasServiceEvidence = true
		}
	}
	if noImpactClaim && !hasImpactEvidence {
		return "the reply claims no user or customer impact without evidence bound to impact.current; " +
			"state that impact is unverified or record direct service-indicator or user-path evidence"
	}
	if recoveryClaim && !hasServiceEvidence {
		return "the reply claims service recovery without evidence bound to application.functional_behavior; " +
			"an alert clearing proves only that the alert condition or evaluation cleared"
	}
	return ""
}

func (s *Service) episodeContinuityPrompt(
	ctx context.Context,
	episode core.WorkEpisode,
) string {
	if strings.TrimSpace(episode.ParentEpisodeID) == "" {
		return ""
	}
	evidence, evidenceErr := s.store.Intelligence.ListEpisodeEvidence(ctx, episode.ID, 30)
	coverage, coverageErr := s.store.Intelligence.ListEpisodeCoverage(ctx, episode.ID, 20)
	if evidenceErr != nil || coverageErr != nil || (len(evidence) == 0 && len(coverage) == 0) {
		return ""
	}
	payload, err := json.Marshal(struct {
		Evidence []core.Evidence `json:"evidence,omitempty"`
		Coverage []core.Coverage `json:"coverage,omitempty"`
	}{Evidence: evidence, Coverage: coverage})
	if err != nil {
		return ""
	}
	return "\n\n<episode-continuity>\n" +
		"These are bounded, host-recorded observations from earlier events in the same " +
		"operational lifecycle. Reconcile them with fresh evidence. A newer observation " +
		"from the same source supersedes an older one; do not publish a conclusion that " +
		"contradicts this history without naming the newer evidence that changed it.\n" +
		string(payload) + "\n</episode-continuity>"
}

func (s *Service) episodeClaimCorrectionWithHistory(
	ctx context.Context,
	episode core.WorkEpisode,
	action string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	completion *completionAssessment,
	now time.Time,
	strict bool,
) (string, error) {
	priorEvidence, err := s.store.Intelligence.ListEpisodeEvidence(ctx, episode.ID, 200)
	if err != nil {
		return "", err
	}
	priorCoverage, err := s.store.Intelligence.ListEpisodeCoverage(ctx, episode.ID, 200)
	if err != nil {
		return "", err
	}
	return investigation.ClaimCorrection(
		episode,
		action,
		append(priorEvidence, evidence...),
		append(priorCoverage, coverage...),
		completion,
		now,
		strict,
	), nil
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

func episodeProgressDue(interval time.Duration, now time.Time) time.Time {
	if interval <= 0 {
		return time.Time{}
	}
	return now.UTC().Add(interval)
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
	now := s.now().UTC()
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
		episodeProgressDue(interval, s.now()),
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
