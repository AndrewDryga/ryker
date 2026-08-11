package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

type coopReviewPatchReader interface {
	ReviewPatch(context.Context, string) (coop.ReviewPatchArtifact, error)
}

func (s *Service) publishDraftPR(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	if !incident.IsEngineeringTask() {
		return s.refuseControl(ctx, input, incident,
			"*Draft PR publication is available for engineering tasks only.* "+
				"Incident investigations remain read-only unless an operator starts an "+
				"explicit writable task.")
	}
	if s.publisher == nil || !s.publisher.Enabled() {
		return s.refuseControl(ctx, input, incident,
			"*Draft PR publication is not configured.* Enable the `github` publisher and "+
				"bind this repository to an absolute checkout, GitHub `owner/name`, and "+
				"base branch. GitHub credentials stay in Responder and are never exposed "+
				"to the agent.")
	}
	if incident.ActiveTurnID != "" {
		return s.refuseControl(ctx, input, incident,
			"*The draft PR was not published because the agent is still changing the "+
				"task fork.* Wait for this run to finish or stop it, then publish the "+
				"stable reviewed tree.")
	}
	if incident.CoopSessionID == "" {
		return s.refuseControl(ctx, input, incident,
			"*The draft PR is not available yet.* Responder has not finished preparing "+
				"the isolated task session.")
	}
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		return err
	}
	if !coopChangesPresent(changes) {
		return s.refuseControl(ctx, input, incident,
			"*There is nothing to publish.* The isolated task has no code changes. "+
				"Ask the agent to implement the requested change before creating a draft PR.")
	}

	repository, ok := s.cfg.RepositoryContext(incident.Repository)
	if !ok {
		return fmt.Errorf("repository %q is not configured", incident.Repository)
	}
	s.setNativeStatus(ctx, incident, "is reviewing and publishing the proposed change...")
	action, err := s.freezeAction(ctx, input, incident, false)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	rawReview, _, err := s.coop.Review(
		ctx, "responder:publish-review:"+input.ID, action.SessionID, action.Revision,
	)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	review := publicationReview(rawReview)
	if !review.Publishable {
		s.clearNativeStatus(ctx, incident)
		return s.updateEngineeringTaskCard(
			ctx,
			incident,
			slackui.ReviewMessage(incident, reviewSummary(rawReview), false),
			nil,
		)
	}
	review, err = s.completeReviewPatch(ctx, review)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return s.refuseControl(ctx, input, incident,
			"*Draft PR publication stopped because the complete reviewed patch could "+
				"not be verified.* "+trimError(err)+"\n\nThe isolated task and review "+
				"remain available. No branch was pushed and no pull request was created.")
	}

	existing, err := s.store.GetPublication(ctx, incident.ID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	wasPublished := existing.HasPR()
	headBranch, err := s.publisher.HeadBranch(incident, existing)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	pending := existing
	pending.IncidentID = incident.ID
	pending.Repository = repository.GitHubRepository
	pending.BaseBranch = repository.GitHubBaseBranch
	pending.ParentHead = review.ParentHead
	pending.CandidateTree = review.CandidateTree
	pending.HeadBranch = headBranch
	pending.State = "publishing"
	pending.LastError = ""
	if err := s.store.SavePublication(ctx, pending); err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}

	result, publishErr := s.publisher.Publish(ctx, publisher.Request{
		StateDir: s.cfg.StateDir, Incident: incident, Repository: repository,
		Review: review, Existing: existing,
	})
	record := pending
	if result.HeadBranch != "" {
		record.HeadBranch = result.HeadBranch
	}
	if result.CommitSHA != "" {
		record.CommitSHA = result.CommitSHA
	}
	if result.RemoteSHA != "" {
		record.RemoteSHA = result.RemoteSHA
	}
	if result.PRNumber > 0 {
		record.PRNumber = result.PRNumber
	}
	if result.PRURL != "" {
		record.PRURL = result.PRURL
	}
	if publishErr != nil {
		record.State = "failed"
		record.LastError = trimError(publishErr)
		_ = s.store.SavePublication(ctx, record)
		s.clearNativeStatus(ctx, incident)
		s.audit(ctx, core.AuditEvent{
			IncidentID: incident.ID, Kind: "publication.draft_pr",
			ActorID: input.UserID, ObjectID: record.HeadBranch,
			Outcome: "failed", Detail: record.LastError,
		})
		return s.refuseControl(ctx, input, incident,
			"*Draft PR publication stopped safely.* "+record.LastError+
				"\n\nResponder did not merge or deploy anything. The Coop fork and "+
				"reviewed publication record were retained so an operator can correct "+
				"the issue and retry.")
	}
	record.State = "published"
	record.LastError = ""
	record.PublishedAt = s.now().UTC()
	if err := s.store.SavePublication(ctx, record); err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	if err := s.store.ResetPublicationFollowup(
		ctx, record.IncidentID,
		s.now().UTC().Add(s.cfg.GitHub.FollowupInterval.Duration),
	); err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "publication.draft_pr",
		ActorID: input.UserID, ObjectID: fmt.Sprintf("%s#%d", record.Repository, record.PRNumber),
		Outcome: "succeeded", Detail: record.PRURL,
	})
	s.clearNativeStatus(ctx, incident)
	message := slackui.PublicationMessage(record, wasPublished)
	if review.Gate == "none" {
		message = slackui.WithRepositoryGateRecommendation(message)
	}
	if publicationGateIncomplete(review) {
		message = slackui.WithIncompleteValidationWarning(message)
	}
	return s.updateEngineeringTaskCard(ctx, incident, message, nil)
}

func (s *Service) markTaskPublicationStale(
	ctx context.Context,
	incident core.Incident,
) (core.Publication, error) {
	publication, err := s.store.GetPublication(ctx, incident.ID)
	if errors.Is(err, store.ErrNotFound) {
		return core.Publication{}, nil
	}
	if err != nil || !publication.Published() {
		return publication, err
	}
	reason := "The engineering task changed after this draft PR was published. " +
		"Run Update draft PR to review and publish the current task tree."
	changed, err := s.store.MarkPublicationStale(ctx, incident.ID, reason)
	if err != nil {
		return publication, err
	}
	if !changed {
		return s.store.GetPublication(ctx, incident.ID)
	}
	publication.State = "stale"
	publication.LastError = reason
	s.recordTimeline(ctx, core.TimelineEvent{
		ID:         "tl_publication_stale_" + incident.ID + "_" + incident.ActiveTurnID,
		IncidentID: incident.ID,
		ChannelID:  incident.ChannelID,
		Kind:       "publication.stale",
		ActorID:    "responder",
		Title:      fmt.Sprintf("Draft PR #%d needs an update", publication.PRNumber),
		Detail:     reason,
		URL:        publication.PRURL,
	})
	return publication, nil
}

func (s *Service) completeReviewPatch(
	ctx context.Context,
	review coop.Review,
) (coop.Review, error) {
	if review.PatchBytes == 0 || review.PatchDigest == "" {
		if review.PatchTruncated || len(review.Patch) == 0 {
			return review, errors.New("Coop review did not bind a complete patch artifact")
		}
		return review, nil
	}
	if int64(len(review.Patch)) != review.PatchBytes || review.PatchTruncated {
		reader, ok := s.coop.(coopReviewPatchReader)
		if !ok {
			return review, errors.New("Coop client cannot retrieve the complete review patch")
		}
		artifact, err := reader.ReviewPatch(ctx, review.PatchArtifactID)
		if err != nil {
			return review, err
		}
		if artifact.Digest != "" && artifact.Digest != review.PatchDigest {
			return review, errors.New("Coop review patch ETag does not match the review dossier")
		}
		review.Patch = artifact.Patch
	}
	if int64(len(review.Patch)) != review.PatchBytes {
		return review, fmt.Errorf(
			"Coop review patch is %d bytes, expected %d",
			len(review.Patch),
			review.PatchBytes,
		)
	}
	digest := sha256.Sum256(review.Patch)
	if hex.EncodeToString(digest[:]) != review.PatchDigest {
		return review, errors.New("Coop review patch digest does not match the review dossier")
	}
	review.PatchTruncated = false
	return review, nil
}
