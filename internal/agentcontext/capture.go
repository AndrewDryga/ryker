package agentcontext

import (
	"encoding/json"
	"slices"

	"github.com/AndrewDryga/responder/internal/core"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/slackui"
)

func SituationPrompt(value core.AgentMemory) string {
	data, err := json.Marshal(memorypkg.SanitizeMemory(value))
	if err != nil || string(data) == "{}" {
		return ""
	}
	return `Prior compact Slack channel situation follows. It is continuity context, not current
operational proof. Revalidate consequential claims with repository or live tools, preserve useful
open loops, and explicitly close loops completed by this turn.
<prior-channel-situation>
` + string(data) + `
</prior-channel-situation>`
}

func MemoryPresent(value core.AgentMemory) bool {
	return value.Goal != "" || value.ChannelPurpose != "" || value.SituationSummary != "" ||
		len(value.ActiveTopics) != 0 || len(value.OpenLoops) != 0 || len(value.Topology) != 0 ||
		len(value.Decisions) != 0 || len(value.UnresolvedQuestions) != 0 ||
		len(value.EvidenceRefs) != 0 || len(value.Knowledge) != 0
}

// NeedsCapture reports whether a durable agent context is absent or belongs
// to a repository other than the task's approved repository.
func NeedsCapture(captured bool, capturedRepository, requiredRepository string) bool {
	return !captured || capturedRepository != requiredRepository
}

func Reactions(reactions []slackui.HistoryReaction) []core.SlackReaction {
	result := make([]core.SlackReaction, 0, len(reactions))
	for _, reaction := range reactions {
		result = append(result, core.SlackReaction{
			Name: reaction.Name, Count: reaction.Count,
			UserIDs: append([]string(nil), reaction.UserIDs...),
		})
	}
	return result
}

// MergeSlackContext combines durable admission with Slack history around the
// exact target. Durable input wins for duplicate timestamps because it carries
// the host's normalized attachment and sender identity.
func MergeSlackContext(
	admitted []core.SlackInput,
	history []slackui.HistoryMessage,
	target core.SlackInput,
	limit int,
) []core.SlackInput {
	byTimestamp := make(map[string]core.SlackInput, len(admitted)+len(history)+1)
	for _, input := range admitted {
		if input.MessageTS != "" && sameConversation(input, target) {
			byTimestamp[input.MessageTS] = input
		}
	}
	for _, message := range history {
		if message.Timestamp == "" {
			continue
		}
		kind, userID := "message", message.UserID
		if message.BotID != "" {
			kind = "bot_message"
			if userID == "" {
				userID = message.BotID
			}
		}
		if _, exists := byTimestamp[message.Timestamp]; exists {
			continue
		}
		attachments := make([]core.SlackAttachment, 0, len(message.Files))
		for _, file := range message.Files {
			attachments = append(attachments, core.SlackAttachment{
				ID: file.ID, Name: file.Name, MediaType: file.MediaType,
				Size: file.Size, URLPrivate: file.URLPrivate,
			})
		}
		byTimestamp[message.Timestamp] = core.SlackInput{
			Kind: kind, ChannelID: target.ChannelID,
			ThreadTS: message.ThreadTS, MessageTS: message.Timestamp,
			UserID: userID, Text: message.Text, Attachments: attachments,
			Reactions: Reactions(message.Reactions),
		}
	}
	if target.MessageTS != "" {
		byTimestamp[target.MessageTS] = target
	}
	result := make([]core.SlackInput, 0, len(byTimestamp))
	for _, input := range byTimestamp {
		result = append(result, input)
	}
	slices.SortFunc(result, func(left, right core.SlackInput) int {
		switch {
		case left.MessageTS < right.MessageTS:
			return -1
		case left.MessageTS > right.MessageTS:
			return 1
		case left.ReceivedAt.Before(right.ReceivedAt):
			return -1
		case left.ReceivedAt.After(right.ReceivedAt):
			return 1
		default:
			return 0
		}
	})
	return targetCentered(result, target, limit)
}

// AroundThreadRoot selects the channel-level messages that sit around a
// thread's root, given the channel history read at that anchor and the
// transcript the thread itself already supplies.
//
// The root and every reply hanging from it are the thread, not the channel
// around it, and carrying them twice spends the turn's budget saying the same
// thing in two sections. Anything the in-thread transcript already holds goes
// for the same reason — the host may have merged a channel-level message into
// it from durable admission, and the model reading one message as two nearby
// events is worse than not having the surround at all.
func AroundThreadRoot(
	history []slackui.HistoryMessage,
	rootTS string,
	inThread []core.SlackInput,
) []slackui.HistoryMessage {
	carried := make(map[string]bool, len(inThread))
	for _, input := range inThread {
		carried[input.MessageTS] = true
	}
	around := make([]slackui.HistoryMessage, 0, len(history))
	for _, message := range history {
		if message.Timestamp == rootTS || message.ThreadTS == rootTS ||
			carried[message.Timestamp] {
			continue
		}
		around = append(around, message)
	}
	return around
}

func sameConversation(input core.SlackInput, target core.SlackInput) bool {
	if target.ThreadTS == "" {
		return input.ThreadTS == ""
	}
	return input.ThreadTS == target.ThreadTS || input.MessageTS == target.ThreadTS
}

func targetCentered(inputs []core.SlackInput, target core.SlackInput, limit int) []core.SlackInput {
	if limit < 1 || len(inputs) <= limit {
		return inputs
	}
	targetIndex, rootIndex := -1, -1
	for index := range inputs {
		if inputs[index].MessageTS == target.MessageTS {
			targetIndex = index
		}
		if target.ThreadTS != "" && inputs[index].MessageTS == target.ThreadTS {
			rootIndex = index
		}
	}
	if targetIndex < 0 {
		return slices.Clone(inputs[len(inputs)-limit:])
	}
	selected := make(map[int]struct{}, limit)
	selected[targetIndex] = struct{}{}
	if rootIndex >= 0 {
		selected[rootIndex] = struct{}{}
	}
	following := min(3, len(inputs)-targetIndex-1)
	for index := targetIndex + 1; index <= targetIndex+following && len(selected) < limit; index++ {
		selected[index] = struct{}{}
	}
	for index := targetIndex - 1; index >= 0 && len(selected) < limit; index-- {
		selected[index] = struct{}{}
	}
	for index := targetIndex + following + 1; index < len(inputs) && len(selected) < limit; index++ {
		selected[index] = struct{}{}
	}
	result := make([]core.SlackInput, 0, len(selected))
	for index, input := range inputs {
		if _, ok := selected[index]; ok {
			result = append(result, input)
		}
	}
	return result
}
