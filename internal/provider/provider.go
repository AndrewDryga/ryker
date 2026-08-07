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
			Kind:        "usage_limit",
			Summary:     "The configured AI provider account has no usable quota or spending capacity.",
			OperatorFix: "Confirm provider usage and billing for the account used by Coop, then retry.",
		}
	case containsAny(lower, "rate limit", "too many requests", "429"):
		return Failure{
			Kind:        "rate_limit",
			Summary:     "The configured AI provider temporarily rate-limited this request.",
			OperatorFix: "Wait for the provider limit window to recover, or reduce concurrent work, then retry.",
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
