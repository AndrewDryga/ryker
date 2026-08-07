// Package recall decides which remembered context reaches a prompt.
//
// The budget is small and the store is large, so something has to choose. That
// choice is the difference between an agent that gets better as it is taught
// and one that gets worse: ordering by recency alone means every new lesson
// pushes an older one out, however relevant the older one is to the question
// being asked. The scoring here is deliberately lexical and deterministic — no
// model call, no embedding service — so recall is cheap, replayable, and
// explainable when it picks the wrong thing.
package recall

import (
	"net/url"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
)

const (
	maxKnowledgeItems = 24
	// CandidateLimit is how many entries the store returns for ranking. The
	// store still orders by scope then recency, so this is the recency window
	// relevance gets to choose from rather than an unbounded scan.
	CandidateLimit = 100
	// ContextLimit is how many entries reach the prompt.
	ContextLimit = 10
	// guidanceFloor is how many guidance entries are always carried even when
	// they do not match the query. Guidance steers how the agent collaborates
	// rather than answering a question, so it is relevant to turns whose
	// wording never mentions it.
	guidanceFloor = 3
)

var stopWords = map[string]struct{}{
	"about": {}, "after": {}, "again": {}, "also": {}, "been": {}, "before": {},
	"being": {}, "could": {}, "does": {}, "from": {}, "have": {}, "into": {},
	"just": {}, "make": {}, "more": {}, "need": {}, "only": {}, "other": {},
	"please": {}, "should": {}, "some": {}, "that": {}, "their": {}, "there": {},
	"these": {}, "they": {}, "this": {}, "those": {}, "through": {}, "what": {},
	"when": {}, "where": {}, "which": {}, "with": {}, "would": {}, "your": {},
	"check": {}, "review": {}, "service": {}, "system": {}, "production": {},
}

func SanitizeKnowledge(items []core.KnowledgeItem) []core.KnowledgeItem {
	result := make([]core.KnowledgeItem, 0, min(len(items), maxKnowledgeItems))
	indexes := make(map[string]int, len(items))
	for _, item := range items {
		item.Subject = core.BoundedText(item.Subject, 160)
		item.Statement = core.BoundedText(item.Statement, 600)
		item.SourceRef = core.BoundedText(item.SourceRef, 500)
		item.SourceMessageTS = core.BoundedText(item.SourceMessageTS, 32)
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
			!validSourceRef(item.SourceRef) {
			continue
		}
		key := strings.ToLower(item.Kind + "\x00" + item.Subject)
		if index, ok := indexes[key]; ok {
			if itemNewer(item, result[index]) {
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

func validSourceRef(value string) bool {
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

func itemNewer(candidate, current core.KnowledgeItem) bool {
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

func QueryText(input *core.SlackInput) string {
	if input == nil {
		return ""
	}
	parts := []string{input.Text}
	for _, attachment := range input.Attachments {
		parts = append(parts, attachment.Name)
	}
	return strings.Join(parts, " ")
}

func SelectConversationMemories(
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
		if score := score(item.State, query); score > 0 {
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

func SelectMemoryRollups(
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
		if score := score(item.State, query); score > 0 {
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

func score(memory core.AgentMemory, query string) int {
	queryTerms := searchTerms(query)
	if len(queryTerms) == 0 {
		return 0
	}
	score := textScore(queryTerms, strings.Join([]string{
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
		score += weight * textScore(
			queryTerms,
			item.Subject+" "+item.Statement,
		)
	}
	return score
}

func textScore(queryTerms map[string]struct{}, value string) int {
	score := 0
	for term := range searchTerms(value) {
		if _, ok := queryTerms[term]; ok {
			score++
		}
	}
	return score
}

func searchTerms(value string) map[string]struct{} {
	terms := make(map[string]struct{})
	for _, term := range strings.FieldsFunc(strings.ToLower(value), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if len(term) < 3 {
			continue
		}
		if _, ignored := stopWords[term]; ignored {
			continue
		}
		terms[term] = struct{}{}
	}
	return terms
}

// canonicalPredicates name the predicates whose subject is an exact
// identifier rather than prose. When a turn names that identifier the entry is
// the answer, so an exact token match outranks anything recency would pick.
var canonicalPredicates = map[string]bool{
	"alias_of":                       true,
	"evidence_route":                 true,
	"entity_relationship_correction": true,
	"repository_for_channel":         true,
}

// SelectMemoryEntries chooses which confirmed memory reaches the prompt.
//
// Ordering by recency alone means the more an operator teaches the agent, the
// worse its recall gets: a mapping taught months ago loses its slot to whatever
// was touched most recently, however unrelated. Rank by overlap with the
// current request instead, keep an exact identifier match unconditionally, and
// spend what remains on recency so a fresh correction still surfaces.
func SelectMemoryEntries(
	candidates []core.MemoryEntry,
	query string,
	limit int,
) []core.MemoryEntry {
	if len(candidates) <= limit {
		return candidates
	}
	queryTerms := searchTerms(query)
	if len(queryTerms) == 0 {
		// A webhook-driven turn has no operator wording to match against;
		// recency is the only signal available and the store already applied it.
		return candidates[:limit]
	}
	type scored struct {
		entry core.MemoryEntry
		score int
		order int
	}
	ranked := make([]scored, 0, len(candidates))
	guidance := make([]core.MemoryEntry, 0, guidanceFloor)
	for index, entry := range candidates {
		if entry.Predicate == "guidance" && len(guidance) < guidanceFloor {
			guidance = append(guidance, entry)
			continue
		}
		score := textScore(queryTerms, entry.SubjectKey+" "+entry.Value)
		if canonicalPredicates[entry.Predicate] &&
			exactSubjectMatch(queryTerms, entry.SubjectKey) {
			score += 10
		}
		ranked = append(ranked, scored{entry: entry, score: score, order: index})
	}
	sort.SliceStable(ranked, func(i, j int) bool {
		if ranked[i].score != ranked[j].score {
			return ranked[i].score > ranked[j].score
		}
		return ranked[i].order < ranked[j].order
	})
	result := make([]core.MemoryEntry, 0, limit)
	result = append(result, guidance...)
	for _, item := range ranked {
		if len(result) >= limit {
			break
		}
		result = append(result, item.entry)
	}
	return result
}

// exactSubjectMatch reports whether the request names this subject
// outright, rather than merely sharing a word with it.
func exactSubjectMatch(queryTerms map[string]struct{}, subject string) bool {
	terms := searchTerms(subject)
	if len(terms) == 0 {
		return false
	}
	for term := range terms {
		if _, ok := queryTerms[term]; !ok {
			return false
		}
	}
	return true
}
