// Package memory owns what Responder is allowed to remember, for how long, and
// who may see it.
//
// The visibility rule is the reason this is a package rather than a file. A
// memory learned in a private conversation must never surface in a public one,
// and that check is easy to get subtly wrong in a way no ordinary test notices
// — it fails open, and failing open here means telling a channel something it
// was not meant to hear. Isolating it makes it testable on its own.
package memory

import (
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/recall"
	"github.com/AndrewDryga/responder/internal/store"
)

// boundedStrings bounds a list and each of its entries.
func boundedStrings(values []string, limit int, fieldLimit int) []string {
	result := make([]string, 0, min(len(values), limit))
	for _, value := range values[:min(len(values), limit)] {
		if value = decision.BoundedField(value, fieldLimit); value != "" {
			result = append(result, value)
		}
	}
	return result
}

// TTL bounds. A memory with no expiry is a memory nobody revisits, and one that
// never expires eventually describes a system that no longer exists.
const (
	DefaultTTL = 30 * 24 * time.Hour
	MaxTTL     = 365 * 24 * time.Hour
)

func MemoryEntryIDs(entries []core.MemoryEntry) []string {
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		result = append(result, entry.ID)
	}
	return result
}

func MemoryRollupIDs(entries []core.MemoryRollup) []string {
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		result = append(result, entry.ID)
	}
	return result
}

func MemoryEntryVisibleForAction(
	entry core.MemoryEntry,
	input core.SlackInput,
	workspaceID string,
) bool {
	switch entry.VisibilityKind {
	case "workspace":
		return entry.VisibilityID == workspaceID && input.TeamID == workspaceID
	case "channel":
		return input.ChannelID != "" && entry.VisibilityID == input.ChannelID
	case "operator":
		return entry.VisibilityID == input.UserID
	default:
		return false
	}
}

func NormalizeGuidanceSubject(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	var result strings.Builder
	result.Grow(min(len(value), 120))
	separator := false
	for _, char := range value {
		switch {
		case char >= 'a' && char <= 'z', char >= '0' && char <= '9':
			if separator && result.Len() > 0 && result.Len() < 120 {
				result.WriteByte('_')
			}
			separator = false
			if result.Len() < 120 {
				result.WriteRune(char)
			}
		case char == '.', char == '_', char == '/', char == ':', char == '-':
			if result.Len() > 0 && result.Len() < 120 {
				result.WriteRune(char)
			}
			separator = false
		default:
			separator = result.Len() > 0
		}
	}
	return strings.TrimRight(result.String(), "._/:-")
}

func ParseMemoryTTL(value string) (time.Duration, error) {
	value = strings.TrimSpace(strings.ToLower(value))
	if value == "" {
		return DefaultTTL, nil
	}
	if strings.HasSuffix(value, "d") {
		daysText := strings.TrimSuffix(value, "d")
		switch daysText {
		case "7":
			return 7 * 24 * time.Hour, nil
		case "30":
			return 30 * 24 * time.Hour, nil
		case "90":
			return 90 * 24 * time.Hour, nil
		case "365":
			return MaxTTL, nil
		}
	}
	return 0, errors.New("expires_in must be 7d, 30d, 90d, or 365d")
}

func MemoryScopeLabel(offer core.MemoryOffer) string {
	if offer.Scope == "repository" {
		return "repository " + offer.Repository
	}
	return offer.Scope
}

func FormatMemoryTTL(ttl time.Duration) string {
	return fmt.Sprintf("%d days", int(ttl/(24*time.Hour)))
}

func MemoryTTLValue(ttl time.Duration) string {
	return fmt.Sprintf("%dd", int(ttl/(24*time.Hour)))
}

func ContainsSecretLikeValue(value string) bool {
	lower := strings.ToLower(value)
	for _, marker := range []string{"xoxb-", "xapp-", "emk-", "ghp_", "akia"} {
		if strings.Contains(lower, marker) {
			return true
		}
	}
	return false
}

type MemoryRollupGroup struct {
	ScopeKind  string
	ScopeKey   string
	Repository string
	Period     time.Time
	Sources    []core.ConversationMemory
}

func GroupMemoryRollups(candidates []store.ConversationMemoryCandidate) []MemoryRollupGroup {
	groups := map[string]*MemoryRollupGroup{}
	order := make([]string, 0)
	for _, candidate := range candidates {
		memory := candidate.Memory
		period := StartOfUTCWeek(memory.UpdatedAt)
		scopeKind := "repository"
		scopeKey := memory.Repository
		if candidate.Private {
			scopeKind = "channel"
			scopeKey = memory.ChannelID
		}
		key := strings.Join([]string{
			scopeKind, scopeKey, period.Format(time.RFC3339),
		}, "\x00")
		group := groups[key]
		if group == nil {
			group = &MemoryRollupGroup{
				ScopeKind: scopeKind, ScopeKey: scopeKey,
				Repository: memory.Repository, Period: period,
			}
			groups[key] = group
			order = append(order, key)
		}
		group.Sources = append(group.Sources, memory)
	}
	result := make([]MemoryRollupGroup, 0, len(groups))
	for _, key := range order {
		result = append(result, *groups[key])
	}
	return result
}

func MergeAgentMemories(states []core.AgentMemory) core.AgentMemory {
	var result core.AgentMemory
	for _, state := range states {
		state = SanitizeMemory(state)
		if result.Goal == "" {
			result.Goal = state.Goal
		}
		if result.ChannelPurpose == "" {
			result.ChannelPurpose = state.ChannelPurpose
		}
		if result.SituationSummary == "" {
			result.SituationSummary = state.SituationSummary
		}
		result.ActiveTopics = append(result.ActiveTopics, state.ActiveTopics...)
		result.OpenLoops = append(result.OpenLoops, state.OpenLoops...)
		result.Topology = append(result.Topology, state.Topology...)
		result.Decisions = append(result.Decisions, state.Decisions...)
		result.UnresolvedQuestions = append(
			result.UnresolvedQuestions, state.UnresolvedQuestions...,
		)
		result.EvidenceRefs = append(result.EvidenceRefs, state.EvidenceRefs...)
		result.Knowledge = append(result.Knowledge, state.Knowledge...)
	}
	result.ActiveTopics = BoundedUnique(result.ActiveTopics, 12, 240)
	result.OpenLoops = BoundedUnique(result.OpenLoops, 20, 400)
	result.Topology = BoundedUnique(result.Topology, 30, 400)
	result.Decisions = BoundedUnique(result.Decisions, 30, 400)
	result.UnresolvedQuestions = BoundedUnique(result.UnresolvedQuestions, 30, 400)
	result.EvidenceRefs = BoundedUnique(result.EvidenceRefs, 50, 120)
	result.Knowledge = recall.SanitizeKnowledge(result.Knowledge)
	return SanitizeMemory(result)
}

func BoundedUnique(values []string, limit int, maxBytes int) []string {
	seen := make(map[string]int, len(values))
	result := make([]string, 0, min(len(values), limit))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		value = core.TruncateUTF8(value, maxBytes)
		key := DedupeKey(value)
		if index, ok := seen[key]; ok {
			// Same fact, different phrasing. Keep the longer one: it is the
			// more specific statement, and a rollup's whole value is that the
			// detail survives consolidation.
			if len(value) > len(result[index]) {
				result[index] = value
			}
			continue
		}
		if len(result) == limit {
			continue
		}
		seen[key] = len(result)
		result = append(result, value)
	}
	return result
}

// DedupeKey collapses the differences that make two statements of the same fact
// look distinct: case, spacing, trailing punctuation, and the filler words that
// carry no meaning on their own.
//
// Without it a rollup spends its bounded slots on restatements — "payments-api
// is degraded" and "payments-api degraded" both survive — and the longer a
// channel runs, the more of its memory is the same fact said several ways.

// DedupeKey collapses the differences that make two statements of the same fact
// look distinct: case, spacing, trailing punctuation, and the filler words that
// carry no meaning on their own.
//
// Without it a rollup spends its bounded slots on restatements — "payments-api
// is degraded" and "payments-api degraded" both survive — and the longer a
// channel runs, the more of its memory is the same fact said several ways.
func DedupeKey(value string) string {
	terms := strings.FieldsFunc(strings.ToLower(value), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	kept := make([]string, 0, len(terms))
	for _, term := range terms {
		if _, filler := DedupeFillerWords[term]; filler {
			continue
		}
		kept = append(kept, term)
	}
	if len(kept) == 0 {
		return strings.ToLower(strings.TrimSpace(value))
	}
	return strings.Join(kept, " ")
}

// DedupeFillerWords are words whose presence or absence does not change which
// fact a line states.

// DedupeFillerWords are words whose presence or absence does not change which
// fact a line states.
var DedupeFillerWords = map[string]struct{}{
	"a": {}, "an": {}, "the": {}, "is": {}, "are": {}, "was": {}, "were": {},
	"be": {}, "been": {}, "being": {}, "to": {}, "of": {}, "in": {}, "on": {},
	"at": {}, "by": {}, "for": {}, "and": {}, "or": {}, "that": {}, "this": {},
	"it": {}, "its": {}, "has": {}, "have": {}, "had": {},
}

func StartOfUTCWeek(value time.Time) time.Time {
	value = value.UTC()
	day := time.Date(value.Year(), value.Month(), value.Day(), 0, 0, 0, 0, time.UTC)
	daysSinceMonday := (int(day.Weekday()) + 6) % 7
	return day.AddDate(0, 0, -daysSinceMonday)
}

func MaxTime(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

func SanitizeMemory(memory core.AgentMemory) core.AgentMemory {
	memory.Goal = decision.BoundedField(memory.Goal, 1000)
	memory.ChannelPurpose = decision.BoundedField(memory.ChannelPurpose, 500)
	memory.SituationSummary = decision.BoundedField(memory.SituationSummary, 1000)
	memory.ActiveTopics = boundedStrings(memory.ActiveTopics, 12, 240)
	memory.OpenLoops = boundedStrings(memory.OpenLoops, 20, 400)
	memory.Topology = boundedStrings(memory.Topology, 30, 400)
	memory.Decisions = boundedStrings(memory.Decisions, 30, 400)
	memory.UnresolvedQuestions = boundedStrings(memory.UnresolvedQuestions, 30, 400)
	memory.EvidenceRefs = boundedStrings(memory.EvidenceRefs, 50, 120)
	memory.Knowledge = recall.SanitizeKnowledge(memory.Knowledge)
	return memory
}
