// Package provider turns a model provider's failure text into something an
// operator can act on.
//
// The provider reports its own vocabulary — quota, rate limit, transcript
// bound — and an operator needs to know which of those they can fix and how.
// Keeping the translation here means the wording is reviewed as product copy
// rather than buried in the run lifecycle.
package provider

import (
	"strings"
)

// Kinds a caller may need to branch on. Named rather than compared as strings
// at the call site, so a rename here cannot leave a stale comparison behind.
const (
	// KindRateLimit: the provider is throttling. Transient by definition, and
	// distinct from KindUsageLimit, which is a quota that will not recover on
	// its own.
	KindRateLimit = "rate_limit"
	// KindUsageLimit: the account has no usable quota. It recovers on a billing
	// boundary rather than in a burst window, so it waits longer.
	KindUsageLimit = "usage_limit"
	// KindProviderRefused: the agent protocol refused the request and did not
	// say why.
	//
	// Responder sees only "ACP request was rejected"; the reason lives in
	// Coop's session log, two layers down. On 2026-08-07 that reason was a
	// spent quota with a reset date four days out, and every refusal in between
	// surfaced in Slack as "Responder could not complete this check" for work
	// that was fine.
	//
	// Treated as a wait rather than a failure because every cause of it is one:
	// a quota, a rate limit, or a credential that needs attention. None is
	// improved by telling the person who asked, and the first two clear on
	// their own. It stays visible in last_error, the logs and the metrics.
	KindProviderRefused = "provider_refused"
)

type Failure struct {
	Kind        string
	Summary     string
	OperatorFix string
}

func Classify(detail string) Failure {
	lower := strings.ToLower(detail)
	switch {
	case containsAny(lower, "acp transcript exceeded its bound"):
		return Failure{
			Kind:        "transcript_limit",
			Summary:     "The investigation repeatedly produced more tool output than Coop can transport, even after Responder restarted it with narrower-query guidance.",
			OperatorFix: "Retry with a narrower scope, or add a server-side aggregate or paginated evidence route for this check.",
		}
	case containsAny(lower, "usage limit", "quota", "insufficient_quota", "credit balance"):
		return Failure{
			Kind:        KindUsageLimit,
			Summary:     "The configured AI provider account has no usable quota or spending capacity.",
			OperatorFix: "Confirm provider usage and billing for the account used by Coop, then retry.",
		}
	case containsAny(lower, "rate limit", "too many requests", "429"):
		return Failure{
			Kind:        KindRateLimit,
			Summary:     "The configured AI provider temporarily rate-limited this request.",
			OperatorFix: "Wait for the provider limit window to recover, or reduce concurrent work, then retry.",
		}
	case containsAny(lower, "acp request was rejected"):
		return Failure{
			Kind: KindProviderRefused,
			Summary: "The AI provider refused the request without giving a reason. " +
				"Coop's session log for the turn has it.",
			OperatorFix: "Check the provider's quota and credentials; the work stays queued meanwhile.",
		}
	case containsAny(
		lower,
		"acl request was rejected",
		"credential needs sign-in",
		"credential is not portable",
		"provider credential needs sign-in or renewal",
		"permission denied",
		"forbidden",
		"unauthorized",
		"invalid api key",
		"authentication",
	):
		return Failure{
			Kind:        "authorization",
			Summary:     "Emisar's AI provider login needs to be refreshed.",
			OperatorFix: "Sign in to the configured Coop agent profile, then retry this request.",
		}
	case containsAny(lower, "model", "unsupported", "does not exist", "not found"):
		return Failure{
			Kind:        "model",
			Summary:     "The configured model is unavailable to the current provider account.",
			OperatorFix: "Choose a model available to that account, restart Responder so managed Coop reloads it, then retry.",
		}
	default:
		return Failure{
			Kind:        "agent",
			Summary:     "Coop ended the agent turn before it produced a usable response.",
			OperatorFix: "Check the Coop service and agent logs, correct the reported error, then retry.",
		}
	}
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}
