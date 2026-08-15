package evaluation

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	attentionpkg "github.com/AndrewDryga/responder/internal/attention"
	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/taskaccess"
)

type EvaluationCase struct {
	Name              string              `json:"name"`
	Tags              []string            `json:"tags,omitempty"`
	Kind              string              `json:"kind"`
	Lane              string              `json:"lane,omitempty"`
	Input             string              `json:"input,omitempty"`
	Repository        string              `json:"repository,omitempty"`
	SenderType        string              `json:"sender_type,omitempty"`
	SenderRole        string              `json:"sender_role,omitempty"`
	MentionsResponder bool                `json:"mentions_responder,omitempty"`
	RecentMessages    []EvaluationMessage `json:"recent_messages,omitempty"`
	FollowingMessages []EvaluationMessage `json:"following_messages,omitempty"`
	// ChannelAroundRoot stages the case as a turn inside a thread, with these
	// messages sitting at channel level above the thread's root. It is the only
	// way a case can pose a reference that resolves outside its own thread —
	// "see above", "^", a reply to a notice that asked for one.
	ChannelAroundRoot      []EvaluationMessage       `json:"channel_around_root,omitempty"`
	Memories               []EvaluationMemory        `json:"memories,omitempty"`
	Preferences            []EvaluationPreference    `json:"preferences,omitempty"`
	StandingRules          []EvaluationStandingRule  `json:"standing_rules,omitempty"`
	RecordedEvents         []EvaluationRecordedEvent `json:"recorded_events,omitempty"`
	RecordedToolResults    []EvaluationToolResult    `json:"recorded_tool_results,omitempty"`
	Output                 string                    `json:"output,omitempty"`
	WantAction             string                    `json:"want_action,omitempty"`
	WantReaction           string                    `json:"want_reaction,omitempty"`
	WantReactionOneOf      []string                  `json:"want_reaction_one_of,omitempty"`
	WantAttentionAddressee string                    `json:"want_attention_addressee,omitempty"`
	MinAttentionScore      int                       `json:"min_attention_score,omitempty"`
	WantOffer              string                    `json:"want_offer,omitempty"`
	WantOffers             []string                  `json:"want_offers,omitempty"`
	WantMemoryContains     []string                  `json:"want_memory_contains,omitempty"`
	WantMessageContains    []string                  `json:"want_message_contains,omitempty"`
	ForbidMessageContains  []string                  `json:"forbid_message_contains,omitempty"`
	WantReasonContains     []string                  `json:"want_reason_contains,omitempty"`
	ForbidReasonContains   []string                  `json:"forbid_reason_contains,omitempty"`
	WantEvidenceSources    []string                  `json:"want_evidence_sources,omitempty"`
	ForbidEvidenceSources  []string                  `json:"forbid_evidence_sources,omitempty"`
	WantCoverageLayers     []string                  `json:"want_coverage_layers,omitempty"`
	WantCoverage           map[string]string         `json:"want_coverage,omitempty"`
	WantAlertAssessment    bool                      `json:"want_alert_assessment,omitempty"`
	WantAlertVerdict       string                    `json:"want_alert_verdict,omitempty"`
	WantImmediateAction    bool                      `json:"want_immediate_action,omitempty"`
	WantLongTermSolution   bool                      `json:"want_long_term_solution,omitempty"`
	RequireCompletion      bool                      `json:"require_completion,omitempty"`
	WantCompletionStatus   string                    `json:"want_completion_status,omitempty"`
	WantCompletionVerdict  string                    `json:"want_completion_verdict,omitempty"`
	WantPendingApproval    *bool                     `json:"want_pending_approval,omitempty"`
	MinEvidence            int                       `json:"min_evidence,omitempty"`
	MaxEvidence            *int                      `json:"max_evidence,omitempty"`
	MinFreshEvidence       int                       `json:"min_fresh_evidence,omitempty"`
	MaxEvidenceAgeSeconds  int                       `json:"max_evidence_age_seconds,omitempty"`
	MinCoverage            int                       `json:"min_coverage,omitempty"`
	MaxCoverage            *int                      `json:"max_coverage,omitempty"`
	MinReplyMessages       int                       `json:"min_reply_messages,omitempty"`
	MaxMessageBytes        int                       `json:"max_message_bytes,omitempty"`
	MaxDurationMS          int64                     `json:"max_duration_ms,omitempty"`
	ProactiveLabel         string                    `json:"proactive_label,omitempty"`
	Judge                  bool                      `json:"judge,omitempty"`
	VerifyEvidence         bool                      `json:"verify_evidence,omitempty"`
	MinQualityScore        float64                   `json:"min_quality_score,omitempty"`
	CoopPolicy             string                    `json:"coop_policy,omitempty"`
	WantCommittedChanges   *bool                     `json:"want_committed_changes,omitempty"`
	WantChangedPaths       []string                  `json:"want_changed_paths,omitempty"`
	ForbidChangedPaths     []string                  `json:"forbid_changed_paths,omitempty"`
	WantReviewPublishable  *bool                     `json:"want_review_publishable,omitempty"`
	WantReviewGate         string                    `json:"want_review_gate,omitempty"`
	// ReplyPlacement is where this reply actually landed — "thread", "channel",
	// or "" when the fixture does not model delivery. WantReplyPlacement is
	// where it belonged, and defaults to whatever the trigger asked for.
	//
	// Nothing in the corpus could express either until now, which is why the
	// judge could not see the second thing the operator complained about: "it
	// was posted in the channel itself and I can't even tell why". A trigger
	// that says "reply in thread" is read straight off the input, but the
	// message that drew that complaint was an alert notification, and an alert
	// never says where its answer goes. Only the case can.
	ReplyPlacement     string `json:"reply_placement,omitempty"`
	WantReplyPlacement string `json:"want_reply_placement,omitempty"`
}

type EvaluationRecordedEvent struct {
	Sequence   int64           `json:"sequence"`
	Kind       string          `json:"kind"`
	Actor      string          `json:"actor,omitempty"`
	OccurredAt string          `json:"occurred_at"`
	Payload    json.RawMessage `json:"payload"`
}

type EvaluationToolResult struct {
	ID         string          `json:"id"`
	Tool       string          `json:"tool"`
	SourceType string          `json:"source_type"`
	ObservedAt string          `json:"observed_at"`
	Sanitized  bool            `json:"sanitized"`
	Output     json.RawMessage `json:"output"`
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
	Name       string `json:"name"`
	CaseName   string `json:"case_name,omitempty"`
	Repetition int    `json:"repetition,omitempty"`
	Passed     bool   `json:"passed"`
	// Unevaluated marks a case the model never answered, as distinct from one
	// it answered wrongly.
	//
	// The first real run of the promoted-corrections gate reported "0/4 passed,
	// 4 failed" — and every one of the four had been rate limited before the
	// model saw it. Read literally that says four kept lessons have regressed,
	// which would send someone to read four fixtures looking for a product bug
	// that is not there. Worse, it is the reading that trains people to ignore
	// the gate, and a gate nobody believes is the same as no gate.
	//
	// An unevaluated case still fails the run — a rate limit must not let an
	// unproven fixture through — but it fails saying the corpus could not be
	// evaluated rather than that it did not pass.
	Unevaluated  bool                    `json:"unevaluated,omitempty"`
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
	Mode         string `json:"mode,omitempty"`
	CorpusDigest string `json:"corpus_digest,omitempty"`
	Total        int    `json:"total"`
	Passed       int    `json:"passed"`
	Failed       int    `json:"failed"`
	// Unevaluated counts cases the provider never let the model answer. They
	// are counted out of Failed so "4 failed" keeps meaning "four answers were
	// wrong", which is the only reading that sends a reader to the right place.
	Unevaluated int                  `json:"unevaluated,omitempty"`
	ModelCalls  int                  `json:"model_calls,omitempty"`
	DurationMS  int64                `json:"duration_ms,omitempty"`
	Proactivity ProactivityMetrics   `json:"proactivity,omitempty"`
	Quality     QualityMetrics       `json:"quality,omitempty"`
	Cases       []CaseAggregate      `json:"cases,omitempty"`
	Gate        EvaluationGateResult `json:"gate,omitempty"`
	Results     []EvaluationResult   `json:"results"`
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
	// Kind routes both halves of a case — which prompt is submitted and which
	// dialect the answer is graded in — so a kind nothing runs is a case that
	// exists and proves nothing. It is checked here, with the other enumerated
	// fields, because the alternative is finding the typo halfway through a
	// half-hour credentialed run. The empty kind is accepted because a scenario
	// step declares its expectations before the runner stamps them "watch".
	switch testCase.Kind {
	case "", "watch", "incident", "task", "handoff":
	default:
		return fmt.Errorf(
			"kind %q is not run by anything; use watch, incident, task, or handoff",
			testCase.Kind,
		)
	}
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
	if !decisionpkg.ValidReplyPlacement(testCase.ReplyPlacement) ||
		!decisionpkg.ValidReplyPlacement(testCase.WantReplyPlacement) {
		return errors.New("reply placement must be thread or channel")
	}
	switch testCase.WantCompletionStatus {
	case "", "decision_ready", "blocked":
	default:
		return errors.New("want_completion_status must be decision_ready or blocked")
	}
	lastSequence := int64(0)
	for index, event := range testCase.RecordedEvents {
		if event.Sequence <= lastSequence || strings.TrimSpace(event.Kind) == "" ||
			strings.TrimSpace(event.OccurredAt) == "" || len(event.Payload) == 0 ||
			!json.Valid(event.Payload) {
			return fmt.Errorf("recorded event %d is not a valid ordered sanitized event", index+1)
		}
		if _, err := time.Parse(time.RFC3339, event.OccurredAt); err != nil {
			return fmt.Errorf("recorded event %d occurred_at: %w", index+1, err)
		}
		lastSequence = event.Sequence
	}
	seenResults := make(map[string]struct{}, len(testCase.RecordedToolResults))
	for index, result := range testCase.RecordedToolResults {
		if strings.TrimSpace(result.ID) == "" || strings.TrimSpace(result.Tool) == "" ||
			strings.TrimSpace(result.SourceType) == "" || !result.Sanitized ||
			len(result.Output) == 0 || !json.Valid(result.Output) {
			return fmt.Errorf("recorded tool result %d is not a valid sanitized result", index+1)
		}
		if _, ok := seenResults[result.ID]; ok {
			return fmt.Errorf("recorded tool result %q is duplicated", result.ID)
		}
		seenResults[result.ID] = struct{}{}
		if _, err := time.Parse(time.RFC3339, result.ObservedAt); err != nil {
			return fmt.Errorf("recorded tool result %d observed_at: %w", index+1, err)
		}
	}
	return nil
}

func evaluateCase(testCase EvaluationCase) EvaluationResult {
	return evaluateCaseWithConfig(testCase, nil, time.Now().UTC())
}

func evaluationReferenceTime(testCase EvaluationCase, fallback time.Time) time.Time {
	reference := time.Time{}
	for _, event := range testCase.RecordedEvents {
		observed, err := time.Parse(time.RFC3339, event.OccurredAt)
		if err == nil && observed.After(reference) {
			reference = observed
		}
	}
	for _, result := range testCase.RecordedToolResults {
		observed, err := time.Parse(time.RFC3339, result.ObservedAt)
		if err == nil && observed.After(reference) {
			reference = observed
		}
	}
	if reference.IsZero() {
		return fallback
	}
	return reference
}

// evaluationObservation is what one evaluated case actually produced. It exists
// so expectations can be checked against a value instead of against a dozen
// locals threaded through one long function.
type evaluationObservation struct {
	action            string
	message           string
	reason            string
	reaction          string
	offer             string
	offers            []string
	evidence          []core.Evidence
	coverage          []core.Coverage
	completion        *service.CompletionAssessment
	assessment        *decisionpkg.AlertAssessment
	attention         decisionpkg.AttentionAssessment
	memory            core.AgentMemory
	replyMessageCount int
	pendingApproval   bool
	now               time.Time
}

// evaluationExpectationMismatch returns the first expectation the observation
// fails, or an empty string when the case passes.
//
// It is a long list of independent guard clauses by design. Each one is a case
// file assertion, and they are checked in a fixed order so a failing case
// always reports the same reason rather than whichever check happened to run
// first. Splitting them further would hide that ordering without making any
// single check easier to read.
func evaluationExpectationMismatch(
	testCase EvaluationCase,
	observed evaluationObservation,
) string {
	if testCase.WantAction != "" && observed.action != testCase.WantAction {
		return fmt.Sprintf("action = %q, want %q", observed.action, testCase.WantAction)
	}
	if testCase.WantAlertVerdict != "" &&
		(observed.assessment == nil || observed.assessment.Verdict != testCase.WantAlertVerdict) {
		actual := ""
		if observed.assessment != nil {
			actual = observed.assessment.Verdict
		}
		return fmt.Sprintf(
			"alert verdict = %q, want %q", actual, testCase.WantAlertVerdict,
		)
	}
	if testCase.WantAlertAssessment && observed.assessment == nil {
		return "alert assessment is missing"
	}
	if testCase.WantImmediateAction &&
		(observed.assessment == nil || strings.TrimSpace(observed.assessment.ImmediateAction) == "") {
		return "alert assessment has no immediate action"
	}
	if testCase.WantLongTermSolution &&
		(observed.assessment == nil || strings.TrimSpace(observed.assessment.LongTermSolution) == "") {
		return "alert assessment has no long-term solution"
	}
	if testCase.WantCompletionStatus != "" &&
		(observed.completion == nil || observed.completion.Status != testCase.WantCompletionStatus) {
		actual := ""
		if observed.completion != nil {
			actual = observed.completion.Status
		}
		return fmt.Sprintf(
			"completion status = %q, want %q",
			actual,
			testCase.WantCompletionStatus,
		)
	}
	if testCase.WantCompletionVerdict != "" &&
		(observed.completion == nil || observed.completion.Verdict != testCase.WantCompletionVerdict) {
		actual := ""
		if observed.completion != nil {
			actual = observed.completion.Verdict
		}
		return fmt.Sprintf(
			"completion verdict = %q, want %q",
			actual,
			testCase.WantCompletionVerdict,
		)
	}
	if len(testCase.WantOffers) > 0 {
		if len(observed.offers) != len(testCase.WantOffers) {
			return fmt.Sprintf("offers = %q, want %q", observed.offers, testCase.WantOffers)
		}
		for _, expected := range testCase.WantOffers {
			if !containsExact(observed.offers, expected) {
				return fmt.Sprintf("offers = %q, want %q", observed.offers, testCase.WantOffers)
			}
		}
	}
	if testCase.WantReaction != "" && observed.reaction != testCase.WantReaction {
		return fmt.Sprintf(
			"reaction = %q, want %q",
			observed.reaction,
			testCase.WantReaction,
		)
	}
	if len(testCase.WantReactionOneOf) > 0 &&
		!containsExact(testCase.WantReactionOneOf, observed.reaction) {
		return fmt.Sprintf(
			"reaction = %q, want one of %q",
			observed.reaction,
			testCase.WantReactionOneOf,
		)
	}
	if testCase.WantAttentionAddressee != "" &&
		observed.attention.Addressee != testCase.WantAttentionAddressee {
		return fmt.Sprintf(
			"attention addressee = %q, want %q",
			observed.attention.Addressee,
			testCase.WantAttentionAddressee,
		)
	}
	if testCase.MinAttentionScore > 0 &&
		observed.attention.Score() < testCase.MinAttentionScore {
		return fmt.Sprintf(
			"attention score = %d, want at least %d",
			observed.attention.Score(),
			testCase.MinAttentionScore,
		)
	}
	if len(testCase.WantMemoryContains) > 0 {
		encoded, err := json.Marshal(observed.memory)
		if err != nil {
			return "encode memory: " + err.Error()
		}
		for _, fragment := range testCase.WantMemoryContains {
			if !containsFold(string(encoded), fragment) {
				return fmt.Sprintf(
					"memory does not contain %q: %s",
					fragment,
					encoded,
				)
			}
		}
	}
	if testCase.WantOffer != "" && observed.offer != testCase.WantOffer {
		return fmt.Sprintf("offer = %q, want %q", observed.offer, testCase.WantOffer)
	}
	if len(observed.evidence) < testCase.MinEvidence {
		return fmt.Sprintf(
			"evidence = %d, want at least %d", len(observed.evidence), testCase.MinEvidence,
		)
	}
	if testCase.MaxEvidence != nil && len(observed.evidence) > *testCase.MaxEvidence {
		return fmt.Sprintf(
			"evidence = %d, want at most %d", len(observed.evidence), *testCase.MaxEvidence,
		)
	}
	if testCase.MinFreshEvidence > 0 {
		maxAge := time.Duration(testCase.MaxEvidenceAgeSeconds) * time.Second
		if maxAge <= 0 {
			maxAge = 15 * time.Minute
		}
		fresh := 0
		for _, item := range observed.evidence {
			if item.ObservedAt.IsZero() || item.ObservedAt.After(observed.now.Add(5*time.Minute)) {
				continue
			}
			if observed.now.Sub(item.ObservedAt) <= maxAge {
				fresh++
			}
		}
		if fresh < testCase.MinFreshEvidence {
			return fmt.Sprintf(
				"fresh evidence = %d, want at least %d within %s",
				fresh,
				testCase.MinFreshEvidence,
				maxAge,
			)
		}
	}
	if len(observed.coverage) < testCase.MinCoverage {
		return fmt.Sprintf(
			"coverage = %d, want at least %d", len(observed.coverage), testCase.MinCoverage,
		)
	}
	if observed.replyMessageCount < testCase.MinReplyMessages {
		return fmt.Sprintf(
			"reply messages = %d, want at least %d",
			observed.replyMessageCount,
			testCase.MinReplyMessages,
		)
	}
	if testCase.MaxCoverage != nil && len(observed.coverage) > *testCase.MaxCoverage {
		return fmt.Sprintf(
			"coverage = %d, want at most %d", len(observed.coverage), *testCase.MaxCoverage,
		)
	}
	if testCase.MaxMessageBytes > 0 && len(observed.message) > testCase.MaxMessageBytes {
		return fmt.Sprintf(
			"message bytes = %d, want at most %d", len(observed.message), testCase.MaxMessageBytes,
		)
	}
	for _, expected := range testCase.WantMessageContains {
		if !containsFold(observed.message, expected) {
			return fmt.Sprintf("message does not contain %q", expected)
		}
	}
	for _, forbidden := range testCase.ForbidMessageContains {
		if containsFold(observed.message, forbidden) {
			return fmt.Sprintf("message contains forbidden text %q", forbidden)
		}
	}
	for _, expected := range testCase.WantReasonContains {
		if !containsFold(observed.reason, expected) {
			return fmt.Sprintf("reason does not contain %q", expected)
		}
	}
	for _, forbidden := range testCase.ForbidReasonContains {
		if containsFold(observed.reason, forbidden) {
			return fmt.Sprintf("reason contains forbidden text %q", forbidden)
		}
	}
	for _, expected := range testCase.WantEvidenceSources {
		if !hasEvidenceSource(observed.evidence, expected) {
			return fmt.Sprintf("evidence has no source_type %q", expected)
		}
	}
	for _, forbidden := range testCase.ForbidEvidenceSources {
		if hasEvidenceSource(observed.evidence, forbidden) {
			return fmt.Sprintf(
				"evidence contains forbidden source_type %q",
				forbidden,
			)
		}
	}
	for _, layer := range testCase.WantCoverageLayers {
		if !hasCoverageLayer(observed.coverage, layer) {
			return fmt.Sprintf("coverage has no %q layer", layer)
		}
	}
	for layer, status := range testCase.WantCoverage {
		if !hasCoverage(observed.coverage, layer, status) {
			return fmt.Sprintf("coverage has no %q layer with status %q", layer, status)
		}
	}
	if testCase.WantPendingApproval != nil &&
		observed.pendingApproval != *testCase.WantPendingApproval {
		return fmt.Sprintf(
			"pending approval = %t, want %t",
			observed.pendingApproval,
			*testCase.WantPendingApproval,
		)
	}
	return ""
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
	var attention decisionpkg.AttentionAssessment
	var memory core.AgentMemory
	var evidence []core.Evidence
	var coverage []core.Coverage
	var assessment *decisionpkg.AlertAssessment
	var completion *service.CompletionAssessment
	var episode *core.WorkEpisode
	var pendingApproval bool
	var strictOperations bool
	var lifecycleContinuationCorrection string
	switch testCase.Kind {
	case "watch":
		decision, err := decisionpkg.ParseWatchDecision(testCase.Output, now)
		if err != nil {
			result.Detail = err.Error()
			return result
		}
		if cfg != nil {
			operatorID := "UEVALOPERATOR"
			if len(cfg.Slack.Operators) > 0 {
				operatorID = cfg.Slack.Operators[0]
			}
			input, recent, _, contextErr := liveEvaluationWatchContext(
				testCase,
				"eval",
				operatorID,
			)
			if contextErr != nil {
				result.Detail = contextErr.Error()
				return result
			}
			state := evaluationWatchState(testCase)
			state.RecentMessages = recent
			episode = service.NewEvaluator(*cfg).EpisodeForWatchedInput(input, state)
			decisionpkg.NormalizeAppAlertCompletion(input, &decision)
			lifecycleContinuationCorrection = service.TerraformLifecycleContinuationCorrection(
				input, state, decision,
			)
			decision = service.EnforceExternalLifecycleCommunication(input, decision)
			decision, _ = service.EnforceExternalLifecycleEvidence(input, *episode, decision)
			decision = attentionpkg.Enforce(
				input,
				state,
				decision,
				cfg.Slack.ReplyAttention,
				cfg.Slack.ReactionAttention,
			)
			decision, _ = decisionpkg.EnforceRecoveredAlertLink(input, state, decision)
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
			replies := decisionpkg.ReplySequence(decision.Message, decision.FollowupMessages)
			message = strings.Join(replies, "\n\n")
			replyMessageCount = len(replies)
		}
		evidence = decision.Evidence
		coverage = decision.Coverage
		assessment = decision.AlertAssessment
		completion = decision.Completion
		strictOperations = len(decision.AppliedOperations) > 0
	case "handoff":
		// A retiring session's turn is graded exactly where the host reads it.
		// finalizeSessionHandoffTurn parses the watch dialect and hands
		// decision.Memory.WithoutThreadScope() to ApplyHandoffMemory; nothing
		// else about the answer is ever used, because no reply is delivered, no
		// correction is sent back, and the session is retired either way.
		decision, err := decisionpkg.ParseWatchDecision(testCase.Output, now)
		if err != nil {
			result.Detail = "handoff result is not in the watch dialect: " + err.Error()
			return result
		}
		types := make([]string, 0, len(decision.AppliedOperations))
		for _, operation := range decision.AppliedOperations {
			types = append(types, operation.Type)
		}
		// This is also where "do not investigate, read anything, or reply in
		// Slack" is measured: a handoff that went off and worked comes back
		// carrying record_evidence and complete_episode beside its memory, and
		// the host's silent-ignore path accepts none of it.
		if len(types) != 1 || types[0] != "update_memory" {
			result.Detail = fmt.Sprintf(
				"handoff operations = %v, want exactly one update_memory", types,
			)
			return result
		}
		// ApplyHandoffMemory writes nothing when the memory marshals to "{}",
		// and WithoutThreadScope drops the goal before it gets there. So a
		// handoff that fills in only a goal, or nothing at all, spends the one
		// turn this session gets and leaves its successor reading exactly the
		// stale memory the rotation was supposed to refresh.
		memory = decision.Memory.WithoutThreadScope()
		encoded, err := json.Marshal(memory)
		if err != nil {
			result.Detail = "encode handed-off memory: " + err.Error()
			return result
		}
		if string(encoded) == "{}" {
			result.Detail = "the handoff carried no channel memory forward"
			return result
		}
		action = decision.Action
		reason = decision.Reason
	case "incident", "task":
		report, structured, err := decisionpkg.ParseAgentReport(testCase.Output)
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
		replies := decisionpkg.ReplySequence(report.Message, report.FollowupMessages)
		message = strings.Join(replies, "\n\n")
		replyMessageCount = len(replies)
		evidence = report.Evidence
		coverage = report.Coverage
		completion = report.Completion
		pendingApproval = report.PendingApproval != nil
		strictOperations = len(report.AppliedOperations) > 0
		if cfg != nil {
			mode := core.AgentRunIncident
			if testCase.Kind == "task" {
				mode = core.AgentRunEngineeringTask
			}
			episode = service.NewEvaluator(*cfg).EpisodeForIncident(
				core.Incident{Title: testCase.Name}, mode, "evaluation", testCase.Input,
			)
		}
	default:
		result.Detail = "kind must be watch, incident, task, or handoff"
		return result
	}
	if cfg != nil {
		evidence = decisionpkg.SanitizeEvidence(evidence, "eval", "CEVALUATION", "", now)
		coverage = decisionpkg.SanitizeCoverage(coverage, "eval", "CEVALUATION", "", now)
		sanitizer := slackui.NewSanitizer(cfg.Limits.MaxAssistantBytes)
		message = sanitizer.Text(message)
		reason = sanitizer.Text(reason)
	}
	if testCase.RequireCompletion && completion == nil {
		result.Detail = "completion assessment is missing"
		return result
	}
	if lifecycleContinuationCorrection != "" {
		result.Detail = "missing lifecycle continuation: " + lifecycleContinuationCorrection
		return result
	}
	if episode != nil {
		completionAction := action
		if testCase.Kind != "watch" {
			completionAction = "reply"
		}
		if correction := investigation.CompletionCorrection(
			*episode, completionAction, coverage, completion,
		); correction != "" {
			result.Detail = "premature completion: " + correction
			return result
		}
		if correction := investigation.ConclusionLanguageCorrection(
			*episode, completionAction, message,
		); correction != "" {
			result.Detail = "wrong conclusion language: " + correction
			return result
		}
		if correction := investigation.ClaimCorrection(
			// A replayed case is the first round of its own chain, so the chain
			// clock and the case clock are the same instant.
			*episode, completionAction, evidence, coverage, completion, now, now,
			strictOperations,
		); correction != "" {
			result.Detail = "unsupported completion: " + correction
			return result
		}
		if testCase.Kind == "watch" {
			if correction := decisionpkg.EpisodeDiagnosisCorrection(
				*episode, completionAction, evidence, coverage, assessment, completion,
			); correction != "" {
				result.Detail = "premature diagnosis: " + correction
				return result
			}
		}
	}
	if detail := evaluationExpectationMismatch(testCase, evaluationObservation{
		action: action, message: message, reason: reason, reaction: reaction,
		offer: offer, offers: offers, evidence: evidence, coverage: coverage,
		completion: completion, assessment: assessment, attention: attention,
		memory:            memory,
		replyMessageCount: replyMessageCount, pendingApproval: pendingApproval,
		now: now,
	}); detail != "" {
		result.Detail = detail
		return result
	}
	result.Passed = true
	return result
}

func hostedWatchDecisionOffers(
	cfg config.Config,
	testCase EvaluationCase,
	decision decisionpkg.WatchDecision,
) []string {
	operatorID := "UEVALOPERATOR"
	if len(cfg.Slack.Operators) > 0 {
		operatorID = cfg.Slack.Operators[0]
	}
	input, _, _, err := liveEvaluationWatchContext(testCase, "eval", operatorID)
	if err != nil {
		return []string{"invalid"}
	}
	evaluator := service.NewEvaluator(cfg)
	result := make([]string, 0, 3)
	if decision.IncidentTitle != "" {
		return []string{"incident"}
	}
	if decision.TaskTitle != "" {
		if _, err := taskaccess.ResolveOfferRepository(
			context.Background(), cfg, evaluator.Store(), input, decision.TaskRepository,
		); err != nil {
			return nil
		}
		result = append(result, "engineering_task")
	}
	if decision.MemoryOffer != nil {
		if _, _, _, _, ok := evaluator.PrepareMemoryOfferAction(
			input,
			decision.MemoryOffer,
		); ok {
			result = append(result, "memory")
		}
	}
	if decision.PreferenceOffer != nil {
		if _, _, _, ok := evaluator.PreparePreferenceOfferAction(
			input,
			decision.PreferenceOffer,
		); ok {
			result = append(result, "preference")
		}
	}
	if decision.RuleOffer != nil {
		if _, _, _, ok := evaluator.PrepareRuleOfferAction(
			input,
			decision.RuleOffer,
		); ok {
			result = append(result, "rule")
		}
	}
	if offers := service.OrderedScheduleOffers(decision.ScheduleOffer, decision.ScheduleOffers); len(offers) != 0 {
		valid := true
		for _, offer := range offers {
			if _, _, ok := evaluator.NormalizeScheduleOffer(context.Background(), input, offer); !ok {
				valid = false
				break
			}
		}
		if valid {
			result = append(result, "schedule")
		}
	}
	return result
}

func watchDecisionOffers(decision decisionpkg.WatchDecision) []string {
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
	if len(service.OrderedScheduleOffers(decision.ScheduleOffer, decision.ScheduleOffers)) != 0 {
		result = append(result, "schedule")
	}
	return result
}

func agentReportOffers(report decisionpkg.AgentReport) []string {
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
	if len(service.OrderedScheduleOffers(report.ScheduleOffer, report.ScheduleOffers)) != 0 {
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
