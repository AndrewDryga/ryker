package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/service"
)

// The correction class becomes an assertion; the correction text does not.
//
// Correction text is prose written for a model. Turning it into an assertion
// automatically would mean keyword matching, which fails for the wrong reasons
// and produces a fixture that blocks releases over wording. The class is
// small and closed, so it maps cleanly — and the prose is kept as a tag so a
// reviewer reading a failure can see what was originally said.
func TestPromotionAssertsTheClassNotTheProse(t *testing.T) {
	fixture := withCorrectionAssertion(
		service.EvaluationCase{Name: "recorded"},
		"incomplete",
		"the reply claimed healthy without fresh evidence",
	)
	if !fixture.RequireCompletion || fixture.WantCompletionStatus != "decision_ready" {
		t.Fatalf("an incomplete correction did not become a completion assertion: %+v", fixture)
	}
	joined := strings.Join(fixture.Tags, " ")
	for _, want := range []string{"regression", "correction:incomplete", "claimed healthy"} {
		if !strings.Contains(joined, want) {
			t.Errorf("tags missing %q: %v", want, fixture.Tags)
		}
	}

	// An unreadable result asserts nothing extra: that it parses at all is
	// inherent in the fixture running, and inventing a second assertion would
	// make the fixture fail for a reason the correction never mentioned.
	unreadable := withCorrectionAssertion(service.EvaluationCase{}, "unreadable", "bad json")
	if unreadable.RequireCompletion {
		t.Error("an unreadable correction invented a completion requirement")
	}
}

// Promotion is idempotent, recognised by the source reference each fixture
// already carries. Running it twice must not duplicate a fixture — a corpus
// with the same case twice makes its pass rate a lie.
func TestPromotionRecognisesWhatIsAlreadyInTheCorpus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "regressions.jsonl")
	if err := os.WriteFile(path, []byte(
		`{"name":"already here","tags":["episode-replay","source:episode/ep_1"]}`+"\n"+
			"# a comment line is not a fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	present, err := promotedEpisodes(path)
	if err != nil {
		t.Fatal(err)
	}
	if !present["ep_1"] {
		t.Fatal("did not recognise an episode already in the corpus")
	}
	if present["ep_2"] {
		t.Fatal("claimed an episode is present that is not")
	}

	// A corpus that does not exist yet is not an error: the first promotion
	// creates it.
	missing, err := promotedEpisodes(filepath.Join(t.TempDir(), "absent.jsonl"))
	if err != nil || len(missing) != 0 {
		t.Fatalf("absent corpus = %v, %v", missing, err)
	}
}
