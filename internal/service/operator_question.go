package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The other half of the choice buttons: what a press means and what it does.
//
// A press is turned into the message the operator would otherwise have typed
// and dropped into the same queue, so everything downstream — episode
// correlation, the waiting_operator resume, the prompt the next attempt sees —
// is the code that already handled typed answers, not a parallel path that has
// to be kept in step with it.

// operatorQuestions reads the questions out of a result, in the order the model
// asked them.
//
// Order is the routing key: the button records which question it answers by
// position, so a question with no choices still occupies its index. Dropping
// it from the list instead would silently renumber every question after it.
func operatorQuestions(
	operations []investigation.ResultOperation,
) []slackui.OperatorQuestion {
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

// operatorAnswerInputID is what makes one asking answerable once.
//
// Slack leaves the buttons on the card after a press, so a second click is not
// a mistake — it is what the surface invites. The id is derived rather than
// minted per press, so the queue's own insert-or-ignore refuses the duplicate
// instead of queueing two attempts on one episode carrying opposite answers.
//
// Keyed by the card, not by the episode. Question indexes restart at zero every
// time the model asks, so an episode-keyed id would let the first round's
// answer consume the id belonging to the second round's first question — and
// the new card's buttons would be dead on arrival, refused as duplicates of an
// answer to a different question. The card's timestamp is what identifies one
// asking, and the delivery check above has already proved this press came from
// that card.
func operatorAnswerInputID(cardMessageTS string, question int) string {
	return fmt.Sprintf("operator_answer_%s_%d", cardMessageTS, question)
}

// handleOperatorChoice turns a pressed choice into the asked operator's answer.
func (s *Service) handleOperatorChoice(ctx context.Context, input core.SlackInput) error {
	choice, decoded := slackui.DecodeOperatorChoice(input.ActionValue)
	if !decoded {
		return s.finishOperatorChoice(ctx, input, "", "invalid",
			"the pressed value was not written by this renderer",
			"*That choice is no longer valid.* Reply in this thread with your answer instead.")
	}
	// The press has to name a button Responder actually rendered on the message
	// it came from, the same check every other host-owned control makes.
	offered, err := s.operatorChoiceWasOffered(ctx, input)
	if err != nil {
		return err
	}
	if !offered {
		return s.finishOperatorChoice(ctx, input, choice.EpisodeID, "invalid",
			"the press does not match the delivered card",
			"*That choice is no longer valid.* Reply in this thread with your answer instead.")
	}
	// Only the person the question was put to. A press carries no words of its
	// own, so the host is what turns it into somebody's answer, and it may only
	// do that for the person who was asked. Everyone else still has the reply
	// box, which is how a colleague answered before any of this existed.
	if choice.AskedUser != input.UserID {
		return s.finishOperatorChoice(ctx, input, choice.EpisodeID, "denied",
			"press came from a member the question was not asked of",
			"*That question was asked of someone else.* Reply in this thread if you want to "+
				"answer it in your own words.")
	}
	episode, err := s.store.GetWorkEpisode(ctx, choice.EpisodeID)
	if errors.Is(err, store.ErrNotFound) {
		return s.finishOperatorChoice(ctx, input, choice.EpisodeID, "invalid",
			"the work this question belongs to no longer exists",
			"*That work is no longer available.* Nothing was answered.")
	}
	if err != nil {
		return err
	}
	if episode.State != core.EpisodeWaitingOperator {
		return s.finishOperatorChoice(ctx, input, episode.ID, "already_answered",
			"episode is "+string(episode.State)+" and is not waiting for an answer",
			"*This question has already been answered.* Reply in this thread to add anything else.")
	}
	// The answer is said in the episode's own destination, not wherever the
	// press came from, because that is the conversation the resume path matches
	// on. Without one there is nowhere to say it and nothing to continue: a
	// synthesized message carrying no channel would be admitted, fail to
	// correlate, and start fresh work in place of the episode it meant to
	// answer.
	if episode.Destination.ChannelID == "" {
		return s.finishOperatorChoice(ctx, input, episode.ID, "invalid",
			"the episode has no bound destination to answer in",
			"*I could not attach that answer to the work.* Reply in this thread instead.")
	}
	answer := core.SlackInput{
		ID:         operatorAnswerInputID(input.MessageTS, choice.Question),
		EnvelopeID: "operator_choice:" + input.ID,
		EventID:    "operator_choice:" + input.ID,
		Kind:       "message",
		TeamID:     core.FirstNonempty(episode.WorkspaceID, input.TeamID),
		ChannelID:  episode.Destination.ChannelID,
		ThreadTS:   episode.Destination.ThreadTS,
		UserID:     input.UserID,
		Text:       choice.Answer,
		ReceivedAt: s.now().UTC(),
	}
	created, err := s.store.AdmitSyntheticSlackInput(ctx, answer)
	if err != nil {
		return err
	}
	if !created {
		return s.finishOperatorChoice(ctx, input, episode.ID, "already_answered",
			"an answer to this question was already admitted",
			"*This question has already been answered.* Reply in this thread to add anything else.")
	}
	// Said in the thread before the work resumes on it. A decision taken with
	// nothing visible is a decision nobody can audit afterwards.
	if err := s.postInputMessageAt(
		ctx, "out_"+answer.ID, answer.ChannelID, answer.ThreadTS,
		slackui.OperatorChoiceAnswer(choice.Answer),
	); err != nil {
		return err
	}
	if err := s.queueWatchedInput(ctx, answer); err != nil {
		return err
	}
	return s.finishOperatorChoice(ctx, input, episode.ID, "answered", choice.Answer, "")
}

// operatorChoiceWasOffered reports whether the delivered message still carries
// the exact button that was pressed.
func (s *Service) operatorChoiceWasOffered(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if input.ChannelID == "" || input.MessageTS == "" {
		return false, nil
	}
	delivery, err := s.store.GetSentSlackMessageDelivery(
		ctx, input.ChannelID, input.MessageTS,
	)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	message, err := slackui.Decode(delivery.Body)
	if err != nil {
		return false, fmt.Errorf("decode the card a choice was pressed on: %w", err)
	}
	return slackui.MessageOffersControl(
		message, slackui.ActionOperatorChoice, input.ActionValue,
	), nil
}

// finishOperatorChoice records what the press did and tells the person who made
// it, unless the press worked — in which case the thread already says so.
func (s *Service) finishOperatorChoice(
	ctx context.Context,
	input core.SlackInput,
	episodeID string,
	outcome string,
	detail string,
	notice string,
) error {
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.operator_choice", ActorID: input.UserID,
		ObjectID: episodeID, Outcome: outcome, Detail: detail,
	})
	if notice == "" {
		return s.finishSlackInput(ctx, input)
	}
	return s.finishSlashInput(ctx, input, notice)
}
