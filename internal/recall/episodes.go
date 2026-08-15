package recall

import (
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const (
	// SimilarEpisodeCandidates is how many finished episodes the store returns
	// for ranking, mirroring CandidateLimit: the store orders by scope then
	// recency, and relevance chooses inside that window.
	SimilarEpisodeCandidates = 100
	// SimilarEpisodeLimit is how many recalled episodes reach a prompt. Three,
	// because the section competes for budget with the live evidence that
	// actually proves current state, and a fourth analogue has never been what
	// a senior engineer needed.
	SimilarEpisodeLimit = 3
)

// Scoring weights. Structural signals outrank vocabulary on purpose: two
// episodes that share an alert group key are the same alert firing twice,
// which is a fact, while two that share the word "latency" may be a database
// and a CDN. Grafana's groupKey is its stable identity for an alert group per
// the README, so it is the strongest signal available without a model.
const (
	sameAlertGroupScore  = 12
	sharedServiceScore   = 6
	sharedServiceCap     = 12
	sameRepositoryScore  = 2
	verifiedOutcomeScore = 3
	// A recalled episode ages out gradually rather than at a cliff: a
	// six-month-old pool-exhaustion episode is still the right analogue, it is
	// just a weaker one than last week's.
	recencyPenaltyPeriod = 30 * 24 * time.Hour
	recencyPenaltyCap    = 6
)

// SymptomQuery is what a new, unfinished episode looks like to the scorer.
type SymptomQuery struct {
	// Text is the real trigger text, never the truncated objective.
	Text          string
	Services      []string
	AlertGroupKey string
	Repository    string
	Now           time.Time
}

// SimilarEpisodeMatch is one recalled outcome and the host's reason for it.
type SimilarEpisodeMatch struct {
	Outcome   core.EpisodeOutcome
	Score     int
	MatchedOn []string
}

// SymptomFingerprint reduces free text to the token set an outcome is stored
// and scored by.
//
// It is the same stopword list and three-character rule the rest of this
// package ranks memory with, called from both the write side and the read side
// so a projection written today can never drift out of scoring range of a
// query built tomorrow. Sorted because a fingerprint is compared as text and
// an unordered one would compare unequal to itself.
func SymptomFingerprint(parts ...string) string {
	terms := searchTerms(strings.Join(parts, " "))
	tokens := make([]string, 0, len(terms))
	for term := range terms {
		tokens = append(tokens, term)
	}
	sort.Strings(tokens)
	return strings.Join(tokens, " ")
}

// SelectSimilarEpisodes ranks finished episodes against the symptom in front
// of the model right now.
//
// Deliberately lexical and deterministic, for the reason stated at the top of
// this package and one more: a recalled episode is shown to an operator on the
// trace page as the host's justification for spending prompt budget, and
// "these words overlapped and it was the same alert group" is a justification.
// An embedding distance is not.
func SelectSimilarEpisodes(
	candidates []core.EpisodeOutcome,
	query SymptomQuery,
	limit int,
) []SimilarEpisodeMatch {
	if limit < 1 {
		return nil
	}
	queryTerms := searchTerms(query.Text)
	services := lowerSet(query.Services)
	repository := strings.ToLower(strings.TrimSpace(query.Repository))
	groupKey := strings.TrimSpace(query.AlertGroupKey)
	ranked := make([]SimilarEpisodeMatch, 0, len(candidates))
	for _, candidate := range candidates {
		match := scoreEpisode(candidate, queryTerms, services, repository, groupKey, query.Now)
		if match.Score > 0 {
			ranked = append(ranked, match)
		}
	}
	sort.SliceStable(ranked, func(i, j int) bool {
		if ranked[i].Score != ranked[j].Score {
			return ranked[i].Score > ranked[j].Score
		}
		if !ranked[i].Outcome.TerminalAt.Equal(ranked[j].Outcome.TerminalAt) {
			return ranked[i].Outcome.TerminalAt.After(ranked[j].Outcome.TerminalAt)
		}
		return ranked[i].Outcome.EpisodeID < ranked[j].Outcome.EpisodeID
	})
	return ranked[:min(limit, len(ranked))]
}

// scoreEpisode returns a zero score for anything that qualified on structure
// alone.
//
// The bonuses would otherwise decide the section by themselves: every episode
// in a one-repository deployment shares the repository, and a verified fix
// bonus applied to an unrelated episode recommends last month's remediation
// for this month's outage. So a candidate has to earn its place on the symptom
// — the same alert group, a service in common, or real vocabulary overlap —
// and the bonuses only reorder what already qualified.
func scoreEpisode(
	candidate core.EpisodeOutcome,
	queryTerms map[string]struct{},
	services map[string]struct{},
	repository string,
	groupKey string,
	now time.Time,
) SimilarEpisodeMatch {
	match := SimilarEpisodeMatch{Outcome: candidate}
	overlap := textScore(queryTerms, candidate.SymptomFingerprint)
	shared := 0
	for _, service := range candidate.Services {
		if _, ok := services[strings.ToLower(strings.TrimSpace(service))]; ok {
			shared++
		}
	}
	sameGroup := groupKey != "" && candidate.AlertGroupKey == groupKey
	if !sameGroup && shared == 0 && overlap < 2 {
		return SimilarEpisodeMatch{Outcome: candidate}
	}
	if sameGroup {
		match.Score += sameAlertGroupScore
		match.MatchedOn = append(match.MatchedOn, "same alert group key")
	}
	if shared > 0 {
		match.Score += min(shared*sharedServiceScore, sharedServiceCap)
		match.MatchedOn = append(match.MatchedOn, "same implicated service")
	}
	if overlap > 0 {
		match.Score += overlap
		match.MatchedOn = append(match.MatchedOn, "overlapping symptom wording")
	}
	if repository != "" && strings.ToLower(candidate.Repository) == repository {
		match.Score += sameRepositoryScore
		match.MatchedOn = append(match.MatchedOn, "same repository")
	}
	if candidate.Verified {
		match.Score += verifiedOutcomeScore
		match.MatchedOn = append(match.MatchedOn, "remediation was verified")
	}
	match.Score -= recencyPenalty(candidate.TerminalAt, now)
	if match.Score < 1 {
		match.Score = 1
	}
	return match
}

// PromptEntries renders recalled outcomes for a prompt, bounded and carrying
// the host's reason for each one.
//
// The reason travels with the entry rather than being implied by its presence.
// A recalled episode with no stated basis is an assertion the model has no way
// to discount, and the one it most needs to discount is the match that rests
// on nothing but shared vocabulary. The symptom source rides along for the
// same reason: a fingerprint built from a truncated objective is a weaker
// claim than one built from what the operator wrote, and only the row knows.
func PromptEntries(matches []SimilarEpisodeMatch) []core.SimilarEpisode {
	entries := make([]core.SimilarEpisode, 0, len(matches))
	for _, match := range matches {
		outcome := match.Outcome
		entry := core.SimilarEpisode{
			EpisodeID: outcome.EpisodeID, TerminalState: outcome.TerminalState,
			MatchedOn: match.MatchedOn, Symptom: core.BoundedText(outcome.Objective, 240),
			SymptomSource: outcome.FingerprintSource, Services: outcome.Services,
			Repository:   outcome.Repository,
			RootCause:    core.BoundedText(outcome.RootCause, 400),
			Remediation:  core.BoundedText(outcome.Remediation, 400),
			Verification: core.BoundedText(outcome.Verification, 300),
			Verified:     outcome.Verified,
		}
		if !outcome.TerminalAt.IsZero() {
			entry.ResolvedAt = outcome.TerminalAt.UTC().Format(time.RFC3339)
		}
		if outcome.TimeToDecision >= time.Minute {
			entry.TimeToDecision = outcome.TimeToDecision.Round(time.Minute).String()
		}
		entries = append(entries, entry)
	}
	return entries
}

func recencyPenalty(terminalAt, now time.Time) int {
	if terminalAt.IsZero() || now.IsZero() || !now.After(terminalAt) {
		return 0
	}
	return min(int(now.Sub(terminalAt)/recencyPenaltyPeriod), recencyPenaltyCap)
}

func lowerSet(values []string) map[string]struct{} {
	result := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value = strings.ToLower(strings.TrimSpace(value)); value != "" {
			result[value] = struct{}{}
		}
	}
	return result
}
