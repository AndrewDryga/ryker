package slackui

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/slack-go/slack"
)

// Two questions harvested from production, one of which marks its own default.
//
// run_943d4feabe6156db570205614a39daf4 asked "At least one (Recommended)" /
// "Two or more" and run_2f0a10452f35e37b950d4bb7e37d9555 asked "One extra per
// zone" / "Only us-central1-f". The first marks its proposal in the choice
// text; the second does not mark one at all. Both shapes are real and the
// renderer has to answer both without inventing a default for the second.
func harvestedQuestions() []OperatorQuestion {
	return []OperatorQuestion{{
		Question: "Did you mean add one spare when a zone hosts at least one steady-state instance, or only when it hosts two or more?",
		Choices:  []string{"At least one (Recommended)", "Two or more"},
	}, {
		Question: "Should the PR reserve one additional rollout slot in every configured zone, or only one extra slot in `us-central1-f`?",
		Choices:  []string{"One extra per zone", "Only us-central1-f"},
	}}
}

// A question with choices reaches the operator as buttons, one per choice.
//
// The operation has carried `operator_input.choices` since the contract was
// written and no Slack surface had ever read it: the question arrived as prose
// inside a blocked completion, and the structure the model had already supplied
// was thrown away at the card. Slack rejects a whole surface whose action_ids
// repeat, so four buttons across two questions must be four distinct ids, and
// each one has to say which question it answers or the second question's press
// would be recorded against the first.
func TestEachQuestionChoiceRendersAsItsOwnButton(t *testing.T) {
	message := WithOperatorQuestions(
		Message{Text: "blocked"}, "epi_01ce33abd2000000", "U0ASKER",
		harvestedQuestions(), NewSanitizer(12000),
	)

	blocks := renderedActionBlocks(t, message)
	if len(blocks) != 2 {
		t.Fatalf("rendered %d action blocks for 2 questions: %v", len(blocks), blocks)
	}
	seen := map[string]bool{}
	answers := map[int][]string{}
	for questionIndex, block := range blocks {
		if len(block) != 2 {
			t.Fatalf("question %d rendered %d buttons, want 2", questionIndex, len(block))
		}
		for choiceIndex, element := range block {
			if seen[element.ActionID] {
				t.Errorf("action_id %q appears twice; Slack rejects the whole surface",
					element.ActionID)
			}
			seen[element.ActionID] = true
			if BaseActionID(element.ActionID) != ActionOperatorChoice {
				t.Errorf("button routes to %q, want %q",
					BaseActionID(element.ActionID), ActionOperatorChoice)
			}
			choice, ok := DecodeOperatorChoice(element.Value)
			if !ok {
				t.Fatalf("button value %q does not decode", element.Value)
			}
			if choice.EpisodeID != "epi_01ce33abd2000000" || choice.AskedUser != "U0ASKER" {
				t.Errorf("button carries episode %q asked of %q",
					choice.EpisodeID, choice.AskedUser)
			}
			if choice.Question != questionIndex {
				t.Errorf("button under question %d says it answers question %d",
					questionIndex, choice.Question)
			}
			if element.Text != "Choose "+string(rune('1'+choiceIndex)) {
				t.Errorf("button %d reads %q, want a bounded numbered label", choiceIndex, element.Text)
			}
			answers[questionIndex] = append(answers[questionIndex], choice.Answer)
		}
	}
	for index, question := range harvestedQuestions() {
		if strings.Join(answers[index], "|") != strings.Join(question.Choices, "|") {
			t.Errorf("question %d offered %v, want %v", index, answers[index], question.Choices)
		}
	}

	// The question itself is still on the card. Buttons are an accelerator, not
	// a replacement for reading what was asked — and a free-text reply is still
	// the answer for anyone who wants to give a different one.
	rendered := renderedText(t, message)
	for _, question := range harvestedQuestions() {
		if !strings.Contains(rendered, question.Question) {
			t.Errorf("the card never states the question %q", question.Question)
		}
		for _, choice := range question.Choices {
			if !strings.Contains(rendered, choice) {
				t.Errorf("the card never states the full choice %q", choice)
			}
		}
	}
}

// Slack button labels are too short for a policy sentence. The complete answer
// must remain visible and must be what the next model turn receives; only the
// accelerator label is allowed to be short.
func TestALongOperatorChoiceIsVisibleInFullAndSubmittedInFull(t *testing.T) {
	answer := "Yes — use the proposed configurable deterministic 1% sampling per RPC while always logging the first failure for each RPC every minute"
	message := WithOperatorQuestions(
		Message{Text: "Choose the sampling policy."}, "epi_sampling", "U0ASKER",
		[]OperatorQuestion{{Question: "Which sampling policy should I implement?", Choices: []string{answer}}},
		NewSanitizer(12000),
	)
	buttons := renderedActionBlocks(t, message)
	if len(buttons) != 1 || len(buttons[0]) != 1 {
		t.Fatalf("long choice buttons = %+v", buttons)
	}
	choice, ok := DecodeOperatorChoice(buttons[0][0].Value)
	if !ok || choice.Answer != answer {
		t.Fatalf("button submitted %q, want full answer %q", choice.Answer, answer)
	}
	if buttons[0][0].Text != "Choose 1" || !strings.Contains(renderedText(t, message), answer) {
		t.Fatalf("long choice was not legible: button=%q card=%s", buttons[0][0].Text, renderedText(t, message))
	}
}

func TestAnOperatorQuestionReplacesTheRedundantBlockedFooter(t *testing.T) {
	message := WithBlockedAssessment(
		Message{Text: "Choose the sampling policy."},
		"The sampling policy needs operator confirmation.", nil, nil,
		"Confirm the proposed default.", NewSanitizer(12000),
	)
	message = WithOperatorQuestions(
		message, "epi_sampling", "U0ASKER",
		[]OperatorQuestion{{Question: "Which sampling policy should I implement?", Choices: []string{"Use 1%"}}},
		NewSanitizer(12000),
	)
	for _, line := range message.Context {
		if strings.Contains(line, "Blocked:") || strings.Contains(line, "Next:") {
			t.Fatalf("question repeated itself in the footer: %+v", message.Context)
		}
	}
}

func TestSelectingAnOperatorChoiceResolvesTheOriginalCardInPlace(t *testing.T) {
	message := WithOperatorQuestions(
		Message{Text: "Sampling should cap volume. Should I implement that?", Sections: []string{
			"Sampling should cap volume. Should I implement that?",
		}}, "epi_sampling", "U0ASKER",
		[]OperatorQuestion{
			{Question: "Which policy should I use?", Choices: []string{
				"Yes — use the proposed 1% plus first-per-minute default",
				"Sample every failure uniformly at 1%",
			}},
			{Question: "Should the setting be configurable?", Choices: []string{
				"Yes, make it configurable", "No, keep it fixed",
			}},
		}, NewSanitizer(12000),
	)
	selected := message.Rows[0].Actions[0].Value
	resolved, ok := ResolveOperatorChoice(message, selected, "U123ABC")
	if !ok {
		t.Fatal("the exact rendered choice was not resolved")
	}
	if resolved.Temporary || MessageOffersControl(resolved, ActionOperatorChoice, selected) {
		t.Fatalf("resolved question remained temporary or actionable: %+v", resolved)
	}
	remaining := 0
	for _, row := range resolved.Rows {
		for _, action := range row.Actions {
			if action.ID == ActionOperatorChoice {
				remaining++
			}
		}
	}
	if remaining != 2 {
		t.Fatalf("answering the first question left %d controls, want the second question's 2: %+v",
			remaining, resolved.Rows)
	}
	rendered := renderedText(t, resolved)
	for _, want := range []string{
		"Options:", "Sample every failure uniformly at 1%", "U123ABC",
		"selected", "Yes — use the proposed 1% plus first-per-minute default",
	} {
		if !strings.Contains(rendered, want) {
			t.Errorf("resolved card does not contain %q: %s", want, rendered)
		}
	}
}

// A long answered question collapsed its decision attribution behind Slack's
// Show more control. The choice was recorded, but the one line people needed
// to scan disappeared with the question prose. Keep the durable attribution in
// its own row after every option so Slack renders it as an independent section.
func TestAnsweredChoiceAttributionStaysOutsideTheCollapsedQuestion(t *testing.T) {
	message := WithOperatorQuestions(
		Message{Text: "Choose the aggregation window."}, "epi_window", "U0ASKER",
		[]OperatorQuestion{
			{Question: strings.Repeat("Why this window matters. ", 90), Choices: []string{
				"Use 5-minute windows with the same 100-combination cap",
				"Use 1-minute windows with a smaller cap",
			}},
			{Question: "Should the cap be configurable?", Choices: []string{
				"Yes, make it configurable", "No, keep it fixed",
			}},
		}, NewSanitizer(12000),
	)
	selected := message.Rows[0].Actions[0].Value
	questionRows := len(message.Rows)
	originalQuestion := message.Rows[0].Text

	resolved, ok := ResolveOperatorChoice(message, selected, "U123ABC")
	if !ok {
		t.Fatal("the exact rendered choice was not resolved")
	}
	if len(resolved.Rows) != questionRows+1 {
		t.Fatalf("resolved rows = %d, want %d question rows plus one attribution: %+v",
			len(resolved.Rows), questionRows, resolved.Rows)
	}
	if resolved.Rows[0].Text != originalQuestion {
		t.Fatalf("selection was folded into the long question row: %q", resolved.Rows[0].Text)
	}
	want := "<@U123ABC> selected “Use 5-minute windows with the same 100-combination cap”."
	if got := resolved.Rows[1].Text; got != want {
		t.Fatalf("standalone attribution = %q, want %q", got, want)
	}
	standalone := false
	for _, block := range resolved.Blocks() {
		section, ok := block.(*slack.SectionBlock)
		if !ok || section.Text == nil {
			continue
		}
		if section.Text.Text == want {
			standalone = true
		}
		if strings.Contains(section.Text.Text, "Why this window matters") &&
			strings.Contains(section.Text.Text, "selected “") {
			t.Fatalf("delivered Slack section folds the attribution with the question: %q",
				section.Text.Text)
		}
	}
	if !standalone {
		t.Fatalf("delivered Slack blocks do not contain a standalone attribution: %+v",
			resolved.Blocks())
	}
}

// A real sampling-policy choice was answered after its question card had been
// delivered by an older renderer. The update retired the buttons but left the
// old "Blocked / Next" footer beneath the recorded decision, telling the
// operator to make the decision they had just made. Exercise the durable
// encode/decode boundary because that is where construction-only state is lost.
func TestAnAnsweredChoiceDropsItsLegacyBlockedFooter(t *testing.T) {
	message := WithOperatorQuestions(
		Message{Text: "Choose the sampling policy."}, "epi_sampling", "U0ASKER",
		[]OperatorQuestion{{
			Question: "Which sampling policy should I implement?",
			Choices:  []string{"Use 1% sampling", "Use rate limiting"},
		}}, NewSanitizer(12000),
	)
	selected := message.Rows[0].Actions[0].Value
	message.Context = append(message.Context,
		"Details saved: 2 evidence records.",
		"Blocked: The sampling policy needs operator confirmation before changing the committed logging behavior. · Next: Confirm the proposed default or select another sampling policy.",
	)
	body, err := Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := Decode(body)
	if err != nil {
		t.Fatal(err)
	}
	resolved, ok := ResolveOperatorChoice(decoded, selected, "U123ABC")
	if !ok {
		t.Fatal("the durable rendered choice was not resolved")
	}
	context := strings.Join(resolved.Context, "\n")
	if strings.Contains(context, "Blocked:") || strings.Contains(context, "Next:") {
		t.Fatalf("answered question kept its stale blocker: %q", context)
	}
	if !strings.Contains(context, "Details saved: 2 evidence records.") {
		t.Fatalf("answer discarded unrelated useful context: %q", context)
	}
}

// The default is the model's claim, not the host's guess.
//
// The contract asks for "your proposed default" and gives the operation nowhere
// typed to put one, so the model writes it into the choice — "At least one
// (Recommended)" in run_943d4feabe6156db570205614a39daf4. Marking the first
// choice instead would have styled "One extra per zone" as a recommendation
// that model never made, on a question about how many machines to pay for.
func TestOnlyAChoiceTheModelMarkedRendersAsTheProposal(t *testing.T) {
	message := WithOperatorQuestions(
		Message{Text: "blocked"}, "epi_1", "U0ASKER", harvestedQuestions(),
		NewSanitizer(12000),
	)

	blocks := renderedActionBlocks(t, message)
	styles := map[string]string{}
	for _, block := range blocks {
		for _, element := range block {
			choice, ok := DecodeOperatorChoice(element.Value)
			if !ok {
				t.Fatalf("choice value does not decode: %q", element.Value)
			}
			styles[choice.Answer] = element.Style
		}
	}
	if styles["At least one (Recommended)"] != "primary" {
		t.Errorf("the choice the model recommended rendered as %q, want primary",
			styles["At least one (Recommended)"])
	}
	for _, unmarked := range []string{"Two or more", "One extra per zone", "Only us-central1-f"} {
		if styles[unmarked] != "" {
			t.Errorf("%q rendered as %q; the model proposed nothing on that question",
				unmarked, styles[unmarked])
		}
	}
}

// A question the model asked in prose alone stays prose.
//
// Half the production asks carry no choices — "Please paste or reattach the
// list you mean by 'those'" cannot be a button — and an empty row of controls
// under a question is worse than none: it reads as an offer that failed to
// load. The question still has to reach the card, because that is the whole
// point of the operation.
func TestAQuestionWithNoChoicesRendersWithoutControls(t *testing.T) {
	message := WithOperatorQuestions(Message{Text: "blocked"}, "epi_1", "U0ASKER",
		[]OperatorQuestion{{
			Question: "Which repository owns the `realtime-gateway` server source?",
		}}, NewSanitizer(12000))

	if message.HasControls() {
		t.Error("a question with no choices rendered controls")
	}
	if !strings.Contains(renderedText(t, message), "realtime-gateway") {
		t.Error("a question with no choices never reached the card")
	}
}

// renderedButton is one button as Slack receives it, not as the Action struct
// describes it: the id carries the instance suffix and the label has been
// through the renderer's own bounds.
type renderedButton struct {
	ActionID string
	Value    string
	Style    string
	Text     string
}

// renderedActionBlocks returns each rendered actions block in card order.
func renderedActionBlocks(t *testing.T, message Message) [][]renderedButton {
	t.Helper()
	var blocks [][]renderedButton
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Type     string `json:"type"`
			Elements []struct {
				ActionID string `json:"action_id"`
				Value    string `json:"value"`
				Style    string `json:"style"`
				Text     struct {
					Text string `json:"text"`
				} `json:"text"`
			} `json:"elements"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			t.Fatal(err)
		}
		if probe.Type != "actions" {
			continue
		}
		group := make([]renderedButton, 0, len(probe.Elements))
		for _, rendered := range probe.Elements {
			// Slack rejects a button value over 2000 characters and rejects the
			// message with it, which would lose the answer and the question.
			if len(rendered.Value) > buttonValueLimit {
				t.Errorf("button value is %d characters, over Slack's %d",
					len(rendered.Value), buttonValueLimit)
			}
			group = append(group, renderedButton{
				ActionID: rendered.ActionID, Value: rendered.Value,
				Style: rendered.Style, Text: rendered.Text.Text,
			})
		}
		blocks = append(blocks, group)
	}
	return blocks
}

func renderedText(t *testing.T, message Message) string {
	t.Helper()
	raw, err := json.Marshal(message.Blocks())
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
