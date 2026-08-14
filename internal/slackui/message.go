package slackui

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
)

const (
	IncidentCardRevision = "2026-08-13.1"

	ActionUpdate          = "responder_update"
	ActionChanges         = "responder_changes"
	ActionChangesPrevious = "responder_changes_previous"
	ActionChangesNext     = "responder_changes_next"
	ActionChangesRefresh  = "responder_changes_refresh"
	ActionReview          = "responder_review"
	ActionRepairReview    = "responder_repair_review"
	ActionPublishPR       = "responder_publish_pr"
	ActionViewPR          = "responder_view_pr"
	ActionCheckDelivery   = "responder_check_delivery"
	ActionDiscardWork     = "responder_discard_work"
	ActionStop            = "responder_stop"
	ActionExtend          = "responder_extend"
	ActionResolve         = "responder_resolve"
	ActionHelp            = "responder_help"
	ActionOpenIncident    = "responder_open_incident"
	// A link out to the conversation an item lives in, so the page that says
	// something needs a decision can also get the reader to it.
	ActionOpenWorkThread     = "responder_open_work_thread"
	ActionStartTask          = "responder_start_engineering_task"
	ActionReviewPullRequest  = "responder_review_pull_request"
	ActionOpenApproval       = "responder_open_emisar_approval"
	ActionRememberMemory     = "responder_remember_memory"
	ActionForgetMemory       = "responder_forget_memory"
	ActionForgetMemoryRollup = "responder_forget_memory_rollup"
	ActionDismissFeedback    = "responder_dismiss_feedback"
	ActionConvertFeedback    = "responder_convert_feedback"
	// ActionConvertFeedbackBrief turns tone feedback into a typed response_detail
	// preference rather than guidance. Guidance is advisory — the model weighs
	// it. A preference is enforced by the host. "Be more concise", said three
	// times, should stop being a suggestion.
	ActionConvertFeedbackBrief = "responder_convert_feedback_brief"
	// ActionInstanceSeparator disambiguates repeated actions in one surface.
	// Chosen because no action constant contains it, so BaseActionID can strip
	// the suffix without knowing which action it is looking at.
	ActionInstanceSeparator = "__i"

	// Reviewing a correction that Responder was told was wrong, and deciding
	// whether the lesson is worth keeping as a regression fixture.
	ActionKeepFixtureCandidate    = "responder_keep_fixture_candidate"
	ActionDiscardFixtureCandidate = "responder_discard_fixture_candidate"
	ActionReviewMemory            = "responder_review_memory"
	ActionKeepMemoryReview        = "responder_keep_memory_review"
	ActionForgetMemoryReview      = "responder_forget_memory_review"
	ActionMergeMemoryReview       = "responder_merge_memory_review"
	ActionDismissMemoryReview     = "responder_dismiss_memory_review"
	ActionRememberPreference      = "responder_remember_preference"
	ActionTogglePreference        = "responder_toggle_preference"
	ActionEditPreference          = "responder_edit_preference"
	ActionDeletePreference        = "responder_delete_preference"
	ActionRememberRule            = "responder_remember_rule"
	ActionToggleRule              = "responder_toggle_rule"
	ActionEditRule                = "responder_edit_rule"
	ActionDeleteRule              = "responder_delete_rule"
	ActionRememberSchedule        = "responder_remember_schedule"
	ActionToggleSchedule          = "responder_toggle_schedule"
	ActionRunSchedule             = "responder_run_schedule"
	ActionEditSchedule            = "responder_edit_schedule"
	ActionDeleteSchedule          = "responder_delete_schedule"
	ActionSaveChannelConfig       = "responder_save_channel_config"
	ActionRestartChannelSetup     = "responder_restart_channel_setup"
	ActionCancelChannelSetup      = "responder_cancel_channel_setup"
	ActionSetupQuickMentions      = "responder_setup_quick_mentions"
	ActionSetupQuickProactive     = "responder_setup_quick_proactive"
	ActionSetupCustomize          = "responder_setup_customize"
	ActionSetupMentions           = "responder_setup_participation_mentions"
	ActionSetupProactive          = "responder_setup_participation_proactive"
	ActionSetupShadow             = "responder_setup_participation_shadow"
	ActionSetupRepository         = "responder_setup_repository_"
	ActionSetupDefaultRepo        = "responder_setup_repository_default"
	ActionSetupAlertReply         = "responder_setup_alert_reply"
	ActionSetupAlertOffer         = "responder_setup_alert_offer"
	ActionSetupAlertAutomatic     = "responder_setup_alert_automatic"
	ActionSetupOperatorsOnly      = "responder_setup_audience_operators"
	ActionSetupIncludeMe          = "responder_setup_audience_include_me"

	ActionCommandStatus            = "responder_command_status"
	ActionCommandOpenIncidents     = "responder_command_incidents_open"
	ActionCommandAllIncidents      = "responder_command_incidents_all"
	ActionCommandPreviousIncidents = "responder_command_incidents_previous"
	ActionCommandNextIncidents     = "responder_command_incidents_next"

	// ActionOverflow is the id every overflow menu carries. One id for every
	// menu on purpose: which item was chosen travels in the option value, the
	// same way a repeated button's row travels in its value, so routing needs
	// one entry rather than one per card.
	ActionOverflow = "responder_overflow"

	// ActionFullRequest posts the whole ask as a thread reply.
	//
	// The card shows a two-line lede because the request is reference material
	// and the card is an instrument — but the full text has to stay reachable,
	// or the card would be hiding the thing the work is about. Routing this to
	// FullRequestMessage is the next phase's edit; the id and the constructor
	// ship together so the button is never rendered without a destination.
	ActionFullRequest = "responder_full_request"
)

// Custody colours. The stripe answers one question — whose turn is it — and it
// is never a status taxonomy: queued, investigating and finishing all wear
// amber, because in all three the operator is waiting on Emisar and that is the
// only thing the colour is allowed to say.
//
// Colour never travels alone. A card that sets a stripe also states the glyph
// and the word, because notifications, the sidebar, and a colourblind reader
// all get the text and none of them get the stripe.
const (
	StripeWorking  = "#FAB219" // Emisar has it
	StripeNeedsYou = "#EC835A" // you have it
	StripeFailed   = "#D03B3B" // it stopped unexpectedly
	StripeDone     = "#0CA30C" // done, nothing outstanding
	StripeIdle     = "#8E9296" // parked, informational, nobody is waiting
)

// Activity kinds. The window shows what the agent is doing right now; the kind
// picks the glyph, and an unrecognised one still renders rather than shifting
// every column to the left.
const (
	ActivityThinking = "thinking"
	ActivityTool     = "tool"
	ActivityEdit     = "edit"
)

var (
	ansiPattern   = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]`)
	tokenPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b`),
		regexp.MustCompile(`(?i)\bxapp-[A-Za-z0-9-]{10,}\b`),
		regexp.MustCompile(`\bemk-[A-Za-z0-9_-]{10,}\b`),
		regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{20,}\b`),
		regexp.MustCompile(`\bAKIA[A-Z0-9]{16}\b`),
	}
	slackMentionPattern = regexp.MustCompile(`<(?:@[A-Z0-9]+|![^>]+)>`)
	// The exact shape slackDate emits, and nothing looser: an integer epoch,
	// then a format and a fallback that carry no angle brackets of their own.
	slackDatePattern = regexp.MustCompile(`^<!date\^\d+\^[^<>]*\|[^<>]*>$`)
	// <https://host/path|Label> renders as Label. A work title is often the
	// Slack message that started it, so it arrives full of these.
	slackLinkTextPattern = regexp.MustCompile(`<https?://[^|>]+\|([^>]*)>`)
	bareURLPattern       = regexp.MustCompile(`<?https?://[^\s|>]+>?`)
	// An Emisar pack ref arrives as `name@version/sha256:<64 hex>`. The digest
	// is what makes the reference immutable and what makes it unreadable, and
	// the version before it already identifies the pack to a person.
	packDigestPattern         = regexp.MustCompile(`/sha256:[0-9a-f]{8,}`)
	scheduleCommitmentPattern = regexp.MustCompile(`(?i)^\s*i(?:['’]ll| will)\s+`)
)

type Message struct {
	Text     string   `json:"text"`
	Header   string   `json:"header,omitempty"`
	Markdown string   `json:"markdown,omitempty"`
	Sections []string `json:"sections,omitempty"`
	// Rows are sections that own their buttons, rendered before Fields with
	// each row's controls directly beneath its text.
	//
	// Sections and Actions are parallel lists, which is right for a card with
	// one set of controls and wrong for a list of things to act on: every
	// button lands in a single pile at the bottom. The App Home ended up with
	// nineteen of them — "Keep 1" through "Discard 5" mixed in with preference
	// and rule controls, all far from the items they referred to, and no way to
	// tell which was which. A caller rendering a list should use Rows.
	Rows    []Row    `json:"rows,omitempty"`
	Fields  []Field  `json:"fields,omitempty"`
	Context []string `json:"context,omitempty"`
	Actions []Action `json:"actions,omitempty"`
	// Stripe is the custody colour, applied by client.go rather than by
	// Blocks: colour lives on an attachment, which is the one thing a bot can
	// tint and the one thing that is not a block. Empty renders as before.
	Stripe string `json:"stripe,omitempty"`
	// Ledger states where a run has got to by position instead of by
	// adjective, so "step 4 of 5" is read rather than inferred from prose.
	Ledger []LedgerStep `json:"ledger,omitempty"`
	// Activity is the live window onto the turn. It exists because the model's
	// own progress prose is structurally thin — "Still working", twice, byte
	// for byte — while the tool calls underneath it are specific and already
	// recorded. Newest first; the renderer keeps three.
	Activity []ActivityLine `json:"activity,omitempty"`
	Chips    []Chip         `json:"chips,omitempty"`
	// Overflow holds the controls that did not earn a button. Slack shows them
	// behind ⋯, which keeps the bottom row at the few actions worth pressing.
	Overflow []Action `json:"overflow,omitempty"`
}

// LedgerStep is one step of a run.
//
// When and Owner are the same column: a finished step says when it finished, an
// unstarted one says who it is waiting for ("Review & merge — yours"), and no
// step needs both. Children are the checks under a running step, not steps of
// their own.
type LedgerStep struct {
	Glyph  string `json:"glyph,omitempty"`
	Label  string `json:"label"`
	Detail string `json:"detail,omitempty"`
	When   string `json:"when,omitempty"`
	Owner  string `json:"owner,omitempty"`
	// Current marks where the run is now. It picks the glyph when the caller
	// did not supply one, so the mark survives a caller that only knows the
	// order of its steps.
	Current  bool         `json:"current,omitempty"`
	Children []LedgerStep `json:"children,omitempty"`
}

// ActivityLine is one entry in the live window: a reasoning summary title, a
// tool call, or a file edit. Never raw thinking — the title is the whole of
// what the model's reasoning is allowed to say in Slack.
type ActivityLine struct {
	Kind   string `json:"kind,omitempty"`
	Title  string `json:"title"`
	Target string `json:"target,omitempty"`
}

// Chip is one counter in the card's context line.
//
// Live marks a value that moves while the card is open (`last activity 6s
// ago`). It changes nothing about the rendering — Slack has no live text, and a
// chip that looked animated while only moving on rewrite would lie about
// freshness — so it is stored for the caller deciding what to refresh.
type Chip struct {
	Label string `json:"label"`
	Value string `json:"value"`
	Live  bool   `json:"live,omitempty"`
}

// LiveTurn is what a card knows about the turn running behind it.
//
// It is the answer to the failure this design was built from: a 57-minute turn
// that made 119 tool calls while the card said "Still working" twice, byte for
// byte, because the only account of the work was the model's summary of
// itself. Everything here was already recorded at the moment it happened, and
// none of it is generated for the card.
//
// The zero value is a card with no turn behind it, which is most cards.
type LiveTurn struct {
	// Active is whether a turn is running now. It decides whether the card
	// shows a window at all: the window is the present tense, and a finished
	// turn's last three lines would be a claim that it is still going.
	Active bool
	// Lines are newest first. The renderer keeps three.
	Lines []ActivityLine
	// ToolCalls and Evidence are the whole turn, not the window. The gap
	// between them and the three lines above is the point.
	ToolCalls int
	Evidence  int
	// Claim is the most recent recorded evidence claim, written once when it
	// was recorded and never re-summarized: a finding must not drift because a
	// card refreshed.
	Claim string
	// LastActivity is the newest moment of any kind. Reasoning counts — a turn
	// thinking hard is not a turn that stopped.
	LastActivity time.Time
}

// Recorded reports whether the turn narrated anything at all, which is a
// different question from whether it narrated anything worth showing.
//
// LastActivity is included deliberately. A turn that has so far only reasoned
// has no lines and no tool calls and is emphatically not idle; "last activity
// 3s ago · 0 tool calls" is the truth about it, and suppressing the whole strip
// would leave the operator with the one thing this design exists to remove — a
// card that says nothing while the work says plenty.
func (l LiveTurn) Recorded() bool {
	return l.ToolCalls > 0 || len(l.Lines) > 0 || !l.LastActivity.IsZero()
}

// Row is one item in a list, with the controls that act on that item.
//
// After records how many Sections existed when the row was appended, so rows
// render in the position they were added rather than after every section. A
// heading is a section and its items are rows; without this the App Home
// stacked "Responder preferences", "Standing rules" and "Corrections worth
// keeping?" together and then listed every row beneath all three.
type Row struct {
	Text    string   `json:"text"`
	Actions []Action `json:"actions,omitempty"`
	After   int      `json:"after,omitempty"`
}

// AppendRow adds a row directly beneath the sections added so far.
func AppendRow(message Message, text string, actions []Action) Message {
	message.Rows = append(message.Rows, Row{
		Text: text, Actions: actions, After: len(message.Sections),
	})
	return message
}

type Field struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

type Action struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Value   string `json:"value"`
	Style   string `json:"style,omitempty"`
	Confirm string `json:"confirm,omitempty"`
	URL     string `json:"url,omitempty"`
}

// truncateUTF8 bounds a payload at Slack's Block Kit limits. A payload over
// any of them is rejected at delivery — after the work is done, and in a way
// the agent cannot explain to whoever is waiting. Not every field that reaches
// a card is bounded upstream (a preference value and a standing-rule trigger
// are not), so the bound belongs here, at the one point every outgoing message
// passes through.
func truncateUTF8(value string, limit int) string {
	return core.TruncateUTF8(value, limit)
}

func Encode(message Message) ([]byte, error) {
	return json.Marshal(message)
}

func Decode(data []byte) (Message, error) {
	var message Message
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&message); err != nil {
		return Message{}, err
	}
	if strings.TrimSpace(message.Text) == "" {
		return Message{}, fmt.Errorf("Slack message fallback text is required")
	}
	return message, nil
}

func (m Message) Blocks() []slack.Block {
	blocks := make([]slack.Block, 0, 12)
	// Slack rejects a surface whose action_ids repeat, and a list UI repeats one
	// by nature: five "Keep" buttons all carry the keep action. Counted across
	// the whole surface, not per block, because a view is rejected either way.
	occurrences := make(map[string]int, len(m.Actions))
	if m.Header != "" {
		blocks = append(blocks, slack.NewHeaderBlock(
			slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(singleLine(m.Header), 150), false, false),
		))
	}
	if m.Markdown != "" {
		blocks = append(blocks, slack.NewMarkdownBlock(
			"",
			truncateMarkdown(m.Markdown, 12000),
		))
	}
	emitRows := func(after int) {
		for _, row := range m.Rows {
			if row.After != after || row.Text == "" {
				continue
			}
			blocks = append(blocks, slack.NewSectionBlock(
				slack.NewTextBlockObject(slack.MarkdownType, truncateUTF8(row.Text, 2900), false, true),
				nil, nil,
			))
			if elements := buttonElements(row.Actions, occurrences); len(elements) > 0 {
				blocks = append(blocks, slack.NewActionBlock("", elements...))
			}
		}
	}
	emitRows(0)
	for index, section := range m.Sections {
		if section != "" {
			blocks = append(blocks, slack.NewSectionBlock(
				slack.NewTextBlockObject(slack.MarkdownType, truncateUTF8(section, 2900), false, true),
				nil, nil,
			))
		}
		emitRows(index + 1)
	}
	if block := preformattedBlock(ledgerLines(m.Ledger, 0)); block != nil {
		blocks = append(blocks, block)
	}
	if block := preformattedBlock(activityLines(m.Activity)); block != nil {
		blocks = append(blocks, block)
	}
	// Slack allows ten fields in a section and rejects the whole surface over
	// that, which is how the App Home came to publish nothing at all: the
	// dashboard carries a dozen counters, so every view it ever built was
	// invalid. Chunked rather than truncated — dropping the last two counters
	// silently would trade a visible failure for an invisible one.
	for start := 0; start < len(m.Fields); start += 10 {
		end := min(start+10, len(m.Fields))
		fields := make([]*slack.TextBlockObject, 0, end-start)
		for _, field := range m.Fields[start:end] {
			fields = append(fields, slack.NewTextBlockObject(
				slack.MarkdownType,
				fmt.Sprintf("*%s*\n%s", truncateUTF8(field.Label, 100), truncateUTF8(field.Value, 500)),
				false, true,
			))
		}
		blocks = append(blocks, slack.NewSectionBlock(nil, fields, nil))
	}
	// Chips are counters, so they sit above the footer rather than in it: the
	// footer states identifiers and boundaries, which do not change, and a
	// reader who has learned to skip that line would skip the counters too.
	if line := chipLine(m.Chips); line != "" {
		blocks = append(blocks, slack.NewContextBlock("",
			slack.NewTextBlockObject(slack.MarkdownType, line, false, true),
		))
	}
	if len(m.Context) > 0 {
		elements := make([]slack.MixedElement, 0, len(m.Context))
		for _, text := range m.Context {
			elements = append(elements, slack.NewTextBlockObject(
				slack.MarkdownType, truncateUTF8(text, 500), false, true,
			))
		}
		blocks = append(blocks, slack.NewContextBlock("", elements...))
	}
	if len(m.Actions) > 0 || len(m.Overflow) > 0 {
		blocks = append(blocks, slack.NewDividerBlock())
		actionBlocks := make([]*slack.ActionBlock, 0, len(m.Actions)/4+1)
		for begin := 0; begin < len(m.Actions); begin += 4 {
			stop := min(begin+4, len(m.Actions))
			elements := buttonElements(m.Actions[begin:stop], occurrences)
			if len(elements) == 0 {
				continue
			}
			actionBlocks = append(actionBlocks, slack.NewActionBlock("", elements...))
		}
		// The menu belongs beside the buttons it is the remainder of, so it
		// joins the last row rather than starting one of its own.
		if overflow := overflowElement(m.Overflow, occurrences); overflow != nil {
			if len(actionBlocks) == 0 {
				actionBlocks = append(actionBlocks, slack.NewActionBlock("", overflow))
			} else {
				last := actionBlocks[len(actionBlocks)-1]
				last.Elements.ElementSet = append(last.Elements.ElementSet, overflow)
			}
		}
		for _, block := range actionBlocks {
			blocks = append(blocks, block)
		}
	}
	return blocks
}

// buttonElements renders one group of buttons, suffixing an action_id that has
// already appeared on this surface. The suffix is stripped again by
// BaseActionID during routing; which copy was clicked travels in Value.
func buttonElements(actions []Action, occurrences map[string]int) []slack.BlockElement {
	elements := make([]slack.BlockElement, 0, len(actions))
	for _, action := range actions {
		if action.ID == "" {
			continue
		}
		actionID := action.ID
		occurrences[action.ID]++
		if seen := occurrences[action.ID]; seen > 1 {
			actionID = fmt.Sprintf("%s%s%d", action.ID, ActionInstanceSeparator, seen)
		}
		button := slack.NewButtonBlockElement(
			actionID,
			action.Value,
			slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(action.Label, 75), false, false),
		)
		switch action.Style {
		case "primary":
			button.WithStyle(slack.StylePrimary)
		case "danger":
			button.WithStyle(slack.StyleDanger)
		}
		if action.URL != "" {
			button.WithURL(action.URL)
		}
		if action.Confirm != "" {
			button.WithConfirm(slack.NewConfirmationBlockObject(
				slack.NewTextBlockObject(slack.PlainTextType, "Confirm action", false, false),
				slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(action.Confirm, 300), false, false),
				slack.NewTextBlockObject(slack.PlainTextType, "Confirm", false, false),
				slack.NewTextBlockObject(slack.PlainTextType, "Cancel", false, false),
			))
		}
		elements = append(elements, button)
	}
	return elements
}

// overflowElement renders the ⋯ menu.
//
// Slack sends the menu's action_id and the chosen option's value, and nothing
// about which option object it came from, so the value carries the target the
// same way a repeated button's value does. Each option's own Action.ID is
// therefore unused; it stays on the struct because callers build overflow
// entries from the same Action they would have made a button from.
//
// There is no per-option confirmation in Block Kit. The element takes a single
// confirm dialog, which would then guard every option including the harmless
// ones and teach the operator to dismiss it — so an overflow holds only
// reversible or read-only actions, and anything that destroys retained work
// stays on a button with its own confirm, or moves into a modal.
func overflowElement(actions []Action, occurrences map[string]int) *slack.OverflowBlockElement {
	options := make([]*slack.OptionBlockObject, 0, len(actions))
	for _, action := range actions {
		if action.Label == "" {
			continue
		}
		// Slack accepts at most five options and rejects the message over
		// that. Unlike fields there is nothing to chunk into — a second menu
		// would be a second ⋯ with no way to tell them apart — so the bound is
		// the caller's to respect, and this only stops the delivery failure.
		if len(options) == 5 {
			break
		}
		options = append(options, slack.NewOptionBlockObject(
			action.Value,
			slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(action.Label, 75), false, false),
			nil,
		))
	}
	if len(options) == 0 {
		return nil
	}
	actionID := ActionOverflow
	occurrences[ActionOverflow]++
	if seen := occurrences[ActionOverflow]; seen > 1 {
		actionID = fmt.Sprintf("%s%s%d", ActionOverflow, ActionInstanceSeparator, seen)
	}
	return slack.NewOverflowBlockElement(actionID, options...)
}

// A monospace strip is the only place a card can hold columns, and Slack wraps
// a long line rather than scrolling it: the overflow lands under the glyph
// column and the alignment that made the strip scannable is gone. So the strips
// truncate to a width that survives a phone in portrait instead of letting
// Slack choose where to break. The bound is load-bearing rather than tidy — a
// real pack ref carries a 64-character digest and a PromQL expression has no
// bound at all.
const monospaceLineRunes = 46

// Children sit five spaces in: far enough that a check reads as belonging to
// the step above it, near enough that it is still the same instrument.
const ledgerChildIndent = 5

type monoRow struct{ glyph, label, detail, right string }

// monoLines lays rows out in columns separated by a two-space gutter, shrinking
// the columns until the widest line fits.
//
// Detail gives way before Label, because a label names the step and a detail
// only qualifies it, and the glyph column never yields at all — losing the
// glyph would cost the reader the state itself, which is the one thing the
// strip exists to show.
func monoLines(rows []monoRow, limit int) []string {
	if len(rows) == 0 {
		return nil
	}
	var glyphWidth, labelWidth, detailWidth, rightWidth int
	for _, row := range rows {
		glyphWidth = max(glyphWidth, utf8.RuneCountInString(row.glyph))
		// A cell only claims a column when something follows it on its line.
		// Otherwise the one long reasoning summary in a window — "Planning
		// PromQL queries for request rates" — would set the width every tool
		// call underneath it has to live with, and squeeze their targets, the
		// part that says which tool it actually was, down to an ellipsis.
		if row.detail != "" || row.right != "" {
			labelWidth = max(labelWidth, utf8.RuneCountInString(row.label))
		}
		detailWidth = max(detailWidth, utf8.RuneCountInString(row.detail))
		rightWidth = max(rightWidth, utf8.RuneCountInString(row.right))
	}
	glyphWidth = max(glyphWidth, 1)
	width := func(label, detail int) int {
		total := glyphWidth + 2 + label
		if detail > 0 {
			total += 2 + detail
		}
		if rightWidth > 0 {
			total += 2 + rightWidth
		}
		return total
	}
	if over := width(labelWidth, detailWidth) - limit; over > 0 && detailWidth > 0 {
		detailWidth = max(1, detailWidth-over)
	}
	if over := width(labelWidth, detailWidth) - limit; over > 0 {
		labelWidth = max(1, labelWidth-over)
	}
	lines := make([]string, 0, len(rows))
	for _, row := range rows {
		var line strings.Builder
		line.WriteString(padRunes(row.glyph, glyphWidth))
		line.WriteString("  ")
		if row.detail == "" && row.right == "" {
			// Nothing follows, so the label keeps its own length and only the
			// line bound applies to it.
			lines = append(lines, truncateRunes(strings.TrimRight(line.String()+row.label, " "), limit))
			continue
		}
		line.WriteString(padRunes(truncateRunes(row.label, labelWidth), labelWidth))
		if detailWidth > 0 {
			line.WriteString("  ")
			line.WriteString(padRunes(truncateRunes(row.detail, detailWidth), detailWidth))
		}
		if rightWidth > 0 {
			line.WriteString("  ")
			line.WriteString(row.right)
		}
		// The right column is the answer to "when" or "whose", so it is never
		// shrunk with the others; the line bound still applies to it last.
		lines = append(lines, truncateRunes(strings.TrimRight(line.String(), " "), limit))
	}
	return lines
}

func padRunes(value string, width int) string {
	if pad := width - utf8.RuneCountInString(value); pad > 0 {
		return value + strings.Repeat(" ", pad)
	}
	return value
}

// truncateRunes cuts by rune rather than by byte, because these lines are
// measured in columns: core.TruncateUTF8 bounds a payload, this bounds a shape.
// The ellipsis costs one of them and is worth it — a silently clipped tool
// target reads as a different tool.
func truncateRunes(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return strings.TrimRight(string(runes[:limit-1]), " ") + "…"
}

// preformattedBlock renders literal, already-bounded lines.
//
// rich_text_preformatted rather than a fenced section because Slack never
// parses its text as mrkdwn: a model-written activity title cannot open a link,
// a mention, or a code fence out of a strip it is only supposed to describe.
// slack-go v0.22.0 ships no constructor for the element — only NewRichTextBlock
// and the section elements — so the struct literal is the supported form.
func preformattedBlock(lines []string) slack.Block {
	if len(lines) == 0 {
		return nil
	}
	return slack.NewRichTextBlock("", &slack.RichTextPreformatted{
		Type: slack.RTEPreformatted,
		Elements: []slack.RichTextSectionElement{
			slack.NewRichTextSectionTextElement(strings.Join(lines, "\n"), nil),
		},
	})
}

func ledgerLines(steps []LedgerStep, indent int) []string {
	limit := monospaceLineRunes - indent
	// Nesting deeper than the strip is wide has nothing left to say.
	if len(steps) == 0 || limit < 8 {
		return nil
	}
	rows := make([]monoRow, 0, len(steps))
	for _, step := range steps {
		rows = append(rows, monoRow{
			glyph:  ledgerGlyph(step),
			label:  step.Label,
			detail: step.Detail,
			right:  firstNonemptyUI(step.When, step.Owner),
		})
	}
	aligned := monoLines(rows, limit)
	prefix := strings.Repeat(" ", indent)
	lines := make([]string, 0, len(aligned))
	for index, line := range aligned {
		lines = append(lines, prefix+line)
		// A child group aligns against its siblings, not against the steps
		// above it: the checks under "Draft PR" are their own small table.
		lines = append(lines, ledgerLines(steps[index].Children, indent+ledgerChildIndent)...)
	}
	return lines
}

func ledgerGlyph(step LedgerStep) string {
	switch {
	case step.Glyph != "":
		return step.Glyph
	case step.Current:
		return "▸"
	default:
		return "·"
	}
}

// activityLines keeps the first three entries. Callers pass newest first, and
// the window is a window: a fourth line would push the card taller every turn,
// and the card is a fixed-height instrument that is rewritten, never extended.
func activityLines(activity []ActivityLine) []string {
	if len(activity) == 0 {
		return nil
	}
	rows := make([]monoRow, 0, 3)
	for _, line := range activity[:min(len(activity), 3)] {
		rows = append(rows, monoRow{
			glyph:  activityGlyph(line.Kind),
			label:  activityText(line.Title),
			detail: activityText(line.Target),
		})
	}
	return monoLines(rows, monospaceLineRunes)
}

func activityGlyph(kind string) string {
	switch kind {
	case ActivityThinking:
		return "🧠"
	case ActivityTool:
		return "⚡"
	case ActivityEdit:
		return "✏"
	default:
		return "·"
	}
}

// activityText is the sanitizer boundary for the live window.
//
// Every string here comes from an agent transcript rather than from this
// package, so it is treated as hostile: ANSI escapes and credential shapes go
// first, then the digest a pack ref drags behind it, then the line breaks that
// would let one entry occupy the whole strip. Sanitizer.Text is a method on an
// instance the renderer does not have, so the shared patterns are applied
// directly — the renderer is the last place this text can be caught.
func activityText(value string) string {
	value = ansiPattern.ReplaceAllString(value, "")
	for _, pattern := range tokenPatterns {
		value = pattern.ReplaceAllString(value, "[REDACTED]")
	}
	// `victoriametrics@0.1.7/sha256:2cb5c…` says nothing the version did not
	// already say, and it is 71 of the 46 characters a line has.
	value = packDigestPattern.ReplaceAllString(value, "")
	return singleLine(value)
}

// chipLine renders the counters as one context line. Bold on the value because
// the label is the constant and the number is the news.
func chipLine(chips []Chip) string {
	if len(chips) == 0 {
		return ""
	}
	parts := make([]string, 0, len(chips))
	for _, chip := range chips {
		switch {
		case chip.Label != "" && chip.Value != "":
			// One asterisk: Slack's mrkdwn bold is not Markdown's, and `**x**`
			// renders the asterisks.
			parts = append(parts, chip.Label+" *"+chip.Value+"*")
		case chip.Value != "":
			parts = append(parts, "*"+chip.Value+"*")
		case chip.Label != "":
			parts = append(parts, chip.Label)
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return truncateUTF8(strings.Join(parts, " · "), 500)
}

func (m Message) FileBlocks() []slack.Block {
	blocks := m.Blocks()
	result := make([]slack.Block, 0, len(blocks)+4)
	for _, block := range blocks {
		markdown, ok := block.(*slack.MarkdownBlock)
		if !ok {
			result = append(result, block)
			continue
		}
		for _, chunk := range splitSlackBlockText(markdown.Text, 2900) {
			result = append(result, slack.NewSectionBlock(
				slack.NewTextBlockObject(slack.MarkdownType, chunk, false, true),
				nil,
				nil,
			))
		}
	}
	return result
}

func splitSlackBlockText(value string, limit int) []string {
	value = strings.TrimSpace(value)
	if value == "" || limit < 1 {
		return nil
	}
	result := make([]string, 0, len(value)/limit+1)
	for len(value) > limit {
		end := limit
		for !utf8.ValidString(value[:end]) {
			end--
		}
		if split := strings.LastIndexByte(value[:end], '\n'); split >= limit/2 {
			end = split + 1
		}
		chunk := strings.TrimSpace(value[:end])
		if chunk != "" {
			result = append(result, chunk)
		}
		value = strings.TrimSpace(value[end:])
	}
	if value != "" {
		result = append(result, value)
	}
	return result
}

func correlationExplanation(incident core.Incident, signals []core.Signal) string {
	if len(signals) < 2 || incident.Route == "manual" {
		return ""
	}
	labels := make([]string, 0, 4)
	for _, name := range []string{"cluster", "namespace", "service", "job"} {
		value := signals[0].Labels[name]
		if value == "" {
			continue
		}
		same := true
		for _, signal := range signals[1:] {
			if signal.Labels[name] != value {
				same = false
				break
			}
		}
		if same {
			labels = append(labels, fmt.Sprintf("`%s=%s`", name, value))
		}
	}
	reason := "The source supplied the same stable incident grouping key."
	if len(labels) > 0 {
		reason += " Shared topology labels: " + strings.Join(labels, ", ") + "."
	}
	reason += " This groups alert signals only; Responder still verifies whether they share a runtime cause."
	return reason
}

func ConversationResponse(text string, sanitizer *Sanitizer) Message {
	text = sanitizer.Text(text)
	if text == "" {
		text = "I could not produce a response."
	}
	return Message{
		Text:     truncateUTF8(text, 4000),
		Markdown: truncateMarkdown(text, 12000),
	}
}

func timeLocation(name string) *time.Location {
	location, err := time.LoadLocation(name)
	if err != nil {
		return time.UTC
	}
	return location
}

func firstNonemptyUI(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func behaviorToggleValue(id string, enabled bool) string {
	data, _ := json.Marshal(struct {
		ID      string `json:"id"`
		Enabled bool   `json:"enabled"`
	}{ID: id, Enabled: enabled})
	return string(data)
}

func guidanceEntryScopeLabel(entry core.MemoryEntry) string {
	switch {
	case entry.ScopeKind == "workspace" && entry.VisibilityKind == "operator":
		return "only you, across this workspace"
	case entry.ScopeKind == "workspace" && entry.VisibilityKind == "workspace":
		return "everyone in this workspace"
	case entry.ScopeKind == "channel":
		return "<#" + escapeSlackText(entry.ScopeKey) + ">"
	case entry.ScopeKind == "repository" && entry.VisibilityKind == "operator":
		return "only you, for repository `" + escapeSlackText(entry.ScopeKey) + "`"
	case entry.ScopeKind == "repository":
		return "repository `" + escapeSlackText(entry.ScopeKey) + "`"
	default:
		return "`" + escapeSlackText(entry.ScopeKind+":"+entry.ScopeKey) + "`"
	}
}

func shortSHA(value string) string {
	if len(value) > 12 {
		return value[:12]
	}
	return value
}

// slackDate renders a wall time in the reader's own timezone.
//
// Responder runs in UTC and the people reading it do not, so every absolute
// time in a card body has been asking its reader to do arithmetic. Slack does
// that conversion client-side from this token; the fallback after the pipe is
// what a client that cannot renders instead, and it stays UTC because it is
// also what the message looks like in a log or an export.
func slackDate(t time.Time, fallbackLayout string) string {
	if t.IsZero() {
		return ""
	}
	return fmt.Sprintf(
		"<!date^%d^{date_short_pretty} at {time}|%s>",
		t.Unix(),
		t.UTC().Format(fallbackLayout),
	)
}

// custody is the question the stripe answers: whose turn is it.
//
// It is deliberately not the status taxonomy. Queued, investigating and
// publishing are three different things a card can say in words, and one thing
// as far as the colour is concerned — the operator is waiting on Emisar. The
// card derives its primary button from this and nothing else, which is what
// keeps "one primary, earned" from decaying into a green button per state.
type custody int

const (
	// custodyEmisar: Emisar is working. No primary button anywhere on the
	// card, and the state line ends in "nothing needed from you".
	custodyEmisar custody = iota
	// custodyOperator: something specific is wanted from a person, and the
	// state line names it.
	custodyOperator
	// custodyNobody: terminal or idle. Nothing is running and nothing is
	// owed, which is a different sentence from either of the above.
	custodyNobody
)

// cardState is what a work card is, resolved once.
//
// Colour, glyph and word are produced together because they must agree and
// each reaches a different reader: the stripe is invisible in a notification,
// the glyph is stripped by the sidebar, and neither survives a screen reader.
// A resolver that returned only a colour would let the three drift apart one
// branch at a time, which is how the card being replaced ended up with eleven
// conditional sections and no single answer to "what is this".
type cardState struct {
	Stripe  string
	Glyph   string
	Word    string
	Custody custody
}

// Header renders "<glyph> <title>" — the first of the two lines rule 1 gives a
// card to answer what this is.
func (s cardState) Header(title string) string {
	title = singleLine(title)
	if s.Glyph == "" {
		return truncateUTF8(title, 150)
	}
	return truncateUTF8(s.Glyph+" "+title, 150)
}

// stateLine is the second line: what state, where, how old, and what is wanted.
//
// It ends with the ask or its absence, always. A card that cannot say which of
// those two it is has not earned the operator's attention.
func (s cardState) stateLine(where, age, ask string) string {
	parts := []string{"*" + s.Word + "*"}
	for _, part := range []string{where, age} {
		if strings.TrimSpace(part) != "" {
			parts = append(parts, part)
		}
	}
	if strings.TrimSpace(ask) != "" {
		parts = append(parts, "*"+ask+"*")
	}
	return strings.Join(parts, "  ·  ")
}

// cardAge is the relative age of a card's subject, or "" when the timestamp
// never made it into the record. An age of "55 years" is what a zero time
// renders as, and it would be the loudest thing on the card.
func cardAge(created, now time.Time) string {
	if created.IsZero() {
		return ""
	}
	return compactDuration(now.Sub(created))
}

// externalText is the boundary for strings this package did not write.
//
// Alert labels, signal titles and requester prose all reach a card from
// outside the process. Sanitizer runs over an assembled Message, but it is
// constructed per-caller and the card functions do not hold one, so the
// shapes that must never render — escape sequences, credentials, a pack
// digest, an embedded newline that would take a monospace column with it —
// are stripped where the value is read.
func externalText(value string) string {
	return activityText(value)
}

func WithRepositoryGateRecommendation(message Message) Message {
	message.Context = append(message.Context,
		"Recommendation: add `gate:` to `.agent/project.yaml` so future draft-PR reviews run the repository's validation command.",
	)
	return message
}

func WithIncompleteValidationWarning(message Message) Message {
	message.Context = append(message.Context,
		"Validation warning: the repository gate did not complete cleanly. Review the PR diff and GitHub checks before merging.",
	)
	return message
}

func EvidenceResponse(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sanitizer *Sanitizer,
) Message {
	message := ConversationResponse(text, sanitizer)
	message.Markdown = truncateMarkdown(
		message.Markdown+evidenceMarkdown(evidence, coverage),
		12000,
	)
	message.Text = truncateUTF8(message.Text+evidenceFallback(evidence, coverage), 4000)
	return message
}

func ConciseEvidenceResponse(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sanitizer *Sanitizer,
) Message {
	message := EvidenceResponse(text, nil, nil, sanitizer)
	if summary := evidenceRecordSummary(evidence, coverage); summary != "" {
		message.Context = append(message.Context, summary)
	}
	return message
}

func WithBlockedAssessment(
	message Message,
	summary string,
	materialGaps []string,
	attempts []string,
	nextAction string,
	sanitizer *Sanitizer,
) Message {
	clean := func(value string) string {
		value = strings.TrimSpace(value)
		if sanitizer != nil {
			value = sanitizer.Text(value)
		}
		return escapeSlackText(value)
	}
	// Completion gaps and attempted routes remain typed episode data for audit,
	// replay, and operator inspection. The model's completion message is the
	// human-facing explanation; projecting the whole ledger again makes Slack
	// replies repetitive and bureaucratic.
	_ = materialGaps
	_ = attempts
	parts := make([]string, 0, 2)
	if summary = clean(summary); summary != "" {
		parts = append(parts, "Blocked: "+summary)
	}
	if nextAction = clean(nextAction); nextAction != "" {
		parts = append(parts, "Next: "+nextAction)
	}
	if len(parts) > 0 {
		message.Context = append(message.Context, truncateUTF8(strings.Join(parts, " · "), 700))
	}
	return message
}

func evidenceRecordSummary(evidence []core.Evidence, coverage []core.Coverage) string {
	var parts []string
	if len(evidence) > 0 {
		parts = append(parts, countLabel(len(evidence), "finding"))
	}
	if len(coverage) > 0 {
		parts = append(parts, countLabel(len(coverage), "system area checked", "system areas checked"))
	}
	if len(parts) == 0 {
		return ""
	}
	return "Details saved: " + strings.Join(parts, " and ") + "."
}

func countLabel(count int, singular string, plural ...string) string {
	label := singular
	if count != 1 {
		label = singular + "s"
		if len(plural) > 0 {
			label = plural[0]
		}
	}
	return fmt.Sprintf("%d %s", count, label)
}

func evidenceMarkdown(
	evidence []core.Evidence,
	coverage []core.Coverage,
) string {
	var output strings.Builder
	if len(coverage) > 0 {
		output.WriteString("\n\n## Coverage\n\n| Layer | State | Source |\n|---|---|---|\n")
		for _, item := range coverage[:min(len(coverage), 12)] {
			fmt.Fprintf(
				&output,
				"| %s | %s | %s |\n",
				markdownCell(item.Layer),
				markdownCell(item.Status),
				markdownCell(displayOr(item.Source, item.Detail)),
			)
		}
	}
	if len(evidence) > 0 {
		output.WriteString("\n\n## Evidence\n")
		for index, item := range evidence[:min(len(evidence), 10)] {
			source := "`" + strings.ReplaceAll(item.SourceName, "`", "'") + "`"
			if link := sourceLink(item.SourceURL); link != "" {
				source = link
			}
			when := ""
			if !item.ObservedAt.IsZero() {
				when = ", observed " + item.ObservedAt.UTC().Format("2006-01-02 15:04 UTC")
			}
			fmt.Fprintf(
				&output,
				"\n%d. **%s** %s (%s%s)",
				index+1,
				item.Claim,
				item.Observation,
				source,
				when,
			)
		}
	}
	return output.String()
}

func evidenceFallback(
	evidence []core.Evidence,
	coverage []core.Coverage,
) string {
	var parts []string
	if len(coverage) > 0 {
		parts = append(parts, fmt.Sprintf("%d infrastructure layers assessed", len(coverage)))
	}
	if len(evidence) > 0 {
		parts = append(parts, fmt.Sprintf("%d evidence sources recorded", len(evidence)))
	}
	if len(parts) == 0 {
		return ""
	}
	return " " + strings.Join(parts, "; ") + "."
}

func markdownCell(value string) string {
	value = singleLine(value)
	value = strings.ReplaceAll(value, "|", "\\|")
	return truncateUTF8(value, 220)
}

func TurnFailureMessage(state, detail string) Message {
	header := "Investigation could not finish"
	if state == "cancelled" {
		header = "Investigation stopped"
	}
	detail = strings.TrimSpace(detail)
	if detail == "" {
		detail = state
	}
	return Message{
		Text:   header + ": " + escapeSlackText(detail),
		Header: header,
		Sections: []string{
			escapeSlackText(detail),
			"The isolated fork and collected evidence are preserved. Reply in this thread to continue or use the incident controls.",
		},
		Context: []string{"No merge, push, signing, or deployment occurred."},
	}
}

// AgentReportFailureMessage is what an operator sees when Responder exhausted
// its corrections and still could not read its own model's result.
//
// It takes no detail argument on purpose. An earlier version accepted one "for
// callers with something operator-facing to add", and the only thing callers
// ever had was the parse error — so the parameter was a hole that put
// `json: cannot unmarshal ...` in front of someone waiting on an incident.
// What they need is what survived, that nothing changed, and what to do next.
func AgentReportFailureMessage() Message {
	return Message{
		Text:   "I could not publish a clean summary of that turn.",
		Header: "Summary needs another pass",
		Sections: []string{
			"The investigation ran and its findings are preserved, but the final " +
				"summary did not come back in a form I could publish.",
			"Reply in this thread and I will write it up again from the same work — " +
				"nothing was lost and nothing was changed.",
		},
		Context: []string{
			"No merge, push, signing, or deployment occurred. " +
				"Raw transcripts and tool output are not posted to Slack.",
		},
	}
}

// TriageFailureMessage is the terminal notice for an accepted human request.
// It intentionally takes no raw error: provider and transport diagnostics are
// useful in logs, not in the Slack thread of the person waiting for an answer.
func TriageFailureMessage() Message {
	return Message{
		Text:   "I couldn't finish this request.",
		Header: "Request needs a retry",
		Sections: []string{
			"I stopped retrying this request so it would not remain silently queued.",
			"Reply in this thread to try again. Verify current state before repeating any operation.",
		},
		Context: []string{"Internal provider and transport errors were kept out of the channel."},
	}
}

// ApprovalVerificationFailureMessage reports only the verification boundary:
// the governed external action may have happened, so retrying it blindly would
// be unsafe even though the follow-up verification has stopped.
func ApprovalVerificationFailureMessage() Message {
	return Message{
		Text:   "The governed run finished, but I couldn't verify or report its result.",
		Header: "Verification needs attention",
		Sections: []string{
			"I stopped the automatic verification after its retry limit.",
			"Check the run and current state before repeating any action, then reply here to continue verification.",
		},
		Context: []string{"Internal provider and transport errors were kept out of the channel."},
	}
}
func EvidenceDirectoryMessage(
	incident core.Incident,
	evidence []core.Evidence,
	coverage []core.Coverage,
) Message {
	message := EvidenceResponse(
		fmt.Sprintf(
			"## Evidence for incident `%s`\n\nThe entries below are the latest durable "+
				"observations and coverage assessments.",
			ShortID(incident.ID),
		),
		evidence,
		coverage,
		NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"Evidence is retained separately from agent prose so operators can audit freshness and source coverage.",
	)
	return message
}

func commitmentStateLabel(state core.CommitmentState) string {
	switch state {
	case core.CommitmentQueued:
		return "Queued"
	case core.CommitmentWorking:
		return "Working"
	case core.CommitmentFinishing:
		return "Finishing"
	case core.CommitmentBlocked:
		return "Blocked"
	case core.CommitmentDone:
		return "Done"
	default:
		return "Cancelled"
	}
}

func CommitmentDirectoryMessage(items []core.Commitment) Message {
	if len(items) == 0 {
		return Message{
			Text:   "Emisar has no unfinished commitments.",
			Header: "No unfinished commitments",
			Markdown: "I do not currently owe the team an investigation, response, or retry. " +
				"Closed incidents and completed engineering tasks remain available in the work history.",
		}
	}
	var body strings.Builder
	body.WriteString(
		"These are durable agent runs that are queued, active, finishing, or blocked. " +
			"Emisar resumes them after restarts and returns to the originating conversation.\n",
	)
	for _, item := range items {
		location := ""
		if item.ChannelID != "" {
			location = " in <#" + item.ChannelID + ">"
		}
		fmt.Fprintf(
			&body,
			"\n- **%s**%s\n  %s - %s",
			escapeSlackText(item.Title),
			location,
			commitmentStateLabel(item.State),
			escapeSlackText(item.Status),
		)
		if item.NextAction != "" {
			fmt.Fprintf(
				&body,
				"\n  Next: %s",
				escapeSlackText(item.NextAction),
			)
		}
	}
	return Message{
		Text:     fmt.Sprintf("%d unfinished Emisar commitments.", len(items)),
		Header:   "What Emisar owes the team",
		Markdown: body.String(),
		Context: []string{
			"Blocked work remains visible until it is retried, resolved, or removed by retention cleanup.",
		},
	}
}

func workflowStateLabel(workflow core.WorkflowState) string {
	switch workflow {
	case core.WorkflowProvisioningChannel:
		return "Creating incident room"
	case core.WorkflowProvisioningSession:
		return "Preparing isolated workspace"
	case core.WorkflowHolding:
		return "Queued for capacity"
	case core.WorkflowInvestigating:
		return "Investigating"
	case core.WorkflowParked:
		return "Waiting for input"
	case core.WorkflowBlocked:
		return "Needs operator action"
	case core.WorkflowClosing:
		return "Closing task"
	case core.WorkflowClosed:
		return "Closed"
	default:
		return displayOr(strings.ReplaceAll(string(workflow), "_", " "), "Unknown")
	}
}

func workflowStateDescription(incident core.Incident) string {
	switch incident.Workflow {
	case core.WorkflowProvisioningChannel:
		if incident.IsThreadScoped() {
			return "Responder is attaching a durable task card and isolated work session to this Slack thread."
		}
		return "Slack is creating and preparing the dedicated incident room."
	case core.WorkflowProvisioningSession:
		if incident.IsEngineeringTask() {
			return "Responder is creating an isolated Coop session and writable task copy. Engineering work has not started yet."
		}
		return "Responder is creating an isolated Coop session and working copy. Investigation has not started yet."
	case core.WorkflowHolding:
		if incident.IsEngineeringTask() {
			return "The engineering task is queued because the configured active-agent capacity is currently full."
		}
		return "The incident is queued because the configured active-agent capacity is currently full."
	case core.WorkflowInvestigating:
		if incident.IsEngineeringTask() {
			return "An agent turn is running or waiting to run against the isolated engineering task."
		}
		return "An agent turn is running or waiting to run against the isolated incident context."
	case core.WorkflowParked:
		if incident.IsEngineeringTask() {
			return "No agent turn is running. The engineering task remains open and Responder is waiting for teammate input."
		}
		return "No agent turn is running. The incident remains open and Responder is waiting for operator input."
	case core.WorkflowBlocked:
		if incident.IsEngineeringTask() {
			return "Responder cannot continue until a workspace teammate addresses the blocker shown on the task card."
		}
		return "Responder cannot continue until an operator addresses the blocker shown on the pinned card."
	case core.WorkflowClosed:
		if incident.IsEngineeringTask() {
			return "The engineering task session is closed. Unpublished changes remain preserved for operator action."
		}
		return "The incident session is closed. Its isolated working copy remains preserved."
	default:
		return "Responder reported a state it cannot yet describe. Check the pinned card and service logs before taking action."
	}
}

func signalStateSummary(incident core.Incident) string {
	if incident.IsEngineeringTask() {
		if incident.Status == core.IncidentClosed {
			return "Engineering task closed; the isolated fork is preserved."
		}
		return "Engineering task is open."
	}
	switch incident.Status {
	case core.IncidentMonitoring:
		if !incident.ResolveDueAt.IsZero() {
			return "All signals recovered. Responder is monitoring until " +
				incident.ResolveDueAt.UTC().Format("2006-01-02 15:04 UTC") + "."
		}
		return "All signals recovered. Responder is monitoring for a stable recovery."
	case core.IncidentResolved:
		return "All alert signals have recovered."
	case core.IncidentClosed:
		if incident.FiringCount > 0 {
			return fmt.Sprintf(
				"Incident closed with %d of %d signals still firing; the isolated fork is preserved.",
				incident.FiringCount, incident.SignalCount,
			)
		}
		return "Incident closed; the isolated fork is preserved."
	default:
		return fmt.Sprintf(
			"%d of %d alert signals are firing.",
			incident.FiringCount, incident.SignalCount,
		)
	}
}

func primarySignal(signals []core.Signal) (core.Signal, bool) {
	for index := len(signals) - 1; index >= 0; index-- {
		if signals[index].Status == core.SignalFiring {
			return signals[index], true
		}
	}
	if len(signals) == 0 {
		return core.Signal{}, false
	}
	return signals[len(signals)-1], true
}

func sourceLink(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 300 || strings.ContainsAny(value, "<>|") {
		return ""
	}
	parsed, err := url.ParseRequestURI(value)
	if err != nil || parsed.Host == "" || parsed.User != nil ||
		(parsed.Scheme != "https" && parsed.Scheme != "http") {
		return ""
	}
	hostname := parsed.Hostname()
	if hostname == "" {
		return ""
	}
	parsed.RawQuery = ""
	parsed.ForceQuery = false
	parsed.Fragment = ""
	return "<" + parsed.String() + "|Open " + escapeSlackText(hostname) + ">"
}

func singleLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func escapeSlackText(value string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(value)
}

func safeInlineCode(value string) string {
	return escapeSlackText(strings.ReplaceAll(value, "`", "'"))
}

func HelpMessage(incident core.Incident) Message {
	conversation := "*Conversation*\nReply normally anywhere in this incident channel. Responder reads " +
		"operator messages as part of the incident conversation; an `@mention` is not required."
	controls := "*Lifecycle controls*\nUse the pinned incident card to stop the active turn or close the incident. " +
		"`/responder stop` cancels the active turn but preserves its work. `/responder close` closes " +
		"the session and schedules ownership-checked retention."
	channelBehavior := "*Channel behavior*\n`/responder status` explains what Responder reads here and why. " +
		"`/responder proactive ...` configures normal-channel triage; it does not disable " +
		"conversation in an attached incident room."
	noun := "incident"
	if incident.IsThreadScoped() {
		noun = "engineering task"
		conversation = "*Conversation*\nKeep replying in this Slack thread. Every authorized reply continues " +
			"the same isolated engineering session; an `@mention` is not required."
		controls = "*Lifecycle controls*\nUse the task card in this thread to stop the active turn, inspect " +
			"changes, or check fix readiness. A configured operator must publish a draft PR, stop, close, or discard work. Slack slash commands do not carry thread " +
			"context, so they cannot select this task from the channel composer."
		channelBehavior = "*Thread scope*\nOnly this source thread is attached to the writable task. Other " +
			"messages in the shared channel continue through its normal read-only triage settings."
	}
	return Message{
		Text:   "Responder controls for " + noun + " " + ShortID(incident.ID),
		Header: "How to work with Responder",
		Sections: []string{
			conversation,
			"*Read-only inspection*\n`/responder update` requests a fresh " +
				"evidence-based summary.\n`/responder changes` shows the isolated working " +
				"copy's diff.\n`/responder review` compares a proposed change with the current " +
				"repository and runs rebase, validation, and policy checks.\n`/responder publish` " +
				"asks a configured operator to create or update a draft PR from the exact reviewed tree for a channel-scoped task.",
			controls,
			"*Automatic capacity*\nResponder allocates turns automatically when authorized work " +
				"arrives. `/responder turn-limit` explains the current channel's lifetime " +
				"safety ceiling; operators do not estimate how many turns a task requires.",
			channelBehavior,
			"Legacy deterministic controls such as `!respond status` and `!respond stop` also " +
				"work when sent as the entire message.",
		},
		Context: []string{
			"Controls never merge, sign, or deploy. Draft PR publication can push only a verified, lease-protected Responder branch. Coop and Emisar policy still govern infrastructure access and approvals.",
		},
	}
}

func Notice(text string) Message {
	return Message{Text: text, Sections: []string{text}}
}

func truncateMarkdown(value string, limit int) string {
	return core.TruncateUTF8WithSuffix(value, limit, "\n\n_Response truncated._")
}

func ShortID(id string) string {
	if index := strings.IndexByte(id, '_'); index >= 0 {
		id = id[index+1:]
	}
	if len(id) > 10 {
		return id[:10]
	}
	return id
}

func displayOr(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func ChannelName(prefix string, incident core.Incident) string {
	title := strings.ToLower(incident.Title)
	var slug strings.Builder
	lastDash := false
	for _, r := range title {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			slug.WriteRune(r)
			lastDash = false
		case !lastDash:
			slug.WriteByte('-')
			lastDash = true
		}
		if slug.Len() >= 36 {
			break
		}
	}
	name := strings.Trim(slug.String(), "-")
	if name == "" {
		name = "incident"
	}
	createdAt := incident.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Unix(0, 0)
	}
	result := fmt.Sprintf("%s-%s-%s", prefix, createdAt.UTC().Format("0102"), name)
	suffix := "-" + ShortID(incident.ID)[:min(10, len(ShortID(incident.ID)))]
	if len(result)+len(suffix) > 80 {
		result = result[:80-len(suffix)]
		result = strings.TrimRight(result, "-")
	}
	return result + suffix
}

// CommitmentOverdueMessage tells a thread that accepted work has stopped
// reporting progress.
//
// The tone matters here: this is Responder admitting it has not delivered
// something it took on, so it states the fact and what the operator can do,
// without apologising at length or implying the work is lost.
//
// It says only what it can see, and it can now see two clocks. overdueBy is how
// late the progress note is; sinceActivity is how long the turn has been quiet,
// where zero means nothing was ever recorded — an older episode, or a turn that
// narrated nothing. Those are three different situations and this card used to
// render them identically. "No progress for 33 minutes" is a fair description
// of a turn that has recorded nothing since before its deadline, and a
// misleading one for a turn that was still working seven minutes ago: it sends
// an operator hunting for a stall that has not happened. So the confident word
// is spent only on the reading that earns it, and both numbers are stated
// either way.
func CommitmentOverdueMessage(
	episode core.WorkEpisode,
	overdueBy time.Duration,
	sinceActivity time.Duration,
) Message {
	objective := displayOr(episode.Objective, "this request")
	text := "Still working on " + objective + ", but I have not made progress recently."
	state := fmt.Sprintf(
		"*No progress for %s.* I am still holding this request, but it has not advanced "+
			"since my last update.",
		roundedDuration(overdueBy),
	)
	switch {
	case sinceActivity <= 0:
		// Nothing recorded either way, so the progress clock is the whole story.
	case sinceActivity < overdueBy:
		// The work kept moving after the update it owed, then went quiet. The
		// second number is the one that matters: the silence is that long, not
		// as long as the missing update makes it look.
		text = fmt.Sprintf(
			"Still working on %s: no update for %s, and quiet for the last %s.",
			objective, roundedDuration(overdueBy), roundedDuration(sinceActivity),
		)
		state = fmt.Sprintf(
			"*No progress note for %s, and last activity %s ago.* The work kept moving after "+
				"my last update and then went quiet.",
			roundedDuration(overdueBy), roundedDuration(sinceActivity),
		)
	default:
		// Both clocks stopped, and the older one stopped first. Nothing has
		// happened here since before the update was due.
		text = fmt.Sprintf(
			"Stalled on %s: no update or recorded activity for %s.",
			objective, roundedDuration(overdueBy),
		)
		state = fmt.Sprintf(
			"*Stalled for %s.* No progress note in that time, and nothing recorded for %s.",
			roundedDuration(overdueBy), roundedDuration(sinceActivity),
		)
	}
	return Message{
		Text: text,
		Sections: []string{
			state,
			"*Current state:* " + displayOr(episode.Status, "working") +
				"\n*Next action:* " + displayOr(episode.NextAction, "none recorded"),
		},
		Context: []string{
			"Ask me to retry, narrow the request, or close it. Nothing has been lost.",
		},
	}
}

// roundedDuration renders a duration the way a person would say it.
func roundedDuration(value time.Duration) string {
	switch {
	case value >= 2*time.Hour:
		return fmt.Sprintf("%d hours", int(value.Hours()))
	case value >= time.Hour:
		return "an hour"
	case value >= 2*time.Minute:
		return fmt.Sprintf("%d minutes", int(value.Minutes()))
	default:
		return "a minute"
	}
}

// compactDuration renders an age as the one token a card column has room for.
//
// roundedDuration is the prose form and stays that way — "3 hours" is what a
// sentence wants. A card wants "3h": the state line puts an age between two
// separators, and a ledger line is 46 runes wide before the alignment starts
// costing the reader a column. Timezone-proof by construction, which is the
// other reason the ledger says "46m ago" rather than a wall clock nobody can
// convert while reading.
func compactDuration(value time.Duration) string {
	switch {
	case value < time.Minute:
		// Never negative and never "0s": a clock skew of a second should not
		// make a card look broken, and every age here is at least a moment old.
		if value < time.Second {
			return "1s"
		}
		return fmt.Sprintf("%ds", int(value.Seconds()))
	case value < time.Hour:
		return fmt.Sprintf("%dm", int(value.Minutes()))
	case value < 48*time.Hour:
		return fmt.Sprintf("%dh", int(value.Hours()))
	default:
		return fmt.Sprintf("%dd", int(value.Hours())/24)
	}
}

// FeedbackSummary is one open feedback item as the App Home shows it.

// BaseActionID strips the per-instance suffix Blocks adds to repeated actions,
// so routing sees the action a button represents rather than which copy of it
// the operator clicked. Ids without a suffix pass through untouched.
func BaseActionID(actionID string) string {
	if index := strings.LastIndex(actionID, ActionInstanceSeparator); index > 0 {
		if _, err := strconv.Atoi(actionID[index+len(ActionInstanceSeparator):]); err == nil {
			return actionID[:index]
		}
	}
	return actionID
}

const publicationActionValueSeparator = "~publication-"

// PublicationActionValue binds a publication control to the durable
// publication generation that rendered it. A later attempt increments that
// generation, making every older button harmless even though Slack may still
// deliver a click from its pre-update view of the message.
func PublicationActionValue(incidentID string, generation int64) string {
	return incidentID + publicationActionValueSeparator + strconv.FormatInt(generation, 10)
}

func DecodePublicationActionValue(value string) (string, int64, bool) {
	index := strings.LastIndex(value, publicationActionValueSeparator)
	if index <= 0 {
		return value, 0, false
	}
	generation, err := strconv.ParseInt(
		value[index+len(publicationActionValueSeparator):], 10, 64,
	)
	if err != nil || generation < 0 {
		return "", 0, false
	}
	return value[:index], generation, true
}
