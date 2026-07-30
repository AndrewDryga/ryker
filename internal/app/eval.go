package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/slackui"
)

func runEval(args []string, stdout, stderr io.Writer) (resultErr error) {
	flags := flag.NewFlagSet("eval", flag.ContinueOnError)
	flags.SetOutput(stderr)
	inputPath := flags.String(
		"input", "",
		"JSONL corpus (defaults to testdata/eval/live.jsonl or golden.jsonl with --replay)",
	)
	jsonOutput := flags.Bool("json", false, "print the complete result as JSON")
	resultsPath := flags.String(
		"results",
		"",
		"write the sanitized complete result as private JSON",
	)
	replay := flags.Bool(
		"replay",
		false,
		"replay checked-in outputs without calling the model",
	)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	caseTimeout := flags.Duration(
		"case-timeout",
		0,
		"maximum duration for each live model case (default 10m)",
	)
	caseFilter := flags.String(
		"case",
		"",
		"run live cases whose name or tag contains this value",
	)
	repeat := flags.Int(
		"repeat",
		1,
		"number of independent model samples per live case (1-10)",
	)
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("eval accepts no positional arguments")
	}
	if *repeat < 1 || *repeat > 10 {
		return errors.New("eval --repeat must be between 1 and 10")
	}
	if *replay && (*caseFilter != "" || *repeat != 1) {
		return errors.New("eval --case and --repeat require a real model run")
	}
	if *inputPath == "" && *replay {
		*inputPath = "testdata/eval/golden.jsonl"
	}
	if *inputPath == "" {
		*inputPath = "testdata/eval/live.jsonl"
	}
	file, err := os.Open(*inputPath)
	if err != nil {
		return fmt.Errorf("open evaluation corpus: %w", err)
	}
	defer file.Close()
	var summary service.EvaluationSummary
	if *replay {
		summary, err = service.EvaluateJSONL(file)
		if err != nil {
			return err
		}
	} else {
		cfg, err := config.Load(*configPath)
		if err != nil {
			return err
		}
		emisarToken, err := cfg.Secret(cfg.Coop.EmisarTokenEnv)
		if err != nil {
			return err
		}
		expectedBootstrap, err := bootstrapFiles(cfg, emisarToken)
		if err != nil {
			return err
		}
		if err := checkPrivateCoopConfig(cfg.Coop.BootstrapDir, expectedBootstrap); err != nil {
			return err
		}
		logger := newLogger(stderr, cfg.LogLevel)
		coopClient := coop.New(cfg.Coop.Socket, cfg.Coop.RequestTimeout.Duration)
		supervisor, supervision, err := startDoctorCoop(
			cfg,
			stderr,
			logger,
			coopClient,
		)
		if err != nil {
			return err
		}
		defer func() {
			if stopErr := stopManagedCoop(supervisor, 15*time.Second); resultErr == nil &&
				stopErr != nil {
				resultErr = stopErr
			}
		}()
		readyCtx, readyCancel := context.WithTimeout(
			context.Background(),
			cfg.Coop.RequestTimeout.Duration,
		)
		err = coopClient.Ready(readyCtx)
		readyCancel()
		if err != nil {
			return fmt.Errorf("Coop: %w", err)
		}
		redactions := []string{emisarToken}
		additional, err := additionalEnvironmentValues(cfg)
		if err != nil {
			return err
		}
		for _, value := range additional {
			redactions = append(redactions, value)
		}
		sanitizer := slackui.NewSanitizer(cfg.Limits.MaxAssistantBytes, redactions...)
		if !*jsonOutput {
			fmt.Fprintf(stderr, "Coop ready (%s); running real model evaluation\n", supervision)
		}
		summary, err = service.EvaluateLiveJSONL(
			context.Background(),
			file,
			cfg,
			coopClient,
			service.LiveEvaluationOptions{
				CaseTimeout: *caseTimeout,
				CaseFilter:  *caseFilter,
				Repeat:      *repeat,
				SanitizeResponse: func(value string) string {
					return sanitizer.Text(value)
				},
				Progress: func(name string, state string) {
					if *jsonOutput {
						return
					}
					fmt.Fprintf(stderr, "%-7s %s\n", state, name)
				},
			},
		)
		if err != nil {
			return err
		}
	}
	if *resultsPath != "" {
		if err := writeEvaluationSummary(*resultsPath, summary); err != nil {
			return err
		}
	}
	if *jsonOutput {
		encoder := json.NewEncoder(stdout)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(summary); err != nil {
			return err
		}
	} else {
		label := "Model evaluation"
		if *replay {
			label = "Contract replay"
		}
		var line strings.Builder
		fmt.Fprintf(
			&line,
			"%s: %d/%d passed, %d failed",
			label,
			summary.Passed, summary.Total, summary.Failed,
		)
		if !*replay {
			fmt.Fprintf(
				&line,
				" (%d model calls, %s)",
				summary.ModelCalls,
				time.Duration(summary.DurationMS)*time.Millisecond,
			)
		}
		fmt.Fprintln(stdout, line.String())
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

func writeEvaluationSummary(path string, summary service.EvaluationSummary) error {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(summary); err != nil {
		return err
	}
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".responder-eval-*.json")
	if err != nil {
		return fmt.Errorf("create evaluation results: %w", err)
	}
	tempPath := file.Name()
	defer os.Remove(tempPath)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return fmt.Errorf("protect evaluation results: %w", err)
	}
	if _, err := file.Write(output.Bytes()); err != nil {
		file.Close()
		return fmt.Errorf("write evaluation results: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close evaluation results: %w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("publish evaluation results: %w", err)
	}
	return nil
}
