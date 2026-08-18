package lifecycle

import (
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

var subjects = []string{
	"run", "deployment", "job", "workflow", "build", "release", "plan", "apply",
}

var pendingStates = []string{
	"created", "planning", "planned", "pending", "waiting", "queued", "running", "applying",
	"in progress", "needs confirmation", "cost estimating", "policy checking",
	"policy checked", "confirmed",
}

type Phase string

const (
	Unknown    Phase = "unknown"
	Created    Phase = "created"
	Planning   Phase = "planning"
	Reviewable Phase = "reviewable"
	Applying   Phase = "applying"
	Succeeded  Phase = "succeeded"
	Failed     Phase = "failed"
	Stopped    Phase = "stopped"
)

var (
	linkPattern   = regexp.MustCompile(`<((?:https?://)[^>|]+)(?:\|[^>]*)?>`)
	rawURLPattern = regexp.MustCompile(`https?://[^[:space:]<>|]+`)
	idPattern     = regexp.MustCompile(
		`(?i)(?:^|[|>[:space:]])(run|deployment|job|workflow|build|release|plan|apply)[[:space:]:]+([a-z0-9][a-z0-9._:/-]{2,})`,
	)
)

// CanonicalProviderURL returns a Terraform-owned link carried by the source
// event. The host uses this exact reference for approval-ready replies instead
// of trusting a model-authored message merely because it happens to contain a
// URL. Workspace links are context, not an approval target.
func CanonicalProviderURL(text string) string {
	expectedRun := ""
	if key := CorrelationKey(text); strings.HasPrefix(key, "run:") {
		expectedRun = strings.TrimPrefix(key, "run:")
	}
	candidates := make([]string, 0)
	for _, match := range linkPattern.FindAllStringSubmatch(text, -1) {
		if len(match) > 1 {
			candidates = append(candidates, match[1])
		}
	}
	candidates = append(candidates, rawURLPattern.FindAllString(text, -1)...)
	for _, candidate := range candidates {
		candidate = strings.TrimRight(strings.TrimSpace(candidate), ".,;)")
		parsed, err := url.Parse(candidate)
		if err != nil || parsed.Scheme != "https" || parsed.User != nil ||
			!strings.EqualFold(parsed.Host, "app.terraform.io") {
			continue
		}
		segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
		runID := ""
		for index := range segments {
			if strings.EqualFold(segments[index], "runs") && index+1 < len(segments) &&
				index+2 == len(segments) {
				runID = strings.ToLower(strings.TrimSpace(segments[index+1]))
				break
			}
		}
		if runID == "" || (expectedRun != "" && runID != expectedRun) {
			continue
		}
		parsed.RawQuery = ""
		parsed.ForceQuery = false
		parsed.Fragment = ""
		parsed.RawFragment = ""
		return parsed.String()
	}
	return ""
}

var genericIDs = map[string]struct{}{
	"notification": {}, "planning": {}, "planned": {}, "pending": {}, "waiting": {},
	"queued": {}, "running": {}, "applying": {}, "progress": {}, "confirmation": {},
	"confirmed": {}, "succeeded": {}, "successful": {}, "applied": {}, "errored": {},
	"error": {}, "failed": {}, "discarded": {}, "canceled": {}, "cancelled": {},
	"completed": {},
}

func ShouldReconcile(text string) bool {
	for _, line := range strings.Split(strings.ToLower(text), "\n") {
		line = normalizedStatusLine(line)
		if line == "" {
			continue
		}
		subject := false
		for _, candidate := range subjects {
			if strings.HasPrefix(line, candidate+" ") || strings.HasPrefix(line, candidate+":") {
				subject = true
				break
			}
		}
		if !subject && !strings.HasPrefix(line, "status:") && !strings.HasPrefix(line, "state:") {
			continue
		}
		for _, state := range pendingStates {
			if strings.Contains(line, state) {
				return true
			}
		}
	}
	return false
}

// Classify examines explicit lifecycle status lines only. Ordinary prose such
// as "the job is running slowly" must not enter deterministic lifecycle policy.
func Classify(text string) Phase {
	phase := Unknown
	for _, line := range strings.Split(strings.ToLower(text), "\n") {
		line = normalizedStatusLine(line)
		if line == "" || !statusLine(line) {
			continue
		}
		switch {
		case containsState(line, "errored", "failed", "failure", "apply failed", "run errored"):
			return Failed
		case containsState(line, "discarded", "cancelled", "canceled", "stopped"):
			return Stopped
		case containsState(line, "applied", "success", "succeeded", "successful", "completed", "finished"):
			phase = Succeeded
		case containsState(line, "applying", "apply in progress"):
			if phase != Succeeded {
				phase = Applying
			}
		case containsState(line, "planned", "needs confirmation", "needs approval"):
			if phase == Unknown || phase == Created || phase == Planning {
				phase = Reviewable
			}
		case containsState(line, "planning", "cost estimating", "policy checking", "policy checked"):
			if phase == Unknown || phase == Created {
				phase = Planning
			}
		case containsState(line, "created", "pending", "waiting", "queued", "running", "in progress"):
			if phase == Unknown {
				phase = Created
			}
		}
	}
	return phase
}

// normalizedStatusLine removes Slack's mrkdwn emphasis from explicit source
// field labels. GitHub Actions emits `*Status:* Success`; the asterisks are
// presentation, not part of the lifecycle vocabulary. Classification remains
// bounded to statusLine, so removing them cannot turn conversational prose
// into a lifecycle event.
func normalizedStatusLine(line string) string {
	return strings.TrimSpace(strings.ReplaceAll(line, "*", ""))
}

func statusLine(line string) bool {
	if strings.HasPrefix(line, "status:") || strings.HasPrefix(line, "state:") {
		return true
	}
	for _, subject := range subjects {
		if strings.HasPrefix(line, subject+" ") || strings.HasPrefix(line, subject+":") {
			return true
		}
	}
	return false
}

func containsState(line string, states ...string) bool {
	for _, state := range states {
		if line == state || strings.Contains(line, " "+state) ||
			strings.Contains(line, state+" ") || strings.Contains(line, state+" -") ||
			strings.Contains(line, state+":") {
			return true
		}
	}
	return false
}

func CorrelationKey(text string) string {
	for _, match := range idPattern.FindAllStringSubmatch(text, -1) {
		if len(match) < 3 {
			continue
		}
		identifier := strings.ToLower(strings.Trim(match[2], ".,;"))
		if _, generic := genericIDs[identifier]; generic {
			continue
		}
		return strings.ToLower(match[1]) + ":" + identifier
	}
	bestLink := ""
	for _, match := range linkPattern.FindAllStringSubmatch(text, -1) {
		if len(match) > 1 && len(match[1]) > len(bestLink) {
			bestLink = strings.TrimSpace(match[1])
		}
	}
	if bestLink != "" {
		return "link:" + bestLink
	}
	return ""
}

// CompletionEpisodePhase projects a finished turn onto its durable episode
// lifecycle. The caller has already persisted every accepted operation.
func CompletionEpisodePhase(
	completion *investigation.CompletionAssessment,
	pendingApproval bool,
	operations []investigation.ResultOperation,
	alertStreamWaitKind string,
) (core.WorkEpisodeState, string, string, string) {
	if pendingApproval {
		return core.EpisodeWaitingApproval, "waiting_for_approval",
			"Waiting for Emisar approval", "Continue automatically after the Emisar decision"
	}
	for _, operation := range operations {
		switch operation.Type {
		case "request_operator_input":
			return core.EpisodeWaitingOperator, "waiting_for_operator",
				"Waiting for your answer", operation.OperatorInput.Question
		case "wait_external":
			if operation.ExternalWait != nil && operation.ExternalWait.Kind == alertStreamWaitKind {
				return core.EpisodeWaitingExternal, "waiting_for_external_event",
					"Watching the alert stream", "Replies stay in this thread until the alert recovers"
			}
			return core.EpisodeWaitingExternal, "waiting_for_external_event",
				"Waiting for an external update", "Resume when the matching event arrives"
		}
	}
	if completion != nil && completion.Status == "blocked" {
		return core.EpisodeBlocked, "blocked", completion.Summary, completion.NextAction
	}
	return core.EpisodeCompleted, "finished", "Completed", ""
}

func HasTerraformRule(rules []core.StandingRule) bool {
	for _, rule := range rules {
		if (rule.Trigger == "terraform_plan" && rule.Action == "review_terraform_plan") ||
			(rule.Trigger == "terraform_lifecycle" && rule.Action == "monitor_terraform_lifecycle") {
			return true
		}
	}
	return false
}

func WaitsForKind(decision decisionpkg.WatchDecision, kind string) bool {
	return externalWait(decision, kind) != nil
}

func ReplyAddsFreshOperationalValue(decision decisionpkg.WatchDecision, now time.Time) bool {
	if decision.Action != "reply" ||
		!decisionpkg.HasFreshOperationalEvidence(
			decisionpkg.SanitizeEvidence(decision.Evidence, "", "", "", now), now,
		) {
		return false
	}
	// The change layer counts too, once something was actually observed.
	//
	// It used to be skipped unconditionally, on the reasoning that a lifecycle
	// event already says the change happened. True of a status paraphrase,
	// false of a verified rollout: a reply saying the requested revision is the
	// running one and answers an HTTP probe is a finding about the running
	// system that happens to be filed under change. Every such reply was
	// suppressed as redundant narration.
	for _, item := range decisionpkg.SanitizeCoverage(decision.Coverage, "", "", "", now) {
		layer := strings.ToLower(strings.TrimSpace(item.Layer))
		status := strings.ToLower(strings.TrimSpace(item.Status))
		if layer == "" {
			continue
		}
		// Bound to recorded claims, though. That is what separates the two, and
		// the layer name is not: both file under change, and both can cite
		// evidence typed monitoring, because the provider's own feed is
		// monitoring. The difference is whether the model tied its healthy
		// verdict to observations it recorded — bound to change.recent — or
		// asserted it from the notification it was reading.
		if layer == "change" && len(item.ClaimIDs) == 0 {
			continue
		}
		switch status {
		case "", "unknown", "unverified", "not_applicable":
			continue
		default:
			return true
		}
	}
	return false
}

type TerraformContinuationInput struct {
	InputKind string
	Text      string
	Rules     []core.StandingRule
	Decision  decisionpkg.WatchDecision
	Now       time.Time
}

// TerraformContinuationCorrection prevents a nonterminal Terraform episode
// from ending when there is nothing useful to post yet. The episode must keep
// one exact-run wakeup until HCP exposes a reviewable plan or terminal result.
func TerraformContinuationCorrection(input TerraformContinuationInput) string {
	if !HasTerraformRule(input.Rules) {
		return ""
	}
	phase := Classify(input.Text)
	if input.InputKind != "recheck" && phase != Created && phase != Planning &&
		phase != Reviewable && phase != Applying && phase != Succeeded && phase != Failed {
		return ""
	}
	decision := input.Decision
	if decision.Completion != nil {
		if decision.Completion.Status == "blocked" {
			return ""
		}
		switch decision.Completion.Verdict {
		case "needs_review":
			if CanonicalProviderURL(input.Text) == "" {
				return "the source Terraform event does not carry a canonical provider run URL for an approval-ready Slack review"
			}
			if !ReplyAddsFreshOperationalValue(decision, input.Now) {
				return "before asking for Terraform approval, record fresh affected-scope infrastructure or workload evidence and coverage so the operator can see whether production is safe before the change"
			}
		case "succeeded":
			if !ReplyAddsFreshOperationalValue(decision, input.Now) {
				return "before completing an applied Terraform run, record fresh affected-scope runtime, workload, dependency, or application evidence and coverage; otherwise return one exact blocker"
			}
			return ""
		case "failed", "inconclusive":
			return ""
		}
	}
	wait := externalWait(decision, "terraform_run")
	key := CorrelationKey(input.Text)
	if wait == nil {
		message := "this matched Terraform lifecycle is not terminal; use action=reply and emit a bounded wait_external operation with kind=terraform_run so the same episode checks the exact run again without posting another progress message"
		if strings.HasPrefix(key, "run:") {
			message += "; the event_matcher must name exact run ID " + strings.TrimPrefix(key, "run:")
		}
		return message
	}
	if len(wait.EventMatcher) == 0 {
		return "the Terraform wait_external operation must include an event_matcher for the exact run ID"
	}
	if strings.HasPrefix(key, "run:") {
		runID := strings.TrimPrefix(key, "run:")
		if !strings.Contains(strings.ToLower(string(wait.EventMatcher)), runID) {
			return "the Terraform wait_external event_matcher must name the exact run ID " + runID
		}
	}
	if wait.PollAfter == "" || wait.Deadline == "" {
		return "the Terraform wait_external operation must include both poll_after and deadline so it is durable and bounded"
	}
	return ""
}

func externalWait(
	decision decisionpkg.WatchDecision,
	kind string,
) *investigation.ExternalWaitOperation {
	for _, operation := range decision.AppliedOperations {
		if operation.Type == "wait_external" && operation.ExternalWait != nil &&
			operation.ExternalWait.Kind == kind {
			return operation.ExternalWait
		}
	}
	return nil
}
