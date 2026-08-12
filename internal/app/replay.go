package app

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const slackReplayPollInterval = 250 * time.Millisecond

var errSlackReplaySourceNotFound = errors.New("saved Slack replay source not found")

type slackReplayResult struct {
	SourceInputID string                `json:"source_input_id"`
	ReplayInputID string                `json:"replay_input_id"`
	AgentRunID    string                `json:"agent_run_id"`
	Published     bool                  `json:"published"`
	Action        string                `json:"action"`
	InputState    string                `json:"input_state"`
	RunState      core.AgentRunState    `json:"run_state"`
	Deliveries    []slackReplayDelivery `json:"deliveries"`
	Duration      time.Duration         `json:"duration"`
}

type slackReplayDelivery struct {
	ID        string                    `json:"id"`
	Operation string                    `json:"operation"`
	State     string                    `json:"state"`
	ChannelID string                    `json:"channel_id"`
	ThreadTS  string                    `json:"thread_ts,omitempty"`
	MessageTS string                    `json:"message_ts,omitempty"`
	SlackUX   service.SlackUXAssessment `json:"slack_ux,omitempty"`
}

func runReplay(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 || args[0] != "slack" {
		return errors.New("usage: responder replay slack [options]")
	}
	flags := flag.NewFlagSet("replay slack", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	inputID := flags.String("input", "", "saved Slack input ID")
	permalink := flags.String("url", "", "Slack message permalink")
	channelID := flags.String("channel", "", "Slack channel ID")
	messageTS := flags.String("message-ts", "", "Slack message timestamp")
	expect := flags.String("expect", "reply", "expected action: reply, react, ignore, incident, or any")
	publish := flags.Bool("publish", false, "publish the replay result to Slack (default: private verification only)")
	timeout := flags.Duration("timeout", 20*time.Minute, "maximum time to await the live result")
	jsonOutput := flags.Bool("json", false, "print JSON")
	if err := flags.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("replay slack accepts no positional arguments")
	}
	if *timeout <= 0 {
		return errors.New("replay timeout must be positive")
	}
	if !validReplayExpectation(*expect) {
		return fmt.Errorf("unsupported replay expectation %q", *expect)
	}
	selectorCount := 0
	if strings.TrimSpace(*inputID) != "" {
		selectorCount++
	}
	if strings.TrimSpace(*permalink) != "" {
		selectorCount++
	}
	if strings.TrimSpace(*channelID) != "" || strings.TrimSpace(*messageTS) != "" {
		if strings.TrimSpace(*channelID) == "" || strings.TrimSpace(*messageTS) == "" {
			return errors.New("replay requires both --channel and --message-ts")
		}
		selectorCount++
	}
	if selectorCount != 1 {
		return errors.New("select exactly one source with --input, --url, or --channel and --message-ts")
	}
	if strings.TrimSpace(*permalink) != "" {
		var err error
		*channelID, *messageTS, err = parseSlackPermalink(*permalink)
		if err != nil {
			return err
		}
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	if err := requireRunningResponder(cfg.StateDir); err != nil {
		return err
	}
	st, err := store.OpenLive(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	source, err := findSlackReplaySource(
		ctx, st, strings.TrimSpace(*inputID), strings.TrimSpace(*channelID),
		strings.TrimSpace(*messageTS),
	)
	if errors.Is(err, errSlackReplaySourceNotFound) && strings.TrimSpace(*inputID) == "" {
		source, err = fetchSlackReplaySource(
			ctx, cfg, strings.TrimSpace(*channelID), strings.TrimSpace(*messageTS),
		)
	}
	if err != nil {
		return err
	}
	replay, err := cloneSlackReplay(source, *publish)
	if err != nil {
		return err
	}
	created, err := st.AdmitSlackInput(ctx, replay)
	if err != nil {
		return err
	}
	if !created {
		return errors.New("the generated Slack replay identity already exists")
	}
	if !*jsonOutput {
		fmt.Fprintf(
			stdout,
			"Reprocessing Slack input %s as %s through the running Responder in %s mode; waiting for %s.\n",
			source.ID,
			replay.ID,
			replayModeName(*publish),
			*expect,
		)
	}
	started := time.Now()
	result, err := waitForSlackReplay(ctx, st, source.ID, replay.ID, *expect, *publish)
	if err != nil {
		return err
	}
	result.Duration = time.Since(started).Round(time.Millisecond)
	if *jsonOutput {
		return json.NewEncoder(stdout).Encode(result)
	}
	fmt.Fprintf(
		stdout,
		"Verified Slack replay %s: mode=%s, action=%s, run=%s, input=%s, deliveries=%d, duration=%s.\n",
		result.ReplayInputID,
		replayModeName(result.Published),
		result.Action,
		result.RunState,
		result.InputState,
		len(result.Deliveries),
		result.Duration,
	)
	for _, delivery := range result.Deliveries {
		fmt.Fprintf(
			stdout,
			"  %s %s sent to %s (thread=%s message=%s ux=%s)\n",
			delivery.ID,
			delivery.Operation,
			delivery.ChannelID,
			displayOr(delivery.ThreadTS, "channel"),
			delivery.MessageTS,
			displayOr(replayUXState(delivery.SlackUX), "not-applicable"),
		)
	}
	return nil
}

func requireRunningResponder(stateDir string) error {
	lock, err := acquireProcessLock(stateDir)
	if err == nil {
		releaseProcessLock(lock)
		return errors.New("Responder is not running; start serve before replaying Slack input")
	}
	if errors.Is(err, errProcessLocked) {
		return nil
	}
	return fmt.Errorf("verify running Responder: %w", err)
}

func findSlackReplaySource(
	ctx context.Context,
	st *store.Store,
	inputID string,
	channelID string,
	messageTS string,
) (core.SlackInput, error) {
	var (
		input core.SlackInput
		err   error
	)
	if inputID != "" {
		input, err = st.GetSlackInput(ctx, inputID)
	} else {
		input, err = st.GetSlackInputForMessage(ctx, channelID, messageTS)
	}
	if errors.Is(err, store.ErrNotFound) {
		return core.SlackInput{}, errSlackReplaySourceNotFound
	}
	if err != nil {
		return core.SlackInput{}, err
	}
	switch input.Kind {
	case "message", "mention", "direct", "bot_message":
		return input, nil
	default:
		return core.SlackInput{}, fmt.Errorf(
			"Slack input %s is %q; only saved messages can be replayed",
			input.ID,
			input.Kind,
		)
	}
}

func fetchSlackReplaySource(
	ctx context.Context,
	cfg config.Config,
	channelID string,
	messageTS string,
) (core.SlackInput, error) {
	token := strings.TrimSpace(os.Getenv(cfg.Slack.BotTokenEnv))
	if token == "" {
		return core.SlackInput{}, fmt.Errorf(
			"saved Slack input expired and %s is unavailable for live history lookup",
			cfg.Slack.BotTokenEnv,
		)
	}
	history, err := slackui.New(token, "").RecentMessages(
		ctx, channelID, "", messageTS, messageTS, 10,
	)
	if err != nil {
		return core.SlackInput{}, fmt.Errorf("fetch Slack replay source: %w", err)
	}
	for _, message := range history {
		if message.Timestamp == messageTS {
			return slackReplaySourceFromHistory(cfg.Slack.TeamID, channelID, message), nil
		}
	}
	return core.SlackInput{}, errors.New(
		"Slack message was not found in local retention or accessible Slack history",
	)
}

func slackReplaySourceFromHistory(
	teamID string,
	channelID string,
	message slackui.HistoryMessage,
) core.SlackInput {
	kind := "message"
	userID := message.UserID
	if message.BotID != "" {
		kind = "bot_message"
		if userID == "" {
			userID = message.BotID
		}
	}
	attachments := make([]core.SlackAttachment, 0, len(message.Files))
	for _, file := range message.Files {
		attachments = append(attachments, core.SlackAttachment{
			ID: file.ID, Name: file.Name, MediaType: file.MediaType,
			Size: file.Size, URLPrivate: file.URLPrivate,
		})
	}
	reactions := make([]core.SlackReaction, 0, len(message.Reactions))
	for _, reaction := range message.Reactions {
		reactions = append(reactions, core.SlackReaction{
			Name: reaction.Name, Count: reaction.Count,
			UserIDs: append([]string(nil), reaction.UserIDs...),
		})
	}
	return core.SlackInput{
		ID:   "slack_history:" + channelID + ":" + message.Timestamp,
		Kind: kind, TeamID: teamID, ChannelID: channelID,
		ThreadTS: message.ThreadTS, MessageTS: message.Timestamp,
		UserID: userID, Text: message.Text, Attachments: attachments,
		Reactions: reactions, ReceivedAt: time.Now().UTC(),
	}
}

func cloneSlackReplay(source core.SlackInput, publish bool) (core.SlackInput, error) {
	id, err := core.NewID("slack_replay")
	if err != nil {
		return core.SlackInput{}, err
	}
	prefix := "replay-private:"
	if publish {
		prefix = "replay-public:"
	}
	return core.SlackInput{
		ID:          id,
		EnvelopeID:  prefix + id,
		EventID:     prefix + id,
		Kind:        source.Kind,
		TeamID:      source.TeamID,
		ChannelID:   source.ChannelID,
		ThreadTS:    source.ThreadTS,
		MessageTS:   source.MessageTS,
		UserID:      source.UserID,
		Text:        source.Text,
		Attachments: append([]core.SlackAttachment(nil), source.Attachments...),
		Reactions:   append([]core.SlackReaction(nil), source.Reactions...),
		ReceivedAt:  time.Now().UTC(),
	}, nil
}

func waitForSlackReplay(
	ctx context.Context,
	st *store.Store,
	sourceID string,
	replayID string,
	expectedAction string,
	publish bool,
) (slackReplayResult, error) {
	ticker := time.NewTicker(slackReplayPollInterval)
	defer ticker.Stop()
	var lastRun core.AgentRun
	var lastInput core.SlackInput
	for {
		input, inputErr := st.GetSlackInput(ctx, replayID)
		if inputErr == nil {
			lastInput = input
			if input.State == "failed" {
				return slackReplayResult{}, fmt.Errorf(
					"Slack replay %s failed before completion", replayID,
				)
			}
		} else if !errors.Is(inputErr, store.ErrNotFound) {
			return slackReplayResult{}, inputErr
		}
		run, runErr := st.GetAgentRunBySource(ctx, "watch", replayID)
		if runErr == nil {
			lastRun = run
			switch run.State {
			case core.AgentRunFailed, core.AgentRunCancelled, core.AgentRunSuperseded:
				return slackReplayResult{}, fmt.Errorf(
					"Slack replay %s ended as %s: %s",
					replayID,
					run.State,
					displayOr(run.LastError, "no detail"),
				)
			case core.AgentRunCompleted:
				action, err := effectiveReplayAction(ctx, st, replayID, run.Result, publish)
				if err != nil {
					return slackReplayResult{}, fmt.Errorf("verify Slack replay result: %w", err)
				}
				if expectedAction != "any" && action != expectedAction {
					return slackReplayResult{}, fmt.Errorf(
						"Slack replay action was %q, want %q",
						action,
						expectedAction,
					)
				}
				if lastInput.State != "done" {
					break
				}
				var deliveries []core.SlackDelivery
				if publish {
					deliveries, err = st.ListSlackDeliveriesByPrefix(ctx, "watch_reply_"+replayID)
					if err != nil {
						return slackReplayResult{}, err
					}
				}
				if publish && action == "reply" {
					if len(deliveries) == 0 {
						break
					}
					pending := false
					for _, delivery := range deliveries {
						switch delivery.State {
						case "sent":
						case "failed", "superseded":
							return slackReplayResult{}, fmt.Errorf(
								"Slack replay delivery %s ended as %s: %s",
								delivery.ID,
								delivery.State,
								displayOr(delivery.LastError, "no detail"),
							)
						default:
							pending = true
						}
					}
					if pending {
						break
					}
				}
				result := slackReplayResult{
					SourceInputID: sourceID,
					ReplayInputID: replayID,
					AgentRunID:    run.ID,
					Published:     publish,
					Action:        action,
					InputState:    lastInput.State,
					RunState:      run.State,
					Deliveries:    make([]slackReplayDelivery, 0, len(deliveries)),
				}
				for _, delivery := range deliveries {
					var ux service.SlackUXAssessment
					if delivery.Operation == "post" || delivery.Operation == "update" {
						ux, err = service.AssessSlackDeliveryUX(delivery.Body, action)
						if err != nil {
							return slackReplayResult{}, fmt.Errorf(
								"verify Slack replay delivery %s: %w",
								delivery.ID,
								err,
							)
						}
					}
					result.Deliveries = append(result.Deliveries, slackReplayDelivery{
						ID: delivery.ID, Operation: delivery.Operation,
						State: delivery.State, ChannelID: delivery.ChannelID,
						ThreadTS: delivery.ThreadTS, MessageTS: delivery.MessageTS,
						SlackUX: ux,
					})
				}
				return result, nil
			}
		} else if !errors.Is(runErr, store.ErrNotFound) {
			return slackReplayResult{}, runErr
		}

		select {
		case <-ctx.Done():
			return slackReplayResult{}, fmt.Errorf(
				"Slack replay %s timed out: input=%s run=%s: %w",
				replayID,
				displayOr(lastInput.State, "not started"),
				displayOr(string(lastRun.State), "not queued"),
				ctx.Err(),
			)
		case <-ticker.C:
		}
	}
}

func effectiveReplayAction(
	ctx context.Context,
	st *store.Store,
	replayID string,
	result []byte,
	publish bool,
) (string, error) {
	if !publish {
		decision, err := st.Intelligence.GetEvaluationDecision(ctx, replayID, "private_replay")
		switch {
		case err == nil:
			return decision.Action, nil
		case !errors.Is(err, store.ErrNotFound):
			return "", err
		}
	}
	return replayAction(result)
}

func replayModeName(publish bool) string {
	if publish {
		return "published"
	}
	return "private"
}

func replayUXState(assessment service.SlackUXAssessment) string {
	if !assessment.Evaluated {
		return ""
	}
	if assessment.Passed {
		return "passed"
	}
	return "failed"
}

func replayAction(result []byte) (string, error) {
	action, err := decision.WatchDecisionAction(string(result))
	if err != nil {
		return "", err
	}
	if !validReplayExpectation(action) || action == "any" {
		return "", fmt.Errorf("agent result has unsupported action %q", action)
	}
	return action, nil
}

func validReplayExpectation(action string) bool {
	switch action {
	case "reply", "react", "ignore", "incident", "any":
		return true
	default:
		return false
	}
}

func parseSlackPermalink(raw string) (string, string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return "", "", errors.New("Slack permalink must be an absolute https URL")
	}
	parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	if len(parts) != 3 || parts[0] != "archives" || parts[1] == "" ||
		!strings.HasPrefix(parts[2], "p") {
		return "", "", errors.New("Slack permalink must contain /archives/<channel>/p<timestamp>")
	}
	digits := strings.TrimPrefix(parts[2], "p")
	if len(digits) < 7 {
		return "", "", errors.New("Slack permalink timestamp is invalid")
	}
	for _, char := range digits {
		if char < '0' || char > '9' {
			return "", "", errors.New("Slack permalink timestamp is invalid")
		}
	}
	return parts[1], digits[:len(digits)-6] + "." + digits[len(digits)-6:], nil
}
