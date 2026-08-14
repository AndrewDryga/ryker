package slackui

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/slack-go/slack"
)

// monospaceStrips returns the text of every preformatted block on the surface,
// which is the only form the ledger and the activity window take.
func monospaceStrips(t *testing.T, message Message) []string {
	t.Helper()
	var strips []string
	for _, block := range message.Blocks() {
		rich, ok := block.(*slack.RichTextBlock)
		if !ok {
			continue
		}
		for _, element := range rich.Elements {
			preformatted, ok := element.(*slack.RichTextPreformatted)
			if !ok {
				t.Fatalf("rich text block carries %T rather than a preformatted element", element)
			}
			var text strings.Builder
			for _, part := range preformatted.Elements {
				value, ok := part.(*slack.RichTextSectionTextElement)
				if !ok {
					t.Fatalf("preformatted element carries %T rather than text", part)
				}
				text.WriteString(value.Text)
			}
			strips = append(strips, text.String())
		}
	}
	return strips
}

func stripLines(t *testing.T, message Message, index int) []string {
	t.Helper()
	strips := monospaceStrips(t, message)
	if len(strips) <= index {
		t.Fatalf("expected at least %d monospace strips, got %d", index+1, len(strips))
	}
	return strings.Split(strips[index], "\n")
}

// column reports where a cell starts in display terms. Byte offsets are not
// comparable across these lines: "·" is two bytes and "▸" is three, so two
// lines whose columns line up on screen have different indexes in memory.
func column(line, cell string) int {
	index := strings.Index(line, cell)
	if index < 0 {
		return -1
	}
	return utf8.RuneCountInString(line[:index])
}

// A run renders as a position, not an adjective: the ledger says which step is
// current and what the remaining ones are waiting for, so "step 4 of 5" is read
// rather than inferred from a paragraph that says "still working".
func TestLedgerAlignsColumnsAndTruncatesDetailBeforeLabel(t *testing.T) {
	for _, testCase := range []struct {
		name  string
		steps []LedgerStep
		want  []string
	}{
		{
			name: "columns line up under the glyph, label, detail and time",
			steps: []LedgerStep{
				{Glyph: "✓", Label: "Changes made", Detail: "3 files", When: "2:31 PM"},
				{Label: "Review & merge", Owner: "yours"},
			},
			want: []string{
				"✓  Changes made    3 files  2:31 PM",
				"·  Review & merge           yours",
			},
		},
		{
			// The step with nothing after it keeps its full label: only a cell
			// with a neighbour to the right has to fit a column.
			name: "a step with no detail or owner keeps its whole label",
			steps: []LedgerStep{
				{Glyph: "✓", Label: "Isolated workspace ready"},
				{Label: "Draft PR", Current: true, Detail: "checks running"},
			},
			want: []string{
				"✓  Isolated workspace ready",
				"▸  Draft PR  checks running",
			},
		},
		{
			name: "children sit five spaces under the step they belong to",
			steps: []LedgerStep{
				{Label: "Draft PR", Current: true, Children: []LedgerStep{
					{Glyph: "✓", Label: "fmt", When: "11s"},
					{Label: "plan (va1)", Detail: "running", Current: true},
				}},
				{Label: "Review & merge", Owner: "yours"},
			},
			// The child group aligns against its siblings, not against the
			// steps above it, so "11s" sits over the column "running" leaves
			// empty rather than over the parent's.
			want: []string{
				"▸  Draft PR",
				"     ✓  fmt                  11s",
				"     ▸  plan (va1)  running",
				"·  Review & merge  yours",
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			lines := stripLines(t, Message{Text: "task", Ledger: testCase.steps}, 0)
			if len(lines) != len(testCase.want) {
				t.Fatalf("ledger =\n%s\nwant\n%s",
					strings.Join(lines, "\n"), strings.Join(testCase.want, "\n"))
			}
			for index, line := range lines {
				if line != testCase.want[index] {
					t.Errorf("ledger line %d = %q, want %q", index, line, testCase.want[index])
				}
				if runes := utf8.RuneCountInString(line); runes > monospaceLineRunes {
					t.Errorf("ledger line %d is %d runes, over the %d the strip has",
						index, runes, monospaceLineRunes)
				}
			}
		})
	}
}

// Slack wraps a long preformatted line instead of scrolling it, and the wrapped
// remainder lands under the glyph column — so a single unbounded detail costs
// the whole strip its alignment. Detail is what gives way, because the label
// names the step and the glyph carries its state.
func TestLedgerDetailTruncatesWhileLabelAndGlyphSurvive(t *testing.T) {
	lines := stripLines(t, Message{Text: "task", Ledger: []LedgerStep{{
		Label:   "Making changes",
		Detail:  strings.Repeat("raising the allocation memory ", 4),
		When:    "2m",
		Current: true,
	}}}, 0)
	if len(lines) != 1 {
		t.Fatalf("ledger = %q", lines)
	}
	line := lines[0]
	if runes := utf8.RuneCountInString(line); runes != monospaceLineRunes {
		t.Fatalf("truncated line is %d runes, want exactly %d: %q", runes, monospaceLineRunes, line)
	}
	if !strings.HasPrefix(line, "▸  Making changes") {
		t.Errorf("truncation reached the glyph or the label: %q", line)
	}
	if !strings.Contains(line, "…") {
		t.Errorf("a clipped detail reads as a shorter detail unless it says so: %q", line)
	}
	if !strings.HasSuffix(line, "2m") {
		t.Errorf("the time is the answer to the line and was dropped: %q", line)
	}
}

// Colour is not allowed to be the only signal, and neither is position: every
// step carries a glyph, including the ones the caller left blank.
func TestLedgerAlwaysRendersAGlyphColumnAndMarksTheCurrentStep(t *testing.T) {
	lines := stripLines(t, Message{Text: "task", Ledger: []LedgerStep{
		{Label: "Workspace ready", When: "2:20 PM"},
		{Label: "Making changes", Current: true, When: "2m"},
		{Label: "Review & merge", Owner: "yours"},
	}}, 0)
	if len(lines) != 3 {
		t.Fatalf("ledger = %q", lines)
	}
	glyphs := []string{"·", "▸", "·"}
	for index, line := range lines {
		if !strings.HasPrefix(line, glyphs[index]+"  ") {
			t.Errorf("line %d = %q, want the %q column and a two-space gutter", index, line, glyphs[index])
		}
	}
	// The right column answers "when" or "whose" for every step, so it starts
	// in the same place on each of them.
	if first, second := column(lines[0], "2:20 PM"), column(lines[2], "yours"); first != second {
		t.Errorf("right column starts at %d and %d; the ledger is not aligned", first, second)
	}
}

// The window exists because the model's own progress prose is thin — "Still
// working; implementing and validating the focused change", twice, byte for
// byte — while the tool calls underneath it were specific the whole time. It
// stays three lines: the card is rewritten, never extended.
func TestActivityWindowKeepsTheThreeNewestLines(t *testing.T) {
	lines := stripLines(t, Message{Text: "task", Activity: []ActivityLine{
		{Kind: ActivityTool, Title: "vm.query_range", Target: "allocs_memory_rss · 2h"},
		{Kind: ActivityThinking, Title: "Planning PromQL queries for request rates"},
		{Kind: ActivityEdit, Title: "traefik.nomad.hcl", Target: "memory 4096 → 8192"},
		{Kind: ActivityTool, Title: "nomad.event_snapshot", Target: "oldest and dropped"},
	}}, 0)
	if len(lines) != 3 {
		t.Fatalf("activity window kept %d lines:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	for index, prefix := range []string{"⚡  ", "🧠  ", "✏  "} {
		if !strings.HasPrefix(lines[index], prefix) {
			t.Errorf("line %d = %q, want the %q glyph", index, lines[index], prefix)
		}
		if runes := utf8.RuneCountInString(lines[index]); runes > monospaceLineRunes {
			t.Errorf("line %d is %d runes, over the %d the strip has", index, runes, monospaceLineRunes)
		}
	}
	if strings.Contains(strings.Join(lines, "\n"), "dropped") {
		t.Error("the fourth entry rendered; callers pass newest first and the window holds three")
	}
	// The long reasoning summary has nothing after it, so it does not set the
	// column width the tool call above it has to live in.
	if !strings.Contains(lines[0], "allocs_memory_rss · 2h") {
		t.Errorf("the tool target was squeezed out by the reasoning line: %q", lines[0])
	}
}

// Everything on these lines was written by an agent transcript rather than by
// this package, and the renderer is the last place it can be caught.
func TestActivityRedactsCredentialsAndPackDigests(t *testing.T) {
	lines := stripLines(t, Message{Text: "task", Activity: []ActivityLine{{
		Kind:   ActivityTool,
		Title:  "auth with xoxb-123456789012-abcdefghij",
		Target: "victoriametrics@0.1.7/sha256:2cb5c57b3152aa9f1c0d4e5b6a7f80912cb5c57b3152aa9f1c0d4e5b6a7f8091",
	}}}, 0)
	line := strings.Join(lines, "\n")
	if strings.Contains(line, "xoxb-") || strings.Contains(line, "abcdefghij") {
		t.Errorf("a credential shape reached Slack: %q", line)
	}
	if strings.Contains(line, "sha256") || strings.Contains(line, "2cb5c57b") {
		t.Errorf("the pack digest reached Slack: %q", line)
	}
	// The version identifies the pack to a person; the digest identifies it to
	// a registry, and costs 71 of the 46 characters a line has.
	if !strings.Contains(line, "victoriametrics@0.1.7") {
		t.Errorf("digest stripping took the pack reference with it: %q", line)
	}
	if runes := utf8.RuneCountInString(line); runes > monospaceLineRunes {
		t.Errorf("line is %d runes, over the %d the strip has: %q", runes, monospaceLineRunes, line)
	}
}

// A transcript title arrives with whatever the agent put in it, including line
// breaks that would let one entry take the whole strip.
func TestActivityCollapsesMultilineTranscriptText(t *testing.T) {
	lines := stripLines(t, Message{Text: "task", Activity: []ActivityLine{
		{Kind: ActivityThinking, Title: "Planning\n\nPromQL   queries"},
		{Kind: "unrecognised", Title: "still rendered"},
	}}, 0)
	if len(lines) != 2 {
		t.Fatalf("activity = %q", lines)
	}
	if lines[0] != "🧠  Planning PromQL queries" {
		t.Errorf("line 0 = %q", lines[0])
	}
	// An unknown kind keeps its column rather than shifting the line left.
	if !strings.HasPrefix(lines[1], "·  still rendered") {
		t.Errorf("line 1 = %q", lines[1])
	}
}

func TestChipsRenderOneBoundedContextLine(t *testing.T) {
	message := Message{
		Text: "task",
		Chips: []Chip{
			{Label: "last activity", Value: "6s ago", Live: true},
			{Value: "87 tool calls"},
			{Label: "0 files changed"},
		},
		Context: []string{"Isolated fork — cannot merge or deploy"},
	}
	var contexts []string
	for _, block := range message.Blocks() {
		if context, ok := block.(*slack.ContextBlock); ok {
			var texts []string
			for _, element := range context.ContextElements.Elements {
				if text, ok := element.(*slack.TextBlockObject); ok {
					texts = append(texts, text.Text)
				}
			}
			contexts = append(contexts, strings.Join(texts, "\x1f"))
		}
	}
	if len(contexts) != 2 {
		t.Fatalf("expected a chip line and the footer, got %q", contexts)
	}
	// Chips are counters and sit above the footer: a reader who has learned to
	// skip the identifiers line would skip the counters with it.
	want := "last activity *6s ago* · *87 tool calls* · 0 files changed"
	if contexts[0] != want {
		t.Errorf("chip line = %q, want %q", contexts[0], want)
	}
	if !strings.Contains(contexts[1], "cannot merge or deploy") {
		t.Errorf("footer context = %q", contexts[1])
	}
}

func TestChipLineStaysWithinSlacksContextBound(t *testing.T) {
	chips := make([]Chip, 0, 60)
	for index := range 60 {
		chips = append(chips, Chip{Label: "counter " + strconv.Itoa(index), Value: "1234567890"})
	}
	line := chipLine(chips)
	if length := len(line); length == 0 || length > 500 {
		t.Fatalf("chip line is %d bytes, want 1..500", length)
	}
	if chipLine(nil) != "" {
		t.Error("no chips rendered a line anyway")
	}
}

// The ⋯ menu is the remainder of the bottom row, so it joins that row rather
// than starting one of its own.
func TestOverflowJoinsTheLastActionRow(t *testing.T) {
	message := Message{
		Text: "task",
		Actions: []Action{
			{ID: ActionChanges, Label: "View diff", Value: "task_1"},
			{ID: ActionStop, Label: "Stop", Value: "task_1"},
		},
		Overflow: []Action{
			{ID: ActionUpdate, Label: "Ask for an update", Value: "update~task_1"},
			{ID: ActionHelp, Label: strings.Repeat("How this works ", 10), Value: "help~task_1"},
		},
	}

	blocks := message.Blocks()
	actions, ok := blocks[len(blocks)-1].(*slack.ActionBlock)
	if !ok {
		t.Fatalf("last block is %T, want the action row", blocks[len(blocks)-1])
	}
	if len(actions.Elements.ElementSet) != 3 {
		t.Fatalf("action row holds %d elements, want two buttons and the menu",
			len(actions.Elements.ElementSet))
	}
	overflow, ok := actions.Elements.ElementSet[2].(*slack.OverflowBlockElement)
	if !ok {
		t.Fatalf("last element is %T, want the overflow menu", actions.Elements.ElementSet[2])
	}
	if overflow.ActionID != ActionOverflow {
		t.Errorf("overflow action_id = %q, want %q", overflow.ActionID, ActionOverflow)
	}
	if len(overflow.Options) != 2 {
		t.Fatalf("overflow holds %d options", len(overflow.Options))
	}
	// Every menu shares one action_id, so the option value is the only thing
	// that distinguishes Ask for an update from How this works. It carries the
	// action and its target, and both survive the round trip.
	if overflow.Options[0].Text.Text != "Ask for an update" {
		t.Errorf("first option = %+v", overflow.Options[0])
	}
	actionID, value, ok := DecodeOverflowOptionValue(overflow.Options[0].Value)
	if !ok || actionID != ActionUpdate || value != "update~task_1" {
		t.Errorf("first option value = %q -> %q/%q/%t",
			overflow.Options[0].Value, actionID, value, ok)
	}
	// Slack rejects a label over 75 characters, and the routing target travels
	// in the value, so the label is the only part that can be cut.
	if length := len(overflow.Options[1].Text.Text); length > 75 {
		t.Errorf("option label is %d characters, over Slack's 75", length)
	}
	actionID, value, ok = DecodeOverflowOptionValue(overflow.Options[1].Value)
	if !ok || actionID != ActionHelp || value != "help~task_1" {
		t.Errorf("option value = %q; routing lost its target",
			overflow.Options[1].Value)
	}
}

func TestOverflowRendersWithoutButtonsAndStaysWithinSlacksOptionLimit(t *testing.T) {
	message := Message{Text: "receipt"}
	for index := range 7 {
		message.Overflow = append(message.Overflow, Action{
			ID: ActionHelp, Label: "Option " + strconv.Itoa(index), Value: strconv.Itoa(index),
		})
	}
	blocks := message.Blocks()
	actions, ok := blocks[len(blocks)-1].(*slack.ActionBlock)
	if !ok {
		t.Fatalf("last block is %T, want an action row holding the menu", blocks[len(blocks)-1])
	}
	overflow, ok := actions.Elements.ElementSet[0].(*slack.OverflowBlockElement)
	if !ok {
		t.Fatalf("first element is %T, want the overflow menu", actions.Elements.ElementSet[0])
	}
	// Slack takes at most five, and rejects the message rather than the menu.
	if len(overflow.Options) != 5 {
		t.Errorf("overflow holds %d options, want Slack's ceiling of 5", len(overflow.Options))
	}
	// Neither actions nor overflow still means no divider and no empty row.
	if bare := (Message{Text: "receipt"}).Blocks(); len(bare) != 0 {
		t.Errorf("a message with no controls rendered %d blocks", len(bare))
	}
}

// Slack rejects a whole surface when two elements share an action_id, and the
// menu is subject to that with everything else — Phase 5 puts one on every row
// of a directory.
func TestOverflowActionIDsStayDistinctAcrossTheSurface(t *testing.T) {
	message := Message{Text: "list"}
	for range 3 {
		message.Actions = append(message.Actions,
			Action{ID: ActionKeepFixtureCandidate, Label: "Keep", Value: "a"},
		)
	}
	message.Overflow = []Action{{ID: ActionHelp, Label: "How this works", Value: "help"}}

	seen := map[string]int{}
	for _, block := range message.Blocks() {
		actions, ok := block.(*slack.ActionBlock)
		if !ok {
			continue
		}
		for _, element := range actions.Elements.ElementSet {
			switch typed := element.(type) {
			case *slack.ButtonBlockElement:
				seen[typed.ActionID]++
			case *slack.OverflowBlockElement:
				seen[typed.ActionID]++
			}
		}
	}
	if len(seen) != 4 {
		t.Fatalf("expected 4 distinct action ids across the surface, got %v", seen)
	}
	for actionID, count := range seen {
		if count > 1 {
			t.Errorf("action_id %q appears %d times", actionID, count)
		}
	}

	// A second menu on one surface takes the same suffix a repeated button
	// does, and routing recovers the action from it.
	occurrences := map[string]int{}
	first := overflowElement(message.Overflow, occurrences)
	second := overflowElement(message.Overflow, occurrences)
	if first.ActionID != ActionOverflow ||
		second.ActionID != ActionOverflow+ActionInstanceSeparator+"2" ||
		BaseActionID(second.ActionID) != ActionOverflow {
		t.Errorf("overflow ids = %q, %q", first.ActionID, second.ActionID)
	}
}

// Two card generations coexist during a rollout: a card stored by the binary
// that is running has to decode after the binary that reads it is replaced.
// Decode refuses unknown fields, which makes new fields safe to add and old
// binaries unsafe to go back to — deploy forward, never downgrade.
func TestStoredCardsDecodeAcrossCardGenerations(t *testing.T) {
	stored := []byte(`{"text":"Working on VA1","header":"VA1","sections":["Investigating."],` +
		`"context":["task 01ce33ab"],"actions":[{"id":"responder_stop","label":"Stop","value":"x"}]}`)
	previous, err := Decode(stored)
	if err != nil {
		t.Fatalf("a card stored by the previous generation no longer decodes: %v", err)
	}
	if previous.Text != "Working on VA1" || previous.Stripe != "" || len(previous.Ledger) != 0 {
		t.Fatalf("old card decoded as %+v", previous)
	}

	current := Message{
		Text:   "Working — VA1",
		Header: "⚙️ VA1",
		Stripe: StripeWorking,
		Ledger: []LedgerStep{{
			Glyph: "✓", Label: "Workspace ready", Detail: "fork", When: "2:20 PM",
			Owner: "emisar", Current: true,
			Children: []LedgerStep{{Label: "fmt", When: "11s"}},
		}},
		Activity: []ActivityLine{{Kind: ActivityTool, Title: "vm.query_range", Target: "rss"}},
		Chips:    []Chip{{Label: "tool calls", Value: "87", Live: true}},
		Overflow: []Action{{ID: ActionHelp, Label: "How this works", Value: "help"}},
	}
	encoded, err := Encode(current)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := Decode(encoded)
	if err != nil {
		t.Fatalf("a card this binary wrote does not decode: %v", err)
	}
	roundTripped, err := Encode(decoded)
	if err != nil {
		t.Fatal(err)
	}
	if string(roundTripped) != string(encoded) {
		t.Fatalf("round trip changed the card:\n%s\n%s", encoded, roundTripped)
	}

	// The reason additive is the only safe direction.
	if _, err := Decode([]byte(`{"text":"hi","invented_by_a_newer_binary":true}`)); err == nil {
		t.Fatal("Decode accepted an unknown field; the rollout constraint is gone")
	}
}

// Responder runs in UTC and the people reading it do not. Slack converts this
// token client-side; the fallback after the pipe is what a client that cannot
// renders, and what an export or a log keeps.
func TestSlackDateRendersLocalTimeWithAUTCFallback(t *testing.T) {
	when := time.Date(2026, 8, 13, 14, 20, 39, 0, time.FixedZone("CST", -5*60*60))
	token := slackDate(when, "2006-01-02 15:04 UTC")
	if !strings.HasPrefix(token, "<!date^"+strconv.FormatInt(when.Unix(), 10)+"^") {
		t.Errorf("token = %q; Slack needs the epoch first", token)
	}
	if !strings.Contains(token, "{date_short_pretty} at {time}") {
		t.Errorf("token = %q; the reader's own date and time are the point", token)
	}
	if !strings.HasSuffix(token, "|2026-08-13 19:20 UTC>") {
		t.Errorf("token = %q; the fallback is UTC whatever zone the caller held", token)
	}
	if got := slackDate(time.Time{}, "2006-01-02 15:04 UTC"); got != "" {
		t.Errorf("zero time rendered %q; an unset time has no wall clock to show", got)
	}
}

// The strips have to be legal Block Kit, and the element is hand-built because
// slack-go ships no constructor for it.
func TestPreformattedStripsAreLegalBlockKit(t *testing.T) {
	message := Message{
		Text:     "task",
		Ledger:   []LedgerStep{{Label: "Workspace ready", When: "2:20 PM"}},
		Activity: []ActivityLine{{Kind: ActivityTool, Title: "vm.query_range"}},
	}
	raw, err := json.Marshal(slack.Blocks{BlockSet: message.Blocks()})
	if err != nil {
		t.Fatal(err)
	}
	var probe []struct {
		Type     string `json:"type"`
		Elements []struct {
			Type     string `json:"type"`
			Elements []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"elements"`
		} `json:"elements"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		t.Fatal(err)
	}
	if len(probe) != 2 {
		t.Fatalf("expected the ledger and the activity strip, got %s", raw)
	}
	for index, block := range probe {
		if block.Type != "rich_text" ||
			len(block.Elements) != 1 ||
			block.Elements[0].Type != "rich_text_preformatted" ||
			len(block.Elements[0].Elements) != 1 ||
			block.Elements[0].Elements[0].Type != "text" ||
			block.Elements[0].Elements[0].Text == "" {
			t.Errorf("strip %d is not a preformatted rich text block: %s", index, raw)
		}
	}
}

// Blocks() renders the card in reading order, and the stripe is not part of it:
// colour lives on the attachment client.go wraps this in.
func TestCardRendersInReadingOrderAndIgnoresTheStripe(t *testing.T) {
	message := Message{
		Text:     "Working — VA1",
		Header:   "VA1",
		Stripe:   StripeNeedsYou,
		Sections: []string{"What changed"},
		Ledger:   []LedgerStep{{Label: "Draft PR", Current: true}},
		Activity: []ActivityLine{{Kind: ActivityTool, Title: "vm.query_range"}},
		Fields:   []Field{{Label: "Fork", Value: "remote-44f3f67"}},
		Chips:    []Chip{{Label: "tool calls", Value: "87"}},
		Context:  []string{"Isolated fork"},
		Actions:  []Action{{ID: ActionStop, Label: "Stop", Value: "x"}},
	}
	var order []string
	for _, block := range message.Blocks() {
		order = append(order, string(block.BlockType()))
	}
	want := []string{
		"header", "section", "rich_text", "rich_text", "section", "context", "context",
		"divider", "actions",
	}
	if strings.Join(order, ",") != strings.Join(want, ",") {
		t.Fatalf("block order = %v, want %v", order, want)
	}
	if strings.Contains(string(mustMarshal(t, message.Blocks())), StripeNeedsYou) {
		t.Error("the stripe reached the blocks; it belongs on the attachment")
	}
}

func mustMarshal(t *testing.T, blocks []slack.Block) []byte {
	t.Helper()
	raw, err := json.Marshal(slack.Blocks{BlockSet: blocks})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
