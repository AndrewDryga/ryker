package service

import (
	"sync"

	"github.com/AndrewDryga/ryker/internal/agentprompt"
	"github.com/AndrewDryga/ryker/internal/changeledger"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/investigationcontract"
	"github.com/AndrewDryga/ryker/internal/promptarchive"
)

// archivedPrompt is the copy of a submitted prompt that outlives the turn.
//
// It is the submitted bytes with every instruction the host recognizes replaced
// by a marker naming it. The conversation, the memory, the evidence and every
// host tag around them survive untouched, because those existed exactly once
// and the instructions did not.
//
// ~131 MB/week on blitz, ~60% of it the same instruction block stored a hundred
// and forty times a day, on a 30-day horizon. Measured after the change: 76,772
// bytes leave a full briefing, ~50% of one, ~42% of the archive — the estimate
// was made before the standing briefing landed, and the delta turns it created
// never carried an instruction block to drop.
//
// Nothing here changes what is SENT: the submitted prompt is passed in and
// returned unmodified, and the caller archives the result.
func archivedPrompt(prompt string) string {
	return promptarchive.Elide(rykerPromptVersion, prompt, instructionBlocks())
}

// instructionBlocks are the instruction texts the host assembles into prompts,
// each named after the Go symbol that owns it so a marker in the archive can be
// grepped back to the words it stands for.
//
// A block that is not on this list is simply archived in full, which is what
// every row looked like before this existed — so an incomplete list costs bytes
// and never correctness. The order does not matter; promptarchive elides the
// longest first so a block nested inside another is not eaten out from under
// it.
var instructionBlocks = sync.OnceValue(func() []promptarchive.Block {
	return []promptarchive.Block{
		// The two largest single blocks in a briefing, and between them most of
		// what this saves: the envelope contract the watch lane ends with, and
		// the result-operations list that the incident lane carries on its own.
		{Name: "investigation.WatchEnvelopePrompt", Text: investigation.WatchEnvelopePrompt()},
		{Name: "investigation.ResultOperationsPrompt", Text: investigation.ResultOperationsPrompt()},
		{Name: "service.StructuredResponseInstructions", Text: StructuredResponseInstructions()},
		{Name: "investigationcontract.EvidenceRules", Text: investigationcontract.EvidenceRules},
		{Name: "investigationcontract.CompletionRules", Text: investigationcontract.CompletionRules},
		{Name: "agentprompt.ToolTransport", Text: agentprompt.ToolTransport()},
		{Name: "agentprompt.EvidenceSourcePolicy", Text: evidenceSourcePolicy},
		{Name: "agentprompt.SuppliedContextPolicy", Text: suppliedContextPolicy},
		{Name: "agentprompt.OfferContractPolicy", Text: offerContractPolicy},
		{Name: "agentprompt.CompoundRequestPolicy", Text: compoundRequestPolicy},
		{Name: "agentprompt.EmisarGovernedActionPolicy", Text: emisarGovernedActionPolicy},
		{Name: "replypolicy.ReplyFormattingPolicy", Text: slackReplyFormattingPolicy},
		{Name: "replypolicy.ReplyShapePolicy", Text: slackReplyShapePolicy},
		{Name: "service.operationalMemoryPolicy", Text: operationalMemoryPolicy},
		{Name: "service.behaviorOfferPolicy", Text: behaviorOfferPolicy},
		{Name: "service.similarPastEpisodesPolicyText", Text: similarPastEpisodesPolicyText},
		{Name: "service.relatedTasksPolicyText", Text: relatedTasksPolicyText},
		{Name: "changeledger.PolicyText", Text: changeledger.PolicyText},
		{Name: "service.scheduledOccurrencePolicyText", Text: scheduledOccurrencePolicyText},
		{Name: "service.hostRecheckPolicyText", Text: hostRecheckPolicyText},
		{Name: "service.publicationCorrelationPolicyText", Text: publicationCorrelationPolicyText},
		{Name: "service.channelAroundRootPolicyText", Text: channelAroundRootPolicyText},
		{Name: "service.generatedVisualPolicyText", Text: generatedVisualPolicyText},
		// The watch lane's own prose, in the order it is assembled. These are
		// the paragraphs that were inline in unboundedWatchPrompt until the
		// archive needed to name them.
		{Name: "service.watchMemoryFramePolicy", Text: watchMemoryFramePolicy},
		{Name: "service.watchMemoryPolicy", Text: watchMemoryPolicy},
		{Name: "service.watchAddressingPolicy", Text: watchAddressingPolicy},
		{Name: "service.watchRepositoryWorkPolicy", Text: watchRepositoryWorkPolicy},
		{Name: "service.watchEvidenceRefreshPolicy", Text: watchEvidenceRefreshPolicy},
		{Name: "service.watchDurableBehaviorPolicy", Text: watchDurableBehaviorPolicy},
		{Name: "service.watchActionChoicePolicy", Text: watchActionChoicePolicy},
		// The bounded conversation lane's equivalents.
		{Name: "service.conversationLanePolicy", Text: conversationLanePolicy},
		{Name: "service.conversationExplanationPolicy", Text: conversationExplanationPolicy},
		{Name: "service.conversationEnvelopePolicy", Text: conversationEnvelopePolicy},
	}
})
