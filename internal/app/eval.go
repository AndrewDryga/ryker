package app

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/AndrewDryga/responder/internal/service"
)

func runEval(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("eval", flag.ContinueOnError)
	flags.SetOutput(stderr)
	inputPath := flags.String(
		"input", "testdata/eval/golden.jsonl",
		"redacted JSONL evaluation corpus",
	)
	jsonOutput := flags.Bool("json", false, "print the complete result as JSON")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("eval accepts no positional arguments")
	}
	file, err := os.Open(*inputPath)
	if err != nil {
		return fmt.Errorf("open evaluation corpus: %w", err)
	}
	defer file.Close()
	summary, err := service.EvaluateJSONL(file)
	if err != nil {
		return err
	}
	if *jsonOutput {
		encoder := json.NewEncoder(stdout)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(summary); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(
			stdout,
			"Evaluation: %d/%d passed, %d failed\n",
			summary.Passed, summary.Total, summary.Failed,
		)
		for _, result := range summary.Results {
			if !result.Passed {
				fmt.Fprintf(stdout, "FAIL %s: %s\n", result.Name, result.Detail)
			}
		}
	}
	if summary.Failed > 0 {
		return fmt.Errorf("%d evaluation cases failed", summary.Failed)
	}
	return nil
}
