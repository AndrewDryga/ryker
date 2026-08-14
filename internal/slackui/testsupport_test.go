package slackui

// Test-only constructors. Production renders incident cards through
// IncidentCardWithPublication and evidence through the typed-offer variants, so
// these narrower forms exist purely to keep their unit tests focused.

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// cardText is everything on a card a person reads as words, including the row
// the ask now lives in — a card assertion that only joined Sections would stop
// seeing the request the moment it moved.
func cardText(message Message) string {
	parts := []string{message.Text, message.Header, message.Markdown}
	parts = append(parts, message.Sections...)
	for _, row := range message.Rows {
		parts = append(parts, row.Text)
	}
	parts = append(parts, message.Context...)
	// The tail is text on the card like any other. It is rendered last, under
	// the footer, so that Slack's fold hides it rather than the controls — a
	// reader still reads it, and a test that skipped it would report a card
	// missing a request that is right there.
	parts = append(parts, message.Tail...)
	return strings.Join(parts, "\n")
}

// cardActions is every control on a card, wherever it is attached.
//
// Controls used to live in one pile at the bottom, so a test could read
// message.Actions and see all of them. They now sit on the row they act on, in
// a row's ⋯ menu, or in the card's — an assertion that still counts the bottom
// pile is asserting where a button is, not whether it exists.
func cardActions(message Message) []Action {
	actions := append([]Action{}, message.Actions...)
	for _, row := range message.Rows {
		actions = append(actions, row.Actions...)
		actions = append(actions, row.Overflow...)
	}
	return append(actions, message.Overflow...)
}

// cardActionIDs is the same set reduced to the routes it would fire.
func cardActionIDs(message Message) []string {
	actions := cardActions(message)
	ids := make([]string, 0, len(actions))
	for _, action := range actions {
		ids = append(ids, action.ID)
	}
	return ids
}

// ledgerText flattens a ledger for assertions that care what a step says
// rather than how the strip is aligned.
func ledgerText(steps []LedgerStep) string {
	parts := make([]string, 0, len(steps))
	for _, step := range steps {
		parts = append(parts, strings.Join(
			[]string{step.Glyph, step.Label, step.Detail, step.When, step.Owner}, " ",
		))
		if len(step.Children) > 0 {
			parts = append(parts, ledgerText(step.Children))
		}
	}
	return strings.Join(parts, "\n")
}

// ledgerMarker reports the run's position: which step is current, out of how
// many. Returns 0 when no step is marked, which is what a terminal card does.
func ledgerMarker(steps []LedgerStep) (int, int) {
	for index, step := range steps {
		if step.Current {
			return index + 1, len(steps)
		}
	}
	return 0, len(steps)
}

func IncidentCard(
	incident core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
) Message {
	return IncidentCardWithPublication(
		incident, repositoryName, signals, hasCodeChanges, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
}

func AssistantResponse(text string, sanitizer *Sanitizer) Message {
	text = sanitizer.Text(text)
	if text == "" {
		text = "No response was returned."
	}
	return Message{
		Text:     truncateUTF8("Investigation update: "+text, 4000),
		Header:   "Investigation update",
		Markdown: truncateMarkdown(text, 12000),
		Context:  []string{"Responder reply. Internal tool output and hidden reasoning are omitted."},
	}
}

func EvidenceResponseWithIncidentOffer(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sourceInputID string,
	sanitizer *Sanitizer,
) Message {
	message := ConciseEvidenceResponse(text, evidence, coverage, sanitizer)
	message.Context = nil
	return WithIncidentOffer(message, sourceInputID)
}

func EvidenceResponseWithTaskOffer(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sourceInputID string,
	repositoryLabel string,
	sanitizer *Sanitizer,
) Message {
	message := ConciseEvidenceResponse(text, evidence, coverage, sanitizer)
	return WithEngineeringTaskOffer(message, "", sourceInputID, repositoryLabel)
}

func summonChannelMembershipError(botName, channelID, channelName string) error {
	return channelMembershipError(botName, "summon", channelID, channelName)
}
