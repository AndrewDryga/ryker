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

// evalOptions collects the eval command's flags.
//
// The eval command is the entry point for every release gate, so a mistake in
// its wiring weakens a gate silently rather than failing loudly. Keeping the
// twenty-four flag declarations out of the command body leaves the part with
// actual logic — the validation and the mode dispatch — short enough to read
// against the Makefile targets that depend on it.
type evalOptions struct {
	inputPath             *string
	jsonOutput            *bool
	resultsPath           *string
	replay                *bool
	episodeReplay         *bool
	canary                *bool
	configPath            *string
	caseTimeout           *time.Duration
	caseFilter            *string
	repeat                *int
	scenarios             *bool
	calibrateJudge        *bool
	judge                 *bool
	verifyEvidence        *bool
	taskPolicy            *string
	minOverallPassRate    *float64
	minCasePassRate       *float64
	minProactivePrecision *float64
	minProactiveRecall    *float64
	maxFalseInterruption  *float64
	minMeanQuality        *float64
	baselinePath          *string
	writeBaselinePath     *string
	maxRegression         *float64
}

func defineEvalFlags(flags *flag.FlagSet) *evalOptions {
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
	episodeReplay := flags.Bool(
		"episode-replay",
		false,
		"call the real model with recorded sanitized episode events and tool results",
	)
	canary := flags.Bool(
		"canary",
		false,
		"run only real-model cases tagged canary",
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
	scenarios := flags.Bool(
		"scenarios",
		false,
		"run a stateful multi-turn scenario corpus",
	)
	calibrateJudge := flags.Bool(
		"calibrate-judge",
		false,
		"run human-labeled quality-judge calibration cases",
	)
	judge := flags.Bool(
		"judge",
		false,
		"score the rendered Slack response with a separate real model turn",
	)
	verifyEvidence := flags.Bool(
		"verify-evidence",
		false,
		"independently re-check response claims with a separate real model turn",
	)
	taskPolicy := flags.String(
		"task-policy",
		"",
		"explicit disposable writable Coop policy for kind=task cases",
	)
	minOverallPassRate := flags.Float64(
		"min-overall-pass-rate",
		0,
		"minimum aggregate pass rate from 0 to 1",
	)
	minCasePassRate := flags.Float64(
		"min-case-pass-rate",
		0,
		"minimum repeated-sample pass rate for every case from 0 to 1",
	)
	minProactivePrecision := flags.Float64(
		"min-proactive-precision",
		0,
		"minimum precision for labeled proactive decisions from 0 to 1",
	)
	minProactiveRecall := flags.Float64(
		"min-proactive-recall",
		0,
		"minimum recall for labeled proactive decisions from 0 to 1",
	)
	maxFalseInterruption := flags.Float64(
		"max-false-interruption-rate",
		0,
		"maximum false interruption rate for labeled silent messages from 0 to 1",
	)
	minMeanQuality := flags.Float64(
		"min-mean-quality",
		0,
		"minimum mean model-judge score from 1 to 5",
	)
	baselinePath := flags.String(
		"baseline",
		"",
		"compare this run with a checked private evaluation baseline",
	)
	writeBaselinePath := flags.String(
		"write-baseline",
		"",
		"write a private baseline from this successful run",
	)
	maxRegression := flags.Float64(
		"max-regression",
		0,
		"maximum allowed per-case pass-rate regression from baseline",
	)
	return &evalOptions{
		inputPath:             inputPath,
		jsonOutput:            jsonOutput,
		resultsPath:           resultsPath,
		replay:                replay,
		episodeReplay:         episodeReplay,
		canary:                canary,
		configPath:            configPath,
		caseTimeout:           caseTimeout,
		caseFilter:            caseFilter,
		repeat:                repeat,
		scenarios:             scenarios,
		calibrateJudge:        calibrateJudge,
		judge:                 judge,
		verifyEvidence:        verifyEvidence,
		taskPolicy:            taskPolicy,
		minOverallPassRate:    minOverallPassRate,
		minCasePassRate:       minCasePassRate,
		minProactivePrecision: minProactivePrecision,
		minProactiveRecall:    minProactiveRecall,
		maxFalseInterruption:  maxFalseInterruption,
		minMeanQuality:        minMeanQuality,
		baselinePath:          baselinePath,
		writeBaselinePath:     writeBaselinePath,
		maxRegression:         maxRegression,
	}
}

// validate rejects flag combinations that would produce a meaningless gate —
// a replay asked to judge, two modes at once, a threshold outside its range.
// It reports whether the false-interruption ceiling was explicitly set, which
// cannot be inferred from its value because zero is a meaningful ceiling.
func (options *evalOptions) validate(flags *flag.FlagSet) (bool, error) {
	enforce := false
	flags.Visit(func(candidate *flag.Flag) {
		if candidate.Name == "max-false-interruption-rate" {
			enforce = true
		}
	})
	if *options.repeat < 1 || *options.repeat > 10 {
		return false, errors.New("eval --repeat must be between 1 and 10")
	}
	for name, value := range map[string]float64{
		"min-overall-pass-rate":       *options.minOverallPassRate,
		"min-case-pass-rate":          *options.minCasePassRate,
		"min-proactive-precision":     *options.minProactivePrecision,
		"min-proactive-recall":        *options.minProactiveRecall,
		"max-false-interruption-rate": *options.maxFalseInterruption,
		"max-regression":              *options.maxRegression,
	} {
		if value < 0 || value > 1 {
			return false, fmt.Errorf("eval --%s must be between 0 and 1", name)
		}
	}
	if *options.minMeanQuality < 0 || *options.minMeanQuality > 5 {
		return false, errors.New("eval --min-mean-quality must be between 0 and 5")
	}
	modeCount := 0
	for _, enabled := range []bool{*options.replay, *options.episodeReplay, *options.scenarios, *options.calibrateJudge} {
		if enabled {
			modeCount++
		}
	}
	if modeCount > 1 {
		return false, errors.New("eval --replay, --episode-replay, --scenarios, and --calibrate-judge are mutually exclusive")
	}
	if *options.calibrateJudge && *options.repeat != 1 {
		return false, errors.New("eval --repeat is not supported with --calibrate-judge")
	}
	if *options.replay && (*options.caseFilter != "" || *options.repeat != 1 || *options.scenarios ||
		*options.calibrateJudge ||
		*options.judge || *options.verifyEvidence) {
		return false, errors.New(
			"eval --case, --repeat, --scenarios, --calibrate-judge, --judge, and --verify-evidence require a real model run",
		)
	}
	if *options.canary && *options.caseFilter != "" {
		return false, errors.New("eval --canary and --case are mutually exclusive")
	}
	if *options.canary {
		*options.caseFilter = "canary"
	}
	if *options.inputPath == "" && *options.replay {
		*options.inputPath = "testdata/eval/golden.jsonl"
	}
	if *options.inputPath == "" && *options.episodeReplay {
		*options.inputPath = "testdata/eval/episode-replay.jsonl"
	}
	if *options.inputPath == "" {
		*options.inputPath = "testdata/eval/live.jsonl"
	}
	return enforce, nil
}

func runEval(args []string, stdout, stderr io.Writer) (resultErr error) {
	flags := flag.NewFlagSet("eval", flag.ContinueOnError)
	flags.SetOutput(stderr)
	options := defineEvalFlags(flags)
	inputPath := options.inputPath
	jsonOutput := options.jsonOutput
	resultsPath := options.resultsPath
	replay := options.replay
	episodeReplay := options.episodeReplay
	canary := options.canary
	configPath := options.configPath
	caseTimeout := options.caseTimeout
	caseFilter := options.caseFilter
	repeat := options.repeat
	scenarios := options.scenarios
	calibrateJudge := options.calibrateJudge
	judge := options.judge
	verifyEvidence := options.verifyEvidence
	taskPolicy := options.taskPolicy
	minOverallPassRate := options.minOverallPassRate
	minCasePassRate := options.minCasePassRate
	minProactivePrecision := options.minProactivePrecision
	minProactiveRecall := options.minProactiveRecall
	maxFalseInterruption := options.maxFalseInterruption
	minMeanQuality := options.minMeanQuality
	baselinePath := options.baselinePath
	writeBaselinePath := options.writeBaselinePath
	maxRegression := options.maxRegression
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("eval accepts no positional arguments")
	}
	enforceFalseInterruption, err := options.validate(flags)
	if err != nil {
		return err
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
		options := service.LiveEvaluationOptions{
			CaseTimeout:    *caseTimeout,
			CaseFilter:     *caseFilter,
			Repeat:         *repeat,
			Judge:          *judge,
			VerifyEvidence: *verifyEvidence,
			TaskPolicy:     *taskPolicy,
			EpisodeReplay:  *episodeReplay,
			SanitizeResponse: func(value string) string {
				return sanitizer.Text(value)
			},
			Progress: func(name string, state string) {
				if *jsonOutput {
					return
				}
				fmt.Fprintf(stderr, "%-7s %s\n", state, name)
			},
		}
		if *calibrateJudge {
			summary, err = service.EvaluateQualityCalibrationJSONL(
				context.Background(),
				file,
				cfg,
				coopClient,
				options,
			)
		} else if *scenarios {
			summary, err = service.EvaluateLiveScenariosJSONL(
				context.Background(),
				file,
				cfg,
				coopClient,
				options,
			)
		} else {
			summary, err = service.EvaluateLiveJSONL(
				context.Background(),
				file,
				cfg,
				coopClient,
				options,
			)
		}
		if err != nil {
			return err
		}
	}
	var baseline *service.EvaluationBaseline
	if *baselinePath != "" {
		value, readErr := readEvaluationBaseline(*baselinePath)
		if readErr != nil {
			return readErr
		}
		baseline = &value
	}
	service.ApplyEvaluationGates(&summary, service.EvaluationGateOptions{
		MinOverallPassRate:       *minOverallPassRate,
		MinCasePassRate:          *minCasePassRate,
		MinProactivePrecision:    *minProactivePrecision,
		MinProactiveRecall:       *minProactiveRecall,
		MaxFalseInterruptionRate: *maxFalseInterruption,
		EnforceFalseInterruption: enforceFalseInterruption,
		MinMeanQuality:           *minMeanQuality,
		MaxBaselineRegression:    *maxRegression,
		Baseline:                 baseline,
	})
	if *writeBaselinePath != "" {
		if !summary.Gate.Passed || summary.Failed != 0 {
			return errors.New("refusing to write a baseline from a failed evaluation")
		}
		if err := writeEvaluationBaseline(
			*writeBaselinePath,
			service.BaselineFromSummary(summary),
		); err != nil {
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
		} else if *episodeReplay {
			label = "Real-model episode replay"
		} else if *canary {
			label = "Live canary"
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
		for _, failure := range summary.Gate.Failures {
			fmt.Fprintf(stdout, "GATE: %s\n", failure)
		}
	}
	if summary.Failed > 0 {
		return fmt.Errorf("%d evaluation cases failed", summary.Failed)
	}
	if !summary.Gate.Passed {
		return errors.New("evaluation gate failed")
	}
	return nil
}

func readEvaluationBaseline(path string) (service.EvaluationBaseline, error) {
	file, err := os.Open(path)
	if err != nil {
		return service.EvaluationBaseline{}, fmt.Errorf(
			"open evaluation baseline: %w",
			err,
		)
	}
	defer file.Close()
	var result service.EvaluationBaseline
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return service.EvaluationBaseline{}, fmt.Errorf(
			"decode evaluation baseline: %w",
			err,
		)
	}
	if result.Version != 1 {
		return service.EvaluationBaseline{}, fmt.Errorf(
			"evaluation baseline version must be 1",
		)
	}
	return result, nil
}

func writeEvaluationBaseline(
	path string,
	baseline service.EvaluationBaseline,
) error {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(baseline); err != nil {
		return err
	}
	return writePrivateEvaluationFile(path, output.Bytes(), "baseline")
}

func writeEvaluationSummary(path string, summary service.EvaluationSummary) error {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(summary); err != nil {
		return err
	}
	return writePrivateEvaluationFile(path, output.Bytes(), "results")
}

func writePrivateEvaluationFile(path string, data []byte, label string) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".responder-eval-*.json")
	if err != nil {
		return fmt.Errorf("create evaluation %s: %w", label, err)
	}
	tempPath := file.Name()
	defer os.Remove(tempPath)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return fmt.Errorf("protect evaluation results: %w", err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return fmt.Errorf("write evaluation %s: %w", label, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close evaluation %s: %w", label, err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("publish evaluation %s: %w", label, err)
	}
	return nil
}
