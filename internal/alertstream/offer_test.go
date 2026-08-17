package alertstream

import "testing"

// Six identical Traefik offers on 2026-08-16, none accepted; the sixth came
// from the scheduled health review in another thread, which the episode-scoped
// check could not see.
//
// The two titles in the first row are the two real ones. They are the same fix
// — raise the VA1 Traefik memory cap — written once by an alert investigation
// and once by the 15:00 whole-platform review, and an equality test calls them
// different work. Every other row is a title this deployment actually offered,
// so "different enough to deserve its own button" is measured against real
// wording rather than invented wording.
func TestTheSameFixWordedTwiceIsOneOffer(t *testing.T) {
	cases := []struct {
		name  string
		one   string
		other string
		same  bool
	}{
		{
			name:  "the alert stream and the scheduled review, same cap raise",
			one:   "Traefik: raise VA1 ingress memory cap and add oversubscription headroom",
			other: "Increase VA1 Traefik memory headroom",
			same:  true,
		},
		{
			name:  "the same title after punctuation and case",
			one:   "Increase VA1 Traefik memory headroom",
			other: "increase va1 traefik memory headroom.",
			same:  true,
		},
		{
			name:  "the shorter title said in another order",
			one:   "Increase VA1 Traefik memory headroom",
			other: "VA1 Traefik: headroom increase for memory",
			same:  true,
		},
		{
			// Both are real tenant-infra tasks, both about VA1 Traefik memory,
			// and they are different work: one stops the reload leak, the other
			// raises the cap. An operator wants both buttons.
			name:  "preventing the OOM is not raising the cap",
			one:   "VA1: prevent reload-driven Traefik OOM recurrence",
			other: "Increase VA1 Traefik memory headroom",
			same:  false,
		},
		{
			name:  "two unrelated tenant-infra tasks",
			one:   "VA1: prevent reload-driven Traefik OOM recurrence",
			other: "BunnyCDN: verify and implement staged hostname TLS",
			same:  false,
		},
		{
			name:  "two unrelated tenant-infra tasks, no word in common",
			one:   "Fix Zot Artifact Registry authentication and detection",
			other: "Refactor PR #514 to use the GCP container module",
			same:  false,
		},
		{
			// A reply that offered nothing has nothing to point at, and a
			// pointer with no title renders no line at all.
			name:  "an offer with no title is not an offer",
			one:   "",
			other: "Increase VA1 Traefik memory headroom",
			same:  false,
		},
		{
			name:  "a title of nothing but short words matches nothing",
			one:   "VA1 OOM fix",
			other: "VA1 OOM fix now",
			same:  false,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := SameFixOffered(testCase.one, testCase.other); got != testCase.same {
				t.Fatalf(
					"SameFixOffered(%q, %q) = %t, want %t",
					testCase.one, testCase.other, got, testCase.same,
				)
			}
			// Similarity is a property of the pair, not of the argument order:
			// which of the two titles the host happens to hold is an accident
			// of which reply came first.
			if got := SameFixOffered(testCase.other, testCase.one); got != testCase.same {
				t.Fatalf(
					"SameFixOffered(%q, %q) = %t, want %t",
					testCase.other, testCase.one, got, testCase.same,
				)
			}
		})
	}
}

// The candidate filter is what the host asks: of the answers posted elsewhere in
// this channel, which ones put a button on this same fix in this same
// repository.
func TestOnlyTheSameFixInTheSameRepositoryIsACandidate(t *testing.T) {
	replies := []ReplyPosted{
		{
			SourceInputID:   "input-cap-raise",
			OfferRepository: "tenant-infra",
			OfferTitle:      "Traefik: raise VA1 ingress memory cap and add oversubscription headroom",
		},
		{
			SourceInputID:   "input-other-repository",
			OfferRepository: "tenant-platform",
			OfferTitle:      "Increase VA1 Traefik memory headroom",
		},
		{
			SourceInputID:   "input-other-fix",
			OfferRepository: "tenant-infra",
			OfferTitle:      "BunnyCDN: verify and implement staged hostname TLS",
		},
		{
			SourceInputID:   "input-being-answered",
			OfferRepository: "tenant-infra",
			OfferTitle:      "Increase VA1 Traefik memory headroom",
		},
	}
	candidates := SameFixCandidates(
		replies, "tenant-infra", "Increase VA1 Traefik memory headroom",
		"input-being-answered",
	)
	if len(candidates) != 1 || candidates[0].SourceInputID != "input-cap-raise" {
		t.Fatalf("channel-wide candidates = %+v", candidates)
	}
}
