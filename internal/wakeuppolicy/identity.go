// Package wakeuppolicy validates external-wait lifecycle identities without
// owning persistence. Callers supply the episode's recorded wakeups.
package wakeuppolicy

import (
	"context"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

type Source interface {
	ListEpisodeWakeups(context.Context, string) ([]core.EpisodeWakeup, error)
}

func Correction(
	ctx context.Context,
	source Source,
	episodeID string,
	operations []investigation.ResultOperation,
) (string, error) {
	existing, err := source.ListEpisodeWakeups(ctx, episodeID)
	if err != nil {
		return "", err
	}
	return IdentityCorrection(existing, operations), nil
}

// IdentityCorrection refuses to use a terminal wakeup row as a new clock.
func IdentityCorrection(
	existing []core.EpisodeWakeup,
	operations []investigation.ResultOperation,
) string {
	waits := make(map[string]bool)
	for _, operation := range operations {
		if operation.Type == "wait_external" && operation.ExternalWait != nil {
			if id := strings.TrimSpace(operation.ExternalWait.ID); id != "" {
				waits[id] = true
			}
		}
	}
	for _, wakeup := range existing {
		if !waits[wakeup.ID] {
			continue
		}
		switch wakeup.State {
		case core.WakeupPending, core.WakeupLeased:
			continue
		default:
			return fmt.Sprintf(
				"wait_external %q is already %s; keep the same matcher and verification but submit a fresh external_wait.id so the new wait has an active clock",
				wakeup.ID, wakeup.State,
			)
		}
	}
	return ""
}
