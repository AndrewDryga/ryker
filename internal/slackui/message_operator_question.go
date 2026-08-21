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
	interactive := false
	for index, question := range questions {
		text := operatorQuestionText(question.Question, sanitizer)
		if text == "" {
			continue
		}
		if asked++; asked > MaxOperatorQuestions {
			break
		}
		actions, choices := operatorChoiceActions(
			episodeID, askedUserID, index, question.Choices, sanitizer,
		)
		row := "*" + text + "*"
		if len(actions) > 0 {
			interactive = true
			row += "\n\n*Options:*"
			for choiceIndex, choice := range choices {
				row += "\n" + choiceNumber(choiceIndex) + ". " + escapeSlackText(choice)
			}
		}
		message = AppendRow(message, row, actions)
	}
	if interactive && message.blockedAssessmentContext != "" {
		message.Context = removeExactString(message.Context, message.blockedAssessmentContext)
		message.blockedAssessmentContext = ""
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
) ([]Action, []string) {
	actions := make([]Action, 0, len(choices))
	visible := make([]string, 0, len(choices))
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
		value := EncodeOperatorChoice(OperatorChoice{
			EpisodeID: episodeID, AskedUser: askedUserID,
			Question: question, Answer: choice,
		})
		// A value over the bound is dropped rather than cut: a truncated one
		// does not decode, so the button would render and then refuse the press
		// with "this control is no longer valid" — an accusation aimed at the
		// operator for a bound the host failed to hold.
		if value == "" || len(value) > buttonValueLimit {
			continue
		}
		action := Action{
			ID: ActionOperatorChoice, Label: "Choose " + choiceNumber(len(actions)), Value: value,
		}
		if proposalMarker.MatchString(choice) {
			action.Style = "primary"
		}
		actions = append(actions, action)
		visible = append(visible, choice)
	}
	return actions, visible
}

func choiceNumber(index int) string {
	return string(rune('1' + index))
}

func removeExactString(values []string, target string) []string {
	for index, value := range values {
		if value == target {
			return append(values[:index:index], values[index+1:]...)
		}
	}
	return values
}

// ResolveOperatorChoice turns the delivered question into its durable decision
// record. The complete options remain visible, the exact selection is
// attributed with a host-created Slack user mention, and every choice control
// on the answered row is retired.
func ResolveOperatorChoice(message Message, selectedValue, userID string) (Message, bool) {
	selectedRow := -1
	var selected OperatorChoice
	for rowIndex := range message.Rows {
		for _, action := range message.Rows[rowIndex].Actions {
			if action.ID != ActionOperatorChoice || action.Value != selectedValue {
				continue
			}
			var ok bool
			selected, ok = DecodeOperatorChoice(action.Value)
			if !ok {
				return message, false
			}
			selectedRow = rowIndex
			break
		}
		if selectedRow >= 0 {
			break
		}
	}
	if selectedRow < 0 {
		return message, false
	}
	// Resuming the episode retires every choice on the asking, not only the
	// pressed row. A second row left live would offer an answer to the old
	// attempt while the model is already working on the selected one.
	for rowIndex := range message.Rows {
		row := &message.Rows[rowIndex]
		kept := make([]Action, 0, len(row.Actions))
		for _, action := range row.Actions {
			if action.ID != ActionOperatorChoice {
				kept = append(kept, action)
			}
		}
		row.Actions = kept
	}
	actor := "The operator"
	if slackUserIDPattern.MatchString(userID) {
		actor = "<@" + userID + ">"
	}
	message.Rows[selectedRow].Text += "\n\n" + actor + " selected “" +
		escapeSlackText(selected.Answer) + "”."
	message.Temporary = false
	return message, true
}

var slackUserIDPattern = regexp.MustCompile(`^[UW][A-Z0-9]+$`)
