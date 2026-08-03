package service

import (
	"strings"
)

type providerFailure struct {
	Kind        string
	Summary     string
	OperatorFix string
}

func classifyProviderFailure(detail string) providerFailure {
	lower := strings.ToLower(detail)
	switch {
	case containsAny(lower, "acp transcript exceeded its bound"):
		return providerFailure{
			Kind:        "transcript_limit",
			Summary:     "The investigation repeatedly produced more tool output than Coop can transport, even after Responder restarted it with narrower-query guidance.",
			OperatorFix: "Retry with a narrower scope, or add a server-side aggregate or paginated evidence route for this check.",
		}
	case containsAny(lower, "usage limit", "quota", "insufficient_quota", "credit balance"):
		return providerFailure{
			Kind:        "usage_limit",
			Summary:     "The configured AI provider account has no usable quota or spending capacity.",
			OperatorFix: "Confirm provider usage and billing for the account used by Coop, then retry.",
		}
	case containsAny(lower, "rate limit", "too many requests", "429"):
		return providerFailure{
			Kind:        "rate_limit",
			Summary:     "The configured AI provider temporarily rate-limited this request.",
			OperatorFix: "Wait for the provider limit window to recover, or reduce concurrent work, then retry.",
		}
	case containsAny(
		lower,
		"acl request was rejected",
		"permission denied",
		"forbidden",
		"unauthorized",
		"invalid api key",
		"authentication",
	):
		return providerFailure{
			Kind:        "authorization",
			Summary:     "The configured AI provider rejected the account or its authorization.",
			OperatorFix: "Re-authenticate the Coop agent profile and confirm that account can use the configured model.",
		}
	case containsAny(lower, "model", "unsupported", "does not exist", "not found"):
		return providerFailure{
			Kind:        "model",
			Summary:     "The configured model is unavailable to the current provider account.",
			OperatorFix: "Choose a model available to that account, restart Responder so managed Coop reloads it, then retry.",
		}
	default:
		return providerFailure{
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
