// Package channelparticipation owns the one writable participation mode for a
// Slack channel. Confirmed channel setup wins; legacy overrides remain only as
// the fallback for channels that have not completed setup.
package channelparticipation

import (
	"context"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store"
)

const (
	Proactive = "proactive"
	Shadow    = "shadow"
)

func Set(
	ctx context.Context,
	st *store.Store,
	scope, channelID, name, value, actor string,
) error {
	if scope == "channel" {
		configuration, err := st.GetChannelConfiguration(ctx, channelID)
		if err == nil {
			if value != "inherit" {
				switch name {
				case Shadow:
					if value == "on" {
						configuration.Participation = Shadow
					} else if configuration.Participation == Shadow {
						configuration.Participation = Proactive
					}
				case Proactive:
					if value == "on" {
						configuration.Participation = Proactive
					} else {
						configuration.Participation = "mentions"
					}
				default:
					return fmt.Errorf("unsupported participation setting %q", name)
				}
				configuration.ActorID = actor
				if _, err := st.SaveChannelConfiguration(ctx, configuration); err != nil {
					return err
				}
			}
			return deleteLegacy(ctx, st, channelID)
		}
		if !errors.Is(err, store.ErrNotFound) {
			return err
		}
	}
	if value == "inherit" {
		if err := st.DeleteSlackSetting(ctx, scope, channelID, name); err != nil &&
			!errors.Is(err, store.ErrNotFound) {
			return err
		}
		return nil
	}
	return st.SetSlackSetting(ctx, scope, channelID, name, value, actor)
}

func LifecyclePresenceVisible(
	ctx context.Context,
	st *store.Store,
	conversationKey string,
	shadow bool,
) (bool, error) {
	if shadow {
		return false, nil
	}
	work, err := st.GetLatestWorkEpisodeByConversationKey(ctx, conversationKey, "")
	if errors.Is(err, store.ErrNotFound) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return episode.Terminal(work.State), nil
}

func deleteLegacy(ctx context.Context, st *store.Store, channelID string) error {
	for _, name := range []string{Proactive, Shadow} {
		if err := st.DeleteSlackSetting(ctx, "channel", channelID, name); err != nil &&
			!errors.Is(err, store.ErrNotFound) {
			return err
		}
	}
	return nil
}
