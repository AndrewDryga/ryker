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
	"time"
)

// RateLimitRetryDelay is how long a rate-limited run waits before asking again.
//
// Fixed rather than the exponential backoff other retries use, because there is
// no attempt count to grow it from — a rate limit deliberately does not spend
// one. Five minutes is the ceiling that backoff reaches anyway, and it is long
// enough that repeated waits do not themselves become the load the provider was
// complaining about.
//
// There is no attempt limit on purpose. A rate limit recovers; a quota does
// not, and that is a different classification (KindUsageLimit) which still
// fails normally. Work waits here rather than being abandoned.
const RateLimitRetryDelay = 5 * time.Minute

// UsageLimitRetryDelay is how long a run waits when the provider's quota is
// spent.
//
// Much longer than a rate limit, because a quota recovers on a billing boundary
// rather than in a burst window — the observed message was "try again at Aug
// 11th", four days out. Checking every half hour costs nothing and notices the
// moment it clears; checking every five minutes would be pointless load on a
// provider that has already said no.
const UsageLimitRetryDelay = 30 * time.Minute

// LadderExhausted reports a Coop turn that failed because every rung of its
// session policy's target ladder was rate limited.
//
// Coop rotates across the ladder itself and only reports this once no rung is
// free, so it is every provider refusing at once rather than the run doing
// anything wrong. Like the refusals Classify names, it must not spend an
// attempt: a busy afternoon would otherwise exhaust the run and hand the
// operator an error for work that was fine.
func LadderExhausted(errorCode string) bool { return errorCode == "rate_limited" }

// LadderRetryDelay is how long to wait before asking an exhausted ladder again.
//
// Coop stamps the soonest rung reset into the detail, which beats guessing at
// it. The wait is still capped at the quota delay, so an operator who signs in
// another credential — or a provider that frees up early — is picked up without
// sitting out the original window. A detail carrying no parseable reset falls
// back to the standard wait rather than failing.
func LadderRetryDelay(detail string, now time.Time) time.Duration {
	const marker = "rate limited until "
	index := strings.LastIndex(detail, marker)
	if index < 0 {
		return RateLimitRetryDelay
	}
	reset, err := time.Parse(time.RFC3339, strings.TrimSpace(detail[index+len(marker):]))
	if err != nil {
		return RateLimitRetryDelay
	}
	if until := reset.Sub(now); until > RateLimitRetryDelay {
		return min(until, UsageLimitRetryDelay)
	}
	return RateLimitRetryDelay
}

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
	// After the specific causes, not before: Coop now carries the adapter's own
	// reason inside this string ("ACP request was rejected: <reason>"), and a
	// reason that names a quota, login, or model must classify as that. This
	// case is what remains — a refusal whose reason said nothing recognisable.
	case containsAny(lower, "acp request was rejected"):
		return Failure{
			Kind: KindProviderRefused,
			Summary: "The AI provider refused the request without a recognisable reason. " +
				"The turn's error detail carries the provider's own words.",
			OperatorFix: "Check the provider's quota and credentials; the work stays queued meanwhile.",
		}
	default:
		return Failure{
			Kind:        "agent",
			Summary:     "Coop ended the agent turn before it produced a usable response.",
			OperatorFix: "Check the Coop service and agent logs, correct the reported error, then retry.",
		}
	}
}

// Transient reports a provider failure that says nothing about the work: the request reached the
// model and the connection broke, so the same turn asked again will usually just succeed.
//
// These are the errors that must never reach Slack. A rate limit at least tells an operator
// something; "the response stalled mid-stream" tells them only that a socket died, and reporting
// it as a failed check trains people to ignore the channel. Retrying is bounded by the run's
// attempts, so a fault that is not actually transient still surfaces — just later, and once.
func Transient(detail string) bool {
	lower := strings.ToLower(detail)
	return containsAny(lower,
		"stalled mid-stream",
		"overloaded",
		"internal error",
		"internal server error",
		"bad gateway",
		"service unavailable",
		"connection reset",
		"connection closed",
		"unexpected eof",
		"stream error",
		"timeout",
	)
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}
