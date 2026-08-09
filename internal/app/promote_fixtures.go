package app

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/store"
)

// regressionCorpusPath is where promoted corrections land.
//
// A separate file from the hand-written corpora on purpose: these are grown
// from production rather than authored, and a reviewer looking at a failure
// should be able to tell immediately which kind they are dealing with.
const regressionCorpusPath = "testdata/eval/regressions.jsonl"

// runPromoteFixtures writes approved corrections into the regression corpus.
//
// This is the last step of the self-improving loop and the only one that
// touches a release gate, which is why it is a command an operator runs rather
// than something that happens on its own. Approval in App Home says the lesson
// is worth keeping; this says it is ready to block a release.
func runPromoteFixtures(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("promote-fixtures", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	corpusPath := flags.String("corpus", regressionCorpusPath, "regression corpus to append to")
	dryRun := flags.Bool("dry-run", false, "print what would be promoted and write nothing")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("promote-fixtures accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	st, err := store.OpenCurrent(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()

	ctx := context.Background()
	approved, err := st.ListApprovedFixtureCandidates(ctx, 50)
	if err != nil {
		return err
	}
	if len(approved) == 0 {
		fmt.Fprintln(stdout, "Nothing approved is waiting to be promoted.")
		return nil
	}
	// Already-promoted episodes are recognised by the source reference each
	// fixture carries, so running this twice is safe and needs no extra state.
	present, err := promotedEpisodes(*corpusPath)
	if err != nil {
		return err
	}
	var written int
	var lines []string
	for _, candidate := range approved {
		// Also marked inside the loop: two corrections routinely land on one
		// episode — the runbook episode carried both "no diagnostic closure"
		// and "material gaps" — and deduplicating only against the existing
		// corpus wrote both, which the corpus validator then rejected as a
		// duplicate case name after the first gate had already passed. One
		// episode replays once; its fixture asserts the corrected outcome for
		// every correction class that pointed at it.
		if present[candidate.EpisodeID] {
			continue
		}
		present[candidate.EpisodeID] = true
		// Candidates queued before the recording site labeled them carry no
		// capability at all. Promoting one as-is is what produced the four
		// fixtures tagged "capability:", so an unlabeled candidate takes the
		// same conservative default the recording site now uses — and says so,
		// because a default nobody is told about is how the empty tag survived
		// a hand review of sixteen corrections.
		capability := strings.TrimSpace(candidate.Capability)
		if capability == "" {
			capability = service.DefaultFixtureCapability()
			fmt.Fprintf(stderr,
				"%s was queued before corrections were labeled; tagging it %q — "+
					"sharpen it in the diff if the episode proves something more specific\n",
				candidate.EpisodeID, capability,
			)
		}
		fixture, err := recordEpisodeFixture(
			ctx, storeEpisodeSource{store: st}, cfg, candidate.EpisodeID, capability, "",
		)
		if err != nil {
			fmt.Fprintf(stderr, "skipped %s: %v\n", candidate.EpisodeID, err)
			continue
		}
		fixture = withCorrectionAssertion(fixture, candidate.CorrectionClass, candidate.Correction)
		encoded, err := json.Marshal(fixture)
		if err != nil {
			return err
		}
		lines = append(lines, string(encoded))
		written++
	}
	if written == 0 {
		fmt.Fprintln(stdout, "Everything approved is already in the corpus.")
		return nil
	}
	if *dryRun {
		fmt.Fprintf(stdout, "Would promote %d correction(s) into %s.\n", written, *corpusPath)
		return nil
	}
	if err := appendCorpusLines(*corpusPath, lines); err != nil {
		return err
	}
	fmt.Fprintf(stdout,
		"Promoted %d correction(s) into %s.\nReview the diff before committing: "+
			"a fixture is a claim about what Responder must always do.\n", written, *corpusPath)
	return nil
}

// withCorrectionAssertion turns a correction class into something checkable.
//
// The correction text is prose written for a model and cannot be turned into an
// assertion automatically — trying would produce brittle keyword matching that
// fails for the wrong reasons. The class can: a result that was refused as
// incomplete must, in the fixture, reach a decision-ready completion.
//
// The prose is kept in the tags so a reviewer reading a failure can see what
// the original correction actually said.
func withCorrectionAssertion(
	fixture service.EvaluationCase,
	class string,
	correction string,
) service.EvaluationCase {
	fixture.Tags = append(fixture.Tags, "regression", "correction:"+class)
	if summary := strings.TrimSpace(correction); summary != "" {
		fixture.Tags = append(fixture.Tags, "corrected:"+truncateTag(summary))
	}
	// Both classes reached a decision: incomplete means the answer fell
	// short, rejected means an attached offer did. Neither is a turn that
	// failed to produce one, so a replay must still get that far.
	if class == "incomplete" || class == "rejected" {
		fixture.RequireCompletion = true
		fixture.WantCompletionStatus = "decision_ready"
	}
	return fixture
}

// truncateTag bounds a correction for use as a tag.
//
// Through core.TruncateUTF8 rather than a slice: a correction quotes model
// output, which routinely contains multi-byte runes, and cutting one in half
// produces invalid UTF-8 that corrupts the fixture when it is re-encoded.
func truncateTag(value string) string {
	return core.TruncateUTF8(strings.Join(strings.Fields(value), " "), 120)
}

// promotedEpisodes reads the source references already in the corpus.
func promotedEpisodes(path string) (map[string]bool, error) {
	present := make(map[string]bool)
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return present, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 1<<20), 1<<22)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var fixture struct {
			Tags []string `json:"tags"`
		}
		if err := json.Unmarshal([]byte(line), &fixture); err != nil {
			continue
		}
		for _, tag := range fixture.Tags {
			if episode, ok := strings.CutPrefix(tag, "source:episode/"); ok {
				present[episode] = true
			}
		}
	}
	return present, scanner.Err()
}

func appendCorpusLines(path string, lines []string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	for _, line := range lines {
		if _, err := fmt.Fprintln(file, line); err != nil {
			return err
		}
	}
	return nil
}
