package service

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// ControlPlaneAct runs one incident-scoped operator action for the local web
// control plane, through the identical handler the Slack button calls.
//
// The dashboard cannot be given these paths any other way: publishing reviews
// the fork through the Coop client, discarding plans and executes a verified
// workspace deletion, and closing schedules cleanup — all against clients only
// this service holds. Reimplementing any of them against the store would be a
// second implementation of the safety rules, which is how a surface ends up
// with a button that skips the dirty-tree check.
//
// The Slack admission gate is mirrored, not skipped: Slack refuses every
// control except inspection and discard once the work is closed, so this
// entrance refuses the same ones rather than becoming the one door without
// the rule. The synthetic input carries the dashboard actor so the audit
// trail says where the action came from, and a fresh id so the outcome
// notices it enqueues are delivered rather than deduplicated away.
func (s *Service) ControlPlaneAct(ctx context.Context, action, incidentID, actor string) error {
	incident, err := s.store.GetIncident(ctx, incidentID)
	if err != nil {
		return fmt.Errorf("load the work record: %w", err)
	}
	inputID, err := core.NewID("cp")
	if err != nil {
		return err
	}
	input := core.SlackInput{ID: inputID, UserID: actor}
	closed := incident.Status == core.IncidentClosed
	switch action {
	case "publish":
		if closed {
			return errors.New("this work is closed, and Slack refuses publish on closed work too; discard is the remaining exit")
		}
		return s.publishDraftPR(ctx, input, incident)
	case "discard":
		return s.discardRetainedWork(ctx, input, incident)
	case "close":
		if closed {
			return errors.New("this work is already closed")
		}
		return s.closeIncident(ctx, input, incident)
	default:
		return fmt.Errorf("unsupported control plane action %q", action)
	}
}

// ControlPlaneChannelSetting writes a participation override the way the
// /responder slash command writes it: the same store call, the same three
// values, and "inherit" deleting the row rather than storing the word — an
// override that stored "inherit" would shadow the workspace default it is
// meant to defer to.
//
// Only the two overrides are offered. The channel-setup flow that writes
// channel_configurations is a guided Slack conversation with a repository
// catalogue behind it, and reproducing its choices in a form would be a second
// implementation of that flow rather than a view onto it.
func (s *Service) ControlPlaneChannelSetting(
	ctx context.Context,
	channelID, name, value, actor string,
) error {
	if name != proactiveSettingName && name != shadowSettingName {
		return fmt.Errorf("unsupported channel setting %q", name)
	}
	if value != "on" && value != "off" && value != "inherit" {
		return fmt.Errorf("channel setting %q must be on, off or inherit", name)
	}
	if strings.TrimSpace(channelID) == "" {
		return errors.New("a channel is required")
	}
	if value == "inherit" {
		if err := s.store.DeleteSlackSetting(ctx, "channel", channelID, name); err != nil &&
			!errors.Is(err, store.ErrNotFound) {
			return err
		}
		return nil
	}
	return s.store.SetSlackSetting(ctx, "channel", channelID, name, value, actor)
}

// ControlPlaneDiscardSession reclaims a retained workspace that belongs to no
// work record.
//
// Thirty-two of the thirty-eight blocked cleanups on the two live deployments
// have no incident, and the incident-shaped discard is the only one that
// existed — so the workspaces page told an operator, in its own words, that
// "reclaiming it needs an acknowledged discard path for record-less sessions,
// which does not exist yet". That is a fair description of a dead end, and a
// dead end that grows: every watch session that ends with a commit in its fork
// lands here and stays.
//
// Every safety rule the incident path enforces is enforced here, because they
// are rules about the workspace and not about the record:
//
//   - uncommitted work is never deleted, by anything, ever;
//   - the session must be closed and idle, so no turn can race the deletion;
//   - unpublished commits need Coop's explicitly acknowledged plan, not the
//     ordinary one.
//
// What is dropped is only the bookkeeping that needs an incident: there is no
// room to post an outcome notice to, and no work record to attribute. The
// audit row is the record instead, which is also the only record a record-less
// session could ever have.
//
// A session Coop has already forgotten is the common case here — the fork was
// reaped, or the whole state root was rebuilt — and it is a success, not an
// error. The cleanup row is the last thing holding a reference to something
// that is already gone, so it is closed out and said so.
func (s *Service) ControlPlaneDiscardSession(ctx context.Context, sessionID, actor string) error {
	item, err := s.store.GetCoopCleanup(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("load the cleanup record: %w", err)
	}
	if item.IncidentID != "" {
		return errors.New(
			"this workspace belongs to a work record, so it discards through that record's " +
				"own control, which posts the outcome to its Slack room",
		)
	}
	inputID, err := core.NewID("cp")
	if err != nil {
		return err
	}
	now := s.now().UTC()
	finish := func(operationID, detail string) error {
		if err := s.store.SetCleanupState(
			ctx, sessionID, "done", operationID, "", now,
		); err != nil {
			return err
		}
		s.audit(ctx, core.AuditEvent{
			Kind: "workspace.discard", ActorID: actor, ObjectID: sessionID,
			Outcome: "succeeded", Detail: detail,
		})
		return nil
	}

	session, err := s.coop.GetSession(ctx, sessionID)
	var apiErr *coop.APIError
	if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
		return finish("", "Coop no longer knows this session; the cleanup record was the last reference to a fork that is already gone.")
	}
	if err != nil {
		return err
	}
	if session.State == "discarded" {
		return finish("", "Coop had already discarded this session; only the cleanup record was still open.")
	}
	if session.State != "closed" || session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		return errors.New(
			"the Coop session is not closed and idle, so nothing was deleted — a turn could " +
				"still be writing to this workspace",
		)
	}
	plan, _, err := s.coop.PlanDiscard(
		ctx, "responder:discard-plan:"+inputID, session.ID, session.Revision, false, false,
	)
	if err != nil {
		return err
	}
	if plan.Plan.Workspace.Dirty {
		return errors.New(
			"the workspace has uncommitted changes, and nothing deletes dirty work — not the " +
				"janitor, not Slack, not this page; inspect the fork and decide what to preserve",
		)
	}
	if plan.Plan.Workspace.Unmerged {
		plan, _, err = s.coop.PlanDiscard(
			ctx, "responder:discard-plan-unpublished:"+inputID,
			session.ID, session.Revision, false, true,
		)
		if err != nil {
			return err
		}
		if plan.Plan.Workspace.Dirty || !plan.Plan.Workspace.AcceptedUnmerged {
			return errors.New("Coop did not return the exact acknowledged unpublished-work discard plan")
		}
	}
	if _, _, err := s.coop.Discard(
		ctx, "responder:discard:"+inputID, session.ID, plan.OperationID,
	); err != nil {
		return err
	}
	return finish(
		plan.OperationID,
		"Operator discarded a retained workspace that belongs to no work record.",
	)
}
