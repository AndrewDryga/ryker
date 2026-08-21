package service

import (
	"context"
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
	"github.com/AndrewDryga/responder/internal/taskaccess"
	"github.com/AndrewDryga/responder/internal/taskpr"
	"github.com/AndrewDryga/responder/internal/taskpublication"
)

func (s *Service) processAutomaticTaskPublication(
	ctx context.Context,
	input core.SlackInput,
) error {
	result, err := taskpublication.Process(ctx, s.store, input, taskpublication.Policy{
		Now: s.now, RetryAt: s.queueDelay, Terminal: s.slackInputFailureIsTerminal,
		SafeError:   func(err error) string { return safePublicationError(s, err) },
		ControlKind: controlPlaneInput, Publish: s.publishDraftPR,
	})
	if err != nil {
		return err
	}
	if result.TerminalFailure {
		s.audit(ctx, core.AuditEvent{
			IncidentID: input.ActionValue, Kind: "publication.automatic_update",
			ActorID: input.UserID, ObjectID: input.ID, Outcome: "failed",
			Detail: result.Detail,
		})
	}
	return nil
}

func (s *Service) publishDraftPR(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) (returnErr error) {
	if refusal := taskaccess.PublicationRefusal(
		s.cfg, incident, input.UserID, input.Kind == controlPlaneInput,
	); refusal != "" {
		return s.refusePublicationControl(ctx, input, incident, refusal)
	}
	if _, terminal, err := s.terminalPublicationFollowup(ctx, incident.ID); err != nil {
		return err
	} else if terminal {
		return s.refuseTerminalPullRequestControl(ctx, input, incident, false)
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
	client, _ := s.publisher.(taskpr.Inspector)
	target, targeted, err := s.taskPullRequestResolver(client).Resolve(ctx, incident, repository)
	if err != nil {
		return err
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
	var targetBinding *core.PullRequestTarget
	if targeted {
		targetBinding = &target
	}
	existing, err := s.store.Publications.BeginReview(
		ctx, input.ID, claimInputID, incident.ID,
		repository.GitHubRepository, repository.GitHubBaseBranch,
		targetBinding, expectedGeneration,
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
	if errors.Is(err, publicationstore.ErrPRTerminal) {
		return s.refuseTerminalPullRequestControl(ctx, input, incident, false)
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
	if targeted {
		session, sessionErr := s.coop.GetSession(ctx, incident.CoopSessionID)
		if sessionErr != nil {
			return sessionErr
		}
		if bindingErr := taskpr.ValidateSession(session, target); bindingErr != nil {
			progress.State = core.PublicationFailed
			progress.FailureCode = core.PublicationFailureSessionBinding
			progress.LastError = safePublicationError(s, bindingErr)
			persistCtx, cancel := publicationPersistenceContext(ctx)
			defer cancel()
			if saveErr := s.store.SavePublication(persistCtx, progress); saveErr != nil {
				return errors.Join(bindingErr, saveErr)
			}
			return bindingErr
		}
	}
	s.setNativeStatus(ctx, incident, "is reviewing and publishing the proposed change...")
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	if !taskpr.ChangesPresent(changes, taskpr.AdmittedHead(target, targeted)) {
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
	if err := taskpr.ValidateReview(rawReview, target, targeted); err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	if rawReview.ParentTree != "" && rawReview.CandidateTree == rawReview.ParentTree {
		progress.State = core.PublicationFailed
		progress.FailureCode = core.PublicationFailureNoChanges
		progress.LastError = "The reviewed task tree already matches the pull request baseline."
		if err := s.store.SavePublication(ctx, progress); err != nil {
			s.clearNativeStatus(ctx, incident)
			return err
		}
		s.clearNativeStatus(ctx, incident)
		return s.refuseControl(ctx, input, incident,
			"*There is nothing new to publish.* The reviewed task tree already matches "+
				"the pull request baseline.")
	}
	review := publicationreview.NormalizeReview(rawReview)
	if !review.Publishable {
		progress.State = core.PublicationFailed
		progress.LastError = core.BoundedText(
			s.sanitizeText(publicationreview.ReviewSummary(rawReview)), 1000,
		)
		if err := s.store.SavePublication(ctx, progress); err != nil {
			s.clearNativeStatus(ctx, incident)
			return err
		}
		s.clearNativeStatus(ctx, incident)
		return s.refuseControl(ctx, input, incident,
			"*The readiness review found blockers.*\n\n"+progress.LastError)
	}
	review, err = coop.CompleteReviewPatch(ctx, review, s.coop)
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
				"remain available for retry.")
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
	if err := s.store.Publications.BeginPublishing(ctx, pending); errors.Is(err, publicationstore.ErrPRTerminal) {
		s.clearNativeStatus(ctx, incident)
		return s.refuseTerminalPullRequestControl(ctx, input, incident, true)
	} else if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}

	// The publication checkout fetches the reviewed parent commit from a local
	// path, so a repository declared by slug has to arrive here carrying the
	// managed clone rather than the empty string it configures.
	publishing := repository
	if checkout, err := ManagedRepositoryPath(s.cfg, repository); err == nil && checkout != "" {
		publishing.Path = checkout
	}
	result, publishErr := s.publisher.Publish(ctx, publisher.Request{
		StateDir: s.cfg.StateDir, Incident: incident, Repository: publishing,
		Review: review, Existing: existing,
	})
	receiptCtx, cancelReceipt := publicationPersistenceContext(ctx)
	defer cancelReceipt()
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
		if saveErr := s.store.SavePublication(receiptCtx, record); saveErr != nil {
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
			"*PR publication stopped.* "+record.LastError+
				"\n\nThe Coop fork and reviewed publication record remain available for retry.")
	}
	record.State = core.PublicationPublished
	record.LastError = ""
	record.PublishedAt = s.now().UTC()
	if err := s.store.SavePublication(receiptCtx, record); err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	if err := s.store.PublicationFollowups.Reset(
		receiptCtx, record.IncidentID,
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
	if err := s.updateEngineeringTaskCard(ctx, "", incident, message, nil); err != nil {
		s.log.Error(
			"record published draft PR task-card summary",
			"incident", incident.ID,
			"publication", record.PRURL,
			"error", safePublicationError(s, err),
		)
	}
	return nil
}

func (s *Service) refuseTerminalPullRequestControl(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
	reviewed bool,
) error {
	followup, err := s.store.PublicationFollowups.Get(ctx, incident.ID)
	if err != nil && !errors.Is(err, core.ErrNotFound) {
		return err
	}
	state := core.FirstNonempty(followup.PRState, "finished")
	detail := "Responder did not run a readiness review, push a branch, or change the pull request."
	if reviewed {
		detail = "The readiness review completed, but Responder stopped before any branch push or pull-request change."
	}
	return s.refuseControl(ctx, input, incident, fmt.Sprintf(
		"*This pull request is already %s.* %s Start a new engineering task to "+
			"review and publish another change.", state, detail,
	))
}

func (s *Service) terminalPublicationFollowup(
	ctx context.Context,
	incidentID string,
) (core.PublicationFollowup, bool, error) {
	followup, err := s.store.PublicationFollowups.Get(ctx, incidentID)
	if errors.Is(err, core.ErrNotFound) {
		return core.PublicationFollowup{}, false, nil
	}
	return followup, followup.Terminal(), err
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
		"Responder will review and update the draft PR automatically."
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
