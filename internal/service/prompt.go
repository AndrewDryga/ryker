package service

import (
	"github.com/AndrewDryga/responder/internal/agentprompt"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

const (
	slackReplyFormattingPolicy = agentprompt.ReplyFormattingPolicy
	slackReplyShapePolicy      = agentprompt.ReplyShapePolicy
	offerContractPolicy        = agentprompt.OfferContractPolicy
	compoundRequestPolicy      = agentprompt.CompoundRequestPolicy
	suppliedContextPolicy      = agentprompt.SuppliedContextPolicy
	emisarGovernedActionPolicy = agentprompt.EmisarGovernedActionPolicy
)

var (
	errEvidenceTooLarge  = agentprompt.ErrEvidenceTooLarge
	evidenceSourcePolicy = agentprompt.EvidenceSourcePolicy
)

func CoopInstructions(configured string) string     { return agentprompt.CoopInstructions(configured) }
func repositorySetPrompt(bound coop.Session) string { return agentprompt.RepositorySet(bound) }
func initialPrompt(instructions string, incident core.Incident, signals []core.Signal, prior string) (string, error) {
	return agentprompt.Initial(instructions, incident, signals, prior)
}
func signalPrompt(signals []core.Signal) (string, error) { return agentprompt.Signal(signals) }
func operatorPrompt(userID, message string) string       { return agentprompt.Operator(userID, message) }
func conversationPrompt(userID, message string, direct bool) string {
	return agentprompt.Conversation(userID, message, direct)
}
func simpleExplanationRequest(message string) bool {
	return agentprompt.SimpleExplanationRequest(message)
}
func boundedOperatorText(message string) string { return agentprompt.BoundedOperatorText(message) }
func suppressConversationReply(message string) bool {
	return agentprompt.SuppressConversationReply(message)
}
