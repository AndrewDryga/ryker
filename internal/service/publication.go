package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	publicationreview "github.com/AndrewDryga/responder/internal/publicationreview"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/publicationstore"
)

type coopReviewPatchReader interface {
	ReviewPatch(context.Context, string) (coop.ReviewPatchArtifact, error)
}

func (s *Service) publishDraftPR(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) (returnErr error) {
	if !incident.IsEngineeringTask() {
		return s.refusePublicationControl(ctx, input, incident,
			"*Draft PR publication is available for engineering tasks only.* "+
				"Incident investigations remain read-only unless an operator starts an "+
				"explicit writable task.")
	}
	if s.publisher == nil || !s.publisher.Enabled() {
		return s.refusePublicationControl(ctx, input, incident,
			"*Draft PR publication is not configured.* Enable the `github` publisher and "+
				"bind this repository to an absolute checkout, GitHub `owner/name`, and "+
				"base branch. GitHub credentials stay in Responder and are never exposed "+
				"to the agent.")
	}
	if incident.ActiveTurnID != "" {
		return s.refusePublicationControl(ctx, input, incident,
			"*The draft PR was not published because the agent is still changing the "+
				"task fork.* Wait for this run to finish or stop it, then publish the "+
				"stable reviewed tree.")
	}
	if incident.CoopSessionID == "" {
		return s.refusePublicationControl(ctx, input, incident,
			"*The draft PR is not available yet.* Responder has not finished preparing "+
				"the isolated task session.")
	}
	repository, ok := s.cfg.RepositoryContext(incident.Repository)
	if !ok {
		return fmt.Errorf("repository %q is not configured", incident.Repository)
	}
	claimInputID := input.ID
	expectedGeneration := int64(-1)
	if input.Kind == controlPlaneInput {
		claimInputID = ""
	} else if input.Kind == "action" {
		if _, generation, versioned := slackui.DecodePublicationActionValue(
			input.ActionValue,
		); versioned {
			expectedGeneration = generation
		}
	}
	existing, err := s.store.Publications.BeginReview(
		ctx, input.ID, claimInputID, incident.ID,
		repository.GitHubRepository, repository.GitHubBaseBranch,
		expectedGeneration,
	)
	if errors.Is(err, publicationstore.ErrCoalesced) {
		return nil
	}
	if errors.Is(err, publicationstore.ErrInProgress) {
		return s.refuseControl(ctx, input, incident,
			"*Draft PR work is already in progress.* The pinned task card will update "+
				"automatically. No second review or publication was started.")
	}
	if errors.Is(err, publicationstore.ErrBindingChanged) {
		detail := errors.New(
			"the task GitHub repository or base branch changed after its PR was created",
		)
		if transitionErr := s.recordPublicationAttemptFailure(
			ctx, incident.ID, input.ID, core.PublicationFailed, detail,
		); transitionErr != nil {
			return errors.Join(err, transitionErr)
		}
		return s.refuseControl(ctx, input, incident,
			"*Draft PR publication stopped because this task’s GitHub repository or base "+
				"branch changed after the PR was created.* Restore the original binding or "+
				"finish this PR manually; Responder will not cross-wire it to another repository.")
	}
	if errors.Is(err, publicationstore.ErrWorkUnavailable) {
		return s.refuseControl(ctx, input, incident,
			"*Draft PR publication did not start because this task is closing or closed.* "+
				"No review, branch push, or pull-request update was started.")
	}
	if err != nil {
		return err
	}
	if input.Kind == controlPlaneInput {
		defer func() {
			if returnErr == nil {
				return
			}
			persistCtx, cancel := publicationPersistenceContext(ctx)
			defer cancel()
			if transitionErr := s.recordPublicationAttemptFailure(
				persistCtx, incident.ID, input.ID, core.PublicationFailed, returnErr,
			); transitionErr != nil {
				returnErr = errors.Join(returnErr, transitionErr)
			}
		}()
	}
	wasPublished := existing.HasPR()
	progress := existing
	s.setNativeStatus(ctx, incident, "is reviewing and publishing the proposed change...")
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	if !coopChangesPresent(changes) {
		progress.State = core.PublicationFailed
		progress.FailureCode = core.PublicationFailureNoChanges
		progress.LastError = "The isolated task has no code changes to publish."
		if err := s.store.SavePublication(ctx, progress); err != nil {
			s.clearNativeStatus(ctx, incident)
			return err
		}
		s.clearNativeStatus(ctx, incident)
		return s.refuseControl(ctx, input, incident,
			"*There is nothing to publish.* The isolated task has no code changes. "+
				"Ask the agent to implement the requested change before creating a draft PR.")
	}
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
	review := publicationreview.NormalizeReview(rawReview)
	if !review.Publishable {
		progress.State = core.PublicationFailed
		progress.LastError = "The readiness review found blockers. See Latest update for details."
		if err := s.store.SavePublication(ctx, progress); err != nil {
			s.clearNativeStatus(ctx, incident)
			return err
		}
		s.clearNativeStatus(ctx, incident)
		return s.updateEngineeringTaskCard(
			ctx,
			incident,
			slackui.ReviewMessage(incident, publicationreview.ReviewSummary(rawReview), false),
			nil,
		)
	}
	review, err = s.completeReviewPatch(ctx, review)
	if err != nil {
		progress.State = core.PublicationFailed
		detail := safePublicationError(s, err)
		progress.LastError = "The complete reviewed patch could not be verified: " + detail
		if saveErr := s.store.SavePublication(ctx, progress); saveErr != nil {
			s.clearNativeStatus(ctx, incident)
			return errors.Join(err, saveErr)
		}
		s.clearNativeStatus(ctx, incident)
		return s.refuseControl(ctx, input, incident,
			"*Draft PR publication stopped because the complete reviewed patch could "+
				"not be verified.* "+detail+"\n\nThe isolated task and review "+
				"remain available. No branch was pushed and no pull request was created.")
	}

	headBranch, err := s.publisher.HeadBranch(incident, existing)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	pending := progress
	pending.ParentHead = review.ParentHead
	pending.CandidateTree = review.CandidateTree
	pending.HeadBranch = headBranch
	pending.State = core.PublicationPublishing
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
		record.State = core.PublicationFailed
		record.LastError = safePublicationError(s, publishErr)
		if saveErr := s.store.SavePublication(ctx, record); saveErr != nil {
			s.clearNativeStatus(ctx, incident)
			return errors.Join(publishErr, saveErr)
		}
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
	record.State = core.PublicationPublished
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
		s.log.Error(
			"schedule published draft PR follow-up",
			"incident", incident.ID,
			"publication", record.PRURL,
			"error", safePublicationError(s, err),
		)
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
	if publicationreview.GateIncomplete(review) {
		message = slackui.WithIncompleteValidationWarning(message)
	}
	if err := s.updateEngineeringTaskCard(ctx, incident, message, nil); err != nil {
		s.log.Error(
			"record published draft PR task-card summary",
			"incident", incident.ID,
			"publication", record.PRURL,
			"error", safePublicationError(s, err),
		)
	}
	return nil
}

func (s *Service) recordPublicationAttemptFailure(
	ctx context.Context,
	incidentID string,
	attemptInputID string,
	state core.PublicationState,
	cause error,
) error {
	return s.store.Publications.RecordFailure(
		ctx, incidentID, attemptInputID, state, safePublicationError(s, cause),
	)
}

func safePublicationError(s *Service, err error) string {
	return core.BoundedText(s.sanitizeText(trimError(err)), 1000)
}

func publicationPersistenceContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
}

func (s *Service) refusePublicationControl(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
	text string,
) error {
	record, err := s.store.GetPublication(ctx, incident.ID)
	if err == nil && record.State == core.PublicationRetrying &&
		(record.AttemptInputID == "" || record.AttemptInputID == input.ID) {
		record.State = core.PublicationFailed
		record.LastError = safePublicationError(
			s, errors.New(strings.ReplaceAll(text, "*", "")),
		)
		err = s.store.SavePublication(ctx, record)
	}
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.log.Error(
			"record refused draft PR attempt",
			"input", input.ID,
			"incident", incident.ID,
			"error", trimError(err),
		)
	}
	return s.refuseControl(ctx, input, incident, text)
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
	publication.State = core.PublicationStale
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
