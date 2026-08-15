package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/evaluation"
)

// runEvalBaseline records what a corpus achieved, from a run that already
// happened.
//
// Baselines are committed files, and a committed number has to be a number some
// run actually produced — `eval --write-baseline` can only write one from a run
// happening right now, which for the credentialed corpora means spending an
// hour of model calls to write down what the last hour of model calls already
// measured. Every one of those runs left its result in EVAL_HISTORY, so this
// reads the newest one back and writes the baseline from it.
//
// The update is deliberately a command an operator runs rather than something
// the gate does for itself. A baseline that refreshed automatically would let
// quality fall one acceptable step at a time and call it the new normal; this
// way a regression is a diff someone approved.
func runEvalBaseline(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("eval-baseline", flag.ContinueOnError)
	flags.SetOutput(stderr)
	historyDir := flags.String("history", "", "directory of recorded evaluation results")
	corpus := flags.String("corpus", "", "history prefix to take the newest result from")
	resultsPath := flags.String("results", "", "one recorded evaluation result to read")
	writePath := flags.String("write", "", "baseline file to rewrite")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("eval-baseline accepts no positional arguments")
	}
	if strings.TrimSpace(*writePath) == "" {
		return errors.New("eval-baseline requires --write naming the baseline to rewrite")
	}
	if (*resultsPath == "") == (*historyDir == "") {
		return errors.New("eval-baseline takes either --results or --history with --corpus")
	}
	source := *resultsPath
	if source == "" {
		if strings.TrimSpace(*corpus) == "" {
			return errors.New("eval-baseline requires --corpus with --history")
		}
		var err error
		source, err = newestEvaluationResult(*historyDir, *corpus)
		if err != nil {
			return err
		}
	}
	summary, err := readEvaluationSummary(source)
	if err != nil {
		return err
	}
	if err := checkBaselineSource(summary, source); err != nil {
		return err
	}
	baseline := evaluation.BaselineFromSummary(summary)
	if err := writeCommittedBaseline(*writePath, baseline); err != nil {
		return err
	}
	fmt.Fprintf(stdout,
		"Wrote %s from %s: %d of %d passed, %d cases, mean judge score %.2f.\n"+
			"Read the diff before committing: it is the number a release will be held to.\n",
		*writePath, filepath.Base(source), summary.Passed, summary.Total,
		len(baseline.CasePassRates), baseline.Quality.MeanScore,
	)
	return nil
}

// checkBaselineSource refuses to write down a number nobody should be held to.
//
// A run with a failure records the failure as the standard, so the next release
// only has to be as bad. A run the provider refused records nothing at all: the
// cases have no rate, and a baseline of absent cases would fail the next real
// run for having cases in it.
func checkBaselineSource(summary evaluation.EvaluationSummary, source string) error {
	switch {
	case summary.Total == 0:
		return fmt.Errorf("%s evaluated no cases", source)
	case len(summary.Cases) == 0:
		// Without per-case rates the file would still write a baseline, and it
		// would compare nothing case by case while looking exactly like one that
		// did. Refuse instead of recording a gate with the middle missing.
		return fmt.Errorf("%s recorded no per-case rates", source)
	case summary.Unevaluated > 0:
		return fmt.Errorf(
			"%s left %d of %d cases unevaluated: the provider refused the turn, "+
				"so this run says nothing about what the corpus achieves",
			source, summary.Unevaluated, summary.Total,
		)
	case summary.Failed > 0:
		return fmt.Errorf(
			"%s had %d failed case(s); a baseline records what a clean run achieved",
			source, summary.Failed,
		)
	case summary.Gate.Evaluated && !summary.Gate.Passed:
		return fmt.Errorf("%s did not pass its own gate", source)
	}
	return nil
}

// newestEvaluationResult picks the last result a corpus recorded.
//
// The history files are stamped in UTC with a fixed-width format, so the newest
// is the last one in lexical order and no file needs to be opened to find it.
func newestEvaluationResult(historyDir string, corpus string) (string, error) {
	matches, err := filepath.Glob(filepath.Join(historyDir, corpus+"-*.json"))
	if err != nil {
		return "", err
	}
	if len(matches) == 0 {
		return "", fmt.Errorf(
			"no recorded result for %q in %s: run the corpus once with --results "+
				"before recording a baseline from it",
			corpus, historyDir,
		)
	}
	sort.Strings(matches)
	return matches[len(matches)-1], nil
}

// readEvaluationSummary decodes a recorded run.
//
// Unknown fields are tolerated, unlike a baseline: a result is an artifact an
// older build wrote, and the summary has grown fields since — refusing to read
// last month's evidence because this month's binary has one more counter would
// make the history unusable exactly when it is most wanted.
func readEvaluationSummary(path string) (evaluation.EvaluationSummary, error) {
	file, err := os.Open(path)
	if err != nil {
		return evaluation.EvaluationSummary{}, fmt.Errorf("open evaluation result: %w", err)
	}
	defer file.Close()
	var summary evaluation.EvaluationSummary
	if err := json.NewDecoder(file).Decode(&summary); err != nil {
		return evaluation.EvaluationSummary{}, fmt.Errorf(
			"decode evaluation result %s: %w", path, err,
		)
	}
	return summary, nil
}

// writeCommittedBaseline writes the reviewed copy.
//
// Mode 0644 rather than the 0600 a run's own results take: a baseline holds
// aggregate rates and the case names already published in the corpus beside it,
// and it is meant to be read in a diff by whoever approves it.
func writeCommittedBaseline(path string, baseline evaluation.EvaluationBaseline) error {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(baseline); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, output.Bytes(), 0o644)
}
