package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/audition"
	"github.com/AndrewDryga/ryker/internal/config"
)

func writeHistory(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// The corpus label and the moment a run happened exist only in the filename.
// The summary inside knows its mode and not which corpus produced it, so a
// reader that could not split the name would report every recorded run as one
// nameless corpus — and labels carry hyphens of their own, which is why the
// split is from the right.
func TestARecordedRunIsIdentifiedByItsFilename(t *testing.T) {
	dir := t.TempDir()
	writeHistory(t, dir, "episode-replay-blitz-20260814T101500Z.json",
		`{"mode":"episode-replay","total":9,"passed":6,"quality":{"evaluated":4,"mean_score":4.25},
		  "cases":[{"name":"a","samples":1,"passed":1,"pass_rate":1}],"results":[]}`)

	corpora, err := recordedCorpora(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(corpora) != 1 {
		t.Fatalf("read %d corpora from one recorded run", len(corpora))
	}
	corpus := corpora[0]
	if corpus.Name != "episode-replay-blitz" {
		t.Fatalf("corpus name = %q, want the hyphenated label kept whole", corpus.Name)
	}
	if !corpus.Recorded.Equal(time.Date(2026, 8, 14, 10, 15, 0, 0, time.UTC)) {
		t.Fatalf("recorded at %v, want the stamp from the filename", corpus.Recorded)
	}
	if corpus.Passed != 6 || corpus.Total != 9 {
		t.Fatalf("gate = %d of %d, want 6 of 9", corpus.Passed, corpus.Total)
	}
	if corpus.JudgeEvaluated != 4 || corpus.JudgeMean != 4.25 {
		t.Fatalf("judge %v over %d, want the denominator carried with the mean",
			corpus.JudgeMean, corpus.JudgeEvaluated)
	}
}

// Only the newest run of each corpus. An audition is a standing answer, and ten
// weeks of a corpus that has not moved buries the row that has.
func TestOnlyTheNewestRunOfEachCorpusIsAuditioned(t *testing.T) {
	dir := t.TempDir()
	writeHistory(t, dir, "regressions-20260801T101500Z.json",
		`{"total":3,"passed":1,"results":[]}`)
	writeHistory(t, dir, "regressions-20260814T101500Z.json",
		`{"total":3,"passed":3,"results":[]}`)

	corpora, err := recordedCorpora(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(corpora) != 1 || corpora[0].Passed != 3 {
		t.Fatalf("corpora = %+v, want only the newest regressions run", corpora)
	}
}

// History is written by whichever binary was current that week. Refusing to
// report at all because one file is malformed would lose the other forty, which
// is the opposite of what a trend is for.
func TestOneUnreadableRecordedRunDoesNotHideTheRest(t *testing.T) {
	dir := t.TempDir()
	writeHistory(t, dir, "regressions-20260814T101500Z.json", `{"total":3,"passed":3,"results":[]}`)
	writeHistory(t, dir, "quality-20260814T101500Z.json", `{ this is not json`)
	writeHistory(t, dir, "notes.txt", `ignored`)
	writeHistory(t, dir, "no-stamp.json", `{"total":1,"passed":1,"results":[]}`)

	corpora, err := recordedCorpora(dir)
	if err != nil {
		t.Fatalf("one malformed file failed the whole read: %v", err)
	}
	if len(corpora) != 1 || corpora[0].Name != "regressions" {
		t.Fatalf("corpora = %+v, want the one readable run", corpora)
	}
}

// The printed report keeps the two cost figures apart and says so in as many
// words. A single combined number cannot be checked against an invoice, and
// nobody downstream can un-add it.
func TestThePrintedAuditionKeepsReportedAndEstimatedApart(t *testing.T) {
	report := audition.Build(time.Now().UTC().AddDate(0, 0, -7),
		[]audition.Lane{
			{Class: "triage", Profile: "deep", Provider: "anthropic", Model: "claude",
				Attempts: 4, Measured: 4, CostedTurns: 4, ReportedUSD: 1.25,
				Corrections: 2, CorrectedAttempts: 1},
			{Class: "engineering", Provider: "openai", Model: "gpt", Attempts: 2},
		},
		[]audition.Corpus{{Name: "regressions", Recorded: time.Now().UTC(),
			Total: 9, Passed: 6, JudgeEvaluated: 4, JudgeMean: 4.25, Cases: 3}},
		config.Pricing{})

	var out strings.Builder
	printAudition(&out, report, 7, "/tmp/history")
	body := out.String()

	if !strings.Contains(body, "provider-reported: 1.25 USD over 4 costed turns") {
		t.Fatalf("the reported figure is not stated over its own denominator:\n%s", body)
	}
	if !strings.Contains(body, "never added together") {
		t.Fatalf("the report does not warn that the two figures are not a total:\n%s", body)
	}
	// An unmeasured lane must read as unmeasured, not as free.
	if !strings.Contains(body, "not measured") {
		t.Fatalf("an unmeasured lane was not marked as such:\n%s", body)
	}
	// And a corpus must not claim a model it never recorded.
	if !strings.Contains(body, "not recorded") {
		t.Fatalf("the corpus half claims to know which model earned it:\n%s", body)
	}
	if !strings.Contains(body, "67% (6/9)") {
		t.Fatalf("the gate-pass rate is not shown over its own denominator:\n%s", body)
	}
}
