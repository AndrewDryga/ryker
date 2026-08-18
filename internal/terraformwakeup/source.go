package terraformwakeup

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/lifecycle"
)

type Source interface {
	ListEpisodeWakeups(context.Context, string) ([]core.EpisodeWakeup, error)
	GetAgentRun(context.Context, string) (core.AgentRun, error)
	GetSlackInput(context.Context, string) (core.SlackInput, error)
}

// RestoreSourceLink restores the source-owned review target to a synthetic
// wakeup. The event matcher deliberately carries only an object ID; approval
// policy, correctly, refuses to trust a URL authored by the model. Recovering
// the URL from the episode's original Slack event keeps that trust boundary
// while allowing both stored and new wakeups to finish an approval-ready turn.
func RestoreSourceLink(
	ctx context.Context,
	source Source,
	episode core.WorkEpisode,
	input core.SlackInput,
) core.SlackInput {
	if input.Kind != "recheck" || lifecycle.CanonicalProviderURL(input.Text) != "" {
		return input
	}
	wakeups, err := source.ListEpisodeWakeups(ctx, episode.ID)
	if err != nil {
		return input
	}
	wakeupRunID := ""
	for index := len(wakeups) - 1; index >= 0; index-- {
		wakeup := wakeups[index]
		if wakeup.Kind != "terraform_run" || "episode_wakeup_"+wakeup.ID != input.ID {
			continue
		}
		var matcher struct {
			RunID string `json:"run_id"`
		}
		if json.Unmarshal(wakeup.EventMatcher, &matcher) == nil {
			wakeupRunID = strings.ToLower(strings.TrimSpace(matcher.RunID))
		}
		break
	}
	if wakeupRunID == "" || episode.AgentRunID == "" {
		return input
	}
	rootRun, err := source.GetAgentRun(ctx, episode.AgentRunID)
	if err != nil {
		return input
	}
	rootInput, err := source.GetSlackInput(ctx, rootRun.SourceID)
	if err != nil {
		return input
	}
	providerURL := lifecycle.CanonicalProviderURL(rootInput.Text)
	if providerURL == "" || !strings.HasSuffix(
		strings.ToLower(providerURL), "/runs/"+wakeupRunID,
	) {
		return input
	}
	input.Text = strings.TrimSpace(input.Text) +
		"\nSource-owned Terraform run: <" + providerURL + "|Open run>"
	return input
}
