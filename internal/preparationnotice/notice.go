// Package preparationnotice plans the single mutable Slack status for a
// triage run whose workspace is not ready yet.
package preparationnotice

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
	"github.com/AndrewDryga/responder/internal/slackui"
)

func Message(run core.AgentRun, cause error, now time.Time) (slackui.Message, bool) {
	if run.Mode != core.AgentRunTriage ||
		(!coop.Retryable(cause) &&
			!errors.Is(cause, sessioncreate.ErrReadOnlyAuthority) &&
			!errors.Is(cause, sessioncreate.ErrHistoricalCreateKeys)) {
		return slackui.Message{}, false
	}
	if errors.Is(cause, sessioncreate.ErrHistoricalCreateKeys) {
		return slackui.WorkspacePreparationBlocked(run.Repository, now.Add(30*time.Minute)), true
	}
	if errors.Is(cause, sessioncreate.ErrReadOnlyAuthority) {
		return slackui.ReadOnlyWorkspaceBlocked(run.Repository, now.Add(30*time.Minute)), true
	}
	return slackui.RepositoryPreparationBlocked(run.Repository), true
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
	for _, delivery := range existing {
		if delivery.AgentRunID == run.ID && string(delivery.Body) == string(body) &&
			(delivery.State == "pending" || delivery.State == "retry" ||
				delivery.State == "sending" || delivery.State == "uncertain" ||
				delivery.State == "sent") {
			return nil
		}
		if delivery.State == "sent" && delivery.MessageTS != "" {
			latestSent = delivery
		}
	}
	digest := sha256.Sum256(append([]byte(run.ID+"\x00"), body...))
	result := &core.SlackDelivery{
		ID: prefix + hex.EncodeToString(digest[:6]), EpisodeID: run.EpisodeID,
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
