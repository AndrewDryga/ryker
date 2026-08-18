// Package wakeuppolicy validates external-wait lifecycle identities without
// owning persistence. Callers supply the episode's recorded wakeups.
package wakeuppolicy

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

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
	now time.Time,
) (string, error) {
	existing, err := source.ListEpisodeWakeups(ctx, episodeID)
	if err != nil {
		return "", err
	}
	return IdentityCorrection(existing, operations, now), nil
}

// IdentityCorrection refuses terminal identity reuse and renewable Terraform
// wait chains before either can create a clock the episode cannot honor.
func IdentityCorrection(
	existing []core.EpisodeWakeup,
	operations []investigation.ResultOperation,
	now time.Time,
) string {
	waits := make(map[string]bool)
	for _, operation := range operations {
		if operation.Type == "wait_external" && operation.ExternalWait != nil {
			if correction := terraformDeadlineCorrection(
				existing, operation.ExternalWait, now,
			); correction != "" {
				return correction
			}
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

func terraformDeadlineCorrection(
	existing []core.EpisodeWakeup,
	wait *investigation.ExternalWaitOperation,
	now time.Time,
) string {
	if wait.Kind != "terraform_run" {
		return ""
	}
	runID := terraformRunID(wait.EventMatcher)
	if runID == "" {
		return ""
	}
	var original time.Time
	for _, wakeup := range existing {
		if wakeup.Kind == wait.Kind && terraformRunID(wakeup.EventMatcher) == runID &&
			!wakeup.Deadline.IsZero() {
			original = wakeup.Deadline
			break
		}
	}
	if original.IsZero() {
		return ""
	}
	bound := original.UTC().Format(time.RFC3339)
	if !now.UTC().Before(original) {
		return fmt.Sprintf(
			"the original Terraform wait deadline for %s (%s) has elapsed; do not emit another wait_external for this run, and instead report the exact current blocker or complete from fresh evidence",
			runID, bound,
		)
	}
	proposed, err := time.Parse(time.RFC3339, strings.TrimSpace(wait.Deadline))
	if err == nil && proposed.After(original) {
		return fmt.Sprintf(
			"the original Terraform wait deadline for %s is %s; a refresh cannot renew it to %s, so keep the original deadline",
			runID, bound, proposed.UTC().Format(time.RFC3339),
		)
	}
	return ""
}

func terraformRunID(raw json.RawMessage) string {
	var matcher map[string]any
	if json.Unmarshal(raw, &matcher) != nil {
		return ""
	}
	for key, value := range matcher {
		if strings.EqualFold(strings.TrimSpace(key), "run_id") {
			id, _ := value.(string)
			return strings.TrimSpace(id)
		}
	}
	return ""
}
