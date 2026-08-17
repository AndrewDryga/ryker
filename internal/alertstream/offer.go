package alertstream

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// Whether two engineering offers are the same offer.
//
// A4 compared them by repository alone, which is right inside one alert stream:
// a stream investigates one situation, so a second offer in the same repository
// is the same fix reworded. Across a channel it is not. The same repository
// holds unrelated work — on 2026-08-16 tenant-infra was offered a Traefik cap
// raise, a BunnyCDN TLS staging and a Zot registry fix in the same week — and
// suppressing the second of those would lose the work rather than save a click.
//
// So a channel-wide match needs the titles to agree as well, and titles are
// prose: the sixth Traefik offer of that day said "Increase VA1 Traefik memory
// headroom" where the stream had said "Traefik: raise VA1 ingress memory cap and
// add oversubscription headroom". Same fix, one word in three shared.

// SameFixOffered reports whether two engineering-task titles name the same fix.
//
// Two rules, and the second exists because the first is not enough. Jaccard over
// the significant words is the honest measure of "these say the same thing", but
// the two real titles above score 3/7 = 0.43 against a 0.5 threshold: the longer
// title carries four words of detail the shorter one leaves out, and Jaccard
// charges the pair for every one of them. The second rule is containment — the
// shorter title's significant words nearly all appear in the longer one — which
// is the shape "the same fix, described at more length" actually takes.
//
// Containment is floored at three shared words rather than a bare ratio because
// this decides whether an operator is offered a control at all. A false match
// silently withholds work; a false miss costs a duplicate button. "Raise the
// Traefik memory limit" and "Reduce Traefik memory fragmentation" share two
// words and are different fixes, and both rules refuse them.
func SameFixOffered(one, other string) bool {
	left, right := normalizedTitle(one), normalizedTitle(other)
	if left == "" || right == "" {
		return false
	}
	if left == right {
		return true
	}
	first, second := significantWords(left), significantWords(right)
	shared := 0
	for word := range first {
		if second[word] {
			shared++
		}
	}
	if shared == 0 {
		return false
	}
	union := len(first) + len(second) - shared
	if union > 0 && float64(shared) >= 0.5*float64(union) {
		return true
	}
	return shared >= 3 && float64(shared) >= 0.6*float64(min(len(first), len(second)))
}

// SameFixCandidates narrows answers posted elsewhere in this channel to the ones
// that put a button on this same fix in this same repository.
//
// Whether those offers are still open remains a question for the store, exactly
// as it is for OpenOfferCandidates: an accepted task and an undelivered reply
// both close one, and neither is visible from the reply record alone.
func SameFixCandidates(
	replies []ReplyPosted,
	repository string,
	title string,
	excludeSourceInputID string,
) []ReplyPosted {
	var candidates []ReplyPosted
	for _, reply := range OpenOfferCandidates(replies, repository, excludeSourceInputID) {
		if SameFixOffered(reply.OfferTitle, title) {
			candidates = append(candidates, reply)
		}
	}
	return candidates
}

// normalizedTitle lower-cases a title and reduces everything that is not a
// letter or a digit to a space, so "Traefik:" and "traefik" are one word and
// "reload-driven" is two.
func normalizedTitle(title string) string {
	folded := strings.Map(func(char rune) rune {
		if unicode.IsLetter(char) || unicode.IsDigit(char) {
			return unicode.ToLower(char)
		}
		return ' '
	}, title)
	return strings.Join(strings.Fields(folded), " ")
}

// significantWords is the set of words worth comparing: four runes or more.
//
// The threshold drops the joins and prepositions two unrelated titles always
// share — and, the, for, with — without a stoplist that would have to be
// maintained against real wording. It also drops the identifiers that make two
// different fixes look alike: "VA1" and "OOM" appear in both of that day's
// Traefik tasks and tell you nothing about which fix either one is.
func significantWords(normalized string) map[string]bool {
	words := make(map[string]bool, 8)
	for _, word := range strings.Fields(normalized) {
		if utf8.RuneCountInString(word) >= 4 {
			words[word] = true
		}
	}
	return words
}
