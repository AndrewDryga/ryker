package recall

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Recall of past episodes is the one place where a scoring mistake does not
// look like a mistake: the model is handed a confident-sounding root cause for
// an incident that has nothing to do with the one in front of it, and every
// word of it is true about some other outage. These tests pin what may put an
// episode in front of the model at all, which matters more than the order.

func outcome(id string, options ...func(*core.EpisodeOutcome)) core.EpisodeOutcome {
	item := core.EpisodeOutcome{
		EpisodeID:          id,
		SymptomFingerprint: SymptomFingerprint("checkout latency alert p99 above threshold"),
		TerminalAt:         time.Date(2026, 8, 10, 0, 0, 0, 0, time.UTC),
		TerminalState:      "completed",
	}
	for _, option := range options {
		option(&item)
	}
	return item
}

func matchedIDs(matches []SimilarEpisodeMatch) []string {
	result := make([]string, 0, len(matches))
	for _, match := range matches {
		result = append(result, match.Outcome.EpisodeID)
	}
	return result
}

func TestRecallRanksTheSameAlertAboveMerelySimilarWording(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	matches := SelectSimilarEpisodes([]core.EpisodeOutcome{
		outcome("wording"),
		outcome("same-alert", func(item *core.EpisodeOutcome) {
			item.AlertGroupKey = "{}/{alertname=CheckoutLatency}"
			item.SymptomFingerprint = SymptomFingerprint("checkout latency")
		}),
	}, SymptomQuery{
		Text:          "checkout latency alert p99 above threshold",
		AlertGroupKey: "{}/{alertname=CheckoutLatency}",
		Now:           now,
	}, SimilarEpisodeLimit)
	if got := matchedIDs(matches); len(got) != 2 || got[0] != "same-alert" {
		t.Fatalf("ranking = %v, want the same alert group first", got)
	}
}

func TestRecallRanksTheSameServiceAboveAnUnrelatedRepository(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	matches := SelectSimilarEpisodes([]core.EpisodeOutcome{
		outcome("same-repository", func(item *core.EpisodeOutcome) {
			item.Repository = "acme/platform"
		}),
		outcome("same-service", func(item *core.EpisodeOutcome) {
			item.Services = []string{"payments-gateway"}
		}),
	}, SymptomQuery{
		Text:       "checkout latency alert p99 above threshold",
		Services:   []string{"payments-gateway"},
		Repository: "acme/platform",
		Now:        now,
	}, SimilarEpisodeLimit)
	if got := matchedIDs(matches); len(got) != 2 || got[0] != "same-service" {
		t.Fatalf("ranking = %v, want the shared service first", got)
	}
}

func TestRecallPrefersAVerifiedRemediationOverAnUnverifiedOne(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	matches := SelectSimilarEpisodes([]core.EpisodeOutcome{
		outcome("unverified"),
		outcome("verified", func(item *core.EpisodeOutcome) { item.Verified = true }),
	}, SymptomQuery{Text: "checkout latency alert p99 above threshold", Now: now},
		SimilarEpisodeLimit)
	if got := matchedIDs(matches); len(got) != 2 || got[0] != "verified" {
		t.Fatalf("ranking = %v, want the verified remediation first", got)
	}
}

// The structural bonuses must never select a candidate by themselves. Every
// episode in a one-repository deployment shares the repository, and a verified
// fix bonus applied to an unrelated episode recommends last month's
// remediation for this month's outage.
func TestRecallRefusesAnEpisodeThatMatchedOnStructureAlone(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	matches := SelectSimilarEpisodes([]core.EpisodeOutcome{
		outcome("unrelated", func(item *core.EpisodeOutcome) {
			item.SymptomFingerprint = SymptomFingerprint("nightly backup job exceeded its window")
			item.Repository = "acme/platform"
			item.Verified = true
		}),
	}, SymptomQuery{
		Text:       "checkout latency alert p99 above threshold",
		Repository: "acme/platform",
		Now:        now,
	}, SimilarEpisodeLimit)
	if len(matches) != 0 {
		t.Fatalf("recalled %v on repository and a verified-fix bonus alone", matchedIDs(matches))
	}
}

// One shared word is a coincidence. "Latency" alone connects a database to a
// CDN, and the section costs prompt budget that live evidence needs.
func TestRecallRefusesASingleSharedWord(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	matches := SelectSimilarEpisodes([]core.EpisodeOutcome{
		outcome("one-word", func(item *core.EpisodeOutcome) {
			item.SymptomFingerprint = SymptomFingerprint("cdn latency regression in eu-west")
		}),
	}, SymptomQuery{Text: "checkout latency alert p99 above threshold", Now: now},
		SimilarEpisodeLimit)
	if len(matches) != 0 {
		t.Fatalf("recalled %v on one shared word", matchedIDs(matches))
	}
}

func TestRecallAgesAnOldEpisodeBelowAFreshOne(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	matches := SelectSimilarEpisodes([]core.EpisodeOutcome{
		outcome("last-year", func(item *core.EpisodeOutcome) {
			item.TerminalAt = now.AddDate(-1, 0, 0)
		}),
		outcome("last-week", func(item *core.EpisodeOutcome) {
			item.TerminalAt = now.AddDate(0, 0, -7)
		}),
	}, SymptomQuery{Text: "checkout latency alert p99 above threshold", Now: now},
		SimilarEpisodeLimit)
	if got := matchedIDs(matches); len(got) != 2 || got[0] != "last-week" {
		t.Fatalf("ranking = %v, want the fresher episode first", got)
	}
}

// Recall has to be byte-for-byte replayable, so equal scores may not be
// ordered by map iteration or by whatever the store happened to return.
func TestRecallOrdersEqualScoresDeterministically(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	candidates := []core.EpisodeOutcome{outcome("bbb"), outcome("aaa")}
	first := matchedIDs(SelectSimilarEpisodes(candidates, SymptomQuery{
		Text: "checkout latency alert p99 above threshold", Now: now,
	}, SimilarEpisodeLimit))
	second := matchedIDs(SelectSimilarEpisodes([]core.EpisodeOutcome{
		candidates[1], candidates[0],
	}, SymptomQuery{Text: "checkout latency alert p99 above threshold", Now: now},
		SimilarEpisodeLimit))
	if len(first) != 2 || first[0] != "aaa" || first[1] != "bbb" {
		t.Fatalf("order = %v, want the episode id to break the tie", first)
	}
	if second[0] != first[0] || second[1] != first[1] {
		t.Fatalf("input order changed the result: %v then %v", first, second)
	}
}

func TestRecallKeepsAtMostTheConfiguredNumberOfEpisodes(t *testing.T) {
	now := time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
	candidates := []core.EpisodeOutcome{
		outcome("a"), outcome("b"), outcome("c"), outcome("d"), outcome("e"),
	}
	matches := SelectSimilarEpisodes(candidates, SymptomQuery{
		Text: "checkout latency alert p99 above threshold", Now: now,
	}, SimilarEpisodeLimit)
	if len(matches) != SimilarEpisodeLimit {
		t.Fatalf("recalled %d episodes, want %d", len(matches), SimilarEpisodeLimit)
	}
}

// The write side and the read side have to tokenize identically or a
// projection written today drifts out of scoring range of a query built
// tomorrow.
func TestSymptomFingerprintIsStableAndOrderIndependent(t *testing.T) {
	if got, want := SymptomFingerprint("Checkout latency ALERT"),
		SymptomFingerprint("alert  latency\ncheckout"); got != want {
		t.Fatalf("fingerprint %q != %q", got, want)
	}
	if got := SymptomFingerprint("a an this checkout"); got != "checkout" {
		t.Fatalf("fingerprint = %q, want short words and stopwords dropped", got)
	}
}
