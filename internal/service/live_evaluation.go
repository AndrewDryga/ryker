package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

type LiveEvaluationOptions struct {
	CaseTimeout      time.Duration
	PollInterval     time.Duration
	CleanupTimeout   time.Duration
	CaseFilter       string
	Repeat           int
	SanitizeResponse func(string) string
	Progress         func(name string, state string)
}

func EvaluateLiveJSONL(
	ctx context.Context,
	reader io.Reader,
	cfg config.Config,
	client CoopAPI,
	options LiveEvaluationOptions,
) (EvaluationSummary, error) {
	cases, err := decodeEvaluationCases(reader)
	if err != nil {
		return EvaluationSummary{}, err
	}
	if client == nil {
		return EvaluationSummary{}, errors.New("live evaluation requires Coop")
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
	cases = filterEvaluationCases(cases, options.CaseFilter)
	if len(cases) == 0 {
		return EvaluationSummary{}, fmt.Errorf(
			"no evaluation case matches %q",
			options.CaseFilter,
		)
	}
	runID, err := core.NewID("eval")
	if err != nil {
		return EvaluationSummary{}, err
	}
	started := time.Now()
	summary := EvaluationSummary{Mode: "live"}
	ordinal := 0
	for _, testCase := range cases {
		for repetition := 1; repetition <= options.Repeat; repetition++ {
			if err := ctx.Err(); err != nil {
				return summary, err
			}
			ordinal++
			name := testCase.Name
			if options.Repeat > 1 {
				name = fmt.Sprintf("%s [%d/%d]", name, repetition, options.Repeat)
			}
			if options.Progress != nil {
				options.Progress(name, "running")
			}
			caseStarted := time.Now()
			caseID := fmt.Sprintf("%s_%d", runID, ordinal)
			caseCtx, cancel := context.WithTimeout(ctx, options.CaseTimeout)
			response, sessionID, modelCalled, runErr := runLiveEvaluationCase(
				caseCtx,
				cfg,
				client,
				testCase,
				caseID,
				options.PollInterval,
			)
			cancel()
			if modelCalled {
				summary.ModelCalls++
			}

			cleanupCtx, cleanupCancel := context.WithTimeout(
				context.Background(),
				options.CleanupTimeout,
			)
			cleanupErr := cleanupLiveEvaluationSession(
				cleanupCtx,
				client,
				sessionID,
				caseID,
				options.PollInterval,
			)
			cleanupCancel()

			result := EvaluationResult{
				Name:       name,
				DurationMS: time.Since(caseStarted).Milliseconds(),
			}
			if options.SanitizeResponse != nil {
				result.Response = options.SanitizeResponse(response)
			} else {
				result.Response = response
			}
			switch {
			case runErr != nil:
				result.Detail = "model call: " + runErr.Error()
			case cleanupErr != nil:
				result.Detail = "session cleanup: " + cleanupErr.Error()
			default:
				testCase.Output = response
				scored := evaluateCaseWithConfig(
					testCase,
					&cfg,
					time.Now().UTC(),
				)
				result.Passed = scored.Passed
				result.Detail = scored.Detail
				if result.Passed && testCase.MaxDurationMS > 0 &&
					result.DurationMS > testCase.MaxDurationMS {
					result.Passed = false
					result.Detail = fmt.Sprintf(
						"duration = %s, want at most %s",
						time.Duration(result.DurationMS)*time.Millisecond,
						time.Duration(testCase.MaxDurationMS)*time.Millisecond,
					)
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
				options.Progress(name, state)
			}
		}
	}
	summary.DurationMS = time.Since(started).Milliseconds()
	return summary, nil
}

func filterEvaluationCases(
	cases []EvaluationCase,
	filter string,
) []EvaluationCase {
	filter = strings.ToLower(strings.TrimSpace(filter))
	if filter == "" {
		return cases
	}
	result := make([]EvaluationCase, 0, len(cases))
	for _, testCase := range cases {
		if strings.Contains(strings.ToLower(testCase.Name), filter) {
			result = append(result, testCase)
			continue
		}
		for _, tag := range testCase.Tags {
			if strings.Contains(strings.ToLower(tag), filter) {
				result = append(result, testCase)
				break
			}
		}
	}
	return result
}

func runLiveEvaluationCase(
	ctx context.Context,
	cfg config.Config,
	client CoopAPI,
	testCase EvaluationCase,
	caseID string,
	pollInterval time.Duration,
) (string, string, bool, error) {
	if strings.TrimSpace(testCase.Name) == "" {
		return "", "", false, errors.New("case has no name")
	}
	if strings.TrimSpace(testCase.Input) == "" {
		return "", "", false, errors.New("live case has no input")
	}
	repositoryKey := strings.TrimSpace(testCase.Repository)
	if repositoryKey == "" {
		repositoryKey = cfg.Slack.DefaultRepository
	}
	repository, ok := cfg.RepositoryContext(repositoryKey)
	if !ok {
		return "", "", false, fmt.Errorf("repository %q is not configured", repositoryKey)
	}
	if strings.TrimSpace(repository.CoopPolicy) == "" {
		return "", "", false, fmt.Errorf("repository %q has no Coop policy", repositoryKey)
	}
	session, _, err := client.CreateSession(
		ctx,
		"responder:live-eval-session:"+caseID,
		repository.CoopPolicy,
		"Responder live model evaluation: "+truncateWatchText(testCase.Name, 160),
	)
	if err != nil {
		return "", "", false, err
	}
	sessionID := session.ID
	if sessionID == "" {
		return "", "", false, errors.New("Coop returned an empty live evaluation session ID")
	}
	session, err = client.GetSession(ctx, sessionID)
	if err != nil {
		return "", sessionID, false, err
	}
	if session.State != "open" || session.ActiveTurnID != "" {
		return "", sessionID, false, fmt.Errorf(
			"new live evaluation session is %q with active turn %q",
			session.State,
			session.ActiveTurnID,
		)
	}
	prompt, err := liveEvaluationPrompt(cfg, testCase, repositoryKey, caseID)
	if err != nil {
		return "", sessionID, false, err
	}
	turn, _, err := client.SubmitTurn(
		ctx,
		"responder:live-eval-turn:"+caseID,
		sessionID,
		session.Revision,
		prompt,
	)
	if err != nil {
		return "", sessionID, false, err
	}
	if turn.ID == "" {
		return "", sessionID, true, errors.New("Coop returned an empty live evaluation turn ID")
	}
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		current, err := client.GetTurn(ctx, sessionID, turn.ID)
		if err != nil {
			return "", sessionID, true, err
		}
		switch current.State {
		case "completed":
			return current.AssistantMessage, sessionID, true, nil
		case "failed", "cancelled":
			detail := strings.TrimSpace(
				firstNonempty(current.ErrorDetail, current.ErrorCode, current.StopReason),
			)
			if detail == "" {
				detail = current.State
			}
			return current.AssistantMessage, sessionID, true, errors.New(detail)
		}
		select {
		case <-ctx.Done():
			return current.AssistantMessage, sessionID, true, ctx.Err()
		case <-ticker.C:
		}
	}
}

func liveEvaluationPrompt(
	cfg config.Config,
	testCase EvaluationCase,
	repositoryKey string,
	caseID string,
) (string, error) {
	evaluator := &Service{cfg: cfg}
	switch testCase.Kind {
	case "watch":
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
			return "", err
		}
		prior := operationalMemoryContext{
			Preferences: make(
				[]preferencePromptEntry,
				0,
				len(testCase.Preferences),
			),
		}
		for _, preference := range testCase.Preferences {
			prior.Preferences = append(
				prior.Preferences,
				preferencePromptEntry(preference),
			)
		}
		rules := make([]core.StandingRule, 0, len(testCase.StandingRules))
		for _, rule := range testCase.StandingRules {
			rules = append(rules, core.StandingRule{
				ID: rule.ID, ChannelID: input.ChannelID,
				Repository: rule.Repository, Trigger: rule.Trigger,
				Action: rule.Action, SourceKind: rule.SourceKind, Enabled: true,
			})
		}
		return evaluator.watchPrompt(
			input,
			"UEVALBOT",
			recent,
			core.AgentMemory{},
			prior,
			repositoryKey,
			rules,
		), nil
	case "incident":
		incident := core.Incident{
			ID:         caseID,
			Route:      "evaluation",
			Repository: repositoryKey,
			Title:      testCase.Name,
			Status:     core.IncidentActive,
		}
		signal := core.Signal{
			Route:          "evaluation",
			SourceID:       caseID,
			EventID:        caseID,
			Repository:     repositoryKey,
			CorrelationKey: caseID,
			Status:         core.SignalFiring,
			Title:          testCase.Name,
			Summary:        boundedOperatorText(testCase.Input),
			ReceivedAt:     time.Now().UTC(),
		}
		prompt, err := initialPrompt("", incident, []core.Signal{signal}, "")
		if err != nil {
			return "", err
		}
		return prompt + "\n\n" + evaluator.structuredResponsePolicy(), nil
	default:
		return "", errors.New("live case kind must be watch or incident")
	}
}

func liveEvaluationWatchContext(
	testCase EvaluationCase,
	caseID string,
	operatorID string,
) (core.SlackInput, []watchContextMessage, error) {
	kind := "message"
	userID := operatorID
	switch strings.TrimSpace(testCase.SenderType) {
	case "", "human":
		switch strings.TrimSpace(testCase.SenderRole) {
		case "", "operator":
		case "member":
			userID = "UEVALMEMBER"
		default:
			return core.SlackInput{}, nil, fmt.Errorf(
				"unsupported sender_role %q",
				testCase.SenderRole,
			)
		}
		if testCase.MentionsResponder {
			kind = "mention"
		}
	case "external_app":
		kind = "bot_message"
		userID = "BEVALAPP"
	default:
		return core.SlackInput{}, nil, fmt.Errorf(
			"unsupported sender_type %q", testCase.SenderType,
		)
	}
	text := boundedOperatorText(testCase.Input)
	if testCase.MentionsResponder && !strings.Contains(text, "<@UEVALBOT>") {
		text = "<@UEVALBOT> " + text
	}
	input := core.SlackInput{
		ID:        caseID,
		EventID:   caseID,
		Kind:      kind,
		ChannelID: "CEVALUATION",
		MessageTS: fmt.Sprintf("1700.%06d", len(testCase.RecentMessages)+1),
		UserID:    userID,
		Text:      text,
	}
	recent := make(
		[]watchContextMessage,
		0,
		len(testCase.RecentMessages)+len(testCase.FollowingMessages)+1,
	)
	for index, message := range testCase.RecentMessages {
		item, err := liveEvaluationContextMessage(
			message,
			index+1,
			operatorID,
		)
		if err != nil {
			return core.SlackInput{}, nil, fmt.Errorf("recent message %d: %w", index+1, err)
		}
		recent = append(recent, item)
	}
	recent = append(recent, watchPromptMessage(input, "UEVALBOT", true))
	for index, message := range testCase.FollowingMessages {
		ordinal := len(testCase.RecentMessages) + index + 2
		item, err := liveEvaluationContextMessage(
			message,
			ordinal,
			operatorID,
		)
		if err != nil {
			return core.SlackInput{}, nil, fmt.Errorf(
				"following message %d: %w",
				index+1,
				err,
			)
		}
		recent = append(recent, item)
	}
	return input, recent, nil
}

func liveEvaluationContextMessage(
	message EvaluationMessage,
	ordinal int,
	operatorID string,
) (watchContextMessage, error) {
	senderType := strings.TrimSpace(message.SenderType)
	if senderType == "" {
		senderType = "human"
	}
	senderID := fmt.Sprintf("UEVALUSER%d", ordinal)
	switch senderType {
	case "human":
		switch strings.TrimSpace(message.SenderRole) {
		case "", "member":
		case "operator":
			senderID = operatorID
		default:
			return watchContextMessage{}, fmt.Errorf(
				"unsupported sender_role %q",
				message.SenderRole,
			)
		}
	case "external_app":
		senderID = fmt.Sprintf("BEVALAPP%d", ordinal)
	default:
		return watchContextMessage{}, fmt.Errorf(
			"unsupported sender_type %q",
			message.SenderType,
		)
	}
	return watchContextMessage{
		MessageTS:         fmt.Sprintf("1700.%06d", ordinal),
		SenderID:          senderID,
		SenderType:        senderType,
		Text:              boundedOperatorText(message.Text),
		MentionsResponder: message.MentionsResponder,
	}, nil
}

func cleanupLiveEvaluationSession(
	ctx context.Context,
	client CoopAPI,
	sessionID string,
	caseID string,
	pollInterval time.Duration,
) error {
	if sessionID == "" {
		return nil
	}
	session, err := client.GetSession(ctx, sessionID)
	if err != nil {
		return err
	}
	if session.State == "discarded" {
		return nil
	}
	if session.ActiveTurnID != "" {
		if _, _, err := client.Cancel(
			ctx,
			"responder:live-eval-cancel:"+caseID,
			session.ID,
			session.ActiveTurnID,
			session.Revision,
		); err != nil {
			return fmt.Errorf("cancel active evaluation turn: %w", err)
		}
		ticker := time.NewTicker(pollInterval)
		defer ticker.Stop()
		for session.ActiveTurnID != "" {
			select {
			case <-ctx.Done():
				return fmt.Errorf("wait for evaluation cancellation: %w", ctx.Err())
			case <-ticker.C:
			}
			session, err = client.GetSession(ctx, sessionID)
			if err != nil {
				return err
			}
		}
	}
	if session.State != "closed" {
		session, _, err = client.Close(
			ctx,
			"responder:live-eval-close:"+caseID,
			session.ID,
			session.Revision,
		)
		if err != nil {
			return fmt.Errorf("close evaluation session: %w", err)
		}
	}
	if session.State == "discarded" {
		return nil
	}
	plan, _, err := client.PlanDiscard(
		ctx,
		"responder:live-eval-discard-plan:"+caseID,
		session.ID,
		session.Revision,
		false,
		false,
	)
	if err != nil {
		return fmt.Errorf(
			"prove evaluation workspace is clean before discard: %w",
			err,
		)
	}
	if plan.OperationID == "" {
		return errors.New("Coop returned an empty evaluation discard-plan operation ID")
	}
	if plan.Plan.Workspace.Dirty || plan.Plan.Workspace.Unmerged ||
		plan.Plan.Workspace.Running {
		return fmt.Errorf(
			"evaluation workspace is not clean; retained session %s for inspection",
			session.ID,
		)
	}
	if _, _, err := client.Discard(
		ctx,
		"responder:live-eval-discard:"+caseID,
		session.ID,
		plan.OperationID,
	); err != nil {
		return fmt.Errorf("discard evaluation session: %w", err)
	}
	return nil
}
