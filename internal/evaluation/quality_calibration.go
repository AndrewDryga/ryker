package evaluation

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/serviceport"
	"github.com/AndrewDryga/responder/internal/slackui"
)

type QualityCalibrationCase struct {
	Name           string              `json:"name"`
	Repository     string              `json:"repository,omitempty"`
	Input          string              `json:"input"`
	RecentMessages []EvaluationMessage `json:"recent_messages,omitempty"`
	Response       slackui.Message     `json:"response"`
	WantPass       bool                `json:"want_pass"`
	MinMeanScore   float64             `json:"min_mean_score,omitempty"`
	MaxMeanScore   float64             `json:"max_mean_score,omitempty"`
	WantCritical   bool                `json:"want_critical_failure,omitempty"`
	// Lane decides which rung of the word ladder this reply is measured
	// against. Absent means the investigation lane, which is the wider bound,
	// so an unlabelled case under-reports length rather than inventing it.
	Lane string `json:"lane,omitempty"`
	// Where the reply landed and where it belonged. See EvaluationCase.
	ReplyPlacement     string `json:"reply_placement,omitempty"`
	WantReplyPlacement string `json:"want_reply_placement,omitempty"`
}

func decodeQualityCalibrationCases(
	reader io.Reader,
) ([]QualityCalibrationCase, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	var cases []QualityCalibrationCase
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var item QualityCalibrationCase
		decoder := json.NewDecoder(strings.NewReader(line))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&item); err != nil {
			return nil, fmt.Errorf(
				"decode quality calibration case %d: %w",
				len(cases)+1,
				err,
			)
		}
		if item.Name == "" || item.Input == "" ||
			strings.TrimSpace(item.Response.Text) == "" {
			return nil, fmt.Errorf(
				"quality calibration case %d requires name, input, and response.text",
				len(cases)+1,
			)
		}
		if item.MinMeanScore < 0 || item.MinMeanScore > 5 ||
			item.MaxMeanScore < 0 || item.MaxMeanScore > 5 {
			return nil, fmt.Errorf(
				"quality calibration case %q score bounds must be between 0 and 5",
				item.Name,
			)
		}
		if !decisionpkg.ValidReplyPlacement(item.ReplyPlacement) ||
			!decisionpkg.ValidReplyPlacement(item.WantReplyPlacement) {
			return nil, fmt.Errorf(
				"quality calibration case %q placement must be thread or channel",
				item.Name,
			)
		}
		cases = append(cases, item)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(cases) == 0 {
		return nil, errors.New("quality calibration corpus is empty")
	}
	return cases, nil
}

func EvaluateQualityCalibrationJSONL(
	ctx context.Context,
	reader io.Reader,
	cfg config.Config,
	client serviceport.Coop,
	options LiveEvaluationOptions,
) (EvaluationSummary, error) {
	cases, err := decodeQualityCalibrationCases(reader)
	if err != nil {
		return EvaluationSummary{}, err
	}
	if options.CaseTimeout <= 0 {
		options.CaseTimeout = 10 * time.Minute
	}
	if options.PollInterval <= 0 {
		options.PollInterval = 500 * time.Millisecond
	}
	if options.CleanupTimeout <= 0 {
		options.CleanupTimeout = 30 * time.Second
	}
	runID, err := core.NewID("judgecal")
	if err != nil {
		return EvaluationSummary{}, err
	}
	encoded, _ := json.Marshal(cases)
	summary := EvaluationSummary{
		Mode:         "quality_calibration",
		CorpusDigest: evaluationBytesDigest(encoded),
	}
	started := time.Now()
	for index, item := range cases {
		if options.CaseFilter != "" &&
			!strings.Contains(
				strings.ToLower(item.Name),
				strings.ToLower(options.CaseFilter),
			) {
			continue
		}
		testCase := EvaluationCase{
			Name:               item.Name,
			Kind:               "watch",
			Lane:               item.Lane,
			Input:              item.Input,
			Repository:         core.FirstNonempty(item.Repository, cfg.Slack.DefaultRepository),
			RecentMessages:     item.RecentMessages,
			ReplyPlacement:     item.ReplyPlacement,
			WantReplyPlacement: item.WantReplyPlacement,
		}
		if options.Progress != nil {
			options.Progress(item.Name, "running")
		}
		caseCtx, cancel := context.WithTimeout(ctx, options.CaseTimeout)
		quality, calls, runErr := runQualityEvaluation(
			caseCtx,
			cfg,
			client,
			testCase,
			item.Response,
			fmt.Sprintf("%s_%d", runID, index+1),
			options,
		)
		cancel()
		summary.ModelCalls += calls
		result := EvaluationResult{
			Name:     item.Name,
			CaseName: item.Name,
			Quality:  quality,
		}
		if runErr != nil {
			result.Detail = runErr.Error()
		} else {
			switch {
			case quality.Passed != item.WantPass:
				result.Detail = fmt.Sprintf(
					"judge pass = %t, want %t: %s",
					quality.Passed,
					item.WantPass,
					quality.Reason,
				)
			case item.MinMeanScore > 0 &&
				quality.MeanScore < item.MinMeanScore:
				result.Detail = fmt.Sprintf(
					"judge score %.2f is below %.2f",
					quality.MeanScore,
					item.MinMeanScore,
				)
			case item.MaxMeanScore > 0 &&
				quality.MeanScore > item.MaxMeanScore:
				result.Detail = fmt.Sprintf(
					"judge score %.2f exceeds %.2f",
					quality.MeanScore,
					item.MaxMeanScore,
				)
			case item.WantCritical &&
				len(quality.CriticalFailures) == 0:
				result.Detail = "judge did not identify a required critical failure"
			default:
				result.Passed = true
			}
		}
		summary.Total++
		if result.Passed {
			summary.Passed++
		} else {
			summary.Failed++
		}
		summary.Results = append(summary.Results, result)
		if options.Progress != nil {
			state := "passed"
			if !result.Passed {
				state = "failed"
			}
			options.Progress(item.Name, state)
		}
	}
	if summary.Total == 0 {
		return summary, fmt.Errorf(
			"no quality calibration case matches %q",
			options.CaseFilter,
		)
	}
	summary.DurationMS = time.Since(started).Milliseconds()
	summarizeEvaluation(&summary)
	return summary, nil
}
