package slackui

import (
	"github.com/AndrewDryga/responder/internal/knowledgeoffer"
)

// KnowledgeConfirmationStale tells an operator how to get a fresh proposal.
const KnowledgeConfirmationStale = "*This confirmation expired; ask Responder for a new proposal.*"

// KnowledgeOperatorOnly refuses a knowledge confirmation from an actor who is
// not on the configured operator list.
const KnowledgeOperatorOnly = "*A configured Responder operator must keep episode knowledge.*"

// KnowledgeMembershipRequired refuses an operator whose Slack account is not
// an active full workspace member and names that distinct remedy.
const KnowledgeMembershipRequired = "*Active full workspace membership is required to create this draft.*"

// KnowledgeDraftFailed prefixes a runbook-draft failure with Emisar's reason.
const KnowledgeDraftFailed = "*Responder could not create this runbook draft.* Emisar said: "

// KnowledgeCardFailed prefixes a task-card failure with the fact that nothing
// was started before appending the underlying reason.
const KnowledgeCardFailed = "*Responder could not start the task that writes this card.* "

// KnowledgeRefusedNotice is the refusal an operator reads when the host can no
// longer reproduce the evidence the card was composed on.
//
// It names the two things that could be missing, because they lead to different
// next steps: an episode that never verified its fix is a gap in the
// investigation, and an action the record does not hold is a gap in the offer.
const KnowledgeRefusedNotice = "*Current evidence no longer supports this draft; verify the remediation and try again.*"

// WithKnowledgeOffer renders whichever artefact was graded.
//
// The switch is here rather than at the call site because the two cards share a
// boundary line, a control, and a discipline; a caller choosing between them
// would be a caller that could pair the runbook's confirmation text with the
// card's button.
func WithKnowledgeOffer(
	message Message,
	artifact knowledgeoffer.Artifact,
	actionValue string,
	rationale string,
) Message {
	if artifact.Kind == knowledgeoffer.KindCard {
		return WithKnowledgeCardOffer(message, artifact.Card, actionValue, rationale)
	}
	return WithRunbookDraftOffer(message, artifact.Draft, actionValue, rationale)
}

// WithRunbookDraftOffer asks an operator to keep a verified remediation as an
// Emisar runbook draft.
//
// The action identity is rendered in full — id, pack and runner — for the same
// reason the approval card and the promotion card render it: the whole claim
// this offer makes is "these are the steps that actually ran", and a person
// confirming it should be reading the identity rather than a friendly name for
// it. The refs shown here are the host's recorded ones, never the model's, so
// what the operator reads is what Emisar will receive.
//
// One control, and it is a confirmation. Declining an offer is not pressing it.
func WithRunbookDraftOffer(
	message Message,
	draft knowledgeoffer.RunbookDraft,
	actionValue string,
	rationale string,
) Message {
	quote := "Let me keep this fix as a runbook draft in Emisar."
	if text := externalText(rationale); text != "" {
		quote = text
	}
	return offerCard(message, "", offerProposal{
		Quote: quote,
		Facts: joinFacts([]string{
			"Runbook `" + safeInlineCode(draft.Slug) + "` — " + externalText(draft.Title),
			"Action `" + safeInlineCode(draft.Action.ActionID) + "`",
			"Pack `" + safeInlineCode(draft.Action.PackRef) + "`",
			"Runner `" + safeInlineCode(draft.Action.RunnerRef) + "`",
			"From episode `" + safeInlineCode(draft.EpisodeID) + "`, which verified this fix",
		}),
		Actions: []Action{{
			ID:      ActionConfirmKnowledgeOffer,
			Label:   "Draft this runbook",
			Value:   actionValue,
			Style:   "primary",
			Confirm: "Create an unpublished draft of " + draft.Slug + " in Emisar?",
		}},
	})
}

// WithKnowledgeCardOffer asks an operator to keep what an episode established
// as a committed knowledge card.
//
// The path is shown rather than described. A reviewer's first question about a
// proposed document is where it lands, and `.agent/kb/<slug>.md` answers it
// exactly; "a knowledge card" does not.
func WithKnowledgeCardOffer(
	message Message,
	card knowledgeoffer.Card,
	actionValue string,
	rationale string,
) Message {
	quote := "Let me write this down where the next investigation will find it."
	if text := externalText(rationale); text != "" {
		quote = text
	}
	return offerCard(message, "", offerProposal{
		Quote: quote,
		Facts: joinFacts([]string{
			"Card `" + safeInlineCode(card.Path()) + "`",
			externalText(card.Title),
			"From episode `" + safeInlineCode(card.EpisodeID) + "`, which verified this fix",
		}),
		Actions: []Action{{
			ID:    ActionConfirmKnowledgeOffer,
			Label: "Open a draft PR",
			Value: actionValue,
			Style: "primary",
			Confirm: "Start an engineering task that writes " + card.Path() +
				" and opens a draft PR for review?",
		}},
	})
}

// RunbookDraftedNotice is the receipt for a held draft.
//
// It restates the boundary in the same breath as the receipt, because this is
// the message an operator remembers having read: the draft is unpublished, and
// making it real is a decision they make in Emisar rather than one this
// confirmation already made for them.
func RunbookDraftedNotice(slug string, digest string) string {
	receipt := "*Drafted.* Emisar is holding an unpublished runbook `" + safeInlineCode(slug) + "`."
	if digest != "" {
		receipt += " Definition `" + safeInlineCode(ShortID(digest)) + "`."
	}
	return receipt + " Review and publish it in Emisar."
}

// KnowledgeCardStartedNotice is the receipt for a card that is now an
// engineering task on its way to a draft pull request.
func KnowledgeCardStartedNotice(path string) string {
	return "*Started.* An engineering task is writing `" + safeInlineCode(path) +
		"` and will open a draft PR for review."
}
