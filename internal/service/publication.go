package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func (s *Service) publishDraftPR(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	threadTS := incident.ConversationThreadTS()
	if !incident.IsEngineeringTask() {
		return s.enqueue(ctx, "out_publish_"+input.ID, incident, "notice", threadTS,
			slackui.Notice(
				"*Draft PR publication is available for engineering tasks only.* "+
					"Incident investigations remain read-only unless an operator starts an "+
					"explicit writable task.",
			))
	}
	if s.publisher == nil || !s.publisher.Enabled() {
		return s.enqueue(ctx, "out_publish_"+input.ID, incident, "notice", threadTS,
			slackui.Notice(
				"*Draft PR publication is not configured.* Enable the `github` publisher and "+
					"bind this repository to an absolute checkout, GitHub `owner/name`, and "+
					"base branch. GitHub credentials stay in Responder and are never exposed "+
					"to the agent.",
			))
	}
	if incident.ActiveTurnID != "" {
		return s.enqueue(ctx, "out_publish_"+input.ID, incident, "notice", threadTS,
			slackui.Notice(
				"*The draft PR was not published because the agent is still changing the "+
					"task fork.* Wait for this run to finish or stop it, then publish the "+
					"stable reviewed tree.",
			))
	}
	if incident.CoopSessionID == "" {
		return s.enqueue(ctx, "out_publish_"+input.ID, incident, "notice", threadTS,
			slackui.Notice(
				"*The draft PR is not available yet.* Responder has not finished preparing "+
					"the isolated task session.",
			))
	}
	changes, err := s.coop.Changes(ctx, incident.CoopSessionID)
	if err != nil {
		return err
	}
	if !coopChangesPresent(changes) {
		return s.enqueue(ctx, "out_publish_"+input.ID, incident, "notice", threadTS,
			slackui.Notice(
				"*There is nothing to publish.* The isolated task has no code changes. "+
					"Ask the agent to implement the requested change before creating a draft PR.",
			))
	}

	repository, ok := s.cfg.Repositories[incident.Repository]
	if !ok {
		return fmt.Errorf("repository %q is not configured", incident.Repository)
	}
	s.setNativeStatus(ctx, incident, "is reviewing and publishing the proposed change...")
	action, err := s.freezeAction(ctx, input, incident, false)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	review, _, err := s.coop.Review(
		ctx, "responder:publish-review:"+input.ID, action.SessionID, action.Revision,
	)
	if err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	if !review.Publishable {
		s.clearNativeStatus(ctx, incident)
		reasons := strings.Join(review.NotPublishableReasons, "; ")
		if reasons == "" {
			reasons = "the configured readiness review did not approve publication"
		}
		return s.enqueue(ctx, "out_publish_"+input.ID, incident, "review", threadTS,
			slackui.ReviewMessage(incident, reviewSummary(review)+"\n\nPublication stopped: "+reasons, false))
	}

	existing, err := s.store.GetPublication(ctx, incident.ID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	wasPublished := existing.Published()
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
		_ = s.store.Audit(ctx, core.AuditEvent{
			IncidentID: incident.ID, Kind: "publication.draft_pr",
			ActorID: input.UserID, ObjectID: record.HeadBranch,
			Outcome: "failed", Detail: record.LastError,
		})
		return s.enqueue(ctx, "out_publish_"+input.ID, incident, "notice", threadTS,
			slackui.Notice(
				"*Draft PR publication stopped safely.* "+record.LastError+
					"\n\nResponder did not merge or deploy anything. The Coop fork and "+
					"reviewed publication record were retained so an operator can correct "+
					"the issue and retry.",
			))
	}
	record.State = "published"
	record.LastError = ""
	record.PublishedAt = time.Now().UTC()
	if err := s.store.SavePublication(ctx, record); err != nil {
		s.clearNativeStatus(ctx, incident)
		return err
	}
	_ = s.store.Audit(ctx, core.AuditEvent{
		IncidentID: incident.ID, Kind: "publication.draft_pr",
		ActorID: input.UserID, ObjectID: fmt.Sprintf("%s#%d", record.Repository, record.PRNumber),
		Outcome: "succeeded", Detail: record.PRURL,
	})
	s.clearNativeStatus(ctx, incident)
	return s.enqueue(ctx, "out_publish_"+input.ID, incident, "publication", threadTS,
		slackui.PublicationMessage(record, wasPublished))
}
