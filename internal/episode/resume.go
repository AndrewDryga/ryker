package episode

import (
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
)

// BindAttempt preserves an episode's durable identity while clearing the
// transport identity that each retry must mint for itself.
func BindAttempt(episode core.WorkEpisode, run core.AgentRun) (core.AgentRun, error) {
	if Terminal(episode.State) {
		return core.AgentRun{}, fmt.Errorf(
			"cannot resume terminal episode %q in state %q", episode.ID, episode.State,
		)
	}
	run.Episode = &episode
	run.EpisodeID = episode.ID
	run.AttemptID = ""
	run.AttemptNumber = 0
	return run, nil
}

// PreferredWaitingThread returns the exact Slack thread that may own an older
// waiting episode. Operational app streams use different correlation rules.
func PreferredWaitingThread(
	input core.SlackInput,
	responseThread string,
	operationalLifecycle bool,
) string {
	if operationalLifecycle {
		return ""
	}
	return core.FirstNonempty(responseThread, input.ThreadTS, input.MessageTS)
}

// AcceptsOperatorAnswer reports whether a human input resumes an episode that
// is durably waiting for that answer.
func AcceptsOperatorAnswer(
	episode core.WorkEpisode,
	input core.SlackInput,
	responseThread string,
	conversationFollowup bool,
) bool {
	if episode.State != core.EpisodeWaitingOperator || input.Kind == "bot_message" ||
		input.Kind == "scheduled" || input.Kind == "recheck" ||
		episode.Destination.ChannelID == "" ||
		episode.Destination.ChannelID != input.ChannelID {
		return false
	}
	if episode.Destination.ThreadTS == "" {
		return conversationFollowup
	}
	return episode.Destination.ThreadTS == responseThread ||
		episode.Destination.ThreadTS == input.ThreadTS
}
