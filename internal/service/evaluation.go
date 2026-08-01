package service

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

type EvaluationCase struct {
	Name                   string                   `json:"name"`
	Tags                   []string                 `json:"tags,omitempty"`
	Kind                   string                   `json:"kind"`
	Lane                   string                   `json:"lane,omitempty"`
	Input                  string                   `json:"input,omitempty"`
	Repository             string                   `json:"repository,omitempty"`
	SenderType             string                   `json:"sender_type,omitempty"`
	SenderRole             string                   `json:"sender_role,omitempty"`
	MentionsResponder      bool                     `json:"mentions_responder,omitempty"`
	RecentMessages         []EvaluationMessage      `json:"recent_messages,omitempty"`
	FollowingMessages      []EvaluationMessage      `json:"following_messages,omitempty"`
	Memories               []EvaluationMemory       `json:"memories,omitempty"`
	Preferences            []EvaluationPreference   `json:"preferences,omitempty"`
	StandingRules          []EvaluationStandingRule `json:"standing_rules,omitempty"`
	Output                 string                   `json:"output,omitempty"`
	WantAction             string                   `json:"want_action,omitempty"`
	WantReaction           string                   `json:"want_reaction,omitempty"`
	WantReactionOneOf      []string                 `json:"want_reaction_one_of,omitempty"`
	WantAttentionAddressee string                   `json:"want_attention_addressee,omitempty"`
	MinAttentionScore      int                      `json:"min_attention_score,omitempty"`
	WantOffer              string                   `json:"want_offer,omitempty"`
	WantOffers             []string                 `json:"want_offers,omitempty"`
	WantMemoryContains     []string                 `json:"want_memory_contains,omitempty"`
	WantMessageContains    []string                 `json:"want_message_contains,omitempty"`
	ForbidMessageContains  []string                 `json:"forbid_message_contains,omitempty"`
	WantReasonContains     []string                 `json:"want_reason_contains,omitempty"`
	ForbidReasonContains   []string                 `json:"forbid_reason_contains,omitempty"`
	WantEvidenceSources    []string                 `json:"want_evidence_sources,omitempty"`
	ForbidEvidenceSources  []string                 `json:"forbid_evidence_sources,omitempty"`
	WantCoverageLayers     []string                 `json:"want_coverage_layers,omitempty"`
	WantCoverage           map[string]string        `json:"want_coverage,omitempty"`
	WantPendingApproval    *bool                    `json:"want_pending_approval,omitempty"`
	WantProposals          *int                     `json:"want_proposals,omitempty"`
	MinEvidence            int                      `json:"min_evidence,omitempty"`
	MaxEvidence            *int                     `json:"max_evidence,omitempty"`
	MinFreshEvidence       int                      `json:"min_fresh_evidence,omitempty"`
	MaxEvidenceAgeSeconds  int                      `json:"max_evidence_age_seconds,omitempty"`
	MinCoverage            int                      `json:"min_coverage,omitempty"`
	MaxCoverage            *int                     `json:"max_coverage,omitempty"`
	MinReplyMessages       int                      `json:"min_reply_messages,omitempty"`
	MaxMessageBytes        int                      `json:"max_message_bytes,omitempty"`
	MaxDurationMS          int64                    `json:"max_duration_ms,omitempty"`
	ProactiveLabel         string                   `json:"proactive_label,omitempty"`
	Judge                  bool                     `json:"judge,omitempty"`
	VerifyEvidence         bool                     `json:"verify_evidence,omitempty"`
	MinQualityScore        float64                  `json:"min_quality_score,omitempty"`
	CoopPolicy             string                   `json:"coop_policy,omitempty"`
	WantCommittedChanges   *bool                    `json:"want_committed_changes,omitempty"`
	WantChangedPaths       []string                 `json:"want_changed_paths,omitempty"`
	ForbidChangedPaths     []string                 `json:"forbid_changed_paths,omitempty"`
	WantReviewPublishable  *bool                    `json:"want_review_publishable,omitempty"`
	WantReviewGate         string                   `json:"want_review_gate,omitempty"`
}

type EvaluationMessage struct {
	SenderType        string `json:"sender_type"`
	SenderRole        string `json:"sender_role,omitempty"`
	Text              string `json:"text"`
	MentionsResponder bool   `json:"mentions_responder,omitempty"`
}

type EvaluationPreference struct {
	Scope     string `json:"scope"`
	Name      string `json:"name"`
	Value     string `json:"value"`
	ExpiresAt string `json:"expires_at"`
}

type EvaluationMemory struct {
	Scope          string `json:"scope"`
	Subject        string `json:"subject"`
	Predicate      string `json:"predicate"`
	Value          string `json:"value"`
	SourceRevision string `json:"source_revision,omitempty"`
	ExpiresAt      string `json:"expires_at"`
}

type EvaluationStandingRule struct {
	ID         string `json:"id"`
	Trigger    string `json:"trigger"`
	Action     string `json:"action"`
	Repository string `json:"repository"`
	SourceKind string `json:"source_kind"`
}

type EvaluationResult struct {
	Name         string                  `json:"name"`
	CaseName     string                  `json:"case_name,omitempty"`
	Repetition   int                     `json:"repetition,omitempty"`
	Passed       bool                    `json:"passed"`
	Detail       string                  `json:"detail,omitempty"`
	Response     string                  `json:"response,omitempty"`
	DurationMS   int64                   `json:"duration_ms,omitempty"`
	Action       string                  `json:"action,omitempty"`
	SlackUX      SlackUXAssessment       `json:"slack_ux,omitempty"`
	Quality      QualityAssessment       `json:"quality,omitempty"`
	Verification EvidenceVerification    `json:"verification,omitempty"`
	Lifecycle    TurnLifecycleAssessment `json:"lifecycle,omitempty"`
	Artifacts    WorkspaceAssessment     `json:"artifacts,omitempty"`
}

type EvaluationSummary struct {
	Mode         string               `json:"mode,omitempty"`
	CorpusDigest string               `json:"corpus_digest,omitempty"`
	Total        int                  `json:"total"`
	Passed       int                  `json:"passed"`
	Failed       int                  `json:"failed"`
	ModelCalls   int                  `json:"model_calls,omitempty"`
	DurationMS   int64                `json:"duration_ms,omitempty"`
	Proactivity  ProactivityMetrics   `json:"proactivity,omitempty"`
	Quality      QualityMetrics       `json:"quality,omitempty"`
	Cases        []CaseAggregate      `json:"cases,omitempty"`
	Gate         EvaluationGateResult `json:"gate,omitempty"`
	Results      []EvaluationResult   `json:"results"`
}

func EvaluateJSONL(reader io.Reader) (EvaluationSummary, error) {
	cases, err := decodeEvaluationCases(reader)
	if err != nil {
		return EvaluationSummary{}, err
	}
	summary := EvaluationSummary{
		Mode:         "replay",
		CorpusDigest: evaluationCorpusDigest(cases),
	}
	for _, testCase := range cases {
		result := evaluateCase(testCase)
		summary.Total++
		if result.Passed {
			summary.Passed++
		} else {
			summary.Failed++
		}
		summary.Results = append(summary.Results, result)
	}
	summarizeEvaluation(&summary)
	return summary, nil
}

func decodeEvaluationCases(reader io.Reader) ([]EvaluationCase, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	var cases []EvaluationCase
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var testCase EvaluationCase
		decoder := json.NewDecoder(strings.NewReader(line))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&testCase); err != nil {
			return nil, fmt.Errorf(
				"decode evaluation case %d: %w", len(cases)+1, err,
			)
		}
		if err := validateEvaluationCase(testCase); err != nil {
			return nil, fmt.Errorf(
				"validate evaluation case %d (%q): %w",
				len(cases)+1,
				testCase.Name,
				err,
			)
		}
		cases = append(cases, testCase)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(cases) == 0 {
		return nil, fmt.Errorf("evaluation corpus is empty")
	}
	return cases, nil
}

func validateEvaluationCase(testCase EvaluationCase) error {
	switch testCase.Lane {
	case "", "conversation", "investigation":
	default:
		return errors.New("lane must be conversation or investigation")
	}
	switch testCase.ProactiveLabel {
	case "", "act", "silent", "exclude":
	default:
		return fmt.Errorf(
			"proactive_label must be act, silent, or exclude",
		)
	}
	if testCase.MinQualityScore < 0 || testCase.MinQualityScore > 5 {
		return errors.New("min_quality_score must be between 0 and 5")
	}
	return nil
}

func evaluateCase(testCase EvaluationCase) EvaluationResult {
	return evaluateCaseWithConfig(testCase, nil, time.Now().UTC())
}

func evaluateCaseWithConfig(
	testCase EvaluationCase,
	cfg *config.Config,
	now time.Time,
) EvaluationResult {
	result := EvaluationResult{Name: testCase.Name}
	if strings.TrimSpace(testCase.Name) == "" {
		result.Detail = "case has no name"
		return result
	}
	var action string
	var offer string
	var offers []string
	var message string
	var replyMessageCount int
	var reason string
	var reaction string
	var attention attentionAssessment
	var memory core.AgentMemory
	var evidence []core.Evidence
	var coverage []core.Coverage
	var pendingApproval bool
	var proposals int
	switch testCase.Kind {
	case "watch":
		decision, err := parseWatchDecision(testCase.Output)
		if err != nil {
			result.Detail = err.Error()
			return result
		}
		if cfg != nil {
			operatorID := "UEVALOPERATOR"
			if len(cfg.Slack.Operators) > 0 {
				operatorID = cfg.Slack.Operators[0]
			}
			input, _, contextErr := liveEvaluationWatchContext(
				testCase,
				"eval",
				operatorID,
			)
			if contextErr != nil {
				result.Detail = contextErr.Error()
				return result
			}
			state := watchTurnState{}
			if len(testCase.StandingRules) > 0 {
				state.MatchedRules = []core.StandingRule{{ID: "evaluation-rule"}}
			}
			decision = enforceAttentionPolicy(
				input,
				state,
				decision,
				cfg.Slack.ReplyAttention,
				cfg.Slack.ReactionAttention,
			)
			offers = hostedWatchDecisionOffers(*cfg, testCase, decision)
		} else {
			offers = watchDecisionOffers(decision)
		}
		offer = firstEvaluationOffer(offers)
		action = decision.Action
		reaction = decision.Reaction
		attention = decision.Attention
		memory = decision.Memory
		reason = decision.Reason
		if decision.Action == "reply" {
			replies := replySequence(decision.Message, decision.FollowupMessages)
			message = strings.Join(replies, "\n\n")
			replyMessageCount = len(replies)
		}
		evidence = decision.Evidence
		coverage = decision.Coverage
	case "incident", "task":
		report, structured, err := parseAgentReport(testCase.Output)
		if err != nil {
			result.Detail = err.Error()
			return result
		}
		if !structured {
			result.Detail = "incident response is not structured"
			return result
		}
		offers = agentReportOffers(report)
		offer = firstEvaluationOffer(offers)
		replies := replySequence(report.Message, report.FollowupMessages)
		message = strings.Join(replies, "\n\n")
		replyMessageCount = len(replies)
		evidence = report.Evidence
		coverage = report.Coverage
		pendingApproval = report.PendingApproval != nil
		proposals = len(report.Proposals)
	default:
		result.Detail = "kind must be watch, incident, or task"
		return result
	}
	if cfg != nil {
		evidence = sanitizeEvidence(evidence, "eval", "CEVALUATION", "")
		coverage = sanitizeCoverage(coverage, "eval", "CEVALUATION", "")
		sanitizer := slackui.NewSanitizer(cfg.Limits.MaxAssistantBytes)
		message = sanitizer.Text(message)
		reason = sanitizer.Text(reason)
	}
	if testCase.WantAction != "" && action != testCase.WantAction {
		result.Detail = fmt.Sprintf("action = %q, want %q", action, testCase.WantAction)
		return result
	}
	if len(testCase.WantOffers) > 0 {
		if len(offers) != len(testCase.WantOffers) {
			result.Detail = fmt.Sprintf("offers = %q, want %q", offers, testCase.WantOffers)
			return result
		}
		for _, expected := range testCase.WantOffers {
			if !containsExact(offers, expected) {
				result.Detail = fmt.Sprintf("offers = %q, want %q", offers, testCase.WantOffers)
				return result
			}
		}
	}
	if testCase.WantReaction != "" && reaction != testCase.WantReaction {
		result.Detail = fmt.Sprintf(
			"reaction = %q, want %q",
			reaction,
			testCase.WantReaction,
		)
		return result
	}
	if len(testCase.WantReactionOneOf) > 0 &&
		!containsExact(testCase.WantReactionOneOf, reaction) {
		result.Detail = fmt.Sprintf(
			"reaction = %q, want one of %q",
			reaction,
			testCase.WantReactionOneOf,
		)
		return result
	}
	if testCase.WantAttentionAddressee != "" &&
		attention.Addressee != testCase.WantAttentionAddressee {
		result.Detail = fmt.Sprintf(
			"attention addressee = %q, want %q",
			attention.Addressee,
			testCase.WantAttentionAddressee,
		)
		return result
	}
	if testCase.MinAttentionScore > 0 &&
		attention.score() < testCase.MinAttentionScore {
		result.Detail = fmt.Sprintf(
			"attention score = %d, want at least %d",
			attention.score(),
			testCase.MinAttentionScore,
		)
		return result
	}
	if len(testCase.WantMemoryContains) > 0 {
		encoded, err := json.Marshal(memory)
		if err != nil {
			result.Detail = "encode memory: " + err.Error()
			return result
		}
		for _, fragment := range testCase.WantMemoryContains {
			if !containsFold(string(encoded), fragment) {
				result.Detail = fmt.Sprintf(
					"memory does not contain %q: %s",
					fragment,
					encoded,
				)
				return result
			}
		}
	}
	if testCase.WantOffer != "" && offer != testCase.WantOffer {
		result.Detail = fmt.Sprintf("offer = %q, want %q", offer, testCase.WantOffer)
		return result
	}
	if len(evidence) < testCase.MinEvidence {
		result.Detail = fmt.Sprintf(
			"evidence = %d, want at least %d", len(evidence), testCase.MinEvidence,
		)
		return result
	}
	if testCase.MaxEvidence != nil && len(evidence) > *testCase.MaxEvidence {
		result.Detail = fmt.Sprintf(
			"evidence = %d, want at most %d", len(evidence), *testCase.MaxEvidence,
		)
		return result
	}
	if testCase.MinFreshEvidence > 0 {
		maxAge := time.Duration(testCase.MaxEvidenceAgeSeconds) * time.Second
		if maxAge <= 0 {
			maxAge = 15 * time.Minute
		}
		fresh := 0
		for _, item := range evidence {
			if item.ObservedAt.IsZero() || item.ObservedAt.After(now.Add(5*time.Minute)) {
				continue
			}
			if now.Sub(item.ObservedAt) <= maxAge {
				fresh++
			}
		}
		if fresh < testCase.MinFreshEvidence {
			result.Detail = fmt.Sprintf(
				"fresh evidence = %d, want at least %d within %s",
				fresh,
				testCase.MinFreshEvidence,
				maxAge,
			)
			return result
		}
	}
	if len(coverage) < testCase.MinCoverage {
		result.Detail = fmt.Sprintf(
			"coverage = %d, want at least %d", len(coverage), testCase.MinCoverage,
		)
		return result
	}
	if replyMessageCount < testCase.MinReplyMessages {
		result.Detail = fmt.Sprintf(
			"reply messages = %d, want at least %d",
			replyMessageCount,
			testCase.MinReplyMessages,
		)
		return result
	}
	if testCase.MaxCoverage != nil && len(coverage) > *testCase.MaxCoverage {
		result.Detail = fmt.Sprintf(
			"coverage = %d, want at most %d", len(coverage), *testCase.MaxCoverage,
		)
		return result
	}
	if testCase.MaxMessageBytes > 0 && len(message) > testCase.MaxMessageBytes {
		result.Detail = fmt.Sprintf(
			"message bytes = %d, want at most %d", len(message), testCase.MaxMessageBytes,
		)
		return result
	}
	for _, expected := range testCase.WantMessageContains {
		if !containsFold(message, expected) {
			result.Detail = fmt.Sprintf("message does not contain %q", expected)
			return result
		}
	}
	for _, forbidden := range testCase.ForbidMessageContains {
		if containsFold(message, forbidden) {
			result.Detail = fmt.Sprintf("message contains forbidden text %q", forbidden)
			return result
		}
	}
	for _, expected := range testCase.WantReasonContains {
		if !containsFold(reason, expected) {
			result.Detail = fmt.Sprintf("reason does not contain %q", expected)
			return result
		}
	}
	for _, forbidden := range testCase.ForbidReasonContains {
		if containsFold(reason, forbidden) {
			result.Detail = fmt.Sprintf("reason contains forbidden text %q", forbidden)
			return result
		}
	}
	for _, expected := range testCase.WantEvidenceSources {
		if !hasEvidenceSource(evidence, expected) {
			result.Detail = fmt.Sprintf("evidence has no source_type %q", expected)
			return result
		}
	}
	for _, forbidden := range testCase.ForbidEvidenceSources {
		if hasEvidenceSource(evidence, forbidden) {
			result.Detail = fmt.Sprintf(
				"evidence contains forbidden source_type %q",
				forbidden,
			)
			return result
		}
	}
	for _, layer := range testCase.WantCoverageLayers {
		if !hasCoverageLayer(coverage, layer) {
			result.Detail = fmt.Sprintf("coverage has no %q layer", layer)
			return result
		}
	}
	for layer, status := range testCase.WantCoverage {
		if !hasCoverage(coverage, layer, status) {
			result.Detail = fmt.Sprintf("coverage has no %q layer with status %q", layer, status)
			return result
		}
	}
	if testCase.WantPendingApproval != nil &&
		pendingApproval != *testCase.WantPendingApproval {
		result.Detail = fmt.Sprintf(
			"pending approval = %t, want %t",
			pendingApproval,
			*testCase.WantPendingApproval,
		)
		return result
	}
	if testCase.WantProposals != nil && proposals != *testCase.WantProposals {
		result.Detail = fmt.Sprintf("proposals = %d, want %d", proposals, *testCase.WantProposals)
		return result
	}
	result.Passed = true
	return result
}

func hostedWatchDecisionOffers(
	cfg config.Config,
	testCase EvaluationCase,
	decision watchDecision,
) []string {
	operatorID := "UEVALOPERATOR"
	if len(cfg.Slack.Operators) > 0 {
		operatorID = cfg.Slack.Operators[0]
	}
	input, _, err := liveEvaluationWatchContext(testCase, "eval", operatorID)
	if err != nil {
		return []string{"invalid"}
	}
	evaluator := &Service{cfg: cfg}
	result := make([]string, 0, 3)
	if decision.IncidentTitle != "" {
		return []string{"incident"}
	}
	if decision.TaskTitle != "" {
		if _, err := evaluator.resolveTaskOfferRepository(decision.TaskRepository); err != nil {
			return nil
		}
		result = append(result, "engineering_task")
	}
	if decision.MemoryOffer != nil {
		if _, _, _, ok := evaluator.prepareMemoryOfferAction(
			input,
			decision.MemoryOffer,
		); ok {
			result = append(result, "memory")
		}
	}
	if decision.PreferenceOffer != nil {
		if _, _, _, ok := evaluator.preparePreferenceOfferAction(
			input,
			decision.PreferenceOffer,
		); ok {
			result = append(result, "preference")
		}
	}
	if decision.RuleOffer != nil {
		if _, _, _, ok := evaluator.prepareRuleOfferAction(
			input,
			decision.RuleOffer,
		); ok {
			result = append(result, "rule")
		}
	}
	if decision.ScheduleOffer != nil {
		if _, _, _, ok := evaluator.prepareScheduleOfferAction(
			context.Background(), input, decision.ScheduleOffer,
		); ok {
			result = append(result, "schedule")
		}
	}
	return result
}

func watchDecisionOffers(decision watchDecision) []string {
	result := make([]string, 0, 4)
	if decision.IncidentTitle != "" {
		return []string{"incident"}
	}
	if decision.TaskTitle != "" {
		result = append(result, "engineering_task")
	}
	if decision.MemoryOffer != nil {
		result = append(result, "memory")
	}
	if decision.PreferenceOffer != nil {
		result = append(result, "preference")
	}
	if decision.RuleOffer != nil {
		result = append(result, "rule")
	}
	if decision.ScheduleOffer != nil {
		result = append(result, "schedule")
	}
	return result
}

func agentReportOffers(report agentReport) []string {
	result := make([]string, 0, 3)
	if report.MemoryOffer != nil {
		result = append(result, "memory")
	}
	if report.PreferenceOffer != nil {
		result = append(result, "preference")
	}
	if report.RuleOffer != nil {
		result = append(result, "rule")
	}
	if report.ScheduleOffer != nil {
		result = append(result, "schedule")
	}
	return result
}

func firstEvaluationOffer(offers []string) string {
	if len(offers) == 0 {
		return "none"
	}
	return offers[0]
}

func containsFold(value, fragment string) bool {
	return strings.Contains(strings.ToLower(value), strings.ToLower(fragment))
}

func containsExact(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func hasEvidenceSource(evidence []core.Evidence, sourceType string) bool {
	for _, item := range evidence {
		if strings.EqualFold(strings.TrimSpace(item.SourceType), strings.TrimSpace(sourceType)) {
			return true
		}
	}
	return false
}

func hasCoverage(coverage []core.Coverage, layer, status string) bool {
	for _, item := range coverage {
		if strings.EqualFold(strings.TrimSpace(item.Layer), strings.TrimSpace(layer)) &&
			strings.EqualFold(strings.TrimSpace(item.Status), strings.TrimSpace(status)) {
			return true
		}
	}
	return false
}

func hasCoverageLayer(coverage []core.Coverage, layer string) bool {
	for _, item := range coverage {
		if strings.EqualFold(strings.TrimSpace(item.Layer), strings.TrimSpace(layer)) {
			return true
		}
	}
	return false
}
