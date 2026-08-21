// Package operatorchoice owns the durable meaning of a Slack choice button.
// A press resumes the exact episode that rendered it and rewrites that asking
// as its decision record; presentation and worker scheduling remain outside.
package operatorchoice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/taskprompt"
)

type Result struct {
	EpisodeID string
	Outcome   string
	Detail    string
	Notice    string
	Timeline  *core.TimelineEvent
}

func Questions(operations []investigation.ResultOperation) []slackui.OperatorQuestion {
	var questions []slackui.OperatorQuestion
	for _, operation := range operations {
		if operation.Type != "request_operator_input" || operation.OperatorInput == nil {
			continue
		}
		questions = append(questions, slackui.OperatorQuestion{
			Question: operation.OperatorInput.Question,
			Choices:  operation.OperatorInput.Choices,
		})
	}
	return questions
}

func AnswerInputID(cardMessageTS string, question int) string {
	return fmt.Sprintf("operator_answer_%s_%d", cardMessageTS, question)
}

func Handle(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
	operator bool,
	now time.Time,
) (Result, error) {
	choice, decoded := slackui.DecodeOperatorChoice(input.ActionValue)
	if !decoded {
		return result("", "invalid", "the pressed value was not written by this renderer",
			"*That choice is no longer valid.* Reply in this thread with your answer instead."), nil
	}
	delivery, message, offered, err := offeredChoice(ctx, st, input)
	if err != nil {
		return Result{}, err
	}
	if !offered {
		answerID := AnswerInputID(input.MessageTS, choice.Question)
		existing, existingErr := st.GetSlackInput(ctx, answerID)
		if existingErr == nil && existing.Text == choice.Answer && existing.UserID == input.UserID {
			return result(choice.EpisodeID, "already_answered",
				"this delivered question already recorded that answer",
				"*This question has already been answered.* Reply in this thread to add anything else."), nil
		}
		if existingErr != nil && !errors.Is(existingErr, store.ErrNotFound) {
			return Result{}, existingErr
		}
		episode, lookupErr := st.GetWorkEpisode(ctx, choice.EpisodeID)
		if lookupErr == nil && episode.State != core.EpisodeWaitingOperator {
			return result(choice.EpisodeID, "already_answered",
				"the delivered question no longer carries choices and the episode is "+string(episode.State),
				"*This question has already been answered.* Reply in this thread to add anything else."), nil
		}
		if lookupErr != nil && !errors.Is(lookupErr, store.ErrNotFound) {
			return Result{}, lookupErr
		}
		return result(choice.EpisodeID, "invalid", "the press does not match the delivered card",
			"*That choice is no longer valid.* Reply in this thread with your answer instead."), nil
	}
	if choice.AskedUser != input.UserID {
		return result(choice.EpisodeID, "denied",
			"press came from a member the question was not asked of",
			"*That question was asked of someone else.* Reply in this thread if you want to answer it in your own words."), nil
	}
	episode, err := st.GetWorkEpisode(ctx, choice.EpisodeID)
	if errors.Is(err, store.ErrNotFound) {
		return result(choice.EpisodeID, "invalid", "the work this question belongs to no longer exists",
			"*That work is no longer available.* Nothing was answered."), nil
	}
	if err != nil {
		return Result{}, err
	}
	if episode.Destination.ChannelID == "" {
		return result(episode.ID, "invalid", "the episode has no bound destination to answer in",
			"*I could not attach that answer to the work.* Reply in this thread instead."), nil
	}
	answer := core.SlackInput{
		ID: AnswerInputID(input.MessageTS, choice.Question), EnvelopeID: "operator_choice:" + input.ID,
		EventID: "operator_choice:" + input.ID, Kind: "message",
		TeamID:    core.FirstNonempty(episode.WorkspaceID, input.TeamID),
		ChannelID: episode.Destination.ChannelID, ThreadTS: episode.Destination.ThreadTS,
		UserID: input.UserID, Text: choice.Answer, ReceivedAt: now.UTC(),
	}
	if episode.State != core.EpisodeWaitingOperator {
		existing, existingErr := st.GetSlackInput(ctx, answer.ID)
		if existingErr == nil && existing.Text == answer.Text && existing.UserID == answer.UserID {
			if err := queueResolution(ctx, st, input, episode.ID, answer.ID, delivery, message); err != nil {
				return Result{}, err
			}
			return result(episode.ID, "already_answered",
				"the accepted answer was reconciled onto its original card", ""), nil
		}
		if existingErr != nil && !errors.Is(existingErr, store.ErrNotFound) {
			return Result{}, existingErr
		}
		return result(episode.ID, "already_answered",
			"episode is "+string(episode.State)+" and is not waiting for an answer",
			"*This question has already been answered.* Reply in this thread to add anything else."), nil
	}
	created, err := st.AdmitSyntheticSlackInput(ctx, answer)
	if err != nil {
		return Result{}, err
	}
	if !created {
		existing, existingErr := st.GetSlackInput(ctx, answer.ID)
		if existingErr != nil {
			return Result{}, existingErr
		}
		if existing.Text != answer.Text || existing.UserID != answer.UserID {
			return result(episode.ID, "already_answered",
				"a different answer to this question was already admitted",
				"*This question has already been answered.* Reply in this thread to add anything else."), nil
		}
	}
	queued, err := Queue(ctx, st, episode, answer, operator)
	if err != nil {
		return Result{}, err
	}
	if err := queueResolution(ctx, st, input, episode.ID, answer.ID, delivery, message); err != nil {
		return Result{}, err
	}
	return Result{
		EpisodeID: episode.ID, Outcome: "answered", Detail: choice.Answer,
		Timeline: queued.Timeline,
	}, nil
}

type Queued struct {
	Run      core.AgentRun
	Timeline *core.TimelineEvent
}

func Queue(
	ctx context.Context,
	st *store.Store,
	episode core.WorkEpisode,
	answer core.SlackInput,
	operator bool,
) (Queued, error) {
	latest, err := st.GetEpisodeAttempt(ctx, episode.LatestAttemptID)
	if err != nil {
		return Queued{}, fmt.Errorf("load the attempt that asked the operator: %w", err)
	}
	previous, err := st.GetAgentRun(ctx, latest.AgentRunID)
	if err != nil {
		return Queued{}, fmt.Errorf("load the run that asked the operator: %w", err)
	}
	threadTS := core.FirstNonempty(episode.Destination.ThreadTS, previous.ThreadTS)
	candidate := core.AgentRun{
		Mode: previous.Mode, IncidentID: previous.IncidentID,
		ChannelID: core.FirstNonempty(episode.Destination.ChannelID, previous.ChannelID),
		ThreadTS:  threadTS, ConversationKey: previous.ConversationKey,
		SourceID: answer.ID, UserID: answer.UserID, Repository: previous.Repository,
		CommitmentTitle: episode.Objective,
	}
	switch previous.Mode {
	case core.AgentRunIncident, core.AgentRunEngineeringTask:
		candidate.SourceKind = "slack"
		candidate.Prompt = taskprompt.ForConversation(
			answer.UserID, answer.Text, true,
			previous.Mode == core.AgentRunEngineeringTask, !operator,
		)
	case core.AgentRunTriage:
		var state decisionpkg.WatchTurnState
		if len(previous.Context) > 0 {
			if err := decisionpkg.DecodeStrictJSON(previous.Context, &state); err != nil {
				return Queued{}, fmt.Errorf("restore the question conversation: %w", err)
			}
		}
		state.ResponseThreadTS = threadTS
		state.ConversationFollowup = true
		candidate.Context, err = json.Marshal(state)
		if err != nil {
			return Queued{}, fmt.Errorf("freeze the operator answer context: %w", err)
		}
		candidate.SourceKind = "watch"
		candidate.Prompt = answer.Text
	default:
		return Queued{}, fmt.Errorf("unsupported operator answer run mode %q", previous.Mode)
	}
	run, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, candidate)
	if err != nil {
		return Queued{}, fmt.Errorf("resume the episode with the operator answer: %w", err)
	}
	queued := Queued{Run: run}
	if created && previous.IncidentID != "" {
		title, kind := "Operator answered the incident question", "operator.message"
		if previous.Mode == core.AgentRunEngineeringTask {
			title, kind = "Teammate answered the engineering question", "teammate.message"
		}
		queued.Timeline = &core.TimelineEvent{
			ID: "tl_input_" + answer.ID, IncidentID: previous.IncidentID,
			ChannelID: candidate.ChannelID, Kind: kind, ActorID: answer.UserID,
			Title: title, Detail: decisionpkg.BoundedField(answer.Text, 2000),
			CreatedAt: answer.ReceivedAt,
		}
	}
	if err := st.FinishSlackInput(ctx, answer.ID); err != nil {
		return Queued{}, fmt.Errorf("finish the operator answer input for run %s: %w", run.ID, err)
	}
	return queued, nil
}

func queueResolution(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
	episodeID string,
	answerID string,
	delivery core.SlackDelivery,
	message slackui.Message,
) error {
	resolved, ok := slackui.ResolveOperatorChoice(message, input.ActionValue, input.UserID)
	if !ok {
		return errors.New("resolve the operator choice on its delivered card")
	}
	body, err := slackui.Encode(resolved)
	if err != nil {
		return fmt.Errorf("encode the resolved operator question: %w", err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_resolve_" + answerID, IncidentID: delivery.IncidentID,
		EpisodeID: episodeID, Operation: "update", Kind: "operator_choice",
		ChannelID: input.ChannelID, ThreadTS: input.ThreadTS, MessageTS: input.MessageTS,
		Body: body, CoalesceKey: "operator_choice:" + input.ChannelID + ":" + input.MessageTS,
	}); err != nil {
		return fmt.Errorf("queue the resolved operator question: %w", err)
	}
	return nil
}

func offeredChoice(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
) (core.SlackDelivery, slackui.Message, bool, error) {
	if input.ChannelID == "" || input.MessageTS == "" {
		return core.SlackDelivery{}, slackui.Message{}, false, nil
	}
	delivery, err := st.GetSentSlackMessageDelivery(ctx, input.ChannelID, input.MessageTS)
	if errors.Is(err, store.ErrNotFound) {
		return core.SlackDelivery{}, slackui.Message{}, false, nil
	}
	if err != nil {
		return core.SlackDelivery{}, slackui.Message{}, false, err
	}
	message, err := slackui.Decode(delivery.Body)
	if err != nil {
		return core.SlackDelivery{}, slackui.Message{}, false,
			fmt.Errorf("decode the card a choice was pressed on: %w", err)
	}
	return delivery, message, slackui.MessageOffersControl(
		message, slackui.ActionOperatorChoice, input.ActionValue,
	), nil
}

func result(episodeID, outcome, detail, notice string) Result {
	return Result{EpisodeID: episodeID, Outcome: outcome, Detail: detail, Notice: notice}
}
