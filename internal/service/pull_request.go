package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

func (s *Service) handlePullRequestReviewAction(
	ctx context.Context,
	input core.SlackInput,
) error {
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		return s.finishSlashInput(ctx, input, "Only active workspace members can start a PR review.")
	}
	source, err := s.store.GetSlackInput(ctx, input.ActionValue)
	if errors.Is(err, store.ErrNotFound) {
		return s.finishSlashInput(ctx, input, "That PR review button is stale. Use the latest one in the original thread.")
	}
	if err != nil {
		return err
	}
	if source.TeamID != input.TeamID || source.ChannelID != input.ChannelID ||
		(source.State != "processing" && source.State != "done") {
		return s.finishSlashInput(ctx, input, "That PR review button belongs to another or stale conversation.")
	}
	matches, err := s.watchOfferActionMatchesDelivery(ctx, input, source)
	if err != nil {
		return err
	}
	if !matches {
		return s.finishSlashInput(ctx, input, "That PR review button is stale. Use the latest one in the original thread.")
	}
	run, err := s.store.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		return err
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		return err
	}
	reference, ok := s.pullRequestReferenceForWatch(source, state)
	if !ok {
		return s.finishSlashInput(ctx, input, "I can no longer identify a configured PR from that conversation.")
	}
	digest := sha256.Sum256([]byte(input.ID + "\x00" + reference.URL))
	sourceID := "slack_pr_review_" + hex.EncodeToString(digest[:8])
	review := core.SlackInput{
		ID: sourceID, EnvelopeID: sourceID, EventID: sourceID, Kind: "shortcut",
		TeamID: source.TeamID, ChannelID: source.ChannelID,
		ThreadTS:  firstNonempty(input.ThreadTS, conversationalResponseThread(source)),
		MessageTS: source.MessageTS, UserID: input.UserID,
		Text: fmt.Sprintf(
			"Review %s deeply. Inspect the exact authenticated PR description, diff, and discussion. Identify correctness, security, operational, rollout, and testing risks; call out concrete file-level findings first. Then explain whether it is ready and how to collaborate on any missing work. If a concrete code change is warranted, offer a writable engineering task for this repository so the operator can prepare a focused follow-up. Do not modify the repository or publish GitHub comments during this review.",
			reference.URL,
		),
		ReceivedAt: s.now().UTC(),
	}
	if _, err := s.store.AdmitSyntheticSlackInput(ctx, review); err != nil {
		return err
	}
	if _, err := s.store.GetAgentRunBySource(ctx, "watch", review.ID); errors.Is(err, store.ErrNotFound) {
		if err := s.queueWatchedInput(ctx, review); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.pull_request.review", ActorID: input.UserID,
		ObjectID: review.ID, Outcome: "queued", Detail: reference.URL,
	})
	return s.finishSlackInput(ctx, input)
}
