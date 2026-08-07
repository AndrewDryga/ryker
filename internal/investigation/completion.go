package investigation

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Completion validation and correction live here, beside the contract they
// check against, rather than in the service package.
//
// Keeping the rule next to the thing it validates is what stops the two
// drifting. It also means the offline evaluation family can reach them without
// depending on the runtime package, which is the coupling that has kept
// internal/service from being splittable.

// containsFold reports a case-insensitive substring match.
func containsFold(value, fragment string) bool {
	return strings.Contains(strings.ToLower(value), strings.ToLower(fragment))
}

var transientRecheckKeyPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9:._/@-]{0,159}$`)

// ValidateCompletion normalizes a model's completion claim and
// rejects it if it does not hold together.
//
// This runs before anything is shown to an operator or written down, because a
// malformed completion is worse than no completion: it either claims a decision
// nobody can act on, or reports a blocker with nothing to unblock.

// ValidateCompletion normalizes a model's completion claim and
// rejects it if it does not hold together.
//
// This runs before anything is shown to an operator or written down, because a
// malformed completion is worse than no completion: it either claims a decision
// nobody can act on, or reports a blocker with nothing to unblock.
func ValidateCompletion(completion *CompletionAssessment) error {
	if completion == nil {
		return nil
	}
	normalizeCompletionAssessment(completion)
	if err := boundCompletionAssessment(completion); err != nil {
		return err
	}
	switch completion.Status {
	case "decision_ready":
		if err := validateDecisionReadyCompletion(completion); err != nil {
			return err
		}
	case "blocked":
		if err := validateBlockedCompletion(completion); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unsupported completion status %q", completion.Status)
	}
	if completion.Verdict != "" && !validCompletionVerdict(completion.Verdict) {
		return fmt.Errorf("unsupported completion verdict %q", completion.Verdict)
	}
	return nil
}

// normalizeCompletionAssessment trims every free-text field to its canonical
// form, so validation and every later comparison see one spelling.

// normalizeCompletionAssessment trims every free-text field to its canonical
// form, so validation and every later comparison see one spelling.
func normalizeCompletionAssessment(completion *CompletionAssessment) {
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
	}
}

// boundCompletionAssessment enforces the size limits. They exist because every
// one of these fields is model-authored and ends up in a Slack message or a
// stored record, both of which have hard limits of their own.

// boundCompletionAssessment enforces the size limits. They exist because every
// one of these fields is model-authored and ends up in a Slack message or a
// stored record, both of which have hard limits of their own.
func boundCompletionAssessment(completion *CompletionAssessment) error {
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
		if err := validateCapabilityGap(completion.CapabilityGaps[index]); err != nil {
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
	return nil
}

// validateDecisionReadyCompletion rejects a decision-ready claim that is not
// actually decision-ready. The rule underneath all of these: if the model still
// has open gaps or an unresolved blocker, saying "decision ready" would put an
// operator's name on a conclusion that was never reached.

// validateDecisionReadyCompletion rejects a decision-ready claim that is not
// actually decision-ready. The rule underneath all of these: if the model still
// has open gaps or an unresolved blocker, saying "decision ready" would put an
// operator's name on a conclusion that was never reached.
func validateDecisionReadyCompletion(completion *CompletionAssessment) error {
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
	return nil
}

// validateBlockedCompletion rejects a blocker nobody could act on. A block is
// only useful if it names what is missing, what was already tried, and what
// would move it forward — which is why all five fields are required together.

// validateBlockedCompletion rejects a blocker nobody could act on. A block is
// only useful if it names what is missing, what was already tried, and what
// would move it forward — which is why all five fields are required together.
func validateBlockedCompletion(completion *CompletionAssessment) error {
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

func validateCapabilityGap(gap CapabilityGap) error {
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

func ValidateCapabilityGapEvidence(
	completion *CompletionAssessment,
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

func AppendCapabilityGuidance(
	message string,
	followups []string,
	completion *CompletionAssessment,
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

func CompletionCorrection(
	episode core.WorkEpisode,
	action string,
	coverage []core.Coverage,
	completion *CompletionAssessment,
) string {
	if action != "reply" {
		return ""
	}
	contract := Compile(episode)
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
	covered, unknown, correction := episodeCoverageState(episode, coverage)
	if correction != "" {
		return correction
	}
	if correction := unknownCoverageCorrection(contract, completion, covered, unknown); correction != "" {
		return correction
	}
	if completion.Status != "decision_ready" {
		return blockedCompletionCorrection(completion)
	}
	if episode.Effort == core.EffortOperationalAssessment {
		if !validOperationalHealthVerdict(completion.Verdict) {
			return "an operational assessment must set completion.verdict to healthy, degraded, or unhealthy; unknown is not an operational verdict"
		}
		if correction := operationalHealthVerdictCorrection(completion.Verdict, covered, unknown); correction != "" {
			return correction
		}
	}
	if contract.Completion.ConclusionKind == "change_review" {
		return changeReviewVerdictCorrection(completion, covered)
	}
	return ""
}

// unknownCoverageCorrection rejects a decision-ready claim made while material
// coverage is still unknown.
//
// The exceptions are narrow and deliberate. An operational health call can be
// made with gaps — "degraded, and here is what I could not see" is a useful
// answer. A change review can too, but only when its verdict already says the
// outcome is not final, or when it is a terminal failure with a stated next
// action: knowing a deploy failed is worth reporting even if the blast radius
// is not fully mapped.

// unknownCoverageCorrection rejects a decision-ready claim made while material
// coverage is still unknown.
//
// The exceptions are narrow and deliberate. An operational health call can be
// made with gaps — "degraded, and here is what I could not see" is a useful
// answer. A change review can too, but only when its verdict already says the
// outcome is not final, or when it is a terminal failure with a stated next
// action: knowing a deploy failed is worth reporting even if the blast radius
// is not fully mapped.
func unknownCoverageCorrection(
	contract InvestigationContract,
	completion *CompletionAssessment,
	covered map[string]core.Coverage,
	unknown []string,
) string {
	if completion.Status != "decision_ready" ||
		(len(completion.MaterialGaps) == 0 && len(unknown) == 0) {
		return ""
	}
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
	return ""
}

// changeReviewVerdictCorrection keeps a change verdict honest against the
// terminal evidence. A change that is still running cannot be called succeeded
// or failed, and one that finished cannot be called in progress.

// changeReviewVerdictCorrection keeps a change verdict honest against the
// terminal evidence. A change that is still running cannot be called succeeded
// or failed, and one that finished cannot be called in progress.
func changeReviewVerdictCorrection(
	completion *CompletionAssessment,
	covered map[string]core.Coverage,
) string {
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
	return ""
}

// episodeCoverageState indexes what was actually assessed and reports the
// layers that came back unknown. A layer declared unknown without saying why is
// a correction on its own: "unknown" with no explanation is indistinguishable
// from not having looked.

// episodeCoverageState indexes what was actually assessed and reports the
// layers that came back unknown. A layer declared unknown without saying why is
// a correction on its own: "unknown" with no explanation is indistinguishable
// from not having looked.
func episodeCoverageState(
	episode core.WorkEpisode,
	coverage []core.Coverage,
) (map[string]core.Coverage, []string, string) {
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
				return nil, nil, fmt.Sprintf("coverage layer %s is unknown without explaining the evidence gap", layer)
			}
			unknown = append(unknown, layer)
		}
	}
	if len(missing) > 0 {
		return nil, nil, "the deep work episode has not assessed required coverage layers: " +
			strings.Join(missing, ", ")
	}
	return covered, unknown, ""
}

// blockedCompletionCorrection rejects a block an operator could not act on. A
// block is only useful if it names the gap, what was already tried, and what
// would move it forward.

// blockedCompletionCorrection rejects a block an operator could not act on. A
// block is only useful if it names the gap, what was already tried, and what
// would move it forward.
func blockedCompletionCorrection(completion *CompletionAssessment) string {
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
	return ""
}

func ConclusionLanguageCorrection(
	episode core.WorkEpisode,
	action string,
	message string,
) string {
	if action != "reply" || Compile(episode).Completion.ConclusionKind == "operational_health" {
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

func ClaimCorrection(
	episode core.WorkEpisode,
	action string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	completion *CompletionAssessment,
	now time.Time,
	strict bool,
) string {
	if action != "reply" || completion == nil || completion.Status == "blocked" {
		return ""
	}
	contract := Compile(episode)
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
	ledger := BuildLedger(contract, evidence, coverage, now.UTC())
	return ledger.CompletionCorrectionFor(completion.Status, completion.Verdict)
}

func claimRequired(contract InvestigationContract, claimID string) bool {
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
