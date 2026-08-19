package slackui

import (
	"regexp"
	"strings"
)

// The model's questions, rendered as the choices it already supplied.
//
// `operator_input.choices` has been in the contract from the start and no Slack
// surface had ever read it. A question arrived as prose inside a blocked
// completion, the operator read a paragraph, typed a reply, and the reply
// re-entered as an ordinary message — which worked, and cost a sentence of
// typing for an answer the model had already written down twice.
//
// Responder owns interactive controls by contract, so this is the host's job
// and not the model's: it never emits Block Kit, it emits the answer set, and
// what that looks like in Slack is decided here.

// MaxOperatorQuestions is how many questions one card asks.
//
// The contract asks the model for "up to three pointed questions" and this is
// the host holding it to that, because a card is a thing a person answers in
// one sitting. A model that emitted six would otherwise get six.
const MaxOperatorQuestions = 3

// MaxOperatorChoices is how many answers one question offers.
//
// Slack allows more buttons in a row than anybody reads. Production asks two;
// five is room to be generous without the row wrapping into a wall.
const MaxOperatorChoices = 5

// OperatorQuestion is one question the model asked and the answers it offered.
type OperatorQuestion struct {
	Question string
	Choices  []string
}

// proposalMarker is the model marking its own recommendation.
//
// The contract asks for "your proposed default" and gives the operation
// nowhere typed to put one, so the model writes it into the choice: "At least
// one (Recommended)", "Two steady-state (Recommended)". This reads that mark
// and nothing else. The tempting shortcut — treat the first choice as the
// proposal — would have styled "One extra per zone" as a recommendation the
// model never made, on a question about how many machines to pay for, and the
// operator would have had no way to know the host had invented it.
//
// Anchored to a trailing parenthetical so a choice that merely contains the
// word ("Ignore the recommended setting") is not read as endorsing itself.
var proposalMarker = regexp.MustCompile(`(?i)\((?:recommended|suggested|proposed|default)\)\s*$`)

// WithOperatorQuestions renders each question with its choices as buttons.
//
// Rows, not a pile of actions at the bottom: three questions' worth of buttons
// gathered under the card would be nine controls with nothing saying which
// question any of them answered. Each question's answers sit directly beneath
// it, which is the same rule the offer cards follow.
//
// The choices are an accelerator and never a constraint. The question stays on
// the card in full, a question with no choices renders as text alone, and a
// typed reply resumes the episode exactly as it did before any of this — the
// buttons save the typing, they do not own the answer.
//
// The sanitizer travels with the text for the same reason it does on a blocked
// assessment: rows are model output reaching a card outside the delivery's own
// redaction pass, which does not walk them.
func WithOperatorQuestions(
	message Message,
	episodeID string,
	askedUserID string,
	questions []OperatorQuestion,
	sanitizer *Sanitizer,
) Message {
	if episodeID == "" || askedUserID == "" {
		return message
	}
	asked := 0
	for index, question := range questions {
		text := operatorQuestionText(question.Question, sanitizer)
		if text == "" {
			continue
		}
		if asked++; asked > MaxOperatorQuestions {
			break
		}
		message = AppendRow(
			message,
			"*"+text+"*",
			operatorChoiceActions(episodeID, askedUserID, index, question.Choices, sanitizer),
		)
	}
	return message
}

// operatorQuestionText is the model's words, redacted and escaped, or nothing.
func operatorQuestionText(value string, sanitizer *Sanitizer) string {
	value = strings.TrimSpace(value)
	if sanitizer != nil {
		value = sanitizer.Text(value)
	}
	return escapeSlackText(value)
}

func operatorChoiceActions(
	episodeID string,
	askedUserID string,
	question int,
	choices []string,
	sanitizer *Sanitizer,
) []Action {
	actions := make([]Action, 0, len(choices))
	for _, raw := range choices {
		choice := strings.TrimSpace(raw)
		if sanitizer != nil {
			choice = strings.TrimSpace(sanitizer.Text(choice))
		}
		if choice == "" {
			continue
		}
		if len(actions) == MaxOperatorChoices {
			break
		}
		// The label is bounded here rather than at the renderer, because the
		// value has to carry the same string the operator read. Slack would
		// truncate the label alone and leave the button answering something
		// longer than it says.
		label := truncateUTF8(choice, operatorChoiceLabelLimit)
		value := EncodeOperatorChoice(OperatorChoice{
			EpisodeID: episodeID, AskedUser: askedUserID,
			Question: question, Answer: label,
		})
		// A value over the bound is dropped rather than cut: a truncated one
		// does not decode, so the button would render and then refuse the press
		// with "this control is no longer valid" — an accusation aimed at the
		// operator for a bound the host failed to hold.
		if value == "" || len(value) > buttonValueLimit {
			continue
		}
		action := Action{ID: ActionOperatorChoice, Label: label, Value: value}
		if proposalMarker.MatchString(label) {
			action.Style = "primary"
		}
		actions = append(actions, action)
	}
	return actions
}

// operatorChoiceLabelLimit is Slack's bound on button text. A choice longer
// than this is a sentence rather than a choice; it still reaches the operator
// in the question, which states the options in the model's own words.
const operatorChoiceLabelLimit = 75

// OperatorChoiceAnswer records a pressed choice where the question was asked.
//
// A press is silent. Without this the thread would show a question, then the
// work resuming on an answer nobody in the channel ever saw — and the person
// reading it back a week later would have no way to learn what was decided or
// that a decision had been taken at all. The words are the ones on the button,
// so the transcript and the model receive the same answer.
//
// Grey: the decision has been made and passed back to the work, so nobody is
// being asked for anything by this line.
func OperatorChoiceAnswer(answer string) Message {
	return Message{
		Text:      "Answered: " + answer,
		Stripe:    StripeIdle,
		Sections:  []string{"*Answered:* " + escapeSlackText(answer)},
		Context:   []string{"Chosen from the options above. Reply in this thread to say more."},
		Temporary: true,
	}
}
