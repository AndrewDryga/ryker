package service

import (
	"net/url"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
)

const maxKnowledgeItems = 24

var memorySearchStopWords = map[string]struct{}{
	"about": {}, "after": {}, "again": {}, "also": {}, "been": {}, "before": {},
	"being": {}, "could": {}, "does": {}, "from": {}, "have": {}, "into": {},
	"just": {}, "make": {}, "more": {}, "need": {}, "only": {}, "other": {},
	"please": {}, "should": {}, "some": {}, "that": {}, "their": {}, "there": {},
	"these": {}, "they": {}, "this": {}, "those": {}, "through": {}, "what": {},
	"when": {}, "where": {}, "which": {}, "with": {}, "would": {}, "your": {},
	"check": {}, "review": {}, "service": {}, "system": {}, "production": {},
}

func sanitizeKnowledge(items []core.KnowledgeItem) []core.KnowledgeItem {
	result := make([]core.KnowledgeItem, 0, min(len(items), maxKnowledgeItems))
	indexes := make(map[string]int, len(items))
	for _, item := range items {
		item.Subject = boundedField(item.Subject, 160)
		item.Statement = boundedField(item.Statement, 600)
		item.SourceRef = boundedField(item.SourceRef, 500)
		item.SourceMessageTS = boundedField(item.SourceMessageTS, 32)
		switch item.Kind {
		case "decision", "constraint", "fact", "rationale":
		default:
			continue
		}
		switch item.Status {
		case "tentative", "accepted", "superseded":
		default:
			continue
		}
		if item.Confidence < 1 || item.Confidence > 3 || item.Subject == "" ||
			item.Statement == "" || item.SourceMessageTS == "" ||
			!validKnowledgeSourceRef(item.SourceRef) {
			continue
		}
		key := strings.ToLower(item.Kind + "\x00" + item.Subject)
		if index, ok := indexes[key]; ok {
			if knowledgeItemNewer(item, result[index]) {
				result[index] = item
			}
			continue
		}
		indexes[key] = len(result)
		result = append(result, item)
	}
	if len(result) > maxKnowledgeItems {
		result = result[:maxKnowledgeItems]
	}
	return result
}

func validKnowledgeSourceRef(value string) bool {
	if strings.HasPrefix(value, "slack:") {
		return strings.TrimSpace(strings.TrimPrefix(value, "slack:")) != ""
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	return host == "slack.com" || strings.HasSuffix(host, ".slack.com")
}

func knowledgeItemNewer(candidate, current core.KnowledgeItem) bool {
	if candidate.SourceMessageTS != current.SourceMessageTS {
		candidateTS, candidateErr := strconv.ParseFloat(candidate.SourceMessageTS, 64)
		currentTS, currentErr := strconv.ParseFloat(current.SourceMessageTS, 64)
		if candidateErr == nil && currentErr == nil {
			return candidateTS > currentTS
		}
		return candidate.SourceMessageTS > current.SourceMessageTS
	}
	if candidate.Confidence != current.Confidence {
		return candidate.Confidence > current.Confidence
	}
	return candidate.Status == "accepted" && current.Status != "accepted"
}

func memoryQueryText(input *core.SlackInput) string {
	if input == nil {
		return ""
	}
	parts := []string{input.Text}
	for _, attachment := range input.Attachments {
		parts = append(parts, attachment.Name)
	}
	return strings.Join(parts, " ")
}

func selectRelevantConversationMemories(
	items []core.ConversationMemory,
	query string,
	limit int,
) []core.ConversationMemory {
	type ranked struct {
		item  core.ConversationMemory
		score int
	}
	rankedItems := make([]ranked, 0, len(items))
	for _, item := range items {
		if score := agentMemoryRelevance(item.State, query); score > 0 {
			rankedItems = append(rankedItems, ranked{item: item, score: score})
		}
	}
	sort.SliceStable(rankedItems, func(i, j int) bool {
		if rankedItems[i].score != rankedItems[j].score {
			return rankedItems[i].score > rankedItems[j].score
		}
		return rankedItems[i].item.UpdatedAt.After(rankedItems[j].item.UpdatedAt)
	})
	result := make([]core.ConversationMemory, 0, min(limit, len(rankedItems)))
	for _, item := range rankedItems[:min(limit, len(rankedItems))] {
		result = append(result, item.item)
	}
	return result
}

func selectRelevantMemoryRollups(
	items []core.MemoryRollup,
	query string,
	limit int,
) []core.MemoryRollup {
	type ranked struct {
		item  core.MemoryRollup
		score int
	}
	rankedItems := make([]ranked, 0, len(items))
	for _, item := range items {
		if score := agentMemoryRelevance(item.State, query); score > 0 {
			rankedItems = append(rankedItems, ranked{item: item, score: score})
		}
	}
	sort.SliceStable(rankedItems, func(i, j int) bool {
		if rankedItems[i].score != rankedItems[j].score {
			return rankedItems[i].score > rankedItems[j].score
		}
		return rankedItems[i].item.PeriodEnd.After(rankedItems[j].item.PeriodEnd)
	})
	result := make([]core.MemoryRollup, 0, min(limit, len(rankedItems)))
	for _, item := range rankedItems[:min(limit, len(rankedItems))] {
		result = append(result, item.item)
	}
	return result
}

func agentMemoryRelevance(memory core.AgentMemory, query string) int {
	queryTerms := memorySearchTerms(query)
	if len(queryTerms) == 0 {
		return 0
	}
	score := memoryTextScore(queryTerms, strings.Join([]string{
		memory.Goal,
		memory.ChannelPurpose,
		memory.SituationSummary,
		strings.Join(memory.ActiveTopics, " "),
		strings.Join(memory.OpenLoops, " "),
		strings.Join(memory.Topology, " "),
		strings.Join(memory.Decisions, " "),
		strings.Join(memory.UnresolvedQuestions, " "),
	}, " "))
	for _, item := range memory.Knowledge {
		weight := 2
		if item.Status == "accepted" && item.Confidence == 3 {
			weight = 4
		}
		score += weight * memoryTextScore(
			queryTerms,
			item.Subject+" "+item.Statement,
		)
	}
	return score
}

func memoryTextScore(queryTerms map[string]struct{}, value string) int {
	score := 0
	for term := range memorySearchTerms(value) {
		if _, ok := queryTerms[term]; ok {
			score++
		}
	}
	return score
}

func memorySearchTerms(value string) map[string]struct{} {
	terms := make(map[string]struct{})
	for _, term := range strings.FieldsFunc(strings.ToLower(value), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if len(term) < 3 {
			continue
		}
		if _, ignored := memorySearchStopWords[term]; ignored {
			continue
		}
		terms[term] = struct{}{}
	}
	return terms
}
