// Package preparationnotice plans the single mutable Slack status for a
// triage run whose workspace is not ready yet.
package preparationnotice

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
	"github.com/AndrewDryga/responder/internal/slackui"
)

type Ledger interface {
	GetWorkEpisode(context.Context, string) (core.WorkEpisode, error)
	ListSlackDeliveriesByPrefix(context.Context, string) ([]core.SlackDelivery, error)
	EnqueueSlackDelivery(context.Context, core.SlackDelivery) (bool, error)
}

type Retirer interface {
	Retire(context.Context, string) (bool, error)
}

// Notify owns the complete blocker lifecycle so service cannot accidentally
// make posting durable while leaving recovery as a best-effort side effect.
func Notify(
	ctx context.Context,
	ledger Ledger,
	retirer Retirer,
	sanitize func(slackui.Message) slackui.Message,
	run core.AgentRun,
	cause error,
	now time.Time,
) error {
	message, eligible := Message(run, cause, now)
	if !eligible {
		if run.Mode == core.AgentRunTriage && Transient(cause) {
			_, err := retirer.Retire(ctx, Prefix(run))
			return err
		}
		return nil
	}
	episode, err := ledger.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil || episode.Destination.ChannelID == "" {
		return err
	}
	body, err := slackui.Encode(sanitize(message))
	if err != nil {
		return err
	}
	prefix := Prefix(run)
	deliveries, err := ledger.ListSlackDeliveriesByPrefix(ctx, prefix)
	if err != nil {
		return err
	}
	delivery := Delivery(run, episode, body, deliveries)
	if delivery == nil {
		return nil
	}
	_, err = ledger.EnqueueSlackDelivery(ctx, *delivery)
	return err
}

func Message(run core.AgentRun, cause error, now time.Time) (slackui.Message, bool) {
	if run.Mode != core.AgentRunTriage ||
		(!coop.Retryable(cause) &&
			!errors.Is(cause, sessioncreate.ErrReadOnlyAuthority) &&
			!errors.Is(cause, sessioncreate.ErrHistoricalCreateKeys)) {
		return slackui.Message{}, false
	}
	// An asynchronous refresh and the bounded historical-key cursor are normal
	// preparation progress, not blockers. Slack's native work presence already
	// represents them; a permanent thread reply would outlive the transient
	// state and make a healthy investigation look stuck.
	if Transient(cause) {
		return slackui.Message{}, false
	}
	if errors.Is(cause, sessioncreate.ErrReadOnlyAuthority) {
		return slackui.ReadOnlyWorkspaceBlocked(run.Repository, now.Add(30*time.Minute)), true
	}
	return slackui.RepositoryPreparationBlocked(run.Repository), true
}

func Transient(cause error) bool {
	var pending *coop.OperationPendingError
	return errors.As(cause, &pending) || errors.Is(cause, sessioncreate.ErrHistoricalCreateKeys)
}

func Prefix(run core.AgentRun) string {
	return "watch_preparation_blocked_" + core.FirstNonempty(run.EpisodeID, run.ID) + "_"
}

func Delivery(
	run core.AgentRun,
	episode core.WorkEpisode,
	body []byte,
	existing []core.SlackDelivery,
) *core.SlackDelivery {
	owner := core.FirstNonempty(run.EpisodeID, run.ID)
	prefix := "watch_preparation_blocked_" + owner + "_"
	var latestSent core.SlackDelivery
	retirements := 0
	epochStart := 0
	activeRetirement := -1
	for index, delivery := range existing {
		if delivery.Operation == "delete" {
			retirements++
			if delivery.State == "pending" || delivery.State == "retry" ||
				delivery.State == "sending" {
				activeRetirement = index
			}
			if delivery.State == "sent" {
				epochStart = index + 1
			}
		}
	}
	// A never-attempted delete immediately after a durably sent blocker can be
	// cancelled by updating that same message. Every other active retirement is
	// causal: it may guard an ambiguous post, may already have reached Slack, or
	// may already have a newer blocker behind it. Start a fresh POST after it.
	if activeRetirement >= 0 {
		retirement := existing[activeRetirement]
		cancellable := retirement.State == "pending" && retirement.Attempts == 0
		if cancellable {
			predecessorSent := false
			for index := activeRetirement - 1; index >= epochStart; index-- {
				candidate := existing[index]
				if candidate.Operation == "post" || candidate.Operation == "update" {
					predecessorSent = candidate.State == "sent" && candidate.MessageTS != ""
					break
				}
			}
			for index := activeRetirement + 1; index < len(existing); index++ {
				candidate := existing[index]
				if (candidate.Operation == "post" || candidate.Operation == "update") &&
					(candidate.State == "pending" || candidate.State == "retry" ||
						candidate.State == "sending" || candidate.State == "uncertain" ||
						candidate.State == "sent") {
					cancellable = false
					break
				}
			}
			cancellable = cancellable && predecessorSent
		}
		if !cancellable {
			epochStart = activeRetirement + 1
		}
	}
	for _, delivery := range existing[epochStart:] {
		if delivery.AgentRunID == run.ID && string(delivery.Body) == string(body) &&
			(delivery.State == "pending" || delivery.State == "retry" ||
				delivery.State == "sending" || delivery.State == "uncertain" ||
				delivery.State == "sent") && activeRetirement < 0 {
			return nil
		}
		if (delivery.Operation == "post" || delivery.Operation == "update") &&
			delivery.State == "sent" && delivery.MessageTS != "" {
			latestSent = delivery
		}
	}
	epoch := retirements + 1
	digest := sha256.Sum256(append([]byte(fmt.Sprintf("%s\x00%d\x00", run.ID, epoch)), body...))
	result := &core.SlackDelivery{
		ID:         fmt.Sprintf("%sepoch_%03d_%s", prefix, epoch, hex.EncodeToString(digest[:6])),
		EpisodeID:  run.EpisodeID,
		AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey,
		SourceInputID: run.SourceID, Operation: "post", Kind: "notice",
		ChannelID: episode.Destination.ChannelID, ThreadTS: episode.Destination.ThreadTS,
		ExpectedDestinationRevision: episode.DestinationRevision,
		Body:                        body, ResponseRoot: false, CoalesceKey: prefix,
	}
	if latestSent.MessageTS != "" {
		result.Operation, result.MessageTS = "update", latestSent.MessageTS
	}
	return result
}
