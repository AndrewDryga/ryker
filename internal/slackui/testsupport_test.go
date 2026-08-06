package slackui

// Test-only constructors. Production renders incident cards through
// IncidentCardWithPublication and evidence through the typed-offer variants, so
// these narrower forms exist purely to keep their unit tests focused.

import (
	"github.com/AndrewDryga/responder/internal/core"
)

func IncidentCard(
	incident core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
) Message {
	return IncidentCardWithPublication(
		incident, repositoryName, signals, hasCodeChanges, core.Publication{},
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
	message := ConciseEvidenceResponse(text, evidence, coverage, nil, sanitizer)
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
	message := ConciseEvidenceResponse(text, evidence, coverage, nil, sanitizer)
	return WithEngineeringTaskOffer(message, "", sourceInputID, repositoryLabel)
}

func summonChannelMembershipError(botName, channelID, channelName string) error {
	return channelMembershipError(botName, "summon", channelID, channelName)
}
