package service

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

type EvaluationScenario struct {
	Name       string                   `json:"name"`
	Tags       []string                 `json:"tags,omitempty"`
	Repository string                   `json:"repository,omitempty"`
	Seeds      []EvaluationScenarioSeed `json:"seeds,omitempty"`
	Steps      []EvaluationScenarioStep `json:"steps"`
}

type EvaluationScenarioSeed struct {
	Channel     string           `json:"channel"`
	ChannelName string           `json:"channel_name,omitempty"`
	Thread      string           `json:"thread,omitempty"`
	Repository  string           `json:"repository,omitempty"`
	Memory      core.AgentMemory `json:"memory"`
}

type EvaluationScenarioStep struct {
	Name              string              `json:"name"`
	Channel           string              `json:"channel"`
	ChannelName       string              `json:"channel_name,omitempty"`
	Thread            string              `json:"thread,omitempty"`
	Input             string              `json:"input"`
	SenderType        string              `json:"sender_type,omitempty"`
	SenderRole        string              `json:"sender_role,omitempty"`
	MentionsResponder bool                `json:"mentions_responder,omitempty"`
	RecentMessages    []EvaluationMessage `json:"recent_messages,omitempty"`
	FollowingMessages []EvaluationMessage `json:"following_messages,omitempty"`
	RestartBefore     bool                `json:"restart_before,omitempty"`
	Expect            EvaluationCase      `json:"expect"`
}

type scenarioConversation struct {
	Channel     string                `json:"channel"`
	ChannelName string                `json:"channel_name,omitempty"`
	Thread      string                `json:"thread,omitempty"`
	Repository  string                `json:"repository"`
	Memory      core.AgentMemory      `json:"memory,omitempty"`
	History     []watchContextMessage `json:"history,omitempty"`
	Answered    bool                  `json:"answered,omitempty"`
	UpdatedAt   time.Time             `json:"updated_at"`
}

func decodeEvaluationScenarios(reader io.Reader) ([]EvaluationScenario, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), 2<<20)
	var scenarios []EvaluationScenario
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var scenario EvaluationScenario
		decoder := json.NewDecoder(strings.NewReader(line))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&scenario); err != nil {
			return nil, fmt.Errorf(
				"decode evaluation scenario %d: %w",
				len(scenarios)+1,
				err,
			)
		}
		if strings.TrimSpace(scenario.Name) == "" {
			return nil, fmt.Errorf(
				"evaluation scenario %d has no name",
				len(scenarios)+1,
			)
		}
		if len(scenario.Steps) < 2 {
			return nil, fmt.Errorf(
				"evaluation scenario %q must contain at least two steps",
				scenario.Name,
			)
		}
		for index, step := range scenario.Steps {
			if strings.TrimSpace(step.Name) == "" ||
				strings.TrimSpace(step.Channel) == "" ||
				strings.TrimSpace(step.Input) == "" {
				return nil, fmt.Errorf(
					"evaluation scenario %q step %d requires name, channel, and input",
					scenario.Name,
					index+1,
				)
			}
			if err := validateEvaluationCase(step.Expect); err != nil {
				return nil, fmt.Errorf(
					"evaluation scenario %q step %q: %w",
					scenario.Name,
					step.Name,
					err,
				)
			}
		}
		scenarios = append(scenarios, scenario)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(scenarios) == 0 {
		return nil, errors.New("evaluation scenario corpus is empty")
	}
	return scenarios, nil
}

func EvaluateLiveScenariosJSONL(
	ctx context.Context,
	reader io.Reader,
	cfg config.Config,
	client CoopAPI,
	options LiveEvaluationOptions,
) (EvaluationSummary, error) {
	scenarios, err := decodeEvaluationScenarios(reader)
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
	if options.Repeat <= 0 {
		options.Repeat = 1
	}
	scenarios = filterEvaluationScenarios(scenarios, options.CaseFilter)
	if len(scenarios) == 0 {
		return EvaluationSummary{}, fmt.Errorf(
			"no evaluation scenario matches %q",
			options.CaseFilter,
		)
	}
	runID, err := core.NewID("scenario")
	if err != nil {
		return EvaluationSummary{}, err
	}
	encoded, _ := json.Marshal(scenarios)
	summary := EvaluationSummary{
		Mode:         "scenario",
		CorpusDigest: evaluationBytesDigest(encoded),
	}
	started := time.Now()
	ordinal := 0
	for _, scenario := range scenarios {
		for repetition := 1; repetition <= options.Repeat; repetition++ {
			ordinal++
			scenarioID := fmt.Sprintf("%s_%d", runID, ordinal)
			results, calls, runErr := runLiveEvaluationScenario(
				ctx,
				cfg,
				client,
				scenario,
				scenarioID,
				repetition,
				options,
			)
			summary.ModelCalls += calls
			if runErr != nil {
				return summary, fmt.Errorf(
					"scenario %q: %w",
					scenario.Name,
					runErr,
				)
			}
			for index, result := range results {
				summary.Total++
				if result.Passed {
					summary.Passed++
				} else {
					summary.Failed++
				}
				summary.Results = append(summary.Results, result)
				if index < len(scenario.Steps) {
					updateProactivity(
						&summary.Proactivity,
						scenario.Steps[index].Expect.ProactiveLabel,
						result.Action,
					)
				}
			}
		}
	}
	summary.DurationMS = time.Since(started).Milliseconds()
	summarizeEvaluation(&summary)
	return summary, nil
}

func filterEvaluationScenarios(
	scenarios []EvaluationScenario,
	filter string,
) []EvaluationScenario {
	filter = strings.ToLower(strings.TrimSpace(filter))
	if filter == "" {
		return scenarios
	}
	var result []EvaluationScenario
	for _, scenario := range scenarios {
		if strings.Contains(strings.ToLower(scenario.Name), filter) {
			result = append(result, scenario)
			continue
		}
		for _, tag := range scenario.Tags {
			if strings.Contains(strings.ToLower(tag), filter) {
				result = append(result, scenario)
				break
			}
		}
	}
	return result
}

func runLiveEvaluationScenario(
	ctx context.Context,
	cfg config.Config,
	client CoopAPI,
	scenario EvaluationScenario,
	scenarioID string,
	repetition int,
	options LiveEvaluationOptions,
) ([]EvaluationResult, int, error) {
	repositoryKey := core.FirstNonempty(
		strings.TrimSpace(scenario.Repository),
		cfg.Slack.DefaultRepository,
	)
	repository, ok := cfg.RepositoryContext(repositoryKey)
	if !ok {
		return nil, 0, fmt.Errorf("repository %q is not configured", repositoryKey)
	}
	session, _, err := client.CreateSession(
		ctx,
		"responder:scenario-session:"+scenarioID,
		repository.CoopPolicy,
		"Responder stateful evaluation: "+truncateWatchText(scenario.Name, 160),
	)
	if err != nil {
		return nil, 0, err
	}
	sessionID := session.ID
	conversations := make(map[string]*scenarioConversation)
	for _, seed := range scenario.Seeds {
		key := scenarioConversationKey(seed.Channel, seed.Thread)
		conversations[key] = &scenarioConversation{
			Channel:     seed.Channel,
			ChannelName: seed.ChannelName,
			Thread:      seed.Thread,
			Repository:  core.FirstNonempty(seed.Repository, repositoryKey),
			Memory:      seed.Memory,
			UpdatedAt:   time.Now().UTC().Add(-time.Hour),
		}
	}
	var results []EvaluationResult
	modelCalls := 0
	for index, step := range scenario.Steps {
		name := scenario.Name + " / " + step.Name
		if options.Repeat > 1 {
			name += fmt.Sprintf(" [%d/%d]", repetition, options.Repeat)
		}
		if options.Progress != nil {
			options.Progress(name, "running")
		}
		if step.RestartBefore {
			encoded, marshalErr := json.Marshal(conversations)
			if marshalErr != nil {
				return results, modelCalls, marshalErr
			}
			reloaded := make(map[string]*scenarioConversation)
			if unmarshalErr := json.Unmarshal(encoded, &reloaded); unmarshalErr != nil {
				return results, modelCalls, unmarshalErr
			}
			conversations = reloaded
			session, err = client.GetSession(ctx, sessionID)
			if err != nil {
				return results, modelCalls, fmt.Errorf(
					"reconnect scenario after restart: %w",
					err,
				)
			}
		}
		testCase := step.Expect
		testCase.Name = name
		testCase.Kind = "watch"
		testCase.Input = step.Input
		testCase.Repository = repositoryKey
		testCase.SenderType = step.SenderType
		testCase.SenderRole = step.SenderRole
		testCase.MentionsResponder = step.MentionsResponder
		testCase.RecentMessages = step.RecentMessages
		testCase.FollowingMessages = step.FollowingMessages
		caseID := fmt.Sprintf("%s_%d", scenarioID, index+1)
		prompt, input, current, promptErr := liveScenarioPrompt(
			cfg,
			testCase,
			step,
			caseID,
			conversations,
		)
		if promptErr != nil {
			return results, modelCalls, promptErr
		}
		caseCtx, cancel := context.WithTimeout(ctx, options.CaseTimeout)
		response, turnID, calls, waitErr := runEvaluationTurnWithRetry(
			caseCtx,
			client,
			sessionID,
			"responder:scenario-turn:"+caseID,
			prompt,
			options.PollInterval,
		)
		modelCalls += calls
		cancel()
		result := EvaluationResult{
			Name:       name,
			CaseName:   scenario.Name + " / " + step.Name,
			Repetition: repetition,
		}
		if options.SanitizeResponse != nil {
			result.Response = options.SanitizeResponse(response)
		} else {
			result.Response = response
		}
		if waitErr != nil {
			result.Detail = "model call: " + waitErr.Error()
		} else {
			result.Lifecycle = assessEvaluationLifecycle(
				ctx,
				client,
				sessionID,
				turnID,
				1,
			)
			testCase.Output = response
			scored := evaluateCaseWithConfig(testCase, &cfg, time.Now().UTC())
			result.Passed = scored.Passed
			result.Detail = scored.Detail
			if !result.Lifecycle.Passed {
				result.Passed = false
				result.Detail = appendEvaluationFailure(
					result.Detail,
					"turn lifecycle: "+
						strings.Join(result.Lifecycle.Issues, "; "),
				)
			}
			rendered, action, renderErr := renderEvaluationMessage(
				cfg,
				testCase,
				response,
			)
			result.Action = action
			if renderErr != nil {
				result.Passed = false
				result.Detail = appendEvaluationFailure(
					result.Detail,
					"Slack render: "+renderErr.Error(),
				)
			} else {
				result.SlackUX = assessSlackUX(rendered, action)
				if !result.SlackUX.Passed {
					result.Passed = false
					result.Detail = appendEvaluationFailure(
						result.Detail,
						"Slack UX: "+strings.Join(result.SlackUX.Issues, "; "),
					)
				}
				if options.Judge || testCase.Judge {
					quality, calls, qualityErr := runQualityEvaluation(
						ctx,
						cfg,
						client,
						testCase,
						rendered,
						caseID,
						options,
					)
					modelCalls += calls
					result.Quality = quality
					if qualityErr != nil || !quality.Passed {
						result.Passed = false
						detail := quality.Reason
						if qualityErr != nil {
							detail = qualityErr.Error()
						}
						result.Detail = appendEvaluationFailure(
							result.Detail,
							"quality judge: "+detail,
						)
					}
				}
			}
			decision, parseErr := parseWatchDecision(response, time.Now().UTC())
			if parseErr == nil {
				current.Memory = decision.Memory
				current.Answered = decision.Action == "reply"
				current.UpdatedAt = time.Now().UTC()
				current.History = append(
					current.History,
					watchPromptMessage(input, "UEVALBOT", true),
				)
				if decision.Action == "reply" {
					current.History = append(current.History, watchContextMessage{
						MessageTS: fmt.Sprintf(
							"1800.%06d",
							len(current.History)+1,
						),
						ThreadTS:   current.Thread,
						SenderID:   "UEVALBOT",
						SenderType: "responder",
						Text:       truncateWatchText(decision.Message, watchContextTextLimit),
					})
				}
			}
		}
		session, err = client.GetSession(ctx, sessionID)
		if err != nil {
			return results, modelCalls, err
		}
		results = append(results, result)
		if options.Progress != nil {
			state := "passed"
			if !result.Passed {
				state = "failed"
			}
			options.Progress(name, state)
		}
	}
	cleanupCtx, cancel := context.WithTimeout(
		context.Background(),
		options.CleanupTimeout,
	)
	cleanupErr := cleanupLiveEvaluationSession(
		cleanupCtx,
		client,
		sessionID,
		scenarioID,
		options.PollInterval,
		false,
	)
	cancel()
	if cleanupErr != nil {
		return results, modelCalls, cleanupErr
	}
	return results, modelCalls, nil
}

func liveScenarioPrompt(
	cfg config.Config,
	testCase EvaluationCase,
	step EvaluationScenarioStep,
	caseID string,
	conversations map[string]*scenarioConversation,
) (string, core.SlackInput, *scenarioConversation, error) {
	operatorID := "UEVALOPERATOR"
	if len(cfg.Slack.Operators) > 0 {
		operatorID = cfg.Slack.Operators[0]
	}
	input, recent, err := liveEvaluationWatchContext(
		testCase,
		caseID,
		operatorID,
	)
	if err != nil {
		return "", core.SlackInput{}, nil, err
	}
	input.ChannelID = step.Channel
	input.ThreadTS = step.Thread
	for index := range recent {
		recent[index].ThreadTS = step.Thread
	}
	key := scenarioConversationKey(step.Channel, step.Thread)
	current := conversations[key]
	if current == nil {
		current = &scenarioConversation{
			Channel:     step.Channel,
			ChannelName: step.ChannelName,
			Thread:      step.Thread,
			Repository:  testCase.Repository,
		}
		conversations[key] = current
	}
	history := append([]watchContextMessage(nil), current.History...)
	history = append(history, recent...)
	if len(history) > cfg.Slack.WatchContext {
		history = history[len(history)-cfg.Slack.WatchContext:]
	}
	var related []conversationSituationContext
	for otherKey, item := range conversations {
		if otherKey == key || memoryEmpty(item.Memory) {
			continue
		}
		relationship := "workspace"
		if item.Repository == current.Repository {
			relationship = "same_repository"
		}
		related = append(related, conversationSituationContext{
			ChannelID:    item.Channel,
			ChannelName:  item.ChannelName,
			ThreadTS:     item.Thread,
			Repository:   item.Repository,
			Relationship: relationship,
			Summary:      sanitizeMemory(item.Memory),
			UpdatedAt:    item.UpdatedAt.UTC().Format(time.RFC3339),
		})
	}
	evaluator := &Service{cfg: cfg}
	episode := evaluator.episodeForWatchedInput(input, watchTurnState{})
	return evaluator.watchPrompt(
		input,
		"UEVALBOT",
		current.Answered,
		history,
		current.Memory,
		related,
		nil,
		operationalMemoryContext{},
		testCase.Repository,
		nil,
	) + "\n\n" + workEpisodePrompt(*episode), input, current, nil
}

func scenarioConversationKey(channel string, thread string) string {
	return channel + "\x00" + thread
}

func memoryEmpty(memory core.AgentMemory) bool {
	encoded, _ := json.Marshal(memory)
	return string(encoded) == "{}"
}

func waitEvaluationTurn(
	ctx context.Context,
	client CoopAPI,
	sessionID string,
	turnID string,
	pollInterval time.Duration,
) (string, error) {
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		current, err := client.GetTurn(ctx, sessionID, turnID)
		if err != nil {
			return "", err
		}
		switch current.State {
		case "completed":
			return current.AssistantMessage, nil
		case "failed", "cancelled":
			return current.AssistantMessage, errors.New(core.FirstNonempty(
				current.ErrorDetail,
				current.ErrorCode,
				current.StopReason,
				current.State,
			))
		}
		select {
		case <-ctx.Done():
			return current.AssistantMessage, ctx.Err()
		case <-ticker.C:
		}
	}
}

func runEvaluationTurnWithRetry(
	ctx context.Context,
	client CoopAPI,
	sessionID string,
	idempotencyKey string,
	prompt string,
	pollInterval time.Duration,
) (string, string, int, error) {
	var response string
	var turnID string
	modelCalls := 0
	for attempt := 0; attempt < 3; attempt++ {
		session, err := client.GetSession(ctx, sessionID)
		if err != nil {
			return response, turnID, modelCalls, err
		}
		key := idempotencyKey
		if attempt > 0 {
			key = fmt.Sprintf("%s:cleanup-retry:%d", idempotencyKey, attempt)
		}
		turn, _, err := client.SubmitTurn(
			ctx,
			key,
			sessionID,
			session.Revision,
			prompt,
		)
		if err != nil {
			return response, turnID, modelCalls, err
		}
		modelCalls++
		turnID = turn.ID
		if turnID == "" {
			return response, turnID, modelCalls, errors.New(
				"Coop returned an empty evaluation turn ID",
			)
		}
		response, err = waitEvaluationTurn(
			ctx,
			client,
			sessionID,
			turnID,
			pollInterval,
		)
		if err == nil {
			return response, turnID, modelCalls, nil
		}
		if attempt == 2 ||
			!strings.Contains(strings.ToLower(err.Error()), "turn cleanup failed") {
			return response, turnID, modelCalls, err
		}
	}
	return response, turnID, modelCalls, errors.New(
		"evaluation turn cleanup retry exhausted",
	)
}

func evaluationBytesDigest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
