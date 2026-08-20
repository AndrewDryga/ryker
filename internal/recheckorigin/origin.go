// Package recheckorigin binds a synthetic recheck to the exact episode that
// scheduled it, independently from newer work in the same Slack conversation.
package recheckorigin

import (
	"context"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

type Reader interface {
	GetAgentRun(context.Context, string) (core.AgentRun, error)
	GetWorkEpisode(context.Context, string) (core.WorkEpisode, error)
}

type Correlate func(context.Context, core.SlackInput, string, *decisionpkg.WatchTurnState) (*core.WorkEpisode, bool, error)

func ResolveOrCorrelate(
	ctx context.Context,
	reader Reader,
	state *decisionpkg.WatchTurnState,
	input core.SlackInput,
	defaultConversation string,
	correlate Correlate,
) (string, *core.WorkEpisode, bool, error) {
	conversation, episode, resumed, err := Resolve(ctx, reader, state, input.ChannelID, defaultConversation)
	if err != nil || resumed {
		return conversation, episode, resumed, err
	}
	episode, resumed, err = correlate(ctx, input, conversation, state)
	return conversation, episode, resumed, err
}

func Resolve(
	ctx context.Context,
	reader Reader,
	state *decisionpkg.WatchTurnState,
	channelID string,
	defaultConversation string,
) (string, *core.WorkEpisode, bool, error) {
	originID := state.RecheckOriginRunID
	if originID == "" {
		return defaultConversation, nil, false, nil
	}
	run, err := reader.GetAgentRun(ctx, originID)
	if err != nil {
		return "", nil, false, fmt.Errorf("load recheck origin run: %w", err)
	}
	if run.EpisodeID == "" {
		return "", nil, false, errors.New("recheck origin run has no work episode")
	}
	episode, err := reader.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		return "", nil, false, fmt.Errorf("load recheck origin episode: %w", err)
	}
	state.ResponseThreadTS = run.ThreadTS
	if episode.Destination.ChannelID == channelID && episode.Destination.ThreadTS != "" {
		state.ResponseThreadTS = episode.Destination.ThreadTS
	}
	state.ConversationFollowup = true
	return run.ConversationKey, &episode, true, nil
}
