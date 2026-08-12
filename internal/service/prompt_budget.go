package service

import (
	"errors"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/promptbudget"
)

var errRequiredPromptTooLarge = errors.New("required prompt sections exceed the Coop turn limit")

func assemblePrompt(
	limit int,
	head string,
	tail string,
	sections ...promptbudget.Section,
) (string, []core.ContextOmission, error) {
	prompt, dropped, err := promptbudget.Assemble(limit, head, tail, sections...)
	if err != nil {
		return "", nil, err
	}
	omissions := make([]core.ContextOmission, 0, len(dropped))
	for _, section := range dropped {
		omissions = append(omissions, core.DroppedContextLayer(section.Name, section.Reason))
	}
	return prompt, omissions, nil
}

func (s *Service) boundedConversationPrompt(
	input core.SlackInput,
	botUserID string,
	conversationFollowup bool,
	recent []decisionpkg.WatchContextMessage,
	memory core.AgentMemory,
	related []decisionpkg.ConversationSituationContext,
	referenced *decisionpkg.ReferencedThreadContext,
	prior decisionpkg.OperationalMemoryContext,
	activeRepository string,
	budget int,
) (string, []core.ContextOmission, error) {
	var omitted []core.ContextOmission
	noted := map[string]bool{}
	note := func(kind, reason string) {
		if !noted[kind] {
			noted[kind] = true
			omitted = append(omitted, core.DroppedContextLayer(kind, reason))
		}
	}
	for {
		prompt := s.conversationPrompt(
			input, botUserID, conversationFollowup, recent, memory,
			related, referenced, prior, activeRepository,
		)
		if len(prompt) <= budget {
			return prompt, omitted, nil
		}
		switch {
		case len(prior.RecentEvidence) > 0:
			prior.RecentEvidence = prior.RecentEvidence[1:]
			note("prior_evidence", "earlier evidence records were omitted to fit the turn")
		case len(related) > 0:
			related = related[1:]
			note("related_situations", "related conversation summaries were omitted to fit the turn")
		case referenced != nil && len(referenced.RecentMessages) > 0:
			copyReferenced := *referenced
			copyReferenced.RecentMessages = referenced.RecentMessages[1:]
			referenced = &copyReferenced
			note("referenced_thread", "the referenced transcript was cut back to fit the turn")
		case len(prior.DreamedMemory) > 0:
			prior.DreamedMemory = prior.DreamedMemory[1:]
			note("dreamed_memory", "synthesized continuity summaries were omitted to fit the turn")
		case len(recent) > 1:
			recent = recent[1:]
			note("channel_history", droppedChannelHistory)
		case len(prior.ConfirmedMemory) > 0:
			prior.ConfirmedMemory = prior.ConfirmedMemory[1:]
			note("confirmed_memory", "operator-confirmed memory was omitted to fit the turn")
		case len(memory.Knowledge) > 0:
			memory.Knowledge = memory.Knowledge[:len(memory.Knowledge)-1]
			note("channel_knowledge", "learned conversation knowledge was omitted to fit the turn")
		default:
			return "", omitted, errRequiredPromptTooLarge
		}
	}
}
